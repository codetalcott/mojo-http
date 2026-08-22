"""Serve a sync Django project with live SSE — no ASGI anywhere.

    uv run poe serve-django-realtime                  # http://localhost:8080
    M0_WORKERS=2 uv run poe serve-django-realtime     # cross-worker fan-out

The composition `apps/django_wsgi` and `apps/datastar_counter` each show half
of: one handler holds both a `WSGIApp` and an `SSERegistry`. Django runs
every request synchronously, exactly as in `django_wsgi` — and when a view
answers with `M0-Hold: stream` + `M0-Channel: <name>`, `take_stream_hold`
converts that ordinary buffered response into an SSE hold and the handler
subscribes the connection's slot. Django decides who may subscribe and to
what (it can consult sessions, tokens, anything); the Mojo layer owns the
connection from then on — heartbeats, disconnect cleanup, fan-out.

Publishing never enters Mojo at all. `m0pub.py` writes complete SSE frames
as bus datagrams to every worker's inherited channel — including this one's,
whose event loop drains it into `sse_peer_frame` like any peer frame. That
is why `bus_read_fd` is passed even in single-worker mode: draining our own
channel IS local delivery; there is no second path to keep in sync.

Fork ordering marries the two halves' rules. Everything shared is created
BEFORE the fork (the listener, the bus — and the `M0_BUS_WRITE_FDS` export,
which must precede the fork so every worker's environment agrees, and must
precede any Python touch so every embedded interpreter is born seeing it).
The first Python call — constructing `WSGIApp` — stays AFTER the fork, per
worker, because forking a live CPython interpreter is unsafe.
"""

from std.os import getenv, setenv

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.broadcast import BroadcastBus
from lightbug_http.c.process import getpid
from lightbug_http.connection import ListenConfig
from lightbug_http.header import Headers, Header, HeaderKey

from m0_http import (
    AppConfig, SSERegistry, WorkerSupervisor, install_shutdown_signals,
    exit_worker,
)
from m0_wsgi import WSGIApp, take_stream_hold


struct RealtimeHandler(HTTPService):
    var app: WSGIApp
    var registry: SSERegistry

    def __init__(out self, var app: WSGIApp):
        self.app = app^
        # Must be at least the server's max connections: slots are indexed
        # directly by req.slot_id.
        self.registry = SSERegistry(1024)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        if req.uri.path == "/health":
            # Answered in Mojo, never enters Django: the live subscriber
            # count is how the smoke asserts a vanished client is actually
            # unsubscribed, and it must stay readable while a slow view has
            # the interpreter busy.
            return OK(
                '{"status":"ok","subscribers":'
                + String(self.registry.active_count())
                + "}",
                "application/json",
            )

        var slot = req.slot_id
        var resp = self.app.serve(req)
        var hold = take_stream_hold(resp)
        if hold.held:
            if slot < 0:
                # The blocking accept loop never assigns slots; a hold under
                # it would leak a subscription nothing can drain. Mirror
                # DatastarStream.open and refuse.
                return _conflict()
            self.registry.subscribe(slot, hold.channel, 0)
            # Which worker holds this stream — the multi-worker smoke reads
            # this to prove its streams span workers before asserting that
            # one publish reaches all of them.
            resp.headers["x-worker"] = String(getpid())
        return resp^

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        pass

    # --- SSE hooks: the registry is the whole implementation ---------------

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return self.registry.drain(slot)

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.registry.is_slot_streaming(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        self.registry.unsubscribe(slot)

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        # Every published frame arrives here — from peer workers AND from
        # this worker's own Django (m0pub writes all channels, ours
        # included). `url` is the channel name; the registry fans out to
        # every slot subscribed to it.
        self.registry.notify_frame(url, event_id, frame)

    def tick(mut self, now_ms: Int):
        pass

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        pass


def _conflict() -> HTTPResponse:
    return HTTPResponse(
        body_bytes=String(
            '{"error":"stream open requires the non-blocking event loop"}'
        ).as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=409,
        status_text="Conflict",
    )


def main() raises:
    var config = AppConfig()
    var port = String(config.port)
    # Where `djangoproj` and `m0pub` live; see apps/django_wsgi for the rule.
    var project_path = getenv("M0_DJANGO_PROJECT", "apps/django_realtime")

    # Bind before forking; every worker accepts from this one socket.
    var listener = ListenConfig().listen(String("0.0.0.0:", port))

    # The bus is created pre-fork so every worker inherits every channel —
    # and exported pre-fork, pre-Python, so every worker's embedded
    # interpreter is born with M0_BUS_WRITE_FDS already in its environment
    # (CPython snapshots the C environ at interpreter init).
    var bus = BroadcastBus(config.workers)
    var fds_csv = String("")
    for i in range(len(bus.write_fds)):
        if i > 0:
            fds_csv += ","
        fds_csv += String(bus.write_fds[i])
    _ = setenv("M0_BUS_WRITE_FDS", fds_csv, True)

    # Fork before touching Python — see the module docstring.
    var multiprocess = config.workers > 1
    var worker = 0
    if multiprocess:
        var supervisor = WorkerSupervisor(config.workers)
        supervisor.fork_all()
        worker = supervisor.worker_index

    var app = WSGIApp(
        "djangoproj.wsgi",
        server_name="0.0.0.0",
        server_port=port,
        project_path=project_path,
        multiprocess=multiprocess,
    )
    var handler = RealtimeHandler(app^)

    print("Starting Django realtime server on 0.0.0.0:" + port)
    var server = Server(config.server_config())
    # After fork_all — each worker arms its own pipe. See datastar_counter.
    var shutdown_fd = install_shutdown_signals()
    # bus_read_fd unconditionally, unlike datastar_counter: single-worker
    # publish delivery IS the bus (Python writes our channel; we drain it).
    server.serve_nonblocking(
        listener,
        handler,
        shutdown_read_fd=shutdown_fd,
        bus_read_fd=bus.read_fd(worker),
    )
    if multiprocess:
        exit_worker()
