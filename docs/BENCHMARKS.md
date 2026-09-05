# Benchmarks

Every number in the tables below is rendered from a dated,
environment-stamped JSON artifact in [`bench/results/`](../bench/results/),
and the figures quoted in the prose are recomputed from those same
artifacts and compared at the precision they are written to. Both are
CI-checked: a hand-edited table, or a sentence whose number has drifted,
fails the build naming the file.

Two figures are **not** covered by that, and each says so where it appears:
the performance/efficiency core split and the cross-session variance
number. Both are recorded observations from before the artifact system
existed. The slow-view isolation result used to be the third and largest of
them; it has an artifact now.

That is the only unusual claim this page makes. The performance claims
themselves are mixed: **m0serve is not the fastest server in this
comparison on raw throughput, and the tables below say so.** What it is
faster at is a narrower thing — keeping a fast request fast while slow work
is in flight — and the reason to read the rest is to see exactly where the
line falls.

## How to read this page

Five caveats, stated before the numbers rather than under them.

- **Within-run ratios are the signal; absolute rows are not.** Identical
  binaries move ~1.5x in absolute rps across sessions on this hardware,
  from thermal and load state alone (recorded observation, not an
  artifact). Compare rows inside one table, never a
  row here against a row in something else you read.
- **Cores are measured, not configured.** Each table's `cores` column is
  sampled `%cpu` of the pids on the listen socket. The column exists
  because it caught a real error: a comparator invoked as `--workers 1` was
  running ~<!-- num:granian-w1-cores@2 -->1.76<!-- /num --> cores across its runtime's I/O threads, so every earlier
  raw-rps ratio had been comparing 1.75 cores against one.
- **The benchmark box has performance and efficiency cores** (Apple M4, 4P
  + 6E). An E-core serves this workload at 18.6k rps against a P-core's
  81.7k — 4.4x slower (measured by pinning a worker to background QoS; not
  an artifact). So per-core rows are comparable only where the
  server plus the load generator fit in the P-cores: on this box, 1 and 2
  workers. The 4-worker rows measure the scheduler, not the server, and are
  kept because removing them would hide that.
- **Every table renders from the newest committed artifact, and CI
  refuses a stale one.** `render_bench_docs.py --check`, inside
  `poe check-docs`, fails when the artifact behind any table lacks a
  version stamp, was recorded on a dirty tree, or is more than one minor
  version behind `pyproject.toml`. Until 2026-09-05 the slow-view table
  sat on an artifact from before two changes that moved exactly its rows,
  because nothing asked. Three of the four tables are recorded on the
  venv's CPython 3.13, the GIL build a `pip install` gets; the slow-view
  isolation table on free-threaded 3.14t, because its `--threads` rows
  need that build.
- **One anomalous round per run is normal on this box.** Three recorded
  runs of the layer split each had exactly one round land well off the
  other two, in a different position each time — which is why every bench
  here takes the median of three rather than a mean of one. The medians
  from those three runs agree to within 0.03 on the per-core ratio; the
  individual rounds do not.

The comparators are Granian 2.8.2 and uvicorn, both run with their own
recommended settings, and every row is a single process unless the label
says otherwise. Where a comparator wins, the row stays.

## The short version

| question | answer |
|---|---|
| Fastest on bare WSGI? | **No** — one worker and one handler thread each, Granian is ahead by ~<!-- num:granian-per-m0@2 -->1.24<!-- /num -->x per core and <!-- num:granian-vs-m0-rps@2 -->1.32<!-- /num -->x in requests per second |
| Fastest on bare ASGI? | **In requests per second, yes**: <!-- num:asgi-vs-uvloop@2 -->1.42<!-- /num -->x uvicorn with uvloop (what `pip install uvicorn[standard]` runs) and <!-- num:asgi-vs-uvicorn@2 -->2.03<!-- /num -->x `uvicorn --loop asyncio` at 16 connections, the executor's two threads using <!-- num:asgi-m0-cores@1 -->1.6<!-- /num --> cores where uvicorn has one. **Per core, against uvloop, no**: uvloop is ahead by ~<!-- num:uvloop-per-core-lead@2 -->1.15<!-- /num -->x; against `--loop asyncio` the executor leads per core by ~<!-- num:asgi-per-core-vs-uvicorn@2 -->1.25<!-- /num -->x |
| Fastest fast-request tail under mixed load? | **Yes** — p99 ahead of uvicorn in every recorded run |
| Fastest HTTP layer, Python excluded? | **Yes** — but see the note on why that is not the interesting number |

## The HTTP layer, and the bridge

This is the decomposition that matters, and it is why the "fastest HTTP
layer" row above is marked as uninteresting. Splitting the server into the
part that parses HTTP and the part that calls Python locates the gap
instead of reporting one number for both:

<!-- generated: layer-split -- edit bench/results, not this table -->
Source: [`layer-split-20260905T201733Z.json`](../bench/results/layer-split-20260905T201733Z.json) — 2026-09-05T20:17:33+00:00, commit `39de02c`.
Environment: Python 3.13.6; granian 2.8.2; Apple M4 (10 cores); wrk -c16 -d10s, 3 rounds, medians.

| row | rps | cores | rps/core |
|-----|----:|------:|---------:|
| `apps/hello` — mojo-http HTTP layer, zero Python | 148,737 | 0.98 | 151,772 |
| `m0serve` + bare WSGI, 1 worker, app inline on the loop (no handler thread) | 103,158 | 0.98 | 105,264 |
| `m0serve` + bare WSGI, 1 worker, 1 handler thread | 143,288 | 1.65 | 86,841 |
| `granian` + bare WSGI, 1 worker, 1 blocking thread | 188,973 | 1.76 | 107,371 |
| `m0serve` + bare WSGI, zero-config (what `m0serve app.wsgi` runs) | 109,209 | 2.63 | 41,524 |
| `m0serve` + bare WSGI, 4 workers, 1 handler thread each | 141,818 | 4.03 | 35,191 |
| `granian` + bare WSGI, 4 workers, 1 blocking thread each | 149,936 | 3.51 | 42,717 |

Cores are measured (sampled `%cpu` of the pids on the listen socket), not configured — the column exists because a "1 worker" comparator was found running 1.6 cores. Cross-session absolute rps on this hardware varies ~1.5x; within-run ratios are the signal.
<!-- /generated: layer-split -->

Read the one-worker rows. Four numbers, and the arithmetic between them
is the finding:

- the HTTP layer with no Python at all (`apps/hello`) runs at
  **<!-- num:hello-rps-k@1 -->151.8<!-- /num -->k rps/core**, above Granian's end-to-end
  **<!-- num:granian-rps-k@1 -->107.4<!-- /num -->k**
- the same bare WSGI application run inline on that loop, one thread, runs
  at **<!-- num:m0-loop-rps-k@1 -->105.3<!-- /num -->k rps/core**, so **the bridge costs
  <!-- num:bridge-tax@2 -->1.44<!-- /num -->x**
- give the worker one handler thread, Granian's shape, and m0serve serves
  **<!-- num:m0-w1-rps-k@1 -->143.3<!-- /num -->k rps on <!-- num:m0-w1-cores@2 -->1.65<!-- /num --> cores** against Granian's
  **<!-- num:granian-w1-rps-k@1 -->189.0<!-- /num -->k on <!-- num:granian-w1-cores@2 -->1.76<!-- /num -->**: **<!-- num:m0-per-granian@2 -->0.81<!-- /num -->x per
  core**, <!-- num:m0-vs-granian-rps@2 -->0.76<!-- /num -->x in throughput
- zero-config, what `m0serve app.wsgi` runs, serves **<!-- num:m0-zero-config-rps-k@1 -->109.2<!-- /num -->k
  rps** on a pool of eight handler threads

So the deficit is the bridge, the per-request crossing into CPython, and
not the parsing or the event loop, which is the whole reason to split the
measurement rather than report one number.

Until 2026-09-05 the head-to-head row was the inline one. An explicit
`--workers 1` switches the zero-config pool off, so the table compared the
loop alone against Granian's one blocking thread, which understated
m0serve's throughput by a third and flattered its per-core figure; the
same-shape pair is the comparison now.

**What this table cannot tell you is how much Granian's own bridge costs**,
because there is no Granian-without-Python row to divide by; the per-side
split needs a measurement nobody has taken yet. Quoting the hello row
against Granian would be comparing a server that runs no Python to one
that does. It is on this page because it locates the cost, not because it
is a win.

## ASGI throughput

`apps/asgi_bare` under wrk with browser-shaped headers, byte parity
asserted between the two responses, single process each:

<!-- generated: asgi-wrk-hello -- edit bench/results, not this table -->
Source: [`asgi-wrk-hello-20260905T201953Z.json`](../bench/results/asgi-wrk-hello-20260905T201953Z.json) — 2026-09-05T20:19:53+00:00, commit `39de02c`.
Environment: Python 3.13.6; Apple M4 (10 cores); wrk -t2 -c16 -d8s, browser headers; executor loop: uvloop.

| row | rps | cores | rps/core |
|-----|----:|------:|---------:|
| `m0serve` — zero-config executor (its loop is stamped above) | 118,686 | 1.60 | 74,179 |
| `uvicorn --loop asyncio` | 58,609 | 0.99 | 59,201 |
| `uvicorn` with uvloop — what `pip install uvicorn[standard]` runs by default | 83,300 | 0.98 | 85,000 |

Cores are measured (sampled `%cpu` of the pids on the listen socket), not configured — the column exists because a "1 worker" comparator was found running 1.6 cores. Cross-session absolute rps on this hardware varies ~1.5x; within-run ratios are the signal.
<!-- /generated: asgi-wrk-hello -->

**The cores column is the story of this row.** The executor used to lose
it at 0.83–0.90 cores against uvicorn's 0.99 — wakeup-bound, every request
serialized through loop thread → submit datagram → executor thread →
completion datagram → loop thread, both threads idling between handoffs.
Batching the pump (2026-08-27) and letting Python call into Mojo per event
took it to 1.06x `uvicorn --loop asyncio` at 0.99 cores. Then the
instrument said why it was still one core with two threads: the loop
re-acquired the GIL after every wake and was blocked in that acquire
16–45 % of wall time, so its parsing and writing never overlapped the
executor's Python. Since 2026-09-04 the loop holds no thread state while it
serves (`docs/notes/detached-loop.md`), and this row runs at 1.59 cores:
**<!-- num:asgi-vs-uvicorn@2 -->2.03<!-- /num -->x `uvicorn --loop asyncio`** and
<!-- num:asgi-vs-uvloop@2 -->1.42<!-- /num -->x uvicorn with uvloop in requests per second, 1.25x and
0.87x per core. At 256 connections (`asgi-wrk-conns`, same afternoon) the
executor does 173k on 1.77 cores against uvicorn asyncio's 59k and uvloop's
76k on one — 1.65x and 1.26x per core — so per core it is ahead of both at
saturation and behind uvloop at low concurrency, where the executor
thread's own per-request work is the bound. That work was cut by a third
the same day (`docs/notes/executor-python-objects.md`: the head read
through the C API, the scope built in Mojo, one request object instead of
three closures), which is the move from 0.80x to 0.87x of uvloop per core
at 16 connections and from 163k to 173k at 256. Read it as a process that can
use two cores against one that cannot, not as one thread beating another;
the concurrency tables and the loop-by-loop comparison are in
[WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md).

Worth recording because it inverted a conclusion: an earlier run of this
comparison used a stdlib `http.client` harness and reported 0.88–0.94x. The
assumption was that the stdlib client understated the Mojo layer's parsing
edge. Under wrk the ratio is <!-- num:asgi-vs-uvicorn@2 -->2.03<!-- /num -->x at 16 connections (0.72x before the
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
2026-09-04 it was a narrow win stated narrowly: uvicorn's p50 was better
by about 1.5x and its throughput by a few percent in the same run. With
the loop off the GIL the executor now leads all three columns (p50 138 µs
against 169, 29.6k rps against 24.6k). This bench records no cores column;
the wrk rows above say the executor uses ~1.7 where uvicorn uses one, and
that is where the p50 came from.

The await-concurrency underneath is unambiguous in a way the percentiles
are not: eight concurrent 1.5 s awaits complete in 1.51 s on one loop with
zero threads, where the buffered bridge takes 12 s.

## Slow-view isolation

The strongest claim this project makes, and now the one with an artifact
behind it. A synchronous view that blocks holds the connections pinned to
its event loop; `--blocking-threads N` puts a pool of handler threads
behind each loop so it stops doing that.

Read the first two rows across, then the next two. Without the pool the
fast-route p99 climbs from ~1 ms to ~195 ms as slow views are added — most
of the 200 ms hold, which is what "the connections pinned behind it" means
arithmetically. With the pool it does not move. **That is a ~100x change
and the largest effect recorded anywhere in this repository**, and it holds
in both execution modes, which is the part that matters: prefork and
threads fail identically and are fixed identically.

The control is the point. Both halves run in one pass, so the rows without
the flag have to keep failing for the rows with it to mean anything.

<!-- generated: mixed-workload -- edit bench/results, not this table -->
Source: [`mixed-workload-20260905T204712Z.json`](../bench/results/mixed-workload-20260905T204712Z.json) — 2026-09-05T20:47:12+00:00, commit `39de02c`.
Environment: Python 3.14.7 free-threading build; granian 2.8.2; Apple M4 (10 cores); wrk -c16 -d10s, 2 rounds, medians.

| configuration | slow=0 | slow=1 | slow=2 |
|---|---|---|---|
| `--workers 4` | 0.8 ms | 191.0 ms | 196.1 ms |
| `--threads 4` | 1.1 ms | 194.7 ms | 200.6 ms |
| `--workers 4 +bt=4` | 2.3 ms | 3.4 ms | 6.2 ms |
| `--threads 4 +bt=4` | 2.1 ms | 2.0 ms | 2.1 ms |
| `granian bt=4` | 0.6 ms | 0.5 ms | 0.6 ms |

Fast-route p99, median across rounds, as concurrent slow requests are added. A row that stays flat isolated the slow work; a row that climbs toward the slow view's hold time had its connections stranded behind it. Both halves run in one pass, because a control that stops failing has stopped measuring anything.
<!-- /generated: mixed-workload -->

**And the comparator's row is better than ours.** Granian's own
`--blocking-threads` is the architecture this feature copied, and its
fast-route p99 stays at ~0.6 ms across all three slow levels — flat, like
ours, but roughly 4x lower than our best row and 12x lower than
`--workers 4 +bt=4`. So the honest claim is the one about the *stall*: the
pool removes a hundredfold failure that is there without it. It does not
also win the tail that remains.

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
- **Anything on Linux.** These artifacts are macOS arm64. The CI matrix
  builds and smoke-tests Linux x86-64 and aarch64, but the benchmark box is
  one machine and the page says which.

## Reproducing

The full procedure — the free-threaded interpreter swap, the rebuild inside
it, the `granian` install, and the three traps that each produced a
confident wrong answer — is in
[WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md#reproducing). It is deliberately
in the working record rather than here: this page is the result, that one
is the method and the dead ends.

After recording a new artifact, `uv run poe render-bench-docs` rewrites
every table on this page from it, and `uv run poe check-docs` fails if
anyone edits one by hand.
