from lightbug_http.header import HeaderKey
from lightbug_http.io.bytes import Bytes

from lightbug_http.http import OK, HTTPRequest, HTTPResponse, NotFound


trait HTTPService:
    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        ...

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        """Called before func(). Return a response to short-circuit (e.g. CORS preflight, auth).
        Return None to continue to func().
        """
        ...

    def after_response(mut self, req_method: String, req_path: String, mut resp: HTTPResponse):
        """Called after func() with the response. Add headers, log, etc."""
        ...

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        """Return and clear pending SSE outbound data for a slot."""
        ...

    def sse_is_streaming(self, slot: Int) -> Bool:
        """Check if a slot is in SSE streaming mode."""
        ...

    def sse_slot_disconnected(mut self, slot: Int):
        """Notify the service that an SSE client disconnected."""
        ...

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        """Deliver an SSE frame broadcast by ANOTHER worker (BroadcastBus).

        Only fires when the server was started with a bus channel
        (`bus_read_fd`), i.e. under a multi-worker SSE setup. Queue the frame
        for local subscribers of `url` — `DatastarStream.deliver_peer` is the
        standard wiring. Non-streaming handlers leave it empty.
        """
        ...

    def tick(mut self, now_ms: Int):
        """Scheduled wakeup from the event loop — the application timer hook.

        Fires every `ServerConfig.app_tick_ms` milliseconds (0, the default,
        means never), with a monotonic timestamp for handlers running their
        own sub-schedules. This is the one place server-initiated work can
        happen: broadcast from here and the same loop pass delivers it, no
        inbound request required. Keep it quick — the tick runs on the event
        loop thread, and every connection waits while it does.
        """
        ...

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        """A complete WebSocket message from the client on `slot`.

        Fires only on connections a `func` response upgraded (see
        `websocket_upgrade` in `websocket.mojo`). Fragments arrive already
        assembled; `opcode` is WS_OP_TEXT or WS_OP_BINARY. Control frames
        never reach here — the loop answers ping and close itself. To send,
        queue `encode_ws_frame(...)` bytes for the slot and return them from
        `sse_drain_slot`; the outbox contract (and `sse_slot_disconnected`
        cleanup) is shared between SSE and WebSocket slots. Handlers that
        never upgrade leave this empty.
        """
        ...


@fieldwise_init
struct Printer(HTTPService):
    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        print("Request URI:", req.uri.request_uri)
        print("Request protocol:", req.protocol)
        print("Request method:", req.method)
        if HeaderKey.CONTENT_TYPE in req.headers:
            print("Request Content-Type:", req.headers[HeaderKey.CONTENT_TYPE])
        if req.body_raw:
            print("Request Body:", StringSlice(unsafe_from_utf8=Span(req.body_raw)))

        return OK(req.body_raw)

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(mut self, req_method: String, req_path: String, mut resp: HTTPResponse):
        pass

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return List[UInt8]()

    def sse_is_streaming(self, slot: Int) -> Bool:
        return False

    def sse_slot_disconnected(mut self, slot: Int):
        pass

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        pass

    def tick(mut self, now_ms: Int):
        pass

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        pass


@fieldwise_init
struct Welcome(HTTPService):
    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        if req.uri.path == "/":
            with open("static/lightbug_welcome.html", "r") as f:
                return OK(Bytes(f.read_bytes()), "text/html; charset=utf-8")

        if req.uri.path == "/logo.png":
            with open("static/logo.png", "r") as f:
                return OK(Bytes(f.read_bytes()), "image/png")

        return NotFound(req.uri.path)

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(mut self, req_method: String, req_path: String, mut resp: HTTPResponse):
        pass

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return List[UInt8]()

    def sse_is_streaming(self, slot: Int) -> Bool:
        return False

    def sse_slot_disconnected(mut self, slot: Int):
        pass

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        pass

    def tick(mut self, now_ms: Int):
        pass

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        pass


@fieldwise_init
struct ExampleRouter(HTTPService):
    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        if req.uri.path == "/":
            print("I'm on the index path!")
        if req.uri.path == "/first":
            print("I'm on /first!")
        elif req.uri.path == "/second":
            print("I'm on /second!")
        elif req.uri.path == "/echo":
            print(StringSlice(unsafe_from_utf8=Span(req.body_raw)))

        return OK(req.body_raw)

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(mut self, req_method: String, req_path: String, mut resp: HTTPResponse):
        pass

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return List[UInt8]()

    def sse_is_streaming(self, slot: Int) -> Bool:
        return False

    def sse_slot_disconnected(mut self, slot: Int):
        pass

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        pass

    def tick(mut self, now_ms: Int):
        pass

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        pass


@fieldwise_init
struct TechEmpowerRouter(HTTPService):
    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        if req.uri.path == "/plaintext":
            return OK("Hello, World!", "text/plain")
        elif req.uri.path == "/json":
            return OK('{"message": "Hello, World!"}', "application/json")

        return OK("Hello world!")  # text/plain is the default

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(mut self, req_method: String, req_path: String, mut resp: HTTPResponse):
        pass

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return List[UInt8]()

    def sse_is_streaming(self, slot: Int) -> Bool:
        return False

    def sse_slot_disconnected(mut self, slot: Int):
        pass

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        pass

    def tick(mut self, now_ms: Int):
        pass

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        pass


@fieldwise_init
struct Counter(HTTPService):
    var counter: Int

    def __init__(out self):
        self.counter = 0

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        self.counter += 1
        return OK("I have been called: " + String(self.counter) + " times")

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(mut self, req_method: String, req_path: String, mut resp: HTTPResponse):
        pass

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return List[UInt8]()

    def sse_is_streaming(self, slot: Int) -> Bool:
        return False

    def sse_slot_disconnected(mut self, slot: Int):
        pass

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        pass

    def tick(mut self, now_ms: Int):
        pass

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        pass
