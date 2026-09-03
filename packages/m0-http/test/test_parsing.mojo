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
    """Two lengths is the same ambiguity as a length plus a chunked encoding."""
    assert_true(
        _rejected(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 6\r\n"
            "Content-Length: 5\r\n\r\n"
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
    """An empty Host lets a request be routed by whatever the next hop guesses.

    covers: A14
    """
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

    covers: B3
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


def test_a_bare_lf_ends_the_line_even_with_a_cr_further_on() raises:
    """A lone LF is a line terminator here (RFC 9112 §2.2 allows it).

    The wide scan used to look for the first CR and only then for any
    other control byte, so a value ended by a bare LF ran on to the next
    line's CR whenever one lay within the same 64-byte chunk — the Host
    below swallowed the whole Accept line and the Accept header vanished.
    Two conditions put the bug in reach, and the shape here meets both:
    at least 64 bytes must remain from the Host value's start (the padding
    header), or the scalar tail scanned it correctly, and the Accept
    line's CR must fall inside that first 64-byte chunk (lane 35 here,
    the LF at lane 17), or the wide scan's second stage found the LF.
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
    assert_equal(_header(raw, "host"), "example.com")
    assert_equal(_header(raw, "accept"), "text/html")


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
