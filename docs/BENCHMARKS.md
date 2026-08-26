# Benchmarks

Every number in the tables below is rendered from a dated,
environment-stamped JSON artifact in [`bench/results/`](../bench/results/),
and the figures quoted in the prose are recomputed from those same
artifacts and compared at the precision they are written to. Both are
CI-checked: a hand-edited table, or a sentence whose number has drifted,
fails the build naming the file.

Three groups of numbers are **not** covered by that, and each says so where
it appears — the performance/efficiency core split, the cross-session
variance figure, and the slow-view isolation result. They come from
measurements taken before the artifact system existed. The last of those is
the strongest claim on this page, which is exactly why it is flagged rather
than blended in.

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
  running ~1.75 cores across its runtime's I/O threads, so every earlier
  raw-rps ratio had been comparing 1.75 cores against one.
- **The benchmark box has performance and efficiency cores** (Apple M4, 4P
  + 6E). An E-core serves this workload at 18.6k rps against a P-core's
  81.7k — 4.4x slower (measured by pinning a worker to background QoS; not
  an artifact). So per-core rows are comparable only where the
  server plus the load generator fit in the P-cores: on this box, 1 and 2
  workers. The 4-worker rows measure the scheduler, not the server, and are
  kept because removing them would hide that.
- **The artifacts below predate the `--target-cpu` baseline pin** (commit
  `30f044a`), visible in each region's `commit` line. The pin's cost was
  measured separately and was zero — byte-identical code — so the numbers
  are not expected to move, but the provenance is one commit stale until
  the runs are repeated. Said here rather than discovered later.
- **One claim on this page has no artifact**, and it is the strongest one.
  See [Slow-view isolation](#slow-view-isolation) below.

The comparators are Granian 2.8.1 and uvicorn, both run with their own
recommended settings, and every row is a single process unless the label
says otherwise. Where a comparator wins, the row stays.

## The short version

| question | answer |
|---|---|
| Fastest per core on bare WSGI? | **No** — Granian, by ~1.2x |
| Fastest per core on bare ASGI? | **No** — uvicorn, by ~1.25x |
| Fastest fast-request tail under mixed load? | **Yes** — p99 ahead of uvicorn in every recorded run |
| Fastest HTTP layer, Python excluded? | **Yes** — but see the note on why that is not the interesting number |

## The HTTP layer, and the bridge

This is the decomposition that matters, and it is why the "fastest HTTP
layer" row above is marked as uninteresting. Splitting the server into the
part that parses HTTP and the part that calls Python locates the gap
instead of reporting one number for both:

<!-- generated: layer-split -- edit bench/results, not this table -->
Source: [`layer-split-20260825T165536Z.json`](../bench/results/layer-split-20260825T165536Z.json) — 2026-08-25T16:55:36+00:00, commit `1670230` (dirty tree).
Environment: Python 3.14.7 free-threading build; granian 2.8.1; Apple M4 (10 cores); wrk -c16 -d10s, 3 rounds, medians.

| row | rps | cores | rps/core |
|-----|----:|------:|---------:|
| `apps/hello` — mojo-http HTTP layer, zero Python | 118,599 | 0.98 | 121,020 |
| `m0serve` + bare WSGI, 1 worker | 82,146 | 0.98 | 83,823 |
| `granian` + bare WSGI, 1 worker | 176,858 | 1.75 | 101,062 |
| `m0serve` + bare WSGI, 4 workers | 160,619 | 3.14 | 51,152 |
| `granian` + bare WSGI, 4 workers | 142,435 | 4.42 | 32,225 |

Cores are measured (sampled `%cpu` of the pids on the listen socket), not configured — the column exists because a "1 worker" comparator was found running 1.6 cores. Cross-session absolute rps on this hardware varies ~1.5x; within-run ratios are the signal.
<!-- /generated: layer-split -->

Read down the `rps/core` column at one worker. Three numbers, and the
arithmetic between them is the finding:

- the HTTP layer with no Python at all (`apps/hello`) runs at **121.0k
  rps/core** — above Granian's end-to-end **101.1k**
- put the same bare WSGI application behind it and m0serve runs at **83.8k
  rps/core**, so **its own bridge costs 1.44x**
- net, m0serve is **0.83x Granian per core**; Granian is 1.21x ahead

So the deficit is the bridge — the per-request crossing into CPython — and
not the parsing or the event loop, which is the whole reason to split the
measurement rather than report one number.

**What this table cannot tell you is how much Granian's own bridge costs**,
because there is no Granian-without-Python row to divide by. A cleaner
decomposition — "1.0x HTTP layer × 1.35x bridge" — appeared in the working
record and does not reconcile with this artifact: the measured gap is
1.21x, and for a 1.35x bridge term to hold, the HTTP layer would have to be
0.89x, which contradicts the row above it. Corrected rather than repeated;
the per-side split needs a measurement nobody has taken yet.

Quoting the 121.0k hello row against Granian's 101.1k would be comparing a
server that runs no Python to one that does. It is on this page because it
locates the cost, not because it is a win.

## ASGI throughput

`apps/asgi_bare` under wrk with browser-shaped headers, byte parity
asserted between the two responses, single process each:

<!-- generated: asgi-wrk-hello -- edit bench/results, not this table -->
Source: [`asgi-wrk-hello-20260825T172428Z.json`](../bench/results/asgi-wrk-hello-20260825T172428Z.json) — 2026-08-25T17:24:28+00:00, commit `58a35ed`.
Environment: Python 3.13.6; Apple M4 (10 cores); wrk -t2 -c16 -d8s, browser headers.

| row | rps | cores | rps/core |
|-----|----:|------:|---------:|
| `m0serve` — zero-config asyncio executor | 40,838 | 0.89 | 45,885 |
| `uvicorn --loop asyncio` | 56,370 | 0.98 | 57,520 |

Cores are measured (sampled `%cpu` of the pids on the listen socket), not configured — the column exists because a "1 worker" comparator was found running 1.6 cores. Cross-session absolute rps on this hardware varies ~1.5x; within-run ratios are the signal.
<!-- /generated: asgi-wrk-hello -->

**uvicorn wins this one, and the cores column says why it is not a CPU
problem.** The executor loses while consuming 0.89 cores against uvicorn's
0.98 — it is wakeup-bound, not CPU-bound. Every request serializes through
loop thread → submit datagram → executor thread → completion datagram →
loop thread, and both threads idle between handoffs. That points at one
real lever (batching the pump so the wakeups amortize across queued
requests) and rules out the ones that sound plausible.

Worth recording because it inverted a conclusion: an earlier run of this
comparison used a stdlib `http.client` harness and reported 0.88–0.94x. The
assumption was that the stdlib client understated the Mojo layer's parsing
edge. Under wrk the ratio is 0.72x — the stdlib client had been
*flattering* the executor, and the fix path derived from it was aimed the
wrong way.

## Fast-request tail under mixed load

The measurement the executor exists for: how fast is a *fast* request while
slow ones are in flight. Four threads measure `/` while two hammer
`/slow?ms=200`.

<!-- generated: asgi-executor -- edit bench/results, not this table -->
Source: [`asgi-executor-20260825T172549Z.json`](../bench/results/asgi-executor-20260825T172549Z.json) — 2026-08-25T17:25:49+00:00, commit `58a35ed` (dirty tree).
Environment: Python 3.13.6; Apple M4 (10 cores); seconds=8, threads=8.

| server | rps | fast p50 | fast p99 | errors |
|--------|----:|---------:|---------:|-------:|
| `m0serve` — asyncio executor | 22,597 | 267 µs | 376 µs | 0 |
| `uvicorn` | 23,642 | 173 µs | 407 µs | 0 |

Fast-request latency is measured while slow requests are in flight; rps and the two percentiles come from the same run, so they trade against each other rather than being separately optimised rows.
<!-- /generated: asgi-executor -->

**This is the row m0serve wins, and it is a narrow win stated narrowly.**
The fast-request p99 is ahead of uvicorn's — in this run and in every
recorded run — because awaits overlap on the loop and the Mojo acceptor
never runs application code. In the same run, uvicorn's p50 is better by
about 1.5x and its throughput by a few percent. Both facts come from one
run of one client, so they are a trade, not two independent scores.

The await-concurrency underneath is unambiguous in a way the percentiles
are not: eight concurrent 1.5 s awaits complete in 1.51 s on one loop with
zero threads, where the buffered bridge takes 12 s.

## Slow-view isolation

The strongest claim this project makes, and **the one without an
artifact.** A synchronous view that blocks holds the connections pinned to
its event loop; `--blocking-threads N` puts a pool of handler threads
behind each loop so it stops doing that. Measured, the fast-route p99 goes
from ~195 ms under two concurrent slow views to ~2 ms, in both execution
modes — a change of about 100x, and the largest effect recorded anywhere in
this repository.

Those numbers are hand-written in
[WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md#stage-b-measured-the-pool-removes-it).
They predate the artifact system, so the claim that most deserves a
machine-readable source is currently the one without one. That is stated
here rather than quietly omitted:

<!-- generated: mixed-workload -- edit bench/results, not this table -->
_No `mixed-workload` artifact has been recorded yet._ `scripts/bench_mixed_workload.sh` records one; the numbers quoted in the prose above predate the artifact system and are therefore the one claim on this page without a machine-readable source. Reproducing it is documented in [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md#reproducing).
<!-- /generated: mixed-workload -->

## What this page does not measure

- **TLS and HTTP/2.** m0serve has neither; terminate at a proxy, which is
  gunicorn's answer too. A comparison against servers that do would be
  measuring the proxy.
- **Real applications.** Every row above serves a bare handler, because a
  Django view's own work dominates and would hide the server difference
  entirely. That cuts both ways: it makes these gaps visible, and it makes
  them a smaller fraction of any real request than they look here.
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
