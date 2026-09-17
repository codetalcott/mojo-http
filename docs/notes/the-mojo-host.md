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
precedent. The cost is six more fork-to-framework imports (`config`,
`multiworker`, `signal`, `threads`, `views` since round 2 and `prefork`
since round 3), all inside `packages/m0-http/`.
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
- **`poe sabotage-host`** (pre-release) breaks nineteen rules (sixteen in round 1). A
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

## Round 2: the other four

The plan's port list was `sim_loop`, `datastar_counter`, `datastar_todo`
and `fragment_notes`, with each smoke kept green without touching its
assertions.

| app | `main` before | after | what it gained |
|---|---:|---:|---|
| `sim_loop` | 105 | 19 | nothing new; its four hand-kept rules became the host's |
| `datastar_counter` | 56 | 7 | shared accepts; the bus joined at any worker count |
| `datastar_todo` | 18 | 7 | two workers over one database (N17) |
| `fragment_notes` | 15 | 10 | `M0_WORKERS=2` refused instead of ignored (N18) |

`sim_loop` needed one thing from the host: a server config it could
adjust, because its on-loop arm sets `app_tick_ms`. `serve` takes one as an
optional second argument. The on-loop arm's `Producer.wanted` answers
False, so no thread starts. The docstring's four numbered rules are the
host's now, and the note says which of them the app once broke.

`datastar_counter`'s page moved from three words on a hand-made page to two
words on its own page (`page_slots`); the event id is the host's. It joins
the bus unconditionally. The old guard (`workers > 1`) was right for that
app and wrong for any app with a producer, and a comment was all that
warned against copying it. At one worker the stream has no peer, and
publishing reaches nobody.

**`datastar_todo` was the one that needed thought.** Its `sse_peer_frame`
existed but never ran. Joining the bus made it live, and serving two
workers over one SQLite file turned out to be two lines — plus one race.
A mutation renders the whole list and then numbers the frame, and a tab
keeps the frame with the newest number. Consider two workers:

1. Worker A renders the list.
2. Worker B commits a change and renders a list that includes it.
3. B numbers its frame 5.
4. A numbers its frame 6.

Frame 6 lacks B's change, and every tab keeps frame 6 until the next
mutation. The fix is SQLite's write lock (`BEGIN IMMEDIATE`), held from
the change until the frame is published. The next writer waits on it, so
renders are serialized across processes in the same order as their ids.
The gate reads the broadcast log straight from the database file, and
under an add-only load every frame must hold every todo its predecessor
held.

The race is real and very short. Without the lock, fifty concurrent adds
passed that check 10 of 10 rounds. With a 5 ms pause between rendering and
numbering (`M0_TODO_RENDER_PAUSE_MS`, the app's gate knob, like
`M0_SIM_ON_LOOP`), the unlocked build failed 5 of 5 rounds and the locked
one passed 5 of 5. So the gate runs with the pause. A gate that could not
tell the two builds apart would be evidence of nothing.

`fragment_notes` keeps its notes in a struct, so a second worker would
serve a second, different list. It had silently ignored `M0_WORKERS`. The
host gained two small things for it:
- `AppHandler.max_workers()`, where the app says it serves from one
  process and the host refuses a larger count with 78 before binding;
- `ViewsApp[S]`, the host's `ViewService`, so a `Views` table and its state
  (`ViewState`: `make`, `urls`) are served with no handler struct.

The table function was renamed `note_urls` so the state's static `urls`
does not shadow it. `ViewsApp` is also the piece Phase 3 needs: one views
module, served under a mount and under the host.

None of these needed an escape hatch in the host. The two additions are
declarations (`max_workers`) and a convenience (`ViewsApp`), and neither
lets an app reach around `serve`.

## Round 3: one preparation for both hosts

The plan's last round moves m0serve's Python-free startup pieces down to
where both hosts call them. `m0_http.prefork` now holds:

- `prefork_page(workers, required)`: the shared page, file-backed where
  the host allows it, the magic word stored in slot 2, `M0_SHARED_ID_FD`
  and `M0_SHARED_ID_ADDR` exported; `required` is m0serve's
  `--spawn-workers`, where an anonymous page is no page at all;
- `prefork_bus(channels)` and `prefork_accept_share(workers)`: created,
  kept across exec and exported, or adopted;
- `bind_accept_share`, `shared_id_addr`, `spawned_worker_index` and
  `int_list_env`, moved from `m0serve.mojo`.

The signatures narrowed on the way down. Each piece used to read
`ServeOptions`; what either host decides is a worker count and whether
the page must be file-backed, and that is all the functions take.
m0serve's `_prepare_realtime` is three calls over them, keeping only what
is its own: `channels` (workers or loop threads), `required`, and
`M0_CORE_LIB` for `m0pub`. Its flags and the `M0_*` names `m0pub` and an
exec'd worker read are unchanged, so the served contract is unchanged and
textshelf needs no follow-up.

Two things changed in behaviour, both on purpose:

- **The Mojo host's page is file-backed and exported**, as m0serve's has
  been since #322. In round 1 it was an anonymous mapping, enough for
  forked workers and nothing else. A child process a host application
  starts can now number its frames from the page it inherited, the way
  `m0pub` does.
- **A spawned worker with no page descriptor is refused.** m0serve's old
  path skipped the adoption silently when `M0_SHARED_ID_FD` was missing
  and went on to bind accept sharing to the address its parent exported,
  which in a fresh image is nothing. `prefork_page` raises there, and
  `host_refusal` refuses an inherited `M0_WORKER_SPAWNED` outright, since
  the Mojo host never sets it and would adopt from descriptors it was
  never handed.

Exec'd workers for the Mojo host are now a small step, adopting
`M0_LISTEN_FD` and calling `enable_spawn`, and are still refused (D29):
no application under `apps/` needs one, and a mode nothing exercises is
a mode nothing gates.

`test_prefork.mojo` runs the adopt path in one process, which is enough:
a spawned worker is a fresh image that maps the same descriptor again,
and a second mapping in the same process is exactly that. SPEC E24 is
the row; the exec itself stays E15's. `sabotage-host` grew six rules
against that file, twenty-five in all.

## Round 4: the host's contract

A review of the host end to end, after round 3, found two defects that
all twenty-five sabotages had survived. Both are the host's own contract
rather than an application's, and both were measured on 2026-09-17 before
being fixed.

**The host hid the bus descriptors but not the id space.**
`Publisher.publish` took an id the application chose, and every producer
chose one from a counter of its own: `host_check`'s `Beat.n`, blobs'
`step_no`, `sim_loop`'s `step_no` in its producer arm, while its on-loop
arm numbered from the shared word, so one application disagreed with
itself. The handlers' publishes were already right: `DatastarStream`
takes the shared word under `enable_bus`. What it costs is the loop's
redelivery filter, which delivers a frame only if its id is above the
slot's last-seen id. When the supervisor respawns worker 0, a producer
numbering from its own counter restarts at 1, and every stream held on a
sibling is silent until the new counter passes the old one:

| observation | value |
|---|---|
| beats on worker 1's held stream before the kill | 41 over 4 s |
| silence on that stream after the respawn | 4.21 s, the pre-kill uptime |
| a stream opened fresh on worker 1 after the respawn | beats at once |
| the same held stream, fixed | a beat 12 ms after the kill |

For blobs at 10 Hz after an hour of uptime, that is an hour of dark tabs
with a clean log. The fix is `Publisher.next_id()`, `fetch_add` on
`HostContext.id_addr`, and the three producers take their ids from it.
The id is handed out rather than stamped inside `publish`, which would be
the stronger shape: it sits inside the frame body, and the framing is the
application's (`format_sse_event` puts `id:` first, Datastar `event:`
first), so the publisher cannot write it. Nor can `publish` check it: an
id at or below the word's current value is true of every correctly
numbered frame too, a handler having taken the next one meanwhile.
D27's publish shape now names the id space. Blobs' `/stats` keeps
`steps` as its own count and `last_id` as the id it last published.

**A raising `make` crash-looped instead of refusing.** With a probe
handler whose `make` raised, `M0_WORKERS=2` logged five rapid crashes
and exited 1, printing Mojo's unhandled-exception trace five times; one
worker printed the listening banner and then the trace. `serve` now
catches a raising `H.make`, prints it under `host:` and exits 78, which
`WorkerSupervisor` reads as a configuration it must not respawn.

The producer's `make` gets the same, and one judgement call came with
it. D27's first form built the producer on its own thread, which starts
just before the serve, so a refusal from there was "before it serves" in
practice and not by construction. It is now built on the spawning
thread, inside `ProducerThread.start`, and moved into memory the thread
takes as its first act; a raise propagates out of `start` with no thread
spawned, and `serve` exits 78 before the server listens. The thread owns
the producer from its first step to the last and destroys it, as before.
`test_host.mojo` tells the two apart: a raising step ends the thread with
`STATUS_RAISED`, a raising `make` leaves it at `STATUS_NEVER_RAN`.

A third thing followed from the second. Only worker 0 builds a producer,
so under `M0_WORKERS=2` its refusal left worker 1 serving: the
supervisor's rule was to let the others finish and exit 78 once they
had, which for m0serve, where every worker refuses the same thing, was
the same as ending them. For the host it was a server with no worker 0
and no producer, indefinitely. The supervisor now forwards SIGTERM to the
siblings on an `EX_CONFIG` exit and exits 78 once they are gone;
`test_respawn.mojo` pins it and D30 records the three together.

**What the refusal uncovered, on its first CI run.** `smoke-todo`'s
two-worker phase went red on the macOS runner: `datastar_todo`'s `make`
raised `database is locked` in one worker, and the host refused it with
78. Before this round that worker crashed on the unhandled exception and
the supervisor respawned it, and the second attempt won the race, so the
gate was green while every two-worker start was losing a coin toss.
Reproduced on an M4 at 29 of 30 starts. The locked step was not the
schema creation but `open()` itself: two processes switching one fresh
file out of the rollback journal race on `PRAGMA journal_mode=WAL`, and
SQLite answers the loser's at once without consulting the busy handler
set the line before. m0-sqlite's `open` now retries the switch on
`SQLITE_BUSY` within the same budget (O1, `test_two_processes_open_one_
fresh_database`, which fails on the old `open` in round 0), and the todo
app takes its schema lock with `BEGIN IMMEDIATE` for the second race the
busy handler cannot help. Gating an ungated row keeps finding real
defects; this one was found by a refusal replacing a crash.

**Gates.** `smoke-host` gained two phases (SPEC E25). The respawn phase
holds four streams spanning both workers for 4 s, SIGKILLs the pid the
beats name, and requires the streams still held on worker 1 to beat
again within 2 s, from the respawned producer, with an id above their
last; the hold is longer than the bound on purpose, since the broken
host's silence is the hold plus the respawn. A fresh stream beating is
not the assertion, because that passes on the broken host. The refusal
phase runs `M0_HOSTCHECK_MAKE_RAISES=1` and
`M0_HOSTCHECK_PRODUCER_RAISES=1` at one worker and two, each of which
must exit 78 naming the knob with no respawn or crash line and no worker
left. Six sabotages join the list, thirty-one in all: the id word made
after the fork, `next_id` not advancing it, the handler's raise left to
propagate, the producer's exiting 1, `start` swallowing it, and the
siblings left serving; the last runs against `test_respawn.mojo`, a
gate of its own.

**Recorded, not fixed.** The drain and the producer join run in
sequence, 5 s of `DRAIN_TIMEOUT_NS` and then 5 s of `JOIN_TIMEOUT_NS`,
so a held stream beside an overrunning step can reach `docker stop`'s
10 s default grace. The smoke measures 5 s today only because nothing is
held during the overrun arm. It is a ROADMAP known issue, retired by
signalling the producer to stop when the drain begins so the two bounds
overlap.

## Next

The host has nothing left to take from m0serve that both can use. What
it does not offer, pool lanes, loops on threads and exec'd workers, is
D29's list of retiring conditions, each waiting on an application that
needs it.
