from lightbug_http.header import HeaderKey
from lightbug_http.io.bytes import Bytes

from lightbug_http.http import OK, HTTPRequest, HTTPResponse, NotFound


trait HTTPService:
    """The handler contract. `func` is the only method you must write.

    The other eight carry default bodies — the same empty implementations
    every handler used to spell out by hand — so a handler declares only the
    hooks it actually uses. Overriding one is ordinary: define it and yours
    wins.

    That is also what makes the trait extensible. A method added here WITH a
    default no longer breaks every implementer in the repo at once; a method
    added without one still does, so give new hooks a default unless there is
    a reason not to. `test_service.mojo` holds a handler that implements
    `func` alone, and exists to fail compilation if a default is ever
    removed.
    """

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        """Answer a request. The one method with no default."""
        ...

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        """Called before func(). Return a response to short-circuit (e.g. CORS preflight, auth).
        Return None to continue to func().
        """
        return None

    def after_response(mut self, req_method: String, req_path: String, mut resp: HTTPResponse):
        """Called after func() with the response. Add headers, log, etc."""
        pass

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        """Return and clear pending SSE outbound data for a slot."""
        return List[UInt8]()

    def sse_is_streaming(self, slot: Int) -> Bool:
        """Check if a slot is in SSE streaming mode."""
        return False

    def sse_slot_disconnected(mut self, slot: Int):
        """Notify the service that an SSE client disconnected."""
        pass

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        """Deliver an SSE frame broadcast by ANOTHER worker (BroadcastBus).

        Only fires when the server was started with a bus channel
        (`bus_read_fd`), i.e. under a multi-worker SSE setup. Queue the frame
        for local subscribers of `url` — `DatastarStream.deliver_peer` is the
        standard wiring. Non-streaming handlers leave it empty.
        """
        pass

    def tick(mut self, now_ms: Int):
        """Scheduled wakeup from the event loop — the application timer hook.

        Fires every `ServerConfig.app_tick_ms` milliseconds (0, the default,
        means never), with a monotonic timestamp for handlers running their
        own sub-schedules. This is the one place server-initiated work can
        happen: broadcast from here and the same loop pass delivers it, no
        inbound request required. Keep it quick — the tick runs on the event
        loop thread, and every connection waits while it does.
        """
        pass

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
        pass

    def ws_message_take(mut self, slot: Int, opcode: Int, payload: List[UInt8]) -> Bool:
        """`ws_message`, with a voice: False asks the loop to STOP READING.

        The loop calls THIS hook, not `ws_message` — the default forwards,
        so a handler that wrote only `ws_message` behaves as before. A
        handler that hands messages to another thread over a channel that
        can fill returns False for a message it PARKED rather than
        delivered; the loop then takes the slot off the read set, so the
        socket's receive buffer fills, TCP advertises a zero window, and
        the CLIENT stops sending — flow control end to end, instead of the
        silent drop this hook replaced (2 881 of 3 000 inbound messages
        lost, against a clean server log). False means "parked, and I will
        name this slot in `take_ws_resumes` when it may read again" — never
        "dropped": a parked message is still owed.
        """
        self.ws_message(slot, opcode, payload)
        return True

    def take_ws_resumes(mut self) -> List[Int]:
        """Slots whose inbound flow may resume — parked messages all sent.

        Called once per loop pass, at the bottom. The loop re-arms each
        named slot's read (`try_add_read`: level-triggered on kqueue, and
        epoll delivers an edge at ADD time for bytes already buffered, so
        nothing is stranded). A handler that never returns False from
        `ws_message_take` never names a slot; the default is that handler.
        """
        return List[Int]()

    def direct_job(mut self, slot: Int) -> Bool:
        """Take a parked request for an executor lane on THIS thread, or decline.

        The loop inversion's submit seam. When the event loop runs as a
        callback inside an asyncio loop — one thread, the executor's — a
        request bound for the executor no longer needs a datagram and a
        wake to reach it: the loop parks the request in the `OffloadPool`
        as it always did, then asks the handler to take it HERE. A handler
        that returns True has started the job (typically by handing the
        parked request to its asyncio loop as a task) and will answer it
        through the pool's completion path; one that returns False gets the
        datagram it always got. The default declines, so every handler that
        is not the inverted executor is unaffected. Only ever called for a
        slot the loop has already marked offloaded and stamped with its lane.
        """
        return False


@fieldwise_init
struct Printer(HTTPService):
    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        print("Request URI:", req.uri.request_uri)
        print("Request protocol:", req.protocol)
        print("Request method:", req.method)
        if HeaderKey.CONTENT_TYPE in req.headers:
            print("Request Content-Type:", req.headers[HeaderKey.CONTENT_TYPE])
        if req.body_raw:
            print("Request Body:", StringSpan(unsafe_from_utf8=Span(req.body_raw)))

        return OK(req.body_raw)

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
            print(StringSpan(unsafe_from_utf8=Span(req.body_raw)))

        return OK(req.body_raw)

@fieldwise_init
struct TechEmpowerRouter(HTTPService):
    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        if req.uri.path == "/plaintext":
            return OK("Hello, World!", "text/plain")
        elif req.uri.path == "/json":
            return OK('{"message": "Hello, World!"}', "application/json")

        return OK("Hello world!")  # text/plain is the default

@fieldwise_init
struct Counter(HTTPService):
    var counter: Int

    def __init__(out self):
        self.counter = 0

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        self.counter += 1
        return OK("I have been called: " + String(self.counter) + " times")
