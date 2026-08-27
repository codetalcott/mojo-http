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
    HeaderKey,
)
from lightbug_http.http.chunked import HTTPChunkedDecoder
from lightbug_http.io.bytes import Bytes


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


# --- Request smuggling: RFC 7230 3.3.3 ---------------------------------------


def test_content_length_with_transfer_encoding_is_rejected() raises:
    """CL.TE: the canonical desync. Two framings, two readers, one exploit."""
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
    """Two lengths is the same ambiguity as a length plus a chunked encoding."""
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 6\r\n"
            "Content-Length: 5\r\n\r\n"
        )
    )


def test_duplicate_content_length_is_rejected_across_letter_case() raises:
    """Header names are case-insensitive; the duplicate check must be too."""
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
    """The rule is about position, not about rejecting every encoding list."""
    assert_true(
        _accepted(
            "POST / HTTP/1.1\r\nHost: x\r\n"
            "Transfer-Encoding: gzip, chunked\r\n\r\n"
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


def test_http11_requires_a_non_empty_host() raises:
    """An empty Host lets a request be routed by whatever the next hop guesses."""
    assert_true(_rejected("GET / HTTP/1.1\r\nHost: \r\n\r\n"))


def test_http11_rejects_a_whitespace_only_host() raises:
    """OWS trimming turns "Host: \\t" into "", which must still be rejected."""
    assert_true(_rejected("GET / HTTP/1.1\r\nHost:\t\r\n\r\n"))


def test_http11_accepts_a_real_host() raises:
    assert_true(_accepted("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"))


def test_http10_without_host_is_accepted() raises:
    """The Host requirement is HTTP/1.1's; 1.0 predates it."""
    assert_true(_accepted("GET / HTTP/1.0\r\n\r\n"))


def test_http11_requires_host_to_be_present_at_all() raises:
    """RFC 9112 3.2 asks for 400, and the empty-Host check did not cover
    this: `headers.get()` returned None, which short-circuited the `and`
    and let the request through with its target host unstated."""
    assert_true(_rejected("GET / HTTP/1.1\r\n\r\n"))
    assert_true(_rejected("POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\n"))


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
    """
    assert_true(
        _rejected("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n")
    )
    assert_true(
        _rejected("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: identity\r\n\r\n")
    )
    # A loose substring match would let these through as "chunked".
    assert_true(
        _rejected("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: xchunked\r\n\r\n")
    )
    assert_true(
        _rejected("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked-foo\r\n\r\n")
    )


def test_chunked_as_the_last_coding_is_still_accepted() raises:
    """The control: a legitimate `gzip, chunked` must keep working."""
    assert_true(
        _accepted(
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n"
        )
    )
    assert_true(
        _accepted("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: CHUNKED\r\n\r\n")
    )


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
    acted on would not be the value sent."""
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
    """An unbounded header list is free memory amplification for an attacker."""
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


# --- Request target normalization: RFC 9112 3.2.2 ----------------------------


def test_absolute_form_target_is_reduced_to_its_path() raises:
    """Handlers compare paths; a proxy-style target must not reach them whole."""
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
    """
    var got = _decode("8000000000000000\r\nx\r\n")
    assert_equal(got[0], -1)
    assert_equal(got[1], 0)


def test_chunk_size_is_limited_to_sixteen_significant_digits() raises:
    var got = _decode("11111111111111111\r\nx\r\n")
    assert_equal(got[0], -1)


def test_leading_zeros_do_not_count_toward_the_digit_limit() raises:
    """RFC 7230 4.1 permits leading zeros. Counting them truncates a valid
    chunk size, which is how the Apache truncation CVE worked."""
    var got = _decode("00000000000000000005\r\nhello\r\n0\r\n\r\n")
    assert_true(got[0] >= 0, "padded chunk size was rejected: " + String(got[0]))
    assert_equal(got[1], 5)


def test_garbage_after_the_chunk_size_is_rejected() raises:
    var got = _decode("5x\r\nhello\r\n")
    assert_equal(got[0], -1)


def test_bare_lf_in_a_chunk_extension_is_rejected() raises:
    """A lone LF where CRLF is required is a classic framing desync."""
    var got = _decode("5;ext\nhello\r\n")
    assert_equal(got[0], -1)


def test_empty_chunk_size_is_rejected() raises:
    var got = _decode("\r\nhello\r\n")
    assert_equal(got[0], -1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


# --- the incremental chunked decoder ----------------------------------------


def _feed_incrementally(raw: String, piece: Int) raises -> Tuple[Int, String]:
    """Drive one decoder the way the event loop does: a buffer holding
    `[decoded][raw tail]`, fed only the bytes that just arrived.

    Returns (final ret, decoded body). This is the loop's arithmetic in
    miniature — if it is wrong here it is wrong there, and unlike the loop
    it can be asserted without a socket.
    """
    var dec = HTTPChunkedDecoder()
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
