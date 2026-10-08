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
final `chunked` coding is removed (no other coding reaches it: the parser
refuses one with 501, SPEC B21). And since `Connection: close` is no longer written into
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


def test_empty_list_elements_leave_no_empty_transfer_encoding() raises:
    """RFC 9110 §5.6.1: empty list elements are accepted and mean nothing, so
    `, chunked` is a lone `chunked` -- no empty field beside the length.

    covers: L25
    """
    var bare = request_from(
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: , chunked\r\n\r\n", "abc"
    )
    assert_true(bare.headers.known_index(KH_TRANSFER_ENCODING) < 0)
    assert_equal(bare.headers.get(HeaderKey.CONTENT_LENGTH).value(), "3")


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


def _closes(connection: String, version: String = "1.1") raises -> Bool:
    var raw = String("GET / HTTP/", version, "\r\nHost: a\r\nConnection: ")
    raw += connection + "\r\n\r\n"
    return request_from(raw).connection_close()


def test_connection_is_read_as_a_list_of_tokens() raises:
    """RFC 9110 §7.6.1: `Connection` lists option tokens, so `close` closes
    wherever it stands, and a 1.0 `keep-alive` keeps alive the same way.
    The whole value was compared, and `close, TE` kept the connection,
    answering the request pipelined behind it.

    covers: B17
    """
    assert_true(_closes("close, TE"))
    assert_true(_closes("TE, close"))
    assert_true(_closes("TE,close"))
    assert_true(_closes("Upgrade , CLOSE ,"))
    assert_true(_closes(", ,close"))
    # OWS is SP or HTAB (RFC 9110 §5.6.3), around any member.
    assert_true(_closes("\tclose\t, TE"))
    assert_true(_closes("TE,\tclose"))
    assert_false(_closes("\tkeep-alive\t,TE", "1.0"))
    # A member must BE the token: neither a longer nor a shorter one.
    assert_false(_closes("closed"))
    assert_false(_closes("close-ish, TE"))
    assert_false(_closes("clos"))
    assert_false(_closes("TE"))
    # HTTP/1.0 persists when `keep-alive` is among the options.
    assert_false(_closes("keep-alive, Upgrade", "1.0"))
    assert_false(_closes("Upgrade,Keep-Alive", "1.0"))
    assert_true(_closes("keep-alive-ish", "1.0"))
    assert_true(_closes("keep-alive, close", "1.0"))


def test_repeated_connection_lines_are_read_as_one_list() raises:
    """RFC 9110 §5.3: field lines of one name combine into one list, in
    order, comma-SP. The header store keeps the LAST line of a repeated
    field, so `Connection: close` then `Connection: keep-alive` kept the
    connection, and an HTTP/1.0 `keep-alive` before a `TE` line closed it.
    The application reads the combined value.

    covers: B22
    """
    var head = String("GET / HTTP/1.1\r\nHost: a\r\n")
    var req = request_from(
        head + "Connection: close\r\nConnection: keep-alive\r\n\r\n"
    )
    assert_true(req.connection_close())
    assert_equal(req.headers.get(HeaderKey.CONNECTION).value(), "close, keep-alive")
    assert_true(
        request_from(head + "Connection: TE\r\nconnection: CLOSE\r\n\r\n").connection_close()
    )
    var three = request_from(
        head + "Connection: a\r\nX-Other: 1\r\nConnection: b\r\nConnection: close\r\n\r\n"
    )
    assert_equal(three.headers.get(HeaderKey.CONNECTION).value(), "a, b, close")
    assert_true(three.connection_close())
    assert_false(
        request_from(
            "GET / HTTP/1.0\r\nConnection: keep-alive\r\nConnection: TE\r\n\r\n"
        ).connection_close()
    )
    assert_false(
        request_from(head + "Connection: keep-alive\r\nConnection: TE\r\n\r\n").connection_close()
    )


def test_the_outgoing_constructor_still_fills_its_headers() raises:
    """The client's constructor keeps filling what a client must send."""
    var req = HTTPRequest(URI.parse("http://example.com/x"), body=Bytes("hi".as_bytes()))
    assert_equal(req.headers.get(HeaderKey.CONTENT_LENGTH).value(), "2")
    assert_equal(req.headers.get(HeaderKey.CONNECTION).value(), "keep-alive")
    assert_true(req.headers.known_index(KH_HOST) >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
