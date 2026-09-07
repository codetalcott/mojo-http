# The elastic pool: one thread until a job has waited — 2026-09-06

> A design note from the engineering record. It is the step after
> [loop-user-space.md](loop-user-space.md): with the event-loop thread
> at tokio's price, the zero-config handler pool — eight threads, what
> `m0serve app.wsgi` runs — was serving a trivial view at two thirds of
> the rate one thread served it, on 1.6x the cores. This note records
> what the eight threads were doing, the three rules that make the pool
> behave as one thread until a job has actually waited, the kernel fact
> that decided the fourth, and what the trivial and slow rows cost
> before and after.

Bare WSGI at one worker, `apps/wsgi_bare`, `wrk -t2` with browser
headers, Apple M4, CPython 3.13.6, granian 2.8.2, the same binary with
the rules on and off in the same session, arms alternated. Zero-config
went from 118.4k / 122.6k requests per second on 2.8 cores to
172.5k / 179.2k on the one-thread shape's cores at 16 connections,
against 176.9k / 179.4k for `--blocking-threads 1`; at 256 connections
from 0.90x of the one-thread shape to parity, one pool thread serving.
A fast request behind two 1.5 s views is answered in 2 ms
(`smoke-blocking-threads`, whose limit is 250 ms), and the mixed-workload
table's pool rows are flat under slow load at the throughput they had —
on a free-threaded interpreter by a fourth rule, recorded at the end of
this note: there the pool is parallel, because a parked thread beside a
queued job is an idle core rather than a GIL waiter.

## What the eight threads were doing

Zero-config runs `--blocking-threads min(cores, 8)` so that one slow
view cannot stall every connection out of the box
([WSGI_PERFORMANCE.md](../WSGI_PERFORMANCE.md), "A slow view strands
the connections pinned behind it"). The isolation is real and the cost
on a view that never waits had become large, because the loop got fast
and the pool did not. Per-thread CPU by `ps -M` (`scripts/probes/bench_threads.py`), medians
over 8 s, main at `3a365c4`:

| handler threads | rps | loop | each pool thread | cores |
|---|---:|---:|---:|---:|
| 1 | 176.7k / 181.4k | 98 / 94 % | 78 / 75 % | 1.76 / 1.68 |
| 2 | 163.8k / 164.2k | 94 / 96 % | 58 % each | 2.10 / 2.14 |
| 4 | 139.3k | 93 % | 41 % each | 2.56 |
| 8 (zero-config) | 121.7k | 87 % | 24 % each | 2.79 |

Every thread added cost throughput and CPU. The first reading was that
a burst of jobs is taken by as many threads as are awake and they then
serialize on the GIL with an OS wake per hand-off; that is true, and
it is not where most of the cost was. Two counters on the pool
(`OffloadPool.wake_counts`, printed at shutdown under `M0_POOL_DEBUG=1`)
split the wakes the loop sent by site, over 11 s at 16 connections:

| build | rps | pool threads | wakes for a stalled ring | wakes into an all-parked lane |
|---|---:|---|---:|---:|
| the three rules below, one shared wake socket | 154.8k | 8 × 14 % | 27 | 132,078 |
| the same, stall check off | 158.9k | 8 × 14 % | 0 | 132,355 |
| `--blocking-threads 1` | 174.2k | 1 × 74 % | 0 | 129,668 |

The one-thread shape parks and is woken 130,000 times in 11 s — once
per burst, whenever the loop has nothing for it for longer than its
10 µs spin — and zero-config parks exactly as often. The difference was
never how often a thread parks; it was which thread the wake lands on.
With eight threads blocked in `recv` on one datagram socket, the kernel
chooses, and a C ping-pong of that primitive
(`scripts/probes/herd.c`, run by `poe probe-herd`: W receivers blocked on one
`SOCK_DGRAM` pair, one datagram per round, whole-process CPU per round
trip) says how it chooses:

| receivers | macOS (M4) CPU per round trip | served by each | Linux (aarch64 VM) CPU per round trip | served by each |
|---:|---:|---|---:|---|
| 1 | 3.0 µs | all | 11.4 µs | all |
| 2 | 6.9 | 50 / 50 % | 11.2 | 50 / 50 % |
| 4 | 16.1 | 25 % each | 11.3 | 25 % each |
| 8 | 59.4 | 12.5 % each | 11.1 | 12.5 % each |

macOS wakes every blocked receiver for every datagram — eight parked
threads make one wake cost twenty times what it costs one — and they
take turns serving. Linux wakes exactly one, at no extra cost, and it
is the OLDEST waiter every time: strict round-robin. On both, every
job after a park lands on a cold thread with a cold interpreter thread
state, and on macOS twelve thousand wakes a second at 56 µs of extra
CPU each is most of the core that zero-config was spending over the
one-thread shape. The Linux VM's absolute figures are the virtualization's, not
the kernel's; the shape is the finding.

## The rules

All in `packages/m0-http/lightbug_http/offload.mojo` (`next_job`,
`submit`, `wake_aged`, `_park_on_own`, `_wake_registered`), the
loop's side in `event_loop.mojo` (`_run_pass`'s bottom and
`_wait_for_events`), and the registration in
`m0_wsgi/blocking_pool.mojo`. `M0_POOL_ELASTIC=0` turns all four off
and is the A/B arm: every idle thread spins, every push into a parked
lane pokes the lane socket, and a thread that takes a job pokes a
sibling for the rest — the rules of the day before.

1. **One idle spinner per lane.** A thread that finds its ring empty
   spins only if no sibling is already spinning idle (`spinners`, a
   per-lane word beside `parked`); otherwise it parks at once. The
   spinner sees every push itself.
2. **`submit` wakes nobody while any thread of the lane is busy or
   spinning.** A busy thread with an empty ring behind it comes back in
   microseconds and takes the job sooner than a wake could land; a wake
   beside it is a second thread on the GIL for nothing. Only a lane
   whose every thread is parked gets a wake (`_all_idle`: spinners
   zero and `threads <= parked`, the thread count kept by
   `register_thread`), and exactly one, because the wake retires the
   woken thread's parked count before the next push can look — so a
   burst of sixteen into a parked lane wakes one thread, which takes
   the burst.
3. **A ring that holds a job and has not been drained for `T` is behind
   a thread that is not coming back, and the LOOP wakes a parked
   sibling for it.** Once per pass `wake_aged` reads each lane's pop
   counter (`Ring.pops`, the head position): moved since the last look,
   the lane is being drained, however deep its queue; unmoved, the head
   has waited since the later of its push and the last look that saw
   the ring move or empty, and past `T` of that one parked thread is
   woken. `_wait_for_events` caps its timeout at `POOL_WAKE_WAIT_MS`
   (1 ms) while any job is pending, so an idle loop looks within a
   millisecond. This replaced the chained wake
   ([pool-ring-handoff.md](pool-ring-handoff.md), a thread that took a
   job poking a sibling for the rest): the hole the chain filled — a
   woken thread's socket poll consuming a sibling's wake, a hold
   registering 1.5 s late on Linux CI — is now closed every pass rather
   than once, because the loop re-examines the ring until it moves.
4. **Every pool thread parks on a wake channel of its own, and the loop
   wakes the one that parked last.** `register_thread` gives each
   thread a `SOCK_DGRAM` pair (`BlockingPool.start` reserves the
   records before spawning); a thread parks in `recv` on its own read
   end after announcing itself PARKED with a sequence number, and
   `_wake_registered` scans the lane's records for the parked thread
   with the highest sequence, moves it PARKED → WOKEN by
   compare-exchange, and pokes its write end. Whoever moves the state
   word off PARKED first owns the transition — a thread that finds a
   job on its own re-check and loses the race consumes the poke in
   flight, so no channel holds a stale wake. Pills go to those
   channels (`stop`), a WebSocket message on the lane socket is
   followed by a wake to a parked thread, which polls the socket first
   thing, and a thread that never registered (a test's, or every
   thread under the knob) parks on the lane socket under the old rule.

What did not change: announce, re-check, block on the pool side and
push, read, poke on the loop side. Every transition into spinning or
parking re-checks the ring after announcing itself, which is what lets
`submit` read three counters one after another and skip the wake: a
snapshot that straddles a thread's transition is safe because that
thread's re-check follows its own announcement, and the push preceded
the loop's reads. `test_offload.mojo` holds the rules — a burst into a
parked lane sends one wake, a push beside a busy or a spinning sibling
sends none, sixty gap-separated jobs land on one thread of two, a ring
being drained is never stalled, a job behind a slow sibling is taken
once the loop wakes a parked one — beside the lost-wakeup test and its
no-pause variant, both with registered threads now.

## Choosing T, and what the check measures

`T` (`POOL_WAKE_AGE_NS`, 200 µs; `M0_POOL_WAKE_AGE_US` overrides it for
measurement) bounds how long a fast request waits behind a slow view
before a sibling is woken: the smoke's limit is 250 ms against a 1.5 s
hold and the mixed-workload p99 is about 2 ms, so 200 µs is well inside
both and leaves the isolation where it was. What the check MEASURES
mattered more than the number:

| stall signal at 256 connections | zero-config rps | one thread | stall wakes / run | pool threads |
|---|---:|---:|---:|---|
| the head's age since its push | 183.3k / 184.6k | 203.6k / 204.5k | 463 / 358 | 8 × 8–22 % |
| the same job at the head across looks | 186.4k / 193.8k | 202.4k / 205.0k | 361 / 270 | 8 × 3–15 % |
| the ring's pop counter unmoved | 210.3k | | 57 | 1 × 59 % |

A ring 256 deep behind one thread taking 4 µs a job has a head that is
a millisecond old and moving every 4 µs; waking for its age put eight
threads on the GIL for a queue one thread was draining faster, and
the cascade sustains itself (more threads, more hand-offs, a deeper
queue, more wakes). Watching for the same job at the head across the
loop's looks was no better there, because a pass at 256 connections is
longer than `T` and every look finds a fresh head as old as the
backlog. The pop counter is the signal that means "draining": it moves
whenever any thread takes a job, whatever the depth, and stops only
when nobody does. At 16 connections all three behaved alike (2 to 36
stall wakes a run), which is why the first two looked finished until
the concurrency went up.

## Measured

`ps -M` per thread, medians over 8 s of `wrk -t2` with browser headers,
`apps/wsgi_bare`, Apple M4, CPython 3.13.6, granian 2.8.2, one session,
arms alternated. Absolute rates drift by several percent across the
session; the ratios are the result.

| connections | zero-config, rules off (`M0_POOL_ELASTIC=0`) | zero-config | `--blocking-threads 1` | granian w1 bt1 |
|---|---:|---:|---:|---:|
| 16, first session | 118.4k / 122.6k rps, 2.82 cores (8 × 24 %) | 172.5k / 179.2k (per-thread wakes, the head-age check) | 176.9k / 179.4k, 1.72 cores (1 × 76 %) | 180.4k / 185.6k, 1.75 cores |
| 16, final build | 120.1k, 2.80 cores (8 × 24 %) | 168.6k / 168.9k, 1.60 cores (1 × 70 %) | 167.5k / 169.3k, 1.59 cores (1 × 70 %) | |
| 256, final build | | 210.3k / 206.3k, 1.58 cores (1 × 59 %) | 206.9k / 207.6k, 1.57 cores (1 × 59 %) | |

The machine ran several percent slower by the final rounds (one thread
at 168k against 177k an hour before); within a session the zero-config
and one-thread arms are within 1 % of each other at both
concurrencies, on the same cores, with one pool thread serving —
which is the "done when" of the handoff that asked for this work.

Where the two rules landed before the fourth was built, for the
record: rules 1–3 over the shared lane socket took zero-config from
118.4k / 122.6k to 159.3k / 163.5k at 16 connections, still 10 % under
one thread on 0.4 more cores, with all eight threads at 14 % — which is
the table in the first section, and what sent this note to the kernel.

## Linux

The hole the chained wake closed reproduced on Linux and never on
macOS, so the Linux reproducers ran first: the tree built in the
`m0lin` container (Debian bookworm, aarch64 under colima, CPython
3.13.11), `scripts/probes/phase5_probe.py` — `smoke-django-realtime` phase 5 with a
fresh server each round: two 1.5 s views in flight, a hold taken on a
pool thread, the subscriber must be registered half a second later —
passed 20 of 20 rounds (2 of 10 failed on the ring's first build, 0 of
20 after the chain), and `scripts/probes/hold_race_probe.py` registered 40 of 40 holds
opened while the loop was kept busy. The pool smokes on both platforms
and the fairness probe are in the pull request's gates.

## The layer split, re-recorded

`scripts/bench_layer_split.sh` on the committed tree, three rounds,
medians, process-level cores (`bench/results/layer-split-20260906T215002Z.json`,
against `layer-split-20260906T151035Z.json` from the morning, main at
`a72e340`):

| row | before | after |
|---|---:|---:|
| `apps/hello` (no Python) | 195.8k rps, 0.98 cores | 196.0k, 0.98 |
| `m0serve` + bare, `--workers 1 --blocking-threads 0` | 117.4k, 0.97 | 118.7k, 0.99 |
| `m0serve` + bare, `--workers 1 --blocking-threads 1` | 183.1k, 1.75 | 183.8k, 1.73 |
| **`m0serve` + bare, zero-config** | **123.4k, 2.84** | **184.4k, 1.74** |
| granian + bare, w1 bt1 | 189.1k, 1.73 | 188.4k, 1.76 |
| `m0serve` + bare, `--workers 4 --blocking-threads 1` | 148.9k, 4.42 | 148.7k, 4.44 |
| granian + bare, w4 | 148.1k, 3.98 | 147.9k, 4.25 |

Every row but the zero-config one is within 1 % of the morning's; that
one is at the one-thread rate on the one-thread cores. A first
recording of the same script an hour earlier landed the one-thread and
zero-config rows 7 % lower with hello and Granian unmoved; an A/B of
main's binary against this one at one thread (186.3k / 186.1k against
184.8k / 185.3k, the rules off 187.1k / 185.5k) found nothing, and
`ps` found `contactsd`, `knowledge-agent` and `AddressBookSourceSync`
at a core and a half between them. The artifact above was recorded
after they went quiet; the depressed one was discarded, as the
comparator rows exist to allow.

## The fast-route tail, and why a free-threaded pool is parallel instead

The handoff's last condition was the mixed-workload row: the fast route's
p99 with two 200 ms views in flight, unchanged at about 2 ms. The first
recording of `scripts/bench_mixed_workload.sh` on this tree (3.14t,
`--workers 4 --blocking-threads 4`, Django, `wrk -c16`) had that row's
p99 at 8.6 / 9.0 ms with one slow view and 4.1 / 6.4 with two, against
the previous artifact's 3.4 and 6.2 — and its throughput up from 55k to
80k requests per second, its p50 halved. Three things were needed to
read that.

**The tail on a GIL build is noise-shaped, on every binary.** On the
pinned 3.13, the same shape, fresh server per run, three and then four
rounds alternated (`scripts/probes/bench_slow.py`):

| arm | slow=0 p99 | slow=1 | slow=2 | rps | p50 |
|---|---:|---:|---:|---:|---:|
| main (`3a365c4`) | 1.7 / 2.9 / 2.9, then 1.8 / 7.6 / 3.1 / 7.3 ms | 2.5 / 2.7 / 2.9 | 3.3 / 3.9 / 2.5 | 54k | 280 µs |
| this tree, `M0_POOL_ELASTIC=0` | 7.5 / 7.5 / 7.6, then 2.3 / 1.9 / 2.7 / 3.1 | 4.6 / 4.4 / 4.3 | 6.3 / 6.8 / 6.3 | 54k | 285 |
| this tree, elastic | 9.9 / 5.0 / 5.5, then 6.3 / 3.2 / 7.5 / 3.3 | 6.5 / 6.9 / 8.2 | 4.9 / 7.5 / 5.7 | 82–86k | 152 |

main's own p99 with no slow view at all lands at 1.8 ms in one run and
7.6 in the next; the rules-off arm — code-identical to main on every
path with the knob off — reads 7.5 three times and then 2 to 3 four
times. The tail of four connections per worker on one interpreter is
bimodal on this machine at 2–3 and 7–8 ms, for every binary, and an
artifact's two-round median can land on either mode. What is not noise:
the elastic arm halves the p50 and carries 55 % more throughput.

**Without a GIL the tail is systematic, and the stall check is not the
cause.** The same A/B under the 3.14t swap, two rounds:

| arm (3.14t) | slow=0 p99 | slow=1 | slow=2 | rps |
|---|---:|---:|---:|---:|
| rules off | 3.3 / 3.7 ms | 2.0 / 3.1 | 2.8 / 2.8 | 60–64k |
| elastic, stall check counting from the push | 0.7 / 6.7 | 8.1 / 10.2 | 8.6 / 8.0 | 72–80k |
| elastic, stall check on progress | 8.0 / 8.7 | 8.3 / 8.6 | 8.4 / 9.1 | 72–80k |

Here the rules-off arm is steadily better in the tail, and letting the
loop wake a sibling for a head that has waited 200 µs since its push —
the first hypothesis, that a queue one thread was draining needed a
second — changed nothing. The difference is the shape: with a GIL, four
threads on four connections serialize into one thread's worth of work
and the elastic arm loses nothing by being one thread; without a GIL
four threads are four cores, and a request queued behind an occasional
slow one on the single hot thread pays that delay whole, while the
rules-off arm's four threads absorb it. The stall check is for a thread
that is not coming back; this is a thread that is coming back a few
milliseconds late, and 200 µs of patience is the wrong instrument.

So the pool is **parallel** on a free-threaded interpreter
(`OffloadPool.parallel`, set by the prefork worker from
`probe_free_threading` and by the threaded mode unconditionally,
`M0_POOL_PARALLEL` overriding either way): `submit` wakes a parked
thread whenever there is one — a parked thread beside a queued job is
an idle core — and the stall check counts from the push. The single
spinner and the wake by name on each thread's own channel apply either
way, which is what the GIL build's herd fix was. Measured under the
swap, same shape, the arms alternated:

| arm (3.14t) | slow=0 p99 | slow=1 | slow=2 | rps | p50 / p90 |
|---|---:|---:|---:|---:|---:|
| parallel (the default there) | 2.2 / 2.8 ms | 2.4 / 2.4 | 10.5 / 3.6 | 54–57k | 200 µs / 1.0 ms |
| `M0_POOL_PARALLEL=0`, the GIL rules | 7.6 / 6.2 | 9.4 / 10.4 | 8.6 / 9.1 | 78–80k | 160 / 350 |
| `M0_POOL_ELASTIC=0`, the rules off | 4.7 / 5.4 | 3.4 / 3.6 | 3.7 / 6.4 | 54–57k | 200 / 1.0 ms |

The parallel pool is the rules-off shape with the herd fix: the same
throughput and percentiles as four threads on the old wake, a tail a
third of the GIL rules'. What the GIL rules would have bought on a
free-threaded build — 40 % more throughput, a p50 of 160 µs against
200 and a p90 of 350 against a millisecond — is the other side of a
real trade, and `M0_POOL_PARALLEL=0` takes it for a deployment that
prefers the median to the tail. The default keeps the table's claim.

## The mixed workload, re-recorded

`scripts/bench_mixed_workload.sh` under the 3.14t swap, two rounds,
fast-route p99 medians (`bench/results/mixed-workload-20260906T225838Z.json`,
against `mixed-workload-20260905T204712Z.json`):

| configuration | before | after | fast rps before → after |
|---|---:|---:|---:|
| `--workers 4` | 0.8 / 191.0 / 196.1 ms | (the control, unchanged in kind) | |
| `--workers 4 +bt=4` | 2.3 / 3.4 / 6.2 | 2.6 / 2.8 / 4.1 | 55.2k → 55.0k |
| `--threads 4 +bt=4` | 2.1 / 2.0 / 2.1 | 2.1 / 2.6 / 3.2 | 42.0k → 41.4k |
| granian bt=4 | 0.6 / 0.5 / 0.6 | 0.6 / 0.5 / 0.6 | 49.9k → 48.9k |

The pool rows are flat under slow load, within the spread the section
above measured, at the throughput they had. A recording made before
the parallel rule existed — the GIL rules on 3.14t, kept in
`bench/results/mixed-workload-20260906T220102Z.json` — has the
`--workers 4 +bt=4` row at 2.5 / 8.8 / 5.2 ms and 79k requests per
second, which is the trade above in the table's own terms.
