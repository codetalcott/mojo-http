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
