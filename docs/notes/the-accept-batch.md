# The accept batch: new connections wait for the ones already held — shipped 2026-09-26

> A design note from the engineering record. SPEC C8; the gate is
> `smoke-accept-batch` on both CI legs, the probe is
> `scripts/accept_batch_probe.py` against `apps/pool_spike` with `func` on
> the loop, and the mechanism is `ACCEPT_BATCH` in
> `packages/m0-http/lightbug_http/event_loop.mojo`.

## The finding

The pre-release run of 2026-09-26 (Linux, 4 vCPUs) listed it as "the
unbounded epoll accept drain; loop-only starvation". Both listeners are
edge-triggered — kqueue `EV_CLEAR`, epoll `EPOLLET` — so one readiness
event covers a whole burst, and the loop drained the listener before it
looked at anything else. kqueue reports the backlog's depth in the event,
which bounded that drain to what was queued when the wait returned. epoll
reports nothing, so the drain ran until `accept` said EAGAIN, through
connections that arrived while it ran, bounded only by `max_connections`
(1024 by default).

What made the drain expensive is `_admit_connection`: every admission runs
the connection's eager read, and on a loop that calls `func` itself — no
`--blocking-threads`, the "loop-only" shape the pool probes compare against
— that read is the whole request. A drain of N connections was N requests
served back to back, and every connection the loop already held waited for
all of them.

## The measurement

`scripts/accept_batch_probe.py`, the gate's probe. One `/slow?ms=600`
request parks the loop in `usleep`; while it sleeps, 120 connections queue
in the backlog (the listen backlog is 128, so all of them fit), each
carrying `/slow?ms=5`; then a keep-alive connection that is already
established sends `/fast`. When the loop wakes, the backlog and the
keep-alive's request are both waiting. What `/fast` waits beyond what was
left of the blocker:

| build | `/fast` beyond the blocker | burst answered |
|---|---|---|
| before (the drain to EAGAIN) | 625, 627, 625 ms | 120/120 |
| a batch of 16, taken where the listen event fell in the pass | 162, 177, 162 ms | 120/120 |
| a batch of 16, taken after the pass's other events (shipped) | 79, 80, 79 ms | 120/120 |
| shipped, `M0_ACCEPT_BATCH=0` | 625 ms | 120/120 |

The first row is the whole burst, 120 × 5 ms. The last is the knob that
restores the drain, and it reproduces the first: the probe sees the defect.

The gate runs the same shape with 10 ms requests, and states its bounds in
what one of them COSTS on the box, measured first, with every time counted
from the blocker's own answer rather than from its nominal 600 ms. Its
first version bounded nominal milliseconds, and CI's first macOS run failed
it on the runner rather than the loop: all 120 answered, `/fast` inside its
bound, and the burst 7039 ms against 1.8 s of nominal work, as a runner
whose timers oversleep every `usleep` produces. Here (Linux, 4 vCPUs) a
request costs 10.6–10.7 ms; `/fast` is answered 153–154 ms after the
blocker, against one and a half batches (about 256 ms); the burst's last
answer 1227 ms after it, against 1.25 of its cost plus 3 s; the widest gap
between two answers 11 ms; and the knob-off arm 1225 ms, against a floor of
two thirds of the burst (about 850 ms).

The second row is why the batch runs where it does. The blocker is itself
admitted inside a listen batch, and that batch goes on to take 15 more of
the burst before it ends. With accepts at the listen event's position, the
next pass's listen event came first in the list epoll returned — the
listener became ready before the keep-alive did — so `/fast` waited a
second batch too. Taken after the pass's other events, the keep-alive's
request goes first, and what is left is the one batch the blocker started:
15 × 5 ms, the 79.

## The rule

- **One batch per door per pass, after the pass's events.** A door is the
  listener or the accept-share channel a sibling hands connections over
  (`_admit_handoffs`, the same eager read, and a sibling can pass a whole
  backlog). The events loop only records that a door is ready; the batch
  runs below it.
- **What a batch leaves is owed.** Neither door is announced again for the
  same backlog, so `LoopState.accept_owed` and `handoffs_owed` carry it:
  the next pass takes a batch even with no event, and `_wait_for_events`
  does not block while either is set. Owed only when the BATCH stopped the
  drain: a kqueue budget of the reported depth that runs out leaves
  nothing its next edge will not announce, and an error accepting harder
  will not cure (EMFILE, ENFILE) is never owed — carried over, it would be
  retried every pass with a wait that no longer blocks.
- **The shutdown path is unchanged.** `_shutdown_begin` still admits every
  connection a sibling handed over before it closes the listener, because
  the drain answers what was handed over, and it clears both flags: the
  drain's passes must neither accept on a closed descriptor nor spin for
  it.
- **The inversion takes owed batches inside its callback.** Under
  `M0_INVERTED=1` a pass runs on the backend fd's readiness, on the flush
  the shim schedules after it, and on a 1 Hz tick, and an owed batch is
  none of those, so it waited for unrelated activity. `run_pass_once` runs
  further passes while anything is owed, up to `max_connections` accepts'
  worth — the bound one drain had before — because under a flood the
  backlog never empties, and the callback must return for the
  application's tasks to run. Each of those passes still serves the
  events of the connections already held before its batch.

`M0_ACCEPT_BATCH` overrides the batch; 0 takes the whole backlog in one
pass as the loop used to, and is the gate's negative arm.

## Why 16, and why a count

A batch bounds a pass's accepting at batch × the cost of one admission. On
a pooled loop an admission is a submit, microseconds; on a loop-only one it
is a request. Sixteen keeps the second short while making the extra passes
a flood costs cheap: an extra pass is a zero-timeout wait and a pass whose
stream sweep is skipped when nothing streams.

Measured on the same box (4 vCPUs, `wrk` sharing them, two threads and 64
connections for 8 s against `/fast` with `func` on the loop), the batch
costs nothing measurable. With `Connection: close`, so every request is an
accept: 50.5k, 50.1k and 46.3k requests a second with the batch, 51.8k,
47.1k and 47.2k with `M0_ACCEPT_BATCH=0`, inside the spread either way
shows between runs. Kept alive: 85.3k and 84.7k against 84.4k and 83.4k.

A time budget — accept until the pass has spent a millisecond — adapts
better to the admission's cost, and was not chosen: a count is what the
probe can hold the loop to, and a clock read per accept buys nothing a
smaller count does not.

## What the gate proves, and what it cannot

The probe holds three things on both legs, each in the measured cost of a
request: `/fast` answered within one and a half batches of the blocker's
answer (the batch, deferred); all 120 burst connections answered, a batch
stranded behind the edge-triggered listener timing out instead; and the
last of them inside 1.25 of the burst's cost plus three seconds, which a
wait that blocked between owed batches (a second per batch, the loop's
idle timeout) misses by seconds — and the widest gap between two answers,
printed beside it, says which it was. On Linux the same probe with
`M0_ACCEPT_BATCH=0` must show at least two thirds of the burst, so the
probe is known to see the drain it guards against.

Sabotaged by hand before landing, one rule at a time against the probe as
committed, each caught by its own check: no cap (`/fast` 1225 ms after the
blocker, against 258), nothing owed (31 of 120 answered, the rest stranded
behind the listener), a wait that blocks while a batch is owed (the burst
7237 ms after the blocker against 1295 of work, its widest gap 1012 ms),
and the batch taken where the listen event falls in the pass (480 ms).

Not asserted on macOS: kqueue's depth bounds its drain to what was queued,
and with accepts taken after the pass's other events, the knob alone does
not recreate the old order there, so the negative arm would test the
platform rather than the rule.

Not measured by it: the hand-off door. Accept sharing already skips a
sibling that has been inside a pass for over 2 ms, so a busy worker is
handed nothing, and a flood of hand-offs onto one worker is hard to
produce on purpose; the batch there is the same rule for the same eager
read, held by the multi-worker smokes staying green rather than by a probe
of its own. Nor the inversion's loop, which `smoke-asgi` under
`M0_INVERTED=1` exercises on every pull request without a burst.

## Not done

- A level-triggered listener with `EPOLLEXCLUSIVE`, which would re-announce
  a backlog on its own. The owed flag keeps the edge-triggered registration
  every worker already relies on under accept sharing.
- Scheduling the inversion's owed passes from the shim (`call_soon`) so
  the application's tasks run between batches. The admission there hands
  the request to an asyncio task rather than serving it, so a batch is
  cheap, and the bound above is the old one.
