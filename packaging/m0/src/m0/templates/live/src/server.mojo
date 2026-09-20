"""__M0_APP__ — one shared state, stepped on the server, pushed to every tab.

    GET  /         the document (Datastar opens /events from data-init)
    GET  /events   the stream: the newest frame at open, then one per step
    POST /kick     kick the bars, for everyone
    GET  /stats    the producer's counters, as JSON
    GET  /health   {"status":"ok"}, answered on the loop

Two pieces the host runs for you (`uv run m0 doctor` prints the topology):

- `Ticker`, a `Producer`: work on a cadence, on a thread of its own, on
  worker 0 alone. `step` returns the nanoseconds to the next step and
  publishes through the host's `Publisher`, which reaches every worker.
  Never do this work in the loop's `tick`: that stalls every connection.
- `LiveHandler`, an `AppHandler`: a `Views` table that also owns the four
  SSE hooks, wired to the state's `DatastarStream`.

Build it:  uv run m0 build      Test it:  uv run m0 test
"""

from lightbug_http import HTTPRequest, HTTPResponse
from m0_host.flags import host_config
from m0_host.host import AppHandler, HostContext, Producer, Publisher, serve

from m0_http import Views

from board import B_KICKS, B_PAUSED, B_REFUSED, B_STEPS, Board, board_slots
from pages import BARS, EVENTS, state_frame
from views import LiveState, live_urls
from wave import Wave

comptime STEP_NS = 500_000_000
"""Two steps a second."""

comptime PAUSE_POLL_NS = 50_000_000
"""How often a paused producer looks for a viewer."""


struct Ticker(Producer):
    """Step, render, publish — and pause while nobody watches."""

    var board: Board
    var workers: Int
    var wave: Wave
    var kicks_seen: Int

    def __init__(out self, board: Board, workers: Int):
        self.board = board
        self.workers = workers
        self.wave = Wave()
        self.kicks_seen = board.load(B_KICKS)

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return Ticker(Board(ctx.page), ctx.workers)

    def step(mut self, mut out: Publisher) raises -> Int:
        var viewers = self.board.viewers(self.workers)
        if viewers == 0:
            # Nobody to draw for: no step, no frame, no cost.
            self.board.store(B_PAUSED, 1)
            return PAUSE_POLL_NS
        self.board.store(B_PAUSED, 0)

        var kicks = self.board.load(B_KICKS)
        self.wave.advance(kicks - self.kicks_seen)
        self.kicks_seen = kicks

        # The id is the HOST's, from the word every worker numbers from: a
        # producer counting for itself restarts at 1 when worker 0 is
        # respawned, and every open stream then ignores it as old news.
        var id = out.next_id()
        var frame = state_frame(id, self.wave.step_no, self.wave.heights(), viewers)
        if not out.publish(EVENTS, id, frame.as_bytes()):
            self.board.add(B_REFUSED, 1)
        self.board.store(B_STEPS, self.wave.step_no)
        return STEP_NS


struct LiveHandler(AppHandler):
    """A `Views` table that also owns the four SSE hooks."""

    var views: Views[LiveState]
    var state: LiveState

    def __init__(out self, var views: Views[LiveState], var state: LiveState):
        self.views = views^
        self.state = state^

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return LiveHandler(
            live_urls(),
            LiveState(ctx.capacity, Board(ctx.page), ctx.worker, ctx.workers),
        )

    @staticmethod
    def page_slots(workers: Int) -> Int:
        return board_slots(workers)

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return self.views.answer_on_loop(req)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return self.views.dispatch(req, self.state)

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return self.state.stream.drain(slot)

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.state.stream.is_streaming(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        self.state.stream.closed(slot)
        self.state.publish_viewers()

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        # The producer's frame, from the bus: kept as the newest state and
        # queued for every viewer on this worker.
        self.state.stream.deliver_peer(url, event_id, frame)


def main() raises:
    var config = host_config()
    print(
        String("__M0_APP__ on ", config.base_url, " — ", config.workers, " worker(s)"),
        flush=True,
    )
    serve[LiveHandler, Ticker](config)
