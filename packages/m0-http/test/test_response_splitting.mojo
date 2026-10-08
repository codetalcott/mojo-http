"""What a response head refuses to carry: CR, LF or NUL (SPEC G1, G2).

A header name, a header value, a reason phrase and a `Set-Cookie` line are
each written into the head verbatim, so a CR or LF inside one ends its line
and starts another the application never listed -- a header, or after a
blank line a body: response splitting. NUL ends a C string. The refusal
used to live only in m0-wsgi, which reads an application's head through the
C API, so every head built in Mojo -- a view's, the Mojo host's, a
`--mount X=mojo` pool thread's -- reached `write_latin1_to` uninspected. It
lives in the fork's head writers now, which every response passes through:
`encode` (the event loop's error answers, `_send_error_to_fd`),
`encode_into` (every other response the loop writes) and the text form a
test prints, each held here.

Every case is judged on the BYTES a writer produced: the injected marker
must be absent from all of them, every head line must be free of CR, LF and
NUL between its CRLFs, and the clean neighbours must still be there --
without them, dropping everything would pass.

The latin-1 transcoder runs AFTER the refusal has looked, so it must never
make a CR, LF or NUL of its own (SPEC G19): it decoded the overlong forms
`E0 80 8D` and `E0 80 8A` to a real CRLF, which `unquote` hands a view from
`?next=%E0%80%8D%E0%80%8A...`.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.cookie import Cookie, ResponseCookieJar
from lightbug_http.header import (
    Header,
    Headers,
    HEADER_VALUE_ASCII,
    HEADER_VALUE_BREAKS,
    HEADER_VALUE_HIGH,
    encode_latin1_header_value,
    header_value_kind,
    span_breaks_header_line,
)
from lightbug_http.http import HTTPResponse
from lightbug_http.io.bytes import Bytes


comptime MARK = "hijack"
"""What every injection below tries to put on the wire."""


def _find(hay: Span[Byte, _], needle: Span[Byte, _]) -> Int:
    """Byte offset of `needle` in `hay`, or -1."""
    var n = len(needle)
    if n > len(hay):
        return -1
    for i in range(len(hay) - n + 1):
        var hit = True
        for j in range(n):
            if hay[i + j] != needle[j]:
                hit = False
                break
        if hit:
            return i
    return -1


def _has(wire: List[Byte], needle: String) -> Bool:
    return _find(Span(wire), needle.as_bytes()) >= 0


def _head_lines(wire: List[Byte]) raises -> Int:
    """The head's line count, status line included, asserting on the way
    that each line holds no CR, LF or NUL of its own: every CR in the head
    is the start of a CRLF, and no LF or NUL stands anywhere else."""
    var end = _find(Span(wire), String("\r\n\r\n").as_bytes())
    assert_true(end > 0, "the head has no end")
    var lines = 1
    var i = 0
    while i < end:
        var b = wire[i]
        if b == 0x0D:
            assert_equal(Int(wire[i + 1]), 0x0A, "a CR in the head that ends no line")
            lines += 1
            i += 2
            continue
        assert_true(b != 0x0A, "a bare LF in the head")
        assert_true(b != 0x00, "a NUL in the head")
        i += 1
    return lines


def _encoded(var resp: HTTPResponse) -> List[Byte]:
    """What the event loop writes for an error it answers itself."""
    return resp^.encode()


def _encoded_into(var resp: HTTPResponse) -> List[Byte]:
    """What the event loop writes, through its rotating buffer."""
    return resp^.encode_into(Bytes(capacity=256))


def _text(resp: HTTPResponse) -> List[Byte]:
    """The response printed, which a test reads as the response sent."""
    var s = String(resp)
    return List[Byte](s.as_bytes())


def _response(var headers: Headers, status: Int = 200, text: String = "OK") -> HTTPResponse:
    return HTTPResponse(
        body_bytes=String("ok").as_bytes(),
        headers=headers^,
        status_code=status,
        status_text=text,
    )


def _clean_headers() -> Headers:
    return Headers(Header("x-before", "fine"), Header("x-after", "fine too"))


def _injected_headers() -> Headers:
    """The clean pair with every shape of injection between them: CRLF, a
    bare LF, a bare CR and a NUL in a value, a CRLF far enough in to sit in
    the scan's sixteen-lane loop rather than its tail, and a CRLF in a
    NAME."""
    return Headers(
        Header("x-before", "fine"),
        Header("x-crlf", "a\r\nSet-Cookie: hijack=1"),
        Header("x-lf", "a\nX-Hijack: 1"),
        Header("x-cr", "a\rX-Hijack: 1"),
        Header("x-nul", "a\x00hijack"),
        Header("x-deep", "0123456789abcdef0123456789\r\nX-Hijack: 1"),
        Header("x-hijack\r\nx-name", "v"),
        Header("x-after", "fine too"),
    )


def _assert_injected_headers_dropped(wire: List[Byte], clean: List[Byte]) raises:
    assert_false(_has(wire, MARK), "an injected header reached the bytes")
    assert_false(_has(wire, "x-crlf"), "a header carrying CRLF was written")
    assert_false(_has(wire, "x-nul"), "a header carrying NUL was written")
    assert_true(_has(wire, "x-before: fine\r\n"), "the clean header before was dropped too")
    assert_true(_has(wire, "x-after: fine too\r\n"), "the clean header after was dropped too")
    assert_equal(_head_lines(wire), _head_lines(clean))


def test_an_injected_header_is_dropped_and_its_neighbours_kept() raises:
    """A header whose name or value holds CR, LF or NUL is dropped by every
    head writer, and the headers beside it are written.

    covers: G2
    """
    _assert_injected_headers_dropped(
        _encoded(_response(_injected_headers())), _encoded(_response(_clean_headers()))
    )
    _assert_injected_headers_dropped(
        _encoded_into(_response(_injected_headers())),
        _encoded_into(_response(_clean_headers())),
    )
    _assert_injected_headers_dropped(
        _text(_response(_injected_headers())), _text(_response(_clean_headers()))
    )


def _assert_reason_emptied(wire: List[Byte], status_line: String) raises:
    assert_false(_has(wire, MARK), "an injected reason phrase reached the bytes")
    assert_equal(
        _find(Span(wire), status_line.as_bytes()), 0, "the status line is not " + status_line
    )
    _ = _head_lines(wire)


def test_an_injected_reason_phrase_is_emptied_and_the_code_kept() raises:
    """A reason phrase holding CR, LF or NUL goes out as the empty phrase;
    the code the application chose is kept.

    covers: G1
    """
    var injected = List[String]()
    injected.append("OK\r\nSet-Cookie: hijack=1")
    injected.append("OK\nLocation: http://hijack.example")
    injected.append("OK\rX-Hijack: 1")
    injected.append("OK\x00hijack")
    injected.append("A Reason Longer Than Sixteen\r\nX-Hijack: 1")
    for i in range(len(injected)):
        var text = injected[i]
        _assert_reason_emptied(_encoded(_response(Headers(), 404, text)), "HTTP/1.1 404 \r\n")
        _assert_reason_emptied(
            _encoded_into(_response(Headers(), 404, text)), "HTTP/1.1 404 \r\n"
        )
        _assert_reason_emptied(_text(_response(Headers(), 404, text)), "HTTP/1.1 404 \r\n")
    # The control: a clean phrase is written as it was given.
    var wire = _encoded_into(_response(Headers(), 404, "Not Found"))
    assert_equal(_find(Span(wire), String("HTTP/1.1 404 Not Found\r\n").as_bytes()), 0)


def _jar_with_injections() -> ResponseCookieJar:
    var jar = ResponseCookieJar()
    jar.add_raw("a=1; Path=/")
    jar.add_raw("b=2\r\nSet-Cookie: hijack=1")
    jar.add_raw("c=3\nX-Hijack: 1")
    jar.add_raw("d=4\x00hijack")
    jar.set_cookie(Cookie("e", "5\r\nX-Hijack: 1"))
    jar.set_cookie(Cookie("f", "6"))
    return jar^


def _assert_injected_cookies_dropped(wire: List[Byte]) raises:
    assert_false(_has(wire, MARK), "an injected Set-Cookie line reached the bytes")
    assert_true(_has(wire, "set-cookie: a=1; Path=/\r\n"), "the clean raw line was dropped too")
    assert_true(_has(wire, "set-cookie: f=6"), "the clean built cookie was dropped too")
    var lines = 0
    var at = 0
    var needle = String("set-cookie: ")
    while True:
        var found = _find(Span(wire)[at:], needle.as_bytes())
        if found < 0:
            break
        lines += 1
        at += found + needle.byte_length()
    assert_equal(lines, 2, "expected exactly the two clean Set-Cookie lines")
    _ = _head_lines(wire)


def test_an_injected_cookie_line_is_dropped_and_the_others_sent() raises:
    """A `Set-Cookie` line holding CR, LF or NUL -- a line an application
    handed `add_raw`, or a `Cookie` a view built -- is dropped, and the
    jar's other lines are written.

    covers: G2
    """
    var r1 = _response(Headers())
    r1.cookies = _jar_with_injections()
    _assert_injected_cookies_dropped(_encoded(r1^))
    var r2 = _response(Headers())
    r2.cookies = _jar_with_injections()
    _assert_injected_cookies_dropped(_encoded_into(r2^))
    var r3 = _response(Headers())
    r3.cookies = _jar_with_injections()
    _assert_injected_cookies_dropped(_text(r3))


def test_a_tab_and_bytes_above_ascii_are_content_not_framing() raises:
    """The control for the whole file: a TAB is legal inside a value (RFC
    9110 field content) and a byte above 0x7F goes out latin-1 encoded, so
    neither may be mistaken for a line break."""
    var wire = _encoded_into(
        _response(Headers(Header("x-tab", "a\tb"), Header("x-latin", "café")))
    )
    assert_true(_has(wire, "x-tab: a\tb\r\n"), "a TAB in a value was refused")
    var latin = List[Byte](String("x-latin: caf").as_bytes())
    latin.append(0xE9)
    latin.append(0x0D)
    latin.append(0x0A)
    assert_true(_find(Span(wire), Span(latin)) >= 0, "a latin-1 value was refused")


def _seq(a: Int, b: Int = -1, c: Int = -1, d: Int = -1) -> List[Byte]:
    var s = List[Byte]()
    for v in [a, b, c, d]:
        if v >= 0:
            s.append(UInt8(v))
    return s^


def _cat(before: String, seq: List[Byte], after: String) -> List[Byte]:
    """`before`, the raw bytes of `seq`, then `after`."""
    var b = List[Byte](before.as_bytes())
    b.extend(Span(seq))
    b.extend(after.as_bytes())
    return b^


def _str(b: List[Byte]) -> String:
    """`b` as a String, whether or not it is UTF-8, as a request's bytes
    become one."""
    return String(unsafe_from_utf8=Span(b))


def _overlongs() -> List[List[Byte]]:
    """An ASCII control in a longer form than UTF-8 allows: CR, LF and NUL
    in three bytes and LF and NUL in four, the record's five, then CR and LF
    in two, whose lead bytes 0xC0 and 0xC1 this transcoder never decoded."""
    var all = List[List[Byte]]()
    all.append(_seq(0xE0, 0x80, 0x8D))
    all.append(_seq(0xE0, 0x80, 0x8A))
    all.append(_seq(0xF0, 0x80, 0x80, 0x8A))
    all.append(_seq(0xF0, 0x80, 0x80, 0x80))
    all.append(_seq(0xE0, 0x80, 0x80))
    all.append(_seq(0xC0, 0x8D))
    all.append(_seq(0xC1, 0x8A))
    return all^


def test_the_transcoder_maps_only_latin1_and_passes_the_rest_verbatim() raises:
    """`encode_latin1_header_value` turns exactly the two-byte sequences
    `C2 80` to `C3 BF` (U+0080 to U+00FF) into their latin-1 byte. Every
    other sequence goes out as the bytes it came in as: one above U+00FF
    has no latin-1 byte, and an overlong one is not UTF-8 -- the three- and
    four-byte forms of CR, LF and NUL decoded to the real byte, AFTER the
    writer had looked for one.

    covers: G19
    """
    var overlongs = _overlongs()
    for k in range(len(overlongs)):
        var given = _cat("a", overlongs[k], "b")
        var out = encode_latin1_header_value(_str(given))
        assert_equal(len(out), len(given), String("overlong ", k, " changed length"))
        for i in range(len(given)):
            assert_equal(Int(out[i]), Int(given[i]), String("overlong ", k, " byte ", i))
        assert_false(span_breaks_header_line(Span(out)), String("overlong ", k))
    # The latin-1 range, both ends and the middle: one byte each.
    var latin = List[List[Byte]]()
    latin.append(_seq(0xC2, 0x80))
    latin.append(_seq(0xC3, 0xA9))
    latin.append(_seq(0xC3, 0xBF))
    var want = [0x80, 0xE9, 0xFF]
    for k in range(len(latin)):
        var out = encode_latin1_header_value(_str(_cat("a", latin[k], "b")))
        assert_equal(len(out), 3)
        assert_equal(Int(out[1]), want[k])
    # Above U+00FF, well formed, and malformed beside the range: verbatim.
    var verbatim = List[List[Byte]]()
    verbatim.append(_seq(0xC4, 0x80))
    verbatim.append(_seq(0xE2, 0x82, 0xAC))
    verbatim.append(_seq(0xF0, 0x9F, 0x98, 0x80))
    verbatim.append(_seq(0xC3, 0x41))
    verbatim.append(_seq(0xC3))
    for k in range(len(verbatim)):
        var given = _cat("a", verbatim[k], "")
        var out = encode_latin1_header_value(_str(given))
        assert_equal(len(out), len(given), String("sequence ", k, " changed length"))
        for i in range(len(given)):
            assert_equal(Int(out[i]), Int(given[i]), String("sequence ", k, " byte ", i))


def _overlong_headers() -> Headers:
    """A clean pair with each of the record's overlong values between them,
    and a clean `é` beside them."""
    var cr_lf = _seq(0xE0, 0x80, 0x8D)
    cr_lf.extend(Span(_seq(0xE0, 0x80, 0x8A)))
    return Headers(
        Header("x-before", "fine"),
        Header("x-cr-lf", _str(_cat("/", cr_lf, "Set-Cookie: hijack=1"))),
        Header("x-lf4", _str(_cat("a", _seq(0xF0, 0x80, 0x80, 0x8A), "X-Hijack: 1"))),
        Header("x-nul3", _str(_cat("a", _seq(0xE0, 0x80, 0x80), "hijack"))),
        Header("x-nul4", _str(_cat("a", _seq(0xF0, 0x80, 0x80, 0x80), "hijack"))),
        Header("x-latin", _str(_cat("caf", _seq(0xC3, 0xA9), ""))),
        Header("x-after", "fine too"),
    )


def _line(name: String, value: List[Byte]) -> List[Byte]:
    """`\\r\\nname: value\\r\\n`: one whole head line, bounded on both sides."""
    var b = List[Byte](String("\r\n", name, ": ").as_bytes())
    b.extend(Span(value))
    b.extend(String("\r\n").as_bytes())
    return b^


def _assert_overlongs_kept_whole(wire: List[Byte], clean: List[Byte], latin1: Bool) raises:
    """Five more head lines than the clean pair's and not one more: each
    overlong value kept on its own line, byte for byte as it was given --
    so neither transcoded into a break nor dropped as one -- and the `é`
    in latin-1 where the writer transcodes."""
    assert_equal(
        _head_lines(wire), _head_lines(clean) + 5, "an overlong value split or lost a line"
    )
    var cr_lf = _seq(0xE0, 0x80, 0x8D)
    cr_lf.extend(Span(_seq(0xE0, 0x80, 0x8A)))
    var kept = List[List[Byte]]()
    kept.append(_line("x-cr-lf", _cat("/", cr_lf, "Set-Cookie: hijack=1")))
    kept.append(_line("x-lf4", _cat("a", _seq(0xF0, 0x80, 0x80, 0x8A), "X-Hijack: 1")))
    kept.append(_line("x-nul3", _cat("a", _seq(0xE0, 0x80, 0x80), "hijack")))
    kept.append(_line("x-nul4", _cat("a", _seq(0xF0, 0x80, 0x80, 0x80), "hijack")))
    for k in range(len(kept)):
        assert_true(
            _find(Span(wire), Span(kept[k])) >= 0,
            String("overlong header ", k, " was not written as it was given"),
        )
    assert_false(_has(wire, "\r\nSet-Cookie"), "an overlong CRLF started a header")
    assert_false(_has(wire, "\nX-Hijack"), "an overlong LF started a header")
    var cafe = _seq(0xE9) if latin1 else _seq(0xC3, 0xA9)
    assert_true(
        _find(Span(wire), Span(_line("x-latin", _cat("caf", cafe, "")))) >= 0,
        "the clean latin-1 value beside them did not go out as it should",
    )


def test_an_overlong_line_break_is_not_a_way_past_the_refusal() raises:
    """A header value carrying the overlong form of CR, LF or NUL goes out
    with its bytes as given, on a line of its own, from every head writer:
    the transcoder decoded each to the real byte after the refusal had
    looked, and wrote the split G2 refuses.

    covers: G19
    """
    _assert_overlongs_kept_whole(
        _encoded(_response(_overlong_headers())), _encoded(_response(_clean_headers())), True
    )
    _assert_overlongs_kept_whole(
        _encoded_into(_response(_overlong_headers())),
        _encoded_into(_response(_clean_headers())),
        True,
    )
    _assert_overlongs_kept_whole(
        _text(_response(_overlong_headers())), _text(_response(_clean_headers())), False
    )


def _jar_with_overlongs() -> ResponseCookieJar:
    var cr_lf = _seq(0xE0, 0x80, 0x8D)
    cr_lf.extend(Span(_seq(0xE0, 0x80, 0x8A)))
    var jar = ResponseCookieJar()
    jar.add_raw(_str(_cat("b=", cr_lf, "Set-Cookie: hijack=1")))
    jar.add_raw(_str(_cat("c=", _seq(0xF0, 0x80, 0x80, 0x8A), "X-Hijack: 1")))
    jar.add_raw(_str(_cat("d=", _seq(0xE0, 0x80, 0x80), "x")))
    jar.add_raw(_str(_cat("e=", _seq(0xF0, 0x80, 0x80, 0x80), "x")))
    jar.add_raw(_str(_cat("g=caf", _seq(0xC3, 0xA9), "")))
    jar.set_cookie(Cookie("f", _str(_cat("6", cr_lf, "X-Hijack: 1"))))
    return jar^


def _assert_overlong_cookies_kept_whole(
    wire: List[Byte], clean: List[Byte], latin1: Bool
) raises:
    assert_equal(
        _head_lines(wire), _head_lines(clean) + 6, "an overlong cookie split or lost a line"
    )
    var cr_lf = _seq(0xE0, 0x80, 0x8D)
    cr_lf.extend(Span(_seq(0xE0, 0x80, 0x8A)))
    var kept = List[List[Byte]]()
    kept.append(_line("set-cookie", _cat("b=", cr_lf, "Set-Cookie: hijack=1")))
    kept.append(_line("set-cookie", _cat("c=", _seq(0xF0, 0x80, 0x80, 0x8A), "X-Hijack: 1")))
    kept.append(_line("set-cookie", _cat("d=", _seq(0xE0, 0x80, 0x80), "x")))
    kept.append(_line("set-cookie", _cat("e=", _seq(0xF0, 0x80, 0x80, 0x80), "x")))
    kept.append(_line("set-cookie", _cat("f=6", cr_lf, "X-Hijack: 1")))
    for k in range(len(kept)):
        assert_true(
            _find(Span(wire), Span(kept[k])) >= 0,
            String("overlong Set-Cookie ", k, " was not written as it was given"),
        )
    assert_false(_has(wire, "\r\nSet-Cookie"), "an overlong CRLF started a header")
    assert_false(_has(wire, "\nX-Hijack"), "an overlong LF started a header")
    var cafe = _seq(0xE9) if latin1 else _seq(0xC3, 0xA9)
    assert_true(
        _find(Span(wire), Span(_line("set-cookie", _cat("g=caf", cafe, "")))) >= 0,
        "the clean latin-1 cookie beside them did not go out as it should",
    )


def test_an_overlong_line_break_in_a_cookie_is_not_a_way_past_the_refusal() raises:
    """The cookie jar's latin-1 writer is the header writer's rule for one
    header, so an overlong CR, LF or NUL in a line handed to `add_raw`, or
    in a `Cookie` a view built, goes out as given, never as a break: its
    bytes are above 0x7F, not the `;` or control byte LF55 drops a built
    cookie for.

    covers: G19
    """
    var r1 = _response(Headers())
    r1.cookies = _jar_with_overlongs()
    _assert_overlong_cookies_kept_whole(_encoded(r1^), _encoded(_response(Headers())), True)
    var r2 = _response(Headers())
    r2.cookies = _jar_with_overlongs()
    _assert_overlong_cookies_kept_whole(
        _encoded_into(r2^), _encoded_into(_response(Headers())), True
    )
    var r3 = _response(Headers())
    r3.cookies = _jar_with_overlongs()
    _assert_overlong_cookies_kept_whole(_text(r3), _text(_response(Headers())), False)


def test_the_scan_finds_each_byte_at_every_position() raises:
    """`span_breaks_header_line` reads sixteen lanes at a time with an
    overlapping last load, two loads of eight or of four for a shorter
    span, and bytes only under four: a CR, LF or NUL is found at every
    position of every length up to forty, which crosses every one of those
    paths, and no other byte value is taken for one."""
    assert_false(span_breaks_header_line(Span(List[Byte]())))
    var bad = List[Byte]()
    bad.append(0x0D)
    bad.append(0x0A)
    bad.append(0x00)
    for n in range(1, 41):
        for pos in range(n):
            for k in range(len(bad)):
                var b = List[Byte](capacity=n)
                b.resize(n, 0x61)
                b[pos] = bad[k]
                assert_true(
                    span_breaks_header_line(Span(b)),
                    String("missed byte ", Int(bad[k]), " at ", pos, " of ", n),
                )
        for v in range(256):
            if v == 0x0D or v == 0x0A or v == 0x00:
                continue
            var b = List[Byte](capacity=n)
            b.resize(n, UInt8(v))
            assert_false(
                span_breaks_header_line(Span(b)),
                String("byte ", v, " taken for a line break at length ", n),
            )


def _kind_of(n: Int, high_at: Int, break_at: Int) -> Int:
    """`header_value_kind` of `n` bytes of `a`, with 0xE9 at `high_at` and
    a CR at `break_at` (either -1 for none)."""
    var b = List[Byte](capacity=n)
    b.resize(n, 0x61)
    if high_at >= 0:
        b[high_at] = 0xE9
    if break_at >= 0:
        b[break_at] = 0x0D
    return header_value_kind(Span(b))


def test_the_value_scan_classifies_at_every_position() raises:
    """`header_value_kind` asks both of the writer's questions of each load:
    plain ASCII, a byte above 0x7F, or a line break -- which wins over a
    high byte wherever each sits -- at every position of every length up
    to forty. A HIGH taken for ASCII writes UTF-8 where latin-1 belongs; a
    BREAKS taken for either writes the split."""
    assert_equal(header_value_kind(Span(List[Byte]())), HEADER_VALUE_ASCII)
    for n in range(1, 41):
        assert_equal(_kind_of(n, -1, -1), HEADER_VALUE_ASCII)
        for pos in range(n):
            assert_equal(_kind_of(n, pos, -1), HEADER_VALUE_HIGH)
            assert_equal(_kind_of(n, -1, pos), HEADER_VALUE_BREAKS)
            assert_equal(_kind_of(n, pos, n - 1 - pos), HEADER_VALUE_BREAKS)
            for bad in range(3):
                var b = List[Byte](capacity=n)
                b.resize(n, 0x61)
                b[pos] = UInt8(0x0D) if bad == 0 else (
                    UInt8(0x0A) if bad == 1 else UInt8(0x00)
                )
                assert_equal(header_value_kind(Span(b)), HEADER_VALUE_BREAKS)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
