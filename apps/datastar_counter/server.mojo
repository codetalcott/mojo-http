"""Datastar counter — live multi-tab sync over one SSE stream.

The smallest app that exercises the whole Datastar path:

    GET  /            the page, with the current count already rendered
    GET  /events      opens the SSE stream (data-on-load)
    POST /increment   mutates, then broadcasts to every open stream
    POST /decrement   likewise

Open two tabs and press a button in one; the other updates without a reload.
That is the entire point, and it is what `DatastarStream` exists to make
possible — the builders in `m0_datastar.sse` produce complete SSE frames, which
`SSERegistry.notify` cannot carry without double-framing them.

Run it:  uv run poe serve-counter
"""

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.server_config import ServerConfig

from m0_http import AppConfig

from m0_datastar.stream import DatastarStream
from m0_datastar.signals import read_signals

from datastar_counter.page import render_page


comptime STREAM_URL = "/events"


struct CounterHandler(HTTPService):
    """One counter, shared by every connected client."""

    var count: Int
    var stream: DatastarStream

    def __init__(out self):
        self.count = 0
        # Must be at least the server's max connections: slots are indexed
        # directly by req.slot_id.
        self.stream = DatastarStream(1024)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var path = req.uri.path

        if path == "/health":
            # subscribers surfaces the stream registry's live count — how the
            # smoke asserts a vanished client is actually unsubscribed, not
            # left as a stale registration queueing bytes nobody will read.
            return OK(
                '{"status":"ok","subscribers":'
                + String(self.stream.subscriber_count(STREAM_URL))
                + "}",
                "application/json",
            )

        if path == "/":
            return _html(render_page(self.count))

        if path == STREAM_URL:
            return self.stream.open(req, STREAM_URL)

        if path == "/increment" or path == "/decrement":
            # The browser posts its whole signal store. This demo keeps the
            # count server-side and ignores the client's copy, but reading it
            # is how you would accept client-supplied input.
            _ = read_signals(req)

            if path == "/increment":
                self.count += 1
            else:
                self.count -= 1

            # One broadcast reaches every tab, including the one that clicked.
            _ = self.stream.patch_signals(
                STREAM_URL, '{"count":' + String(self.count) + "}"
            )
            # The POST itself needs no body: the update arrives over the stream.
            return HTTPResponse(
                body_bytes=String("").as_bytes(), status_code=204, status_text="No Content"
            )

        return HTTPResponse(
            body_bytes=String('{"error":"not found"}').as_bytes(),
            headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
            status_code=404,
            status_text="Not Found",
        )

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        pass

    # --- The four SSE hooks, wired straight through to the stream ----------

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return self.stream.drain(slot)

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.stream.is_streaming(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        self.stream.closed(slot)


def _html(body: String) -> HTTPResponse:
    return HTTPResponse(
        body_bytes=body.as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/html; charset=utf-8")),
        status_code=200,
        status_text="OK",
    )


def main() raises:
    var config = AppConfig()
    print("Datastar counter on " + config.base_url + " — open it in two tabs")
    # Heartbeats keep idle streams alive through proxies and NATs, and let the
    # loop discover dead subscribers; M0_SSE_HEARTBEAT_MS tunes the cadence
    # (the smoke sets it low to assert heartbeats actually arrive).
    var server_config = ServerConfig()
    server_config.access_log = config.access_log
    server_config.sse_heartbeat_ms = config.sse_heartbeat_ms
    var server = Server(server_config^)
    var handler = CounterHandler()
    # SSE requires `listen_and_serve_nonblocking`, not `listen_and_serve`.
    # Only the non-blocking event loop assigns `req.slot_id` and drains the
    # outbox; the plain accept loop leaves slot_id at -1, and every stream open
    # would answer 409.
    server.listen_and_serve_nonblocking(config.address(), handler)
