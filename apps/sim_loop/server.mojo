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

That thread is the Mojo host's `Producer` (`lightbug_http.host`): this app
writes `SimProducer.step` and the host does the four things this file used
to do by hand, each of which is easy to get wrong -- and this app got one
wrong, publishing to `bus.write_fds[0]` alone under a comment saying every
worker received the frames, while its gate ran one worker:

1. **The bus is created, and drained, at one worker too.** Here it is the
   thread-to-loop channel, not only worker-to-worker, and publishing with
   nothing draining fails quietly.
2. **`skip_worker = -1`.** Nothing has queued the step locally, so every
   channel wants it, this worker's included.
3. **Every worker's channel.** The step reaches `Publisher`, which holds
   all of them and hides the descriptors, so a list of one cannot be
   spelled. The gate's two-worker phase is the counterfactual.
4. **A bounded join at shutdown.** A step that overruns must not turn
   SIGTERM into a hang, and `pthread_join` has no timeout; the host waits
   the drain's 5 s on the producer's status slot and then leaves.

`M0_SIM_ON_LOOP=1` moves the identical step onto `tick`. Same work, same
cadence, same publish — the only difference is which thread runs it. It is
the A/B knob (`M0_ACCEPT_SHARE`, `M0_POOL_RING`, `M0_POOL_ELASTIC` are the
others) and the negative arm of `smoke-sim-loop`: without it the gate
would pass on a server that does no work at all. Under it the producer is
not `wanted`, so the host starts no thread.

Under `M0_WORKERS>1` only worker 0 runs the simulation — the tick-owner
rule — and every worker's loop receives the frames over the same bus. The
host shares accepts between workers (`AcceptShare`, SPEC E16), so held
streams spread across them instead of all landing on whichever worker
wakes first, and `/events` names its worker in `x-worker` so a client can
tell. The on-loop arm queues each step locally with `notify`, so it
reaches worker 0's subscribers only; it is the one-worker latency
comparison, not a fan-out shape.

Run it:  uv run poe serve-sim
"""

from std.os import getenv
from std.time import perf_counter_ns

from lightbug_http import HTTPRequest, HTTPResponse, OK
from lightbug_http.host import AppHandler, HostContext, Producer, Publisher, serve

from m0_http import AppConfig, SSERegistry, format_sse_event, sse_response
from m0_http.multiworker import shared_fetch_add

comptime STREAM_URL = "/events"

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


struct SimConfig(Copyable, Movable):
    """The cadence and the budget, from `M0_SIM_HZ`, `M0_SIM_COST_MS` and
    `M0_SIM_ON_LOOP`."""

    var hz: Int
    var cost_ms: Int
    var on_loop: Bool

    def __init__(out self):
        self.hz = _env_int("M0_SIM_HZ", 4)
        self.cost_ms = _env_int("M0_SIM_COST_MS", 200)
        self.on_loop = getenv("M0_SIM_ON_LOOP", "") == "1"

    def period_ms(self) -> Int:
        return 1000 // self.hz if self.hz > 0 else 0


struct SimProducer(Producer):
    """The simulation thread: cadence, work, publish. Never touches the loop."""

    var period_ns: Int
    var cost_ns: Int
    var step_no: Int

    def __init__(out self, sim: SimConfig):
        self.period_ns = sim.period_ms() * 1_000_000
        self.cost_ns = sim.cost_ms * 1_000_000
        self.step_no = 0

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return SimProducer(SimConfig())

    @staticmethod
    def wanted(ctx: HostContext) -> Bool:
        # The on-loop arm runs the step on `tick` instead, and a zero rate
        # runs nothing at all.
        var sim = SimConfig()
        return not sim.on_loop and sim.period_ms() > 0

    def step(mut self, mut out: Publisher) raises -> Int:
        self.step_no += 1
        var state = simulate(self.step_no, self.cost_ns)
        var frame = format_sse_event(self.step_no, "sim", state)
        _ = out.publish(STREAM_URL, self.step_no, frame.as_bytes())
        return self.period_ns


struct SimHandler(AppHandler):
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

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        # The registry indexes slots directly, so its capacity is the
        # server's connection count.
        var sim = SimConfig()
        return SimHandler(
            ctx.capacity,
            sim.on_loop,
            sim.cost_ms * 1_000_000,
            sim.period_ms(),
            tick_owner=ctx.tick_owner(),
            id_addr=ctx.id_addr,
            worker=ctx.worker,
        )

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
    var sim = SimConfig()
    print(
        String(
            "sim_loop on ", config.address(), " — ", sim.hz, "Hz x ",
            sim.cost_ms, "ms (", "ON the loop" if sim.on_loop else "off the loop", ")",
        )
    )
    var server_config = config.server_config()
    if sim.on_loop:
        # The on-loop arm drives its OWN cadence rather than inheriting
        # M0_APP_TICK_MS. Without this the tick never fires unless the
        # operator happens to set that variable too, and the arm reads as
        # "the loop coped fine" when in truth nothing ran — the exact
        # quiet failure this app is here to argue against. The gate
        # asserts frames on this arm for the same reason.
        server_config.app_tick_ms = sim.period_ms()
    serve[SimHandler, SimProducer](config, server_config^)
