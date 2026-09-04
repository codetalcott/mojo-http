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
  running ~<!-- num:granian-w1-cores@2 -->1.72<!-- /num --> cores across its runtime's I/O threads, so every earlier
  raw-rps ratio had been comparing 1.75 cores against one.
- **The benchmark box has performance and efficiency cores** (Apple M4, 4P
  + 6E). An E-core serves this workload at 18.6k rps against a P-core's
  81.7k — 4.4x slower (measured by pinning a worker to background QoS; not
  an artifact). So per-core rows are comparable only where the
  server plus the load generator fit in the P-cores: on this box, 1 and 2
  workers. The 4-worker rows measure the scheduler, not the server, and are
  kept because removing them would hide that.
- **Four of the five artifacts on this page were re-recorded on 2026-09-04**,
  after the event loop stopped holding a thread state while it serves
  (`docs/notes/detached-loop.md`), on the venv's CPython 3.13.6 — the GIL
  build a `pip install` gets. The slow-view isolation artifact still dates
  from 2026-08-26 on free-threaded 3.14t: its `--threads` rows need that
  build, and on the GIL build its Granian row would show the convoy the
  note describes rather than the flat tail recorded there.
- **One anomalous round per run is normal on this box.** Three recorded
  runs of the layer split each had exactly one round land well off the
  other two, in a different position each time — which is why every bench
  here takes the median of three rather than a mean of one. The medians
  from those three runs agree to within 0.03 on the per-core ratio; the
  individual rounds do not.

The comparators are Granian 2.8.1 and uvicorn, both run with their own
recommended settings, and every row is a single process unless the label
says otherwise. Where a comparator wins, the row stays.

## The short version

| question | answer |
|---|---|
| Fastest per core on bare WSGI? | **No** — Granian, by ~<!-- num:granian-per-m0@1 -->1.1<!-- /num -->x |
| Fastest per core on bare ASGI? | **Against `uvicorn --loop asyncio`, yes** — the executor is ahead by ~<!-- num:asgi-per-core-vs-uvicorn@2 -->1.25<!-- /num -->x per core at 16 connections and 1.50x at 256. **Against uvloop — what `pip install uvicorn[standard]` runs by default — per core only at saturation**: at 16 connections uvicorn with uvloop is ahead by ~<!-- num:uvloop-per-core-lead@2 -->1.15<!-- /num -->x per core, at 256 the executor leads by 1.14x. In requests per second the executor leads uvloop at both (<!-- num:asgi-vs-uvloop@2 -->1.41<!-- /num -->x and 2.15x), because since 2026-09-04 its two threads use 1.7–1.9 cores where uvicorn has one |
| Fastest fast-request tail under mixed load? | **Yes** — p99 ahead of uvicorn in every recorded run |
| Fastest HTTP layer, Python excluded? | **Yes** — but see the note on why that is not the interesting number |

## The HTTP layer, and the bridge

This is the decomposition that matters, and it is why the "fastest HTTP
layer" row above is marked as uninteresting. Splitting the server into the
part that parses HTTP and the part that calls Python locates the gap
instead of reporting one number for both:

<!-- generated: layer-split -- edit bench/results, not this table -->
Source: [`layer-split-20260904T032639Z.json`](../bench/results/layer-split-20260904T032639Z.json) — 2026-09-04T03:26:39+00:00, commit `0766272` (dirty tree).
Environment: Python 3.13.6; granian 2.8.2; Apple M4 (10 cores); wrk -c16 -d10s, 3 rounds, medians.

| row | rps | cores | rps/core |
|-----|----:|------:|---------:|
| `apps/hello` — mojo-http HTTP layer, zero Python | 153,054 | 0.98 | 156,177 |
| `m0serve` + bare WSGI, 1 worker | 95,245 | 0.98 | 97,189 |
| `granian` + bare WSGI, 1 worker | 181,017 | 1.72 | 105,243 |
| `m0serve` + bare WSGI, 4 workers | 167,298 | 2.92 | 57,294 |
| `granian` + bare WSGI, 4 workers | 141,344 | 3.78 | 37,393 |

Cores are measured (sampled `%cpu` of the pids on the listen socket), not configured — the column exists because a "1 worker" comparator was found running 1.6 cores. Cross-session absolute rps on this hardware varies ~1.5x; within-run ratios are the signal.
<!-- /generated: layer-split -->

Read down the `rps/core` column at one worker. Three numbers, and the
arithmetic between them is the finding:

- the HTTP layer with no Python at all (`apps/hello`) runs at **<!-- num:hello-rps-k@1 -->156.2<!-- /num -->k
  rps/core** — above Granian's end-to-end **<!-- num:granian-rps-k@1 -->105.2<!-- /num -->k**
- put the same bare WSGI application behind it and m0serve runs at **<!-- num:m0-wsgi-rps-k@1 -->97.2<!-- /num -->k
  rps/core**, so **its own bridge costs <!-- num:bridge-tax@2 -->1.61<!-- /num -->x**
- net, m0serve is **<!-- num:m0-per-granian@2 -->0.92<!-- /num -->x Granian per core**; Granian is <!-- num:granian-per-m0@2 -->1.08<!-- /num -->x ahead

So the deficit is the bridge — the per-request crossing into CPython — and
not the parsing or the event loop, which is the whole reason to split the
measurement rather than report one number.

**What this table cannot tell you is how much Granian's own bridge costs**,
because there is no Granian-without-Python row to divide by. A cleaner
decomposition — "1.0x HTTP layer × 1.35x bridge" — appeared in the working
record and does not reconcile with this artifact: the measured gap is
<!-- num:granian-per-m0@2 -->1.08<!-- /num -->x, and for a 1.35x bridge term to hold, the HTTP layer would have to be
0.89x, which contradicts the row above it. Corrected rather than repeated;
the per-side split needs a measurement nobody has taken yet.

Quoting the 115.9k hello row against Granian's 100.0k would be comparing a
server that runs no Python to one that does. It is on this page because it
locates the cost, not because it is a win.

## ASGI throughput

`apps/asgi_bare` under wrk with browser-shaped headers, byte parity
asserted between the two responses, single process each:

<!-- generated: asgi-wrk-hello -- edit bench/results, not this table -->
Source: [`asgi-wrk-hello-20260904T131803Z.json`](../bench/results/asgi-wrk-hello-20260904T131803Z.json) — 2026-09-04T13:18:03+00:00, commit `8e9466d`.
Environment: Python 3.13.6; Apple M4 (10 cores); wrk -t2 -c16 -d8s, browser headers; executor loop: uvloop.

| row | rps | cores | rps/core |
|-----|----:|------:|---------:|
| `m0serve` — zero-config executor (its loop is stamped above) | 117,643 | 1.59 | 73,989 |
| `uvicorn --loop asyncio` | 58,382 | 0.99 | 58,972 |
| `uvicorn` with uvloop — what `pip install uvicorn[standard]` runs by default | 83,384 | 0.98 | 85,085 |

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
**<!-- num:asgi-vs-uvicorn@2 -->2.02<!-- /num -->x `uvicorn --loop asyncio`** and
<!-- num:asgi-vs-uvloop@2 -->1.41<!-- /num -->x uvicorn with uvloop in requests per second, 1.25x and
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
edge. Under wrk the ratio is <!-- num:asgi-vs-uvicorn@2 -->2.02<!-- /num -->x at 16 connections (0.72x before the
pump was batched and then inverted) — the stdlib client had been
*flattering* the executor as it stood, and the fix path derived from it
was aimed the wrong way.

## Fast-request tail under mixed load

The measurement the executor exists for: how fast is a *fast* request while
slow ones are in flight. Four threads measure `/` while two hammer
`/slow?ms=200`.

<!-- generated: asgi-executor -- edit bench/results, not this table -->
Source: [`asgi-executor-20260904T033151Z.json`](../bench/results/asgi-executor-20260904T033151Z.json) — 2026-09-04T03:31:51+00:00, commit `0766272` (dirty tree).
Environment: Python 3.13.6; Apple M4 (10 cores); seconds=8, threads=8.

| server | rps | fast p50 | fast p99 | errors |
|--------|----:|---------:|---------:|-------:|
| `m0serve` — asyncio executor | 29,640 | 138 µs | 265 µs | 0 |
| `uvicorn` | 24,600 | 169 µs | 378 µs | 0 |

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
Source: [`mixed-workload-20260826T141514Z.json`](../bench/results/mixed-workload-20260826T141514Z.json) — 2026-08-26T14:15:14+00:00, commit `c182b62`.
Environment: Python 3.14.7 free-threading build; granian 2.8.1; Apple M4 (10 cores); wrk -c16 -d10s, 2 rounds, medians.

| configuration | slow=0 | slow=1 | slow=2 |
|---|---|---|---|
| `--workers 4` | 1.0 ms | 190.7 ms | 195.9 ms |
| `--threads 4` | 1.7 ms | 195.2 ms | 200.5 ms |
| `--workers 4 +bt=4` | 2.4 ms | 7.4 ms | 7.4 ms |
| `--threads 4 +bt=4` | 2.2 ms | 2.5 ms | 1.6 ms |
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
