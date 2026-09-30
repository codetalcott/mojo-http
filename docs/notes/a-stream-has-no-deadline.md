# A stream has no deadline — 2026-09-30

A design note from the engineering record. D57 is the decision; SPEC A24
names it.

## The question

Pull request #412 gave a response a send deadline: `--idle-timeout`
between two sends that move bytes, the way nginx's `send_timeout` works
(SPEC A24). It left streams out on purpose. `_arm_send_deadline` skips a
slot the loop holds as SSE or as a WebSocket, so a client that stops
reading a stream keeps its slot until it leaves. The question was whether
streams should get a timer too.

## What was decided

**No timer** (the owner, 2026-09-30). Three reasons:

- **A stalled reader's slot costs what an idle reader's does.** A stream
  lives as long as its client. A deadline would not stop abuse, because a
  client can read one byte a second and never trip it. How many slots one
  client may hold is a connection-count question.
- **Memory is bounded.** A slot's queue stops at `MAX_PENDING_BYTES`
  (65536 bytes) in `SSERegistry` and in `WSHub`, and a frame that would
  pass it is dropped for that slot alone. `SSERegistry` holds Mojo SSE
  streams, `DatastarStream`'s, and both kinds of m0serve hold. Beyond the
  queue, a slot holds what the kernel's socket buffers hold.
- **A client that vanishes without a FIN is reaped by TCP**, because the
  heartbeat keeps bytes in flight. `M0_SSE_HEARTBEAT_MS` defaults to
  15000, and on that timer an SSE slot gets a `: heartbeat` comment and a
  WebSocket slot a ping. Nothing acknowledges those bytes, so the kernel
  retransmits them until `tcp_retries2` is spent and fails the socket
  with `ETIMEDOUT`. The loop then closes the slot, and the application's
  disconnect hook runs. That is the measurement below.

A stream the application writes through the chunk channel differs in two
ways. That is an ASGI application's stream, or a WSGI iterable a pool
thread streams. First, the loop puts no comment into its SSE, because an
event may span two chunks and a comment between them corrupts the event
(`_heartbeat` returns early for `slot_channel_stream`). Such a stream is
reaped the same way only if the application writes something on a
cadence of its own, as sse-starlette's ping does; a WebSocket on that path
still gets the loop's ping. Second, its sends wait for drain credit
([the WebSocket send window](websocket-send-window.md)), so a stalled
reader holds up the application's producer and no frame is dropped. None
of this path was measured here.

## The measurement

The server was m0serve built from `main` at 13c7d40, in the Linux
container `m0lin` (arm64, kernel 6.8.0), with `--realtime` and one
worker. It served a WSGI view that holds an SSE stream (`M0-Hold:
stream`) and one that holds a WebSocket (`M0-Hold: websocket`). A client
connected and read the head. Then `iptables` dropped every packet to and
from the client's port on `lo`, so the client vanished without a FIN. The
probe polled the server's own count every 0.2 s from the moment the rule
was in: `subscribers` or `sockets` in `/health`, and the server's socket
in `ss -tnoi`.

`tcp_retries2` was lowered to 5 in the container's network namespace,
entered from the VM with `nsenter -n`. The setting is per namespace: after
the write it read 5 inside the container and 15 in the VM's own namespace.

| arm | heartbeat | `tcp_retries2` | the slot closed after the vanish |
|---|---|---|---|
| SSE hold | 1 s | 5 | 14.44 s, 14.23 s, 14.57 s |
| WebSocket hold | 1 s | 5 | 14.48 s |
| SSE hold | 15 s, the default | 15, the default | 964.59 s |
| SSE hold, heartbeat off | 0 | 5 | held at 100 s |
| SSE hold, a live client with a zero window | 1 s | 5 | held at 100 s |
| the same client, then vanished | 1 s | 5 | 39.94 s |

With a 1 s heartbeat, the first unacknowledged heartbeat went out about
1.0 s after the vanish. The kernel retransmitted it with the timeout
doubling from 201 ms (`backoff:5`, `rto:6432` at the end) and gave up
about 13 s after that first send. Linux derives the give-up time from
`tcp_retries2` and a 200 ms base: 12.6 s for 5, 924.6 s for 15, checked
when a retransmission timer fires. In every reaped run the socket left
`ss` and the count reached 0 in the same 0.2 s sample.

At the defaults, the first unacknowledged heartbeat went out 15.0 s after
the vanish, and the slot closed 949.6 s after that, with the last
retransmissions 120 s apart (`backoff:15`, `rto:120000`). So a client that
vanishes holds its slot for up to about 16 minutes: the heartbeat period,
then about 15.5 minutes of retransmission. The close fell between two
heartbeats, 63.3 periods after the first, so the loop acted on the
kernel's error report itself. An SSE slot keeps read interest while it
idles, and the error wakes it.

**With the heartbeat off, the slot stays.** Nothing is in flight, so
nothing times out. `ss` showed the socket established with an empty send
queue and no timer for all 100 s, past the 60 s idle timeout, which a
stream does not have. m0serve sets no `SO_KEEPALIVE` on a connection, so
nothing else looks. Once the rules were removed and the client closed,
the count was 0 within 1.5 s.

**A live client that stops reading keeps its slot, by design.** It set a
4 KB receive buffer and read nothing after the head. Two publishes of
8 × 4000 bytes filled its window, and the server's socket went onto its
persist timer with 58 KB unsent. For 100 s the kernel's window probes were
answered: `timer:(persist,…,0)`, no probe outstanding. TCP keeps a
connection with a zero window open for as long as its probes are
answered, and Linux does. Dropping that client's packets then left the
probes unanswered. The count of unanswered probes rose to 5 and the slot
closed 39.9 s after the drop. So a reader that stalls and then vanishes is
reaped too, by the persist timer's probe limit, which is also
`tcp_retries2`.

Not measured:

- macOS. The packet filter and the TCP sysctls need root there.
- A stalled reader that vanishes, at the default `tcp_retries2`. The
  probe interval grows to 120 s, so the bound is longer than the
  retransmission case's.
- The chunk-channel streams above.

## What it costs

A reader that stalls and then resumes gets later frames with silent gaps.
A frame the cap refuses does not advance the slot's last-seen id, and a
later frame that fits does. The client's `Last-Event-ID` moves past the
gap, so a reconnect cannot replay the frames it lost. A WebSocket has no
replay at all, so a message the cap refuses is missed. For a stream of
whole states, such as `DatastarStream(send_latest=True)` and the blobs
demo, that is the right degradation: the next frame supersedes what was
lost. For a stream that is a log, it is not.

## What would retire it

An application whose stream is a log rather than whole states, and whose
clients stall. The answer then is to close a stream when its queue
reaches the cap, so the client reconnects and replays from its
`Last-Event-ID`, rather than to add a timer. Or a deployment that sees
live stalled readers holding slots.
