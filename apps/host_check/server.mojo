"""The Mojo host's own gate: the smallest application that uses all of it.

    GET  /health   liveness
    GET  /pid      this worker's pid, as text (what `accept_spread.py` asks)
    GET  /events   the producer's beats, as SSE; `x-worker` names the worker

`smoke-host` (SPEC E21-E23) drives it. The application is nothing but the
two conformances `lightbug_http.host` asks for — a handler with `make`, a
producer with `make` and `step` — so what the gate observes is the host:
which workers hold streams, whether every one of them gets every beat,
where accepted connections land, how a drain ends, and what happens to a
producer that will not stop.

Five knobs, all for the gate:

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

Each beat's id comes from the host's shared word (`Publisher.next_id`),
never from a counter of this process's own: the gate's respawn phase kills
worker 0 and requires a stream already held on worker 1 to beat again,
which the loop's redelivery filter forbids for a producer that restarted
its numbering below what the stream has seen.

Run it:  uv run poe serve-host-check
"""

from std.os import getenv
from std.time import sleep

from lightbug_http import OK, HTTPRequest, HTTPResponse
from lightbug_http.c.process import getpid
from lightbug_http.host import AppHandler, HostContext, Producer, Publisher, serve

from m0_http import AppConfig, SSERegistry, format_sse_event, sse_response

comptime STREAM = "/events"


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
        return Check(ctx.capacity, ctx.worker)

    @staticmethod
    def max_workers() -> Int:
        return _env_ms("M0_HOSTCHECK_MAX_WORKERS", 0)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var path = req.uri.path
        if path == "/health":
            return OK('{"status":"ok"}', "application/json")
        if path == "/pid":
            return OK(String(getpid()), "text/plain")
        if path == STREAM:
            self.streams.subscribe(req.slot_id, STREAM, 0)
            var resp = sse_response()
            resp.headers["x-worker"] = String(self.worker)
            return resp^
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
