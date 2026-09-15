"""Periodic work that does NOT run on the event loop.

The reference wiring for an application with a simulation cadence — a game
tick, a physics step, a pricing pass — where the work has a real budget.

    GET  /health   liveness
    GET  /now      a trivial request, the one the gate times
    GET  /events   the SSE stream carrying each simulation step
    GET  /         a page that opens the stream

`HTTPService.tick` is the wrong home for this. It runs ON the event loop
thread, so its cost is its DUTY CYCLE: work over period. Retention tracks
`1 - duty` and the work transfers into p99 about one for one, so a 200ms
step at 4Hz — what this app does by default — would hold every connection
for 200ms at a time. The tick is for SCHEDULING; this is what to do
instead.

So the cadence runs on a thread of its own and publishes each step through
the `BroadcastBus`, exactly as `--pg-listen`'s listener thread does. The
loop drains the channel and pays only `sse_peer_frame`.

Four things here are the point, and each is a thing that is easy to get
wrong somewhere else:

1. **The bus is created unconditionally, at one worker too.** In
   `apps/datastar_counter` the bus is joined only when `M0_WORKERS>1`,
   because there it is cross-worker fan-out. Here it is the THREAD-to-LOOP
   channel and is needed in a single process. Publishing with nothing
   draining fails quietly — the frames simply never arrive.
2. **`skip_worker = -1`, not this worker's index.** Nothing has queued the
   step locally, so every channel wants it, this one's included. Passing
   the worker index is the same silent nothing.
3. **The thread holds EVERY worker's write fd, not the first.**
   `publish_to_channels` sends to exactly the list it is given, so a list
   of one reaches worker 0's subscribers and nobody else's. This app
   shipped that way — `bus.write_fds[0]` — under a comment saying every
   worker received the frames, and its gate ran one worker, where the two
   are the same list. The gate's two-worker phase is the counterfactual.
4. **The thread is joined within a bound at shutdown.** A step that
   overruns must not turn SIGTERM into a hang, and `pthread_join` has no
   timeout — `join_within` waits on the body's status slot instead, which
   is why the body writes `BLK_STATUS` as its very last act.

`M0_SIM_ON_LOOP=1` moves the identical step onto `tick`. Same work, same
cadence, same publish — the only difference is which thread runs it. It is
the A/B knob (`M0_ACCEPT_SHARE`, `M0_POOL_RING`, `M0_POOL_ELASTIC` are the
others) and the negative arm of `smoke-sim-loop`: without it the gate
would pass on a server that does no work at all.

Under `M0_WORKERS>1` only worker 0 runs the simulation — the tick-owner
rule — and every worker's loop receives the frames over the same bus. The
workers share accepts (`AcceptShare`, SPEC E16), so held streams spread
across them instead of all landing on whichever worker wakes first, and
`/events` names its worker in `x-worker` so a client can tell. The on-loop
arm queues each step locally with `notify`, so it reaches worker 0's
subscribers only; it is the one-worker latency comparison, not a fan-out
shape.

Run it:  uv run poe serve-sim
"""

from std.ffi import external_call
from std.memory import Pointer
from std.os import getenv
from std.time import perf_counter_ns, sleep

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.accept_share import AcceptShare, accept_share_slots
from lightbug_http.broadcast import BroadcastBus, publish_to_channels
from lightbug_http.connection import ListenConfig

from m0_http import (
    AppConfig,
    SSERegistry,
    WorkerSupervisor,
    exit_worker,
    format_sse_event,
    install_shutdown_signals,
    sse_response,
)
from m0_http.multiworker import SharedAtomics, shared_fetch_add
from m0_http.threads import (
    BLK_STATUS,
    BLK_USER,
    STATUS_OK,
    ThreadBlock,
    ThreadSet,
)

comptime STREAM_URL = "/events"

comptime BLK_COST = 10
"""Per-step work budget in nanoseconds."""

comptime BLK_STOP = 11
"""Set to 1 by the main thread to end the simulation."""

comptime BLK_FDS = 12
"""Address of the bus write fds, one Int per worker (process-lifetime)."""

comptime BLK_NFDS = 13
"""How many fds `BLK_FDS` holds: the worker count."""

comptime JOIN_TIMEOUT_NS = 5_000_000_000
"""The drain's own 5s. A straggler is abandoned, not waited for."""

comptime PAGE = String(
    "<!doctype html><title>sim_loop</title>"
    "<h1>sim_loop</h1><pre id=out>waiting…</pre>"
    "<script>new EventSource('/events').addEventListener('sim',"
    "e=>{document.getElementById('out').textContent=e.data})</script>"
)


def _env_int(name: String, default: Int) -> Int:
    """Parse an integer environment variable, or return `default`."""
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


def simulate(step: Int, cost_ns: Int) -> String:
    """One simulation step: burn the budget, return the state to broadcast.

    A spin rather than a sleep on purpose — a sleeping step would release
    the loop thread and hide the very cost this app exists to show.
    """
    var spins = 0
    if cost_ns > 0:
        var deadline = perf_counter_ns() + cost_ns
        while perf_counter_ns() < deadline:
            spins += 1
    return String('{"step":') + String(step) + ',"spins":' + String(spins) + "}"


def sim_body(arg: Int) -> Int:
    """The simulation thread: cadence, work, publish. Never touches the loop.

    Runs beside an interpreter it has not attached to and holds no server
    state — the only thing it shares with the loops is the bus sockets, one
    per worker.
    """
    var block = ThreadBlock(arg)
    var period_ns = block.get(BLK_USER)
    var cost_ns = block.get(BLK_COST)
    var fds_addr = block.get(BLK_FDS)
    var fds = List[Int]()
    for i in range(block.get(BLK_NFDS)):
        fds.append(
            Pointer[Int, MutUntrackedOrigin](unsafe_from_address=fds_addr + i * 8)[]
        )

    var step = 0
    var next_ns = perf_counter_ns()
    while block.get(BLK_STOP) == 0:
        next_ns += period_ns
        step += 1
        var state = simulate(step, cost_ns)
        var frame = format_sse_event(step, "sim", state)
        # skip_worker = -1: every channel, this worker's included. Nothing
        # has queued this locally, unlike an in-process publish.
        publish_to_channels(fds, -1, STREAM_URL, step, frame.as_bytes())
        var now = perf_counter_ns()
        if next_ns > now:
            sleep(Float64(next_ns - now) / 1_000_000_000.0)
        else:
            # Behind the cadence: do not try to catch up, or an overrunning
            # step compounds into a busy loop that never sleeps again.
            next_ns = now
    # Last act, and load-bearing: `join_within` waits on this slot.
    block.set(BLK_STATUS, STATUS_OK)
    return 0


struct SimHandler(HTTPService):
    """Serves the stream; never computes a step unless told to on the loop."""

    var streams: SSERegistry
    var on_loop: Bool
    var cost_ns: Int
    var period_ms: Int
    var tick_owner: Bool
    var id_addr: Int
    var worker: Int
    var _last_step_ms: Int

    def __init__(
        out self,
        capacity: Int,
        on_loop: Bool,
        cost_ns: Int,
        period_ms: Int,
        tick_owner: Bool,
        id_addr: Int,
        worker: Int,
    ):
        self.streams = SSERegistry(capacity)
        self.on_loop = on_loop
        self.cost_ns = cost_ns
        self.period_ms = period_ms
        self.tick_owner = tick_owner
        self.id_addr = id_addr
        self.worker = worker
        self._last_step_ms = 0

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var path = req.uri.request_uri
        if path == "/health":
            return OK('{"status":"ok"}', "application/json")
        if path == "/now":
            # Deliberately trivial. What this answers is not the question —
            # how long it waited to be answered is.
            return OK("now", "text/plain")
        if path == STREAM_URL:
            self.streams.subscribe(req.slot_id, STREAM_URL, 0)
            # Which worker holds this stream: the only way a client can tell
            # that a frame crossed the bus rather than being produced beside it.
            var resp = sse_response()
            resp.headers["x-worker"] = String(self.worker)
            return resp^
        return OK(PAGE, "text/html")

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return self.streams.drain(slot)

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.streams.is_slot_streaming(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        self.streams.unsubscribe(slot)

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        # The whole off-loop seam, from the loop's side: a frame arrives on
        # the bus channel and is queued for this worker's subscribers. The
        # loop pays this and the drain, and nothing else.
        _ = self.streams.notify_frame(url, event_id, frame)

    def tick(mut self, now_ms: Int):
        # Only reached under M0_SIM_ON_LOOP=1 — the negative arm. This is
        # the shape the app exists to argue against, kept runnable so the
        # gate can measure it rather than take the claim on trust.
        if not self.on_loop or not self.tick_owner:
            return
        if now_ms - self._last_step_ms < self.period_ms:
            return
        self._last_step_ms = now_ms
        var step = shared_fetch_add(self.id_addr, 1) + 1
        var state = simulate(step, self.cost_ns)
        _ = self.streams.notify(STREAM_URL, step, "sim", state)


def main() raises:
    var config = AppConfig()
    var hz = _env_int("M0_SIM_HZ", 4)
    var cost_ms = _env_int("M0_SIM_COST_MS", 200)
    var on_loop = getenv("M0_SIM_ON_LOOP", "") == "1"
    var period_ms = 1000 // hz if hz > 0 else 0

    print(
        String("sim_loop on ")
        + config.address()
        + " — "
        + String(hz)
        + "Hz x "
        + String(cost_ms)
        + "ms ("
        + ("ON the loop" if on_loop else "off the loop")
        + ")"
    )

    var listener = ListenConfig().listen(config.address())
    # Slot 0 is the event id; accept sharing's per-worker lines follow it on
    # the same page (`accept_share_slots`), which is m0serve's layout.
    var shared = SharedAtomics(accept_share_slots(config.workers))
    # Unconditional, and at one worker too: this is the thread-to-loop
    # channel, not only worker-to-worker. See the module docstring.
    var bus = BroadcastBus(config.workers)
    # Created pre-fork like the bus: one channel per worker, every worker
    # holding every send end. Without it one worker takes nearly every
    # connection (SPEC E16). `M0_ACCEPT_SHARE=0` is the bare race.
    var share = AcceptShare()
    if config.workers > 1 and getenv("M0_ACCEPT_SHARE", "") != "0":
        share = AcceptShare(config.workers)
    var worker = 0
    if config.workers > 1:
        var supervisor = WorkerSupervisor(config.workers)
        supervisor.fork_all()
        worker = supervisor.worker_index
    # Inactive with one worker or under the knob; `bind` is harmless there.
    share.bind(worker, shared.addr(0))

    # The registry indexes slots directly, so its capacity must be at least
    # the server's max connections.
    var server_config = config.server_config()
    if on_loop:
        # The on-loop arm drives its OWN cadence rather than inheriting
        # M0_APP_TICK_MS. Without this the tick never fires unless the
        # operator happens to set that variable too, and the arm reads as
        # "the loop coped fine" when in truth nothing ran — the exact
        # quiet failure this app is here to argue against. The gate
        # asserts frames on this arm for the same reason.
        server_config.app_tick_ms = period_ms
    var handler = SimHandler(
        server_config.max_connections,
        on_loop,
        cost_ms * 1_000_000,
        period_ms,
        tick_owner=(worker == 0),
        id_addr=shared.addr(0),
        worker=worker,
    )

    # One simulation, in worker 0 — the tick-owner rule. Every worker's loop
    # still receives its frames, because every channel gets the publish: the
    # thread is handed ALL the write fds. One of them reaches worker 0 alone.
    var threads = ThreadSet(1)
    var running = not on_loop and worker == 0 and period_ms > 0
    if running:
        # Process-lifetime, like the thread set's own blocks: the thread may
        # outlive `main`'s last use of anything here (a straggler abandoned
        # at the join), so nothing it reads may be a local Mojo destroys.
        var nfds = len(bus.write_fds)
        var fds_addr = external_call["malloc", Int, Int](nfds * 8)
        for i in range(nfds):
            Pointer[Int, MutUntrackedOrigin](
                unsafe_from_address=fds_addr + i * 8
            )[] = bus.write_fds[i]
        threads.block(0).set(BLK_FDS, fds_addr)
        threads.block(0).set(BLK_NFDS, nfds)
        threads.block(0).set(BLK_USER, period_ms * 1_000_000)
        threads.block(0).set(BLK_COST, cost_ms * 1_000_000)
        threads.block(0).set(BLK_STOP, 0)
        var body = sim_body
        threads.spawn(0, Pointer(to=body).unsafe_bitcast[Int]()[])

    var server = Server(server_config^, config.address())
    var shutdown_fd = install_shutdown_signals()
    server.serve_nonblocking(
        listener,
        handler,
        shutdown_read_fd=shutdown_fd,
        bus_read_fd=bus.read_fd(worker),
        accept_share=share^,
    )

    # The loop has drained and returned. Tell the simulation to stop and
    # give it the drain's own 5s; a step still running after that is
    # abandoned rather than waited for, because nothing here can interrupt
    # it and a longer wait only makes SIGTERM a no-op until SIGKILL.
    if running:
        threads.block(0).set(BLK_STOP, 1)
        var stragglers = threads.join_within(JOIN_TIMEOUT_NS)
        if stragglers > 0:
            print("sim_loop: abandoned a simulation step still running")
    if config.workers > 1:
        exit_worker()
