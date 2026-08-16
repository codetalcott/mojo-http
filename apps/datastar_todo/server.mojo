"""Datastar todos — the flagship: live multi-tab sync over one SSE stream.

Where `apps/datastar_counter` broadcasts a signal (a number), this broadcasts
*HTML*: every mutation renders the `<section id="todos">` fragment once and
`patch_elements` morphs it into every connected tab. The list lives on the
server; the browser never owns state beyond the draft input.

It also composes the framework layer the counter skips: the per-item actions
are `Router` routes with `:id` captures —

    GET  /              the page, list already rendered
    GET  /events        opens the SSE stream (data-on-load)
    POST /add           reads the draft signal, appends, broadcasts
    POST /toggle/:id    flips done, broadcasts
    POST /delete/:id    removes, broadcasts

One process only: SSE fan-out is per-process, so `M0_WORKERS>1` would split
tabs across workers that cannot see each other's broadcasts.

Run it:  uv run poe serve-todo
"""

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.header import Headers, Header, HeaderKey

from m0_core.json_parse import parse_json_field

from m0_http import AppConfig, Router

from m0_datastar.stream import DatastarStream
from m0_datastar.signals import read_signals

from datastar_todo.page import render_page, render_todos


comptime STREAM_URL = "/events"

comptime H_ADD = 0
comptime H_TOGGLE = 1
comptime H_DELETE = 2


struct TodoHandler(HTTPService):
    """One shared todo list, every connected tab in sync."""

    var router: Router
    var stream: DatastarStream
    # The store, SoA (the repo convention around List[Struct] copyability).
    # Ids are stable and never reused; deletion shifts to preserve order —
    # a todo list that reorders itself on delete looks broken.
    var ids: List[Int]
    var texts: List[String]
    var done: List[Bool]
    var next_id: Int

    def __init__(out self):
        self.router = Router()
        self.router.add("POST", "/add", H_ADD)
        self.router.add("POST", "/toggle/:id", H_TOGGLE)
        self.router.add("POST", "/delete/:id", H_DELETE)
        # Must be at least the server's max connections: slots are indexed
        # directly by req.slot_id.
        self.stream = DatastarStream(1024)
        self.ids = List[Int]()
        self.texts = List[String]()
        self.done = List[Bool]()
        self.next_id = 1

    def _find(self, id: Int) -> Int:
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return i
        return -1

    def _broadcast(mut self):
        """Render the fragment once, morph it into every subscriber."""
        try:
            var fragment = render_todos(self.ids, self.texts, self.done)
            _ = self.stream.patch_elements(STREAM_URL, fragment)
        except:
            pass  # a render bug must not kill the mutating request

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var path = req.uri.path

        if path == "/health":
            return OK('{"status":"ok"}', "application/json")

        if path == "/":
            return _html(render_page(self.ids, self.texts, self.done))

        if path == STREAM_URL:
            return self.stream.open(req, STREAM_URL)

        var m = self.router.match(req.method, path)
        if not m.matched:
            return _not_found()

        if m.handler_id == H_ADD:
            # The browser posts its signal store; the draft is all we want.
            var draft = parse_json_field(read_signals(req), "draft")
            if draft.byte_length() > 0:
                self.ids.append(self.next_id)
                self.texts.append(draft)
                self.done.append(False)
                self.next_id += 1
                self._broadcast()
            # Empty drafts are ignored, not an error: the Add button is
            # always clickable and a 4xx would surface nothing useful.
            return _no_content()

        var id = _parse_id(m.params[0])
        var i = self._find(id)
        if i < 0:
            # A stale tab can race a delete; its click is simply out of date.
            # 204 keeps the tab quiet — the next broadcast corrects its view.
            return _no_content()

        if m.handler_id == H_TOGGLE:
            self.done[i] = not self.done[i]
        else:
            _ = self.ids.pop(i)
            _ = self.texts.pop(i)
            _ = self.done.pop(i)
        self._broadcast()
        return _no_content()

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        pass

    # --- The three SSE hooks, wired straight through to the stream ----------

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return self.stream.drain(slot)

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.stream.is_streaming(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        self.stream.closed(slot)


def _html(body: String) -> HTTPResponse:
    return HTTPResponse(
        body_bytes=body.as_bytes(),
        headers=Headers(
            Header(HeaderKey.CONTENT_TYPE, "text/html; charset=utf-8")
        ),
        status_code=200,
        status_text="OK",
    )


def _no_content() -> HTTPResponse:
    # Mutations need no body: the update arrives over the stream.
    return HTTPResponse(
        body_bytes=String("").as_bytes(),
        status_code=204,
        status_text="No Content",
    )


def _not_found() -> HTTPResponse:
    return HTTPResponse(
        body_bytes=String('{"error":"not found"}').as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=404,
        status_text="Not Found",
    )


def _parse_id(s: String) -> Int:
    if s.byte_length() == 0:
        return -1
    var result = 0
    var bytes = s.as_bytes()
    for i in range(s.byte_length()):
        var c = Int(bytes[i])
        if c < ord("0") or c > ord("9"):
            return -1
        result = result * 10 + (c - ord("0"))
    return result


def main() raises:
    var config = AppConfig()
    print("Datastar todos on " + config.base_url + " — open it in two tabs")
    var server = Server()
    var handler = TodoHandler()
    # SSE requires `listen_and_serve_nonblocking`, not `listen_and_serve`:
    # only the non-blocking event loop assigns `req.slot_id` and drains the
    # outbox; the plain accept loop would answer every stream open with 409.
    server.listen_and_serve_nonblocking(config.address(), handler)
