# The bus and its doors: fan-out across workers, Postgres NOTIFY and the names the server keeps — moved out of CLAUDE.md 2026-09-28

> A design note from the engineering record, moved out of CLAUDE.md on
> 2026-09-28 (review record C11) and kept as written. CLAUDE.md's "Runtime
> constraints" keeps each rule in a line or two and points here for the
> reason. The tick hook's costs are measured in
> [periodic-work-off-the-loop](periodic-work-off-the-loop.md).

## Fan-out is per process unless the application joins the bus

`M0_WORKERS>1` forks, and each worker gets its own subscriber registry; a
broadcast reaches other workers' subscribers only when everything shared is
created *before* the fork (listener, `BroadcastBus`, `SharedAtomics` id
slot) and each worker wires `enable_bus` + `bus_read_fd` + `sse_peer_frame`
→ `deliver_peer`. `apps/datastar_counter` is the reference; partial wiring
fails quietly (publishing without draining just fills peer channels).
Cross-worker ordering is best-effort — the redelivery filter keeps the newer
of two racing ids. The bus itself is transport-agnostic: `WSHub`
(`src/ws.mojo`) rides it for WebSocket fan-out the same way (`apps/ws_chat`
is that reference), with `sse_peer_frame` carrying encoded WS frames instead
of SSE events.

## ASGI applications on the bus

ASGI apps get cross-worker pub/sub as `scope["state"]["m0"]`.
`publish(channel, payload)` is m0pub's bus protocol from Python (one datagram
per worker channel, shared-atomic ids, best-effort); `subscribe(channel)` is
an async iterator, executor mode only — the loop forwards GRIP-named bus
frames to each executor as tag-3 submit datagrams and the shim fans them out
to per-connection asyncio queues (drop-oldest at 256). The loop grew a second
bus fd (`peer_bus_fd`) because the executor's chunk channel consumes
`bus_read_fd`; same codec, same drain, same `sse_peer_frame` entry. The bus +
`SharedAtomics` + env exports are created unconditionally pre-fork —
protocol detection is post-fork, and a single worker's own subscribers ride
its own channel (there is deliberately no separate local-delivery path).

## `--pg-listen`: the bus's second door

`m0pub` writes datagram descriptors the server hands down at fork, so a
management command, a cron job, a database trigger or `psql` publishes to
nobody — which textshelf's own realtime module records as a known
limitation. One `LISTEN` on worker 0 turns `pg_notify` into a bus frame: the
payload is three JSON string fields (`channel`, `event`, `data`), so the
listener needs no value scanner, and the frame is built by the same
`format_sse_event` every other publisher uses, so a client cannot tell which
door an event came through. `m0pub.notify_sql` builds the statement for a
caller that already has a cursor, without importing a driver into a
stdlib-only module.

**Refused on macOS wherever a worker is FORKED** — `--workers N`, and
`--reload`, which supervises even one worker — because libpq's connect
reaches GSSAPI, then Kerberos, then CoreFoundation, and Objective-C aborts a
forked child — measured as the worker killed by signal 9 and respawned until
the supervisor gave up, which is the same disguise the `_scproxy` entry in
[workers-signals-and-the-fork](workers-signals-and-the-fork.md) records. The
predicate asks what `main` calls `supervised`, not the worker count: testing
`workers > 1` alone let `--reload` through, doctor included.
`--spawn-workers` is the escape, as it is for Core ML. Both `--pg-listen`
refusals run BEFORE the bind and the fork: placed after it they ran in every
child and never in the supervisor, so a usage error read as a crash loop. A
host with no libpq exits 78 rather than serving without a listener, asserted
on the wheel's own binary.

Four rules, each with what broke or would break without it:

- **Worker 0 only** — the tick-owner rule; every worker would deliver its
  own copy.
- **`skip_worker` is -1** — nothing has queued the frame locally, unlike an
  in-process publish.
- **A malformed payload is refused and counted rather than guessed at** —
  the check that is uniquely the listener's, in `pg_envelope.mojo`. An
  `event` or `data` present as anything but a JSON STRING is malformed,
  because `parse_json_field` reads an object as `""` and a trigger's
  `'data', row_to_json(NEW)` reached every subscriber as an empty event,
  counted as delivered; `parse_json_string` is the reader that can say no.
  A reserved channel is refused here too, but `publish_to_channels` refuses
  the same names at the bus boundary, so that one is defence in depth and
  measured to be — removing it leaves the gate green.
- **A reset re-`LISTEN`s** — a reconnected connection is a new backend
  session listening to nothing, and a listener that skipped that would
  deliver nothing forever while logging no error. It also **drains once
  after connecting and after every reset**, because a notification read
  during the `LISTEN` round trip sits in libpq's queue where `poll` cannot
  see it (`test_notify.mojo` shows the mechanism; the listener-level race is
  not reproducible on demand, so no gate fails when that drain is removed).

The thread never attaches to the interpreter. Refused without `--realtime`,
which is what creates the bus. SPEC I22, `smoke-pg-notify`.

## The names the server keeps

**A channel name opening with `\x01` is reserved, and every publish boundary
refuses one.** That namespace is how the executor and pool threads address a
connection SLOT on the loop (`\x01<kind>/<slot>[/<lane>]` — queue these bytes
into its stream, unsubscribe it, re-point it), and
`WSGIHandler.sse_peer_frame` acts on it before looking at any subscription.
An application's channel is frequently user input, and `%01` in a form body
decodes to a real control byte, so the separation is enforced where an
untrusted name crosses in: `channel_is_reserved` in `broadcast.mojo` guards
`publish_to_channels`, and the shim's `_M0Broadcast.publish` and both copies
of `m0pub.publish_frame` spell the same rule. Internal senders bypass those
helpers — they build `encode_bus_frame` datagrams directly — which is what
makes refusing at the boundary sufficient. It was previously argued that an
HTTP header cannot carry a control byte and so a collision was impossible;
that covers the `M0-Channel` header alone, and an unauthenticated POST
reached another client's SSE stream through `publish()`.

**`/ws/message` is the server's path, not the application's.** Under
`--realtime` an inbound WebSocket frame is delivered as a synthetic `POST`
there, carrying `M0-Channel`/`M0-Slot`/`M0-Opcode`; the view must be
CSRF-exempt to accept it. A request for that path that arrived over the wire
is therefore answered 404 in `serve_local`, so only the synthetic one (built
in-process, bypassing `serve_local`) reaches the app. Without the
reservation the CSRF exemption and the trusted headers were available to
anyone who could POST.
