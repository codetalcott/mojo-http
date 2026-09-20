"""The state the views share with the SSE hooks, the views, and the table.

Route placement is the thing to get right in a streaming app:

- `add_loop` — stateless, answered on the event loop (`/health`).
- `add_read` — the state borrowed.
- `add_write` — the state `mut`. Opening the stream is a WRITE: it
  subscribes a connection slot and changes the viewer count.
"""

from lightbug_http import HTTPRequest, HTTPResponse

from m0_datastar.stream import DatastarStream
from m0_http import Views, reply

from board import B_KICKS, B_PAUSED, B_REFUSED, B_STEPS, Board
from pages import EVENTS, HEALTH, KICK, PAGE, STATS, render_page


struct LiveState(Movable):
    """What the views read and write, and what the SSE hooks drive."""

    var stream: DatastarStream
    var board: Board
    var worker: Int
    var workers: Int
    var page_html: String

    def __init__(out self, capacity: Int, board: Board, worker: Int, workers: Int) raises:
        # `capacity` is the server's connection count and must be: a slot
        # indexes the stream's registry directly. `send_latest`: a new
        # viewer gets the newest frame at once, never a replay.
        self.stream = DatastarStream(capacity, journal_entries=0, send_latest=True)
        self.board = board
        self.worker = worker
        self.workers = workers
        # Nothing in the document varies by request: rendered once.
        self.page_html = render_page()

    def publish_viewers(mut self):
        """Store this worker's open streams where the producer reads them."""
        self.board.set_viewers(self.worker, self.stream.subscriber_count(EVENTS))


def health(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    return reply.json(200, "OK", '{"status":"ok"}')


def page(req: HTTPRequest, params: List[String], st: LiveState) raises -> HTTPResponse:
    return reply.html(st.page_html)


def events(
    req: HTTPRequest, params: List[String], mut st: LiveState
) raises -> HTTPResponse:
    """GET /events — the state stream."""
    var resp = st.stream.open(req, EVENTS)
    st.publish_viewers()
    return resp^


def kick(req: HTTPRequest, params: List[String], st: LiveState) raises -> HTTPResponse:
    """POST /kick — for everyone. The view only counts it: the producer
    applies it on its next step, and the frame that shows it reaches every
    viewer on every worker."""
    st.board.add(B_KICKS, 1)
    return reply.no_content()


def stats(req: HTTPRequest, params: List[String], st: LiveState) raises -> HTTPResponse:
    var b = st.board
    return reply.json(200, "OK", String(
        '{"steps":', b.load(B_STEPS),
        ',"kicks":', b.load(B_KICKS),
        ',"refused":', b.load(B_REFUSED),
        ',"paused":', b.load(B_PAUSED),
        ',"viewers":', b.viewers(st.workers),
        ',"worker":', st.worker,
        "}",
    ))


def live_urls() raises -> Views[LiveState]:
    var v = Views[LiveState]()
    v.add_loop("GET", HEALTH, health)
    v.add_read("GET", PAGE, page)
    v.add_write("GET", EVENTS, events)
    v.add_read("POST", KICK, kick)
    v.add_read("GET", STATS, stats)
    return v^
