"""A parsed request carries the headers its client sent (SPEC L25).

`HTTPRequest.from_parsed` used to go through the outgoing constructor, which
fills in what a CLIENT must send: a `Content-Length` of the body, a
`Connection` from the protocol and a `Host` from the URI. On the server side
those were inventions. A GET reached every application with a
`content-length: 0` and a `connection: keep-alive` its client never sent, and
a chunked request, once the loop had decoded its body, with BOTH
`transfer-encoding: chunked` and a `content-length` -- a contradictory pair
that an application proxying the request would forward.

Now a parsed request keeps its headers as sent, with one rewrite: a body the
loop de-chunked is a sized body, so it is described by its length and the
final `chunked` coding is removed (any other coding stays, because the body
is still in it). And since `Connection: close` is no longer written into
every HTTP/1.0 request, `connection_close()` reads the protocol itself
(RFC 9112 §9.3): 1.0 closes unless it asked to keep alive.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.header import (
    HeaderKey,
    KH_CONNECTION,
    KH_CONTENT_LENGTH,
    KH_HOST,
    KH_TRANSFER_ENCODING,
    parse_request_headers,
)
from lightbug_http.http import HTTPRequest
from lightbug_http.io.bytes import Bytes
from lightbug_http.uri import URI


def request_from(raw: String, body: String = "") raises -> HTTPRequest:
    """Parse a request the way the server's read path does: the header parse,
    then `from_parsed` with the body the loop read (decoded, if chunked)."""
    var parsed = parse_request_headers(raw.as_bytes())
    try:
        return HTTPRequest.from_parsed(
            "http://localhost", parsed^, Bytes(body.as_bytes()), 8192
        )
    except:
        raise Error("fixture request failed to build")


def test_a_bodiless_get_carries_no_invented_content_length() raises:
    """A GET with no body reaches the application with no `Content-Length`.

    covers: L25
    """
    var req = request_from("GET / HTTP/1.1\r\nHost: a\r\n\r\n")
    assert_true(req.headers.known_index(KH_CONTENT_LENGTH) < 0)


def test_a_request_carries_no_connection_or_host_it_did_not_send() raises:
    """Neither a `Connection` nor, on HTTP/1.0, a `Host` is filled in.

    covers: L25
    """
    var req = request_from("GET / HTTP/1.1\r\nHost: a\r\n\r\n")
    assert_true(req.headers.known_index(KH_CONNECTION) < 0)
    var old = request_from("GET / HTTP/1.0\r\n\r\n")
    assert_true(old.headers.known_index(KH_CONNECTION) < 0)
    assert_true(old.headers.known_index(KH_HOST) < 0)
    # And what the client did send is kept as it sent it.
    var sent = request_from("GET / HTTP/1.1\r\nHost: a\r\nConnection: keep-alive\r\n\r\n")
    assert_equal(sent.headers.get(HeaderKey.CONNECTION).value(), "keep-alive")


def test_a_dechunked_request_carries_its_length_and_no_transfer_encoding() raises:
    """A body the loop de-chunked is described by its length, not its coding.

    covers: L25
    """
    var req = request_from(
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n",
        "chunked",
    )
    assert_equal(req.headers.get(HeaderKey.CONTENT_LENGTH).value(), "7")
    assert_true(req.headers.known_index(KH_TRANSFER_ENCODING) < 0)


def test_a_dechunked_request_keeps_its_other_transfer_codings() raises:
    """Only the final `chunked` goes: a gzip coding still describes the body.

    covers: L25
    """
    var req = request_from(
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        "zipped",
    )
    assert_equal(req.headers.get(HeaderKey.TRANSFER_ENCODING).value(), "gzip")
    assert_equal(req.headers.get(HeaderKey.CONTENT_LENGTH).value(), "6")


def test_empty_list_elements_leave_no_empty_transfer_encoding() raises:
    """RFC 9110 §5.6.1: empty list elements are accepted and mean nothing, so
    `, chunked` is a lone `chunked` -- no empty field beside the length --
    and `gzip,,chunked` keeps `gzip`.

    covers: L25
    """
    var bare = request_from(
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: , chunked\r\n\r\n", "abc"
    )
    assert_true(bare.headers.known_index(KH_TRANSFER_ENCODING) < 0)
    assert_equal(bare.headers.get(HeaderKey.CONTENT_LENGTH).value(), "3")
    var gz = request_from(
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip,,chunked\r\n\r\n", "abc"
    )
    assert_equal(gz.headers.get(HeaderKey.TRANSFER_ENCODING).value(), "gzip")


def test_transfer_encoding_case_does_not_matter() raises:
    """RFC 9112 §7.1: coding names are case-insensitive, so `CHUNKED` goes too.
    """
    var req = request_from(
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: CHUNKED\r\n\r\n", "abc"
    )
    assert_true(req.headers.known_index(KH_TRANSFER_ENCODING) < 0)
    assert_equal(req.headers.get(HeaderKey.CONTENT_LENGTH).value(), "3")


def test_a_client_content_length_is_kept_as_sent() raises:
    """A length the client sent is never dropped, a zero one included."""
    var zero = request_from("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n")
    assert_equal(zero.headers.get(HeaderKey.CONTENT_LENGTH).value(), "0")
    var five = request_from(
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\n", "hello"
    )
    assert_equal(five.headers.get(HeaderKey.CONTENT_LENGTH).value(), "5")


def test_http10_closes_unless_it_asks_to_keep_alive() raises:
    """RFC 9112 §9.3, now read from the protocol rather than an invented header.
    """
    assert_true(request_from("GET / HTTP/1.0\r\n\r\n").connection_close())
    assert_false(
        request_from("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n").connection_close()
    )
    assert_true(
        request_from("GET / HTTP/1.0\r\nConnection: close\r\n\r\n").connection_close()
    )
    assert_false(request_from("GET / HTTP/1.1\r\nHost: a\r\n\r\n").connection_close())
    assert_true(
        request_from("GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n").connection_close()
    )
    assert_true(
        request_from("GET / HTTP/1.1\r\nHost: a\r\nConnection: CLOSE\r\n\r\n").connection_close()
    )


def test_the_outgoing_constructor_still_fills_its_headers() raises:
    """The client's constructor keeps filling what a client must send."""
    var req = HTTPRequest(URI.parse("http://example.com/x"), body=Bytes("hi".as_bytes()))
    assert_equal(req.headers.get(HeaderKey.CONTENT_LENGTH).value(), "2")
    assert_equal(req.headers.get(HeaderKey.CONNECTION).value(), "keep-alive")
    assert_true(req.headers.known_index(KH_HOST) >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
