"""WebSocket echo — the smallest app that speaks RFC 6455.

    GET  /health   liveness, plus how many sockets are connected
    GET  /ws       the WebSocket endpoint: every message comes straight back

The handler shows the entire WebSocket contract in one screen:
`websocket_upgrade` answers the handshake in `func`, `ws_message` receives
each complete message (fragments already assembled, control frames already
handled by the event loop), and replies are queued as encoded frames that
`sse_drain_slot` — the outbox hook SSE and WebSocket share — hands to the
loop. Disconnects arrive at `sse_slot_disconnected` whatever their cause:
a close frame, a vanished client, a failed heartbeat ping.

Run it:  uv run poe serve-ws
Talk to it from a browser console:
    ws = new WebSocket("ws://localhost:8080/ws")
    ws.onmessage = (e) => console.log(e.data)
    ws.onopen = () => ws.send("hello")
"""

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse, OK, NotFound
from lightbug_http.websocket import websocket_upgrade, encode_ws_frame

from m0_http import AppConfig, install_shutdown_signals


comptime MAX_SLOTS = 1024


struct EchoHandler(HTTPService):
    """Echo every WebSocket message back on the socket it came from."""

    # Outbox per slot (parallel to the server's slot table): ws_message
    # queues encoded frames here, the event loop drains them via
    # sse_drain_slot in the same pass.
    var outbox: List[List[UInt8]]
    var connected: List[Bool]

    def __init__(out self):
        self.outbox = List[List[UInt8]](capacity=MAX_SLOTS)
        self.connected = List[Bool](capacity=MAX_SLOTS)
        for _ in range(MAX_SLOTS):
            self.outbox.append(List[UInt8]())
            self.connected.append(False)

    def _connection_count(self) -> Int:
        var n = 0
        for s in range(MAX_SLOTS):
            if self.connected[s]:
                n += 1
        return n

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var path = req.uri.path

        if path == "/health":
            return OK(
                '{"status":"ok","connections":' + String(self._connection_count()) + "}",
                "application/json",
            )

        if path == "/ws":
            # None means "not even trying to upgrade" — a plain GET /ws gets
            # told how to talk to this endpoint. An actual upgrade attempt
            # always yields a response: 101, 426, or 400.
            var upgraded = websocket_upgrade(req)
            if upgraded:
                if req.slot_id >= 0 and req.slot_id < MAX_SLOTS:
                    self.connected[req.slot_id] = True
                    self.outbox[req.slot_id].clear()
                return upgraded.take()
            return HTTPResponse(
                body_bytes=String("WebSocket endpoint — connect with a WebSocket client").as_bytes(),
                status_code=426,
                status_text="Upgrade Required",
            )

        return NotFound(path)

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        if slot < 0 or slot >= MAX_SLOTS:
            return List[UInt8]()
        var pending = self.outbox[slot].copy()
        self.outbox[slot].clear()
        return pending^

    def sse_is_streaming(self, slot: Int) -> Bool:
        return slot >= 0 and slot < MAX_SLOTS and self.connected[slot]

    def sse_slot_disconnected(mut self, slot: Int):
        if slot >= 0 and slot < MAX_SLOTS:
            self.connected[slot] = False
            self.outbox[slot].clear()

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        # The echo: same opcode, same payload, queued for the same slot.
        if slot < 0 or slot >= MAX_SLOTS:
            return
        var frame = encode_ws_frame(opcode, Span(payload))
        for j in range(len(frame)):
            self.outbox[slot].append(frame[j])


def main() raises:
    var config = AppConfig()
    print("WebSocket echo on " + config.base_url + " — endpoint at /ws")

    # For WebSocket slots the heartbeat is a protocol ping; the same
    # M0_SSE_HEARTBEAT_MS cadence drives both stream kinds.
    var server = Server(config.server_config(), config.address())
    var handler = EchoHandler()
    # Upgrades need the non-blocking loop: it assigns req.slot_id and owns
    # the frame parsing; the plain accept loop knows nothing of WebSockets.
    var shutdown_fd = install_shutdown_signals()
    server.listen_and_serve_nonblocking(
        config.address(), handler, shutdown_read_fd=shutdown_fd
    )
