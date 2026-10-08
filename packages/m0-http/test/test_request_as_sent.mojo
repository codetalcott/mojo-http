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
refuses one, SPEC B21). And since `Connection: close` is no longer written into
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
from lightbug_http.header import Headers
from lightbug_http.http import HTTPRequest, URITooLongError, split_server_address
from lightbug_http.io.bytes import Bytes
from lightbug_http.uri import URI


def request_from(
    raw: String, body: String = "", server_addr: String = "http://localhost"
) raises -> HTTPRequest:
    """Parse a request the way the server's read path does: the header parse,
    then `from_parsed` with the body the loop read (decoded, if chunked) and
    the server's address split as the loop splits it."""
    var parsed = parse_request_headers(raw.as_bytes())
    var host_port = split_server_address(server_addr)
    try:
        return HTTPRequest.from_parsed(
            host_port[0], host_port[1], parsed^, Bytes(body.as_bytes()), 8192
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


def test_the_uri_names_the_server_the_same_way_whatever_the_target() raises:
    """`uri.host` and `uri.port` are the address the server listens on, and
    `uri.request_uri` the request target as the application reads it, for
    every target shape and scheme case. They depended on the target: with
    the loop on `0.0.0.0:8973`, `GET /x` read host `0.0.0.0:8973` and no
    port, `GET /x?q=1` host `0.0.0.0` and port 8973, and `GET HTTP://h/p`
    differed from `GET http://h/p?q=1` the same way (review record LF54).
    The authority an absolute-form target names is the request's `Host`
    (B16), not its URI's.

    covers: A37
    """
    var addrs = [
        (String("0.0.0.0:8973"), String("0.0.0.0"), 8973),
        (String("127.0.0.1:8080"), String("127.0.0.1"), 8080),
        (String("[::1]:8080"), String("[::1]"), 8080),
        (String("http://localhost"), String("localhost"), -1),
        (String("127.0.0.1"), String("127.0.0.1"), -1),
    ]
    # (request line, Host value, request_uri)
    var targets = [
        (String("GET /x"), String("a"), String("/x")),
        (String("GET /x?q=1"), String("a"), String("/x?q=1")),
        (String("GET /a%20b"), String("a"), String("/a%20b")),
        (String("GET /a%20b?q=1"), String("a"), String("/a%20b?q=1")),
        (String("GET http://h/p?q=1"), String("h"), String("/p?q=1")),
        (String("GET HTTP://h/p"), String("h"), String("/p")),
        (String("GET http://h:81/p"), String("h:81"), String("/p")),
        (String("GET https://h"), String("h"), String("/")),
        (String("OPTIONS *"), String("a"), String("*")),
    ]
    for a in addrs:
        for t in targets:
            var raw = String(t[0], " HTTP/1.1\r\nHost: a\r\n\r\n")
            var req = request_from(raw, server_addr=a[0])
            var where = String(a[0], " ", t[0])
            assert_equal(req.uri.host, a[1], where)
            if a[2] < 0:
                assert_false(Bool(req.uri.port), where)
            else:
                assert_true(Bool(req.uri.port), where)
                assert_equal(Int(req.uri.port.value()), a[2], where)
            assert_equal(req.uri.request_uri, t[2], where)
            assert_equal(req.headers.get(HeaderKey.HOST).value(), t[1], where)


def _request_line(var req: HTTPRequest) -> String:
    """The first line `encode` writes, CRLF excluded."""
    var wire = req^.encode()
    var end = 0
    while end < len(wire) and wire[end] != 0x0D:
        end += 1
    return String(unsafe_from_utf8=Span(wire)[:end])


def test_a_request_is_written_with_its_target_as_received() raises:
    """`encode` and `write_to` write the request target as it arrived or as
    the URL gave it: the percent-DECODED path went into the request line,
    so `/a%20b` went out as `/a b` (no longer one request line's target),
    an encoded CR LF as the real bytes (a split line), and an asterisk-form
    `OPTIONS *` as `OPTIONS /` (review record LF62).

    covers: A38
    """
    var head = String(" HTTP/1.1\r\nHost: a\r\n\r\n")
    var targets = ["/a%20b?x=1", "/a%20b", "/x?q=a%26b", "/p", "*", "/"]
    for t in targets:
        var method = String("OPTIONS") if String(t) == "*" else String("GET")
        var line = String(method, " ", t, " HTTP/1.1")
        var req = request_from(String(method, " ", t, head))
        assert_equal(req.uri.request_uri, String(t))
        assert_true(String(req).startswith(line + "\r\n"), String("write_to: ", t))
        assert_equal(_request_line(req^), line)
    # A URL's escapes stay escapes: never a CR LF the request line splits on.
    var built = HTTPRequest(URI.parse("http://example.com/x%0D%0AEvil:%201?a=%0A"))
    assert_equal(_request_line(built^), "GET /x%0D%0AEvil:%201?a=%0A HTTP/1.1")
    # An absolute-form target is written as the path it was reduced to.
    assert_equal(
        _request_line(request_from("GET http://h/p?q=1 HTTP/1.1\r\nHost: h\r\n\r\n")),
        "GET /p?q=1 HTTP/1.1",
    )
def test_a_server_wide_options_reaches_the_application_as_an_asterisk() raises:
    """`OPTIONS *` names the server, not its root (RFC 9112 §3.2.4), and
    the application reads `*` as its path and its request target: both were
    `/`, so an application could not tell it from `OPTIONS /` (review record
    LF41). Both spellings of the server's address are held, and `OPTIONS /`
    stays the root.

    covers: B19
    """
    for addr in [String("http://localhost"), String("127.0.0.1:8973")]:
        var req = request_from(
            "OPTIONS * HTTP/1.1\r\nHost: a\r\n\r\n", server_addr=addr
        )
        assert_equal(req.method, "OPTIONS")
        assert_equal(req.uri.path, "*", addr)
        assert_equal(req.uri.request_uri, "*", addr)
        assert_equal(req.uri.query_string, "", addr)
        var root = request_from(
            "OPTIONS / HTTP/1.1\r\nHost: a\r\n\r\n", server_addr=addr
        )
        assert_equal(root.uri.path, "/", addr)
        assert_equal(root.uri.request_uri, "/", addr)


def test_the_outgoing_constructor_still_fills_its_headers() raises:
    """The client's constructor keeps filling what a client must send:
    a length, `Connection` from the protocol, and `Host` from the URL, its
    port included; a header the caller set is kept."""
    var req = HTTPRequest(URI.parse("http://example.com/x"), body=Bytes("hi".as_bytes()))
    assert_equal(req.headers.get(HeaderKey.CONTENT_LENGTH).value(), "2")
    assert_equal(req.headers.get(HeaderKey.CONNECTION).value(), "keep-alive")
    assert_equal(req.headers.get(HeaderKey.HOST).value(), "example.com")
    var old = HTTPRequest(URI.parse("http://example.com:8080/x"), protocol="HTTP/1.0")
    assert_equal(old.headers.get(HeaderKey.CONNECTION).value(), "close")
    assert_equal(old.headers.get(HeaderKey.HOST).value(), "example.com:8080")
    assert_equal(old.headers.get(HeaderKey.CONTENT_LENGTH).value(), "0")
    var given = Headers()
    given[HeaderKey.HOST] = "other"
    given[HeaderKey.CONNECTION] = "close"
    var kept = HTTPRequest(URI.parse("http://example.com/"), headers=given^)
    assert_equal(kept.headers.get(HeaderKey.HOST).value(), "other")
    assert_equal(kept.headers.get(HeaderKey.CONNECTION).value(), "close")


def test_a_target_longer_than_the_limit_is_refused() raises:
    """`from_parsed` refuses a target longer than `max_uri_length`; the loop
    answers 414 before it asks, a caller of its own is held here."""
    var parsed = parse_request_headers("GET /abcdef HTTP/1.1\r\nHost: a\r\n\r\n".as_bytes())
    var refused = False
    try:
        _ = HTTPRequest.from_parsed("localhost", None, parsed^, Bytes(), 6)
    except e:
        refused = e.isa[URITooLongError]()
    assert_true(refused, "a seven-byte target passed a limit of six")
    var fits = parse_request_headers("GET /abcde HTTP/1.1\r\nHost: a\r\n\r\n".as_bytes())
    try:
        _ = HTTPRequest.from_parsed("localhost", None, fits^, Bytes(), 6)
    except:
        raise Error("a six-byte target was refused at a limit of six")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
