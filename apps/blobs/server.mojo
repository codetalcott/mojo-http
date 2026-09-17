"""The blobs demo: one shared world, stepped in Mojo, pushed to every open tab.

    GET  /         the stage (Datastar opens /events from data-init)
    GET  /events   the state stream: the newest frame at open, then one per step
    POST /drop     {"x": pct, "y": pct} — drop a blob, for everyone
    GET  /stats    the producer's counters, as JSON
    GET  /health   liveness (answered on the loop)
    GET  /now      a trivial request (answered on the loop; the gate times it)

The claim is the one a page cannot make for itself: one world, held by the
server and shared by every viewer, with each step's work bounded whatever
the viewers do — at most `MAX_BLOBS` blobs, the oldest evicted by a drop.
The step time on the page is honesty about that cost, not a benchmark.

It is the first app here that is BOTH a `Views` table and a streaming
handler. `ViewService` forwards only `func` and `before_request`, so
`BlobsHandler` is the shape an app writes when it also owns the SSE hooks:
the table dispatches, the struct holds the state and wires the four hooks
to the state's `DatastarStream`.

It runs on the Mojo host (`lightbug_http.host`): `main` reads the cadence
and calls `serve[BlobsHandler, BlobsProducer]`, and the host does the rest
-- the listener, the pre-fork board and bus, the workers and their shared
accepts, the signals, and the producer on worker 0, stopped and joined
within the drain's bound. `M0_WORKERS=2` serves from two processes.

The step runs on the host's producer thread (`apps/sim_loop` says why the
tick is the wrong home), and every step is published as a whole state
frame to every worker's bus channel. Each worker's loop drains its channel
into `sse_peer_frame`, where the stream keeps it as the newest state
(`send_latest`), so a tab that opens the stream on any worker -- first
visit, reconnect or a restarted server -- is sent the current world at once
instead of a replay or a blank.

The producer pauses while nobody watches, on any worker, and slows to
`M0_BLOBS_IDLE_HZ` after `M0_BLOBS_IDLE_MS` without a drop. Clicks and
viewer counts reach it through the shared page in `board.mojo`, never
through `malloc`'d memory: a click on worker 1 crosses a process boundary
to reach the producer in worker 0. `/events` names its worker in
`x-worker`, and `/stats` names the worker that answered, so a client can
tell which process it is talking to.

The kernel (`kernel.mojo`) samples the metaball field on the stage's
192 x 192 grid and traces its outlines, so blobs that meet merge into one
shape. That is the work the step time reports.

Run it:  uv run poe serve-blobs
"""

from std.os import getenv
from std.time import perf_counter_ns

from lightbug_http import HTTPRequest, HTTPResponse
from lightbug_http.c.process import process_exit
from lightbug_http.host import AppHandler, HostContext, Producer, Publisher, serve

from m0_core.json_parse import parse_json_number

from m0_http import AppConfig, Views, reply

from m0_datastar.signals import read_signals
from m0_datastar.stream import DatastarStream

from blobs.board import (
    B_FRAME_BYTES,
    B_FRAME_MAX,
    B_HOLES,
    B_LAST_ID,
    B_LOST,
    B_APPLIED,
    B_OPEN_PATHS,
    B_OVER_BUDGET,
    B_PAUSED,
    B_PERIOD_MS,
    B_POLYGONS,
    B_REFUSED,
    B_STEPS,
    B_STEP_NS,
    B_STEP_NS_MAX,
    Board,
    DropReader,
    board_slots,
)
from blobs.kernel import Shapes, Tracer
from blobs.page import render_page
from blobs.routes import DROP, EVENTS, HEALTH, NOW, PAGE, STATS
from blobs.wire import state_frame
from blobs.world import STAGE, World

comptime STEP_BUDGET_NS = 2_000_000
"""What a step may cost before `/stats` counts it over budget.

A fraction of what a Fly shared vCPU earns per 100 ms (6.25% of a core,
6.25 ms), because the loop, the writes and the frame all spend from the
same allowance. The kernel measures ~0.2 ms on an M4 at sixteen blobs.
"""

comptime DROPS_PER_SECOND = 4
"""Drops one connection may make per second; the rest are answered 429."""

comptime PAUSE_POLL_NS = 20_000_000
"""How often a paused producer looks for a viewer."""


def _env_int(name: String, default: Int) -> Int:
    """A non-negative integer environment variable, or `default`."""
    var val = getenv(name, "")
    if val.byte_length() == 0:
        return default
    var result = 0
    var bytes = val.as_bytes()
    for i in range(val.byte_length()):
        var c = Int(bytes[i])
        if c < ord("0") or c > ord("9"):
            return default
        result = result * 10 + (c - ord("0"))
    return result


def _now_ms() -> Int:
    return Int(perf_counter_ns() // 1_000_000)


struct Cadence(Copyable, Movable):
    """How fast the stage steps, and when an untouched stage slows down."""

    var hz: Int
    var idle_hz: Int
    var idle_after_ms: Int

    def __init__(out self):
        """Read from the environment: `M0_BLOBS_HZ`, `M0_BLOBS_IDLE_HZ`,
        `M0_BLOBS_IDLE_MS`."""
        self.hz = _env_int("M0_BLOBS_HZ", 10)
        self.idle_hz = _env_int("M0_BLOBS_IDLE_HZ", 2)
        self.idle_after_ms = _env_int("M0_BLOBS_IDLE_MS", 60_000)

    def valid(self) -> Bool:
        return self.hz > 0 and self.idle_hz > 0


# --- The producer -------------------------------------------------------------


struct BlobsProducer(Producer):
    """Step, trace, publish -- and pause while nobody watches.

    Holds the world and nothing of the server's. What it shares with the
    workers is the board page; the host's publisher carries each frame to
    every worker's channel.
    """

    var board: Board
    var workers: Int
    var active_ns: Int
    var idle_ns: Int
    var idle_after_ns: Int
    var world: World
    var tracer: Tracer
    var shapes: Shapes
    var drops: DropReader
    var step_no: Int
    var last_drop_ns: Int

    def __init__(out self, board: Board, workers: Int, cadence: Cadence):
        self.board = board
        self.workers = workers
        self.active_ns = 1_000_000_000 // cadence.hz
        self.idle_ns = 1_000_000_000 // cadence.idle_hz
        self.idle_after_ns = cadence.idle_after_ms * 1_000_000
        self.world = World()
        self.tracer = Tracer()
        self.shapes = Shapes()
        self.drops = DropReader()
        self.step_no = 0
        self.last_drop_ns = perf_counter_ns()

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return BlobsProducer(Board(ctx.page), ctx.workers, Cadence())

    def step(mut self, mut out: Publisher) raises -> Int:
        var viewers = self.board.viewers(self.workers)
        if viewers == 0:
            # Nobody to draw for: no step, no frame. The world waits where
            # it is, and the next viewer is sent that state at open.
            self.board.store(B_PAUSED, 1)
            return PAUSE_POLL_NS
        self.board.store(B_PAUSED, 0)

        var now = perf_counter_ns()
        if self.drops.take(self.board, self.world) > 0:
            self.last_drop_ns = now
        var period_ns = self.active_ns
        if self.idle_after_ns > 0 and now - self.last_drop_ns >= self.idle_after_ns:
            period_ns = self.idle_ns
        self.board.store(B_PERIOD_MS, period_ns // 1_000_000)

        var t0 = perf_counter_ns()
        self.world.advance(Float64(period_ns) / 1_000_000_000.0)
        self.tracer.trace(self.world, self.shapes)
        var step_ns = perf_counter_ns() - t0
        self.step_no += 1
        # The frame's id is the host's, from the shared word every worker
        # numbers from, so a respawned producer's first frame is above what
        # every held stream has seen; `step_no` counts this process's steps.
        var id = out.next_id()
        var frame = state_frame(
            self.shapes, id, step_ns // 1000, viewers,
            self.world.count(), Int(period_ns // 1_000_000),
        )
        # Every worker's channel. A shortfall is counted: a frame the bus
        # refuses is otherwise indistinguishable from no step at all.
        if not out.publish(EVENTS, id, frame.as_bytes()):
            self.board.add(B_REFUSED, 1)

        var b = self.board
        b.store(B_STEPS, self.step_no)
        b.store(B_LAST_ID, id)
        b.store(B_POLYGONS, self.tracer.kept)
        if self.tracer.open_paths > 0:
            b.add(B_OPEN_PATHS, self.tracer.open_paths)
        if self.tracer.holes > 0:
            b.add(B_HOLES, self.tracer.holes)
        b.store(B_STEP_NS, step_ns)
        if step_ns > b.load(B_STEP_NS_MAX):
            b.store(B_STEP_NS_MAX, step_ns)
        if step_ns > STEP_BUDGET_NS:
            b.add(B_OVER_BUDGET, 1)
        b.store(B_FRAME_BYTES, frame.byte_length())
        if frame.byte_length() > b.load(B_FRAME_MAX):
            b.store(B_FRAME_MAX, frame.byte_length())
        return period_ns


# --- The views ----------------------------------------------------------------


struct BlobState(Movable):
    """What the views read and write, and what the SSE hooks drive."""

    var stream: DatastarStream
    var board: Board
    var worker: Int
    var workers: Int
    var capacity: Int
    var _window_ms: List[Int]
    var _window_drops: List[Int]

    def __init__(out self, capacity: Int, board: Board, worker: Int, workers: Int):
        # A stream of states: the newest frame at open, never a replay, and
        # no journal, since nothing here reads one.
        self.stream = DatastarStream(capacity, journal_entries=0, send_latest=True)
        self.board = board
        self.worker = worker
        self.workers = workers
        self.capacity = capacity
        self._window_ms = List[Int](length=capacity, fill=0)
        self._window_drops = List[Int](length=capacity, fill=0)

    def publish_viewers(mut self):
        """Store this worker's subscriber count where the producer reads it."""
        self.board.set_viewers(self.worker, self.stream.subscriber_count(EVENTS))

    def admit_drop(mut self, slot: Int) -> Bool:
        """At most `DROPS_PER_SECOND` drops per connection per second.

        Keyed by slot, so a connection that closes and whose slot is reused
        within the second hands its count on — conservative, never lenient.
        The world's own cap is what bounds the compute; this bounds how fast
        one client can churn it.
        """
        if slot < 0 or slot >= self.capacity:
            return False
        var now = _now_ms()
        if now - self._window_ms[slot] >= 1000:
            self._window_ms[slot] = now
            self._window_drops[slot] = 0
        if self._window_drops[slot] >= DROPS_PER_SECOND:
            return False
        self._window_drops[slot] += 1
        return True


def health(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    return reply.json(200, "OK", '{"status":"ok"}')


def now_view(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    # Deliberately trivial: how long it waited is the measurement.
    return reply.json(200, "OK", '{"now":true}')


def page(req: HTTPRequest, params: List[String], st: BlobState) raises -> HTTPResponse:
    return reply.html(render_page())


def events(
    req: HTTPRequest, params: List[String], mut st: BlobState
) raises -> HTTPResponse:
    var resp = st.stream.open(req, EVENTS)
    st.publish_viewers()
    # Which worker holds this stream: how a client tells that a frame
    # crossed the bus rather than being produced beside it.
    resp.headers["x-worker"] = String(st.worker)
    return resp^


def drop(
    req: HTTPRequest, params: List[String], mut st: BlobState
) raises -> HTTPResponse:
    """Validate a click, clamp it into the stage, hand it to the producer."""
    var body = read_signals(req)
    var x = parse_json_number(body, "x")
    var y = parse_json_number(body, "y")
    if not x or not y:
        return reply.problem(
            400, "Invalid Drop", "the body must carry numeric x and y", DROP
        )
    if not st.admit_drop(req.slot_id):
        var slow = reply.problem(
            429, "Too Many Drops",
            String("at most ", DROPS_PER_SECOND, " drops a second per connection"),
            DROP,
        )
        slow.headers["retry-after"] = "1"
        return slow^
    # Percent of the stage to grid units; the board and the world clamp to
    # the keep-out band, so a click at the very edge lands a margin inside.
    _ = st.board.post_drop(
        x.value() / 100.0 * STAGE, y.value() / 100.0 * STAGE
    )
    return reply.no_content()


def stats(req: HTTPRequest, params: List[String], st: BlobState) raises -> HTTPResponse:
    var b = st.board
    var body = String(
        '{"steps":', b.load(B_STEPS),
        ',"last_id":', b.load(B_LAST_ID),
        ',"step_us":', b.load(B_STEP_NS) // 1000,
        ',"step_us_max":', b.load(B_STEP_NS_MAX) // 1000,
        ',"over_budget":', b.load(B_OVER_BUDGET),
        ',"polygons":', b.load(B_POLYGONS),
        ',"open_paths":', b.load(B_OPEN_PATHS),
        ',"holes":', b.load(B_HOLES),
        ',"frame_bytes":', b.load(B_FRAME_BYTES),
        ',"frame_max":', b.load(B_FRAME_MAX),
        ',"refused":', b.load(B_REFUSED),
        ',"drops":', b.load(B_APPLIED),
        ',"lost":', b.load(B_LOST),
        ',"paused":', b.load(B_PAUSED),
        ',"period_ms":', b.load(B_PERIOD_MS),
        ',"viewers":', b.viewers(st.workers),
        ',"worker":', st.worker,
        "}",
    )
    return reply.json(200, "OK", body)


def urls() raises -> Views[BlobState]:
    var v = Views[BlobState]()
    v.add_loop("GET", HEALTH, health)
    v.add_loop("GET", NOW, now_view)
    v.add_read("GET", PAGE, page)
    # A write: opening a stream subscribes a slot and changes the count.
    v.add_write("GET", EVENTS, events)
    v.add_write("POST", DROP, drop)
    v.add_read("GET", STATS, stats)
    return v^


struct BlobsHandler(AppHandler):
    """A `Views` table that also owns the four SSE hooks."""

    var views: Views[BlobState]
    var state: BlobState

    def __init__(out self, var views: Views[BlobState], var state: BlobState):
        self.views = views^
        self.state = state^

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        # The stream's capacity is the server's connection count, since
        # slots index it.
        return BlobsHandler(
            urls(),
            BlobState(ctx.capacity, Board(ctx.page), ctx.worker, ctx.workers),
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
        # queued for every subscriber on this worker.
        self.state.stream.deliver_peer(url, event_id, frame)


def main() raises:
    var cadence = Cadence()
    if not cadence.valid():
        print("blobs: M0_BLOBS_HZ and M0_BLOBS_IDLE_HZ must be positive", flush=True)
        process_exit(78)
    var config = AppConfig()
    print(
        String(
            "blobs on ", config.base_url, " -- ", cadence.hz, " Hz, ",
            cadence.idle_hz, " Hz after ", cadence.idle_after_ms,
            " ms without a drop, ", config.workers, " worker(s)",
        ),
        flush=True,
    )
    serve[BlobsHandler, BlobsProducer](config)
