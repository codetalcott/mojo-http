"""Datastar counter — live multi-tab sync over one SSE stream.

The smallest app that exercises the whole Datastar path:

    GET  /            the page, with the current count already rendered
    GET  /events      opens the SSE stream (data-on-load)
    POST /increment   mutates, then broadcasts to every open stream
    POST /decrement   likewise

Open two tabs and press a button in one; the other updates without a reload.
The page also shows a live uptime clock driven by the `tick` hook
(`M0_APP_TICK_MS`, e.g. 1000): the event loop's own timer broadcasts the
patch — no inbound request involved, which no earlier version of this
framework could express. Under `M0_WORKERS>1` only worker 0 drives the
clock, and everyone else's tabs get it over the bus.
That is the entire point, and it is what `DatastarStream` exists to make
possible — the builders in `m0_datastar.sse` produce complete SSE frames, which
`SSERegistry.notify` cannot carry without double-framing them.

It is also the reference wiring for **cross-worker SSE fan-out**. With
`M0_WORKERS>1` this app creates, before the fork: the listener every worker
accepts from, a `BroadcastBus` (one datagram channel per worker), and a
`SharedAtomics` page (slot 0: SSE event ids, slot 1: the count, slot 2:
uptime seconds). Each
worker then joins the bus with `enable_bus`, hands its channel to the server,
and wires `sse_peer_frame` → `deliver_peer` — after which a button press
handled by any worker updates tabs connected to every worker. The count lives
in shared memory so all workers agree on it without a database.

Run it:  uv run poe serve-counter        (M0_WORKERS=2 for the fan-out shape)
"""

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.broadcast import BroadcastBus
from lightbug_http.c.process import getpid
from lightbug_http.connection import ListenConfig
from lightbug_http.header import Headers, Header, HeaderKey

from m0_http import (
    AppConfig, WorkerSupervisor, install_shutdown_signals, exit_worker,
)
from m0_http.multiworker import SharedAtomics, shared_fetch_add, shared_load

from m0_datastar.stream import DatastarStream
from m0_datastar.signals import read_signals

from datastar_counter.page import render_page


comptime STREAM_URL = "/events"


struct CounterHandler(HTTPService):
    """One counter, shared by every connected client."""

    # The count is a shared atomic (a `SharedAtomics` slot), not a field:
    # under M0_WORKERS>1 every worker must read and bump the same number, and
    # in single-worker mode the same code simply runs uncontended.
    var count_addr: Int
    # Uptime seconds, also shared: the page renders it consistently no
    # matter which worker serves the GET, and a respawned tick owner
    # continues the count instead of restarting it.
    var uptime_addr: Int
    # Exactly one worker drives the clock. Every worker's loop ticks, but
    # only the owner bumps and broadcasts — otherwise N workers would each
    # patch every tab N times a second (locally and over the bus).
    var tick_owner: Bool
    var _last_bump_ms: Int
    var stream: DatastarStream

    def __init__(out self, count_addr: Int, uptime_addr: Int, tick_owner: Bool):
        self.count_addr = count_addr
        self.uptime_addr = uptime_addr
        self.tick_owner = tick_owner
        self._last_bump_ms = 0
        # Must be at least the server's max connections: slots are indexed
        # directly by req.slot_id.
        self.stream = DatastarStream(1024)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var path = req.uri.path

        if path == "/health":
            # subscribers surfaces the stream registry's live count — how the
            # smoke asserts a vanished client is actually unsubscribed, not
            # left as a stale registration queueing bytes nobody will read.
            return OK(
                '{"status":"ok","subscribers":'
                + String(self.stream.subscriber_count(STREAM_URL))
                + "}",
                "application/json",
            )

        if path == "/":
            return _html(render_page(
                shared_load(self.count_addr), shared_load(self.uptime_addr)
            ))

        if path == STREAM_URL:
            var resp = self.stream.open(req, STREAM_URL)
            # Which worker owns this stream — the multi-worker smoke reads
            # this to prove its streams span workers before asserting that
            # one POST reaches all of them.
            resp.headers["X-Worker"] = String(getpid())
            return resp^

        if path == "/increment" or path == "/decrement":
            # The browser posts its whole signal store. This demo keeps the
            # count server-side and ignores the client's copy, but reading it
            # is how you would accept client-supplied input.
            _ = read_signals(req)

            var count: Int
            if path == "/increment":
                count = shared_fetch_add(self.count_addr, 1) + 1
            else:
                count = shared_fetch_add(self.count_addr, -1) - 1

            # One broadcast reaches every tab, including the one that clicked
            # — and, over the bus, tabs held by every other worker.
            _ = self.stream.patch_signals(
                STREAM_URL, '{"count":' + String(count) + "}"
            )
            # The POST itself needs no body: the update arrives over the stream.
            return HTTPResponse(
                body_bytes=String("").as_bytes(), status_code=204, status_text="No Content"
            )

        return HTTPResponse(
            body_bytes=String('{"error":"not found"}').as_bytes(),
            headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
            status_code=404,
            status_text="Not Found",
        )

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        pass

    # --- The four SSE hooks, wired straight through to the stream ----------

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return self.stream.drain(slot)

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.stream.is_streaming(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        self.stream.closed(slot)

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        # A broadcast from another worker: queue it for this worker's
        # subscribers (and journal it, so replay works on every worker).
        self.stream.deliver_peer(url, event_id, frame)

    def tick(mut self, now_ms: Int):
        # The server-initiated push the framework could not express before
        # this hook existed: nobody sends a request, and every tab's uptime
        # advances anyway. The tick may fire faster than once a second
        # (M0_APP_TICK_MS); the sub-schedule below decides when to act —
        # the intended pattern for handlers with their own cadences.
        if not self.tick_owner:
            return
        if now_ms - self._last_bump_ms < 1000:
            return
        self._last_bump_ms = now_ms
        var up = shared_fetch_add(self.uptime_addr, 1) + 1
        # The tick carries the WHOLE signal state, not just the clock.
        # Cross-worker ordering is best-effort: a count patch racing an
        # uptime patch can lose (the newer id wins the redelivery filter),
        # and a tab would show a stale count until the next click. Ticks
        # that reconcile full state heal any lost race within a second —
        # the recommended shape for increment-y signals under fan-out.
        _ = self.stream.patch_signals(
            STREAM_URL,
            '{"uptime":' + String(up)
            + ',"count":' + String(shared_load(self.count_addr)) + "}",
        )

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        pass


def _html(body: String) -> HTTPResponse:
    return HTTPResponse(
        body_bytes=body.as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/html; charset=utf-8")),
        status_code=200,
        status_text="OK",
    )


def main() raises:
    var config = AppConfig()
    print("Datastar counter on " + config.base_url + " — open it in two tabs")

    # Everything workers must share is created BEFORE the fork, so every
    # process inherits it: the listener (all workers accept from this one
    # socket), the broadcast bus channels, and the shared atomics — slot 0
    # numbers SSE events across workers, slot 1 is the count. In
    # single-worker mode the same objects simply serve one process.
    var listener = ListenConfig().listen(config.address())
    var shared = SharedAtomics(3)
    var bus = BroadcastBus(config.workers)
    var worker = 0
    if config.workers > 1:
        var supervisor = WorkerSupervisor(config.workers)
        supervisor.fork_all()
        worker = supervisor.worker_index

    var handler = CounterHandler(
        shared.addr(1), shared.addr(2), tick_owner=(worker == 0)
    )
    var bus_read_fd = -1
    if config.workers > 1:
        # Joining the bus is three-sided: the stream publishes to peers and
        # takes ids from the shared slot; the server drains this worker's
        # channel; sse_peer_frame (above) delivers what arrives.
        handler.stream.enable_bus(bus, worker, shared.addr(0))
        bus_read_fd = bus.read_fd(worker)

    # Heartbeats keep idle streams alive through proxies and NATs, and let the
    # loop discover dead subscribers; M0_SSE_HEARTBEAT_MS tunes the cadence
    # (the smoke sets it low to assert heartbeats actually arrive).
    var server = Server(config.server_config(), config.address())
    # SSE requires the non-blocking event loop: only it assigns `req.slot_id`
    # and drains the outbox; the plain accept loop would answer every stream
    # open with 409.
    # After fork_all, so each worker arms its own pipe: dispositions and fds
    # are inherited, and a pre-fork install would point every worker at the
    # supervisor's pipe, which nothing is watching. The supervisor arms itself
    # separately, so signalling it alone still reaps the workers.
    var shutdown_fd = install_shutdown_signals()
    server.serve_nonblocking(
        listener, handler, shutdown_read_fd=shutdown_fd, bus_read_fd=bus_read_fd
    )
    if config.workers > 1:
        # A drained worker must not fall off the end of main — see exit_worker.
        exit_worker()
