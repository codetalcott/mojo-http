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

The step runs on a thread of its own (`apps/sim_loop` is the reference and
says why the tick is the wrong home), publishing every step as a whole
state frame through the `BroadcastBus` to every worker's channel with
`skip_worker = -1`. The loop drains it into `sse_peer_frame`, where the
stream keeps it as the newest state (`send_latest`), so a tab that opens
the stream — first visit, reconnect or a restarted server — is sent the
current world at once instead of a replay or a blank.

The producer pauses while nobody watches and slows to `M0_BLOBS_IDLE_HZ`
after `M0_BLOBS_IDLE_MS` without a drop. Clicks and viewer counts reach it
through the shared page in `board.mojo`, never through `malloc`'d memory,
because a fork is where the Mojo host takes this next.

**One process, on purpose, for now.** Serving from several workers means
accept sharing, clicks landing on a worker other than the producer's and a
viewer count summed across workers — all of it the Mojo host's job, and
written here by hand it would be written once to be deleted. `M0_WORKERS`
above 1 is refused rather than half-served. The board is laid out per
worker already.

`main` is annotated: `[host]` marks what every Mojo app with a producer
writes and the host will own, `[blobs]` what is this app's. That split is
the host's first specification.

THE KERNEL IS A STAND-IN (`kernel.mojo`): circles, no merging. The
metaball kernel replaces `trace` behind the same contract.

Run it:  uv run poe serve-blobs
"""

from std.ffi import external_call
from std.memory import Pointer
from std.os import getenv
from std.time import perf_counter_ns, sleep

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse
from lightbug_http.broadcast import BroadcastBus, publish_to_channels
from lightbug_http.c.process import process_exit
from lightbug_http.connection import ListenConfig

from m0_core.json_parse import parse_json_number

from m0_http import AppConfig, Views, install_shutdown_signals, reply
from m0_http.multiworker import SharedAtomics
from m0_http.threads import BLK_STATUS, BLK_USER, STATUS_OK, ThreadBlock, ThreadSet

from m0_datastar.signals import read_signals
from m0_datastar.stream import DatastarStream

from blobs.board import (
    B_ACTIVE_NS,
    B_FRAME_BYTES,
    B_FRAME_MAX,
    B_IDLE_AFTER_NS,
    B_IDLE_NS,
    B_LAST_ID,
    B_LOST,
    B_APPLIED,
    B_OVER_BUDGET,
    B_PAUSED,
    B_PERIOD_MS,
    B_REFUSED,
    B_STEPS,
    B_STEP_NS,
    B_STEP_NS_MAX,
    Board,
    DropReader,
    board_slots,
)
from blobs.kernel import Shapes, trace
from blobs.page import render_page
from blobs.routes import DROP, EVENTS, HEALTH, NOW, PAGE, STATS
from blobs.wire import state_frame
from blobs.world import STAGE, World

comptime WORKERS = 1
"""Phase 1 serves from one process; see the module docstring."""

comptime STEP_BUDGET_NS = 2_000_000
"""What a step may cost before `/stats` counts it over budget.

A fraction of what a Fly shared vCPU earns per 100 ms (6.25% of a core,
6.25 ms), because the loop, the writes and the frame all spend from the
same allowance. The metaball kernel measured ~0.3 ms on an M4.
"""

comptime DROPS_PER_SECOND = 4
"""Drops one connection may make per second; the rest are answered 429."""

comptime PAUSE_POLL_S = Float64(0.02)
"""How often a paused producer looks for a viewer."""

comptime BLK_STOP = 10
"""Set to 1 by the main thread to end the producer."""

comptime BLK_FDS = 11
"""Address of the bus write fds, one Int per worker (process-lifetime)."""

comptime BLK_NFDS = 12
"""How many fds `BLK_FDS` holds."""

comptime JOIN_TIMEOUT_NS = 5_000_000_000
"""The drain's own 5 s; a producer still stepping after that is abandoned."""


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


# --- The producer thread ------------------------------------------------------


def producer_body(arg: Int) -> Int:
    """Step, trace, publish, sleep — and pause while nobody watches.

    Holds the world and nothing of the server's. What it shares with the
    loop is the bus sockets (one per worker) and the board page.
    """
    var block = ThreadBlock(arg)
    var board = Board(block.get(BLK_USER))
    var fds_addr = block.get(BLK_FDS)
    var fds = List[Int]()
    for i in range(block.get(BLK_NFDS)):
        fds.append(
            Pointer[Int, MutUntrackedOrigin](unsafe_from_address=fds_addr + i * 8)[]
        )
    var active_ns = board.load(B_ACTIVE_NS)
    var idle_ns = board.load(B_IDLE_NS)
    var idle_after_ns = board.load(B_IDLE_AFTER_NS)

    var world = World()
    var shapes = Shapes()
    var drops = DropReader()
    var step = 0
    var last_drop_ns = perf_counter_ns()
    var next_ns = perf_counter_ns()
    while block.get(BLK_STOP) == 0:
        var viewers = board.viewers(WORKERS)
        if viewers == 0:
            # Nobody to draw for: no step, no frame. The world waits where
            # it is, and the next viewer is sent that state at open.
            board.store(B_PAUSED, 1)
            sleep(PAUSE_POLL_S)
            next_ns = perf_counter_ns()
            continue
        board.store(B_PAUSED, 0)

        var now = perf_counter_ns()
        if drops.take(board, world) > 0:
            last_drop_ns = now
        var period_ns = active_ns
        if idle_after_ns > 0 and now - last_drop_ns >= idle_after_ns:
            period_ns = idle_ns
        board.store(B_PERIOD_MS, period_ns // 1_000_000)

        var t0 = perf_counter_ns()
        world.advance(Float64(period_ns) / 1_000_000_000.0)
        trace(world, shapes)
        var step_ns = perf_counter_ns() - t0
        step += 1
        var frame = state_frame(
            shapes, step, step_ns // 1000, viewers, world.count(),
            Int(period_ns // 1_000_000),
        )
        # skip_worker = -1: every channel, this worker's included — nothing
        # has queued the frame locally. A shortfall is counted: a frame the
        # bus refuses is otherwise indistinguishable from no step at all.
        var sent = publish_to_channels(fds, -1, EVENTS, step, frame.as_bytes())
        if sent < len(fds):
            board.add(B_REFUSED, 1)

        board.store(B_STEPS, step)
        board.store(B_LAST_ID, step)
        board.store(B_STEP_NS, step_ns)
        if step_ns > board.load(B_STEP_NS_MAX):
            board.store(B_STEP_NS_MAX, step_ns)
        if step_ns > STEP_BUDGET_NS:
            board.add(B_OVER_BUDGET, 1)
        board.store(B_FRAME_BYTES, frame.byte_length())
        if frame.byte_length() > board.load(B_FRAME_MAX):
            board.store(B_FRAME_MAX, frame.byte_length())

        next_ns += period_ns
        var after = perf_counter_ns()
        if next_ns > after:
            sleep(Float64(next_ns - after) / 1_000_000_000.0)
        else:
            # Behind: do not catch up, or an overrun compounds into a loop
            # that never sleeps.
            next_ns = after
    # Last act, and load-bearing: `join_within` waits on this slot.
    block.set(BLK_STATUS, STATUS_OK)
    return 0


# --- The views ----------------------------------------------------------------


struct BlobState(Movable):
    """What the views read and write, and what the SSE hooks drive."""

    var stream: DatastarStream
    var board: Board
    var worker: Int
    var capacity: Int
    var _window_ms: List[Int]
    var _window_drops: List[Int]

    def __init__(out self, capacity: Int, board: Board, worker: Int):
        # A stream of states: the newest frame at open, never a replay, and
        # no journal, since nothing here reads one.
        self.stream = DatastarStream(capacity, journal_entries=0, send_latest=True)
        self.board = board
        self.worker = worker
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
        ',"frame_bytes":', b.load(B_FRAME_BYTES),
        ',"frame_max":', b.load(B_FRAME_MAX),
        ',"refused":', b.load(B_REFUSED),
        ',"drops":', b.load(B_APPLIED),
        ',"lost":', b.load(B_LOST),
        ',"paused":', b.load(B_PAUSED),
        ',"period_ms":', b.load(B_PERIOD_MS),
        ',"viewers":', b.viewers(WORKERS),
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


struct BlobsHandler(HTTPService):
    """A `Views` table that also owns the four SSE hooks."""

    var views: Views[BlobState]
    var state: BlobState

    def __init__(out self, var views: Views[BlobState], var state: BlobState):
        self.views = views^
        self.state = state^

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
    var config = AppConfig()  # [host]
    # [blobs] The cadence, and when an untouched stage slows down.
    var hz = _env_int("M0_BLOBS_HZ", 10)
    var idle_hz = _env_int("M0_BLOBS_IDLE_HZ", 2)
    var idle_after_ms = _env_int("M0_BLOBS_IDLE_MS", 60_000)
    if hz <= 0 or idle_hz <= 0:
        print("blobs: M0_BLOBS_HZ and M0_BLOBS_IDLE_HZ must be positive", flush=True)
        process_exit(78)
    # [host, not yet] Several workers is the host's to wire; refuse, never
    # half-serve (see the module docstring).
    if config.workers != WORKERS:
        print(
            "blobs: serves from one process until the Mojo host exists;"
            " unset M0_WORKERS",
            flush=True,
        )
        process_exit(78)
    print(
        String(
            "blobs on ", config.base_url, " — ", hz, " Hz, ", idle_hz,
            " Hz after ", idle_after_ms, " ms without a drop",
        ),
        flush=True,
    )

    var listener = ListenConfig().listen(config.address())  # [host]
    # [host] Shared state and the bus exist before any fork, at one worker
    # too: the bus is the thread-to-loop channel here.
    var shared = SharedAtomics(board_slots(WORKERS))
    var bus = BroadcastBus(WORKERS)
    var worker = 0
    # [blobs] The board's layout and configuration.
    var board = Board(shared.addr(0))
    board.store(B_ACTIVE_NS, 1_000_000_000 // hz)
    board.store(B_IDLE_NS, 1_000_000_000 // idle_hz)
    board.store(B_IDLE_AFTER_NS, idle_after_ms * 1_000_000)

    # [host] The handler is built after the fork, per worker; its stream's
    # capacity is the server's connection count, since slots index it.
    var server_config = config.server_config()
    var handler = BlobsHandler(
        urls(), BlobState(server_config.max_connections, board, worker)
    )

    # [host] One producer, on the tick owner (worker 0), handed EVERY
    # worker's bus write fd. Process-lifetime memory: a producer abandoned
    # at the join may outlive `main`'s locals.
    var threads = ThreadSet(1)
    var nfds = len(bus.write_fds)
    var fds_addr = external_call["malloc", Int, Int](nfds * 8)
    for i in range(nfds):
        Pointer[Int, MutUntrackedOrigin](unsafe_from_address=fds_addr + i * 8)[] = (
            bus.write_fds[i]
        )
    threads.block(0).set(BLK_FDS, fds_addr)
    threads.block(0).set(BLK_NFDS, nfds)
    threads.block(0).set(BLK_USER, board.base)  # [blobs] what the producer reads
    threads.block(0).set(BLK_STOP, 0)
    var body = producer_body  # [blobs] the producer itself
    threads.spawn(0, Pointer(to=body).unsafe_bitcast[Int]()[])

    # [host] Serve: signals armed after any fork, the bus channel drained.
    var server = Server(server_config^, config.address())
    var shutdown_fd = install_shutdown_signals()
    server.serve_nonblocking(
        listener,
        handler,
        shutdown_read_fd=shutdown_fd,
        bus_read_fd=bus.read_fd(worker),
    )

    # [host] Drained: stop the producer and give it the drain's own bound.
    threads.block(0).set(BLK_STOP, 1)
    var stragglers = threads.join_within(JOIN_TIMEOUT_NS)
    if stragglers > 0:
        print("blobs: abandoned a producer step still running", flush=True)
