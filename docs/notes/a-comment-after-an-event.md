# A comment after an event — 2026-10-29

A design note from the engineering record. SPEC I47 is the capability;
issue #641 is the report.

## What was seen

datastar-builder's drones game, on Fly.io with m0 0.13.0 and Datastar
1.0.4, in Safari 27.0.1 on macOS driven by `safaridriver`. Its build list
is a `send_latest` stream that writes when the list changes and re-sends
every 3 s. On a fresh page the list appeared 3393 ms in, where the first
frame took 588 ms, and every later change showed one change late.

Fly's proxy speaks HTTP/2 to the browser, and it forwarded an event of more
than 1015 bytes in two pieces, the first exactly 1015 bytes. Safari's
`fetch` body handed the page the first piece at once and held the second
until another piece arrived on that stream. Datastar reads `@get` streams
through `fetch`, so its parser held half an event, and the patch waited for
whatever the server wrote next. The same 5787-byte event, read in the game
page:

| Reader | Event complete | Next event (re-sent ~3 s later) |
| --- | --- | --- |
| `fetch` + `getReader()` | 3045 ms (1015 B at 142 ms, the rest with the next event) | 6044 ms |
| `EventSource`, same page and URL | 142 ms | 3045 ms |
| `fetch`, heartbeat at 250 ms | 355 ms (the rest with the next heartbeat) | 3106 ms |

Ruled out by the report: the server and the network (Node, reading raw,
had all 5787 bytes 79 ms after the open), compression (Fly sends a stream
without `Content-Encoding` whatever the request offers), Safari over
HTTP/1.1 with no proxy (each event in one piece), and Chromium, Firefox
and `EventSource` (each saw the event at once).

The mechanism is inferred, not read in WebKit's source: a network delivery
that lands before the page's next `read()` is buffered rather than
enqueued, and the buffer is flushed by the next delivery. The observation
holds either way: an event's second piece waits for a third.

## What the server does

Each event the server writes on an SSE stream it holds is followed by the
comment `: flush`, 50 ms later, unless another event was written to that
stream first (`M0_SSE_FLUSH_MS`; `0` sends none). The comment is the third
piece. A parser ignores a comment line, Datastar's and `EventSource`'s
alike, as it ignores the heartbeat.

- **One comment for the last event of a burst.** An event written while
  the one before it is still owed its comment moves the due: each event is
  the piece the one before it waited for. A stream whose events come
  closer together than the interval is sent the comment only after the
  last of them.
- **Late enough to be a piece of its own.** Written with the event, the
  comment would reach the proxy in the same read and leave in the same
  frame. 50 ms is past any proxy's read and well inside what a person
  notices.
- **Only where a heartbeat may go** (`_takes_an_out_of_band_frame`, SPEC
  D13). A stream the application writes through the chunk channel gets
  none, since an event there may span two chunks. A WebSocket gets none,
  since its frames arrive whole. An event still waiting on writability is
  followed once it lands, never interrupted: the slot is marked
  (`FLUSH_AFTER_SEND`), and `_stream_idle` owes the comment afresh when the
  event's last byte goes. A reader that has stopped reading holds no timer
  meanwhile. A compressed stream's comment goes through its context, as
  the heartbeat does.
- **One timer for the loop.** `TIMER_SSE_FLUSH`, in the range the header
  timer had before header deadlines were swept, is set for the earliest
  flush owed. Every flush is the same interval from its own moment, so none
  is due before the one the timer is set for, and a broadcast to a thousand
  streams sets the timer once. When it fires, the loop sends what is due,
  then sets the timer for the next due or deletes it. It is never left
  expired, because an expired timerfd is reported by every epoll wait
  after it.
- **A stream that opens with an event in its head's body** is owed the
  comment too. `send_latest`'s queued frame at open goes through the
  outbox drain like any other event.

## What it costs

A comment of 9 bytes per event, or per burst. A quiet stream pays it once
after each change and is otherwise left at the heartbeat's 15 s. A stream
at 10 Hz pays it after every event, 10 a second. That is more comments
than the 250 ms heartbeat's 4, and 90 bytes a second against the 19 KB a
seat already gets. A stream at 25 Hz pays nothing, since each event is
followed by the next inside the interval. The timer fires about once per
interval while any flush is owed, and its sweep reads one word per slot.

## What was not done

- **A faster heartbeat everywhere.** It costs every stream four writes a
  second forever, busy or idle, and it is what datastar-builder did as a
  stopgap. It stays available: `M0_SSE_HEARTBEAT_MS` is still the
  keepalive's knob, not this one's.
- **`X-Accel-Buffering: no`**, which the server already sends and Fly
  ignores, and **`Content-Encoding: none`**, since Fly does not compress
  a stream.
- **A size threshold.** The 1015-byte first piece is one proxy's read and
  one browser's window. A comment after every event costs little, and it
  does not depend on either.

## What is proved, and what is not

`smoke-sse-flush` proves the wire on every pull request against the
counter demo, at a 400 ms interval so the lower bound is the server's and
not the runner's. The opening and each of three events are followed by one
comment, no sooner than half the interval after the request that caused
it, and then by nothing. At 0, nothing follows. The unit tests in
`test_slot_lifecycle.mojo` drive the drain and the timer over epoll's timer
semantics, and sixteen reverts of the rules were each caught by one of
them.

Not proved here: that Safari, behind Fly's proxy, now reads each event
whole. Only a browser behind that proxy can show it, and the measurement
above is the one to repeat with the heartbeat back at its default.

Not measured yet: what the comment costs a broadcast. Each comment is a
send of its own, and the blobs demo broadcasts at 10 Hz, every frame more
than the interval after the last. So its viewers now take two sends a
frame where they took one, and `bench_blobs_modes.py`'s CPU per viewer is
the figure to take again.
