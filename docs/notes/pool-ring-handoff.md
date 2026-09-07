# The pool handoff moved into memory — shipped 2026-09-05

> A design note from the engineering record. It is the change
> [loop-thread-bound.md](loop-thread-bound.md) recommended, built the
> same day: the `--blocking-threads` handoff between the event loop and
> its handler threads now rides in-memory rings, and the two datagram
> socketpairs carry only wakes and payloads.

Bare WSGI at one worker and one handler thread, the same binary with the
ring on and off in the same session, is 155k requests per second against
131k at 16 connections and 184k against 154k at 256. The loop thread's
per-request cost went from 7.5 µs to 6.3 µs at 16 connections and to
5.3 µs at 256, which is what Granian's tokio thread costs. The rest of
the gap to Granian on this row is user-space work in the request path,
and it is the next thing to measure.

## What was measured before it was built

The per-thread instrument in [loop-thread-bound.md](loop-thread-bound.md)
put the saturated stage on the event-loop thread, at 7.2 µs of CPU per
request against 5.3 for Granian's tokio thread, and priced the handoff at
1.2 µs of that: a `sendto` to submit each job (0.65) and the `recvfrom`s
that drained each completion (0.58). On the pool thread the handoff was
1.4 µs of a 5.1 µs job — a blocking `recvfrom` that parked on most jobs,
and a `sendto` per completion. Granian's crossbeam channel and tokio
oneshot cost it nothing on the common path: two atomics, a spin that
absorbs the gap between jobs, and a syscall only when a thread is
actually parked. A C ping-pong of the primitives on this machine put the
datagram pair at 2.7–3.0 µs of CPU per round trip and the same with the
loop side parking in `kevent` at 4.5, against 0.1–0.2 for a spin.

## The design

`lightbug_http/ring.mojo` is Dmitry Vyukov's bounded multi-producer,
multi-consumer queue over `malloc`'d memory: a sequence word per cell
says whose turn the cell is, producers contend on one counter and
consumers on another, and a claimed cell is published by its own
sequence store, so a reader never sees a half-written value and no lock
exists to be held across a park. `OffloadPool` keeps one ring per pool
lane for jobs (`submit` pushes, `next_job` pops) and one for completions
(`complete` pushes, `drain_completions` pops). The rings are the ownership
fence the socketpair syscalls used to be.

The socketpairs stay, for two jobs. Everything that carries a payload
still rides them — an inbound WebSocket message, the poison pill, a
stream abort, and every datagram of the asyncio executor, whose lane and
completion protocol are untouched. And they are the WAKE, used only when
the receiving side has said it is parked:

- A pool thread whose ring is empty spins for `POOL_SPIN_NS` (10 µs,
  yielding after 2), then counts itself parked in a per-lane word,
  re-checks the ring, and only then blocks in `recv`. `submit` pushes,
  then reads that count, and pokes the lane with an 8-byte `_POKE`
  datagram only if it exceeds the wakes already in flight to the lane —
  one wake per parked thread, never one per push, so a burst into N
  parked threads sends N and leaves no stale wake for a thread to spin
  on later.
- The loop raises its own flag before `backend.wait` and re-checks the
  completion ring after raising it (`_wait_for_events`); a non-empty ring
  skips the wait and runs a pass with no events, whose first act is to
  drain it. `complete` pushes, then reads the flag, and pokes the
  completion channel only if it is set.

Announce, then re-check, then block; push, then read the announcement,
then poke. Every step is sequentially consistent (the stdlib's default),
so on each side one of the two always sees the other and a wake is never
lost. The lost-wakeup test in `test_offload.mojo` submits two hundred
jobs to a thread that has parked before every one of them, with a
two-second bound on each completion; reordering either sequence is what
it exists to catch. A thread that never runs dry still sees a pill or a
WebSocket message: `next_job` polls its socket non-blocking once per
`POOL_DGRAM_POLL_NS` (100 µs) before it looks at the ring, whatever the
ring holds. The loop's flag starts SET and the
inversion's driver never clears it — it waits inside asyncio rather than
in `_wait_for_events` — so that path keeps the datagram per completion
it always had. `M0_POOL_RING=0` builds a pool with no rings, and both
crossings are then the syscalls they were.

The spin is the part that makes a park rare rather than free, and it is
crossbeam's shape: at 130–180k requests per second the gap between jobs
on one thread is a microsecond or two, inside the spin, so most jobs are
taken without a park and most submits without a poke. It runs detached
(the pool body saves its thread state before `next_job`), so it holds no
GIL, and it is what the pool thread's higher CPU figure below is.

## Measured

`ps -M` per thread, medians over 8 s of `wrk -t2` with browser headers,
`apps/wsgi_bare`, `--workers 1 --blocking-threads 1`, the same binary
with `M0_POOL_RING` unset and `=0`, arms alternated, Apple M4, CPython
3.13.6.

| connections | ring off | ring on | change |
|---|---:|---:|---:|
| 16, round 1 | 129.7k rps (loop 96 %, pool 67 %) | 155.0k (loop 98 %, pool 89 %) | +19 % |
| 16, round 2 | 133.3k (97 %, 69 %) | 150.4k (95 %, 84 %) | +13 % |
| 256 | 154.4k (99 %, 67 %) | 184.5k (98 %, 73 %) | +19 % |

Per request on the saturated loop thread: 7.4 µs off, 6.3 on at 16
connections, 5.3 on at 256. Granian 2.8.2 in the same session, one
worker and one blocking thread, 16 connections: 186.0k rps (tokio 98 %,
blocking 81 %). The row is 0.82x Granian at 16 connections, from 0.72x,
and about 0.9x at 256.

The pool thread's CPU rose at 16 connections, from 67 % to 84–89 %,
while its work per job fell: the spin is on the clock. At 256 connections
the ring is rarely empty and the thread runs at 73 % for 19 % more
requests, 4.0 µs per job against 5.1 before — the 1.4 µs the handoff
cost it, gone. What a spin costs at low load is bounded by `POOL_SPIN_NS`
per job; at ten microseconds, a server taking a thousand requests a
second spends one percent of one core on it.

The spin length was chosen by measurement, same binary but for the two
constants, arms alternated, later the same day on a faster-running box
(absolute rates are not comparable to the table above; the pairs are):

| connections | spin 30 µs, yield after 5 | spin 10 µs, yield after 2 |
|---|---:|---:|
| 16 | 168.9k / 173.6k rps, pool thread 88 % | 169.7k / 168.6k, pool thread 75–77 % |
| 256 | 185.1k, pool 67 % | 185.4k, pool 62 % |

The shorter spin gives the same throughput and a tenth of a core back,
so it is the one shipped.

## The hole the first CI run found

Linux CI's `smoke-django-realtime` phase 5 failed on the first run: `a
hold taken on a pool thread did not register with the loop`. Two 1.5 s
views hold two of four pool threads, a subscribe follows 0.3 s later, and
half a second after that the loop had no subscriber. The same phase
passed on macOS and in an idle Linux container, four times under two CPU
hogs, and under a probe that opened forty holds while three clients kept
the loop busy — so the first model, a hold's head finished before its
frame was read, was wrong, and the outbox sweep says why: it closes an
unsubscribed flagged slot only for an executor's stream. What reproduced
it was the phase itself, repeated with a fresh server each round: 2 of 10
rounds with the ring on, 0 of 10 with `M0_POOL_RING=0`, and in the
failing rounds the subscriber appeared 1.5 s late — when a slow view's
thread came back to the ring. The job had been pushed and nobody was
woken for it.

*(The chained wake described here was replaced the next day by the
loop's per-pass age check, and the shared lane socket by a wake channel
per thread: [elastic-pool.md](elastic-pool.md).)*

A wake datagram is a credit for ONE parked thread, and the cap sends at
most one per parked thread. But a thread woken for job 1 polls its socket
on its way back to the ring, and that poll can read the wake sent for job
2; it takes job 1, its sibling stays parked with no datagram to wake it,
and job 2 waits for whichever busy thread returns first. The fix is the
chained wake a condition variable would use: a thread that takes a job
and leaves work on the ring pokes a parked sibling by `submit`'s own
rule (`_chain_wake`; the unit test is
`test_a_thread_that_takes_a_job_wakes_a_parked_sibling_for_the_rest`).
After it, 0 of 20 rounds failed in the container. The same commit also
made frame-before-head deterministic for a completion off the ring —
`_complete_one` drains both bus channels before finishing a streaming
head or a 101, since a ring completion is not an event and its frame's
readiness may not be in the pass — which is hardening, not the fix.

## What did not change, and what is next

The executor's protocol, the mounted server's lanes, the streaming seam
and the `--realtime` hold path are as they were; the pool-exercising
smokes (`smoke-blocking-threads`, `smoke-wsgi-stream`, `smoke-shutdown`,
`smoke-django-realtime` and its WebSocket phase, `smoke-hybrid`,
`smoke-pool`, `smoke-wsgi`, `smoke-django`) and both package suites ran
green on the change before it was measured.

The loop is still the bound on this row, at 6.3 µs per request against
tokio's 5.3, and what is left in it is user space: the header-name scans
behind every lookup (`Headers._name_matches`), the parse, and about a
microsecond of per-request bookkeeping outside the parts the
`bench_http_parts.mojo` instrument prices. That is the next measurement.
The pool thread has headroom to ~250k requests per second at its 4.0 µs,
so the ring serves both sides of the pipeline, as it had to.
