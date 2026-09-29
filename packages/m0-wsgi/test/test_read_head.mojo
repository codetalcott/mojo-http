"""The application's response head as the gateway reads it, through a live
interpreter: what m0-wsgi still refuses as it reads a head.

The fork's head writers refuse CR, LF and NUL for every response (SPEC G1,
G2), so the wire no longer depends on m0-wsgi. What a writer cannot do is
unread a value the gateway acted on before any writer ran: `take_hold`
takes `M0-Hold` and `M0-Channel` off a WSGI response, and a HEAD's or a
304's answer keeps the application's `Content-Length`. `PyBridge.read_head`
drops a header whose name or value carries one of the three bytes before
any of that, and these are the tests that fail without it: `smoke-wsgi`'s
injecting route passes with the refusal removed, the writers dropping what
it lets through.
"""

from std.python import Python
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from lightbug_http.hold import HOLD_NONE, take_hold

from src.bridge import PyBridge
from src.response import build_asgi_response, build_response


def test_a_channel_carrying_a_line_break_is_never_held() raises:
    """A WSGI view approving a stream on a channel it built from request
    data: `M0-Channel` carrying CR LF, then one carrying NUL. Neither may
    become a hold's channel: the head is read without it, `take_hold` finds
    no channel and serves the ordinary response, instruction headers
    stripped, and the clean header beside them is kept."""
    var bridge = PyBridge()
    for channel in ["news\\r\\nX-Evil: 1", "news\\x00tail"]:
        var headers = Python.evaluate(
            "[('M0-Hold', 'stream'), ('M0-Channel', '" + channel + "'),"
            " ('X-Clean', 'ordinary')]"
        )
        var resp = build_response(
            bridge, String("200 OK"), headers, Python.evaluate("b'body'")
        )
        var hold = take_hold(resp)
        assert_equal(
            hold.mode, HOLD_NONE,
            "a hold was taken on a channel carrying a control byte",
        )
        assert_false(resp.sse_streaming)
        assert_false("m0-hold" in resp.headers)
        assert_false("m0-channel" in resp.headers)
        assert_true("x-clean" in resp.headers, "the clean header was dropped too")


def test_a_head_measures_its_body_when_its_length_carries_a_line_break() raises:
    """A HEAD answer keeps the application's `Content-Length` (it describes
    the body a GET would carry, RFC 9110 §9.3.2), so an injected one is
    what the response holds unless the read refuses it -- and the writer
    then drops it, leaving the HEAD with no length at all. Refused at the
    read, a WSGI application that answers HEAD like GET is measured."""
    var bridge = PyBridge()
    var headers = Python.evaluate(
        "[('Content-Length', '5\\r\\nX-Evil: 1'), ('X-Clean', 'ordinary')]"
    )
    var resp = build_response(
        bridge, String("200 OK"), headers, Python.evaluate("b'hello'"),
        is_head=True,
    )
    var length = resp.headers.get("content-length")
    assert_true(Bool(length), "the HEAD answer has no Content-Length")
    assert_equal(length.value(), "5")
    assert_false("x-evil" in resp.headers)


def test_an_asgi_304_keeps_no_length_carrying_a_line_break() raises:
    """The ASGI head, `(bytes, bytes)` pairs read from their own buffers:
    a 304 keeps the application's length (RFC 9110 §8.6), so one carrying
    CR LF must not be kept, and the `ETag` beside it must."""
    var bridge = PyBridge()
    var headers = Python.evaluate(
        "[(b'content-length', b'5\\r\\nx-evil: 1'), (b'etag', b'\"a\"')]"
    )
    var resp = build_asgi_response(
        bridge, 304, headers, Python.evaluate("b''")
    )
    assert_false(
        "content-length" in resp.headers,
        "a 304 kept a Content-Length carrying a line break",
    )
    assert_true("etag" in resp.headers, "the clean header was dropped too")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
