# Pacing the pump's loop thread

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

What the sweep measurement exposed: at c16 the pump's throughput depends
on how long its loop thread spends per pass, in a way that an accidental
1.2 µs improved by 3%. An *explicit* pause before flushing a partial
batch — spin N ns, optionally re-poll once and fold the new events'
submits into the same datagram — is the deliberate form of that, and
tunable where the sweep was not.

**Measured the same day, as an experiment patch, and recorded rather
than built** (`bench/results/outbox-sweep/pacing/`, fourteen arms, pump,
c16, stdlib asyncio, uvicorn asyncio within 58.3–59.3k on every one):

| pump's loop thread, per pass | rps @ cores |
|---|---|
| the sweep (today) | 59.95k @0.97 |
| no sweep, no pause | 58.70k @1.01 |
| spin 500 / 1000 / 2000 / 4000 ns **before a partial flush only** | 58.6–59.0k @0.97–1.01 |
| the same, then `wait(0)` and fold the new events into the pass | 58.9–59.3k @**1.05** |
| spin 1200 / 2000 ns **on every pass** | **60.04k / 60.13k @0.97** |
| the same, with the re-poll | 55.6–55.8k @**1.08** |

Two things settled. The sweep's effect is a delay on *every* pass —
including the completion-only passes that write responses and park —
not on the pass that has submits to flush: pausing only before a
partial flush is too late, because by then the batch is whatever the
previous `wait` returned, while a pause after writing responses lets
the clients' next requests arrive before the loop parks. An explicit
per-pass spin of 1.2–2 µs reproduces the sweep to within noise, and no
longer pause improves on it. And the re-poll is simply worse: a nested
pass costs the loop thread more than a merged batch saves the executor.
So the pump keeps its pacing through the sweep it already runs, which
is neither prettier nor uglier than a spin and needs no knob; the
finding is that ~2% at c16 (and nothing at c256) is what per-pass
latency on the pump's loop thread is worth, and that it is already
collected.

The design, so it is not re-derived:

- **Scope:** unmounted single-executor ASGI only — the benchmark shape.
  Every other topology stays on the pump. Behind `M0_INVERTED=1` until the
  gate passes, so the A/B is one environment variable.
- **Submit:** a defaulted `HTTPService` hook (`direct_job(slot) -> Bool`,
  default False — Phase 1 made adding one non-breaking). The loop still
  parks the request; on an executor lane it asks the handler first and
  sends the datagram only when it declines. `WSGIHandler` in inverted mode
  answers by running the port's job branch, factored into one function
  shared with the port.
- **Complete:** the port keeps parking responses; its per-iteration
  `_flush` calls `service_direct_completions[T,B](handler, backend, st,
  slots)` — the per-slot body of `_service_completions` — instead of a
  datagram. The port grows the loop state's and backend's addresses; the
  backend is the platform one, no `DetachingBackend`, because `wait(0)`
  never blocks attached.
- **The ordering rule that makes it safe:** a stream's begin frame rides
  the chunk channel and is drained by a PASS, while its head is a direct
  completion. `_flush` therefore runs a pass first and completions second,
  or a head could precede its own begin frame — the recycled-slot hazard
  the 0.14.1 rules exist for. Deterministic on one thread.
- **Driver:** `add_reader(kq_fd, _on_mojo)` → `port.pass_()`, plus a 1 Hz
  `call_later` for the idle sweep, the date cache and the heartbeats,
  which assume a wake per second. Acks and credit unchanged.
- **Shutdown — designed, not built, and deliberately skipped
  (2026-08-29):** `_run_shutdown`'s drain waits in `backend.wait`, which
  inside an asyncio callback blocks the very tasks it waits for. The
  design was to poll the drain from `call_later` passes until
  `active_count == 0` or the 5 s budget, then `loop.stop()`. The first
  cut runs the drain as it is, blocking, and the consequence is measured:
  with a 1.5 s request mid-await at SIGTERM the pump answers it at
  1.50 s, the inversion at **5.30 s** — the drain deadline, after which
  the shim runs the in-flight tasks to completion and the response goes
  out. Not dropped, but any stop grace under ~6 s drops it. The
  reshaping is half a day (split `_run_shutdown` into prepare / step /
  finish as `run_event_loop` was split, drive the step from a
  `call_later` cadence) and buys that only under the flag, which nothing
  runs in production; it is the inversion's promotion bar, not 0.15.0
  work. Until then an inverted server wants a stop grace of 10 s or more
  (`docker stop`'s default), and the comment beside the flag in
  `m0serve.mojo` says so.
