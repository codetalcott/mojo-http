# The ramp test: lanes in the host, one module on two hosts — 2026-09-17

> A design note from the engineering record. Phase 3 of the Mojo host
> plan, in two rounds: **R5a**, pool lanes in the host and a route's
> placement on its table (this note's first half, SPEC E26 and N19, D31
> and D32); **R5b**, the ramp module itself, one views module compiled
> under `m0serve` and under the host and gated byte for byte and by
> placement (the second half, SPEC N20). The brief it executes is the
> owner's `mojo-host-phase-3-brief.md`; its open questions are answered
> below as recommended there.

**The question.** The Mojo host (D28–D30) served every request on its
loop. `m0serve` serves a Mojo mount on `MojoPool` threads, N per lane. A
views module written for one could not be promised to behave on the
other: the same 200 ms compute view that a mount absorbs on one of four
threads stalls every connection on a host worker for 200 ms — the pool
bullet's measured 1.6 ms to ~194 ms p99. The plan's Phase 3 asks for a
module that compiles into both and answers the same bytes AND the same
placement, and the placement half is what forces lanes into the host.

## R5a — the lane

### What the host does now under `M0_BLOCKING_THREADS=N`

The variable v1 refused (D29) is served (D31): one `OffloadPool` per
worker's loop, one lane, N `MojoPool` threads on it. The lane is marked
GIL-free (`set_lane_gil_free`) because nothing in a Mojo host ever
attaches to an interpreter: a job that has waited past the idle spin
wakes a parked sibling, while `submit` stays elastic (SPEC M25's rule,
which held a compute route to one of four threads before it and cost a
trivial one a fifth of its rate under eager wakes).

**One conformance, two instances.** `MojoPool.start[T]` asks for a
`PoolHandler` built by `make(PoolContext)` on the thread that will use
it; the application wrote an `AppHandler` built by `make(HostContext)`.
`PoolLane[H]` is the adapter between them, in `host.mojo`: `ctx.user` is
the address of the worker's `HostContext`, copied to memory that outlives
`serve` exactly as the producer's is, and the copy handed to `H.make`
carries `thread`, the pool thread's index, where the loop's own instance
has `-1`. Only `func`, `before_request` and `after_response` are
forwarded, because only those run on a pool thread; the streaming hooks,
`tick` and `ws_message` are the loop instance's. The brief proposed the
application conforming twice; the adapter was chosen because the host's
reason to exist is that an application cannot spell the wiring wrong,
and a second conformance is a second place to.

**Every thread's handler, or none.** A `PoolHandler.make` that raised
used to print `mojo-pool[i] raised` and leave the pool serving with one
thread fewer — an existing gap under `m0serve`, and a contradiction of
D30 the day the host took a lane. The brief's second option is built:
`_pool_serve` sets `BLK_READY` the instant `T.make` returns, and
`MojoPool.wait_ready` polls it, counting a thread that has already ended
`STATUS_RAISED` at once rather than waiting for it. The host calls it
before it serves and exits 78 if any thread is short. `PoolLane.make`
prints the error under `host:` with the thread named before re-raising,
so the line the smoke greps carries the application's own message.
Measured with `M0_HOSTCHECK_POOL_MAKE_RAISES=1`: exit 78 at one worker
and at two, where the supervisor ends worker 1 for it (D30's third
rule); before the wait, the same knob served, two threads short.

**What a stream does under a pool.** `_pool_serve` refuses a streaming
response from a pool thread with 409, because the pool thread's own
registries are ones nothing drains. That refusal stands, per request and
named in the log, and `apps/host_check`'s gate pins it on `/events`
rather than moving the route: the refusal is what an application meets.
A stream open belongs on the loop, and there are two ways to put it
there. A handler of its own answers it in `before_request`, as
`host_check` now answers `/health`. A `Views` table flags the route.

### Placement is a property of the route (N19, D32)

`add_read` and `add_write` take `on_loop=True`. The route stays in the
main router — one `Allow`, one `url_for`, one 404 — and is registered in
the loop router too, with which table and slot its view lives in
(`LOOP_READ`, `LOOP_WRITE`; `add_loop`'s entries are `LOOP_STATELESS`).
`answer_on_loop(req, state)`, the new overload, answers all three on the
loop; `ViewsApp.before_request` and `ViewService.before_request` call it
with their own state. A view that raises there is answered 500 and named,
because the hook cannot raise. The stateless `answer_on_loop(req)` — a
handler with no state at hand — declines an `on_loop` route, and
`dispatch` answers it one round trip later, bytes identical.

The brief's first open question, a flag or a second table: the flag.
`Views` had two routers already (the loop's is a scan of one or two
routes, so `before_request` does not route the whole table twice); a
third would be a third `Allow` to merge and a second `url_for`.

**The `add_loop` divergence on `m0serve` is recorded, not built** (D32,
the brief's option ii). `WSGIHandler` is the loop handler there and
holds no Mojo table, so a mounted table's loop routes are answered on a
pool thread by `dispatch` — one round trip later, with that thread's
state. The divergence is latency under a full lane, not a stall: the
lane's other threads answer, and R5b measures it on both hosts. Option
(i), a `thin` pointer plus an address from one extra `MojoMount` built
on the loop thread, is the retiring condition, to be built on that
measurement rather than argued.

### The shutdown bounds overlap

Round 4 recorded a ROADMAP issue: the drain's 5 s and then the producer
join's 5 s, in sequence. Building the lane would have added a third. The
brief asked for the producer to be signalled when the drain begins; the
mechanism is `run_event_loop`'s `stop_addr`, the address of a word the
loop stores `perf_counter_ns()` into as the first act of
`_shutdown_begin`. The host passes the producer's stop word
(`ProducerThread.stop_addr`, valid before `start` and for a producer
never started, since the block is the thread set's), so the producer is
stopping DURING the drain, and `stop_and_join` reads the stamp back and
waits only for what is left of the bound. The pool is pilled after the
loop returns — a pill read beside a job still on the ring strands the
job, which is why `m0serve` pills there too — and joined within the same
remainder, floored at `POOL_JOIN_FLOOR_NS` (500 ms) so an idle thread
taking its pill under a loaded runner is not counted a straggler.

One correction to the issue as recorded. It said a HELD STREAM beside an
overrunning step reaches 10 s. It does not: `_shutdown_begin` sends every
held stream its farewell and closes it before the drain waits on
anything. What stretches the drain is a request in flight, and the gate
holds one:

| shape | leaves in |
|---|---|
| a 4 s `/slow` in flight on a pool thread at SIGTERM, beside a 60 s step, stop word unstamped (the round-4 order) | 8.54 s |
| the same, stamped as the drain begins | 5.05 s |

Both answered the request whole. Without a pool the shape cannot
overlap by construction — the loop reads the shutdown pipe only after
the handler returns — which is another reason a blocking view belongs on
a lane.

### The gates

`smoke-host` (every PR) gains four phases, all on `apps/host_check`,
which gained `/slow?ms=N` (a spin in `func`), `/health` answered in
`before_request`, and the pool knob:

- **placement** — `M0_BLOCKING_THREADS=4`, two connections looping a
  200 ms spin, the worst of 24 `/health` samples under 100 ms (0 ms on an
  M4); `/events` answered 409 with the refusal in the log; a clean exit
  with no thread reported a straggler;
- **the negative arm** — `M0_BLOCKING_THREADS=0` under the same load
  must reach 100 ms (382 ms measured), or the placement arm proves
  nothing;
- **overlap** — the table above, asserted as an exit inside 6 s with the
  request answered whole and the producer named;
- **a raising pool `make`** — exit 78 at one worker and two, the knob
  named on the `host:` line, no crash line, no worker left.

The refusal phase drops `M0_BLOCKING_THREADS=2` from its list. Recorded:
`host.pool_health_ms` and `host.overlap_exit_s`. The unit halves:
`test_host.mojo` (the lane builds the handler for its thread; a raising
lane `make` is counted; a stop stamped 900 ms ago leaves 100 ms of a 1 s
bound, against the unstamped control that waits the whole bound),
`test_mojo_pool.mojo` (`wait_ready` on a sound pool and a refusing one),
`test_views.mojo` (the flag, the stateless decline, the 500,
`ViewService`).

`sabotage-host` grows by six rules to thirty-seven, and two moved. "The
producer is never told to stop" now edits TWO files — the loop's stamp
and the join's fallback — because removing either alone leaves the other
telling it; the harness takes a tuple of paths for that. The six: the
variable served on the loop, the stop word withheld from the loop, the
producer's join counted from the loop's return, a raising pool `make`
served short, a pool thread's handler built as the loop's own, and an
on-loop read answered without its state (against `test_views.mojo`, a
unit gate, since `views.mojo` is `src/`).

### Found on the way

`listener.socket.fd` as a call argument is a value, and the expression
that reads it was the listener's last use: Mojo destroyed it there, its
destructor closed the socket, and the loop's first `fcntl` on the fd
failed with EBADF before a connection was taken — with and without a
pool. `Server.serve_nonblocking` never had the problem because the
listener was its argument. `_run_loop` in `host.mojo` takes it as a read
parameter for the same reason, and says so.

## R5b — the ramp

*Not yet built; this section is filled in by the round that builds it.*
