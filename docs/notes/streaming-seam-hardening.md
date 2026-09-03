# Hardening the streaming seam — shipped 2026-08-27

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

0.14.0 shipped a fix for a hang that had been live all day: the shim keyed
a connection slot's executor state — credit window, event, disconnect mark
— by SLOT, while the loop recycles a slot the instant it closes a
connection, so a client that closed one stream and opened another on the
same slot could leave the loop holding a subscription with no producer.
The client saw a 30 s stall against a clean server log. It reproduced 8 of
11 `smoke-asgi` runs under twelve CPU hogs and **vanished under every
instrumentation that added a timer**.

What that left behind was a gap, not a bug: the fix was verified by an
ad-hoc reproducer in a scratchpad, so nothing in CI or `poe` would catch a
re-introduction — which breaks this repo's own rule that every guard is
sabotage-verified. And it was one instance of a shape, not a one-off: the
same seam had five more paths where a failure was *discarded* rather than
reported.

**The guards.** Two, because the failure has two natures.

`poe test-shim` is the deterministic half, and IS in CI. The shim is a
Python program inside a Mojo string, so `scripts/shim_ownership.py`
extracts `SHIM_SOURCE`, `exec`s it, hands it a real asyncio loop and a
socketpair per channel, and drives it exactly as the Mojo loop does —
8-byte job datagrams, 9-byte disconnect tags, 8-byte drain acks — with a
stand-in `_port` that records every event and spawns on `('job', slot)`,
which is what `ExecutorPort._dispatch` does. No server, no Mojo, no
interpreter embedding, no threads. Six tests, one per rule; on the shim
reverted to its pre-fix shape, four of the six fail. `--sabotage` (what
the poe task runs) reverts each rule in the extracted source in turn and
insists the suite fails for every one — the sabotage rule made permanent
instead of remembered, and a patch that no longer applies is itself a
failure, because that means a guarded line was renamed or deleted.

`poe stress-asgi` is the timing half, and is deliberately NOT in CI:
`chunked_keepalive.py` N times under CPU hogs, whose HTTP/1.0 probe closes
after its head so the keep-alive stream behind it lands on the same slot.
On the reverted build it failed on round 5 of 15 under 20 hogs, with a
silent server log; on `main`, 45 of 45 across three runs. Shared runners
are already loaded and cannot reproduce this reliably, which is exactly
why CI passed with the bug live — so it is a pre-release check
([RELEASING.md](../RELEASING.md)), not a gate.

**The other five paths, all the same shape.** A frame the streaming seam
could not place was discarded at five of six sites. Each is now terminal
and named, and each was measured both ways by forcing the failure:

| path | before | after |
|---|---|---|
| `b` stream begin dropped | a clean, **empty 200**; the log names only a downstream `KeyError` | 500 + close in 11 ms, one named line, the app's task cancelled through its own disconnect tag |
| `e` stream end dropped | the client hangs to its own timeout (12 s, curl exit 28); log silent | bytes delivered, then a close with no terminator (exit 18) in 13 ms, one named line |
| `s` chunk refused by the outbox | a 12 s hang, log silent | abort — truncation the client can see — one named line |
| `w` WebSocket frame refused | 430,693 of 1,638,400 bytes delivered under a **clean close frame**; log silent | 61,689 bytes then an abrupt close (1006), one named line |
| a stale drain ack | credits a recycled slot's new stream, over-committing the one shared chunk channel | clamped to the window |

The `w` case is the reachable one and was reproduced with an ordinary
client: an ASGI app sending 400 × 4 KB with no pause, and a peer that
completes the handshake and then stalls two seconds. `websocket.send` was
not credit-gated at all — unlike a response chunk, which is gated twice —
so the outbox filled. **That gap is now closed** (see below), which turns
the loud failure back into a working one; the tear-down stays as the last
resort. The `s` case is unreachable by construction today
(a stream may have at most one 64 KB window of un-acked bytes outstanding,
bytes are acked only once they have left the outbox, and the window equals
`MAX_PENDING_BYTES`); it is guarded because that invariant is implicit and
one constant away from breaking, and because being wrong about it silently
costs a stream that stalls for ever.

**A WebSocket could not be aborted at all**, which the measurements found
rather than the reading: the loop's abort path gates on `slot_sse`, and a
held 101 never sets it — `websocket_upgrade` builds an ordinary response —
so `abort_stream` on a socket was a silent no-op. Verified by isolating it:
with an outbound frame forced to fail, the socket closes immediately when
the abort knows about sockets and is still open eight seconds later when it
does not. Two lines in `event_loop.mojo` fix it — the gate reads
`slot_sse or slot_ws`, and a 101 records its generation in
`OffloadLoopState.stream_gen` AFTER the non-stream branch's `clear_stream`,
which was wiping it (the first attempt set it in the upgrade branch and the
abort was still dropped, on the generation check instead). Recorded in
NOTICE. The loop-side refusal (`queue_frame`) does not use it: a socket's
outbox is unframed, so `asgi_done` flushes what is queued and the loop's
`ended and not framed` branch closes — which is better, because those bytes
are real. And the tear-down has to be claimed once per stream: the producer
does not learn its connection is gone until the loop closes it, so one
flooding socket announced itself 336 times before `stream_lost` made it
once.

**Generation-tagged acks: considered, not built.** The real fix for a
stale ack is to carry the stream's generation in the ack datagram, as
every chunk frame already does. The clamp is exact for the damage that
matters — `credit + in flight == the window` is the invariant, and `min()`
keeps it true — and the residual is a transient over-credit of the global
budget that cancels itself on the next real ack (the refund is capped by
the slot's own in-flight count). Widening the ack wire format touches
`ack_stream`, the loop's owed-credit retry, the pool thread's stop-and-wait
poll and the shim's reader; it is worth doing when one of those changes
for another reason, not on its own.
