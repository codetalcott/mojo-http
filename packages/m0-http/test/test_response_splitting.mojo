"""What a response head refuses to carry: CR, LF or NUL (SPEC G1, G2).

A header name, a header value, a reason phrase and a `Set-Cookie` line are
each written into the head verbatim, so a CR or LF inside one ends its line
and starts another the application never listed -- a header, or after a
blank line a body: response splitting. NUL ends a C string. The refusal
used to live only in m0-wsgi, which reads an application's head through the
C API, so every head built in Mojo -- a view's, the Mojo host's, a
`--mount X=mojo` pool thread's -- reached `write_latin1_to` uninspected. It
lives in the fork's head writers now, which every response passes through:
`encode` (the blocking server), `encode_into` (the event loop) and the text
form a test prints, each held here.

Every case is judged on the BYTES a writer produced: the injected marker
must be absent from all of them, every head line must be free of CR, LF and
NUL between its CRLFs, and the clean neighbours must still be there --
without them, dropping everything would pass.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.cookie import Cookie, ResponseCookieJar
from lightbug_http.header import (
    Header,
    Headers,
    HEADER_VALUE_ASCII,
    HEADER_VALUE_BREAKS,
    HEADER_VALUE_HIGH,
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
    """What the blocking server writes."""
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
