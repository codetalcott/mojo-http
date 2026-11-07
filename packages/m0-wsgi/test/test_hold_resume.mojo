"""Where a `--realtime` hold subscribes, read through a live handler.

`WSGIHandler` reads the shared event counter twice: as it is built, for
the journal's floor (a respawned worker has none of what its siblings
published before it), and as a hold lands, for the head (`_event_head`).
A smoke at one worker cannot tell either read from `replay.head`, which
equals the counter there, so these build the handler with
`M0_SHARED_ID_ADDR` naming a page whose counter they set, and around an
application registered in `sys.modules`: its one view approves a
WebSocket on `news`, the inline socket hold. The page is a
`SharedAtomics` of the test's own, which no destructor unmaps, so it
outlives every handler built over it.
"""

from std.os import setenv
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from lightbug_http.broadcast import reserved_stream_url
from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.http import HTTPRequest
from lightbug_http.uri import URI
from m0_http import SharedAtomics, StaticFiles, shared_store
from m0_http.sse.format import format_sse_event_bytes

from src.app import WSGIApp
from src.cli import ServeOptions
from src.handler import WSGIHandler
from src.thread_handler import ThreadContext


comptime APP_MODULE = "m0_test_hold_resume"

comptime APP_SOURCE = """
import sys, types

m = types.ModuleType('m0_test_hold_resume')


def application(environ, start_response):
    start_response('200 OK', [('M0-Hold', 'websocket'), ('M0-Channel', 'news')])
    return [b'']


m.application = application
sys.modules[m.__name__] = m
"""

comptime SLOT = 3


def _handler_at(counter: Int) raises -> WSGIHandler:
    """A `--realtime` handler built while the shared counter stands at
    `counter`: a worker that joins after `counter` frames went out."""
    var page = SharedAtomics(1)
    page.store(0, counter)
    _ = setenv("M0_SHARED_ID_ADDR", String(page.addr(0)), True)
    var builtins = Python.import_module("builtins")
    builtins.exec(PythonObject(APP_SOURCE), Python.dict())
    var handler = WSGIHandler(
        WSGIApp(APP_MODULE), List[StaticFiles](), realtime=True
    )
    assert_equal(handler.shared_id, page.addr(0), "the page was not read")
    return handler^


def _pending_text(mut handler: WSGIHandler, slot: Int) -> String:
    var out = handler.streams.drain(slot)
    return String(unsafe_from_utf8=Span(out))


def _publish(mut handler: WSGIHandler, channel: String, event_id: Int):
    """A frame off the bus, as `sse_peer_frame` receives every publish."""
    handler.sse_peer_frame(
        channel, event_id,
        format_sse_event_bytes(event_id, String(""), String("frame")),
    )


def test_a_resume_from_before_a_late_worker_joined_is_a_gap() raises:
    """Frames 1-40 went out before this loop existed, so its journal
    holds none of 31-40: a client resuming at 30 is told, never served
    the live feed alone as if it had missed nothing. With the floor read
    removed the journal covers 30, replays nothing and says nothing.

    covers: I33
    """
    var h = _handler_at(40)
    h.streams.subscribe(SLOT, String("news"), 30)
    h._resume(SLOT, String("news"), 30)
    var sent = _pending_text(h, SLOT)
    assert_true("event: m0-gap" in sent, "no gap frame: " + sent)
    assert_true('{"last_event_id":30,"head":40}' in sent, sent)


def test_a_resume_at_the_counter_is_caught_up_with_nothing() raises:
    """The control: a client holding frame 40, the last published before
    the loop existed, has missed nothing and is told nothing.

    covers: I33
    """
    var h = _handler_at(40)
    h.streams.subscribe(SLOT, String("news"), 40)
    h._resume(SLOT, String("news"), 40)
    assert_false(h.streams.has_pending(SLOT), _pending_text(h, SLOT))
    assert_equal(h.streams.last_event_ids[SLOT], 40)


def test_an_id_the_bus_has_not_delivered_yet_is_not_clamped() raises:
    """Siblings have published 41-45 and this loop's bus has delivered
    none yet, so its journal's head is 40. A client that got frame 43 on
    another worker is ahead of this loop, not of the server: it stays
    subscribed at 43, with no gap frame, and 44 reaches it live. Judged
    by `replay.head`, it was clamped to 40 and told of a gap that does
    not exist.

    covers: I33
    """
    var h = _handler_at(40)
    shared_store(h.shared_id, 45)
    h.streams.subscribe(SLOT, String("news"), 43)
    h._resume(SLOT, String("news"), 43)
    assert_false(h.streams.has_pending(SLOT), _pending_text(h, SLOT))
    assert_equal(h.streams.last_event_ids[SLOT], 43)
    _publish(h, String("news"), 44)
    assert_true("id: 44" in _pending_text(h, SLOT), "frame 44 did not arrive")


def test_a_socket_held_on_a_pool_thread_is_clamped_to_the_head() raises:
    """A pool thread's socket hold arrives as an `H` frame whose id field
    is the upgrade's `Last-Event-ID`. One from a previous incarnation
    (999999999 against a counter at 5) taken literally suppressed every
    frame until the counter passed it: a silent socket and a clean log.
    Clamped to the head, frame 6 reaches it.

    covers: I12
    """
    var h = _handler_at(5)
    h.sse_peer_frame(
        reserved_stream_url(String("H"), SLOT), 999999999,
        List[UInt8](String("news").as_bytes()),
    )
    assert_true(h.sockets.is_slot_streaming(SLOT), "the H frame subscribed nothing")
    assert_equal(h.sockets.last_event_ids[SLOT], 5)
    _publish(h, String("news"), 6)
    assert_true(h.sockets.has_pending(SLOT), "frame 6 was suppressed")


def test_a_socket_held_inline_is_clamped_to_the_head() raises:
    """The same socket held by the loop's own handler (no pool): the view
    approves the upgrade, the handler performs it and subscribes at the
    request's `Last-Event-ID`, clamped to the head as the `H` frame's is.

    covers: I12
    """
    var h = _handler_at(5)
    var headers = Headers(
        Header(HeaderKey.HOST, "localhost"),
        Header(HeaderKey.UPGRADE, "websocket"),
        Header(HeaderKey.CONNECTION, "Upgrade"),
        Header("Sec-WebSocket-Version", "13"),
        Header("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
        Header("Last-Event-ID", "999999999"),
    )
    var req = HTTPRequest(URI.parse("http://localhost/ws"), headers=headers^)
    req.slot_id = SLOT
    var resp = h.func(req)
    assert_equal(resp.status_code, 101)
    assert_true(h.sockets.is_slot_streaming(SLOT), "the view's hold subscribed nothing")
    assert_equal(h.sockets.last_event_ids[SLOT], 5)
    _publish(h, String("news"), 6)
    assert_true(h.sockets.has_pending(SLOT), "frame 6 was suppressed")


comptime COUNT = 64


def _made(pool: Bool) raises -> WSGIHandler:
    """A handler built as `WSGIHandler.make` builds one for a thread: a
    `--blocking-threads` pool thread's (`pool`), holding the loop's hold
    channel, or a `--threads` serving loop's. `--realtime`, with the chunk
    channel's registries on, as m0serve sets them under any pool."""
    var builtins = Python.import_module("builtins")
    builtins.exec(PythonObject(APP_SOURCE), Python.dict())
    var opts = ServeOptions()
    opts.module = String(APP_MODULE)
    opts.realtime = True
    opts.asgi_streaming = True
    opts.max_connections = COUNT
    var opts_ptr = Pointer(to=opts)
    var ctx = ThreadContext(
        0, Pointer(to=opts_ptr).unsafe_bitcast[Int]()[],
        hold_fd=7 if pool else -1, pool=pool,
    )
    var handler = WSGIHandler.make(ctx)
    _ = opts
    return handler^


def test_a_pool_threads_handler_keeps_no_stream_tables() raises:
    """A pool thread's holds go to the loop's handler as frames, and
    nothing drains a pool thread's registries, so its handler sizes them
    at 0. Sized by the count, each thread's copy was about 200 B a slot,
    1600 B at the default eight threads (#657)."""
    var h = _made(pool=True)
    assert_equal(len(h.streams.is_streaming), 0, "the SSE registry was sized")
    assert_equal(len(h.sockets.is_streaming), 0, "the socket registry was sized")
    assert_equal(len(h.hold_lane), 0, "the per-slot lists were sized")
    assert_equal(len(h.ws_parked), 0, "the parked-message table was sized")
    assert_equal(h.hold_notify_fd, 7, "the hold channel did not reach the handler")


def test_a_serving_loops_handler_keeps_a_table_a_slot() raises:
    """A `--threads` serving loop's handler holds its loop's streams, so
    its tables are sized by the loop's count, as the loop's own handler's
    are: a slot the loop hands out is one they can hold."""
    var h = _made(pool=False)
    assert_equal(len(h.streams.is_streaming), COUNT)
    assert_equal(len(h.sockets.is_streaming), COUNT)
    assert_equal(len(h.hold_lane), COUNT)
    assert_equal(len(h.ws_parked), COUNT)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
