# Loops on threads — 2026-09-18

The Mojo host served one loop per process and refused `M0_THREADS` with 78,
because that variable was `m0serve`'s and a host that ignored it would serve
a configuration other than the one written down. The reasons `m0serve`
defaults to prefork are Python's: a GIL, an interpreter that must be forked
before its first call, libpython on the link line. A Mojo application has
none of them. So the question for this round was whether a Mojo app's way to
N cores should be N forked workers or N loops on N threads of one process —
to be decided by a number, not by which reasons sounded better.

The answer: **they measure the same, so the default stays prefork and
`M0_THREADS` is served as an option** (DECISIONS D35). What follows is what
was built, the three design questions the round had to answer, the
measurement, and what is gated.

## What was built

`m0_host.serve[H, P]` under `M0_THREADS=N` runs `_serve_threaded`: the
prefork order with "fork" struck out. It is in `m0_host/host.mojo`, not in
the fork and not in `src/` — it calls `run_event_loop`, and nothing in
`src/` may reach the event loop (D33). It takes the SHAPE of
`m0-wsgi/src/threaded.mojo` and none of its body, which is interpreter
discipline from top to bottom.

`HostContext.worker` and `workers` count loops, and a new `threaded` field
says which kind of sibling they are. That is the whole change an application
sees: `apps/host_check` runs under both modes without a line that asks.

## Question 1: what is per thread, and what happens once

| step (prefork order) | under threads |
|---|---|
| refuse | once, before the bind; two new refusals below |
| listen | once; each loop gets a `dup` of the listener, so a loop closing its listener at shutdown is a per-thread close |
| shared page, app page | once, sized by the loop count. Still made by `prefork_page`, so still file-backed and exported: a child process an application starts publishes through `m0pub` the same way |
| the bus | once, one channel per LOOP. Fan-out across loops rides it exactly as fan-out across workers does. The host passes it as `bus_read_fd`, as under prefork — `m0serve` needs `peer_bus_fd` only because its chunk channel takes the first, and the host has no chunk channel |
| accept-share channels | once; each loop binds a COPY to its own index, `AcceptShare` carrying per-worker counters |
| fork | — |
| signals | once, BEFORE the threads exist (under prefork: after the fork). One process has one disposition |
| `H.make`, the pool lane, the loop, the pool's join | per thread (`_loop_run`) |
| the producer | one thread beside the loops, built after every handler, before any loop serves |
| `exit_worker()` | — |

**Accept.** The handoff called this "the biggest real win or the biggest
trap", and it was neither: accept sharing runs across threads unchanged. An
`SCM_RIGHTS` hand-off to a sibling thread is the kernel doing a `dup` into
the same descriptor table; the sender closes its number and the receiver
admits the new one. What had to be measured was whether it was needed.
Thirty-two keep-alive connections against four loops on macOS:

| `M0_ACCEPT_SHARE` | connections per loop |
|---|---|
| `0` (the bare race) | 1, 0, 30, 1 |
| unset | 8, 8, 8, 8 |

So N threads on one listener are the same herd as N processes (E16 found
32 of 32), and a throughput row taken without sharing would have been one
loop's. Replacing the channel with a plain integer over an in-process queue
is possible and was not done: the socketpair is what the gates cover, and at
one hand-off per CONNECTION it is not on any request's path.

**Signals.** `m0serve`'s threaded mode had already solved it and the host
does the same: the handler writes its byte to the one pipe; the spawning
thread is blocked reading it; it then pokes one pipe per loop
(`ShutdownFanout`), because a loop never drains its shutdown pipe and N
loops cannot share one. The coordinator's join is bounded
(`JOIN_TIMEOUT_NS` + the pool join's floor + 1 s): a loop that never sees
the stop is named and the exit is 1, where `join_all` would have made
SIGTERM a no-op until the SIGKILL.

**The producer, and what replaces the supervisor.** In one process the
producer is simply one thread; there is no tick-owner question because there
is one process to own it. `Publisher.next_id` still numbers from the shared
word. The respawn case that motivated E25 — ids restarting at 1 under a
stream that has seen 41 — cannot happen, because nothing is respawned.
**Nothing replaces the supervisor: a loop that dies takes the process**
(exit 1, named). The alternative, serving on the loops that are left, is N−1
loops behind a listener N were promised, with every stream the dead loop
held open and silent. Whatever restarts the process — a container runtime,
systemd — plays the supervisor's part, and that is the real difference
between the modes: under prefork a crash costs one worker's connections,
here it costs all of them.

D30's threaded reading: a `make` that raises on any loop is the same 78, and
**no loop takes a connection until every loop has its handler.** Each thread
builds its handler and its pool, reports ready, and waits at a barrier the
spawning thread opens once all have reported. Without it, loop 0 was serving
for the 300 ms it took loop 1 to refuse — a server that ran a configuration
it then said it would not run.

**`M0_BLOCKING_THREADS` × `M0_THREADS`** is T loops of N, `m0serve`'s rule:
one pool per loop, because a job names a slot and a slot indexes one loop's
`ProvisionPool`. That is T×(N+1) handlers. The pool code is shared between
the two modes (`_start_pool`, `_join_pool`) rather than written twice.

**State that lives in one THREAD.** `fragment_notes` answers
`max_workers() -> 1` because its notes are a list in a struct. Under threads
that is N lists in one process — every loop calls `make` — and the app would
have served them without a word, each request seeing whichever list its
connection's loop held. So `AppHandler` and `ViewState` gained
`max_threads()`, **defaulting to `max_workers()`**: the application that
refused workers refuses loops without being asked, and the notes app's
source did not change. An application whose state really is shared across
its loops (`ctx.page`, which under threads is plain memory; a database)
overrides it. `M0_WORKERS>1` with `M0_THREADS>1` is refused
(`threads_conflict`, the sentence `m0serve` uses), as is `M0_THREADS=0`.

## Question 2: does `global_slot.mojo` survive?

Yes. Its three slots are the shutdown pipe's write end, the supervisor's
child pids and the supervisor's stopping flag. The first is written once, on
the spawning thread, before any loop exists, and read only by the signal
handler; the other two belong to a supervisor a threaded host never makes.
Nothing per-worker is stashed there, so nothing became a race.

## Question 3: `exit_worker()`

Not called. It exists because a forked child cannot run the runtime's
teardown; nothing here was forked, and `main` returns. Measured: exit 0,
70 ms after SIGTERM. The two `_exit` paths that
remain are the ones the prefork host has — a pool thread or a producer step
still inside the application past its bound — plus the straggler loop above.

## The measurement

`uv run poe bench-host-modes` (`scripts/bench_host_modes.py`): one binary,
`apps/ramp` under the host, three arms per round each on a fresh server —
one worker (the comparator), N workers, N threads — against `/x/now`, which
is answered on the loop and so measures the LOOP, and `/x/search?sel=25`,
the table's compute view. Keep-alive, the keep-alive cap off, three rounds,
eight seconds each. Cores and RSS are summed over the server's process tree.
The ratios below are threads over workers, the median across rounds of the
ratio within each round.

macOS, Apple M4, N = 4
([`host-modes-20260918T201017Z.json`](../../bench/results/host-modes-20260918T201017Z.json),
rendered in [SERVER_PERFORMANCE.md](../SERVER_PERFORMANCE.md)):

| route, connections | throughput | per core | p99 | RSS |
|---|--:|--:|--:|--:|
| now, 16 | 0.99x | 0.95x | 1.02x | 0.78x |
| now, 256 | 1.00x | 0.96x | 1.00x | 0.79x |
| search, 16 | 0.99x | 0.99x | 1.02x | 0.78x |
| search, 256 | 0.99x | 0.99x | 0.95x | 0.80x |

Linux 6.8 aarch64 in the colima VM, 4 CPUs shared with the client, N = 2
([`host-modes-linux-20260918T201830Z.json`](../../bench/results/linux-2026-09/host-modes-linux-20260918T201830Z.json),
filed under the subdirectory because a container copy of the tree cannot
say whether it was clean):

| route, connections | throughput | per core | p99 | RSS |
|---|--:|--:|--:|--:|
| now, 16 | 0.95x | 0.95x | 1.61x | 0.63x |
| now, 256 | 1.00x | 0.89x | 1.02x | 0.68x |
| search, 16 | 1.03x | 1.03x | 0.98x | 0.64x |
| search, 256 | 0.99x | 0.99x | 1.11x | 0.68x |

How to read them:

- **Throughput is the same**, on both backends, on the loop route and the
  compute route, at both connection counts: between 0.95x and 1.03x, inside
  what one arm moves between its own rounds.
- **The tail is the same.** The one ratio that stands out, 1.61x at sixteen
  connections on Linux, is a median of 121 µs against 48, 43 against 44 and
  98 against 61 — tens of microseconds, in rounds that do not agree with
  each other.
- **RSS is the difference**: a fifth less on macOS at four loops, a third
  less on Linux at two. One runtime and one allocator instead of N. The
  ramp's corpus is built per handler in both modes, so this is the floor of
  the saving, not an application's.
- On macOS the `now` rows are the CLIENT's: one worker serves as many
  requests as four (212k against 206k), `wrk` being out of cores before the
  server is, and the server's cores column reads 2.8 of 4. What those rows
  compare is cost per request, where threads spend 4–5 % more CPU for the
  same work. The `search` rows and both Linux routes are the server's.
- Linux round 3's `now` rows fell in BOTH arms (546k to 439k for workers,
  557k to 347k for threads at 256 connections) while the one-worker
  comparator held: a four-CPU VM running two loops and two client threads
  has no core to spare for anything else the host machine does. The medians
  are rounds 1 and 2's figures; the round is in the artifact.
- Not measured: Linux x86, which the plan asked for. There is none here —
  the local VM is aarch64, and an emulated amd64 `m0serve` dies of SIGFPE
  under QEMU. If the two architectures disagree, that is a finding for the
  first x86 host this runs on; nothing above predicts it.

## The decision

Threads buy no throughput and no tail, and they cost crash isolation: a
worker that dies is replaced, a loop that dies ends the process. They buy
memory, one address space, and the absence of `fork` — which is what
matters to an application that must use a runtime that is off limits after
a fork without exec (Core ML, anything reaching CoreFoundation;
[coreml-embeddings](coreml-embeddings.md)), that wants its loops to share
state through plain memory, or that is sized by RSS. So prefork stays what
the documentation reaches for first and `M0_THREADS` is served, whole, for
the application that has one of those reasons. Neither is a default in the
sense of happening unasked: the host's default is one loop.

## What is gated

`smoke-host-threads`, a `test.yml` step of its own, on every pull request.
CI pins a GIL-enabled CPython, so `m0serve`'s threaded phases skip there and
its step proves the refusal alone; a Mojo host has no interpreter, so this is
the first threaded SERVING the repository gates on every pull request.

- **E27, fan-out across loops.** Four streams that must span both loops
  (`x-worker`; a run that cannot spread them fails as vacuous — the
  `sim_loop` lesson) each carry every beat, from one pid. And T loops of N.
- **E28, the drain.** One connection per loop, proven to sit on different
  loops, a 1.5 s request written on each, SIGTERM while they spin: both
  answered whole, exit 0.
- **E29, isolation.** Five `/instance` requests per connection: one pid, and
  each loop's handler has counted exactly its own requests. The three
  refusals, and the barrier: a knob raises on loop 1 alone, 300 ms late, and
  the log must hold no `Event loop started`. `smoke-fragment-notes` refuses
  `M0_THREADS=2` for the app that said only `max_workers`.

Each has its negative arm in `poe sabotage-host --only threads`, seven rules
reverted one at a time, all caught on the first run: only loop 0 draining
its bus channel (a stream on loop 1 carries no beats), the stop reaching
loop 0 alone (exit 1), every handler built as loop 0 (the spread is
vacuous), the barrier removed, the loop limit removed, the default not the
worker limit, and the conflict served. An eighth, `ViewsApp` dropping its
state's loop limit, is caught by the notes smoke.

Not claimed: that a loop which RAISES takes the process. The line is there
and it is three lines long, but nothing on the wire makes `run_event_loop`
raise on demand, and a gate that cannot fail is not evidence.
