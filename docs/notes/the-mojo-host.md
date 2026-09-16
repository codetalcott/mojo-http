# The Mojo host — built 2026-09-16

> A design note from the engineering record. What a Mojo application's
> `main` used to be, what `lightbug_http.host` took out of it, the choices
> it makes for every application, and what it does not do yet.

**The problem.** m0serve is a host: it owns the listener, the workers, the
bus, accept sharing, signals and the drain, and a Python application
brings only itself. A Mojo application had no host. Each one wrote its
own `main` from the comments in CLAUDE.md's runtime constraints, and the
reference applications got those rules wrong. `apps/datastar_counter`
joined the bus only above one worker. `apps/sim_loop` published to worker
0's channel alone under a comment saying otherwise. No application shared
its accepts, so under `M0_WORKERS=2` one worker took nearly every
connection. Those rules are the repository's hardest-won, and they were
being re-derived by hand in every `main`: 105 lines in `sim_loop`, 77 in
`apps/blobs`.

**The host.** `serve[H, P](config)` is everything in that `main` that is
not the application:

```mojo
def main() raises:
    var cadence = Cadence()          # the app's own configuration check
    if not cadence.valid():
        ...
    serve[BlobsHandler, BlobsProducer](AppConfig())
```

`H` conforms to `AppHandler`: an `HTTPService` plus a static `make(ctx)`,
and optionally `page_slots(workers)` for a pre-fork page of the
application's own. `P` conforms to `Producer`: `make(ctx)` and
`step(mut self, mut out: Publisher) -> Int`. `NoProducer` is the default.
Construction is a type parameter with a static `make`, not a function
value, for the reason `PoolHandler` gives: Mojo 1.0 cannot turn a
function-parameterised `def` into the address a pthread needs.

`serve` does these steps in this order, and the order is the point:

1. It refuses `M0_THREADS`, `M0_BLOCKING_THREADS`, `M0_SPAWN_WORKERS` and
   `M0_WORKERS=0` with exit 78, before anything is bound.
2. It listens once, in the process that will fork.
3. It creates the host's shared page (m0serve's layout: slot 0 the event
   id, slot 2 the magic word, then each worker's accept-share line) and,
   if the application asked for one, a separate application page.
4. It creates the bus unconditionally, at one worker too.
5. It creates the accept-share channels above one worker, unless
   `M0_ACCEPT_SHARE=0` asks for the bare race.
6. It forks when `M0_WORKERS > 1`.
7. It binds this worker's accept share.
8. It arms the signals, after the fork.
9. It builds this worker's handler with `H.make`.
10. On worker 0 alone, it starts the producer.
11. It serves, with this worker's bus channel drained.
12. It stops the producer and joins it within 5 s. A producer still
    inside a step at that point is left behind by name, and the process
    leaves with `_exit`.
13. A forked worker ends with `exit_worker()`.

Two things make the wrong wiring impossible to write rather than merely
documented. The application never sees a bus descriptor: `Publisher`
holds all of them and sends to all of them with `skip_worker = -1`, so a
producer cannot publish to a subset. And nothing in the application
decides whether it has forked.

## The three choices a helper would have had to make

DECISIONS D26 declined a worker-thread helper because it "would have to
choose the cadence policy, the shutdown bound and the publish shape on
the application's behalf, and one application is not evidence of which
choices are right". By 2026-09-16 there were two applications, and they
disagreed on cadence, so the choices are made here once and recorded as
D27:

- **Cadence.** `step` returns the time from this step's scheduled start
  to the next one. The schedule is fixed-rate and never catches up: after
  a step overruns, the next one is scheduled from now, rather than the
  missed steps running back to back. `sim_loop`'s fixed 4 Hz is
  `return period`. `blobs`' pause with nobody watching is
  `return PAUSE_POLL_NS` without publishing, and its 2 Hz idle rate is a
  different return value. The sleep between steps is sliced at 50 ms, so
  a producer with a 60 s period stops at once. Returning the period from
  `step` beat a separate `period_ns()` method: blobs decides its next
  period in the middle of its step, from the same clock read.
- **Shutdown bound.** The drain's own 5 s, `JOIN_TIMEOUT_NS` from
  `mojo_pool.mojo`. After that the host prints `host: abandoned a
  producer step still running 5 s after the drain; exiting without it`
  and calls `_exit(0)`. `pthread_join` has no timeout, so waiting longer
  only turns SIGTERM into a no-op until `docker stop` sends SIGKILL.
  `ThreadSet.join_within` waits on the body's status slot, which the
  host's producer body writes as its last act.
- **Publish shape.** Every worker's channel, `skip_worker = -1`, with each
  refusal counted on the publisher and reported to the step as `False`.
  Blobs counts refusals in `/stats` as before. A step that raises ends the
  producer and is named in the log, while the server keeps serving what it
  has. A producer that restarted itself after a raise would repeat the
  failure at its cadence.

The producer is built on its own thread, from a copy of the context in
memory the host never frees, because an abandoned producer outlives
`main`'s locals. `ProducerThread` is a struct separate from `serve`, so
`test_host.mojo` can drive it with a real bus and no server.

## Where it lives: the fork (D28)

The owner decided this before building, on the handoff's recommendation.
On the pinned toolchain, an application's conformance to a trait in a
precompiled package gets no witness table. The cause is that every
package here builds a directory named `src` into `<name>.mojoc`, so
traits are recorded under the directory's name and looked up under the
package's (`poe check-mojoc-trait`; fixed on the nightly). A
source-resolved module has no such mismatch, and `mojo_pool.mojo` is the
precedent. The cost is four more fork-to-framework imports (`config`,
`multiworker`, `signal`, `threads`), all inside `packages/m0-http/`.
CLAUDE.md's cycle paragraph lists them, and `poe check-fork-package`
still compiles the fork whole. The second decision, the toolchain pin,
stays at 1.0.0: no stable release carries the fix, and pinning a product
to a nightly is a separate decision.

## What v1 does not do (D29)

The host has no pool lanes, no loops on threads, no exec'd workers, no CLI
flags and no `--doctor`. Its whole configuration is `AppConfig`'s
environment. The three variables that name m0serve's other modes are
refused rather than ignored. An ignored variable is a configuration that
reads as applied, which is the class of defect this repository keeps
finding when it gates an ungated row. A host that offers pool lanes and a
bus will have to call `run_event_loop` directly for `peer_bus_fd`, as
m0serve does. No application under `apps/` needs that yet.

The handler is built after the fork and the pages before it. Neither
order is a one-line edit in `serve`, so neither is sabotaged on its own.
The two-worker phases are what would fail: one handler cannot hold
streams in two processes, and a bus created after the fork reaches no
sibling.

## Blobs on two workers

`apps/blobs` served from one process until the host existed, with
`M0_WORKERS` above 1 refused. Its board was already laid out per worker,
so the port was a sizing change (`page_slots(workers)` is
`board_slots(workers)`) plus a producer that sums every worker's viewer
word. The board lost its three configuration words: the producer now
reads its cadence from the environment itself. `main` went from 77 lines
to 15, and the file from 480 to 428.

`smoke-blobs`' refusal phase became a two-worker phase
(`blobs_probe.py two`):

- **Spread.** Streams are opened until they sit on both workers, which
  each names in `x-worker`. A run that cannot spread them fails as
  vacuous.
- **Every step.** Every stream carries every step, contiguously, at the
  same step as its siblings.
- **A crossing click.** A keep-alive connection that `/stats` says is
  held by worker 1 posts a drop, and both workers' streams must draw it.
  This is the first test of the drop box's multi-writer design across a
  process boundary; it had been tested by construction only.
- **The viewer sum.** With worker 0's streams closed and worker 1's held,
  `/stats` must count worker 1's viewers and the producer must keep
  stepping. Then it must pause once they close.

Two of `sabotage-blobs`' rules are new. One counts worker 0's viewers
alone. The other gives worker 1 a board of its own, so its click never
crosses. The rules that moved into the host left the blobs list: the
skipped channel, the stop that is never sent, and the refusal itself.

## The gates

- **`poe smoke-host`** (every PR, SPEC E21–E23) runs on `apps/host_check`,
  a handler and a producer and nothing else. Each server gets its own
  port. It checks:
  - a stream at one worker beats, so the bus is drained there;
  - four streams spanning two workers each carry every beat, with no id
    repeated (one producer) or skipped (every channel);
  - a SIGTERM to the supervisor alone ends four held streams, both workers
    report a clean exit, and none outlives the supervisor;
  - accept sharing, through `accept_spread.py --app-bin`, lands bursts
    within 2:1 with hand-offs; on macOS the knob-off arm must skew;
  - a 60 s step leaves 5 s after SIGTERM with the producer named, in one
    process and in a forked worker;
  - a 60 s period leaves at once;
  - each refused variable exits 78, names itself and never prints the
    listening banner.
- **`test_host.mojo`** (every PR) holds the thread rules without a server:
  every channel in order, no catch-up, a prompt stop, the bounded join, a
  raising step's status, the refusals, and a counted refusal on the
  publisher.
- **`poe sabotage-host`** (pre-release) breaks sixteen rules. A
  sabotage that does not compile is reported as BROKEN and counted as a
  miss. Its first run missed two rules, and both misses taught something:
  - **A producer in every worker was invisible.** Each stream still saw
    every beat id once, because the loop's redelivery filter keeps the
    newer of two racing ids: two producers in lockstep look like one. Each
    beat now carries its producer's pid, and one run must see exactly one.
  - **Catching up after an overrun was indistinguishable from not.** When
    every step costs more than its period, both schedules run the steps
    back to back. The test now overruns once and then steps freely, and
    catching up doubles the steps in the next window.

  A seventeenth rule was dropped rather than guarded: removing the `_exit`
  after an abandoned producer. A forked worker leaves through
  `exit_worker` anyway, and a single process returning from `main` with
  the producer asleep in its step exited 0 in the same time. The `_exit`
  stays, so teardown never runs under a thread that is mid-step, but
  nothing on the wire can tell, so it is not claimed.

  Two harness bugs turned up as well. The first draft moved the signal
  install by *adding* a pre-fork one, which the post-fork install then
  repaired; the duplicate declaration would also have been "caught" by the
  compiler. And `mojo run` prints `error: execution exited with a non-zero
  result` for a failing test, which a loose compile-error check read as a
  broken sabotage. A compiler diagnostic names a file, line and column;
  only that is counted as a compile error now.

What the smoke measured on an M4 running macOS 26 (one run each):

| arm | result |
|---|---|
| accept sharing | bursts of 32 split [16, 16] twice; 45 hand-offs |
| `M0_ACCEPT_SHARE=0` | a burst of 32 split [27, 5] |
| overrun | exit 0, 5 s after SIGTERM, one worker and two |
| long period, drain | exit 0 within a second |

## Found on the way: a supervisor that outlived its SIGTERM

One sabotage made a forked host worker return from `main` instead of
calling `exit_worker()`. The runtime's teardown is unusable after a fork, so
the worker crashed on its way out. The smoke caught it, and then left the
process behind: a supervisor still running eight minutes later, with two
fresh workers holding the port the next rule's server tried to bind. The
next rules were served by that stale, sabotaged binary, which is why the
first run's later results were re-run.

The cause is in `WorkerSupervisor`, not the host. A SIGTERM sent to the
supervisor alone is forwarded to each worker, and supervision then waits
for them. A worker that exits 0 is retired, and one killed by the forwarded
signal ends supervision. But one that crashes is respawned, exactly as a
crash in service would be. Nothing ever signals the replacement, so the
supervisor serves it until something sends SIGKILL. For `docker stop` that
is the whole grace period, then a kill. A worker whose drain fails in any
way (a teardown crash, a non-zero exit) hits this, under `m0serve` as much
as under the host.

The handler now records the stop, one word in the data segment beside the
child PIDs it already reads, before it forwards the signal. `_try_respawn`
refuses while the word is set, and the supervisor exits 1 once the rest are
gone. `test_respawn.mojo` pins it (SPEC D10) and fails with the guard
reverted. The smokes now reap whatever runs from their own temporary
directory on exit, so a supervisor that does outlive its signal cannot
serve the next run.

## Next

R2 ports `sim_loop`, `datastar_counter`, `datastar_todo` and
`fragment_notes`. The two single-process apps gain workers, accept
sharing and a bus at no extra length. `datastar_todo`'s `sse_peer_frame`
becomes live once the bus is always joined. R3 moves m0serve's
Python-free startup pieces (the accept-share preparation, the shared page,
the bus half of `--realtime`) down to where both hosts call them.
