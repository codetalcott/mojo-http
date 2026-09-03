# Proven once, unloaded: an inventory of the gates with that shape

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

The v0.15.1 bug came from a shape rather than an oversight: **proven once, by
a smoke, and stressed not at all.** The measure of how little that guarantees
is exact. Reverting the `websocket.send` credit gate was caught on round 1 by
the extended `stress-asgi`, and passed the old chunked-only gate 30 of 30
under 8 hogs.

This is the inventory that shape asked for, taken 2026-08-30 by reading each
gate rather than by assuming from its name. Two of the three candidates turn
out to be better covered than the handoff that proposed them said; the third
is a real gap, and it is not the one that looked biggest.

**A verdict of "this one does not need it, because X" is a result.** It is
recorded here so it is not re-proposed.

## `--realtime` holds on a pool thread — was a real gap; now gated and MEASURED

**No gate anywhere takes more than one hold at a time.** `smoke-django-realtime`
opens two concurrent SSE subscribers; `smoke-django-realtime-ws` opens three
concurrent sockets, and its pool phase runs the whole probe behind two 1.5 s
views. But `realtime_probe.py` handshakes SEQUENTIALLY — every `handshake()`
completes before the next begins — so with four pool threads configured, the
number of holds in flight at once is one.

What contention would exercise, and the reason it is worth doing: a hold taken
on a pool thread travels to the loop as a reserved `h`/`H` frame on **one
`SOCK_DGRAM` bus channel per loop**, and N pool threads are N producers on it.
That is the same "one shared socket pair, N producers" shape whose per-stream
windows over-committed the ASGI chunk channel — twelve concurrent Django
`FileResponse`s were enough there — and the bus channel has no budget at all.
Its documented policy is fire-and-forget: a publish that meets a full buffer is
DROPPED on EAGAIN (`broadcast.mojo`), and a hold frame that meets one becomes a
503 (`handler.mojo`, deliberately, "a client holding a dead stream").

Both are documented, deliberate degradations, so the honest claim was never
"there is a race" — it was that **the threshold was unmeasured**. Nobody knew
how many concurrent holds, or how heavy a publish rate beside them, turns a
working server into one issuing 503s and silently losing broadcasts.

**Measured 2026-08-31, and the threshold is not reachable.**
`apps/django_realtime/hold_contention_probe.py` releases N subscribers off a
barrier so their hold frames reach the loop inside one window, waits for the
subscriptions to settle, then publishes into all of them:

| concurrent holds | pool threads | holds granted | publishes delivered |
|---|---|---|---|
| 4, 16, 32, 64, 128 | 4 | all | 100% |
| 64, 256, 512 | 16 | all | 100% |
| 512, fifty messages back to back | 16 | all | 100% (25 600 of 25 600) |

Nothing was refused and nothing was lost at any width up to 512 — against a
default `max_connections` of 1024, so this is half the server's whole capacity
— nor with the publish gap removed entirely, which is what pressures each
connection's outbox rather than the bus channel. Raising the pool from 4 to 16
producers changed nothing either. **The feared degradation does not occur
within the range this server can serve**, and that is the deliverable the
inventory asked for.

**The negative is only worth as much as the instrument**, so the probe's
self-test is part of the gate rather than a convenience: a bad token must read
as zero holds granted, and a publish to a channel nobody holds must read as
zero delivery. Both steer the real path rather than a special one, and
`smoke-realtime-holds` runs the self-test BEFORE the measurement — a clean
result from a counter that cannot register a failure would be worse than no
gate, because it would be believed. The gate itself asserts a floor (32 holds,
100% delivery) well inside what was measured, so it is a regression check
rather than a capacity test that reddens on a loaded runner. Row I18.

**One thing the probe cannot see, so the gate asserts it separately.** 32
concurrent holds pass IDENTICALLY with `--blocking-threads 0` — measured —
because taking them on the loop works too. The width alone therefore says
nothing about which path was entered, and a row claiming "from a pool" on that
evidence would be claiming a path the gate stops entering the moment the flag
is dropped. So `smoke-realtime-holds` greps the server's own BANNER for
`blocking-threads=4`, which is `stress-asgi`'s rule (assert the mode from the
banner, never from the variable) applied to a configuration instead of a loop
mode. Sabotage-verified by removing the flag: the smoke fails naming the
banner, not the holds.

## Mounts — adequately covered; do not re-propose

`smoke-hybrid` is not the single-shot gate its name suggests. Phase 3 streams
**256 KB concurrently from two ASGI mounts on two executors** — four credit
windows each, which is exactly the misrouted-ack failure the shared chunk
channel can produce — and then disconnects a client mid-stream on one mount and
requires the other to survive. Phase 3t repeats the whole thing under
`--threads`. Beside it, `hybrid_isolation.py` runs **four concurrent blocking
sync-mount views** and takes twelve samples against the async mount, reporting
its headroom on every run.

That is contention, on the seam that matters (per-lane credit, per-lane ack
routing), at a width chosen for the failure. No gap found.

## The handler pool — adequately covered; do not re-propose

`smoke-pool` runs **six concurrent blocking requests** and requires them to
spread across threads. `smoke-blocking-threads` puts two 1.5 s views in flight
and measures a fast request behind them, then abandons four in-flight requests
mid-job and requires every slot back. `sabotage-pool` reverts each `mojo_pool`
rule. `probe-pool` is the pre-release timing gate for the same path.

The one shape none of them has is slot RECYCLING under contention, which is
what produced the executor's slot-ownership bug — but that bug's home was the
shim's per-slot state, which pool threads do not have, and `stress-asgi`
already lands a WebSocket handshake on a slot a streamed connection just
released. Not worth a second gate on this argument alone.

## What the inventory cost, and what it bought

Item 1 of the same handoff — gating the idle timeout — found a live bug in
under an hour: the WebSocket close linger re-armed on every loop pass, so the
bound v0.15.1 relies on did not exist and a peer that never answered Close held
its slot for the life of the process. That is the case FOR this kind of work.
This inventory is the case for doing it by reading first: two of the three
candidates named in the same handoff did not need it, and building for them
would have produced gates that could not fail.
