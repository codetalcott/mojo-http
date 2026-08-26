"""The blocking accept loop refuses what it cannot honour (issue #118).

`gate_streaming_response` is the decision the blocking loop applies to every
handler response. Tested directly because driving `listen_and_serve` needs a
real socket pair; the loop's only involvement is calling this on the one
line between the handler and the wire, so the function IS the behaviour.
"""
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from lightbug_http import HTTPResponse, HeaderKey
from lightbug_http.header import Headers, Header
from lightbug_http.io.bytes import Bytes
from lightbug_http.server import gate_streaming_response
from m0_http.sse import sse_response


def test_plain_response_passes_through() raises:
    var response = HTTPResponse(
        "hello".as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/plain")),
    )
    var out = gate_streaming_response(response^)
    assert_equal(out.status_code, 200)
    assert_false(out.sse_streaming)


def test_sse_response_becomes_409() raises:
    # The exact object `sse_response()` documents as "the event loop keeps
    # the connection open" -- which the blocking loop used to write as a
    # one-shot body and close, silently.
    var out = gate_streaming_response(sse_response())
    assert_equal(out.status_code, 409)
    # The refusal must name the fix, or it is a dead end for the reader.
    var body = String(StringSlice(unsafe_from_utf8=Span(out.body_raw)))
    assert_true("listen_and_serve_nonblocking" in body)


def test_websocket_101_becomes_409() raises:
    # Same machinery gap, other transport: a 101 asks the loop to switch
    # the socket to frame mode, and only the event loop can.
    var response = HTTPResponse(
        Bytes(),
        headers=Headers(Header("Upgrade", "websocket")),
        status_code=101,
        status_text="Switching Protocols",
    )
    var out = gate_streaming_response(response^)
    assert_equal(out.status_code, 409)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
