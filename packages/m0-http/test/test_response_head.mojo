"""What a response carries when its status says it has no content (SPEC A21).

RFC 9110 §8.6: a server MUST NOT send `Content-Length` in a 1xx or 204
response, and a 304 may carry one only as the length its GET would have had.
The server-side constructors used to add `Content-Length: <len(body)>` and
`Content-Type: application/octet-stream` to every response that lacked them,
so a native 204 or 304 went out with `content-length: 0` and an octet-stream
type, and nothing downstream removed either except for a 101.

Two rules now. The constructors invent neither header for a bodiless status,
and neither at all when told not to (`invent_entity_headers=False`, how the
gateway relays an application's head as sent). And `enforce_bodiless_framing`,
which the event loop applies to every response with such a status, strips a
length and a body that a handler set on a 1xx or 204 itself -- Django's
`CommonMiddleware` adds a length to every non-streaming response -- and keeps
a 304's. The rule's call sites are the wire's to prove: `scripts/head_probe.py`
sends a 204 carrying a length and seven bytes and reads the next response on
the same connection.

The head's one `Server` line is held here too (SPEC A26).
"""

from std.ffi import c_int, external_call
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from lightbug_http.c.fcntl import is_cloexec
from lightbug_http.header import (
    Header, Headers, HeaderKey, KH_CONTENT_LENGTH, KH_CONTENT_TYPE, KH_TRANSFER_ENCODING,
)
from lightbug_http.http import (
    HTTPResponse, enforce_bodiless_framing, is_bodiless_status, OK, BadRequest,
    NotFound, RequestTimeout, PayloadTooLarge, URITooLong, HeadersTooLarge,
    InternalError, NotImplemented,
)
from lightbug_http.io.bytes import Bytes


def _seven() -> Bytes:
    return Bytes(String("ignored").as_bytes())


def test_a_204_invents_no_content_length_or_type() raises:
    """A native 204 goes out with neither a length nor a type it never set.

    covers: A21
    """
    var r = HTTPResponse(
        body_bytes=String("").as_bytes(), status_code=204, status_text="No Content"
    )
    assert_equal(r.headers.known_index(KH_CONTENT_LENGTH), -1)
    assert_equal(r.headers.known_index(KH_CONTENT_TYPE), -1)


def test_a_304_invents_none_and_keeps_one_it_was_given() raises:
    """A 304 invents neither header, and keeps the length its handler gave.

    covers: A21
    """
    var bare = HTTPResponse(
        body_bytes=String("").as_bytes(),
        headers=Headers(Header(HeaderKey.ETAG, '"v1"')),
        status_code=304,
        status_text="Not Modified",
    )
    assert_equal(bare.headers.known_index(KH_CONTENT_LENGTH), -1)
    assert_equal(bare.headers.known_index(KH_CONTENT_TYPE), -1)

    # The length a GET would have had is the handler's to state (§8.6).
    var given = HTTPResponse(
        owned_body=Bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_LENGTH, "12345")),
        status_code=304,
        status_text="Not Modified",
    )
    assert_equal(given.headers.get(HeaderKey.CONTENT_LENGTH).value(), "12345")
    assert_equal(given.headers.known_index(KH_CONTENT_TYPE), -1)


def test_a_1xx_invents_neither() raises:
    """An informational response invents neither header either.

    covers: A21
    """
    var r = HTTPResponse(
        body_bytes=String("").as_bytes(), status_code=103, status_text="Early Hints"
    )
    assert_equal(r.headers.known_index(KH_CONTENT_LENGTH), -1)
    assert_equal(r.headers.known_index(KH_CONTENT_TYPE), -1)


def test_only_1xx_204_and_304_are_bodiless() raises:
    for code in [100, 101, 103, 199, 204, 304]:
        assert_true(is_bodiless_status(code), String(code))
    for code in [200, 201, 205, 206, 299, 301, 303, 404, 500]:
        assert_false(is_bodiless_status(code), String(code))


def test_the_rule_strips_a_204s_given_length_and_body() raises:
    """A length and a body a handler put on a 204 never reach the wire.

    covers: A21
    """
    var r = HTTPResponse(
        owned_body=_seven(),
        headers=Headers(Header(HeaderKey.CONTENT_LENGTH, "7")),
        status_code=204,
        status_text="No Content",
    )
    enforce_bodiless_framing(r)
    assert_equal(r.headers.known_index(KH_CONTENT_LENGTH), -1)
    assert_equal(len(r.body_raw), 0)


def test_the_rule_keeps_a_304s_given_length_and_drops_its_body() raises:
    """A 304 keeps the GET's length its handler gave, and loses its body.

    covers: A21
    """
    var r = HTTPResponse(
        owned_body=_seven(),
        headers=Headers(Header(HeaderKey.CONTENT_LENGTH, "12345")),
        status_code=304,
        status_text="Not Modified",
    )
    enforce_bodiless_framing(r)
    assert_equal(r.headers.get(HeaderKey.CONTENT_LENGTH).value(), "12345")
    assert_equal(len(r.body_raw), 0)


def test_the_rule_drops_a_transfer_encoding_from_a_1xx_or_204() raises:
    """A handler's own `Transfer-Encoding` never reaches a 1xx or a 204.

    RFC 9112 §6.1: a server MUST NOT send it in either. A 304 keeps one,
    as it keeps a length: §6.1 lets a 304 to a GET say what coding the GET
    would have had.

    covers: A21
    """
    for code in [100, 204]:
        var r = HTTPResponse(
            owned_body=Bytes(),
            headers=Headers(Header(HeaderKey.TRANSFER_ENCODING, "chunked")),
            status_code=code,
            status_text="X",
        )
        enforce_bodiless_framing(r)
        assert_equal(r.headers.known_index(KH_TRANSFER_ENCODING), -1)
    var kept = HTTPResponse(
        owned_body=Bytes(),
        headers=Headers(Header(HeaderKey.TRANSFER_ENCODING, "chunked")),
        status_code=304,
        status_text="Not Modified",
    )
    enforce_bodiless_framing(kept)
    assert_equal(kept.headers.get(HeaderKey.TRANSFER_ENCODING).value(), "chunked")


def test_the_rule_closes_a_file_body_on_a_204() raises:
    """A descriptor handed to a bodiless response is the rule's to close, or
    it leaks: the loop never transfers it."""
    var fd = Int(external_call["dup", c_int, c_int](c_int(2)))
    assert_true(fd > 2, "dup(2) failed")
    var r = HTTPResponse(
        body_bytes=String("").as_bytes(), status_code=204, status_text="No Content"
    )
    r.body_fd = fd
    r.body_fd_len = 100
    enforce_bodiless_framing(r)
    assert_equal(r.body_fd, -1)
    assert_equal(r.body_fd_len, 0)
    with assert_raises():
        _ = is_cloexec(fd)  # EBADF: the descriptor is closed


def test_the_rule_leaves_a_200_alone() raises:
    var r = HTTPResponse(
        owned_body=_seven(),
        headers=Headers(Header(HeaderKey.CONTENT_LENGTH, "7")),
        status_code=200,
    )
    enforce_bodiless_framing(r)
    assert_equal(r.headers.get(HeaderKey.CONTENT_LENGTH).value(), "7")
    assert_equal(len(r.body_raw), 7)


def test_a_200_keeps_both_defaults() raises:
    """Native handlers rely on these: the default is for a body."""
    var r = HTTPResponse(body_bytes=String("hello").as_bytes())
    assert_equal(r.headers.get(HeaderKey.CONTENT_LENGTH).value(), "5")
    assert_equal(
        r.headers.get(HeaderKey.CONTENT_TYPE).value(), "application/octet-stream"
    )


def test_invent_entity_headers_false_adds_neither_on_a_200() raises:
    """A relayed head gains no type and no length, whatever the status.

    covers: A21
    """
    var r = HTTPResponse(
        owned_body=_seven(), status_code=200, invent_entity_headers=False
    )
    assert_equal(r.headers.known_index(KH_CONTENT_LENGTH), -1)
    assert_equal(r.headers.known_index(KH_CONTENT_TYPE), -1)
    var b = HTTPResponse(
        body_bytes=String("hello").as_bytes(), invent_entity_headers=False
    )
    assert_equal(b.headers.known_index(KH_CONTENT_LENGTH), -1)
    assert_equal(b.headers.known_index(KH_CONTENT_TYPE), -1)


def test_a_204_on_the_wire_carries_no_length_and_no_body() raises:
    """Encoded after the rule, a 204 ends at its blank line.

    covers: A21
    """
    var r = HTTPResponse(
        owned_body=_seven(),
        headers=Headers(Header(HeaderKey.CONTENT_LENGTH, "7")),
        status_code=204,
        status_text="No Content",
    )
    enforce_bodiless_framing(r)
    var wire = String(unsafe_from_utf8=r^.encode())
    assert_false("content-length" in wire.lower(), wire)
    assert_false("ignored" in wire, wire)
    assert_true(wire.endswith("\r\n\r\n"), wire)


def _server_lines(wire: String) raises -> List[String]:
    """Every head line naming `Server`, whatever its case."""
    var found = List[String]()
    var head = wire.split("\r\n\r\n")[0]
    for line in head.split("\r\n"):
        if line.lower().startswith("server:"):
            found.append(String(line))
    return found^


def _with_server(server: String) -> HTTPResponse:
    var headers = Headers()
    if server:
        headers = Headers(Header("Server", server))
    return HTTPResponse(
        body_bytes=String("ok").as_bytes(), headers=headers^, status_code=200, status_text="OK"
    )


def test_a_server_header_the_application_set_is_the_only_one() raises:
    """A response whose application set `Server` carries that line and no
    default beside it, from both encoders and the printed form; one that
    set none carries the default once. The encoders wrote the default
    whatever the headers held, so an application naming itself sent two
    `Server` lines, which RFC 9110 §10.2.4's grammar cannot join into one.

    covers: A26
    """
    for writer in range(3):
        var mine = _with_server("my-app/1.0")
        var wire: String
        if writer == 0:
            wire = String(unsafe_from_utf8=mine^.encode())
        elif writer == 1:
            wire = String(unsafe_from_utf8=mine^.encode_into(Bytes(capacity=256)))
        else:
            wire = String(mine)
        var lines = _server_lines(wire)
        assert_equal(len(lines), 1, wire)
        assert_equal(lines[0], "server: my-app/1.0", wire)

        var plain = _with_server("")
        if writer == 0:
            wire = String(unsafe_from_utf8=plain^.encode())
        elif writer == 1:
            wire = String(unsafe_from_utf8=plain^.encode_into(Bytes(capacity=256)))
        else:
            wire = String(plain)
        lines = _server_lines(wire)
        assert_equal(len(lines), 1, wire)
        assert_equal(lines[0], "server: lightbug_http", wire)



def _says(r: HTTPResponse, code: Int, reason: String, body: String) raises:
    assert_equal(r.status_code, code, reason)
    assert_equal(r.status_text, reason)
    assert_equal(r.headers.get(HeaderKey.CONTENT_TYPE).value(), "text/plain")
    assert_equal(String(unsafe_from_utf8=Span(r.body_raw)), body)
    assert_equal(
        r.headers.get(HeaderKey.CONTENT_LENGTH).value(), String(body.byte_length())
    )


def test_the_server_s_own_answers_say_what_they_are() raises:
    """The responses the loop sends itself (`common_response.mojo`): each
    status with its RFC 9110 §15 reason phrase, a `text/plain` body that
    says it, and a length that matches. `NotFound` and `OK` are the two an
    application builds too."""
    _says(BadRequest(), 400, "Bad Request", "Bad Request")
    _says(NotFound("/x"), 404, "Not Found", "path /x not found")
    _says(RequestTimeout(), 408, "Request Timeout", "Request Timeout")
    _says(PayloadTooLarge(), 413, "Payload Too Large", "Payload Too Large")
    _says(URITooLong(), 414, "URI Too Long", "URI Too Long")
    _says(
        HeadersTooLarge(),
        431,
        "Request Header Fields Too Large",
        "Request Header Fields Too Large",
    )
    _says(InternalError(), 500, "Internal Server Error", "Failed to process request")
    _says(NotImplemented(), 501, "Not Implemented", "Not Implemented")
    var ok = OK("hi", "application/json")
    assert_equal(ok.status_code, 200)
    assert_equal(ok.headers.get(HeaderKey.CONTENT_TYPE).value(), "application/json")
    assert_equal(String(unsafe_from_utf8=Span(ok.body_raw)), "hi")
    assert_equal(
        OK("x").headers.get(HeaderKey.CONTENT_TYPE).value(), "text/plain"
    )
    var wire = String(unsafe_from_utf8=Span(URITooLong().encode()))
    assert_true(wire.startswith("HTTP/1.1 414 URI Too Long\r\n"), wire)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
