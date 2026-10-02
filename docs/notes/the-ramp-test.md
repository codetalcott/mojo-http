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

- **placement** — `M0_BLOCKING_THREADS=2`, two connections looping a
  200 ms spin holding both threads, the worst of 24 `/health` samples
  under 100 ms (0 ms on an M4); two streams opened on the loop carrying
  every beat under the pool, and four spanning two pooled workers;
  `/events-from-func` answered 409 with the refusal in the log; a clean
  exit with no thread reported a straggler;
- **the negative arm** — `M0_BLOCKING_THREADS=0` under the same load
  must reach 100 ms (389 ms measured), or the placement arm proves
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

`sabotage-host` grows by seven rules to thirty-eight, and three moved. "The
producer is never told to stop" now edits TWO files — the loop's stamp
and the join's fallback — because removing either alone leaves the other
telling it; the harness takes a tuple of paths for that. The seven: the
variable served on the loop, the stop word withheld from the loop, the
producer's join counted from the loop's return, a raising pool `make`
served short, a pool thread's handler built as the loop's own, the gate
app's `/health` moved onto the pool, and an on-loop read answered without
its state (against `test_views.mojo`, a unit gate, since `views.mojo` is
`src/`).

### Found on the way

`listener.socket.fd` as a call argument is a value, and the expression
that reads it was the listener's last use: Mojo destroyed it there, its
destructor closed the socket, and the loop's first `fcntl` on the fd
failed with EBADF before a connection was taken — with and without a
pool. `Server.serve_nonblocking` never had the problem because the
listener was its argument. `_run_loop` in `host.mojo` takes it as a read
parameter for the same reason, and says so.

### Found by review

The round's review, from a fresh context as the process asks, read the
commit before the ramp was written and found one defect and two gates
that could not tell. The defect: `pool`'s last use in `serve` was the
join, so Mojo destroyed the `OffloadPool` there — while a straggler thread
the join had given up on still held its address and would write its
completion into freed memory when its view returned, in the microseconds
before `_exit`. `m0serve` pins its own pool with `_ = pool.capacity` at
the end of `_serve_offloaded` for exactly this; the host now does the
same, and the harness records why no sabotage can guard it (no symptom on
the wire). The gates: the placement phase held two threads of four, so an
idle thread would have answered a `/health` that became a job within a
millisecond and the phase could not tell "on the loop" from "on a spare
thread" — it now holds every thread (a pool of two, both busy; two rather
than four so a shared runner's cores keep something for the loop), and a
sabotage moves the gate app's `/health` into `func` and insists the phase
fails; and E23's prose still said the producer was told to stop after the
drain. Two more things the review asked for: a stream opened on the LOOP
under a pool is now gated (`host_check`'s `/events` moved into
`before_request`, the refused shape kept as `/events-from-func`, and a
two-worker pooled phase holds streams spanning both), and the ready wait
says which of two things it refused — a raise, or a build still running
at a ten-minute bound.

## R5b — the ramp

### The module

`apps/ramp/views.mojo` is one `Views[Ramp]` table, four views and a
state type, and nothing that knows which host it is on. Under `Mount`:
`/` (the index, two links through `st.at.url_for`, `on_loop=True`),
`/now` (`add_loop`, the timed route), `/search?sel=&k=` (the demo mount's
filtered scan, a writing view over the instance's own score buffer) and
`/slow?ms=` (a spin). Two adapters, each a page long:

- `apps/ramp/mount/m0serve_mount.mojo` is the `MojoMount` `m0serve`
  builds in with `M0SERVE_MOUNT_DIR=apps/ramp/mount`, taking its prefix
  from the lane (`PoolContext.prefix`); `build-serve` gained
  `M0SERVE_INCLUDE`, the application's own module root, placed AFTER the
  mount directory so it can never be a second mount root (N14's rule).
- `apps/ramp/server.mojo` is `serve[ViewsApp[Ramp]](AppConfig())`; the
  `ViewState` conformance sits on the state itself, and the host, having
  no mount table, takes the prefix from the module's `RAMP_PREFIX`. The
  smoke passes that same value to `--mount`, and a disagreement is a
  dead link the gate follows.

The module keeps two rules the brief set. Nothing in a body names where
it ran — the demo mount's `"thread":N` would be a lane index on one host
and -1 on the other — and the spin count is not in `/slow`'s body either.
And the state is built from the prefix alone (`Ramp.generate(at)`), so
both adapters call one function.

### What the wire said

`scripts/ramp_probe.py bytes` issues nine requests under the prefix to
both ports — the index, `now`, the scan with and without parameters,
`slow`, a 404 inside the prefix, a 405 with `Allow`, an `OPTIONS` 204
and a 405 on the writing route — and diffs status, headers and body
per request. Every one was byte-identical apart from `Date` on the first
run, as the brief predicted from the code: `x-worker` is set on holds
alone, `x-thread` under `--threads` alone, and both hosts write the rest
through the same `_finish_response`. It then follows the index's two
links on each host and requires the same link without its prefix to be
404 on both. Outside the prefix the two hosts differ by design and are
asserted per host: `/` is the Python application on `m0serve` and the
table's problem+json 404 on the host, and `/xapp/now` reaches neither
mount.

Placement, `scripts/ramp_probe.py placement`, is `host_probe.py`'s
arithmetic under the prefix: K connections looping `/x/slow?ms=200`, 24
samples of `/x/now` at random gaps, the worst reported — and, since
2026-10-01, the second-worst beside it, which is what the gate reads
([below](#the-gate-reads-the-second-worst-sample-2026-10-01)). The table
is the worst sample.

| arm | m0serve (lane of 2) | host (lane of 2) | host, bare loop |
|---|---|---|---|
| one connection on `/x/slow` | 1 ms | 0 ms | 385 ms |
| two connections — the lane full | 196 ms | 0 ms | — |

(The first cut used lanes of four with two and four loaders: 1 ms and
1 ms, then 154 ms against 5 ms — the same shape. Two threads leave a
shared runner's cores something for the loop.) The first row is the
gate's bound on both hosts (100 ms, `sim_loop`'s, on the second-worst
sample), and the bare loop is the negative arm that must fail it. The
second row
is the measurement D32 asked for. With every thread busy, `m0serve`'s
loop route waits for a pool thread — its loop handler holds no Mojo
table — while the host's, an `add_loop` route, is answered by the loop:
a fixed cost of about one spin on `m0serve`, no stall. The gate bounds
the host there and RECORDS `m0serve` (`ramp.full_lane_now_ms.m0serve`),
so the number that would justify building option (i) accumulates on
every run instead of being argued once.

### The gate reads the second-worst sample (2026-10-01)

The bound was on the WORST of the 24 samples, and on a macOS runner that
is a bound on the runner. `Tests` run 36898942895 failed in the host's
full-lane arm, `/x/now waited 120 ms with every lane thread busy`, on a
change that did not touch it; the rerun passed, and the two arms before
it in the same job measured 2 ms and 4 ms. What 40 green `Tests` runs
had recorded up to that day (`ci-results-<os>-gateway`):

| metric (the worst of 24) | macOS: median, p90, max | Ubuntu: max |
|---|---|---|
| `ramp.full_lane_now_ms.host`, the arm that failed | 2, 7, 8 ms | 1 ms |
| `ramp.worst_now_ms.host` | 1, 5, **79** ms | 0 ms |
| `ramp.worst_now_ms.m0serve` | 3, 12, 42 ms | 1 ms |
| `ramp.full_lane_now_ms.m0serve` (D32, recorded, not gated) | 190, 200, 201 ms | 200 ms |

So a macOS runner stalls a single sample for 80 to 120 ms, twice in
about 2,000 gated samples, an Ubuntu runner never did, and a gate on the
worst of 24 has no margin for one. The regression the gate exists for is
different in kind. With `add_loop` broken, or the lane's other thread
not answering, a sample waits out what is left of a 200 ms view, so many
of the 24 are slow, not one: the last row above is that shape, on every
run.

The three bounded arms and the negative arm therefore read the
**second-worst** sample, `second_now_ms`, against the same 100 ms. One
stall no longer fails the gate; two in one arm still do. What the change
costs was measured rather than argued, on an M4, by registering `/x/now`
with `add_read` in place of `add_loop` and running the arm repeatedly:

| the regression | runs | worst | second-worst |
|---|---|---|---|
| the host's lane full, `/x/now` no longer on the loop | 13 | 146–198 ms | 132–194 ms |
| a lane of one holding the view, the same build | 8 | 146–199 ms | 130–195 ms |
| the bare loop (the negative arm, unsabotaged) | 2 | 378, 386 ms | 321, 307 ms |

Every run is over the bound by either statistic. The margin is thinner
than the worst's, and arithmetic says by how much: with the two loaders'
spins in step a sample waits 100 ms or more half the time, and with them
out of step a quarter of the time, which would leave the second-worst of
24 under the bound in about one run in a hundred. The gate runs on two
legs of every pull request.

The worst sample is still printed and still recorded, without a limit,
so a runner that stalls more often shows in the numbers first. And each
line now says where its worst sample spent its time:

```
full lane, host: worst_now_ms=7 second_now_ms=1 worst_connect_ms=0 worst_request_ms=7 slow_requests=40
```

`worst_connect_ms` is the connect, which on loopback the kernel
completes without the server's loop taking part; `worst_request_ms` is
the request written to the last byte of the answer read. The total also
holds the close, so a stall neither figure accounts for was the probe
itself not running. **Nothing yet says which side the 120 ms was on**:
the run that failed printed one number. The next one prints three, and
CI records the two parts for the host's full-lane arm
(`ramp.full_lane_worst_connect_ms.host`,
`ramp.full_lane_worst_request_ms.host`) beside the gated
`ramp.second_now_ms.*` and `ramp.full_lane_second_now_ms.host`.

The summary is a pure function of the sample list, and `ramp_probe.py
selftest`, the task's first step, holds it to the two cases that matter:
23 samples of 2 ms and one of 120 are under the bound, two of 120 are
over it, and fewer than two samples are refused.

**The host's own placement arms read it the same way since 2026-10-02.**
`host_probe.py placement` (`smoke-host`'s pool and bare-loop arms, and
`smoke-host-threads`' pooled loops) printed one number, the worst of 24
`/health` samples, and `smoke-host-threads` failed on it twice on macOS
on 2026-10-01 at 120 to 190 ms. It now prints the same line, built by the
one function in `probelib.py` (`placement_summary`), and its three arms
read `second_health_ms`. The rule the pool arm exists for still fails it:
with the gate app's health path answered on a pool thread
(`sabotage-host`'s rule of that name) the line was

```
worst_health_ms=143 second_health_ms=141 worst_connect_ms=0 worst_request_ms=143 slow_requests=40
```

and the unsabotaged bare loop measured 358 and 354 ms. Recorded:
`host.pool_second_health_ms` against the limit, `host.pool_health_ms`
beside it without one.

**What a search for the stall found.** A throwaway pull request (#533)
looped the gate's own sequence on three macOS runners, 171 gate runs per
build, against `main`, `main` with the pool's timed look patched out
and `main` without the streams phase first. No run
of any build would have failed; the worst sample was 80.4 ms, of which
78.9 ms was the connect. A first run of about 5,200 samples per build
had none at 100 ms, and three over 50 ms: one in the connect, and two in
the request under the eager wakes (`M0_POOL_ELASTIC=0`), where the timed
look does nothing. On Ubuntu the
worst of 240 gate runs was 0.8 ms. So the stall is not a steady property
of `main`, nothing measured ties it to the timed look, and why four
first-attempt failures fell on one day is not known; the runner image was
the same before, during and after. The split in each line is what will
say which side the next one is on.

### The gates

`smoke-ramp` (every PR, SPEC N20) builds both binaries from the one
module, starts `m0serve` with the mount beside `bareapp.wsgi` and the
host with a lane of two on ports of its own, runs the bytes phase, the
one-loader placement on each, the full-lane arm on each, then the bare
host as the negative arm, and records the placement numbers: the
second-worst sample of each bounded arm against the limit, and the worst
beside it. It reaps by its own temp directory as every host smoke does.

### Open questions, answered

1. A flag on `Views`, not a second table (N19).
2. The drain-then-join issue retired inside R5a, which added the third
   bound it would have stacked.
3. `add_loop` on `m0serve`: recorded now (D32), built on evidence; the
   evidence is now recorded on every run.
4. `apps/ramp` is a fresh module; the demo mount keeps its job and its
   thread index.
