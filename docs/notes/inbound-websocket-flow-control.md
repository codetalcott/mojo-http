# Inbound WebSocket flow control — shipped 2026-08-31

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

The outbound direction was credit-gated (`websocket.send` awaits its window)
and the inbound direction had no backpressure of any kind. Once the
executor's submit channel filled, `WSGIHandler.ws_message` discarded each
further message with a log line the client can never see -- the same "a full
channel means skip this frame" mistake the chunk channel's own rule forbids,
in the direction nobody had written a rule for. **2932 of 3000 lost** at
4 KB.

**The two directions were coupled, which is why the threshold was so low.**
The echo app awaits `send` inside its `receive` loop, so a client that stops
reading blocks that send on its OUTBOUND window -- which stops the app
calling `receive`, which stops the executor draining the channel that
INBOUND messages ride. The outbound backpressure produced the inbound loss,
and only one of the two directions was allowed to say "wait".

Both may now. The fix is the outbound design in mirror image, plus the one
piece a mirror does not give you:

- **A window, granted by the consumer.** `WS_IN_WINDOW` (64 KB) bounds the
  unacked datagram bytes the loop may have in flight toward one socket's
  `receive()` queue. The shim acks CUMULATIVELY as the application actually
  consumes -- a running total, not a delta, so an ack frame the chunk
  channel has to drop heals at the next consume instead of costing credit
  for ever. That is why this is the one frame on the seam that may be
  dropped without an abort.
- **Read suspension, which is what makes it real backpressure.** A handler
  that cannot forward returns False from the new `ws_message_take` hook, and
  the loop takes the slot off the read set. The socket's receive buffer
  fills, TCP advertises a zero window, and the CLIENT stops sending. Nothing
  else in the design propagates past the process boundary.
- **A parked queue, bounded by ONE `recv`.** Parsing is all-or-nothing: a
  single 4 KB read can yield many complete messages and the window can run
  out partway through. The remainder is parked and replayed in order. It can
  never grow past what one `recv_staging` produced, because no further bytes
  are read -- bounded by the receive buffer, not by the client's send rate,
  which is the property that makes it safe.

`take_ws_resumes` names the drained slots once per pass and the loop re-arms
their reads. Both new trait methods carry defaults (`ws_message_take`
forwards to `ws_message`), so every handler that is not the WSGI one is
untouched.

**A pool-held socket gets the same treatment for free**: its channel refusal
parks and suspends identically. It has no window, because pool threads send
no consumption acks -- the per-pass retry in `take_ws_resumes` is what
drains it.

**The gate's shape was chosen by measuring the wrong one first**, and this
is the part worth remembering. A client that reads CONCURRENTLY loses
nothing on the BROKEN build -- 3000 of 3000 echoed, zero drop lines -- so
the obvious "send a lot and count the echoes" test passes on the defect it
was written for. `scripts/ws_inbound_loss_probe.py` therefore sends WITHOUT
reading until the socket stops taking bytes (phase A), then reads and sends
together and requires every message (phase B). Phase A stalls on BOTH builds
-- socket buffers fill either way, 380 KB broken against 360 KB fixed -- so
it is a precondition, not the assertion. Phase B is the discriminator:

| build | phase A stall | phase B echoed | lost | drop lines |
|---|---|---|---|---|
| pre-fix | 380 KB / 93 msgs | 68 | **2932** | 2932 |
| fixed | 360 KB / 88 msgs | **3000** | **0** | 0 |

Verified by running the gate against a rebuilt pre-fix binary: exit 1,
naming the dropped messages. Holds at 8000 x 4 KB, 3000 x 16 KB and
20 000 x 64 B -- the last being the parked queue's hardest case, many
complete messages out of one read.

**And it uncovered an older bug, which is the part worth reading.** The first
Linux CI run of the new gate stalled -- 3 of 3000 echoed, and NO drops, so the
backpressure was working and the socket simply never resumed. Two fixes were
needed and only the first was mine:

- `slot_read_armed` is an INVARIANT every re-arm site in the loop consults,
  and suspending without updating it left the flag lying. On kqueue read and
  write are independent filters so nothing noticed; on epoll they share ONE
  registration, so the outbox drain's `add_write_oneshot` MODs the read
  interest away and nothing restores it. Setting the flag is not enough
  either: `_after_send`'s WebSocket branch re-arms on exactly `not armed`, so
  the socket's own echo would undo the suspension it had just asked for --
  and with it the parked queue's bound. Hence `WSState.inbound_suspended`: a
  DELIBERATE suspension, distinguishable from an incidental one.
- **The WebSocket read path took ONE `recv` per event and never re-armed** --
  A13's defect, in the one path nothing had ever sent a large inbound burst
  to. The body path has carried the fix and the reason for a long time ("a
  body larger than the staging buffer leaves bytes pending that will never
  raise another edge on their own"); this path was simply never asked.
  kqueue's level trigger hides it entirely. On epoll the edge is spent, and
  the stall needs the client to STOP SENDING -- which is precisely what
  inbound backpressure is for, so the feature exposed the bug that had been
  waiting for it. Re-armed only on a FULL staging buffer, so an ordinary
  small-message socket pays no extra syscall. Row I19.

Verified by building Linux/aarch64 in a container and running the gate there:
3 of 3000 before, 3000 of 3000 after, same tree. The first hypothesis (the
invariant alone) was wrong and the container said so -- macOS passed every
version of this, including the two broken ones.

**One consequence worth stating plainly.** A client that sends without ever
reading, against an app that echoes, now BLOCKS instead of losing data. That
is the correct end of a deadlock every echo server has -- uvicorn included
-- and the old behaviour only avoided it by discarding the client's
messages.
