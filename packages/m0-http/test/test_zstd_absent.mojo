"""A stream that asks for zstd on a box without libzstd goes out
uncompressed (docs/notes/compressing-a-stream.md, step 3).

A file of its own because libzstd, once opened, is the process's for good
(`lightbug_http/c/zstd.mojo`): this process names a library that is not
there before anything opens one.
"""

from std.ffi import c_int
from std.os import setenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http import HTTPRequest, HTTPResponse, HTTPService, OK
from lightbug_http.c.platform import MSG_DONTWAIT, PlatformBackend
from lightbug_http.c.socket import close, recv
from lightbug_http.connection import ConnectionState
from lightbug_http.loop.response import _finish_response
from lightbug_http.loop.state import LoopState
from lightbug_http.server_config import ServerConfig
from test.support import _stream_pair


def test_a_stream_that_asked_for_zstd_without_the_library_goes_out_plain() raises:
    """The response's `Content-Encoding` comes off, since nothing would
    honour it; the body is the bytes the application wrote; the slot holds
    no context; and the loop records that it has said why, once.

    covers: I45
    """
    _ = setenv("M0_LIBZSTD", "/nonexistent/m0-zstd-absent/libzstd.so.1", True)
    var config = ServerConfig()
    config.max_connections = 2
    config.sse_heartbeat_ms = 0
    var st = LoopState(RawFileDescriptor(-1), config, String(""), True)
    var backend = PlatformBackend()
    var app = _NoApp()
    var pair = _stream_pair()
    var fd = pair[0]
    var slot = st.provision_pool.borrow()
    st.slot_fds[slot] = fd
    st.fd_to_slot[fd] = slot
    st.active_count = 1
    st.offload.http11[slot] = True
    st.offload.is_head[slot] = False
    st.provision_pool.provisions[slot].state = ConnectionState.processing()
    var response = OK(": open\n\n", "text/event-stream")
    response.sse_streaming = True
    response.zstd_stream = True
    response.headers["content-encoding"] = "zstd"
    _finish_response(app, backend, st, slot, fd, response^)

    assert_false(Bool(st.slot_zstd[slot]), "a context without a library")
    assert_true(st.zstd_refused, "the refusal was not recorded")
    var buf = List[UInt8](length=4096, fill=0)
    var n = Int(recv(RawFileDescriptor(c_int(pair[1])), Span(buf), MSG_DONTWAIT))
    var wire = String(unsafe_from_utf8=Span(buf)[:n]).lower()
    assert_false("content-encoding" in wire, wire)
    assert_true(wire.endswith("\r\n\r\n: open\n\n"), wire)
    close(RawFileDescriptor(c_int(fd)))
    close(RawFileDescriptor(c_int(pair[1])))


struct _NoApp(HTTPService):
    def __init__(out self):
        pass

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return OK("unused", "text/plain")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
