# The one-thread WSGI gap is the loop thread, not the bridge — measured 2026-09-05

> A design note from the engineering record. It re-asks the question the
> layer-split table on [BENCHMARKS.md](../BENCHMARKS.md) exists to answer
> — which layer bounds `m0serve` at one worker and one handler thread
> against Granian in the same shape — with a per-thread instrument, and
> gets the other answer. Two sentences in the tree changed because of it;
> nothing in the code did.

At one worker and one handler thread, `m0serve` serves bare WSGI at about
0.73–0.76x Granian's rate, and the layer-split table's per-core arithmetic
put that deficit in the bridge, the per-request crossing into CPython.
Measured per thread, the deficit is on the event-loop thread. It is
saturated while the Python thread has slack, it costs about 7.2 µs of CPU
per request against 5.3 µs for Granian's tokio thread, and the bridge
itself — the environ build, the call, the response read — is cheaper per
request than Granian's PyO3 crossing. About 1.2 µs of the loop's cost is
the datagram handoff to the pool thread; the rest of the difference is
user-space work in the request path.

## What a per-core table cannot say

The layer-split rows are rps per measured core, and a core count summed
over two threads doing different work cannot say which thread is the
bound. 143k rps on 1.65 cores is 11.5 µs of CPU per request against
Granian's 9.3, and the inline row prices the bridge at 1.44x, so the
arithmetic reads as "the bridge". But a server with an acceptor thread
and a handler thread is a two-stage pipeline, and its rate is set by the
slower stage, not by the sum. Which stage that is takes a per-thread
measurement, and the answer changes what is worth building.

## Per thread

`ps -M -p PID` once a second over an 8 s `wrk -t2 -c16` run with the
browser headers `bench_layer_split.sh` sends, medians of the samples; byte
parity held; Apple M4, CPython 3.13.6, granian 2.8.2, the 0.18.0 tree at
`be7df4b`. Absolute rates ran under the committed artifact's, as they do
across sessions on this hardware; the ratios are the signal.

| server | rps | I/O thread | Python thread | cores |
|---|---:|---:|---:|---:|
| `m0serve --workers 1 --blocking-threads 1` | 131.2k | loop **98.6 %** | pool 69.8 % | 1.68 |
| `granian --workers 1 --blocking-threads 1` | 180.8k | tokio **96.5 %** | blocking 81.0 % | 1.77 |
| `apps/hello`, no Python | 149.3k | 98.8 % | — | 0.99 |
| `m0serve`, app inline on the loop | 103.7k | 97.4 % | — | 0.97 |

Both servers saturate the I/O thread and leave slack on the Python
thread. A saturated stage's per-request cost is its CPU fraction over
the rate: the m0serve loop 7.5 µs, Granian's tokio thread 5.3 µs; the
Python threads 5.3 and 4.5 µs. The ratio holds as concurrency rises, so
this is not a 16-connection artefact:

| connections | m0serve bt1 | granian bt1 | ratio |
|---|---:|---:|---:|
| 16 | 131.2k (loop 98.6 %, pool 69.8 %) | 180.8k (96.5 %, 81.0 %) | 0.73x |
| 64 | 147.8k (99.1 %, 68.8 %) | 198.6k (95.0 %, 80.1 %) | 0.74x |
| 256 | 150.9k (98.3 %, 66.9 %) | 203.6k (96.8 %, 75.4 %) | 0.74x |

Two consequences before any profile. A faster bridge cannot move the
one-thread row, because the thread it runs on is not the bound. And the
bench's cores column, which sums the process's `%cpu`, is the wrong
instrument for the question it was added to answer: it sees 1.65 against
1.76 and cannot see that one of the 1.65 is a saturated loop.

## Where the loop's time goes

Instruments' Time Profiler — `xctrace record --template 'Time Profiler'
--attach PID --time-limit 5s`, on-CPU samples only — taken inside the same
kind of wrk run; each column is that thread's own samples, scaled to
microseconds by that run's rate and the thread's CPU fraction (m0serve
135.4k rps with the loop at 98 %, 7.2 µs per request; Granian 179.5k with
the tokio thread at 94.6 %, 5.3 µs; hello 153.4k at 98.4 %, 6.4 µs). The
loop's `sendto` and `recvfrom` are split into their two callers by hello's
single-syscall figure.

| µs per request | hello loop | m0serve loop, bt1 | granian tokio thread |
|---|---:|---:|---:|
| socket recv (`recvfrom`) | 1.2 | 1.2 | 1.6 |
| response send (`sendto` / `writev`) | 1.6 | 1.6 | 1.8 |
| `kevent` | 0.35 | 0.24 | 0.32 |
| submit `sendto` to the pool | — | 0.65 | — |
| completion `recvfrom`s (one per completion, plus the EAGAIN) | — | 0.58 | — |
| waking a parked thread (`semaphore_signal`) | — | — | 0.07 |
| clock (`mach_absolute_time`) | 0.08 | 0.09 | 0.14 |
| user space, everything else | 3.1 | 2.85 | 1.3 |
| **total** | **6.4** | **7.2** | **5.3** |

The kernel charges the two servers the same for the socket: within 0.2 µs
on the send, and tokio's read side is if anything the dearer one. What
the loop pays that tokio does not is 1.2 µs of handoff syscalls and about
1.5 µs more user-space work per request. The user-space work, by the
profile's own ranking: `Headers._name_matches` (the linear name scans
behind every header the loop asks for), `scan_token`, `Headers.set_bytes`,
`_handle_read_headers`, `List.extend` (buffer copies), `_run_pass`,
`drain_completions`, `_process_request`, `_finish_response`,
`parse_request_headers`, `write_latin1_to`, `_drain_pipelined`. In
isolation `bench_http_parts.mojo` prices the parts at 2.09 µs today
(parse 0.95, `from_parsed` 0.19, `OK()` 0.54 — which under a pool runs on
the pool thread, not here — `encode_into` 0.30); in situ the loop's user
space is 2.85, so about 1.2 µs per request lives outside the parts: the
copies, the provision reset, the offload lists, the pipelined re-check,
the pass itself.

The loop is compute-bound, not waiting. A throwaway build (a worktree,
not committed) put counters and a timer around `backend.wait` and a
completion count in `_service_completions`, printed at shutdown:

| shape, 16 connections | rps | `kevent` calls per request | events per call | time inside passes | time in `wait`, per request |
|---|---:|---:|---:|---:|---:|
| m0serve bt1 | 141k | 0.22 | 5.4 | 96 % | 0.3 µs |
| `apps/hello` | 156k | 0.08 | 12.9 | 98 % | 0.1 µs |
| m0serve inline | 106k | 0.07 | 13.8 | 99 % | 0.1 µs |

(Idle waits between the warm-up and the measured run are excluded; they
are the only waits over a millisecond.) One `kevent` per five requests
returning five events, and 0.3 µs of wait per request, agree with the
profile's 0.24 µs and rule out the other story — a loop parking after
every completion and paying a wake each time.

## The Python thread

Same trace, same scaling (the m0serve pool thread at 69.2 % of 135.4k,
5.1 µs per request; Granian's blocking thread at 77.8 % of 179.5k,
4.3 µs).

| µs per request | m0serve pool thread | granian blocking thread |
|---|---:|---:|
| job `recvfrom`, blocking, the park and the wake inside it | 0.82 | — |
| completion `sendto` | 0.58 | — |
| spin-yield and park (`swtch_pri`, `semaphore_wait`) | — | 0.29 |
| waking a runtime parked in `kevent` | — | 0.05 |
| thread-state save and restore | 0.04 | 0.04 |
| environ build, the call, the response read, Python | **3.7** | **4.0** |
| **total** | **5.1** | **4.3** |

The bridge this repo spent five rounds on is cheaper per request than
Granian's, by about a tenth. What makes the pool thread dearer than
Granian's blocking thread is the 1.4 µs of `recvfrom` and `sendto` around
each job. Add the two threads and m0serve spends 12.3 µs of CPU per
request to Granian's 9.6, and the handoff's 2.6 µs (1.2 on the loop, 1.4
on the pool) is the whole of that difference: the CPU-efficiency gap is
the socketpair, and the throughput gap is the loop.

## Why Granian's handoff costs nothing

Granian 2.8.2, `src/wsgi/http.rs` and `src/blocking.rs`. `call_http`
opens a `tokio::sync::oneshot`, `spawn_blocking`s a closure, and the
hyper task awaits the receiver. `spawn_blocking` is a `crossbeam_channel`
unbounded `send`; the one blocking thread runs `py.detach(|| queue.recv())`
then the task attached. Crossbeam's `recv` spins, then yields, then parks
(`std::thread::park`, a semaphore on macOS) — the 0.29 µs of `swtch_pri`
and `semaphore_wait` on the blocking thread is that backoff absorbing the
gap between jobs, so the thread parks on a minority of them, and the
sender's `unpark` costs a syscall only then (the 0.07 µs of
`semaphore_signal` on the tokio thread). The reply is the oneshot's
`send` waking the task's waker; the current-thread runtime's unpark is an
atomic state swap unless the driver is parked in `kevent`, when it is one
`kevent` from the blocking thread (the 0.05 µs there). Common path: zero
syscalls, two atomics.

`OffloadPool` (`offload.mojo`) chose two `SOCK_DGRAM` socketpairs so that
the ownership handoff *is* the syscall — the kernel lock is the fence,
the kernel is the queue, and the completion end is something kqueue can
wake the loop on. The price is four syscalls per request (submit send,
job recv, completion send, completion recv) plus the EAGAIN read that
ends each drain, at 0.3–0.8 µs of CPU each on macOS whether or not
anything parks — and the pool thread's blocking `recv` does park on most
jobs, because the loop is the slower stage and its queue is usually
empty. A C ping-pong of the primitives on this machine, two threads,
200k round trips, both threads' CPU per round trip: spin 0.1–0.2 µs,
condvar 2.0, two datagram pairs 2.7–3.0, the same with the loop side
parking in `kevent` and draining to EAGAIN 4.5.

## What matching Granian would take

The loop must shed about 1.9 µs per request. The lever
[detached-loop.md](detached-loop.md) named under "What this did not
change" — an in-memory ring with a wake-only-if-parked flag — is worth
about 1.2 µs on the loop and 1.4 µs on the pool thread: a queue whose
acquire/release stores replace the socketpair as the ownership fence; a
parked flag per side, so the loop pokes the pool (one datagram, or a
semaphore) only when the pool is parked and the pool pokes the loop only
when the loop is in `kevent`; and a spin-then-park on the pool side so
the one-to-two-microsecond gap between jobs at these rates is absorbed
without a park, which is exactly what crossbeam's backoff buys Granian.
With that alone the loop sits near 6.0 µs and the row near 0.9x. The
remaining 0.7 µs is the user-space work above — the name scans, the
parse, the per-request bookkeeping the parts instrument does not see —
and matching Granian per thread means finding it. Bridge work buys
nothing on this row until the loop is faster; once it is, the pool thread
becomes the bound at its 5.1 µs, which is the other reason the ring has
to serve both sides.

## The instruments, and a trap

- **Per-thread CPU** is `ps -M -p PID` on macOS, sampled once a second
  and reduced to a median per thread. The bench script's process-level
  `%cpu` is a sum over threads and cannot distinguish a saturated loop
  beside an idle pool from two half-busy threads.
- **On-CPU profile** is Instruments' Time Profiler through `xctrace`,
  exported with `xctrace export --input X.trace --xpath
  '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'`. The
  export is not well-formed XML: Mojo symbol names put raw `&`, `<` and
  `>` inside `name=` attributes, so ElementTree refuses it and a regex
  pass over the `<row>` elements — resolving the `id`/`ref` pairs on
  `thread`, `tagged-backtrace`, `backtrace` and `frame` — reads it.
- **The trap is `/usr/bin/sample`.** It is a wall-clock sampler and it
  samples blocked threads too, and on this loop it attributed 28.8 % of
  the thread's samples to `kevent` where the on-CPU share is 3.3 % and the
  loop's own timer around the wait agrees with the on-CPU figure. On
  hello the same tool put `kevent` at 3.8 % against an on-CPU 5.5 %, so
  the distortion is specific to the offloaded shape; its mechanism was
  not chased. A `sample` profile of a thread that shares a pipeline with
  another thread is not evidence about its syscall shares.

## What changed in the tree

The paragraph under the layer-split table in
[BENCHMARKS.md](../BENCHMARKS.md) and the Granian bullet in the README no
longer say the deficit is the bridge rather than the event loop; they say
what this page measured and point here. The tables and the artifacts are
as they were. The ring handoff this page names as the lever was built the
same day: [pool-ring-handoff.md](pool-ring-handoff.md).
