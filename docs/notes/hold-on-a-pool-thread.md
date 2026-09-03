# Hold on a pool thread: the refusal that keeps `--realtime` off real applications

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

**Where this comes from.** Serving `textshelf`
([REAL_APP_VALIDATION.md](../REAL_APP_VALIDATION.md), 2026-08-26) showed the
realtime mode is not deployable for the application class it exists for,
and the reason is a refusal this server makes on purpose: `--realtime`
refuses `--blocking-threads`, so a held-stream server runs its views on the
loop, and one slow view then stalls every held stream on that worker along
with every other request. Measured on textshelf with eight 1.5 s views in
flight (what an AI call or a typst render looks like to a server), fast-path
p50, plus what 200 held SSE streams cost:

| shape | fast path p50 | 200 held streams |
|---|---|---|
| `--realtime --workers 4` | **1 543 ms** | +2 MB RSS, no Python state, no DB connection |
| `--blocking-threads 4 --workers 4` | 0.3 ms | cannot hold |
| `--mount /=wsgi --mount /rt=asgi`, 4 × 4 | 0.7 ms | within noise; one Postgres connection each in production (their `psycopg.AsyncConnection` per subscriber, not ours) |
| daphne — their `fly.toml` | 4.9 ms | +94 MB |
| gunicorn, 2 workers — their `Dockerfile` | 6 015 ms | cannot hold |

One laptop, scratch SQLite, a 120-request burst at concurrency 16: relative
numbers, not a benchmark. Two things are true at once. **M0-Hold is by far
the cheapest way to hold a stream** — 2 MB per 200, no per-stream Python,
no per-stream database connection, and the retrofit that reaches it was
+52/−293 lines. And **choosing it costs the pool**, which is the fix for the
hostage pathology the README leads with. The feature the pool would protect
reintroduces the pathology the pool cures. Workers mitigate at N× RSS (491 MB
for four of textshelf), and only until the N+1th slow view.

The hybrid mount already gets an application like textshelf most of the way
with no code change — its existing async SSE views on the executor at `/rt`,
its sync bulk on the pool at `/`, 0.7 ms isolation, +6 MB for the second
mount (503 MB against 497) — and that is the recommendation today. What it
cannot do is combine the pool with M0-Hold, which is the shape textshelf
actually wants: four of its six SSE endpoints are pub/sub (subscribe, then
wait for events published elsewhere) and convert to a hold outright; the
other two (`ai/streaming.py`) are request-scoped generators, the view being
the producer, and belong on the executor. **Protocol is the wrong axis;
stream shape is the right one**, and one process should serve both shapes.

**1. `--realtime` with `--blocking-threads`.** The refusal's reason is
exact: `take_hold` runs inside `WSGIHandler.func`, which under the pool
runs on a pool thread against that thread's own `SSERegistry`/`WSHub`, while
the loop calls its hooks on the loop's handler. The executor solved the
identical problem, and its seam is the one to reuse: it does not subscribe
from the producing thread. It sends a reserved begin frame
(`\x01b/<slot>/<lane>`) that the *loop's* handler turns into a subscription
in `sse_peer_frame`, ordered ahead of the head completion. A pool thread in
realtime mode would do the same — decide with `take_hold` where it is, then
publish a new reserved kind (`h` for an SSE hold, `H` for a socket; payload
the channel and the request's `Last-Event-ID`) onto the loop's bus channel,
which every worker already has (created pre-fork; `m0pub` writes to it from
Python), and complete with `sse_streaming` set. The loop's handler
subscribes the slot in its own registries; the drain, the heartbeats, the
disconnect hooks and the bus fan-out do not change. The WebSocket half is
harder. The 101 must be computed from the original request, which the pool
thread has, so it performs the upgrade and completes with the 101 — the loop
already switches a slot to frame mode on that wire signal. But inbound
frames are today delivered by `ws_message` running the Django view **on the
loop thread**, and under a pool they must not; they need to reach a pool
thread as a tagged submit datagram the way the executor receives them
(`_TAG_WS_MESSAGE`), which the pool's `next_job` does not decode. Stage it:
SSE holds first, which is what textshelf's four pub/sub endpoints need and
what the numbers above are about; sockets second.

**2. `--realtime` with `--mount` — shipped 2026-08-26, and it came before
the socket half.** Re-measuring `textshelf` after stage 1 settled the order
([REAL_APP_VALIDATION.md](../REAL_APP_VALIDATION.md), *Revisited*). Holds and
an ASGI mount in one process is what a mixed application needs, because
stream *shape* decides where an endpoint belongs: its four pub/sub
endpoints convert to holds, while `ai/streaming.py` is a request-scoped
generator whose view is the producer and which no hold can carry. That
application opens no WebSocket against its own server, so the socket half
buys it nothing. The refusal was broader than its reason — an inbound
WebSocket message was said to have no defensible destination among several
urlconfs, and an SSE hold has nothing inbound to deliver — so it first
narrowed to the socket half, and then (3) removed that too. What is refused
now is only `--realtime` on a server where no mount could take a hold.

**What it took was not the ordering work this entry expected.** The loop
already had the answer in `OffloadPool.slot_lane`, which `submit` stamps
with the mount a job went to, and a lane has a drain-ack pair exactly when
an executor serves it. So `slot_is_executor(slot)` replaced
`stream_active()` at the four places the loop decided what a streaming slot
was, and "is this an ASGI stream?" stopped being a question about the
server and became one about the slot. Getting it wrong is silent, which is
what `smoke-django-realtime` phase 6 exists to catch: a held stream drained
as an executor's is chunk-framed with a `Transfer-Encoding` it never asked
for, acked to an executor that never issued the credit, and denied the
comment heartbeat that keeps it alive through an idle proxy — while still
delivering, so nothing looks wrong until a proxy times the stream out. The
phase holds one stream of each kind on one loop and asserts the heartbeat
and the framing on the held one.

That makes the hybrid's proposition whole for a mixed application: holds
for its pub/sub streams, the executor for its generator streams, the pool
for everything else, one process.

**3. The socket half — shipped 2026-08-26.** A pool thread performs the 101
(the client's key is in the request it holds) and sends an `H` frame
carrying its own LANE; the loop records `hold_lane[slot]`, and an inbound
frame rides the submit channel back as a `TAG_WS_MESSAGE` datagram — the
executor's shape plus the channel, because a pool thread's registries are
empty and the name the socket joined with has to travel with the message.
`next_job` decodes both shapes off one channel, told apart by length (a job
is exactly 8 bytes, a message at least 12), into a caller-owned buffer so a
WebSocket's size is not charged to every request.

Two things were not obvious until they broke. **The pool question must be
asked before the executor one**: on a mixed mounted server `asgi_notify_fd`
is set for the ASGI mount, so asking that one first hands every socket's
message to an executor that never accepted the connection — which is what
happened, and what `smoke-django-realtime-ws` phase 4 now catches. And
**`NOT_POOL_HELD` cannot be -1**, because -1 is a real lane (the unmounted
pool); a sentinel a real lane can equal routes an executor's socket into a
pool. Phases 3 and 4 run the whole socket probe — handshake, fan-out, relay
through Django, channel isolation — against a pool and against mounts, and
phase 3 adds what the pool is for: the probe runs **+13 ms** behind two
1.5 s views, against its own ~4 s baseline.

With that, `--realtime` composes with everything it used to refuse, and the
`ws_message` limit the design doc recorded — the view runs on the loop
thread — is retired: under a pool it runs on a pool thread, on the mount
that gated the socket.

**What has to be established before (1) is built**, each a place the
design could be wrong:

- The begin-before-head ordering argument (`asgi_executor.mojo`,
  `stream_start`) is made for the chunk channel. A hold frame would ride
  the bus channel — a different descriptor, drained in a different branch
  of the same loop pass — and whether the same guarantee holds there has to
  be shown, not assumed: a subscription that lands after the head
  completion is a stream the loop closes as ended, the wrongful-early-close
  race the executor's ordering exists to prevent.
- `x-worker`, `Last-Event-ID` seeding (`request_last_event_id`) and the
  `/health` subscriber counts all assume the subscribe happens where the
  request is; each moves to the loop side, and `smoke-django-realtime` must
  not notice.
- Under `--threads`, each loop has its own pool and its own handler; the
  bus descriptor a pool thread writes to must be *its* loop's
  (`peer_bus_fd`), or the hold lands in another loop's registry against a
  slot that means nothing there.
- The `_health` docstring already concedes the premise — its counts are
  answered in Mojo because they "have to stay readable while a slow view
  has the interpreter busy" — which is the hostage problem stated from the
  inside. After (1) that sentence is about the pool, not about the loop.

**Stage 1 shipped (2026-08-26): SSE holds on pool threads.** `--realtime
--blocking-threads N` is accepted; a pool thread takes the hold and sends
it to the loop's registries as a reserved `h` frame on that loop's own bus
channel (`OffloadPool.hold_notify_fd` → `ThreadContext.hold_fd` →
`WSGIHandler.hold_notify_fd`; `sse_peer_frame` subscribes), before the
response completes. The ordering question resolved in the design's favour
without needing a same-pass guarantee: with no executor there is no
end-of-stream signal for the loop to misread, so a frame drained a pass
late is a stream that starts a pass late, and publishes are FIFO behind it.
That is also why the `--mount` refusal stays — an ASGI mount brings the
signal — and why a WebSocket hold under the pool is a 409 that says so,
until inbound messages can reach a pool thread. `smoke-django-realtime`
phase 5 pins it: two 1.5 s views in flight, a subscribe and a publish still
land well inside a second, heartbeats keep coming, a vanished client is
unsubscribed, SIGTERM exits 0. Under `--threads` each loop's pool writes to
its own loop's channel (`ThreadedServer.bus_write_fds`). Building it found
one more thing the refusal had been hiding: under a pool, `/health` was
answered by a pool thread's handler, whose registries are never the ones
being drained, so it reported zero subscribers while events were being
delivered. The loop's `before_request` now runs *before* the offload and
answers static mounts and the health path itself (`answers_local`) — it
used to run only on the queue-full fallback, so under a pool the hook had
never fired on the loop at all. Measured on textshelf after: fast-path p50
0.3 ms with eight slow views in flight, four streams held on pool threads
across three workers, all four delivered.

**Is it a significant advance?** For (1), yes, and by a distance: it is the
difference between the realtime claim being demonstrable and being
deployable. Every application with a slow view and a stream — which is
every application that wants a stream — currently has to choose between the
two things this server does best. (2) is worth doing only after (1) and is
the smaller: the executor mount already streams, so what it adds is the
cheaper hold and the sync-only codebase for the pub/sub half of a mixed
application. Neither is a rewrite. The mechanism, the channel, the
reserved-name dispatch and the lane record all exist; the work is one new
frame kind, one handler branch, one narrowed refusal, and the smokes that
prove the ordering.
