# Benchmarks

Every table renders from a dated, environment-stamped artifact in
[`bench/results/`](../bench/results/), and the prose recomputes its
figures from the same artifacts. A figure that no artifact backs carries
an `observed:` marker in the page's source.

m0serve ties Granian on bare WSGI. On bare ASGI it serves more requests
per second than uvicorn, and about as many per core as uvloop. Its
clearest lead is the tail: a fast request stays fast while slow work is
in flight.

## How to read this page

- <!-- observed: cross-session runs from before the artifact system, 2026-08 -->Compare rows inside one table. Identical binaries move ~1.5x in
  absolute rps across sessions on this hardware, from thermal and load
  state alone. Whether a ratio holds on Linux is under
  [What this page does not measure](#what-this-page-does-not-measure).
- Each table's `cores` column is sampled `%cpu` of the pids on the listen
  socket. A comparator run as `--workers 1` uses
  ~<!-- num:granian-w1-cores@2 -->1.79<!-- /num --> cores across its
  runtime's I/O threads, and rps/core corrects for it.
- <!-- observed: one worker pinned to background QoS, 2026-08; not re-measured -->The box has performance and efficiency cores (Apple M4, 4P + 6E), and
  an E-core serves this workload 4.4x slower (18.6k rps against a
  P-core's 81.7k, measured by pinning a worker to background QoS). Per-core
  rows are comparable only where server plus load generator fit in the
  P-cores: 1 and 2 workers. The 4-worker rows measure the scheduler.
- An explicit `--workers N` turns the zero-config handler pool off, so
  every row names its handler threads.
- Every table renders from the newest committed artifact. CI refuses an
  artifact that lacks a version stamp, was recorded on a dirty tree, or is
  more than one minor version behind `pyproject.toml`. Each table's
  Environment line names its Python; the slow-view table is on
  free-threaded 3.14t because its `--threads` rows need that build.
- Each wrk figure is a median across rounds, because one round per run
  lands well off the others; each artifact records the rounds behind
  every row. The medians of three recorded runs agree to within 0.03 on
  the per-core ratio. The fast-request tail table is one run of
  `scripts/bench_asgi.py`.

The comparators are Granian, at the version each table's Environment line
names, and uvicorn, both run with their own recommended settings, and
every row is a single process unless the label says otherwise. Where a
comparator wins, the row stays.

## The short version

| question | answer |
| --- | --- |
| Fastest on bare WSGI? | **A tie** — one worker and one handler thread each, Granian to m0serve is ~<!-- num:granian-per-m0@2 -->0.98<!-- /num -->x per core and <!-- num:granian-vs-m0-rps@2 -->0.99<!-- /num -->x in requests per second, inside the spread between recordings, which have put each of the two a few percent ahead in turn. <!-- observed: bench/results/linux-2026-11/layer-split-linux-20261106T023949Z.json; bench/results/asgi-per-core-2026-10/layer-split-linode-unpinned-20261006T193017Z.json -->On Linux m0serve leads this row: 1.11x Granian in requests per second in the aarch64 container at 1.17.0, and 1.04x on rented x86-64 hardware on 2026-10-06 |
| Fastest on bare ASGI? | **In requests per second, yes**: <!-- num:asgi-vs-uvloop@2 -->1.64<!-- /num -->x uvicorn with uvloop (what `pip install uvicorn[standard]` runs) and <!-- num:asgi-vs-uvicorn@2 -->2.34<!-- /num -->x `uvicorn --loop asyncio` at 16 connections, the executor's two threads using <!-- num:asgi-m0-cores@1 -->1.6<!-- /num --> cores where uvicorn has one. **Per core against uvloop, about level on this box**: <!-- num:asgi-per-core-vs-uvloop@2 -->0.99<!-- /num -->x, the second thread buying throughput rather than efficiency. <!-- observed: notes/asgi-per-core.md, artifacts in bench/results/asgi-per-core-2026-10/ -->On Linux the default is a little behind per core, 0.91x in a container and 0.94x on rented x86-64 hardware, and the one-thread loop (`M0_INVERTED=1`) is the per-core answer: 1.31x uvloop on this box, 1.42x in the container and 1.27x on the rented box, at 16 connections, where it also serves more than the default on Linux and less on this box. Against `--loop asyncio` the executor leads per core by ~<!-- num:asgi-per-core-vs-uvicorn@2 -->1.43<!-- /num -->x everywhere measured |
| Fastest fast-request tail under mixed load? | **Yes** against `uvicorn --loop asyncio`: p99 ahead in every recorded run. uvloop is not in this bench. |

## The HTTP layer, and the bridge

Splitting the server into the part that parses HTTP and the part that
calls Python prices each layer:

<!-- generated: layer-split -- edit bench/results, not this table -->
Source: [`layer-split-20261023T024755Z.json`](../bench/results/layer-split-20261023T024755Z.json) — 2026-10-23T02:47:55+00:00, commit `d207a9ef`.
Environment: Python 3.13.6; granian 2.8.4; Apple M4 (10 cores: 4P+6E); 16 GB; macOS 27.0.1 (26A434); AC Power; wrk -c16 -d10s, 3 rounds, medians.

| row | rps | cores | rps/core |
|-----|----:|------:|---------:|
| `apps/hello` — mojo-http HTTP layer, zero Python | 230,009 | 0.99 | 231,165 |
| `m0serve` + bare WSGI, 1 worker, app inline on the loop (no handler thread) | 132,891 | 0.99 | 133,559 |
| `m0serve` + bare WSGI, 1 worker, 1 handler thread | 198,067 | 1.77 | 112,219 |
| `granian` + bare WSGI, 1 worker, 1 blocking thread | 196,977 | 1.79 | 110,043 |
| `m0serve` + bare WSGI, zero-config (what `m0serve app.wsgi` runs) | 198,025 | 1.75 | 112,835 |
| `m0serve` + bare WSGI, 4 workers, 1 handler thread each | 155,887 | 4.57 | 34,111 |
| `granian` + bare WSGI, 4 workers, 1 blocking thread each | 155,112 | 4.10 | 37,832 |

Cores: sampled `%cpu` of the pids on the listen socket.
<!-- /generated: layer-split -->

The one-worker rows:

- the HTTP layer with no Python at all (`apps/hello`) runs at
  **<!-- num:hello-rps-k@1 -->231.2<!-- /num -->k rps/core**, above Granian's end-to-end
  **<!-- num:granian-rps-k@1 -->110.0<!-- /num -->k**
- the same bare WSGI application run inline on that loop, one thread, runs
  at **<!-- num:m0-loop-rps-k@1 -->133.6<!-- /num -->k rps/core**, so **the bridge costs
  <!-- num:bridge-tax@2 -->1.73<!-- /num -->x**
- give the worker one handler thread, Granian's shape, and m0serve serves
  **<!-- num:m0-w1-rps-k@1 -->198.1<!-- /num -->k rps on <!-- num:m0-w1-cores@2 -->1.77<!-- /num --> cores** against Granian's
  **<!-- num:granian-w1-rps-k@1 -->197.0<!-- /num -->k on <!-- num:granian-w1-cores@2 -->1.79<!-- /num -->**: **<!-- num:m0-per-granian@2 -->1.02<!-- /num -->x per
  core**, <!-- num:m0-vs-granian-rps@2 -->1.01<!-- /num -->x in throughput
- zero-config, what `m0serve app.wsgi` runs, serves **<!-- num:m0-zero-config-rps-k@1 -->198.0<!-- /num -->k
  rps** on a pool of eight handler threads

What the split prices is the bridge: the
<!-- num:bridge-tax@2 -->1.73<!-- /num -->x on the inline row is
m0serve's own. Rps per core averages two threads that do different work,
so it cannot say which thread bounds the one-handler-thread row. Measured
per thread, the loop thread costs what Granian's tokio thread does per
request ([notes/loop-thread-bound.md](notes/loop-thread-bound.md),
[notes/loop-user-space.md](notes/loop-user-space.md)), and the two rows
are <!-- num:w1-rps-gap-pct@1 -->0.6<!-- /num --> % apart in throughput.
The bridge itself, the environ build and the response read, was cheaper
per request than Granian's PyO3 crossing in every per-thread measurement.
Bridge work was never the lever.

This table cannot say how much Granian's own bridge costs, because there
is no Granian-without-Python row to divide by. Per thread it can be read
off a profile, and the loop-thread note does that for both servers'
Python threads. Quoting the hello row against Granian would be comparing
a server that runs no Python to one that does. The row prices the bridge.

## ASGI throughput

`apps/asgi_bare` under wrk with browser-shaped headers, byte parity
asserted between the two responses, single process each:

<!-- generated: asgi-wrk-hello -- edit bench/results, not this table -->
Source: [`asgi-wrk-hello-20261023T052543Z.json`](../bench/results/asgi-wrk-hello-20261023T052543Z.json) — 2026-10-23T05:25:43+00:00, commit `d207a9ef`.
Environment: Python 3.13.6; Apple M4 (10 cores: 4P+6E); 16 GB; macOS 27.0.1 (26A434); AC Power; wrk -t2 -c16 -d8s, browser headers; executor loop: uvloop.

| row | rps | cores | rps/core |
|-----|----:|------:|---------:|
| `m0serve` — zero-config executor (its loop is stamped above) | 138,776 | 1.64 | 84,619 |
| `uvicorn --loop asyncio` | 59,186 | 1.00 | 59,186 |
| `uvicorn` with uvloop — what `pip install uvicorn[standard]` runs by default | 84,634 | 0.99 | 85,489 |

Cores: sampled `%cpu` of the pids on the listen socket.
<!-- /generated: asgi-wrk-hello -->

The loop holds no thread state while it serves
([notes/detached-loop.md](notes/detached-loop.md)), so its parsing and
writing overlap the executor's Python, and this row runs at
<!-- num:asgi-m0-cores@2 -->1.64<!-- /num --> cores:
**<!-- num:asgi-vs-uvicorn@2 -->2.34<!-- /num -->x `uvicorn --loop asyncio`**
and <!-- num:asgi-vs-uvloop@2 -->1.64<!-- /num -->x uvicorn with uvloop in
requests per second, <!-- num:asgi-per-core-vs-uvicorn@2 -->1.43<!-- /num -->x
and <!-- num:asgi-per-core-vs-uvloop@2 -->0.99<!-- /num -->x per core. The
executor can use two cores, and uvicorn one. The concurrency tables and
the loop-by-loop comparison are in [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md).

## Fast-request tail under mixed load

The measurement the executor exists for: how fast is a *fast* request while
slow ones are in flight. Four threads measure `/` while two hammer
`/slow?ms=200`. The comparator is `uvicorn --loop asyncio`.

<!-- generated: asgi-executor -- edit bench/results, not this table -->
Source: [`asgi-executor-20261023T023826Z.json`](../bench/results/asgi-executor-20261023T023826Z.json) — 2026-10-23T02:38:26+00:00, commit `d207a9ef`.
Environment: Python 3.13.6; Apple M4 (10 cores: 4P+6E); 16 GB; macOS 27.0.1 (26A434); AC Power; seconds=8, threads=8.

| server | rps | fast p50 | fast p99 | errors |
|--------|----:|---------:|---------:|-------:|
| `m0serve` — asyncio executor | 29,462 | 139 µs | 343 µs | 0 |
| `uvicorn` | 23,835 | 169 µs | 375 µs | 0 |

Fast-request latency is measured while slow requests are in flight; rps and the two percentiles come from the same run, so they trade against each other rather than being separately optimised rows.
<!-- /generated: asgi-executor -->

The fast-request p99 is ahead of uvicorn's in every recorded run. Awaits
overlap on the loop, and the Mojo acceptor never runs application code.
This bench records no cores column; the wrk rows above say the executor
uses <!-- num:asgi-m0-cores@1 -->1.6<!-- /num --> cores where uvicorn uses
one, and that is where the p50 came from.

<!-- observed: notes/wsgi-vs-asgi-history.md, the executor's first await-concurrency run -->
The await-concurrency underneath is unambiguous in a way the percentiles
are not: eight concurrent 1.5 s awaits complete in 1.51 s on one loop with
zero threads, where the buffered bridge takes 12 s.

## Slow-view isolation

A synchronous view that blocks holds the connections pinned to its event
loop; `--blocking-threads N` puts a pool of handler threads behind each
loop so it stops doing that.

Read the first two rows across, then the next two. Without the pool the
fast-route p99 climbs from <!-- num:isolation-nopool-slow0-ms@1 -->0.6<!-- /num --> ms
to <!-- num:isolation-nopool-slow2-ms@0 -->195<!-- /num --> ms as slow views
are added, most of the <!-- num:isolation-hold-ms@0 -->200<!-- /num --> ms
hold. With the pool it stays at
<!-- num:isolation-pool-slow2-ms@1 -->1.3<!-- /num --> ms. That is a
<!-- num:isolation-ratio@0 -->148<!-- /num -->x change. Prefork and
threads fail the same way and are fixed the same way.

<!-- generated: mixed-workload -- edit bench/results, not this table -->
Source: [`mixed-workload-20261023T052228Z.json`](../bench/results/mixed-workload-20261023T052228Z.json) — 2026-10-23T05:22:28+00:00, commit `d207a9ef`.
Environment: Python 3.14.7 free-threading build; granian 2.8.4; Apple M4 (10 cores: 4P+6E); 16 GB; macOS 27.0.1 (26A434); AC Power; wrk -c16 -d10s, 3 rounds, medians.

| configuration | slow=0 | slow=1 | slow=2 |
|---|---|---|---|
| `--workers 4` | 0.6 ms (0.6–0.6) | 189.6 ms (186.6–191.7) | 195.0 ms (195.0–195.4) |
| `--threads 4` | 0.7 ms (0.7–0.7) | 194.8 ms (194.7–194.9) | 199.7 ms (199.6–199.8) |
| `--workers 4 +bt=4` | 1.4 ms (1.4–1.8) | 1.4 ms (1.4–1.5) | 1.3 ms (1.3–1.3) |
| `--threads 4 +bt=4` | 0.9 ms (0.9–1.1) | 0.9 ms (0.9–0.9) | 0.9 ms (0.9–1.0) |
| `--workers 1 +bt=4` | 0.5 ms (0.5–0.5) | 0.4 ms (0.4–0.4) | 0.5 ms (0.5–0.5) |
| `granian bt=4` | 0.5 ms (0.5–0.6) | 0.5 ms (0.5–0.5) | 0.5 ms (0.5–0.5) |

Fast-route p99 as concurrent slow requests are added: the median across 3 rounds, with the min–max across those rounds in parentheses. A row that stays flat isolated the slow work; a row that climbs toward the slow view's hold time had its connections stranded behind it. Both halves run in one pass, because a control that stops failing has stopped measuring anything.
<!-- /generated: mixed-workload -->

Granian's own `--blocking-threads` is the architecture this feature
follows, and its row is one worker with a pool of four. The `--workers 4`
and `--threads 4` rows are four loops with a pool of four each, so the
`--workers 1 +bt=4` row is the like-for-like comparison. The four-loop
rows carry four processes' worth of parallel Python threads beside the
client on one ten-core laptop. The keep-alive cap is
`--max-keepalive-requests` ([RUNNING.md](RUNNING.md#limits-and-lifecycle)
says how it reaches a client's tail, and
[notes/pool-tail.md](notes/pool-tail.md) has the A/B).

## A compressed stream

`DatastarStream.open(compress=True)` (SPEC I45) sends a stream in zstd
when its request accepts zstd, one context per subscriber. It was measured by
`scripts/bench_hello_ab.py`, and by `scripts/bench_blobs_modes.py` with
`--arms before,loop,loop+zstd` on the blobs demo's image, pinned to one
core. The artifacts are in
[`bench/results/zstd-stream-2026-10/`](../bench/results/zstd-stream-2026-10/),
and the tables are in
[notes/compressing-a-stream.md](notes/compressing-a-stream.md).

- <!-- observed: bench/results/zstd-stream-2026-10/hello-zstd-ab-20261027T020015Z.json -->A server that compresses nothing did not move: `apps/hello` built before the binding and after, interleaved over six rounds on performance cores, served 1.002x the requests per second (0.99 to 1.01 by round) on the same cores.
- <!-- observed: bench/results/zstd-stream-2026-10/blobs-zstd-20261027T013922Z.json -->An uncompressed stream did not move either: blobs before and after, at 1, 10, 100 and 400 viewers, used 0.93 to 1.00x the CPU and delivered every frame.
- <!-- observed: bench/results/zstd-stream-2026-10/blobs-zstd-20261027T013922Z.json -->Compressed, blobs's whole-state frames go 3.42:1, 23.1 kB/s a viewer down to 6.75, at every count.
- <!-- observed: bench/results/zstd-stream-2026-10/blobs-zstd-20261027T013922Z.json; notes/compressing-a-stream.md for the native run -->Compression costs a loop more than the ratio suggests. At 100 and 400 viewers on one core it took 2.6 to 2.7 times the loop's CPU and 160 KB a stream. Beside 400 compressed streams a fast request's p99 was 20.5 ms, against 5.0. Natively, on a performance core, a push costs about 14 µs, where one hot context takes 5. Each subscriber's context is cold by its next frame.
- <!-- observed: bench/results/zstd-stream-2026-10/fly-load-x86-20261027.txt -->On Fly's shared-cpu-1x x86, each compressed viewer cost about 12 times a plain one, about 120 µs a push. 150 compressed viewers took 21 % of a core, and 400 plain ones took 6 %.
- <!-- observed: bench/results/zstd-stream-2026-10/seat-compress-20261027.txt -->A stream that repeats its markup compresses much further: a Datastar game's seat, captured for 240 s with its own tools, reached the page at 25.1:1, 3.03 MB in 121 KB. Its bytes decoded to the plain capture exactly.

## What this page does not measure

- m0serve has neither TLS nor HTTP/2; terminate at a proxy, as gunicorn
  does. A comparison against servers that have them would be measuring
  the proxy.
- Every row above serves a bare handler, because a Django view's own work
  dominates and would hide the server difference entirely. That cuts both
  ways: it makes these gaps visible, and it makes them a smaller fraction
  of any real request than they look here. Two framework rows, FastHTML
  and Django ASGI at `/`, were measured on 2026-08-27 and not re-recorded
  after the executor's later changes. They are in
  [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md) ("Framework rows").
- <!-- observed: notes/asgi-per-core.md; bench/results/linux-2026-11/ -->Every
  artifact on this page is macOS arm64; CI builds and smoke-tests Linux
  x86-64 and aarch64, and the benchmark box is one machine.
  `uv run poe bench-linux-conclusions` re-measures the page's conclusions
  on Linux before each release, and on 1.17.0 all of them held in
  direction. Two differ in size there: bare WSGI leans to m0serve, and the
  ASGI default is further behind uvloop per core. The short version gives
  both figures, and [the note](notes/the-conclusions-on-linux.md) has the
  tables and the per-arm spreads.

## Reproducing

Each table's artifact comes from one script, run on a clean checkout with
nothing else busy on the machine:

| table | recorded on | run |
| --- | --- | --- |
| The HTTP layer, and the bridge | the default venv, Granian from `uv sync --group bench` | `scripts/bench_layer_split.sh`, with `apps/hello` built to `/tmp/bench_hello_server` |
| ASGI throughput | the default venv | `poe bench-asgi-wrk` |
| Fast-request tail under mixed load | the default venv | `poe bench-asgi` |
| Slow-view isolation | free-threaded 3.14t, `poe py314t-try` | `scripts/bench_mixed_workload.sh` |

The prerequisites, the swap's rules, and the procedures for that page's
own tables are in [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md#reproducing).

After recording a new artifact, `uv run poe render-bench-docs` rewrites
the tables.
