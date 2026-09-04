# The detached loop — shipped 2026-09-03

> A design note from the engineering record. The comparison it came out of
> — Granian, Go's `net/http` and fasthttp, uWebSockets, uvloop, read at
> mechanism level against this server — is in the session's handoff notes;
> this page keeps the part that changed the tree.

## The finding

Under `--blocking-threads` and under the ASGI executor the event loop is an
acceptor: it parses, parks a request, and writes the answer a Python thread
produces. None of that needs Python. Yet `DetachingBackend.wait` released
the loop's thread state only around `kevent`/`epoll_wait` and took it back
after every wake — so every pass ran with the GIL held, and before every
pass the loop waited for whichever Python thread held it.

An instrumented build timed that `PyEval_RestoreThread` (log2 buckets,
printed at exit). Wall per row ≈ 13 s:

| row | rps @ cores | time blocked in the re-attach | per-wait mean / p99 / max | time parked in kevent |
|---|---|---|---|---|
| ASGI executor, c16 | 67.6k @ 1.01 | **16 %** | 7 µs / <65 µs / 191 µs | 42 % |
| ASGI executor, c256 | 83.9k @ 1.00 | **43 %** | 212 µs / <1 ms / 2.5 ms | 5 % |
| WSGI bare, w1 bt1, c16 | 69.2k @ 1.13 | **36 %** | 17 µs / <131 µs / 185 µs | 14 % |
| WSGI bare, w1 bt4, c256 | 71.5k @ 1.13 | **45 %** | 278 µs / <2 ms / 3.0 ms | 11 % |

At saturation the loop was parked 5 % of the time and blocked on the GIL
45 %: GIL-bound, not I/O-bound, which is why the pump measured one core with
two threads (WSGI_PERFORMANCE.md, "Evaluated the same day") and why the
inversion's gain was per-core only. Granian's tokio threads never take the
GIL; its 1.9x on bare WSGI in the same session was 1.75 cores genuinely
overlapping against m0serve's 1.1 that could not.

## The change

`_serve_offloaded` releases the loop thread's state once before
`run_event_loop` and restores it once after. `DetachingBackend` told
`set_loop_detached` is a plain wait. The one place the loop runs Python —
the inline fallback, `WSGIHandler.func` on a full submit queue or a pool
that is not accepting — attaches for itself with `PyGILState_Ensure` /
`Release`, as does the inline WebSocket serve. Everything else the loop's
handler does (`before_request`'s static and health answers, the registries,
`after_response`, `_finish_response`) is Mojo, and the audit that says so is
the one CLAUDE.md's rule about `PythonObject` destructors makes necessary.
`M0_LOOP_ATTACHED=1` restores the old shape for an A/B; the inline prefork
shape (no pool, no executor) is unchanged, since it runs Python on every
request.

One binary, one env var (`M0_LOOP_ATTACHED=1` is the attached arm), arms
alternated within each configuration, two rounds, 8 s, Apple M4, CPython
3.13.6, the tree as shipped (hand-off barrier with the 1 ms slice in place):

| configuration | attached | detached | change |
|---|---|---|---|
| ASGI executor, c16 | 68.4–68.6k rps @ 1.01, p50 218 µs | **109.1–109.9k @ 1.60, p50 133 µs** | +59–61 % |
| ASGI executor, c256 | 84.6–85.3k @ 1.00, p50 2.88 ms | **157.4–161.1k @ 1.83, p50 1.45 ms** | +86–89 % |
| WSGI bare, w1 bt1, c16 | 73.9–74.1k @ 1.13, p50 200 µs | **141.9–142.2k @ 1.72, p50 102 µs** | +92 % |
| WSGI bare, w1 bt4, c256 | 72.7–74.8k @ 1.15, p50 3.4 ms | **124.3–130.6k @ 2.38, p50 1.9 ms** | +71–75 % |
| WSGI bare, zero-config (pool of 8), c16 | 63.6–64.1k @ 1.52, p50 220 µs | **101.5–106.4k @ 2.55, p50 99 µs** | +59–66 % |

Bodies byte-identical, no errors. Against the comparators measured the same
evening: the executor at c256 does roughly 2x the rps of a single
uvicorn+uvloop process (~77–82k), on 1.8 cores where uvicorn has one; bare
WSGI in Granian's own topology (one I/O thread, one Python thread) goes from
0.37x to 0.75x Granian's rps.

## The twist: the attached loop was the pool's fairness pump

With the loop detached, the Django mixed workload at `--workers 1
--blocking-threads 4` on the GIL build reproduced Granian's own pathology
on that interpreter: fast-route p99 of 240–510 ms and a max of 0.9–1.0 s at
every slow level, where the attached loop held 1.4–1.9 ms. CPython's
`drop_gil` forces a real hand-off only when a waiter has set
`gil_drop_request` after the 5 ms switch interval; a pool thread that
finishes a job, detaches, dequeues the next at once and re-attaches wins the
GIL back before the threads it just signalled are scheduled, and a job one
of them already dequeued waits out the convoy. The attached loop was a
waiter on every pass, timing out and forcing switches roughly every 5 ms.
Granian with two or more blocking threads on 3.13 shows 0.7–1.3 s tails for
the same reason (its recorded flat 0.6 ms was a free-threaded 3.14t result).

So the pool has a **hand-off barrier with a slice**: two atomic counters
— threads parked inside `PyEval_RestoreThread`, and attaches completed. A
pool thread parks itself as a waiter around its re-attach; a thread that
has held its run of the GIL for a millisecond (`TURN_SLICE_NS`) and drops
it while a waiter exists yields (`sched_yield`, bounded at 1 ms) until an
attach completes. Per job rather than per slice, the hand-off — a thread
switch and a condvar wake — cost a 200 µs Django view 15 % of its
throughput (21.5k against 25k) at 1.3 cores; per millisecond it is a few
percent, and no waiter's extra wait exceeds the slice. The waiter is already inside the acquisition, so the GIL
never sits free while it wakes; the yield only stops the thread that just
ran from winning the race back. No syscall on the common path, nothing
held across a job, so a view that blocks (the GIL released inside it)
contends with nobody and slow-view isolation is untouched; a pool of one
has no barrier. The ASGI executor, one Python thread, has no convoy and
needs nothing.

Two token designs were tried first and are recorded so they are not
re-proposed. One token in a datagram pair (take before the attach, give
after) was fair but left the GIL idle while the next taker woke from the
kernel: a bare app at four threads and 256 connections fell from 137k to
67k rps, Django from 28k to 20k. N−1 tokens closed that gap on the bare
rows (84k) and then gave no order at all once a thread was asleep in a slow
view — three tokens for three active threads is no queue — and the Django
tail came back (p99 188 ms at slow=1). The barrier depends on neither the
thread count nor on how many threads are inside views.

The Django mixed workload (`apps/django_wsgi`, c16, one 200 ms slow view
held in flight per `slow` level), `--workers 1 --blocking-threads 4`, on
the same interpreter, is the trade written out. Fast-route rps and p99 /
max at slow = 0 / 1 / 2:

| build | rps @ cores | slow=0 | slow=1 | slow=2 |
|---|---|---|---|---|
| HEAD (attached loop) | 23.1k @ 1.08 | 1.42 ms / 9 ms | 1.95 / 10 | 1.81 / 10 |
| detached, no barrier | 28.3k @ 1.45 | **508 ms / 887 ms** | 401 / 1000 | 240 / 564 |
| detached, barrier per job | 20.7k @ 1.31 | 1.02 / 5.0 | 1.00 / 7.6 | 1.15 / 8.8 |
| **detached, barrier with 1 ms slice** (shipped) | **27.1–27.8k @ 1.44** | 7.6 / 23 | 4.6 / 14 | 1.9 / 14 |
| granian bt=4, same interpreter | 28.6k @ 1.49 | 771 ms / 1.2 s | 804 / 1380 | 816 / 1800 |

The slice is a constant (`TURN_SLICE_NS`), and the row above it is the
other setting of that constant: a hand-off on every job buys a 1 ms p99 at
−25 % throughput on a 35 µs view. A view longer than the slice hands off
every job either way, so on real applications the two rows converge; the
difference is what a micro-view pays, and the slice was chosen so that it
pays in tail (bounded by N−1 slices) rather than in throughput.

The gate is `poe probe-pool-fairness` (SPEC E11), pre-release like the
other timing probes: sixteen connections against `/busy?ms=0.3` on four pool
threads must hold a single-digit-millisecond p99, and the same run with
`M0_POOL_TURN=0` must convoy, or the probe cannot see the failure it exists
to catch.

## What this did not change

- The inline prefork shape and `--threads` (free-threaded, no GIL to
  contend for) keep their attached loops.
- The `SOCK_DGRAM` handoff itself. Its cost was measured at ~13 µs at p99 on
  the Mojo-only pool and is the next lever (an in-memory ring with a
  wake-only-if-parked flag), not this one.
- The benchmark pages. Their tables render from `bench/results/` artifacts
  recorded by `bench_asgi_wrk.sh` and `bench_layer_split.sh`; re-recording
  them is a separate, mechanical step.
