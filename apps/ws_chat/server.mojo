"""WebSocket chat — every message reaches every socket, across workers.

    GET  /         the chat page (plain-browser WebSocket, no library)
    GET  /ws       the WebSocket endpoint
    GET  /health   liveness, plus this worker's connection count

This is the reference wiring for **cross-worker WebSocket fan-out** — the
WebSocket sibling of `apps/datastar_counter`'s SSE shape, riding the same
machinery. Everything shared is created BEFORE the fork: the listener all
workers accept from, the `BroadcastBus` (one datagram channel per worker),
and a `SharedAtomics` slot for bus frame ids. Each worker's `WSHub` then
joins the bus, and a message received by any worker reaches sockets held
by every worker: `ws_message` → `hub.broadcast` (queues locally, publishes
to peers) → each peer's `sse_peer_frame` → `hub.deliver_peer`.

The bus is transport-agnostic on purpose: `sse_peer_frame` means "a peer
worker broadcast something", and the payload here is an encoded WebSocket
frame instead of an SSE event. Delivery is best-effort in arrival order —
chat-shaped traffic wants exactly that; state replication with replay
wants `DatastarStream`.

Run it:  uv run poe serve-chat        (M0_WORKERS=2 for the fan-out shape)
"""

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse, OK, NotFound
from lightbug_http.broadcast import BroadcastBus
from lightbug_http.c.process import getpid
from lightbug_http.connection import ListenConfig
from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.websocket import websocket_upgrade, encode_ws_frame, WS_OP_TEXT

from m0_http import AppConfig, WorkerSupervisor, WSHub
from m0_http.multiworker import SharedAtomics

from ws_chat.page import render_page


comptime CHAT_URL = "/ws"
comptime MAX_SLOTS = 1024


struct ChatHandler(HTTPService):
    """One room, everyone in it — this worker's sockets in the hub, every
    other worker's reached over the bus."""

    var hub: WSHub

    def __init__(out self):
        # Must be at least the server's max connections: slots are indexed
        # directly by req.slot_id.
        self.hub = WSHub(MAX_SLOTS)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var path = req.uri.path

        if path == "/health":
            # Connection count is per-worker (each worker's hub knows only
            # its own sockets) — how the smoke checks local cleanup.
            return OK(
                '{"status":"ok","connections":' + String(self.hub.count()) + "}",
                "application/json",
            )

        if path == "/":
            return HTTPResponse(
                body_bytes=render_page(getpid()).as_bytes(),
                headers=Headers(
                    Header(HeaderKey.CONTENT_TYPE, "text/html; charset=utf-8")
                ),
                status_code=200,
                status_text="OK",
            )

        if path == CHAT_URL:
            var upgraded = websocket_upgrade(req)
            if upgraded:
                var resp = upgraded.take()
                # Which worker owns this socket — the multi-worker smoke
                # reads this to prove its sockets span workers before
                # asserting one message reaches all of them.
                resp.headers["X-Worker"] = String(getpid())
                self.hub.open(req.slot_id)
                return resp^
            return HTTPResponse(
                body_bytes=String("WebSocket endpoint — connect with a WebSocket client").as_bytes(),
                status_code=426,
                status_text="Upgrade Required",
            )

        return NotFound(path)

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        pass

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return self.hub.drain(slot)

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.hub.is_connected(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        self.hub.closed(slot)

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        # A message another worker broadcast: the frame is already an
        # encoded WebSocket frame — queue it for this worker's sockets.
        self.hub.deliver_peer(frame)

    def tick(mut self, now_ms: Int):
        pass

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        # The chat: whatever one socket says, every socket hears — the
        # sender included (their own message coming back is the delivery
        # confirmation). Re-encoded as a text frame, fanned out everywhere.
        self.hub.broadcast(CHAT_URL, encode_ws_frame(WS_OP_TEXT, Span(payload)))


def main() raises:
    var config = AppConfig()
    print("WebSocket chat on " + config.base_url + " — open it in two tabs")

    # Everything workers must share is created BEFORE the fork: the
    # listener (all workers accept from this one socket), the bus channels,
    # and the shared atomic numbering bus frames. Single-worker mode simply
    # serves one process with the same objects.
    var listener = ListenConfig().listen(config.address())
    var shared = SharedAtomics(1)
    var bus = BroadcastBus(config.workers)
    var worker = 0
    if config.workers > 1:
        var supervisor = WorkerSupervisor(config.workers)
        supervisor.fork_all()
        worker = supervisor.worker_index

    var handler = ChatHandler()
    var bus_read_fd = -1
    if config.workers > 1:
        # Joining the bus is three-sided: the hub publishes to peers, the
        # server drains this worker's channel, and sse_peer_frame (above)
        # delivers what arrives. Partial wiring fails quietly.
        handler.hub.enable_bus(bus, worker, shared.addr(0))
        bus_read_fd = bus.read_fd(worker)

    # WebSocket heartbeats are protocol pings on the same cadence knob.
    var server = Server(config.server_config(), config.address())
    # WebSockets need the non-blocking event loop: it assigns req.slot_id,
    # parses frames, and drains the outbox.
    server.serve_nonblocking(listener, handler, bus_read_fd=bus_read_fd)
