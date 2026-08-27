"""Tests for the pure parts of the WSGI mapping.

Deliberately no interpreter here: `cgi_header_name`, the CGI/latin-1 byte
transforms, and `split_status` are plain byte/string transforms, and keeping
them testable without Python is why they are separate from `bridge.mojo`,
where the environ dict is actually built.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src.environ import (
    all_ascii,
    append_cgi_name_as_utf8,
    append_latin1_as_utf8,
    cgi_header_name,
    cgi_name_utf8,
    header_is_excluded,
)
from src.response import split_status


def _text(b: List[UInt8]) -> String:
    """The bytes as a Mojo String — valid because everything here is UTF-8."""
    return String(StringSlice(unsafe_from_utf8=Span(b)))


def _bytes(var s: String) -> List[UInt8]:
    var out = List[UInt8](capacity=s.byte_length())
    out.extend(s.as_bytes())
    return out^


# --- cgi_header_name, the readable statement of the rule ---------------------


def test_cgi_header_name_prefixes_ordinary_headers() raises:
    """Ordinary headers get HTTP_ and are upper-cased with dashes to underscores."""
    assert_equal(cgi_header_name("accept-encoding"), "HTTP_ACCEPT_ENCODING")
    assert_equal(cgi_header_name("host"), "HTTP_HOST")
    assert_equal(cgi_header_name("x-forwarded-proto"), "HTTP_X_FORWARDED_PROTO")


def test_cgi_header_name_content_headers_unprefixed() raises:
    """PEP 3333: Content-Type and Content-Length carry no HTTP_ prefix."""
    assert_equal(cgi_header_name("content-type"), "CONTENT_TYPE")
    assert_equal(cgi_header_name("content-length"), "CONTENT_LENGTH")


def test_cgi_header_name_is_case_insensitive() raises:
    """`Headers` lowercases keys, but the mapping must not depend on that."""
    assert_equal(cgi_header_name("Content-Type"), "CONTENT_TYPE")
    assert_equal(cgi_header_name("USER-AGENT"), "HTTP_USER_AGENT")


# --- the two implementations must never disagree -----------------------------


def test_cgi_name_utf8_matches_cgi_header_name() raises:
    """The byte writer and `cgi_header_name` must never drift apart.

    The rule is implemented twice on purpose: `cgi_header_name` is the
    readable statement of it, and `append_cgi_name_as_utf8` writes the same
    bytes into a reused buffer without building three Strings per header to
    do so. Two implementations can drift, so this asserts they agree on
    every shape the rule distinguishes — the `HTTP_` prefix, the two
    unprefixed names, dashes, a name that merely *starts* like a content
    header, and a one-character name.
    """
    var names = [
        String("connection"),
        String("host"),
        String("accept-encoding"),
        String("x-forwarded-proto"),
        String("content-type"),
        String("content-length"),
        String("content-disposition"),
        String("a"),
        String("x"),
        String("sec-fetch-mode"),
    ]
    for name in names:
        assert_equal(
            _text(cgi_name_utf8(name.as_bytes())),
            cgi_header_name(name),
            "disagreement on " + name,
        )

    # And the distinguishing cases specifically, so a change that made every
    # name agree by making them all wrong would still fail.
    assert_equal(cgi_header_name("content-disposition"), "HTTP_CONTENT_DISPOSITION")
    assert_equal(cgi_header_name("a"), "HTTP_A")


# --- latin-1 → UTF-8, the mapping the C API needs ----------------------------


def test_all_ascii_discriminates() raises:
    """The fast-path test: True only when every byte is below 0x80."""
    assert_true(all_ascii("plain text".as_bytes()))
    assert_true(all_ascii("".as_bytes()))
    var high = List[UInt8](capacity=2)
    high.append(UInt8(ord("a")))
    high.append(0x80)
    assert_false(all_ascii(Span(high)))
    var top = List[UInt8](capacity=1)
    top.append(0xFF)
    assert_false(all_ascii(Span(top)))


def test_append_latin1_leaves_ascii_alone() raises:
    """Below 0x80 the mapping is the identity — ASCII is its own UTF-8."""
    var out = List[UInt8]()
    append_latin1_as_utf8(out, "GET /widgets?q=1".as_bytes())
    assert_equal(_text(out), "GET /widgets?q=1")


def test_append_latin1_encodes_high_bytes_as_two() raises:
    """Byte 0xNN above 0x7F becomes the two-byte UTF-8 for codepoint U+00NN.

    This is the whole reason the transform exists: Mojo 1.0 has no
    `PyUnicode_DecodeLatin1` binding, so the bytes are re-encoded here and
    decoded as UTF-8 there. `0xE9` is é — U+00E9 — which UTF-8 spells
    `C3 A9`.
    """
    var src = List[UInt8](capacity=3)
    src.append(UInt8(ord("c")))
    src.append(0xE9)
    src.append(UInt8(ord("s")))
    var out = List[UInt8]()
    append_latin1_as_utf8(out, Span(src))
    assert_equal(len(out), 4)
    assert_equal(Int(out[0]), ord("c"))
    assert_equal(Int(out[1]), 0xC3)
    assert_equal(Int(out[2]), 0xA9)
    assert_equal(Int(out[3]), ord("s"))
    assert_equal(_text(out), "cés")


def test_append_latin1_covers_every_byte() raises:
    """All 256 byte values survive the round trip to their own codepoint.

    Decoding this as UTF-8 must give exactly what `bytes.decode('latin-1')`
    gives, so the property is checked over the whole domain rather than on
    a sample: one byte below 0x80, two above, and nothing else.
    """
    var src = List[UInt8](capacity=256)
    for i in range(256):
        src.append(UInt8(i))
    var out = List[UInt8]()
    append_latin1_as_utf8(out, Span(src))
    assert_equal(len(out), 128 + 128 * 2)
    var off = 0
    for i in range(256):
        if i < 0x80:
            assert_equal(Int(out[off]), i)
            off += 1
        else:
            assert_equal(Int(out[off]), 0xC0 | (i >> 6))
            assert_equal(Int(out[off + 1]), 0x80 | (i & 0x3F))
            off += 2
    assert_equal(off, len(out))


def test_cgi_name_high_bytes_stay_valid_utf8() raises:
    """A header name with a byte above 0x7F must still produce valid UTF-8.

    Nothing on the wire guarantees an ASCII header name, and
    `PyUnicode_DecodeUTF8` is strict — an invalid sequence would fail the
    whole request rather than the one header. The CGI transform still
    applies around it: prefix, uppercase, dash to underscore.
    """
    var name = List[UInt8](capacity=4)
    name.append(UInt8(ord("x")))
    name.append(UInt8(ord("-")))
    name.append(0xE9)
    name.append(UInt8(ord("z")))
    var out = cgi_name_utf8(Span(name))
    # HTTP_ + X + _ + C3 A9 + Z
    assert_equal(len(out), 5 + 1 + 1 + 2 + 1)
    assert_equal(_text(out), "HTTP_X_éZ")


def test_cgi_name_appends_without_clearing() raises:
    """The writer appends: `PyBridge` reuses one buffer and clears it itself."""
    var out = _bytes(String("KEEP:"))
    append_cgi_name_as_utf8(out, "host".as_bytes())
    assert_equal(_text(out), "KEEP:HTTP_HOST")


# --- split_status ------------------------------------------------------------


def test_split_status_ordinary() raises:
    """A normal status line splits into code and reason phrase."""
    var ok = split_status("200 OK")
    assert_equal(ok[0], 200)
    assert_equal(ok[1], "OK")

    var missing = split_status("404 Not Found")
    assert_equal(missing[0], 404)
    assert_equal(missing[1], "Not Found")


def test_split_status_multiword_reason() raises:
    """The reason phrase keeps its spaces."""
    var status = split_status("500 Internal Server Error")
    assert_equal(status[0], 500)
    assert_equal(status[1], "Internal Server Error")


def test_split_status_code_only() raises:
    """A bare code is legal; the reason phrase is optional in WSGI practice."""
    var status = split_status("204")
    assert_equal(status[0], 204)
    assert_equal(status[1], "")


def test_split_status_malformed_becomes_500() raises:
    """A malformed status must not discard an already-computed body."""
    var status = split_status("banana")
    assert_equal(status[0], 500)
    assert_equal(status[1], "Internal Server Error")


# --- httpoxy ----------------------------------------------------------------


def test_proxy_header_is_excluded_from_the_environ() raises:
    """`Proxy:` must never become `HTTP_PROXY` (httpoxy, CVE-2016-5385).

    CGI's mapping is mechanical, so a client-sent header lands in the same
    variable that `urllib`/`requests` consult to choose an outbound proxy.
    Any application making a server-side HTTP call would then send it
    wherever the client said. No legitimate request carries this header, so
    it is dropped rather than renamed.
    """
    assert_true(header_is_excluded("proxy".as_bytes()))


def test_ordinary_headers_are_not_excluded() raises:
    """The exclusion is one exact name — not a prefix, not a family.

    `X-Forwarded-*` in particular stays: it is load-bearing behind a real
    proxy, and this server never reads it itself.
    """
    assert_false(header_is_excluded("accept".as_bytes()))
    assert_false(header_is_excluded("content-type".as_bytes()))
    assert_false(header_is_excluded("x-forwarded-for".as_bytes()))
    assert_false(header_is_excluded("x-forwarded-proto".as_bytes()))
    assert_false(header_is_excluded("proxy-authorization".as_bytes()))
    assert_false(header_is_excluded("".as_bytes()))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
