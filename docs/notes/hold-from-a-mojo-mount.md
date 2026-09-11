# An SSE hold from a Mojo mount — shipped 2026-09-11

> A design note from the engineering record. The phase-3 probe of the
> application layer's plan, and what it lifted; the probe's question was
> whether a `MojoPool` thread can take the hold a WSGI pool thread takes.

**Where this comes from.** The application layer (SPEC section N) had ten
capabilities proven by demos and no real application. textshelf, which
runs on this server in production, was the named candidate, and its SSE
views the named path — and D18 stood in the way: `MojoPool` refused every
streaming response, because a stream begun on a pool thread has no
producer the loop drains ([mojo-handler-pool](mojo-handler-pool.md)). The
WSGI pool had already found the way around that for its own threads: a
hold has no producer of its own — the loop drains it from its registries
and the bus feeds it — so a WSGI pool thread decides the hold where it is
and sends the loop a reserved `h` frame on the loop's own bus channel,
which the loop's handler turns into a subscription
([hold-on-a-pool-thread](hold-on-a-pool-thread.md)). The plan asked for a
day's probe: can a Mojo pool thread send that same frame, and does the
loop's handler subscribe the slot for it?

## The probe

Two edits, one run. `_pool_serve` in `mojo_pool.mojo` gained a branch
that read the `M0-Hold`/`M0-Channel` headers off the handler's response,
rewrote it into the stream's head and sent the `h` frame to
`OffloadPool.hold_notify_fd` before completing; `m0serve`'s own
`MojoMount` gained a `/hold?channel=` route returning those two headers.
Served `--mount /=djangoproj.wsgi:application --mount /native=mojo
--realtime --blocking-threads 2`, a client on `/native/hold` received the
Mojo view's head, then two events published from the Django mount's
`/publish` view, numbered 1 and 2 by the shared counter, and SIGTERM
exited clean. Nothing on the loop side had to change: the `h` branch of
`WSGIHandler.sse_peer_frame` reads a slot number, not a lane, and the
loop finishes a held head from a pool lane as a hold (no ack pair on the
lane, so `slot_channel_stream` is false and nothing is chunk-framed). The
probe took an hour; D18 retires, superseded by D22.

## What was lifted

- **The hold module is in the fork.** `packages/m0-wsgi/src/hold.mojo`
  became `packages/m0-http/lightbug_http/hold.mojo`, unchanged but for the
  frame sender joining it (`send_hold_frame`, the WSGI handler's
  `_send_hold_frame` under a public name). One copy of the rewrite is what
  keeps the WSGI path and the Mojo path from drifting; it sits beside
  `broadcast.mojo` and `offload.mojo` because it is server mechanism of
  the same kind, and imports nothing of the framework's. `m0_wsgi` exports
  every name it did, from the new place. The reserved url builder the
  frame uses is `reserved_stream_url` in `broadcast.mojo`, beside the
  predicate that refuses that namespace at every publish boundary;
  `asgi_stream_url` in the WSGI handler is now that function under its
  old name.
- **A `MojoPool` thread takes an SSE hold**, and only where the loop wired
  a channel (`hold_notify_fd`, which `m0serve --realtime` sets). The
  rules are the WSGI thread's: read the request's `Last-Event-ID` before
  `func` consumes it; take the hold with `take_stream_hold`, so a
  `websocket` instruction degrades rather than promising a 101 nothing
  here performs; send the frame BEFORE the completion, because the loop
  drains its bus channels before it finishes a streaming head and that
  order is what puts the subscription ahead of the head; a frame the
  channel will not take is a 503, not a head; stamp `x-worker` as the
  WSGI hold does. The refusal narrows to what it was always about: a
  streaming response that is not a hold is still 409, and now has a unit
  test.
- **The view is a Django hold view's twin.** `m0serve`'s `MojoMount`
  keeps the `/hold` route: two headers on an ordinary response, the body
  as the head of the stream. It is unauthenticated, as
  `apps/django_realtime`'s publish is, and its docstring says so; a real
  mount decides here whether the connection may be held and which
  channel it joins.

## The gate

`smoke-mojo-mount-hold`, on every pull request. Each phase pins one thing
that was silent-wrong or absent before the lift: the hold delivered at all
(the frame arriving before the head), the reconnect cursor reaching the
subscription (`Last-Event-ID: 3` while the counter stood at 1 — ids 2 and
3 muted, 4 delivered), the hold drained as a hold (comment heartbeats, no
`Transfer-Encoding`, the `smoke-django-realtime` phase-6 shape), the slot
released when the client leaves, the head answered while both Python
threads are inside 1.5 s views (recorded by `emit.py` as
`mojo-mount-hold-head-s`), and the degrade without `--realtime`.
`test_mojo_pool.mojo` holds the unit forms — an unheld stream is refused
409 and marked raised; a hold consumes its headers, becomes the head, and
its `h` frame naming the slot, the cursor and the channel is on the
loop's channel by the time the completion is — and `poe sabotage-pool`
reverts the send and the refusal in the source and insists the test fails
for each.

## What it found about the textshelf path

Two things the plan did not know, both read from textshelf's own tree.

**textshelf already holds.** Its production command is `m0serve
config.wsgi --realtime --blocking-threads 8`, and its three SSE views —
annotation events on a submission or a document, and a user's
notifications — are hold views: each returns `hold_stream_response`,
Django's spelling of the same two headers. REAL_APP_VALIDATION's 2026-09
finding 2, the `LISTEN/NOTIFY` generators holding pool threads, was fixed
in the application by that conversion, on the WSGI pool hold this note's
mechanism is the twin of. So the mount does not fix a stall; what it
offers that path is the layer's first real application.

**Each of those views authorizes before it names its channel.** Every one
checks `request.user.is_authenticated` and a membership query, and the
channel names carry the object id (`notate_submission_<id>`,
`notifications_user_<id>`). A Mojo view has none of that: no session, no
ORM. The path onto the mount therefore needs the authorization to travel
— Django decides, as it does today, and hands the browser a stream URL
into the mount carrying a grant the mount can verify without asking
Python: the channel, an expiry, and a signature. That signature is an
HMAC-SHA256 over a key the two sides share, which is the primitive the
login row (N13) needs first as well; `m0-core` has neither it nor
SHA-256 today. Nothing else about textshelf is a compute shape — no
embeddings, no numpy — so the alternative the plan named, a compute path
first, does not exist there.

Two deployment facts follow and are the owner's to weigh. A Mojo mount is
a compile-time type, so textshelf on the mount is a binary textshelf's
own repository builds from this tree with its mount struct, where today
it installs the wheel. And the soak entry that turns the application
layer's milestone to MET is that binary serving textshelf under the
driver, not this note.

## Refused, and what would retire each

| Not done | Why | What would retire it |
| --- | --- | --- |
| `--realtime` on a server whose only mounts are ASGI and Mojo | `_realtime_without_wsgi` still refuses it; a Mojo mount can now take a hold, so the refusal is wider than its reason, but the executor's loop handler taking an `h` frame beside its own streams is unverified | a smoke that holds on the Mojo mount beside an ASGI mount, and a publish from the ASGI application reaching it |
| A WebSocket hold from a Mojo mount | the pool thread would have to perform the 101 and inbound frames would have to reach it as `TAG_WS_MESSAGE` datagrams, which `mojo_pool`'s `next_job` skips by design | a Mojo application that needs a socket rather than a stream |
| A hold from a Mojo server binary with no `m0serve` | the loop handler that reads the `h` frame is `WSGIHandler`'s; a standalone Mojo server has no handler that turns the frame into a subscription | a second loop handler implementing the `h` branch, pulled by such a binary |

## What is not claimed

Nothing here is a throughput measurement; the one number the smoke
records is the hold's head latency behind two busy Python threads, on one
laptop, and it is recorded rather than asserted beyond its limit. The
application layer's soak is still NOT MET — this note is the mechanism,
not the application — and `poe milestones` says so. The ordering
argument (frame before head) rests on the loop draining its bus channels
before finishing a streaming head, which [pool-ring-handoff](pool-ring-handoff.md)
established for the WSGI thread's frame; the Mojo thread sends on the
same channel in the same order and inherits it rather than re-proving it.
