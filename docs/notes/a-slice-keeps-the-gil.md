# A slice keeps the GIL: the hand-off went back to the thread that had just held it — shipped 2026-09-26

> A design note from the engineering record. SPEC E34, and E11's probe;
> the gates are `test_blocking_pool.mojo`'s keep test and `test_offload.mojo`'s
> `try_next_job` tests on every pull request, and `probe-pool-fairness`'s
> Linux arm before a release; the mechanism is `OffloadPool.try_next_job` in
> `packages/m0-http/lightbug_http/offload.mojo` and the keep branch of
> `_pool_serve` in `packages/m0-wsgi/src/blocking_pool.mojo`.

## The finding

The pre-release run of 2026-09-26 (Linux, 4 vCPUs) recorded it as
"fairness probe max outlier on a VM; needs a run on the reference Mac":
`probe-pool-fairness`'s fair arm held its p99 and failed its max. It was
not the VM. On a box of the same shape the fair arm failed 14 of 14 runs,
its max 335–1637 ms against a bound of 250 and its p99 7–23 ms. A recorder
run beside one of them — a 1 ms sleep loop, and `/proc/stat`'s steal
column every 100 ms — saw its worst sleep take 5 ms and steal at 0.6 % of
the CPU: the box never stalled. The pool's own histograms
(`M0_POOL_DEBUG=1`) put the time inside the server. A thread that had
popped its job waited 0.3–0.9 s in `PyEval_RestoreThread` while the pool
went on serving 2.6k requests a second, and the wait on the ring before
the pop never passed 20 ms.

## The mechanism

A log of every attach on the four threads — when each dropped the GIL,
yielded, asked for it back and got it, and how many threads it found
parked — showed the shape of every long wait. Thread 3 waited 656 ms
while threads 1 and 2 held the GIL 888 and 886 times between them, a job
a hold, handing it back and forth; thread 0 starved beside it. The
barrier's yield was not the cause: of 23,726 drops, 7,851 yielded until
an attach and 39 ran out of their 1 ms bound. What was: 15,751 attaches
took the GIL with no wait although another pool thread was already parked
on it.

Those were the slice's own drops. A thread inside its 1 ms slice dropped
the GIL after every job, only to pop the next, and took it straight back —
the barrier lets it, by design, until the slice is spent. Each drop
signals CPython's condition variable, which wakes a parked waiter; the
waiter finds the GIL taken again and waits once more, and a waiter that
returns to glibc's condition variable queues as a new one, behind the
rest. With three jobs to a slice and three waiters, the slice's drops
woke the two longest waiters and sent them to the back, and the slice-end
hand-off woke the one left at the front: the thread that had held the GIL
before this one. Two threads alternate for as long as the timing repeats,
and the other two starve until noise breaks it. CPython's own remedy does
not reach them either: a waiter asks the holder to drop only when its
5 ms wait saw no switch, and a switch happened every millisecond — between
the other two.

The reference Mac measured the fair arm at 17 ms on the same code, and
the probe had only run there before this. Why macOS does not show it was
not measured.

## The rule

Inside its slice, a thread takes a job that is already queued WITHOUT
dropping the GIL. `OffloadPool.try_next_job` is `next_job`'s pill check,
its socket poll on the lane's cadence and one ring pop — never its spin
or its park — so it can be called holding the GIL, and `JOB_NONE` sends
the thread down the path it always took: drop, yield if the slice is spent
and a waiter is parked, `next_job`, re-attach. The only drops a slice now
makes are its last, the hand-off, and those a view makes itself, so a
waiter is woken to take the GIL rather than to lose its place.

- Only with the turn on. A pool of one and `M0_POOL_TURN=0` keep the old
  path, so the probe's convoy arm is what it was.
- A run still begins only after a wait or a yield (`TURN_WAITED_NS`). An
  uncontended thread drops between jobs as before, which disturbs nobody
  when nobody is parked.
- A pill and an inbound WebSocket message are still read on the socket
  poll's cadence, by `try_next_job` itself, so a thread inside its slice
  leaves on its pill as it would in `next_job`. Without rings it is one
  non-blocking `recv`.
- `M0_POOL_TURN_KEEP=0` drops the GIL between every job again: the A/B
  knob, and the probe's Linux arm.

## The measurement

Linux, 4 vCPUs, the probe's shape — four pool threads, `/busy?ms=0.3`,
sixteen keep-alive connections from the probe's Python client:

| build | p99 | max | worst GIL wait | attaches past a parked waiter |
|---|---|---|---|---|
| before (14 runs) | 7–23 ms | 335–1637 ms | 262–917 ms | 15,751 of 23,726 |
| the rule (7 runs) | 8.9–9.8 ms | 12.9–20.6 ms | 10–23 ms | 16–43 |
| the rule, `M0_POOL_TURN_KEEP=0` (2 runs) | 8.6–16.6 ms | 575–735 ms | | |
| the rule, `M0_POOL_TURN=0` | 5.4–6.3 ms | 3357–5450 ms | | |

With `wrk` as the client, which takes a fraction of a core where the
Python client takes one, the old shape was worse and the rule the same:
on `/busy?ms=0.3` at sixteen connections the p99 went from 394–515 ms to
9.3–12.7 ms and the max from 617–982 ms to 24–68 ms, at 2659–2678 requests
a second before and 2660–2723 after. On the trivial route, four threads:
80.1–82.4k requests a second before and 80.3–83.0k after at sixteen
connections, and 79.8–98.2k before against 102.4–103.4k after at 256,
the p99 from 6.1–7.3 ms to 4.3–4.8. Fewer drops is less work.

## What the gates prove

- `test_blocking_pool.mojo:test_a_slice_takes_the_jobs_queued_behind_it_without_dropping_the_gil`
  (every PR): 64 jobs through four threads whose views hold the GIL, with
  every thread awake so they contend for it — every job answered, some
  taken inside a slice, and none under `M0_POOL_TURN_KEEP=0`. It proves the
  rule runs; the unfairness it prevents needs the probe's load. On a
  free-threaded interpreter nothing waits for a GIL, so no run begins and
  it asserts only the answers.
- `test_offload.mojo`'s `try_next_job` tests (every PR): the queued jobs in
  order, on the ring and without it; an empty lane answered at once, on a
  thread of its own, so a version that waits fails inside a second
  instead of hanging the suite; the pill, on a thread's own channel and on
  the lane socket.
- `probe-pool-fairness` (pre-release): the fair arm as before, and on
  Linux a third arm with the rule off (`--expect-starvation`), which must
  fail the fair bounds — the arm that proves the probe sees what the rule
  prevents. Not on macOS, where the old shape measured fair.
- Sabotaged by hand, one at a time, each caught by its own test: the keep
  branch never taken; the knob ignored; `try_next_job` waiting; and
  `try_next_job` ignoring the pill.

## Not done

- A FIFO hand-off, a ticket per waiter. The rule removes the drops that
  reordered the waiters; it does not make CPython's condition variable a
  queue. A waiter can still lose its place to a view that releases the GIL
  and takes it back inside CPython, or to its own 5 ms timeout. Two token
  designs were measured and rejected before (docs/notes/detached-loop.md),
  and a ticket would need the same care about leaving the GIL idle while
  the next taker wakes.
- The probe in CI. Its first Linux run found this, and a Linux leg would
  catch its return on every pull request, at the price of a 250 ms bound
  on a shared runner's scheduling. Not decided here.
