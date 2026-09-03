# The WebSocket send window — shipped 2026-08-28

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

The one path above that an ordinary application reaches, made to work
rather than merely to fail honestly. `websocket.send` had no window: an
app faster than its client filled the loop's 64 KB per-slot outbox and
every frame past it was dropped — 430,693 of 1,638,400 bytes under a
clean close frame. It waits for drain credit now, exactly as `_emit` does
for a streaming HTTP response, and the same flood arrives whole:
**1,640,193 bytes on the wire, byte for byte** (400 × 4 KB payload plus
4-byte headers, the handshake and the close frame).

Almost nothing new was built. The loop was *already* acking a socket's
drained bytes — a WS slot on an executor lane answers
`slot_channel_stream`, so the outbox drain's `ack_stream` fires — and the
shim was discarding those acks, because `_exec_credits[slot]` is only ever
seeded at HTTP stream start. Seeding it at `websocket.accept` and awaiting
it in `send` is the whole change.

One thing had to be got right: credit is charged in **encoded frame
bytes**, not payload bytes, because encoded frames are what the outbox
holds and what the loop acks back. Charging the payload drifts by the
header on every message — threefold on one-byte sends, which is exactly
the traffic that reaches a 64 KB cap first. `_ws_frame_bytes` mirrors
`encode_ws_frame`'s unmasked 2/4/10-byte header.

Guarded twice, sabotage-proven both ways. `apps/asgi_bare` has a
`/ws/flood` route and `ws_probe.py` a phase that stalls two seconds and
then asserts the exact frame and byte counts, so `smoke-asgi` carries it
in CI; ungated it reports "15 of 400 frames (61440 of 1638400 bytes)
arrived". And `shim_ownership.py` pins the arithmetic with no server at
all: one window of 65536 bytes holds exactly 15 frames of 4100, credit for
eight releases exactly eight more. Two sabotage entries — the `await`
removed, and the window never seeded — each fail that test.

Two limits it does not lift, both loud rather than silent now: a single
message larger than `MAX_PENDING_BYTES` is refused by the outbox, whose
cap bounds one frame as well as the queue; and a `--realtime` hold on a
WSGI lane gets no window, the loop not acking those sockets. Neither is
new, and `_ws_spend` returns without charging where there is no window
rather than pretending to gate.
