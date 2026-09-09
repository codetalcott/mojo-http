# The loop inversion — in progress 2026-08-28

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

The handoff's item 1: run the Mojo loop's pass as a callback inside the
executor's `run_forever`, on one thread, so a request goes parse → app →
response with no datagram and no cross-thread wake. At c16 the pump batches
about one submit per pass, so every request pays two wakes today; removing
them is the whole bet, and the gate is unchanged — ≥1.0x
`uvicorn --loop asyncio` at c16 on stdlib asyncio, both loops measured, RSS
0 KB over 10k requests, `stress-asgi` N of N.

Landed so far, each a verbatim move with zero behaviour change:
`run_event_loop` is `prepare_loop` → `LoopState` + a `while` over
`_run_pass` / `_run_shutdown`. Established on the way: asyncio's
`KqueueSelector` fires `add_reader` on a kqueue fd (spiked live);
`backend.wait(0)` is a real non-blocking poll; field-projected `ref`
bindings of one `mut` struct pass exclusivity as separate `mut` arguments.

**Built and measured, first cut (2026-08-28, `M0_INVERTED=1`).** Correct
under every gate: `smoke-asgi` with 0 KB RSS, fan-out, Django ASGI,
FastHTML, `stress-asgi` 30/30 — on kqueue, and on **epoll** too, verified
in a Linux container before CI (`scripts/epoll_inverted_check.sh` under
colima, linux/aarch64: the smoke with 0 KB RSS, the recycled-slot probe,
`stress-asgi` 30/30 under 8 hogs). Two single-thread traps found and fixed on
the way — a producer waiting for the loop to drain the chunk channel was
waiting for itself (`_place_frame` runs a pass instead), and a direct job
overtook the slot's disconnect tag on the FIFO submit channel and stamped
the new task (`notify_disconnect` goes direct). Both showed as the
recycled-slot probe timing out with a clean log.

The bet was half right. Same session, uvloop executor, c16, two samples of
three rounds: inverted **59.1–59.6k rps at 0.87–0.88 cores** (p50 263 µs),
pump **62.6–63.1k at 0.98** (p50 237 µs), uvicorn asyncio ~57.5k and
uvicorn uvloop ~82.4k at ~0.99. The wakes were ~1 µs of CPU each and are
gone — that is the −11% of cores — but the pump's two threads were also
overlapping Mojo parse/write with Python app work, and at c16 wrk is a
closed loop (16 ÷ p50 is the rps), so +27 µs of serialized latency per
request is −6% rps. Per core the inversion is +5% (~67.6k vs ~64.5k
rps/core); against uvicorn asyncio it is 1.03x on uvloop. On stdlib asyncio
— the gate's own row, executor on the system Python 3.13 with no uvloop —
inverted **~54.0k at 0.89 cores** and pump **~53.4k at 0.99** against
uvicorn asyncio ~57.6k: +1% rps at −10% CPU, **+12% per core**, and BOTH
arms at 0.93x uvicorn asyncio, so the gate (≥1.0x at c16 on stdlib
asyncio) is met by neither. Artifacts, both arms and both loops:
`bench/results/inverted-ab/`. The default stays the pump. What would change the verdict is not fewer
wakes but less serialized work per request — the 2.05 µs parse and the
per-pass 1,024-slot outbox sweep were the two named levers — or a
workload where CPU, not closed-loop latency, is the bound.

**The parse lever, taken 2026-08-29, moved the gate's row for both arms
— and cleared it for both.** Same session, one binary per parser, the
executor on the system Python 3.13 with no uvloop (the gate's own row),
c16, medians of three, uvicorn asyncio re-measured beside every arm
(`bench/results/parse-lever-ab/`):

| executor | old parser | new parser |
|---|---|---|
| pump, stdlib asyncio | 55.7k @0.96 cores — 0.96x uvicorn asyncio (58.1k) | **60.1k @0.97 — 1.03x** (58.4k) |
| inverted, stdlib asyncio | 54.5k @0.89 — 0.93x (58.7k) | **59.7k @0.88 — 1.01x** (59.0k), 67.9k/core |
| pump, uvloop | 63.2k @0.97 — 0.77x uvicorn uvloop (81.9k) | **69.1k @1.00 — 0.83x** (83.4k) |
| inverted, uvloop | 60.2k @0.88 — 0.72x (83.7k) | **66.4k @0.86 — 0.79x** (84.0k), 77.2k/core |

The parser is the same 1.1 µs cheaper under all four, and on a closed-loop
client that is +8–9% rps on the pump and +10% on the inversion, on either
loop. What the lever did NOT change is the inversion's standing against
the pump: on throughput it is within noise on stdlib asyncio (59.7k
against 60.1k) and −4% on uvloop (66.4k against 69.1k), and per core it
keeps +9% and +12% (77.2k/core on uvloop is 0.92x uvicorn-uvloop's, where
its rps is 0.79x). So the ROADMAP gate as written — ≥1.0x `uvicorn --loop
asyncio` at c16 on stdlib asyncio — is now met by the pump on its own,
and the inversion's remaining claim is CPU, not rps. Whether that claim is
worth making it the default is the 0.15.0 question; the numbers are filed
either way. (The outbox sweep, the other named lever, was taken later the
same day — "The outbox sweep", below.)

**Evaluated the same day, and the answer is no — not for 0.15.0.** Two
more measurements settled it. At **c256** (uvloop executor, pump →
inverted → pump back to back on an otherwise idle machine, comparators
within 0.5% across all three arms; the `-c256-` artifacts in
`parse-lever-ab/`) the per-core edge is gone: pump 88.1k @1.02 and 87.3k
@1.02 around inverted 85.5k @0.99 — −2.5% rps, +0.6% per core, tails
identical. The +12% per core at c16 is the ~0.1 core of cross-thread
handoff the pump pays at light load, and its batching amortizes exactly
that away where CPU becomes the bound; the edge does not buy capacity.
(A first c256 run had put the inversion at 73k in one round with a
23 ms p99; the drift-control rows showed a 13% dent in the comparator
during that arm — another session on the machine — and the clean rerun
had no such round.) And the shutdown limitation above is a regression
the pump does not have. What the inversion honestly is on these numbers:
an efficiency mode for low-concurrency, tail-sensitive deployments —
−14% CPU and a better p90/p99 at c16, a worse p50, nothing at
saturation, one topology — not a throughput default. The bar for ever
promoting it: design item 6 with a smoke that pins the in-flight
shutdown case, and a saturation workload showing a gain, which no
measurement yet does. (The outbox sweep, the other named lever, was
taken the same day — the next entry — and is worth +4.6% to the
inversion at c16; it does not change this reading.)

## Design item 6, built 2026-09-08: the drain is stepped, not blocking

The shutdown limitation above is gone, and it was one line of shape. The
inverted `pass_` called `_run_shutdown` — the whole graceful drain, its
5 s budget and its 100 ms waits — from inside an asyncio callback. The
application's in-flight request tasks live on that same loop, so the
callback that was waiting for them to finish was the reason they could
not run: `active_count` never fell, and every in-flight request was
answered when the budget ran out rather than when it was done. The pump
does not have the bug because its drain runs on the Mojo thread while
asyncio keeps running on another.

`_run_shutdown` is now three functions in `event_loop.mojo` —
`_shutdown_begin` (leave accept sharing, close the listener, farewell the
streams, stop watching the shutdown pipe, stamp the deadline),
`_shutdown_drain_step` (ONE pass, with the blocking wait as a parameter,
returning True when the drain is over) and `_shutdown_finish` (the late
farewell, the last submit flush, the accept-sharing record). The blocking
composition is unchanged and is what every other topology runs:

    var drain_start = _shutdown_begin(handler, backend, st)
    while not _shutdown_drain_step(handler, backend, st, drain_start, 100):
        pass
    _shutdown_finish(handler, backend, st)

Inverted, the shim steps it instead (`_drain_and_stop`): `drain_step`
with a wait of 0, `await asyncio.sleep(0.001)` between passes so the loop
runs everything else it has ready, then the post-pill gather, then
`drain_finish`, then `stop()`. A millisecond rather than `sleep(0)`,
which would spin a core for the length of the drain; the drain's own
granularity was 100 ms before this, so 1 ms costs nothing and is 100x
finer.

Measured with `/slow?ms=1500`, SIGTERM 300 ms in, on both backends:

| | kqueue | epoll |
|---|---:|---:|
| pump (the reference) | 1.50 s | 1.51 s |
| inverted, before | 5.36 s | — |
| inverted, after | 1.50 s | 1.50 s |

Lifespan shutdown still runs in every arm, and the process exits within
about 10 ms of answering.

**The smoke the bar asked for is `smoke-asgi`'s, and it is deliberately
not the phase next to it.** The existing outlive-the-drain phase uses
`/slow?ms=5800` and `/slow?ms=6800` — requests that exceed the 5 s budget
on purpose — so a correct drain and a frozen one both end at the
deadline there and it cannot see this defect at all. The new phase sends
a 1.5 s request and asserts the answer arrives inside 3 s: a bound loose
enough that a slow shared runner will not fail it, and tight enough to
separate "finished" from "gave up". `smoke-asgi` already runs in both
loop modes on every pull request, so the inverted arm gates it. Proven by
sabotage: with `pass_` reverted to the blocking `_run_shutdown`, the
inverted arm fails with `a 1.5 s request was answered 5.39s after it was
sent`.

That is the first half of the promotion bar. The second half — a
saturation workload showing a gain — is met too, by measurements that
postdate the verdict above rather than by anything the inversion did:
see `bench/results/inversion-2026-09/` for the Mac artifacts (+16 % per
core at 256 connections) and the core-constrained sweep, where the
inversion serves 1.14x the pump and 1.42x uvicorn+uvloop on a single
CPU. What changed is the pump: the detached loop bought its throughput by
spreading over 1.6–1.8 cores, so its per-core efficiency fell as its rps
rose. This note's own reading — "or a workload where CPU, not
closed-loop latency, is the bound" — is what that turned out to be.
