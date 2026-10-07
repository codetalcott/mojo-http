"""The state, the views and the table that joins them.

The state holds the list AND the stream every tab subscribes to, so the
view that changes the list is the one that sends it: `post` appends, then
`patch_elements` numbers one frame carrying the whole board and queues it
for every open stream on this process.

Every view that touches the state runs on the event loop (`on_loop=True`).
Opening a stream must, since it subscribes a connection slot and only the
loop's instance of the state is drained. The other two must as well, so
that they read and write that same instance: under `--blocking-threads N`
the host builds a state for every pool thread too.
"""

from lightbug_http import HTTPRequest, HTTPResponse
from m0_host.host import HostContext, ViewState

from m0_datastar.stream import DatastarStream
from m0_http import Views, form, reply

from pages import EVENTS, HEALTH, MESSAGES, PAGE, render_board, render_page

comptime MAX_MESSAGES = 50
"""The board keeps the newest fifty, and every frame carries all of them."""

comptime MAX_TEXT = 1500
"""Bytes in one message; longer is refused, never cut (a cut can split a
UTF-8 character). The page's `maxlength` is 500 characters, which is at
most 1500 bytes, so the browser never sends a message this refuses."""


struct Board(ViewState):
    """The messages, oldest first, and the stream that carries them."""

    var messages: List[String]
    var stream: DatastarStream

    def __init__(out self, capacity: Int):
        self.messages = List[String]()
        # `capacity` is the server's connection count and must be: a slot
        # indexes the stream's registry directly. `send_latest`: a tab that
        # opens or reopens its stream gets the newest board at once.
        self.stream = DatastarStream(capacity, journal_entries=0, send_latest=True)

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return Board(ctx.capacity)

    @staticmethod
    def urls() raises -> Views[Self]:
        return board_urls()

    @staticmethod
    def max_workers() -> Int:
        # The list and its subscribers live in this struct: a second worker
        # would hold a second list whose posts reach only its own tabs, so
        # `M0_WORKERS=2` and `M0_THREADS=2` are refused (exit 78) rather
        # than served. Reaching every worker takes the bus, which takes a
        # handler of your own: the host page says how.
        return 1

    def add(mut self, var text: String):
        self.messages.append(text^)
        if len(self.messages) > MAX_MESSAGES:
            _ = self.messages.pop(0)

    # The three stream hooks `ViewsApp` forwards to the state.
    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return self.stream.drain(slot)

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.stream.is_streaming(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        self.stream.closed(slot)


def health(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    return reply.json(200, "OK", '{"status":"ok"}')


def page(req: HTTPRequest, params: List[String], st: Board) raises -> HTTPResponse:
    """GET / — the document, with the board as it stands."""
    return reply.html(render_page(st.messages))


def events(
    req: HTTPRequest, params: List[String], mut st: Board
) raises -> HTTPResponse:
    """GET /events — subscribe this connection to the board."""
    var resp = st.stream.open(req, EVENTS)
    return resp^


def post(
    req: HTTPRequest, params: List[String], mut st: Board
) raises -> HTTPResponse:
    """POST /messages — add one, then send the board to every open tab.

    Datastar 1.0 applies an action's answer only when it is a 200: the
    page's `required` keeps an empty message in the browser, and the
    refusals below are for a client that is not the page, as
    `problem+json`.
    """
    var maybe = form(req)
    if not maybe:
        return reply.problem(
            400, "Bad Request",
            "the request body must be application/x-www-form-urlencoded",
            MESSAGES,
        )
    var text = maybe.take().first("text")
    if text.byte_length() == 0 or text.byte_length() > MAX_TEXT:
        return reply.problem(
            422, "Unprocessable Content",
            String("a message is 1 to ", MAX_TEXT, " bytes of text in the field `text`"),
            MESSAGES,
        )
    st.add(text^)
    # One frame, the whole board, to every stream on this process. A tab
    # whose outbox dropped an earlier frame is healed by this one.
    _ = st.stream.patch_elements(EVENTS, render_board(st.messages))
    # The poster's own answer: Datastar reads an `application/json` answer
    # as a signal patch, and `$text` is bound to the input, so this empties
    # it. Other tabs keep whatever their visitor is typing.
    return reply.json(200, "OK", '{"text":""}')


def board_urls() raises -> Views[Board]:
    """The whole URL-to-view mapping."""
    var v = Views[Board]()
    v.add_loop("GET", HEALTH, health)
    v.add_read("GET", PAGE, page, on_loop=True)
    v.add_write("GET", EVENTS, events, on_loop=True)
    v.add_write("POST", MESSAGES, post, on_loop=True)
    return v^
