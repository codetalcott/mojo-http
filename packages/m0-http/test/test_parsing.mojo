"""Tests for the fork's request-parsing hardening.

[NOTICE](../../../NOTICE) records "security hardening against request smuggling,
slowloris, and integer overflow in request parsing" as a reason this fork exists.
Everything asserted here corresponds to one of those claims. A licensing record
cannot be kept honest by prose alone, and these are the checks most likely to be
removed by someone tidying code they did not write.

The distinction that matters throughout: a hostile request must be **invalid**,
not **incomplete**. "Incomplete" tells the server to wait for more bytes, which
for a smuggling attempt means leaving the attacker's payload in the buffer to be
read as the start of the next request — the exact outcome the check exists to
prevent.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.header import (
    parse_request_headers,
    InvalidHTTPRequestError,
    IncompleteHTTPRequestError,
    UnsupportedHTTPRequestError,
    HeaderKey,
    holds_bare_lf,
)
from lightbug_http.http.chunked import HTTPChunkedDecoder
from lightbug_http.io.bytes import Bytes
from lightbug_http.strings import is_token_char


# --- Helpers -----------------------------------------------------------------


def _rejected(raw: String) -> Bool:
    """True only if the request is rejected as malformed."""
    var bytes = raw.as_bytes()
    try:
        var parsed = parse_request_headers(bytes)
        _ = parsed^
        return False
    except e:
        return e.isa[InvalidHTTPRequestError]()


def _unsupported(raw: String) -> Bool:
    """True only if the request is refused as asking for what this server
    does not implement, which the loop answers 501 rather than 400."""
    var bytes = raw.as_bytes()
    try:
        var parsed = parse_request_headers(bytes)
        _ = parsed^
        return False
    except e:
        return e.isa[UnsupportedHTTPRequestError]()


def _accepted(raw: String) -> Bool:
    var bytes = raw.as_bytes()
    try:
        var parsed = parse_request_headers(bytes)
        _ = parsed^
        return True
    except:
        return False


def _path_of(raw: String) raises -> String:
    var bytes = raw.as_bytes()
    var parsed = parse_request_headers(bytes)
    return parsed.path


def _header(raw: String, key: String) raises -> String:
    var bytes = raw.as_bytes()
    var parsed = parse_request_headers(bytes)
    var v = parsed.headers.get(key)
    if not v:
        return String("(absent)")
    return String(v.value())


# --- Request smuggling: RFC 9112 6.3 -----------------------------------------


def test_content_length_with_transfer_encoding_is_rejected() raises:
    """CL.TE: the canonical desync. Two framings, two readers, one exploit.

    covers: B1
    """
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 6\r\n"
            "Transfer-Encoding: chunked\r\n\r\n"
        )
    )


def test_transfer_encoding_before_content_length_is_also_rejected() raises:
    """Header order must not decide the outcome."""
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
            "Content-Length: 6\r\n\r\n"
        )
    )


def test_duplicate_content_length_is_rejected() raises:
    """Two lengths is the same ambiguity as a length plus a chunked encoding.

    Two lines that AGREE are refused too. RFC 9112 §6.3 lets a recipient
    collapse identical values into one, and RFC 9110 §8.6 lets it reject
    them instead; this parser takes the second, so a second length line
    is never read as anything but a second framing.
    """
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 6\r\n"
            "Content-Length: 5\r\n\r\n"
        )
    )
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 6\r\n"
            "Content-Length: 6\r\n\r\n"
        )
    )


def test_duplicate_content_length_is_rejected_across_letter_case() raises:
    """Header names are case-insensitive; the duplicate check must be too.

    covers: B2
    """
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 6\r\n"
            "content-length: 6\r\n\r\n"
        )
    )


def test_padded_headers_do_not_bypass_the_smuggling_check() raises:
    """Values are OWS-trimmed before the check, so padding cannot hide a header.

    A check that ran before trimming, or a trim that ran only on some values,
    would let "Transfer-Encoding:\tchunked " slip past.

    covers: B4
    """
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length:  6 \r\n"
            "Transfer-Encoding:\tchunked \r\n\r\n"
        )
    )


def test_chunked_must_be_the_last_transfer_encoding() raises:
    """RFC 9112 6.1. If chunked is not outermost, framing is undefined."""
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\n"
            "Transfer-Encoding: chunked, gzip\r\n\r\n"
        )
    )


def test_chunked_last_in_a_list_is_accepted() raises:
    """The rule is about position, not about rejecting every encoding list:
    empty members mean nothing (RFC 9110 §5.6.1). A real coding before
    `chunked` is refused, but as not implemented (SPEC B21), never as a
    `chunked` out of place."""
    assert_true(
        _accepted(
            "POST / HTTP/1.1\r\nHost: x\r\n"
            "Transfer-Encoding: , chunked\r\n\r\n"
        )
    )


def test_plain_chunked_request_is_accepted() raises:
    """The hardening must not reject ordinary chunked requests."""
    assert_true(
        _accepted(
            "POST / HTTP/1.1\r\nHost: x\r\n"
            "Transfer-Encoding: chunked\r\n\r\n"
        )
    )


def test_single_content_length_is_accepted() raises:
    assert_true(
        _accepted("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
    )


# --- Host: RFC 9110 7.2 ------------------------------------------------------


def test_an_empty_host_is_accepted_when_the_target_names_no_authority() raises:
    """RFC 9110 §7.2: a client whose target URI has no authority MUST send
    `Host` with an EMPTY value, and an origin-form or asterisk-form target
    names none. Every empty Host was refused, where h11 and llhttp accept
    it. OWS trimming turns "Host: \\t" into "", read the same way. An
    absolute-form target names its authority, which Host must then be, so
    an empty one there is still refused -- and a missing Host is refused
    whatever the target.

    covers: B20
    """
    assert_true(_accepted("GET / HTTP/1.1\r\nHost:\r\n\r\n"))
    assert_equal(_header("GET / HTTP/1.1\r\nHost: \r\n\r\n", "host"), "")
    assert_true(_accepted("GET / HTTP/1.1\r\nHost:\t\r\n\r\n"))
    assert_true(_accepted("OPTIONS * HTTP/1.1\r\nHost:\r\n\r\n"))
    assert_true(_accepted("GET / HTTP/1.2\r\nHost:\r\n\r\n"))
    assert_true(_rejected("GET http://h/p HTTP/1.1\r\nHost:\r\n\r\n"))
    assert_true(_rejected("GET HTTPS://h HTTP/1.1\r\nHost: \r\n\r\n"))
    assert_true(_rejected("GET / HTTP/1.1\r\n\r\n"))


def test_http11_accepts_a_real_host() raises:
    assert_true(_accepted("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"))


def test_http10_without_host_is_accepted() raises:
    """The Host requirement is HTTP/1.1's; 1.0 predates it."""
    assert_true(_accepted("GET / HTTP/1.0\r\n\r\n"))


def test_http11_requires_host_to_be_present_at_all() raises:
    """RFC 9112 3.2 asks for 400, and the empty-Host check did not cover
    this: `headers.get()` returned None, which short-circuited the `and`
    and let the request through with its target host unstated.

    covers: A14
    """
    assert_true(_rejected("GET / HTTP/1.1\r\n\r\n"))
    assert_true(_rejected("POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\n"))


def test_a_later_http1_minor_version_requires_host() raises:
    """HTTP/1.2 to HTTP/1.9 are processed as HTTP/1.1 (RFC 9110 §2.5), so
    they need Host too. The check asked for minor version 1 exactly, and
    `GET / HTTP/1.2` with no Host was served.

    covers: B15
    """
    assert_true(_rejected("GET / HTTP/1.2\r\n\r\n"))
    assert_true(_rejected("GET / HTTP/1.9\r\n\r\n"))
    assert_true(_rejected("GET http://h/ HTTP/1.2\r\nHost: \r\n\r\n"))
    assert_true(_accepted("GET / HTTP/1.2\r\nHost: x\r\n\r\n"))


def test_an_http10_request_with_transfer_encoding_has_faulty_framing() raises:
    """RFC 9112 §6.1, the head's half: the loop closes behind a request
    `faulty_framing` names, and `Smoke test pipelined requests` holds that
    half on the wire."""
    var te10 = String(
        "POST / HTTP/1.0\r\nConnection: keep-alive\r\n"
        "Transfer-Encoding: chunked\r\n\r\n"
    )
    assert_true(parse_request_headers(te10.as_bytes()).faulty_framing())
    var te11 = String(
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
    )
    assert_false(parse_request_headers(te11.as_bytes()).faulty_framing())
    var cl10 = String("POST / HTTP/1.0\r\nContent-Length: 0\r\n\r\n")
    assert_false(parse_request_headers(cl10.as_bytes()).faulty_framing())


def test_a_second_host_line_is_rejected() raises:
    """RFC 9112 §3.2: a server MUST answer 400 to "any request message
    that contains more than one Host header field line". The parser kept
    the last line and served the request, so a proxy routing on the first
    `Host` and an application reading the last (Django's `HTTP_HOST`)
    disagreed about which site the request was for.

    The rule counts LINES: two that agree are still refused, and so are
    two that differ only in the name's letter case. It is not HTTP/1.1's
    alone, and an empty first line does not hide the second.

    covers: B10
    """
    assert_true(
        _rejected("GET / HTTP/1.1\r\nHost: a.example\r\nHost: b.example\r\n\r\n")
    )
    assert_true(
        _rejected("GET / HTTP/1.1\r\nHost: a.example\r\nHost: a.example\r\n\r\n")
    )
    assert_true(
        _rejected("GET / HTTP/1.1\r\nHost: a.example\r\nhOST: b.example\r\n\r\n")
    )
    assert_true(_rejected("GET / HTTP/1.1\r\nHost: \r\nHost: b.example\r\n\r\n"))
    assert_true(
        _rejected("GET / HTTP/1.0\r\nHost: a.example\r\nHost: b.example\r\n\r\n")
    )
    # Not adjacent: another field between the two lines hides nothing.
    assert_true(
        _rejected(
            "GET / HTTP/1.1\r\nHost: a.example\r\nAccept: */*\r\n"
            "Host: b.example\r\n\r\n"
        )
    )
    # The control: one Host line, on either version, is served.
    assert_true(_accepted("GET / HTTP/1.1\r\nHost: a.example\r\nAccept: */*\r\n\r\n"))
    assert_true(_accepted("GET / HTTP/1.0\r\nHost: a.example\r\n\r\n"))


def test_a_second_transfer_encoding_line_is_rejected() raises:
    """Field lines of one name combine into one comma-separated list (RFC
    9110 §5.3), so two `Transfer-Encoding: chunked` lines are `chunked,
    chunked` -- refused on one line (RFC 9112 §6.1), and accepted on two,
    because the parser kept only the last line and read a single `chunked`.
    A hop that combines the lines frames the body differently from one
    that keeps the last: the desync the rules above exist to prevent. A
    second line is refused whatever the two say, as a second
    `Content-Length` line is.

    covers: B11
    """
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
            "Transfer-Encoding: chunked\r\n\r\n"
        )
    )
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
            "transfer-encoding: CHUNKED\r\n\r\n"
        )
    )
    # `gzip` then `chunked` is `gzip, chunked` combined, and the last line
    # alone reads as a plain `chunked`: two hops, two framings again.
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n"
            "Transfer-Encoding: chunked\r\n\r\n"
        )
    )
    # The control: ONE line keeps working.
    assert_true(
        _accepted(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
        )
    )


# --- Transfer-Encoding is case-insensitive (RFC 9112 7.1) --------------------


def test_uppercase_chunked_is_recognised_as_chunked() raises:
    """`CHUNKED` used to answer False to `is_chunked_body` and, having no
    Content-Length either, was dispatched as a bodyless request while its
    body stayed in the buffer. A proxy in front reading the same header per
    spec would frame that body: two hops, two framings."""
    var raw = String(
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: CHUNKED\r\n\r\n"
    )
    var parsed = parse_request_headers(raw.as_bytes())
    assert_true(parsed.is_chunked_body())


def test_mixed_case_chunked_is_recognised() raises:
    var raw = String(
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: Chunked\r\n\r\n"
    )
    var parsed = parse_request_headers(raw.as_bytes())
    assert_true(parsed.is_chunked_body())


def test_uppercase_chunked_not_last_is_still_rejected() raises:
    """The must-be-last rule was skipped entirely for uppercase, because its
    own guard tested the raw value."""
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: CHUNKED, zorg\r\n\r\n"
        )
    )


def test_transfer_encoding_whose_last_coding_is_not_chunked_is_rejected() raises:
    """RFC 9112 6.3: only `chunked` says where a request body ends.

    Deliberately WITHOUT a Content-Length — an earlier version of this test
    included one, which meant the pre-existing TE+CL rule rejected it and
    the assertion said nothing at all about the encoding. Without it, a
    server that does not check this dispatches the request as bodyless and
    leaves the body in the buffer for the next reader to find.

    Each is a coding this server does not implement, so the refusal is
    501 (SPEC B21), where it was 400; refused either way, never served.

    covers: B3
    """
    assert_true(
        _unsupported("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n")
    )
    assert_true(
        _unsupported("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: identity\r\n\r\n")
    )
    # A loose substring match would let these through as "chunked".
    assert_true(
        _unsupported("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: xchunked\r\n\r\n")
    )
    assert_true(
        _unsupported("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked-foo\r\n\r\n")
    )


def test_chunked_applied_twice_is_rejected() raises:
    """RFC 9112 §6.1: a sender MUST NOT apply `chunked` more than once, so
    `chunked` anywhere but last is refused, not only a final coding that
    is something else. The loop decodes ONE layer: accepted, `chunked,
    chunked` reached an application as a still-chunked body described by a
    length -- the contradictory pair SPEC L25 removes.

    covers: B3
    """
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked, chunked\r\n\r\n"
        )
    )
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: CHUNKED, gzip, chunked\r\n\r\n"
        )
    )


def test_chunked_as_the_last_coding_is_still_accepted() raises:
    """The control: a lone `chunked`, in any case and with empty members
    before it, keeps working."""
    assert_true(
        _accepted(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: ,, chunked\r\n\r\n"
        )
    )
    assert_true(
        _accepted("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: CHUNKED\r\n\r\n")
    )


def test_a_transfer_coding_other_than_chunked_is_not_implemented() raises:
    """RFC 9112 §6.1: a server that receives a transfer coding it does not
    understand SHOULD answer 501. This one decodes `chunked` and nothing
    else, and `gzip, chunked` was de-chunked and handed to the application
    still gzipped. A coding before the final `chunked`, or one alone, is
    refused as not implemented; the malformed lists stay 400 -- `chunked`
    out of place or twice, a list naming nothing or ending in an empty
    member -- and the malformed answer wins where a list is both.

    covers: B21
    """
    var head = String("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: ")
    assert_true(_unsupported(head + "gzip, chunked\r\n\r\n"))
    assert_true(_unsupported(head + "GZIP,chunked\r\n\r\n"))
    assert_true(_unsupported(head + "deflate, gzip, chunked\r\n\r\n"))
    assert_true(_unsupported(head + "gzip,,chunked\r\n\r\n"))
    assert_true(_unsupported(head + "gzip\r\n\r\n"))
    assert_true(_unsupported(head + "gzip, deflate\r\n\r\n"))
    assert_true(_unsupported(head + "chunked;x=1\r\n\r\n"))
    assert_true(_rejected(head + "chunked, gzip\r\n\r\n"))
    assert_true(_rejected(head + "gzip, chunked, chunked\r\n\r\n"))
    assert_true(_rejected(head + "\r\n\r\n"))
    assert_true(_rejected(head + "gzip,\r\n\r\n"))
    assert_true(_accepted(head + "chunked\r\n\r\n"))


# --- What this server does not implement: 501, not 400 ----------------------


def test_connect_is_refused_as_not_implemented() raises:
    """CONNECT asks for a tunnel (RFC 9110 §9.3.6), which this server does
    not implement, so it is refused before any application sees it --
    whatever its target or version. An application answering it 2xx (as
    one answering every method does) told a front end forwarding it that
    the tunnel was open, and the client's next bytes went through
    unparsed. The refusal still needs a well-formed head: a malformed one
    is 400 first, and the method name is case-sensitive.

    covers: B18
    """
    assert_true(_unsupported("CONNECT h:443 HTTP/1.1\r\nHost: h:443\r\n\r\n"))
    assert_true(_unsupported("CONNECT h:443 HTTP/1.0\r\n\r\n"))
    assert_true(_unsupported("CONNECT / HTTP/1.1\r\nHost: h\r\n\r\n"))
    assert_true(_rejected("CONNECT h:443 HTTP/1.1\nHost: h:443\r\n\r\n"))
    assert_false(_unsupported("connect / HTTP/1.1\r\nHost: h\r\n\r\n"))
    assert_true(_accepted("GET / HTTP/1.1\r\nHost: h\r\n\r\n"))


# --- Content-Length must be a plain digit run (RFC 9112 6.3) ----------------


def test_content_length_list_is_rejected() raises:
    """`5, 5` is two hops having already disagreed. It parsed as 0 before,
    so the body stayed unread and unframed instead of being refused."""
    assert_true(
        _rejected("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5, 5\r\n\r\n")
    )


def test_non_digit_content_lengths_are_rejected() raises:
    """Each of these silently became 0."""
    assert_true(
        _rejected("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0x10\r\n\r\n")
    )
    assert_true(
        _rejected("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: +5\r\n\r\n")
    )
    assert_true(
        _rejected("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n")
    )
    assert_true(
        _rejected("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5abc\r\n\r\n")
    )
    assert_true(
        _rejected("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: \r\n\r\n")
    )


def test_overflowing_content_length_is_rejected() raises:
    """A 20-digit length wraps Int64 in `content_length()`, so the value
    acted on would not be the value sent.

    covers: B6
    """
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 18446744073709551621\r\n\r\n"
        )
    )


def test_ordinary_content_lengths_are_still_accepted() raises:
    """The guard must not cost a legitimate request: plain digits, zero, and
    a large-but-representable length all still parse."""
    assert_true(
        _accepted("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
    )
    assert_true(
        _accepted("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1024\r\n\r\n")
    )
    assert_true(
        _accepted(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 999999999999999999\r\n\r\n"
        )
    )


# --- Resource bounds: the slowloris family -----------------------------------


def test_header_count_is_capped() raises:
    """An unbounded header list is free memory amplification for an attacker.

    covers: C4
    """
    var raw = String("GET / HTTP/1.1\r\nHost: x\r\n")
    for i in range(200):
        raw += "X-Pad-" + String(i) + ": v\r\n"
    raw += "\r\n"
    assert_true(_rejected(raw))


def test_a_normal_header_count_is_accepted() raises:
    """The cap must sit well above anything a real client sends."""
    var raw = String("GET / HTTP/1.1\r\nHost: x\r\n")
    for i in range(40):
        raw += "X-Pad-" + String(i) + ": v\r\n"
    raw += "\r\n"
    assert_true(_accepted(raw))


def test_a_truncated_request_is_incomplete_not_invalid() raises:
    """The other half of the framing contract: don't reject a partial read.

    If this ever returned "invalid", every request split across two TCP
    segments would fail.
    """
    var raw = String("GET / HTTP/1.1\r\nHost: exam")
    assert_false(_rejected(raw))
    assert_false(_accepted(raw))


def test_a_header_line_cut_between_cr_and_lf_is_incomplete() raises:
    """The same contract one byte later: a segment boundary between a
    header line's CR and its LF is a partial read, not a malformed line.

    `scan_to_eol` answered invalid there while the request line and the
    terminating empty line answered incomplete; the release fuzz's
    invalid-is-sticky rule found the disagreement (seed 5, iteration
    147067), latent since the parser was written.
    """
    var first = String("GET / HTTP/1.1\r\nHost: example.com\r")
    assert_false(_rejected(first))
    assert_false(_accepted(first))
    var second = String("GET / HTTP/1.1\r\nHost: example.com\r\nX-A: b\r")
    assert_false(_rejected(second))
    assert_false(_accepted(second))
    # A CR followed by anything but LF is still a bad line.
    assert_true(_rejected(String("GET / HTTP/1.1\r\nHost: example.com\rX")))
    # And the completed line still parses.
    assert_true(_accepted(String("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")))


# --- One line terminator: CRLF (SPEC B12) ------------------------------------
#
# The event loop frames a head by its first CRLFCRLF and hands the parser
# exactly that many bytes. A parser that also ended a head at a bare LF
# stopped short of the loop's frame, and whatever lay between was lost: the
# two wire shapes below are what `apps/hello` did with them (one answer for
# two requests; a body answered as a request). A bare LF anywhere in a
# request head is refused, invalid rather than incomplete.


def test_a_bare_lf_in_a_request_head_is_rejected() raises:
    """Every line of a request head ends in CRLF, the empty one included.

    covers: B12
    """
    # The empty line that ends the head.
    assert_true(_rejected("GET / HTTP/1.1\r\nHost: x\r\n\n"))
    # A field line.
    assert_true(_rejected("GET / HTTP/1.1\r\nHost: x\nAccept: */*\r\n\r\n"))
    # The request line.
    assert_true(_rejected("GET / HTTP/1.1\nHost: x\r\n\r\n"))
    # An empty line before the request line.
    assert_true(_rejected("\nGET / HTTP/1.1\r\nHost: x\r\n\r\n"))
    # All of them, the shape the old parser accepted whole.
    assert_true(_rejected("GET / HTTP/1.1\nHost: x\n\n"))


def test_a_bare_lf_is_invalid_before_the_rest_arrives() raises:
    """Refused at the LF, not left waiting for more bytes.

    "Incomplete" keeps the bytes in the buffer for the next read to
    reinterpret; the head is already unframeable at the LF.
    """
    assert_true(_rejected("GET / HTTP/1.1\r\nHost: x\n"))
    assert_true(_rejected("GET / HTTP/1.1\n"))


def test_the_two_bare_lf_wire_shapes_are_rejected() raises:
    """What the loop hands the parser for each shape `apps/hello` lost.

    The loop's frame runs to the first CRLFCRLF, so the parser sees the
    first head, the bare LF, and everything up to that CRLFCRLF: the second
    request's head, or the `Content-Length` that described the body.
    """
    assert_true(
        _rejected(
            "GET /health HTTP/1.1\r\nHost: x\r\n\n"
            "GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
        )
    )
    assert_true(
        _rejected(
            "POST /health HTTP/1.1\r\nHost: x\r\n\nContent-Length: 33\r\n\r\n"
        )
    )


def test_a_bare_lf_is_found_in_a_head_still_arriving_at_every_offset() raises:
    """`holds_bare_lf`, which the loop asks of a head with no CRLFCRLF yet
    (SPEC B23): an LF no CR comes right before is found at every offset
    across its 64-lane and one-byte widths, a CRLF at every offset is not,
    and the byte before `start` is read as the LF's predecessor -- a read
    ending on CR and the next opening with LF are a CRLF.

    covers: B23
    """
    for at in range(0, 141):
        var pad = String("a") * at
        var bare = pad + "\nb" + String("c") * 70
        assert_true(holds_bare_lf(bare.as_bytes()), String("bare LF at ", at))
        var crlf = pad + "\r\nb" + String("c") * 70
        assert_false(holds_bare_lf(crlf.as_bytes()), String("CRLF at ", at))
        # Scanned from the LF itself: its CR sits before `start`.
        assert_false(holds_bare_lf(crlf.as_bytes(), at + 1), String("split at ", at))
        # A bare LF before `start` was the last scan's to find.
        assert_false(holds_bare_lf(bare.as_bytes(), at + 1), String("past at ", at))
    assert_true(holds_bare_lf("\n".as_bytes()))
    assert_false(holds_bare_lf("".as_bytes()))
    assert_false(holds_bare_lf("ab\r\n".as_bytes(), 9))


def test_an_empty_crlf_line_before_the_request_line_is_still_skipped() raises:
    """RFC 9112 §2.2's robustness rule stands for a CRLF empty line."""
    var raw = String("\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n")
    assert_true(_accepted(raw))
    var parsed = parse_request_headers(raw.as_bytes())
    assert_equal(parsed.bytes_consumed, raw.byte_length())


# --- obs-fold: RFC 9112 5.2 (SPEC B13) ---------------------------------------


def test_an_obs_fold_line_is_rejected() raises:
    """A field line opening with SP or HTAB continues the one before it.

    RFC 9112 §5.2: a server MUST either refuse such a message with 400 or
    replace each fold with SP; this one refuses. The parser used to accept
    the line as a field with an EMPTY name, which reached a WSGI
    application as the environ key `HTTP_`, and the folded text never
    joined the value it continued.

    covers: B13
    """
    assert_true(_rejected("GET / HTTP/1.1\r\nHost: x\r\nX-A: 1\r\n folded\r\n\r\n"))
    assert_true(_rejected("GET / HTTP/1.1\r\nHost: x\r\nX-A: 1\r\n\tfolded\r\n\r\n"))
    # A fold of Host itself, and one before any field at all.
    assert_true(_rejected("GET / HTTP/1.1\r\nHost: x\r\n y\r\n\r\n"))
    assert_true(_rejected("GET / HTTP/1.1\r\n folded\r\nHost: x\r\n\r\n"))


def test_an_obs_fold_is_invalid_before_its_line_ends() raises:
    """Refused at the SP that opens the line, not left waiting for more."""
    assert_true(_rejected("GET / HTTP/1.1\r\nHost: x\r\n "))
    assert_true(_rejected("GET / HTTP/1.1\r\nHost: x\r\n\t"))


# --- Request target normalization: RFC 9112 3.2.2 ----------------------------


def test_absolute_form_target_is_reduced_to_its_path() raises:
    """Handlers compare paths; a proxy-style target must not reach them whole.

    covers: A15
    """
    assert_equal(
        _path_of("GET http://example.com/orders/7 HTTP/1.1\r\nHost: x\r\n\r\n"),
        "/orders/7",
    )


def test_absolute_form_https_target_is_reduced() raises:
    assert_equal(
        _path_of("GET https://example.com/a HTTP/1.1\r\nHost: x\r\n\r\n"), "/a"
    )


def test_absolute_form_with_no_path_becomes_root() raises:
    assert_equal(
        _path_of("GET http://example.com HTTP/1.1\r\nHost: x\r\n\r\n"), "/"
    )


def test_an_absolute_form_authority_replaces_host() raises:
    """RFC 9112 §3.2.2: a server MUST ignore the received Host and use the
    target's authority instead. The authority was thrown away and Host
    kept, so an application routing on Host read a site the target never
    named.

    covers: B16
    """
    var raw = String("GET http://h.example/p?q=1 HTTP/1.1\r\nHost: x\r\n\r\n")
    assert_equal(_path_of(raw), "/p?q=1")
    assert_equal(_header(raw, "host"), "h.example")
    assert_equal(
        _header("GET http://h.example:8080/ HTTP/1.1\r\nHost: x\r\n\r\n", "host"),
        "h.example:8080",
    )
    # An IPv6 literal and its port: the colons inside it end nothing.
    var v6 = String("GET http://[::1]:8080/p HTTP/1.1\r\nHost: x\r\n\r\n")
    assert_equal(_header(v6, "host"), "[::1]:8080")
    assert_equal(_path_of(v6), "/p")
    # HTTP/1.0 needs no Host field, and gets the target's.
    assert_equal(_header("GET http://h.example/p HTTP/1.0\r\n\r\n", "host"), "h.example")
    # HTTP/1.1 still needs one sent (RFC 9112 §3.2), whatever the target says.
    assert_true(_rejected("GET http://h.example/p HTTP/1.1\r\n\r\n"))


def test_an_absolute_form_scheme_matches_in_any_case() raises:
    """A scheme is case-insensitive (RFC 3986 §3.1). `HTTP://h/p` was left
    whole, and reached the application as a path with no leading slash."""
    var raw = String("GET HTTP://h/p HTTP/1.1\r\nHost: x\r\n\r\n")
    assert_equal(_path_of(raw), "/p")
    assert_equal(_header(raw, "host"), "h")
    assert_equal(_path_of("GET Https://h/a HTTP/1.1\r\nHost: x\r\n\r\n"), "/a")
    assert_equal(_path_of("GET hTtP://h HTTP/1.1\r\nHost: x\r\n\r\n"), "/")


def test_an_absolute_form_authority_ends_at_a_query() raises:
    """The authority runs to the first `/`, `?` or `#` (RFC 3986 §3.2): a
    query straight after it is the target's, and was dropped."""
    var raw = String("GET http://h?q=1 HTTP/1.1\r\nHost: x\r\n\r\n")
    assert_equal(_path_of(raw), "/?q=1")
    assert_equal(_header(raw, "host"), "h")
    # A `#` ends it too, and what follows reduces as an origin-form
    # target's would, the fragment kept on the path.
    var frag = String("GET http://h#f HTTP/1.1\r\nHost: x\r\n\r\n")
    assert_equal(_path_of(frag), "/#f")
    assert_equal(_header(frag, "host"), "h")
    # An `@` past the authority is data, as in an origin-form target.
    assert_equal(
        _path_of("GET http://h/p?x=a@b HTTP/1.1\r\nHost: x\r\n\r\n"), "/p?x=a@b"
    )


def test_an_absolute_form_target_without_a_usable_authority_is_rejected() raises:
    """An empty authority names no host to replace Host with, and a
    userinfo is to be treated as an error (RFC 9110 §4.2.4): it is how a
    target hides the host it really names."""
    assert_true(_rejected("GET http:///p HTTP/1.1\r\nHost: x\r\n\r\n"))
    assert_true(_rejected("GET http:// HTTP/1.1\r\nHost: x\r\n\r\n"))
    assert_true(_rejected("GET https://?q=1 HTTP/1.1\r\nHost: x\r\n\r\n"))
    assert_true(_rejected("GET http://u@h/p HTTP/1.1\r\nHost: x\r\n\r\n"))
    assert_true(_rejected("GET http://u:pw@h/ HTTP/1.1\r\nHost: x\r\n\r\n"))


def _target_with(prefix: String, byte: UInt8, suffix: String) -> List[UInt8]:
    """A request head whose target holds `byte` between `prefix` and
    `suffix`, the rest of the head after them."""
    var raw = List[UInt8]()
    raw.extend(prefix.as_bytes())
    raw.append(byte)
    raw.extend(suffix.as_bytes())
    raw.extend(" HTTP/1.1\r\nHost: x\r\n\r\n".as_bytes())
    return raw^


def _invalid_bytes(raw: List[UInt8]) -> Bool:
    """`_rejected` for a head that is not a String's bytes."""
    try:
        var parsed = parse_request_headers(Span(raw))
        _ = parsed^
        return False
    except e:
        return e.isa[InvalidHTTPRequestError]()


def test_an_absolute_form_target_with_bytes_above_ascii_is_refused() raises:
    """SPEC G14: the target is request data, and may not be UTF-8. The
    reduction slices it as bytes, never with a codepoint-asserting slice,
    and since SPEC B19 such a target is refused before it gets there."""
    assert_true(_invalid_bytes(_target_with("GET http://h", 0xFF, "/a")))
    assert_true(_invalid_bytes(_target_with("GET http://h/a", 0x80, "")))


def test_a_request_target_must_take_one_of_the_four_forms() raises:
    """RFC 9112 §3.2: origin-form opens with `/`; absolute-form is an
    `http` or `https` URI; asterisk-form is `*`, for OPTIONS only;
    authority-form is CONNECT's, which is refused 501 (SPEC B18). `GET p`
    and `GET h:80` were served, the application reading a path with no
    leading slash.

    covers: B19
    """
    assert_true(_rejected("GET p HTTP/1.1\r\nHost: x\r\n\r\n"))
    assert_true(_rejected("GET h:80 HTTP/1.1\r\nHost: h\r\n\r\n"))
    assert_true(_rejected("GET ?q=1 HTTP/1.1\r\nHost: x\r\n\r\n"))
    assert_true(_rejected("GET ftp://h/p HTTP/1.1\r\nHost: x\r\n\r\n"))
    assert_true(_rejected("GET * HTTP/1.1\r\nHost: x\r\n\r\n"))
    assert_true(_rejected("OPTIONS *x HTTP/1.1\r\nHost: x\r\n\r\n"))
    assert_true(_rejected("options * HTTP/1.1\r\nHost: x\r\n\r\n"))
    # The four forms, the controls.
    assert_equal(_path_of("GET /p HTTP/1.1\r\nHost: x\r\n\r\n"), "/p")
    assert_equal(_path_of("GET HTTP://h/p HTTP/1.1\r\nHost: x\r\n\r\n"), "/p")
    assert_equal(_path_of("OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n"), "*")
    assert_true(_accepted("OPTIONS /p HTTP/1.1\r\nHost: x\r\n\r\n"))


def test_a_byte_above_ascii_in_the_request_target_is_rejected() raises:
    """No URI byte is above ASCII (RFC 3986 §2): a client percent-encodes
    one. `/caf<0xE9>` was served, where h11 and llhttp refuse it, and the
    application read a path that is not UTF-8. Refused wherever the byte
    sits -- at every offset across the scanner's 64-, 16- and one-byte
    widths, in the query, before the rest of the line has arrived -- and
    a `%` escape is left for the application to decode.

    covers: B19
    """
    assert_true(_invalid_bytes(_target_with("GET /caf", 0xE9, "")))
    assert_true(_invalid_bytes(_target_with("GET /?q=", 0x80, "x")))
    for n in range(0, 141):
        var prefix = String("GET /") + String("p") * n
        assert_true(_invalid_bytes(_target_with(prefix, 0xFF, "")), String(n))
    # Invalid at once, not incomplete: nothing after it can make it a URI.
    var partial = List[UInt8]()
    partial.extend("GET /caf".as_bytes())
    partial.append(0xE9)
    assert_true(_invalid_bytes(partial))
    assert_equal(
        _path_of("GET /caf%C3%A9?x=%E9 HTTP/1.1\r\nHost: x\r\n\r\n"),
        "/caf%C3%A9?x=%E9",
    )


def test_origin_form_target_is_untouched() raises:
    assert_equal(
        _path_of("GET /orders/7 HTTP/1.1\r\nHost: x\r\n\r\n"), "/orders/7"
    )


# --- Field value normalization: RFC 9110 5.5 ---------------------------------


def test_header_values_are_ows_trimmed() raises:
    """Untrimmed values turn " application/json" into a negotiation miss."""
    assert_equal(
        _header(
            "GET / HTTP/1.1\r\nHost: x\r\nAccept:   application/json  \r\n\r\n",
            "accept",
        ),
        "application/json",
    )


# --- The scanners: one answer at every width ---------------------------------
#
# `scan_to_eol`, `scan_token` and the request-target scan each run 64 lanes
# wide, then 16, then byte by byte, and the three paths must agree. The
# sweeps below put a line ending at every offset from 1 to 140 bytes into
# each scanner with the buffer ending just after it, so every hand-off
# between widths is crossed with both a match and a miss on each side.


def _long_value_round_trips(n: Int) raises:
    var value = String("v") * n
    var raw = String("GET / HTTP/1.1\r\nHost: x\r\nX-V: ") + value + "\r\n\r\n"
    assert_equal(_header(raw, "x-v"), value)


def test_field_values_end_at_the_right_byte_at_every_length() raises:
    for n in range(1, 141):
        _long_value_round_trips(n)


def test_field_names_end_at_the_colon_at_every_length() raises:
    for n in range(1, 141):
        var name = String("X-") + String("n") * n
        var raw = String("GET / HTTP/1.1\r\nHost: x\r\n") + name + ": 1\r\n\r\n"
        assert_equal(_header(raw, name.lower()), "1")


def test_request_targets_end_at_the_space_at_every_length() raises:
    for n in range(1, 141):
        var path = String("/") + String("p") * n
        var raw = String("GET ") + path + " HTTP/1.1\r\nHost: x\r\n\r\n"
        assert_equal(_path_of(raw), path)


def test_a_bare_lf_is_found_even_with_a_cr_further_on() raises:
    """The value scan stops at the FIRST control byte, LF included.

    The wide scan used to look for the first CR and only then for any
    other control byte, so a value ended by a bare LF ran on to the next
    line's CR whenever one lay within the same 64-byte chunk — the Host
    below swallowed the whole Accept line and the Accept header vanished.
    Two conditions put the bug in reach, and the shape here meets both:
    at least 64 bytes must remain from the Host value's start (the padding
    header), or the scalar tail scanned it correctly, and the Accept
    line's CR must fall inside that first 64-byte chunk (lane 35 here,
    the LF at lane 17), or the wide scan's second stage found the LF.

    A request head's bare LF is refused now (SPEC B12), and that answer
    still depends on the scan: a scan that skipped the LF to the CR would
    end the line at a CRLF, with a Host value holding an LF, and accept it.
    """
    var raw = (
        String(
            "GET / HTTP/1.1\r\n"
            "Host: example.com\n"
            "Accept: text/html\r\n"
            "X-Pad: "
        )
        + String("p") * 70
        + "\r\n\r\n"
    )
    assert_true(_rejected(raw))


def test_a_control_byte_in_a_field_name_is_invalid() raises:
    assert_true(_rejected("GET / HTTP/1.1\r\nHo\x01st: x\r\n\r\n"))


def test_a_field_line_without_a_colon_is_invalid_not_incomplete() raises:
    """The token scanner stops at the line's end, not at the next colon.

    Searching the whole buffer for a colon would find the NEXT line's and
    report this one as still arriving — and a request the server waits on
    is a request whose bytes stay in the buffer.

    covers: A16
    """
    assert_true(_rejected("GET / HTTP/1.1\r\nHost: x\r\nNoColonHere\r\n\r\n"))
    assert_true(_rejected("GET / HTTP/1.1\r\nHost: x\r\nNoColon\r\nX-Next: 1\r\n\r\n"))


def test_a_truncated_field_name_is_incomplete() raises:
    var raw = String("GET / HTTP/1.1\r\nHost: x\r\nAccep")
    assert_false(_rejected(raw))
    assert_false(_accepted(raw))


def test_a_truncated_field_name_with_a_bad_byte_is_already_invalid() raises:
    """No need to wait for the rest of a line that can never be a field."""
    assert_true(_rejected("GET / HTTP/1.1\r\nHost: x\r\nAcc ep"))


def test_a_control_byte_in_the_request_target_is_invalid() raises:
    """Declared coverage.

    covers: A17
    """
    assert_true(_rejected("GET /a\x01b HTTP/1.1\r\nHost: x\r\n\r\n"))
    assert_true(_rejected("GET /a\tb HTTP/1.1\r\nHost: x\r\n\r\n"))
    assert_true(_rejected("GET /a\x7fb HTTP/1.1\r\nHost: x\r\n\r\n"))


def test_a_truncated_request_target_is_incomplete() raises:
    var raw = String("GET /still/arriv")
    assert_false(_rejected(raw))
    assert_false(_accepted(raw))


def test_del_in_a_field_value_is_invalid_and_htab_is_content() raises:
    assert_true(_rejected("GET / HTTP/1.1\r\nHost: x\r\nX: a\x7fb\r\n\r\n"))
    assert_equal(_header("GET / HTTP/1.1\r\nHost: x\r\nX: a\tb\r\n\r\n", "x"), "a\tb")


# --- Chunked decoding: integer overflow and the truncation CVEs --------------


def _decode(raw: String) -> Tuple[Int, Int]:
    """Run the chunked decoder over one buffer. Returns (ret, decoded_len)."""
    var buf = List[UInt8]()
    buf.extend(raw.as_bytes())
    var decoder = HTTPChunkedDecoder()
    return decoder.decode(buf)


def test_chunked_body_decodes() raises:
    """Baseline: the guards below must not have broken ordinary decoding."""
    var got = _decode("5\r\nhello\r\n0\r\n\r\n")
    assert_true(got[0] >= 0, "expected a complete decode, got " + String(got[0]))
    assert_equal(got[1], 5)


def test_chunk_size_overflow_is_rejected() raises:
    """A 64-bit wrap in the size accumulator would produce a negative length.

    That value flows into a copy bound; the guard is the only thing between a
    hostile chunk header and arithmetic that no longer describes the buffer.

    Two details, both established by disabling the guard and re-running:

    - Exactly sixteen digits. Seventeen is caught by the significant-digit
      limit below, so a seventeen-digit input passes this test whether or not
      the overflow guard exists.
    - The decoded length is asserted, not just the return code. Without the
      guard the size wraps to -1, the copy loop runs `range(-1)` and moves
      `src`/`dst` *backwards*, and the decoder still eventually returns -1 —
      from a corrupted position, with dst = -1. Only `dst == 0` distinguishes
      "rejected the header" from "wandered off and failed later".
    """
    var got = _decode("FFFFFFFFFFFFFFFF\r\nx\r\n")
    assert_equal(got[0], -1)
    assert_equal(got[1], 0, "decoder advanced past a rejected chunk size")


def test_chunk_size_with_the_sign_bit_set_is_rejected() raises:
    """0x8000000000000000 is one hex digit that flips Int negative.

    With the overflow guard removed this input does not merely return a wrong
    answer — it terminates the process. That is the whole argument for the
    guard, in one test case.

    covers: B7
    """
    var got = _decode("8000000000000000\r\nx\r\n")
    assert_equal(got[0], -1)
    assert_equal(got[1], 0)


def test_chunk_size_is_limited_to_sixteen_significant_digits() raises:
    """Declared coverage.

    covers: C2
    """
    var got = _decode("11111111111111111\r\nx\r\n")
    assert_equal(got[0], -1)


def test_leading_zeros_do_not_count_toward_the_digit_limit() raises:
    """RFC 9112 7.1 permits leading zeros. Counting them truncates a valid
    chunk size, which is how the Apache truncation CVE worked."""
    var got = _decode("00000000000000000005\r\nhello\r\n0\r\n\r\n")
    assert_true(got[0] >= 0, "padded chunk size was rejected: " + String(got[0]))
    assert_equal(got[1], 5)


def test_garbage_after_the_chunk_size_is_rejected() raises:
    var got = _decode("5x\r\nhello\r\n")
    assert_equal(got[0], -1)


def test_bare_lf_in_a_chunk_extension_is_rejected() raises:
    """A lone LF where CRLF is required is a classic framing desync.

    covers: B5
    """
    var got = _decode("5;ext\nhello\r\n")
    assert_equal(got[0], -1)


def test_empty_chunk_size_is_rejected() raises:
    var got = _decode("\r\nhello\r\n")
    assert_equal(got[0], -1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


# --- the incremental chunked decoder ----------------------------------------


def _feed_incrementally(
    raw: String, piece: Int, consume_trailer: Bool = False
) raises -> Tuple[Int, String]:
    """Drive one decoder the way the event loop does: a buffer holding
    `[decoded][raw tail]`, fed only the bytes that just arrived.

    Returns (final ret, decoded body). This is the loop's arithmetic in
    miniature — if it is wrong here it is wrong there, and unlike the loop
    it can be asserted without a socket.
    """
    var dec = HTTPChunkedDecoder()
    dec.consume_trailer = consume_trailer
    var buf = Bytes()
    var decoded = 0
    var ret = -2
    var src = raw.as_bytes()
    var at = 0
    while at < len(src):
        var upto = at + piece
        if upto > len(src):
            upto = len(src)
        for i in range(at, upto):
            buf.append(src[i])
        at = upto

        if len(buf) > decoded:
            var produced: Int
            ret, produced = dec.decode(Span(buf)[decoded:])
            if ret == -1:
                return (ret, String(""))
            var leftover = dec.pending_bytes
            buf.resize(decoded + produced + leftover, 0)
            decoded += produced
            if ret >= 0:
                buf.resize(decoded, 0)
                break
    return (
        ret,
        String(unsafe_from_utf8=Span(buf)[:decoded]),
    )


def test_incremental_decode_matches_a_single_pass() raises:
    """The same body fed one byte at a time must decode to the same bytes.

    The decoder carries chunk state across calls, so feeding it only the
    NEW bytes is what makes a chunked body linear rather than quadratic in
    the number of reads. Every split lands somewhere different — mid size
    line, mid data, between CR and LF — and all of them must agree.

    covers: A7
    """
    var raw = String("5\r\nHello\r\n6\r\n World\r\n0\r\n\r\n")
    for piece in range(1, 12):
        var got = _feed_incrementally(raw, piece)
        assert_equal(got[0] >= 0, True)
        assert_equal(got[1], "Hello World")


def test_incremental_decode_does_not_leak_framing_into_the_body() raises:
    """Chunk framing must never appear in the decoded output.

    It did: the first pass over bytes that arrived WITH the headers seeded
    `bytes_read` from the raw count rather than the decoded one, so the
    resumed decode began past bytes it had not consumed and read the
    `<size>\r\n ... \r\n` in the gap as body. A 300 KB upload in 64-byte
    chunks came out 12 bytes long, holding two chunks' framing.
    """
    var sixteen = String("A") * 16
    var raw = String()
    for _ in range(12):  # 12 chunks of 16 bytes = 192
        raw += "10\r\n" + sixteen + "\r\n"
    raw += "0\r\n\r\n"
    for piece in range(1, 9):
        var got = _feed_incrementally(raw, piece)
        assert_equal(got[0] >= 0, True)
        assert_equal(got[1].byte_length(), 192)
        # Nothing but the payload byte survives.
        for c in got[1].as_bytes():
            assert_equal(c, UInt8(ord("A")))


def test_a_long_ordinary_body_does_not_trip_the_abuse_guard() raises:
    """The overhead ratio must measure framing, not the unread tail.

    Charging `buffer_len - dst` counts the not-yet-decodable remainder as
    overhead on every call — and, since the remainder is re-offered on the
    next call, counts it again each time. This body is almost all payload
    (8 bytes of framing per 8 KB chunk) and must decode whole.
    """
    var chunk = String("B") * 8192
    var raw = String()
    for _ in range(40):  # 320 KB of payload, 8 bytes of framing per chunk
        raw += "2000\r\n" + chunk + "\r\n"
    raw += "0\r\n\r\n"
    var got = _feed_incrementally(raw, 1500)
    assert_equal(got[0] >= 0, True)
    assert_equal(got[1].byte_length(), 40 * 8192)


def test_a_body_that_is_mostly_framing_still_trips_the_abuse_guard() raises:
    """The guard must still fire on what it was written for: one-byte
    chunks are 5 bytes of framing for every byte of data."""
    var raw = String()
    for _ in range(40000):
        raw += "1\r\nx\r\n"
    raw += "0\r\n\r\n"
    var got = _feed_incrementally(raw, 4096)
    assert_equal(got[0], -1)


# --- Trailer fields (RFC 9112 7.1.2, RFC 9110 6.5) ---------------------------
#
# The servers build their decoder with `consume_trailer = True`
# (`server.mojo`), which is what makes a chunked body end where RFC 9112 says
# it ends rather than at the `0\r\n` line -- see the CLAUDE.md note on why
# closing a socket with the terminating CRLF still queued sends an RST and
# loses the response. Everything below is that setting's behaviour, which the
# round-trip tests set but never exercised: their wire carries no trailer
# section at all, so every trailer state in the decoder was reached by no
# test.
#
# The decoder produces BYTES; it never touches a `Headers`. So "not surfaced
# to the application" is asserted here as the observable thing at this layer:
# no trailer byte appears in the decoded body, and no trailer field changes
# how much body there is.


def _decode_trailing(raw: String) raises -> Tuple[Int, String]:
    """Single-call decode with the servers' `consume_trailer = True`.

    Returns (ret, decoded body). `_decode` above is the same thing with the
    default setting, and the pair is deliberate: several claims below are
    only meaningful against both halves.
    """
    var buf = Bytes()
    buf.extend(raw.as_bytes())
    var dec = HTTPChunkedDecoder()
    dec.consume_trailer = True
    var res = dec.decode(Span(buf))
    if res[0] < 0:
        return (res[0], String(""))
    return (res[0], String(unsafe_from_utf8=Span(buf)[: res[1]]))


def test_a_trailer_section_is_consumed_whole() raises:
    """The body ends after the trailer, not at the zero chunk.

    `ret == 0` is the claim: zero bytes left over means the decoder consumed
    the trailer AND its terminating CRLF. Anything left behind is what the
    connection later closes on top of.

    covers: A10
    """
    var got = _decode_trailing("5\r\nhello\r\n0\r\nX-Checksum: abc123\r\n\r\n")
    assert_equal(got[0], 0)
    assert_equal(got[1], "hello")


def test_several_trailer_fields_are_consumed() raises:
    """One trailer line is the easy case; the state machine loops per line."""
    var got = _decode_trailing(
        "5\r\nhello\r\n0\r\nX-A: 1\r\nX-B: 2\r\nX-C: 3\r\n\r\n"
    )
    assert_equal(got[0], 0)
    assert_equal(got[1], "hello")


def test_no_trailer_byte_reaches_the_decoded_body() raises:
    """The trailer is discarded, not appended.

    A decoder that consumed the trailer as data would still report a clean
    `ret`, so the body is asserted by VALUE. The field value here is chosen
    to be visible if it leaks.
    """
    var got = _decode_trailing(
        "5\r\nhello\r\n0\r\nX-Leak: LEAKED-TRAILER-VALUE\r\n\r\n"
    )
    assert_equal(got[0], 0)
    assert_equal(got[1], "hello")
    assert_equal(got[1].byte_length(), 5)


def test_a_trailer_cannot_change_the_framing() raises:
    """RFC 9110 6.5: a recipient must ignore framing fields in a trailer.

    `Content-Length` and `Transfer-Encoding` arriving after the body are the
    smuggling shape of this section -- a recipient that honoured either would
    disagree with the sender about where the message ends. The assertion is
    that the hostile trailer decodes to exactly what a benign one does.
    """
    var benign = _decode_trailing("5\r\nhello\r\n0\r\nX-Ok: 1\r\n\r\n")
    var hostile = _decode_trailing(
        "5\r\nhello\r\n0\r\nContent-Length: 999\r\n"
        "Transfer-Encoding: chunked\r\nHost: evil.example\r\n\r\n"
    )
    assert_equal(hostile[0], benign[0])
    assert_equal(hostile[1], benign[1])
    assert_equal(hostile[1], "hello")


def test_bytes_after_a_trailer_are_left_for_the_next_request() raises:
    """The pipelined tail must survive the trailer, byte for byte.

    `ret` is "bytes after the chunked data", and `_drain_pipelined` re-parses
    exactly that many. A trailer parser that over-consumed by even the final
    CRLF would eat the first bytes of the next request -- which is answered
    as a malformed request, not as the request the client sent.
    """
    var tail = String("GET /next HTTP/1.1\r\nHost: x\r\n\r\n")
    var got = _decode_trailing(
        "5\r\nhello\r\n0\r\nX-Checksum: abc\r\n\r\n" + tail
    )
    assert_equal(got[0], tail.byte_length())
    assert_equal(got[1], "hello")


def test_without_consume_trailer_the_body_ends_at_the_zero_chunk() raises:
    """The other half, so a decoder that consumed everything cannot pass.

    With the default setting the trailer is NOT the decoder's business: it
    reports the trailer bytes as left over, which is what a caller framing
    its own trailers needs. Asserting only the consuming half would be
    satisfied by a decoder that always swallowed to the end of the buffer.
    """
    var trailer = String("X-Checksum: abc123\r\n\r\n")
    var got = _decode("5\r\nhello\r\n0\r\n" + trailer)
    assert_equal(got[0], trailer.byte_length())
    assert_equal(got[1], 5)


def test_an_oversized_trailer_section_trips_the_abuse_guard() raises:
    """A trailer section is bounded, and the ratio guard is what bounds it.

    Trailer bytes advance `src` and never `dst`, so they are charged as pure
    overhead -- which means the existing guard already covers them and no
    second limit is needed. That is only true while the decode is INCOMPLETE
    (the guard is inside the `ret == -2` branch), so this feeds incrementally
    the way the loop does; a single-call decode of the same bytes completes
    and is never measured. Without the guard this section is bounded only by
    what the connection's receive buffer will hold.
    """
    var raw = String("5\r\nhello\r\n0\r\n")
    for _ in range(40000):  # ~360 KB of trailer, 5 bytes of body
        raw += "X-Pad: aaaa\r\n"
    raw += "\r\n"
    var got = _feed_incrementally(raw, 4096, consume_trailer=True)
    assert_equal(got[0], -1)


def test_an_ordinary_trailer_does_not_trip_the_abuse_guard() raises:
    """The guard must not fire on a trailer any real client would send.

    The control for the test above: a body with a normal trailer decodes
    whole. A guard that refused every trailer would satisfy that test and
    break every conforming client.
    """
    var chunk = String("B") * 8192
    var raw = String()
    for _ in range(8):
        raw += "2000\r\n" + chunk + "\r\n"
    raw += "0\r\nX-Checksum: abc123\r\nX-Server-Timing: dur=12\r\n\r\n"
    var got = _feed_incrementally(raw, 1500, consume_trailer=True)
    assert_equal(got[0], 0)
    assert_equal(got[1].byte_length(), 8 * 8192)


def test_a_trailer_line_must_end_in_crlf() raises:
    """Every trailer line, and the empty one that ends the section, ends in
    CRLF; anything else makes the body invalid -- B5's rule for the chunk
    header, applied to the trailer.

    The trailer states skipped any run of CR and took a bare LF as a line
    end, so `0\\r\\n\\n` ended a body that a stricter hop in front reads
    as still open, its next bytes the trailer. Each shape below was a
    complete body with nothing left over.

    covers: B14
    """
    # A bare LF ends the trailer section.
    assert_equal(_decode_trailing("5\r\nhello\r\n0\r\n\n")[0], -1)
    # A bare LF ends a trailer field line.
    assert_equal(_decode_trailing("5\r\nhello\r\n0\r\nX-A: 1\n\r\n")[0], -1)
    # A run of CR before the LF.
    assert_equal(_decode_trailing("5\r\nhello\r\n0\r\n\r\r\n")[0], -1)
    assert_equal(_decode_trailing("5\r\nhello\r\n0\r\nX-A: 1\r\r\n\r\n")[0], -1)
    # A CR inside a trailer line that no LF follows.
    assert_equal(_decode_trailing("5\r\nhello\r\n0\r\nX-A: 1\rX\r\n\r\n")[0], -1)


def test_a_trailer_line_must_be_a_field_line() raises:
    """A name of token characters, then a colon (RFC 9112 §7.1.2, whose
    trailer section is field lines). Refused by llhttp and h11 alike; this
    decoder discarded whatever the line held.

    The no-colon shape was the differential run's finding: `XY` served
    here, refused by both references.
    """
    # No colon.
    assert_equal(_decode_trailing("5\r\nhello\r\n0\r\nXY\r\n\r\n")[0], -1)
    # An empty name.
    assert_equal(_decode_trailing("5\r\nhello\r\n0\r\n: v\r\n\r\n")[0], -1)
    # A line opening with whitespace (an obs-fold, or a name with a space).
    assert_equal(_decode_trailing("5\r\nhello\r\n0\r\n X: v\r\n\r\n")[0], -1)
    assert_equal(_decode_trailing("5\r\nhello\r\n0\r\nX-A: 1\r\n\tmore\r\n\r\n")[0], -1)
    # A separator inside the name.
    assert_equal(_decode_trailing("5\r\nhello\r\n0\r\nX A: v\r\n\r\n")[0], -1)
    # And the ordinary line still decodes: a name, a colon, any value.
    var got = _decode_trailing("5\r\nhello\r\n0\r\nX-A:\r\nX-B: a b:c\r\n\r\n")
    assert_equal(got[0], 0)
    assert_equal(got[1], "hello")


def test_a_control_byte_in_a_trailer_value_is_refused() raises:
    """A trailer line is a field line, and its value holds field content
    (RFC 9110 §5.5): a control byte other than HTAB, or DEL, makes the
    body invalid, as it makes a head's field value. The trailer is
    discarded, so this is the head's rule kept, not an exposure closed.

    covers: B24
    """
    for bad in ["\x00", "\x01", "\x0b", "\x1f", "\x7f"]:
        var raw = String("5\r\nhello\r\n0\r\nX-A: a") + bad + "b\r\n\r\n"
        assert_equal(_decode_trailing(raw)[0], -1, String("byte ", Int(bad.as_bytes()[0])))
    var tab = _decode_trailing("5\r\nhello\r\n0\r\nX-A: a\tb c\r\n\r\n")
    assert_equal(tab[0], 0)
    assert_equal(tab[1], "hello")


def test_a_trailer_split_at_every_byte_still_decodes() raises:
    """A segment boundary anywhere in the trailer is a partial read.

    The stricter states each wait at a buffer's end -- between CR and LF
    above all -- rather than answering invalid to a body the next read
    completes.
    """
    var raw = String("5\r\nhello\r\n0\r\nX-Checksum: abc\r\nX-B: 2\r\n\r\n")
    for piece in range(1, 8):
        var got = _feed_incrementally(raw, piece, consume_trailer=True)
        assert_equal(got[0], 0, String("piece ", piece))
        assert_equal(got[1], "hello")
    # And a refused shape is refused however it arrives.
    var bad = String("5\r\nhello\r\n0\r\nX-A: 1\n\r\n")
    for piece in range(1, 8):
        assert_equal(_feed_incrementally(bad, piece, consume_trailer=True)[0], -1)


def test_tchar_table_matches_the_rfc_list() raises:
    """`is_token_char` over every byte, against RFC 9110 §5.6.2 spelled out."""
    var tchars = String(
        "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    )
    var want = Array[Bool, 256](fill=False)
    for b in tchars.as_bytes():
        want[Int(b)] = True
    var count = 0
    for c in range(256):
        assert_equal(is_token_char(UInt8(c)), want[c], String("byte ", c))
        if want[c]:
            count += 1
    assert_equal(count, 77)


def test_a_separator_in_a_field_name_is_invalid_at_every_position() raises:
    """Every non-tchar printable byte, at every offset across the sixteen-
    lane boundaries the vector check works in, is a 400 -- including the
    lane right before a chunk edge and the first lane of the next."""
    var bad = String("()<>@,;\\\"/[]?={} ")
    for b in bad.as_bytes():
        for pos in range(0, 40):
            # A line opening with SP (pos 0) is an obs-fold continuation of
            # the previous field, refused for that reason (SPEC B13).
            var raw = List[UInt8]()
            raw.extend("GET / HTTP/1.1\r\nHost: x\r\n".as_bytes())
            for _ in range(pos):
                raw.append(0x6E)
            raw.append(b)
            for _ in range(40 - pos):
                raw.append(0x6E)
            raw.extend(": 1\r\n\r\n".as_bytes())
            var rejected = False
            try:
                _ = parse_request_headers(Span(raw))
            except e:
                rejected = e.isa[InvalidHTTPRequestError]()
            assert_true(rejected, String("byte ", Int(b), " at ", pos))


def test_a_byte_above_ascii_in_a_field_name_is_invalid_at_every_position() raises:
    for pos in range(0, 40):
        var raw = List[UInt8]()
        raw.extend("GET / HTTP/1.1\r\nHost: x\r\n".as_bytes())
        for _ in range(pos):
            raw.append(0x6E)
        raw.append(0xC3)
        for _ in range(40 - pos):
            raw.append(0x6E)
        raw.extend(": 1\r\n\r\n".as_bytes())
        var rejected = False
        try:
            _ = parse_request_headers(Span(raw))
        except:
            rejected = True
        assert_true(rejected, String("0xC3 at ", pos))


def test_a_field_name_of_every_tchar_round_trips_at_every_length() raises:
    """The whole tchar alphabet, cycled, as names from one byte to eighty:
    nothing the vector check lets through is refused by the table, and
    the reverse."""
    var alphabet = String(
        "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    )
    var ab = alphabet.as_bytes()
    for n in range(1, 81):
        var name = List[UInt8]()
        for k in range(n):
            name.append(ab[(k * 7) % len(ab)])
        var name_s = String(unsafe_from_utf8=Span(name))
        var raw = String("GET / HTTP/1.1\r\nHost: x\r\n") + name_s + ": v\r\n\r\n"
        assert_equal(_header(raw, name_s.lower()), "v")


def test_a_separator_in_the_value_is_not_the_name_s_problem() raises:
    """The first non-tchar lane past the name is the colon or the value;
    only lanes inside the name may refuse it."""
    var raw = String("GET / HTTP/1.1\r\nHost: x\r\nX-Name: (a) [b] {c} \"d\"\r\n\r\n")
    assert_equal(_header(raw, "x-name"), "(a) [b] {c} \"d\"")
    var raw2 = String("GET / HTTP/1.1\r\nHost: x\r\nX-Nam: (a)\r\n\r\n")
    assert_equal(_header(raw2, "x-nam"), "(a)")
