# The outbox sweep — taken, scoped (2026-08-29)

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

The second lever the inversion entry named. Every pass swept all 1,024
slots for a streaming one to drain, and the miss path — two flag loads
per slot, none set — measured **1.2–1.3 µs per pass** in isolation, on a
pass that carries one or two requests at low concurrency. The ceiling,
with the sweep skipped outright (`bench/results/outbox-sweep/`,
comparators within the clean band on every arm): hello **+3.5%** at c16
and +2% at c64, the inverted executor **+4.1%** at c16 — and the pump
**−2.9% rps at +6% CPU** at c16, ±0 at c256. That last row is the
finding: under the pump the microsecond was accidental pacing. A loop
thread that returns to `wait` a microsecond sooner finds fewer events,
batches fewer submits, and the executor thread takes more wakes per
request; at c256 the batches are large regardless and it makes no
difference either way.

So the gate is scoped. `OffloadLoopState.streaming_hint` is an upper
bound on the flagged slots — raised by the two sites that set a stream
flag (both in `_finish_response`), recounted by the sweep itself, never
touched by the many sites that clear one, so an under-count (a stream
nothing drains) cannot happen and an over-count costs one sweep — and
the sweep runs only while it is non-zero. EXCEPT when the pool says
`sweeps_every_pass`, which the pump wiring sets and nothing else does:
its loop keeps the per-pass sweep, and the reason is written on the
field. Realized (same day, comparators clean): hello **152.3k → 157.4k
at c16 (+3.3%, +5.5% per core)**, +1.3% at c64; the inverted executor
**59.3k → 62.0k (+4.6%)**, 69.6k/core; the pump 60.0k → 59.7k @0.98,
parity within noise, as intended. Guards:
the streaming smokes, sabotaged three ways — never sweep (counter and ws
fail), the SSE site not raising the hint (counter fails, ws passes), the
WS site not raising it (ws fails, counter passes).
