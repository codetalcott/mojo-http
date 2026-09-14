# Periodic work off the event loop — measured 2026-09-14

*Linux container, 4 shared cores, Mojo 1.0.0. Eight closed-loop keep-alive
connections against a trivial handler, driven from Python. The absolute
throughput is the driver's, not the server's — every arm pays the same
driver cost, so the comparisons hold and the rps figures do not.*

## The question

`HTTPService.tick` was the framework's one answer to "do something without
an inbound request", and its docstring said to keep it quick without
saying what quick is. An application with a real cadence — a game tick, a
physics step, a pricing pass — has no way to read that instruction. So:
what does the tick cost, and where should that work go instead?

## What the tick costs

At 60Hz, one round per row:

| tick work | duty | rps | % of baseline | p99 | p99.9 | max |
|---|---:|---:|---:|---:|---:|---:|
| none (baseline) | — | 9188 | — | 2.36 | 3.21 | 8.46 |
| 0 ms (wakeup only) | 0% | 8979 | 98% | 2.42 | 3.50 | 5.84 |
| 1 ms | 6% | 8765 | 95% | 2.64 | 3.77 | 7.37 |
| 4 ms | 25% | 7315 | 80% | 4.79 | 5.86 | 7.49 |
| 8 ms | 50% | 4958 | 54% | 9.02 | 9.92 | 11.61 |
| 1 Hz x 50 ms | 5% | 7593 | 83% | 2.81 | **48.62** | **64.62** |

Three things, and they are what the docstring says now:

- **The wakeup is free.** 60Hz with no work costs 2%; the hook's mechanism
  was never the problem.
- **Throughput retention tracks `1 - duty cycle`**, at every point measured.
- **The work transfers into p99 about one for one.**

The last row is the shape that hides. A rare expensive tick leaves p50 and
p99 healthy and shows only in the maximum, so it passes any median-based
check and surfaces in production as an occasional unexplained stall.

## Where the work goes instead

Onto a thread of its own, publishing through the `BroadcastBus`. This is
not a new mechanism: `--pg-listen`'s listener thread is already exactly
this shape, and has been gated by `smoke-pg-notify` since I22. The loop
drains the channel and pays `sse_peer_frame`, nothing more.

The same 60Hz x 8ms work, medians of 3 rounds:

| | rps | p50 | p90 | p99 | max |
|---|---:|---:|---:|---:|---:|
| baseline (no work) | 8168 | 0.86 | 1.68 | 2.69 | 8.26 |
| on the loop | 4733 | 0.87 | 6.57 | 9.07 | 13.65 |
| off the loop | 8403 | 0.74 | 1.64 | 4.39 | 10.46 |

1.78x the throughput, restoring 103% of the no-work baseline; p90 4.0x
better, p99 2.1x. The on-loop arm was stable across rounds (rps 4442-4756,
p99 8.97-9.10) — a deterministic duty cycle, not noise. On the 1Hz x 50ms
shape the tail spike disappears outright: p99.9 46.27 -> 4.13, max
53.42 -> 7.30.

Bus delivery over 5s against an idle loop: **0% loss at 60Hz and 250Hz**.
At 1000Hz the count runs 1.6% under nominal, at least partly the
producer's own `sleep` granularity rather than the channel. 60Hz is
comfortably clean, and `apps/sim_loop` runs at 4Hz.

## The application

`apps/sim_loop`, and three things in it are the point because each is easy
to get wrong somewhere else:

- **The bus is created unconditionally, at one worker too.**
  `apps/datastar_counter` joins the bus only when `M0_WORKERS>1`, because
  there it is cross-worker fan-out — so it reads as "the bus is for
  multiple workers". Here it is the thread-to-loop channel and is needed
  in a single process.
- **`skip_worker = -1`, not this worker's index.** Nothing has queued the
  step locally. Passing the index publishes to nobody, and nothing says so.
- **The thread is joined within a bound.** `pthread_join` has no timeout,
  so `join_within` waits on the body's status slot instead — which is why
  the body writes `BLK_STATUS` as its very last act. A step that overruns
  is abandoned, not waited for: nothing here can interrupt it, and a
  longer wait only makes SIGTERM a no-op until SIGKILL.

`M0_SIM_ON_LOOP=1` moves the identical step onto `tick`. Same work, same
cadence, same publish; the only difference is which thread runs it.

## Two defects found while building the reference

Both are the kind the app now exists to prevent, and both were found by
running it rather than by reading it:

1. **The on-loop arm silently did nothing.** `tick` never fires unless
   `M0_APP_TICK_MS` is set, which the arm did not set — so it produced
   zero steps and a fast `/now`, reading as "the loop coped fine". The app
   now drives its own cadence in that mode, and the gate asserts the step
   ran on BOTH arms, because a negative arm that measures nothing makes
   the comparison vacuous.
2. **The first probe never joined its thread**, relying on process exit.
   That is the unbounded-shutdown bug in miniature; the reference joins.

## The gate

`smoke-sim-loop`, at 4Hz x 200ms — an 80% duty cycle, chosen so the
separation (measured ~200x: 0-1 ms off the loop against 199-200 ms on it)
leaves the 100 ms threshold with margin on both sides rather than being a
hair's breadth either way.

It asserts the steps arrive, their ids are contiguous, the loop stays free,
the on-loop arm is both slow AND productive, and SIGTERM with a step in
flight still exits 0. Sabotaged by publishing with `skip_worker = 0`, which
delivers to nobody and fails the first assertion.

## Not built

A framework helper — `Server.add_worker_thread(body, period)` or similar —
so an application need not hand-roll `ThreadSet` block slots. One
application is not evidence of a shape; see D26.
