# The Mojo handler pool — shipped 2026-08-28

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

The offload pool, for handlers written in Mojo. Planned as a kill-criterion
spike: if a slow Mojo handler did not strand the connections behind it the
way a slow Python view does, the branch was to be deleted and this entry was
to say why. It stranded them harder — a Mojo handler blocks the single loop
thread outright, so at two 400 ms blockers the fast route's **p50** was
405 ms, not merely its p99 — and the pool of 4 held 0.2–0.3 ms throughout
(three runs; the loop-only collapse is definitionally expected, the pooled
row's complete recovery is the result). `lightbug_http/mojo_pool.mojo`:
`MojoPool` + `PoolHandler` (`make`/`shutdown` — two methods against
`ThreadHandler`'s eleven, the other nine being WSGI streaming and mounts),
over the same `OffloadPool`/`ThreadSet` machinery, minus the four
attach/detach sites that were the only Python in the WSGI pool's thread body.

Boundaries, stated where they were decided:

- **Blocking handlers only.** `asyncrt`'s `TaskGroup` parallelises CPU work
  inside one handler at 3.6x with no plumbing; the pool exists for threads
  parked in a syscall. The spike's `/slow` is `usleep`, not a spin, so the
  measurement cannot conflate the two.
- **Streaming from a pool thread is a 409**, matching the blocking loop's
  `gate_streaming_response` refusal: the loop drains its own handler's
  registries, and a stream begun on a pool thread has no producer.
- **The saturation boundary is in the probe's own table** (blockers >
  threads), so the pooled row is shown degrading where it must rather than
  implying N threads are magic. Measured at 6 blockers on 4 threads
  (`bench/results/pool-probe-20260828T175956Z.json`): the pool's fast-route
  p99 is ~one blocking duration (404 ms, p50 31.8 ms) while the bare loop's
  is the queue's sum (2026 ms, p50 2022 ms) — saturation degrades a pooled
  server linearly, not catastrophically.
- **Untested, recorded not dropped:** composition with `M0_WORKERS` prefork
  (the Python table says prefork alone does not fix stranding — same
  mechanism here, unmeasured); the per-mount `lanes` plumbing has no
  consumer yet.

Guards: `test_mojo_pool` in `test-http`; `smoke-pool` in CI (thread
attribution, saturation, clean SIGTERM); `sabotage-pool` in CI on Linux —
the one-pill-per-thread rule is invisible on macOS, where closing the
submit channel wakes a blocked `recv` (`OffloadPool.stop`'s documented
20-minute-CI-timeout lesson); `probe-pool` pre-release (RELEASING.md).
Sabotage earned its keep before landing: it caught the per-thread-handler
test asserting completions without ever checking the handler indices
differed.
