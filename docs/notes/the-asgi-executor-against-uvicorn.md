# The ASGI executor against uvicorn — 2026-08-24

> A design note from the engineering record, moved out of
> [WSGI_PERFORMANCE.md](../WSGI_PERFORMANCE.md) on 2026-11-06 and kept as
> written. The page itself now holds the current tables; the runs that led
> to them live here.

This note records the ASGI executor measured against uvicorn from
2026-08-24 to 2026-08-27: the stdlib-client gate, the `wrk` run that found
the executor wakeup-bound, pump batching, the `run_forever` pump, and the
pump inverted through `ExecutorPort`. Every figure is the record of its
date; the current comparison is on [Benchmarks](../BENCHMARKS.md).

## The ASGI executor vs uvicorn

The Phase-2 gate from [the design record](wsgi-vs-asgi-history.md) §8, measured
2026-08-24 with `poe bench-asgi` (Linux CI-shaped container, 4 logical
cores). **Client caveat first**: the container carries neither wrk nor ab,
so the harness is a stdlib `http.client` keep-alive loop on 8 threads —
the client is a large share of each round trip, which compresses every
server difference and makes the numbers meaningful only as ratios under
the identical client (and this container's absolutes swing ±10% between
runs; SERVER_PERFORMANCE.md records 1.7x swings between sessions).

`apps/asgi_bare`, single process each, 15 s rounds. "mixed" is 4 fast
threads measuring `/` latency while 2 threads hammer `/slow?ms=200`:

| target                              | hello rps | mixed fast p50 | mixed fast p99 |
|-------------------------------------|----------:|---------------:|---------------:|
| m0serve, asyncio executor           |     3,818 |        1.29 ms |    **2.87 ms** |
| uvicorn (asyncio loop, C httptools) |     4,192 |        1.13 ms |        3.27 ms |
| uvicorn (uvloop, C httptools)       |     4,344 |        1.02 ms |        3.34 ms |
| m0serve, WSGI `--blocking-threads 4`|     4,530 |        1.04 ms |        3.14 ms |
| m0serve, buffered bridge on pool-4  |     2,199 |        1.71 ms |        3.91 ms |

Three findings:

- **The mixed-tail half of the gate passes**: the executor's fast-request
  p99 beats uvicorn's in every run (awaits overlap on the loop; the Mojo
  acceptor never runs application code). The await-concurrency itself is
  unambiguous — eight concurrent 1.5 s awaits complete in 1.51 s on one
  loop with zero threads, where the buffered bridge takes 12 s.
- **Hello-world throughput stood at 0.88–0.94x uvicorn across runs.** The
  gap is *located*, not mysterious: the WSGI pool row proves the offload
  machinery itself clears uvicorn (4,530), so the remainder is the
  executor being ONE thread doing pump + scope hand-off + task + response
  assembly for every request, plus the four datagram syscalls and the
  cross-thread handoff each request pays — partially offset by the HTTP
  parse it never does. Per-request executor-side work already crosses the
  boundary once, C-API only (the environ-based spawn and its Python-side
  scope re-transform were replaced by direct method/path/query/headers
  hand-off, worth ~5%; the 10k-request RSS guard reads 20 KB–1.7 MB across
  runs — allocator/arena noise, not growth — against the 12 MB limit).
- **Recorded fix paths**, in expected-value order: run the bench under wrk
  where available (the stdlib client understates the Mojo layer's edge on
  parse-heavy traffic — see the header-count table above); N executor
  threads per pool on free-threaded builds (the datagram channel already
  delivers to any number of receivers — the same shape as
  `--blocking-threads`, but for tasks); further pump batching. None of
  these block Phase 3, which changes this path's shape anyway.

**The wrk run happened (2026-08-25), and it falsified the first fix path's
premise in the opposite direction**
([`asgi-wrk-hello-*.json`](../../bench/results/)): under wrk with browser
headers the ratio is **0.72x** (40.8k vs 56.4k on `--loop asyncio`), not
the stdlib harness's 0.88–0.94x — the stdlib client was *flattering* the
executor, not understating it. The decisive number is the cores column:
**the executor loses while consuming 0.89 cores.** It is wakeup-bound,
not CPU-bound — every request serializes through loop thread → submit
datagram → executor thread → completion datagram → loop thread, and both
threads idle between handoffs. That confirms **pump batching** (amortize
the wakeups across queued requests) as the one real lever, retires
"measure under wrk" as done, and is why `bench-asgi`'s throughput gate
read ≥0.8x rather than ≥1.0x until it was retired the same day batching
landed (below): the deficit is a located mechanism
cost, a red-by-design gate trains people to ignore red, and the gate that
carries the executor's actual claim — fast-request tail under mixed load
— still requires beating uvicorn. Ratchet the threshold back up if pump
batching lands, with the measurement that justifies it.

The uvicorn baseline row stays `--loop asyncio` per this repo's standing
benchmark configuration, with the uvloop row recorded in the same
artifact since 2026-08-27, because `uvicorn[standard]` is what a default
install runs and the number a developer's own machine produces should be
on the page; on 2026-08-27 it read 0.53x at 16 connections, against
0.75x for the asyncio-loop comparator.

**Which loop the executor itself runs on is a property of the
interpreter, and the record did not say.** The shim adopts uvloop where
the interpreter m0serve embeds can import it — and that interpreter is
the `python3` on `PATH` ([RUNNING.md](../RUNNING.md#install-and-start)), so `bin/m0serve` run
outside the venv embeds the system Python, finds no uvloop, and runs on
stdlib asyncio. Every executor row recorded before 2026-08-27T18Z was
measured that way, unrecorded; the artifact's `environment.python` names
the *recorder's* venv interpreter, which is not evidence of anything.
`bench_asgi_wrk.sh` now puts the venv first on `PATH` (what `uv run poe`
does) and stamps `executor_python` and `executor_loop` in the artifact,
and the generated block prints the loop. Measured on the same afternoon,
the choice is a wash for this design: the executor on uvloop against
the executor on stdlib asyncio is −3% at 16 connections (40,138 vs
41,474 rps), +3.5% at 64 (55,392 vs 53,527) and +4% at 256 (56,757 vs
54,569) — artifacts `asgi-wrk-conns-*.json` with
`executor_loop=uvloop`. The reason is the pump's shape, measured
directly (`.venv/bin/python`, 4,000 passes): the executor leaves the
loop every pass through `run_until_complete(batch())`, and one such pass
costs **38 µs on stdlib asyncio and 64 µs on uvloop** — uvloop is built
to be entered once and run forever, and pays libuv setup on every entry.
That number is not artifact-backed; it is reproducible from the two
figures with any Python that has both loops.

**Pump batching, built 2026-08-27: +5% at 16 connections, +19% at
256 — the row's concurrency decides what the lever is worth.** The lever
the wrk run pointed at was built in both directions (`TAG_JOB_BATCH`
submit datagrams sent at the bottom of a loop pass; `complete_many`
poking the loop once per pump pass) and measured in one session with
`scripts/bench_asgi_wrk.sh`, the script behind the `asgi-wrk-hello`
artifact that had none, the executor on stdlib asyncio for every row
here. Medians of three rounds, `wrk -t2 -d8s`, browser headers,
`apps/asgi_bare`; the uvicorn rows are re-measured in every run as the
drift control (their nine medians span 57.1–58.8k for `--loop asyncio`
and 76.0–84.4k with uvloop); artifacts `asgi-wrk-conns-*.json`, each
stamped with its `variant`:

| connections | executor, no batching (`0db9cb5`) | executor, batched (`a39df3b`) | Δ | ÷ `uvicorn --loop asyncio` | ÷ uvicorn + uvloop |
|---:|---:|---:|---:|---:|---:|
| 16 | 41,474 rps @ 0.90 cores | 43,581 @ 0.88 | +5% | 0.78 | 0.56 |
| 64 | 53,527 @ 0.99 | 57,135 @ 0.99 | +7% | 1.00 | 0.69 |
| 256 | 54,569 @ 1.02 | 64,763 @ 1.02 | +19% | **1.10** | 0.85 |

Three things the table says. The gain grows with concurrency because
the batch does: **a loop pass batches three submits on average at
sixteen connections** (counted; batches of sixteen occurred 18 times in
60,000) — keep-alive connections do not move in lockstep, each sends its
next request as its own response lands, so requests reach the loop in
small groups and the wakeup amortisation is ~3x there; at 256 the groups
are large and the two-thread handoff is paid once per many. The
executor's 16-connection deficit is therefore handoff *latency*, not
throughput: at 64 connections the batched executor is at parity with the
asyncio comparator and at 256 it is ahead, on 1.02 cores — both threads
finally busy. And the executor's rows swing more between rounds than
uvicorn's do (one batched 64-connection round read 49.6k against 57–59k
for the other two; a single-threaded uvicorn round never moves more than
2%) — two threads on a box with performance and efficiency cores land
differently run to run, which is why every figure here is a median of
three with the comparator re-measured beside it, and why a single-round
difference under 5% on this row means nothing.

**The pass itself was the next lever, measured as a prototype and then
landed.** With batching in, the executor's remaining per-request Python
cost was dominated by how the pump parked: every pass was a
`run_until_complete(batch())` — a Task for the pump coroutine,
`run_forever` setup and teardown — at **38 µs on stdlib asyncio** (64 on
uvloop), against 17 µs for parking in `run_forever` and having the first
queued event schedule `loop.stop()` for the end of the next iteration.
That shape (shim-only, no Mojo change; every event that used to be
`put_nowait` on a queue is appended to a list that stops the loop once
per pass) was measured in the same session as a prototype, on top of
batching, executor on stdlib asyncio — artifacts `asgi-wrk-conns-*.json`
with `variant` naming it — and is what the tree runs now:

| connections | batched | batched + `run_forever` pump | Δ | ÷ `uvicorn --loop asyncio` | ÷ uvicorn + uvloop |
|---:|---:|---:|---:|---:|---:|
| 16 | 43,581 rps @ 0.88 cores | 50,747 @ 1.01 | **+16%** | 0.90 | 0.64 |
| 64 | 57,135 @ 0.99 | 67,258 @ 1.00 | **+18%** | **1.17** | 0.83 |
| 256 | 64,763 @ 1.02 | 66,128 @ 1.02 | +2% | 1.15 | 0.88 |

The two levers are the same lever seen from two ends: batching lowers
the number of passes per request when the connections supply the
groups, and the cheap pass lowers the cost of each pass when they do
not — which is why the prototype gains most at 16 and 64 connections
and almost nothing at 256, where batching had already amortised the
passes. From the executor of the morning (no batching) the two together
are +22% at 16 connections, +26% at 64 and +21% at 256; the cores column
reads 1.01 at 16 connections for the first time, which is the executor
thread finally busy rather than waiting. The review the seam demanded
found one rule: a stop may be armed only while the pump itself is parked
(`_pump_parked`), never inside another caller's `run_until_complete`.
Without it, a request task completing inside `finish_executor`'s
post-pill gather scheduled the pump's stop, the gather ended with "Event
loop stopped before Future completed", and the application's lifespan
shutdown never ran — reachable with two requests that outlive the 5 s
drain and finish in different iterations (buffered request tasks are not
cancelled by the farewell; stream tasks are). `smoke-asgi`'s
outlive-the-drain phase pins it, and was verified to fail against the
unguarded prototype before it counted.

**Then the pump was inverted, and the executor thread stopped leaving the
loop at all.** The remaining per-pass cost — 17 µs of `run_forever`
entry and exit on stdlib asyncio, 45 on uvloop — goes away when Python
calls *into* Mojo instead of Mojo polling Python: `ExecutorPort` is a
Python type built with `PythonModuleBuilder` inside the interpreter
m0serve embeds (the manual documents only the extension-module route;
the builder works in-process because it uses the same `CPython` handle
the embedding does — a call measured at 50–76 ns), set into the shim as
`_port`, and every event that used to be queued for a Mojo pass is
`_port.dispatch(ev)`, handled at once inside the loop iteration that
produced it. The executor thread's Mojo side is now *build the handler,
build the port, park in one `run_forever`, flush, shut down*.
Completions still park and are poked to the loop once per loop
iteration, by a `call_soon`-scheduled `_port.flush` — batching without a
batch buffer, uvicorn's write-coalescing shape. Measured in the same
session as the rows above, `wrk -c16/-c64/-c256`, uvicorn re-measured
beside every row, artifacts `asgi-wrk-conns-*.json` with `variant`
naming the port:

| connections | `run_forever`+`stop()` pump, asyncio | port, asyncio | Δ | ÷ `uvicorn --loop asyncio` | port, uvloop | ÷ asyncio comparator | ÷ uvicorn + uvloop |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 16 | 49,236 @ 1.00 | 49,713 @ 0.98 | +1% | 0.93 | 60,419 @ 0.99 | 1.05 | 0.74 |
| 64 | 67,258 @ 1.00 | 60,875 @ 1.03 | — | 1.07 | 70,075 @ 1.02 | 1.20 | 0.84 |
| 256 | 66,128 @ 1.02 | 65,542 @ 1.01 | — | 1.13 | 72,011 @ 1.02 | 1.22 | 0.94 |

Two readings. On stdlib asyncio the port is the `run_forever`+`stop()`
pump within noise at 16 connections (49,713 against
49,236 in the same session) and at parity or ahead of
`uvicorn --loop asyncio` from 64 connections up — the 17 µs pass it
removed was already a small share there, and the 64- and 256-connection
pump figures are the earlier session's, so no delta is claimed for them.
On uvloop the difference is the whole point: the old pump paid uvloop's
45 µs `run_forever` entry on every pass and ran at 0.85 cores
(48,858 rps, 0.84x the asyncio comparator, the same session);
the port never leaves the loop, runs at 0.99 cores, and reads
60,419 — **+24% over the pump on the same loop, 1.05x
`uvicorn --loop asyncio` on the standing 16-connection row, 0.74x uvicorn
with uvloop** — and 0.94x uvicorn with uvloop at 256 connections. The
executor's `import uvloop` has been opportunistic since the executor
existed; this is the first shape in which it pays, and it is what a
venv with `uvicorn[standard]` in it gets for free. One round in three of
the eight runs was starved (the server at 0.5–0.75 cores with p50 four
times its neighbours' — the #151 binary's runs included), which the
medians absorb and the per-round artifacts show; the comparator's own
spread across the runs (53.4–59.0k for `--loop asyncio`) is why every
ratio here is against the comparator measured beside it.

The stdlib-client `bench-asgi` harness read the executor at **1.41–1.46x
uvicorn** the same afternoon, before and after batching alike, where
its 2026-08-25 artifact read 0.96x and wrk reads 0.73–1.10x; nothing on
the server side moved that way. It measures its own client, so its
throughput gate is retired: the ratio it prints is information, its
mixed-tail gate — the executor's actual claim — stays, and the wrk
artifacts are the record.
