"""Tests for a stream that asks for zstd: `sse_response(zstd=True)` and the
one question its caller asks, `accepts_zstd` (docs/notes/compressing-a-stream.md).

The loop's half, the context every byte after the head goes through, is
`test_slot_lifecycle.mojo`'s; the wire's is `smoke-stream-zstd`.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from lightbug_http.header import Header, Headers, HeaderKey
from lightbug_http.http import HTTPRequest
from lightbug_http.uri import URI
from src.sse.response import accepts_zstd, sse_response, zstd_acceptable


def test_a_zstd_stream_names_its_coding_and_varies_on_it() raises:
    var plain = sse_response()
    assert_true(plain.sse_streaming)
    assert_false(plain.zstd_stream)
    assert_false(Bool(plain.headers.get("content-encoding")))

    var z = sse_response(zstd=True)
    assert_true(z.sse_streaming)
    assert_true(z.zstd_stream, "the loop is not asked to compress")
    assert_equal(z.headers.get("content-encoding").value(), "zstd")
    var vary = z.headers.get(HeaderKey.VARY)
    assert_true(Bool(vary), "a coded stream must vary on Accept-Encoding")
    assert_true("accept-encoding" in vary.value().lower(), vary.value())
    # The body is what the loop compresses: it is left as written here.
    assert_equal(String(unsafe_from_utf8=Span(z.body_raw)), ": open\n\n")


def test_the_accept_encoding_table() raises:
    """RFC 9110 §12.5.3's rules for one coding: a `zstd` member decides by
    its weight, a `*` decides when there is none, codings compare in any
    case, and a weight that is not a qvalue refuses.

    covers: I45
    """
    var cases = List[Tuple[String, Bool]]()
    cases.append(("", False))
    cases.append(("gzip, deflate, br", False))
    cases.append(("zstd", True))
    cases.append(("ZSTD", True))
    cases.append(("gzip, deflate, br, zstd", True))
    cases.append((" , zstd , ", True))
    cases.append(("zstd;q=1", True))
    cases.append(("zstd;q=1.000", True))
    cases.append(("zstd;q=0.5", True))
    cases.append(("zstd; q=0.001", True))
    cases.append(("zstd;Q=0.2", True))
    cases.append(("zstd;level=3", True))
    cases.append(("zstd;q=0", False))
    cases.append(("zstd;q=0.0", False))
    cases.append(("zstd;q=0.000", False))
    cases.append(("gzip, zstd;q=0", False))
    cases.append(("zstd;q=2", False))
    cases.append(("zstd;q=1.5", False))
    cases.append(("zstd;q=0.0001", False))
    cases.append(("zstd;q=", False))
    cases.append(("zstd;q=abc", False))
    cases.append(("zstdx, xzstd", False))
    cases.append(("*", True))
    cases.append(("*;q=0", False))
    cases.append(("gzip;q=1, *;q=0.1", True))
    cases.append(("*, zstd;q=0", False))
    cases.append(("zstd;q=0, *", False))
    cases.append(("zstd;q=0, zstd", True))
    for row in cases:
        assert_equal(zstd_acceptable(row[0]), row[1], "Accept-Encoding: '" + row[0] + "'")


def test_bytes_outside_utf8_are_walked_not_sliced() raises:
    """A request's header value may hold bytes that are not UTF-8 (SPEC
    G14); the walk reads bytes, so they are an unknown coding and nothing
    traps."""
    var raw = List[UInt8]()
    raw.append(0xFF)
    raw.append(0xFE)
    for b in String(", zstd").as_bytes():
        raw.append(b)
    assert_true(zstd_acceptable(String(unsafe_from_utf8=Span(raw))))


def test_a_request_without_the_field_takes_no_coding() raises:
    """RFC 9110 lets a server pick any coding when `Accept-Encoding` is
    absent; a stream is compressed only for a client that asked, so a plain
    `curl` reads it as written."""
    assert_false(accepts_zstd(HTTPRequest(URI.parse("http://127.0.0.1/events"))))
    assert_true(
        accepts_zstd(
            HTTPRequest(
                URI.parse("http://127.0.0.1/events"),
                headers=Headers(Header("Accept-Encoding", "gzip, br, zstd")),
            )
        )
    )
    assert_false(
        accepts_zstd(
            HTTPRequest(
                URI.parse("http://127.0.0.1/events"),
                headers=Headers(Header("Accept-Encoding", "gzip, br")),
            )
        )
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
