# Benchmarks

Every number in the tables below is rendered from a dated,
environment-stamped JSON artifact in [`bench/results/`](../bench/results/),
and the figures quoted in the prose are recomputed from those same
artifacts. Both are CI-checked.

Figures that no artifact backs — the performance/efficiency core split,
the cross-session variance number, and the history of how each row got
where it is — are marked as recorded observations in the page's source.

Performance claims themselves are mixed: m0serve is not the fastest server in this
comparison on raw throughput, but the tables show it keeps a fast request fast while slow work is in flight.

## How to read this page

- <!-- observed: cross-session runs from before the artifact system, 2026-08 -->**Within-run ratios are the signal; absolute rows are not.** Identical
  binaries move ~1.5x in absolute rps across sessions on this hardware,
  from thermal and load state alone. Compare rows inside one table. The
  doctrine holds across RUNS and not across PLATFORMS: two of the
  conclusions below invert on Linux (last section).
- **Cores are measured, not configured.** Each table's `cores` column is
  sampled `%cpu` of the pids on the listen socket; a comparator run as
  `--workers 1` uses ~<!-- num:granian-w1-cores@2 -->1.76<!-- /num --> cores
  across its runtime's I/O threads, and rps/core is what corrects for it.
- <!-- observed: one worker pinned to background QoS, 2026-08; not re-measured -->**The box has performance and efficiency cores** (Apple M4, 4P + 6E),
  and an E-core serves this workload 4.4x slower (18.6k rps against a
  P-core's 81.7k, measured by pinning a worker to background QoS). Per-core
  rows are comparable only where server plus load generator fit in the
  P-cores: 1 and 2 workers. The 4-worker rows measure the scheduler.
- **Every table renders from the newest committed artifact, and CI
  refuses one that lacks a version stamp, was recorded on a dirty tree,
  or is more than one minor version behind `pyproject.toml`.** Each
  table's Environment line names its Python; the slow-view table is on
  free-threaded 3.14t because its `--threads` rows need that build.
- **Every figure is the median of three rounds**, because one round per
  run lands well off the other two; the medians of three recorded runs
  agree to within 0.03 on the per-core ratio.

The comparators are Granian 2.8.2 and uvicorn, both run with their own
recommended settings, and every row is a single process unless the label
says otherwise. Where a comparator wins, the row stays.

## The short version

| question | answer |
| --- | --- |
| Fastest on bare WSGI? | **On this box, no** — one worker and one handler thread each, Granian is ahead by ~<!-- num:granian-per-m0@2 -->1.01<!-- /num -->x per core and <!-- num:granian-vs-m0-rps@2 -->1.02<!-- /num -->x in requests per second. <!-- observed: notes/the-conclusions-on-linux.md, artifacts in bench/results/linux-2026-09/ -->**On Linux the answer inverts** — 1.08x in requests per second and 1.03x per core, m0serve ahead |
| Fastest on bare ASGI? | **In requests per second, yes**: <!-- num:asgi-vs-uvloop@2 -->1.44<!-- /num -->x uvicorn with uvloop (what `pip install uvicorn[standard]` runs) and <!-- num:asgi-vs-uvicorn@2 -->2.01<!-- /num -->x `uvicorn --loop asyncio` at 16 connections, the executor's two threads using <!-- num:asgi-m0-cores@1 -->1.6<!-- /num --> cores where uvicorn has one. **Per core on this box, against uvloop, no**: uvloop is ahead by ~<!-- num:uvloop-per-core-lead@2 -->1.12<!-- /num -->x — <!-- observed: notes/the-conclusions-on-linux.md, artifacts in bench/results/linux-2026-09/ -->**this too inverts on Linux**, where the executor leads uvloop by 1.11x per core; against `--loop asyncio` the executor leads per core by ~<!-- num:asgi-per-core-vs-uvicorn@2 -->1.25<!-- /num -->x on either platform |
| Fastest fast-request tail under mixed load? | **Yes** — p99 ahead of uvicorn in every recorded run |
| Fastest HTTP layer, Python excluded? | **Yes** — but see the note on why that is not the interesting number |

## The HTTP layer, and the bridge

This is the decomposition that matters, and it is why the "fastest HTTP
layer" row above is marked as uninteresting. Splitting the server into the
part that parses HTTP and the part that calls Python prices each layer
instead of reporting one number for both:

<!-- generated: layer-split -- edit bench/results, not this table -->
Source: [`layer-split-20260906T215002Z.json`](../bench/results/layer-split-20260906T215002Z.json) — 2026-09-06T21:50:02+00:00, commit `e794772`.
Environment: Python 3.13.6; granian 2.8.2; Apple M4 (10 cores); wrk -c16 -d10s, 3 rounds, medians.

| row | rps | cores | rps/core |
|-----|----:|------:|---------:|
| `apps/hello` — mojo-http HTTP layer, zero Python | 195,969 | 0.98 | 199,968 |
| `m0serve` + bare WSGI, 1 worker, app inline on the loop (no handler thread) | 118,652 | 0.99 | 119,850 |
| `m0serve` + bare WSGI, 1 worker, 1 handler thread | 183,787 | 1.73 | 106,235 |
| `granian` + bare WSGI, 1 worker, 1 blocking thread | 188,371 | 1.76 | 107,029 |
| `m0serve` + bare WSGI, zero-config (what `m0serve app.wsgi` runs) | 184,423 | 1.74 | 105,990 |
| `m0serve` + bare WSGI, 4 workers, 1 handler thread each | 148,716 | 4.44 | 33,495 |
| `granian` + bare WSGI, 4 workers, 1 blocking thread each | 147,882 | 4.25 | 34,796 |

Cores are measured (sampled `%cpu` of the pids on the listen socket), not configured — the column exists because a "1 worker" comparator was found running well over one core. Cross-session absolute rps on this hardware varies ~1.5x; within-run ratios are the signal.
<!-- /generated: layer-split -->

Read the one-worker rows. Four numbers, and the arithmetic between them
is the finding:

- the HTTP layer with no Python at all (`apps/hello`) runs at
  **<!-- num:hello-rps-k@1 -->200.0<!-- /num -->k rps/core**, above Granian's end-to-end
  **<!-- num:granian-rps-k@1 -->107.0<!-- /num -->k**
- the same bare WSGI application run inline on that loop, one thread, runs
  at **<!-- num:m0-loop-rps-k@1 -->119.8<!-- /num -->k rps/core**, so **the bridge costs
  <!-- num:bridge-tax@2 -->1.67<!-- /num -->x**
- give the worker one handler thread, Granian's shape, and m0serve serves
  **<!-- num:m0-w1-rps-k@1 -->183.8<!-- /num -->k rps on <!-- num:m0-w1-cores@2 -->1.73<!-- /num --> cores** against Granian's
  **<!-- num:granian-w1-rps-k@1 -->188.4<!-- /num -->k on <!-- num:granian-w1-cores@2 -->1.76<!-- /num -->**: **<!-- num:m0-per-granian@2 -->0.99<!-- /num -->x per
  core**, <!-- num:m0-vs-granian-rps@2 -->0.98<!-- /num -->x in throughput
- zero-config, what `m0serve app.wsgi` runs, serves **<!-- num:m0-zero-config-rps-k@1 -->184.4<!-- /num -->k
  rps** on a pool of eight handler threads

What the split prices is the bridge: the
<!-- num:bridge-tax@2 -->1.67<!-- /num -->x on the inline row is real and
it is m0serve's own. What it cannot say is which thread bounds the
one-handler-thread row, because rps per core averages two threads that do
different work. Measured per thread
([notes/loop-thread-bound.md](notes/loop-thread-bound.md)), that row was
bound by the event-loop thread, which cost more CPU per request than
Granian's tokio thread while the Python thread idled a third of the time.
Two changes since closed that gap on the loop: the pool handoff moved
into memory, taking its datagram syscalls with it
([notes/pool-ring-handoff.md](notes/pool-ring-handoff.md)), and the
header path — lookups, inserts, the token scanner, the receive copy —
was rebuilt against the on-CPU profile
([notes/loop-user-space.md](notes/loop-user-space.md)). The loop thread
now costs what the tokio thread does per request, and the two rows are
<!-- num:w1-rps-gap-pct@1 -->2.4<!-- /num --> % apart in throughput. The
bridge itself, the environ build and the response read, was cheaper per
request than Granian's PyO3 crossing throughout, which is why bridge work
was never the lever. The per-thread figures are in the three notes.

Until 2026-09-05 the head-to-head row was the inline one. An explicit
`--workers 1` switches the zero-config pool off, so the table compared the
loop alone against Granian's one blocking thread, which understated
m0serve's throughput by a third and flattered its per-core figure; the
same-shape pair is the comparison now.

**What this table cannot tell you is how much Granian's own bridge costs**,
because there is no Granian-without-Python row to divide by. Per thread it
can be read off a profile, and the loop-thread note does that for both
servers' Python threads. Quoting the hello row against Granian would be
comparing a server that runs no Python to one that does. It is on this
page because it prices the bridge, not because it is a win.

## ASGI throughput

`apps/asgi_bare` under wrk with browser-shaped headers, byte parity
asserted between the two responses, single process each:

<!-- generated: asgi-wrk-hello -- edit bench/results, not this table -->
Source: [`asgi-wrk-hello-20260908T161109Z.json`](../bench/results/asgi-wrk-hello-20260908T161109Z.json) — 2026-09-08T16:11:09+00:00, commit `7dae923`.
Environment: Python 3.13.6; Apple M4 (10 cores); wrk -t2 -c16 -d8s, browser headers; executor loop: uvloop.

| row | rps | cores | rps/core |
|-----|----:|------:|---------:|
| `m0serve` — zero-config executor (its loop is stamped above) | 117,185 | 1.60 | 73,241 |
| `uvicorn --loop asyncio` | 58,178 | 0.99 | 58,766 |
| `uvicorn` with uvloop — what `pip install uvicorn[standard]` runs by default | 81,365 | 0.99 | 82,187 |

Cores are measured (sampled `%cpu` of the pids on the listen socket), not configured — the column exists because a "1 worker" comparator was found running well over one core. Cross-session absolute rps on this hardware varies ~1.5x; within-run ratios are the signal.
<!-- /generated: asgi-wrk-hello -->

**The cores column is the story of this row.** The executor used to lose
it, running under one core against uvicorn's one: every request was
serialized through loop thread → submit datagram → executor thread →
completion datagram → loop thread, both threads idling between handoffs.
Since 2026-09-04 the loop holds no thread state while it serves
([notes/detached-loop.md](notes/detached-loop.md)), so its parsing and
writing overlap the executor's Python, and this row runs at
<!-- num:asgi-m0-cores@2 -->1.60<!-- /num --> cores:
**<!-- num:asgi-vs-uvicorn@2 -->2.01<!-- /num -->x `uvicorn --loop asyncio`**
and <!-- num:asgi-vs-uvloop@2 -->1.44<!-- /num -->x uvicorn with uvloop in
requests per second, <!-- num:asgi-per-core-vs-uvicorn@2 -->1.25<!-- /num -->x
and <!-- num:asgi-per-core-vs-uvloop@2 -->0.89<!-- /num -->x per core. Read
it as a process that can use two cores against one that cannot, not as one
thread beating another; the concurrency tables and the loop-by-loop
comparison are in [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md).

<!-- observed: notes/detached-loop.md, notes/executor-python-objects.md and the artifact asgi-wrk-conns-20260904T132016Z.json record these runs -->
How it got there, with the numbers of the runs that found each step:
batching the pump (2026-08-27) and letting Python call into Mojo per event
took the executor from 0.83–0.90 cores to 1.06x `uvicorn --loop asyncio`
at 0.99 cores; the instrument then showed the loop blocked in its GIL
re-acquire 16–45 % of wall time, which detaching it removed. At 256
connections (`asgi-wrk-conns`, recorded 2026-09-04) the executor did 173k
on 1.77 cores against uvicorn asyncio's 59k and uvloop's 76k on one —
1.65x and 1.26x per core — so per core it is ahead of both at saturation
and behind uvloop at low concurrency, where the executor thread's own
per-request work is the bound. That work was cut by a third the same day
(the head read through the C API, the scope built in Mojo, one request
object instead of three closures), the move from 0.80x to 0.87x of uvloop
per core at 16 connections and from 163k to 173k at 256.

<!-- observed: the stdlib http.client run predates the artifact system; WSGI_PERFORMANCE.md holds it -->
Worth recording because it inverted a conclusion: an earlier run of this
comparison used a stdlib `http.client` harness and reported 0.88–0.94x. The
assumption was that the stdlib client understated the Mojo layer's parsing
edge. Under wrk the ratio is <!-- num:asgi-vs-uvicorn@2 -->2.01<!-- /num -->x at 16 connections (0.72x before the
pump was batched and then inverted) — the stdlib client had been
*flattering* the executor as it stood, and the fix path derived from it
was aimed the wrong way.

## Fast-request tail under mixed load

The measurement the executor exists for: how fast is a *fast* request while
slow ones are in flight. Four threads measure `/` while two hammer
`/slow?ms=200`.

<!-- generated: asgi-executor -- edit bench/results, not this table -->
Source: [`asgi-executor-20260905T202031Z.json`](../bench/results/asgi-executor-20260905T202031Z.json) — 2026-09-05T20:20:31+00:00, commit `39de02c`.
Environment: Python 3.13.6; Apple M4 (10 cores); seconds=8, threads=8.

| server | rps | fast p50 | fast p99 | errors |
|--------|----:|---------:|---------:|-------:|
| `m0serve` — asyncio executor | 30,334 | 135 µs | 262 µs | 0 |
| `uvicorn` | 24,422 | 171 µs | 385 µs | 0 |

Fast-request latency is measured while slow requests are in flight; rps and the two percentiles come from the same run, so they trade against each other rather than being separately optimised rows.
<!-- /generated: asgi-executor -->

**This is the row m0serve wins.** The fast-request p99 is ahead of
uvicorn's — in this run and in every recorded run — because awaits overlap
on the loop and the Mojo acceptor never runs application code. Until
2026-09-04 it was a narrow win stated narrowly: uvicorn's p50 and its
throughput were both better in the same run. With the loop off the GIL
the executor leads all three columns; the table above is the run. This
bench records no cores column; the wrk rows above say the executor uses
<!-- num:asgi-m0-cores@1 -->1.6<!-- /num --> cores where uvicorn uses one,
and that is where the p50 came from.

<!-- observed: notes/wsgi-vs-asgi-history.md, the executor's first await-concurrency run -->
The await-concurrency underneath is unambiguous in a way the percentiles
are not: eight concurrent 1.5 s awaits complete in 1.51 s on one loop with
zero threads, where the buffered bridge takes 12 s.

## Slow-view isolation

The strongest claim this project makes. A synchronous view that blocks holds the connections pinned to
its event loop; `--blocking-threads N` puts a pool of handler threads
behind each loop so it stops doing that.

Read the first two rows across, then the next two. Without the pool the
fast-route p99 climbs from <!-- num:isolation-nopool-slow0-ms@1 -->0.8<!-- /num --> ms
to <!-- num:isolation-nopool-slow2-ms@0 -->194<!-- /num --> ms as slow views
are added — most of the <!-- num:isolation-hold-ms@0 -->200<!-- /num --> ms
hold, which is what "the connections pinned behind it" means
arithmetically. With the pool it stays at
<!-- num:isolation-pool-slow2-ms@1 -->1.3<!-- /num --> ms. **That is a
<!-- num:isolation-ratio@0 -->150<!-- /num -->x change and the largest
effect recorded anywhere in this repository**, and it holds in both
execution modes, which is the part that matters: prefork and threads fail
identically and are fixed identically.

The control is the point. Both halves run in one pass, so the rows without
the flag have to keep failing for the rows with it to mean anything.

<!-- generated: mixed-workload -- edit bench/results, not this table -->
Source: [`mixed-workload-20260907T032546Z.json`](../bench/results/mixed-workload-20260907T032546Z.json) — 2026-09-07T03:25:46+00:00, commit `9f0511b`.
Environment: Python 3.14.7 free-threading build; granian 2.8.2; Apple M4 (10 cores); wrk -c16 -d10s, 3 rounds, medians.

| configuration | slow=0 | slow=1 | slow=2 |
|---|---|---|---|
| `--workers 4` | 0.8 ms (0.8–0.8) | 189.7 ms (188.7–191.0) | 193.6 ms (192.4–194.0) |
| `--threads 4` | 0.7 ms (0.7–0.7) | 192.7 ms (191.2–195.5) | 198.4 ms (196.8–199.6) |
| `--workers 4 +bt=4` | 1.4 ms (1.4–1.5) | 1.3 ms (1.3–1.3) | 1.3 ms (1.3–1.3) |
| `--threads 4 +bt=4` | 0.9 ms (0.9–0.9) | 0.9 ms (0.9–0.9) | 0.9 ms (0.9–1.0) |
| `--workers 1 +bt=4` | 0.5 ms (0.5–0.5) | 0.4 ms (0.4–0.5) | 0.5 ms (0.5–0.6) |
| `granian bt=4` | 0.5 ms (0.5–0.6) | 0.5 ms (0.5–0.5) | 0.5 ms (0.5–0.5) |

Fast-route p99 as concurrent slow requests are added: the median across 3 rounds, with the min–max across those rounds in parentheses. A row that stays flat isolated the slow work; a row that climbs toward the slow view's hold time had its connections stranded behind it. Both halves run in one pass, because a control that stops failing has stopped measuring anything.
<!-- /generated: mixed-workload -->

<!-- observed: the before is mixed-workload-20260906T225838Z.json; notes/pool-tail.md has the A/B -->
**The comparator's row and ours are the same row at the same shape.**
Granian's own `--blocking-threads` is the architecture this feature
follows, and its row is ONE worker with a pool of four; the `--workers 4`
and `--threads 4` rows are four loops with a pool of four each, so the
`--workers 1 +bt=4` row is the like-for-like comparison. Until 2026-09-07
that comparison read 2–4 ms against 0.5–0.6, and the whole difference was
a policy, not a path: the keep-alive request cap was 100, so the server
closed every connection after its hundredth request, the client
reconnected, and one reconnect per hundred requests is a 99th percentile
by construction — invisible to every server-side instrument, because it
sits between one response's last byte and the next request's first.
Granian has no such cap. The cap is 1000 now (nginx's) and configurable
(`--max-keepalive-requests`, 0 = never), and the spread column beside
each median says how far the rounds agreed. The four-loop rows carry
what is left: four processes' worth of parallel Python threads beside the
client on one ten-core laptop. The record, with the instruments and the
A/B, is [notes/pool-tail.md](notes/pool-tail.md).

That row could not appear in this repository's earlier record of this
benchmark, which noted granian was absent because it is not in the lock
file's default groups. It is in the `bench` group, pinned at the version
every number here names, and installing it is one flag:
`uv sync --group bench`.

## What this page does not measure

- **TLS and HTTP/2.** m0serve has neither; terminate at a proxy, which is
  gunicorn's answer too. A comparison against servers that do would be
  measuring the proxy.
- **Real applications.** Every row above serves a bare handler, because a
  Django view's own work dominates and would hide the server difference
  entirely. That cuts both ways: it makes these gaps visible, and it makes
  them a smaller fraction of any real request than they look here. Two
  framework rows — FastHTML and Django ASGI at `/` — are measured all the
  same and kept in [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md) ("Framework
  rows"), off this page for that reason.
- **Anything on Linux — and this is stronger than it sounds.** These
  artifacts are macOS arm64. The CI matrix builds and smoke-tests Linux
  x86-64 and aarch64, but the benchmark box is one machine and the page
  says which. <!-- observed: notes/the-conclusions-on-linux.md -->Measured
  on 2026-09-08, **two of this page's four headline conclusions invert on
  Linux** — both of the "No" answers above, both in m0serve's favour — and
  one mechanism explains both: the row with no cross-thread handoff is the
  same on the two platforms, and every row that has one is much better on
  Linux, because a handoff costs less on epoll and futex than on kqueue.
  So "within-run ratios are the signal" transfers across RUNS, not across
  PLATFORMS. [The note](notes/the-conclusions-on-linux.md) has the table
  and what it does not say.

## Reproducing

Each table's artifact comes from one script, run on a clean checkout with
nothing else busy on the machine:

| table | recorded on | run |
| --- | --- | --- |
| The HTTP layer, and the bridge | the pinned venv, Granian from `uv sync --group bench` | `scripts/bench_layer_split.sh`, with `apps/hello` built to `/tmp/bench_hello_server` |
| ASGI throughput | the pinned venv | `poe bench-asgi-wrk` |
| Fast-request tail under mixed load | the pinned venv | `poe bench-asgi` |
| Slow-view isolation | free-threaded 3.14t, `poe py314t-try` | `scripts/bench_mixed_workload.sh` |

The prerequisites, the swap's rules, and the procedures for that page's
own tables are in [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md#reproducing).

After recording a new artifact, `uv run poe render-bench-docs` rewrites
every table on this page from it, and `uv run poe check-docs` fails if
anyone edits one by hand or types a figure into the prose outside a span.
