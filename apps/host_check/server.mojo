"""The Mojo host's own gate: the smallest application that uses all of it.

    GET  /health   liveness -- answered in `before_request`, ON THE LOOP,
                   so it stays answered whatever a pool is busy with
    GET  /pid      this worker's pid, as text (what `accept_spread.py` asks)
    GET  /events   the producer's beats, as SSE; `x-worker` names the worker.
                   Opened in `before_request` too: a stream is subscribed
                   in the LOOP instance's registry, the one the loop
                   drains, so it works under a pool
    GET  /events-from-func
                   the same stream opened in `func`: what a pool thread
                   refuses 409, kept as a route so the gate pins that
    GET  /slow?ms=N  spins for N ms in `func`: the placement load

`smoke-host` (SPEC E21-E23, E25, E26) drives it. The application is
nothing but the two conformances `lightbug_http.host` asks for — a handler
with `make`, a producer with `make` and `step` — so what the gate observes
is the host: which workers hold streams, whether every one of them gets
every beat, where accepted connections land, how a drain ends, what
happens to a producer that will not stop, and where a request is served
under `M0_BLOCKING_THREADS`. Under a pool a stream opened in `func` is
refused 409 -- it would subscribe a pool thread's registry, which nothing
drains (`mojo_pool.mojo`) -- so `/events` opens on the loop and
`/events-from-func` keeps the refused shape for the gate to pin.

Six knobs, all for the gate:

    M0_HOSTCHECK_PERIOD_MS   the beat's period (default 100)
    M0_HOSTCHECK_STEP_MS     how long each beat sleeps before it publishes
                             (default 0; the overrun arm sets it past the
                             host's join bound)
    M0_HOSTCHECK_MAX_WORKERS what `max_workers` answers (default 0, any),
                             so the gate can prove the host asks
    M0_HOSTCHECK_MAKE_RAISES=1
                             the handler's `make` raises, naming the knob:
                             the host must refuse with 78, not crash-loop
    M0_HOSTCHECK_PRODUCER_RAISES=1
                             the producer's `make` raises the same way; at
                             two workers only worker 0 builds one, and the
                             supervisor must end worker 1 with it
    M0_HOSTCHECK_POOL_MAKE_RAISES=1
                             the handler's `make` raises on a POOL thread
                             alone (`ctx.thread >= 0`): the host must
                             refuse with 78 before it serves, never run a
                             pool one thread short

Each beat's id comes from the host's shared word (`Publisher.next_id`),
never from a counter of this process's own: the gate's respawn phase kills
worker 0 and requires a stream already held on worker 1 to beat again,
which the loop's redelivery filter forbids for a producer that restarted
its numbering below what the stream has seen.

Run it:  uv run poe serve-host-check
"""

from std.os import getenv
from std.time import perf_counter_ns, sleep

from lightbug_http import OK, HTTPRequest, HTTPResponse
from lightbug_http.c.process import getpid
from lightbug_http.host import AppHandler, HostContext, Producer, Publisher, serve

from m0_http import AppConfig, SSERegistry, format_sse_event, sse_response

comptime STREAM = "/events"


def _digits(val: String) -> Int:
    """A non-negative decimal, or 0 for anything else."""
    var result = 0
    for b in val.as_bytes():
        var c = Int(b)
        if c < ord("0") or c > ord("9"):
            return 0
        result = result * 10 + (c - ord("0"))
    return result


def _env_ms(name: String, default: Int) -> Int:
    """A non-negative millisecond count from the environment, or `default`."""
    var val = getenv(name, "")
    if val.byte_length() == 0:
        return default
    var result = 0
    for b in val.as_bytes():
        var c = Int(b)
        if c < ord("0") or c > ord("9"):
            return default
        result = result * 10 + (c - ord("0"))
    return result


struct Beat(Producer):
    """One numbered beat per period, to every worker."""

    var period_ns: Int
    var cost_s: Float64
    var n: Int

    def __init__(out self, period_ms: Int, cost_ms: Int):
        self.period_ns = period_ms * 1_000_000
        self.cost_s = Float64(cost_ms) / 1000.0
        self.n = 0

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        if getenv("M0_HOSTCHECK_PRODUCER_RAISES", "") == "1":
            raise Error("M0_HOSTCHECK_PRODUCER_RAISES: the producer refuses to be built")
        return Beat(
            _env_ms("M0_HOSTCHECK_PERIOD_MS", 100), _env_ms("M0_HOSTCHECK_STEP_MS", 0)
        )

    def step(mut self, mut out: Publisher) raises -> Int:
        if self.cost_s > 0:
            sleep(self.cost_s)
        # The id is the host's, so a respawned producer continues the
        # numbering; `n` counts this process's own beats for the payload.
        self.n += 1
        var id = out.next_id()
        var frame = format_sse_event(
            id, "beat", String('{"beat":', self.n, ',"pid":', getpid(), "}")
        )
        _ = out.publish(STREAM, id, frame.as_bytes())
        return self.period_ns


struct Check(AppHandler):
    """Serves the beats; knows its worker and nothing else."""

    var streams: SSERegistry
    var worker: Int

    def __init__(out self, capacity: Int, worker: Int):
        self.streams = SSERegistry(capacity)
        self.worker = worker

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        if getenv("M0_HOSTCHECK_MAKE_RAISES", "") == "1":
            raise Error("M0_HOSTCHECK_MAKE_RAISES: the handler refuses to be built")
        if ctx.thread >= 0 and getenv("M0_HOSTCHECK_POOL_MAKE_RAISES", "") == "1":
            raise Error(
                "M0_HOSTCHECK_POOL_MAKE_RAISES: the handler refuses to be built on"
                " pool thread " + String(ctx.thread)
            )
        return Check(ctx.capacity, ctx.worker)

    @staticmethod
    def max_workers() -> Int:
        return _env_ms("M0_HOSTCHECK_MAX_WORKERS", 0)

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        # On the loop, in every shape: the route that must answer while
        # every pool thread is inside a slow view, and the stream, whose
        # subscription must land in the registry the loop drains.
        if req.uri.path == "/health":
            return OK('{"status":"ok"}', "application/json")
        if req.uri.path == STREAM:
            return self._open_stream(req)
        return None

    def _open_stream(mut self, req: HTTPRequest) -> HTTPResponse:
        self.streams.subscribe(req.slot_id, STREAM, 0)
        var resp = sse_response()
        resp.headers["x-worker"] = String(self.worker)
        return resp^

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var path = req.uri.path
        if path == "/pid":
            return OK(String(getpid()), "text/plain")
        if path == "/slow":
            # A spin, not a sleep: what holds the thread that serves it,
            # loop or pool, and what the placement phase measures against.
            var ms = 0
            try:
                ref q = req.uri.queries
                if "ms" in q:
                    ms = _digits(q["ms"])
            except:
                pass
            var deadline = perf_counter_ns() + ms * 1_000_000
            var spins = 0
            while perf_counter_ns() < deadline:
                spins += 1
            return OK(String('{"ms":', ms, ',"spins":', spins, "}"), "application/json")
        if path == "/events-from-func":
            # Correct without a pool (the loop's own instance), refused
            # with one: the shape the docstring names.
            return self._open_stream(req)
        return OK("host_check", "text/plain")

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return self.streams.drain(slot)

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.streams.is_slot_streaming(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        self.streams.unsubscribe(slot)

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        _ = self.streams.notify_frame(url, event_id, frame)


def main() raises:
    var config = AppConfig()
    print(String("host_check on ", config.base_url, ", ", config.workers, " worker(s)"), flush=True)
    serve[Check, Beat](config)
