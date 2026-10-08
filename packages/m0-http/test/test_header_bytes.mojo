"""No byte string puts CR, LF or NUL inside a response head line (SPEC G24).

`test_response_splitting.mojo` holds G2 and G19 on fixed inputs: the shapes
the 2026-10-07 review found. This is the same claim as a property over bytes
nobody chose. Each case is made from a seeded generator biased toward what
broke the head once: every UTF-8 lead (the overlong `C0`/`C1`, the two-,
three- and four-byte leads, the invalid `F8`-`FF`), lone continuations, and
continuation bytes that DECODE to U+000A, U+000D or U+0000 when a writer
decodes an overlong form. The bytes become a header value, a header name, a
reason phrase, a `Server` value, a raw `Set-Cookie` line, a built cookie's
value and a `reply.redirect` target, and each response is written by every
head writer: `encode`, `encode_into` and the printed form.

The oracle is a model of the rules, not "no CR": the bytes a writer put
between the status line and the blank line must be, line for line, the lines
the rules say. A header or cookie holding CR, LF or NUL in what was GIVEN is
dropped, and so is a built cookie whose value holds a `;` or any other
control byte (C0 or DEL), which could add an attribute (review record LF55;
its name here is the token `f`); any other is written as given with only
`C2`/`C3` plus a continuation byte turned into one latin-1 byte (the text
form writes the bytes as they are). So an extra line, an altered line, a line lost that the
rules keep, a body that is not the one handed in, and a CR, LF or NUL inside
any line all fail -- and a writer that dropped everything fails too, which
"no CR on the wire" alone would pass.

Deterministic: the seed is printed, and `M0_HEADER_BYTES_SEED` replays a
failure, whose message names the seed, the iteration, the writer and the
input bytes in hex.

"""

from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_true

from lightbug_http.cookie import Cookie, ResponseCookieJar
from lightbug_http.header import (
    Header,
    Headers,
    encode_latin1_header_value,
    span_breaks_header_line,
)
from lightbug_http.http import HTTPResponse
from lightbug_http.io.bytes import Bytes

from src.reply import redirect


comptime SEED_ENV = "M0_HEADER_BYTES_SEED"
comptime DEFAULT_SEED = 20261008
comptime ITERATIONS = 4000
comptime BODY = "ok"
comptime WRITERS = 3
"""`encode`, `encode_into` and the printed form."""


struct Rng(Movable):
    """Deterministic xorshift64, reproducible from its seed."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed if seed != 0 else 0x9E3779B97F4A7C15

    def next(mut self) -> UInt64:
        var x = self.state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        self.state = x
        return x

    def below(mut self, n: Int) -> Int:
        return Int((self.next() >> 11) % UInt64(n))


def _seq(a: Int, b: Int = -1, c: Int = -1, d: Int = -1) -> List[Byte]:
    var s = List[Byte]()
    for v in [a, b, c, d]:
        if v >= 0:
            s.append(UInt8(v))
    return s^


def _str(b: List[Byte]) -> String:
    """`b` as a String, whether or not it is UTF-8, as a request's bytes
    become one."""
    return String(unsafe_from_utf8=Span(b))


def _hex(b: List[Byte]) -> String:
    comptime DIGITS = "0123456789abcdef"
    var s = String()
    for i in range(len(b)):
        if i > 0:
            s += " "
        var v = Int(b[i])
        s += DIGITS[byte = v >> 4 : (v >> 4) + 1]
        s += DIGITS[byte = v & 15 : (v & 15) + 1]
    return s^


def _is_break(b: Byte) -> Bool:
    return b == 0x0D or b == 0x0A or b == 0x00


def _breaks(b: List[Byte]) -> Bool:
    for i in range(len(b)):
        if _is_break(b[i]):
            return True
    return False


def _adds_an_attribute(b: List[Byte]) -> Bool:
    """LF55's rule for a built cookie's value, in its own words: a `;` or a
    control byte (C0 or DEL) drops the cookie. A byte above 0x7F does not."""
    for i in range(len(b)):
        if b[i] < 0x20 or b[i] == 0x7F or b[i] == 0x3B:
            return True
    return False


def _eq(a: List[Byte], b: List[Byte]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _continuation(mut rng: Rng) -> Byte:
    """A continuation byte; one in four is the low bits of CR, LF or NUL,
    which is what a decoder of an overlong form would turn into one."""
    var r = rng.below(8)
    if r == 0:
        return 0x8D
    if r == 1:
        return 0x8A
    if r == 2:
        return 0x80
    return UInt8(0x80 + rng.below(0x40))


def _piece(mut rng: Rng, allow_raw: Bool, mut out: List[Byte]):
    """One run of bytes, biased toward every UTF-8 lead."""
    var kind = rng.below(10)
    if kind <= 1:
        for _ in range(1 + rng.below(4)):
            out.append(UInt8(0x61 + rng.below(26)))
    elif kind <= 3:
        # Any lead, then up to three continuations.
        var lead = 0xC0 + rng.below(0x40)
        out.append(UInt8(lead))
        for _ in range(rng.below(4)):
            out.append(_continuation(rng))
    elif kind <= 5:
        # An overlong form of CR, LF or NUL in 2, 3 or 4 bytes.
        var low = 0x80
        var r = rng.below(3)
        if r == 0:
            low = 0x8D
        elif r == 1:
            low = 0x8A
        var width = 2 + rng.below(3)
        if width == 2:
            out.append(UInt8(0xC0 + rng.below(2)))
        elif width == 3:
            out.append(0xE0)
            out.append(0x80)
        else:
            out.append(0xF0)
            out.append(0x80)
            out.append(0x80)
        out.append(UInt8(low))
    elif kind == 6:
        # A well formed latin-1 pair, the case that must still transcode.
        out.append(UInt8(0xC2 + rng.below(2)))
        out.append(UInt8(0x80 + rng.below(0x40)))
    elif kind == 7:
        for _ in range(1 + rng.below(3)):
            out.append(UInt8(0x80 + rng.below(0x40)))
    elif kind == 8:
        out.append(UInt8(0xF8 + rng.below(8)))
        out.append(_continuation(rng))
    else:
        var b = UInt8(rng.below(256))
        if not allow_raw and _is_break(b):
            b = 0x41
        out.append(b)
    if allow_raw and rng.below(6) == 0:
        var raw = rng.below(4)
        out.append(UInt8(0x0D if raw == 0 else (0x0A if raw == 1 else (0x00 if raw == 2 else 0x09))))


def _bytes(mut rng: Rng, allow_raw: Bool) -> List[Byte]:
    var out = List[Byte]()
    for _ in range(rng.below(7)):
        _piece(rng, allow_raw, out)
    return out^


def _transcode(b: List[Byte]) -> List[Byte]:
    """What the rules say the wire gets: `C2`/`C3` plus a continuation byte
    is one latin-1 byte, every other byte is itself. Written out here, in
    its own words, rather than asked of `encode_latin1_header_value`."""
    var out = List[Byte]()
    var i = 0
    var n = len(b)
    while i < n:
        if (b[i] == 0xC2 or b[i] == 0xC3) and i + 1 < n and b[i + 1] >= 0x80 and b[i + 1] <= 0xBF:
            out.append(((b[i] & 0x03) << 6) | (b[i + 1] & 0x3F))
            i += 2
        else:
            out.append(b[i])
            i += 1
    return out^


def _on_wire(b: List[Byte], latin1: Bool) -> List[Byte]:
    """`b` as the writer puts it on the wire: transcoded by the encoders,
    as it stands in the printed form."""
    return _transcode(b) if latin1 else b.copy()


def _controls_encoded(b: List[Byte]) -> List[Byte]:
    """`reply.redirect`'s rule: each C0 control and DEL as `%XX`."""
    comptime HEX = "0123456789ABCDEF"
    var out = List[Byte]()
    for i in range(len(b)):
        var v = Int(b[i])
        if v < 0x20 or v == 0x7F:
            out.append(0x25)
            out.append(UInt8(HEX.as_bytes()[v >> 4]))
            out.append(UInt8(HEX.as_bytes()[v & 15]))
        else:
            out.append(b[i])
    return out^


def _line(name: String, value: List[Byte]) -> List[Byte]:
    var l = List[Byte](name.as_bytes())
    l.append(0x3A)
    l.append(0x20)
    l.extend(Span(value))
    return l^


def _find(hay: Span[Byte, _], needle: Span[Byte, _]) -> Int:
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


def _starts_with(l: List[Byte], prefix: String) -> Bool:
    var p = prefix.as_bytes()
    if len(l) < len(p):
        return False
    for i in range(len(p)):
        if l[i] != p[i]:
            return False
    return True


@fieldwise_init
struct Case(Copyable):
    """One iteration's inputs: every place a request's bytes can reach a
    head."""

    var name_tail: List[Byte]
    var value: List[Byte]
    var reason: List[Byte]
    var server: List[Byte]
    var app_names_server: Bool
    var cookie_raw: List[Byte]
    var cookie_value: List[Byte]
    var target: List[Byte]


def _case(mut rng: Rng, it: Int) -> Case:
    # One case in four may hold a raw CR, LF or NUL; the rest hold none, so
    # most headers are KEPT and the transcoder is what is under test.
    var allow_raw = rng.below(4) == 0
    return Case(
        name_tail=_bytes(rng, allow_raw),
        value=_bytes(rng, allow_raw),
        reason=_bytes(rng, allow_raw),
        server=_bytes(rng, allow_raw),
        app_names_server=(it % 2 == 0),
        cookie_raw=_bytes(rng, allow_raw),
        cookie_value=_bytes(rng, allow_raw),
        target=_bytes(rng, allow_raw),
    )


def _header_name(c: Case) -> List[Byte]:
    """The name as `Headers` stores it: ASCII lowercased, every other byte
    as given."""
    var n = List[Byte](String("x-n").as_bytes())
    for i in range(len(c.name_tail)):
        var b = c.name_tail[i]
        n.append(b + 0x20 if b >= 0x41 and b <= 0x5A else b)
    return n^


def _cookie_of(c: Case) -> Cookie:
    return Cookie("f", _str(c.cookie_value))


def _cookie_line_value(c: Case) -> List[Byte]:
    return List[Byte](_cookie_of(c).build_header_value().as_bytes())


def _head_response(c: Case) -> HTTPResponse:
    var headers = Headers()
    headers.set_bytes(String("x-before").as_bytes(), String("fine").as_bytes())
    headers.set_bytes(Span(_header_name(c)), Span(c.value))
    headers.set_bytes(String("x-after").as_bytes(), String("fine too").as_bytes())
    if c.app_names_server:
        headers.set_bytes(String("server").as_bytes(), Span(c.server))
    var jar = ResponseCookieJar()
    jar.add_raw(String("a=1; Path=/"))
    jar.add_raw(_str(c.cookie_raw))
    jar.set_cookie(_cookie_of(c))
    var resp = HTTPResponse(
        body_bytes=String(BODY).as_bytes(),
        headers=headers^,
        status_code=200,
        status_text=_str(c.reason),
    )
    resp.cookies = jar^
    return resp^


def _redirect_response(c: Case) -> HTTPResponse:
    return redirect(303, _str(c.target))


def _written(var resp: HTTPResponse, writer: Int) -> List[Byte]:
    if writer == 0:
        return resp^.encode()
    if writer == 1:
        return resp^.encode_into(Bytes(capacity=256))
    return List[Byte](String(resp).as_bytes())


def _writer_name(writer: Int) -> String:
    return "encode" if writer == 0 else ("encode_into" if writer == 1 else "printed form")


def _refuse(seed: Int, it: Int, writer: Int, what: String, c: Case) raises:
    raise Error(
        String(
            what, "\n  seed      : ", seed, " (replay: ", SEED_ENV, "=", seed, ")",
            "\n  iteration : ", it,
            "\n  writer    : ", _writer_name(writer),
            "\n  name tail : ", _hex(c.name_tail),
            "\n  value     : ", _hex(c.value),
            "\n  reason    : ", _hex(c.reason),
            "\n  server    : ", _hex(c.server), " (set: ", c.app_names_server, ")",
            "\n  raw cookie: ", _hex(c.cookie_raw),
            "\n  cookie val: ", _hex(c.cookie_value),
            "\n  target    : ", _hex(c.target),
        )
    )


def _head_lines(wire: List[Byte], body_given: String, seed: Int, it: Int, writer: Int, c: Case) raises -> List[List[Byte]]:
    """The head's lines, status line first, after checking the body is the
    one handed in and no line holds CR, LF or NUL."""
    var end = _find(Span(wire), String("\r\n\r\n").as_bytes())
    if end < 0:
        _refuse(seed, it, writer, "the head has no end", c)
    var body = List[Byte](Span(wire)[end + 4 :])
    if not _eq(body, List[Byte](body_given.as_bytes())):
        _refuse(seed, it, writer, "the body after the head is not the body given: " + _hex(body), c)
    var lines = List[List[Byte]]()
    var cur = List[Byte]()
    var i = 0
    while i < end:
        var b = wire[i]
        if b == 0x0D and wire[i + 1] == 0x0A:
            lines.append(cur^)
            cur = List[Byte]()
            i += 2
            continue
        if _is_break(b):
            _refuse(seed, it, writer, "CR, LF or NUL inside a head line: " + _hex(List[Byte](Span(wire)[:end])), c)
        cur.append(b)
        i += 1
    lines.append(cur^)
    return lines^


@fieldwise_init
struct Tally(Copyable):
    """What the run exercised, so that passing cannot mean checking nothing."""

    var kept_value: Int
    var dropped_value: Int
    var transcoded: Int
    var overlong_kept: Int
    var kept_cookie: Int
    var built_dropped: Int
    """Built cookies LF55 dropped that G2 would have kept: a `;` or a
    control byte other than CR, LF and NUL."""
    var emptied_reason: Int
    var redirects: Int


def _has_lead(b: List[Byte]) -> Bool:
    for i in range(len(b)):
        if b[i] >= 0xC0:
            return True
    return False


def _expect(
    mut expected: List[List[Byte]], name: String, value: List[Byte], latin1: Bool
) -> Bool:
    """Add `name: value` to the lines expected, unless the rules drop it.
    True when it was kept."""
    if _breaks(value) or _breaks(List[Byte](name.as_bytes())):
        return False
    expected.append(_line(name, _on_wire(value, latin1)))
    return True


def _check(
    lines: List[List[Byte]], var expected: List[List[Byte]], status: List[Byte],
    server_default: Bool, body_length: Int, seed: Int, it: Int, writer: Int, c: Case,
) raises:
    """`lines` is `status`, then `expected` in any order, then each of the
    defaults the encoders add at most once: `date`, `content-length`,
    `content-type`, `connection` and, when the application named no server, `server`."""
    if not _eq(lines[0], status):
        _refuse(seed, it, writer, "the status line is " + _hex(lines[0]) + ", not " + _hex(status), c)
    var defaults: List[String] = ["date: ", "content-length: ", "content-type: ", "connection: "]
    var server_seen = False
    for k in range(1, len(lines)):
        var found = -1
        for j in range(len(expected)):
            if _eq(lines[k], expected[j]):
                found = j
                break
        if found >= 0:
            _ = expected.pop(found)
            continue
        var is_default = False
        for d in range(len(defaults)):
            if _starts_with(lines[k], defaults[d]):
                if defaults[d] == "content-length: " and not _eq(
                    lines[k], _line("content-length", List[Byte](String(body_length).as_bytes()))
                ):
                    _refuse(seed, it, writer, "content-length is not the body's length " + String(body_length) + ": " + _hex(lines[k]), c)
                _ = defaults.pop(d)
                is_default = True
                break
        if is_default:
            continue
        if server_default and not server_seen and _eq(lines[k], List[Byte](String("server: lightbug_http").as_bytes())):
            server_seen = True
            continue
        _refuse(seed, it, writer, "a line the rules do not give: " + _hex(lines[k]), c)
    if len(expected) > 0:
        _refuse(seed, it, writer, "a line the rules keep was lost or altered: " + _hex(expected[0]), c)
    if server_default and not server_seen:
        _refuse(seed, it, writer, "the default server line is missing", c)


def _run(seed: Int, iterations: Int) raises -> Tally:
    var rng = Rng(UInt64(seed))
    var t = Tally(0, 0, 0, 0, 0, 0, 0, 0)
    for it in range(iterations):
        var c = _case(rng, it)
        for writer in range(WRITERS):
            var latin1 = writer != 2
            # The head: a header value, a header name, a reason phrase, a
            # Server value and three Set-Cookie lines.
            var expected = List[List[Byte]]()
            _ = _expect(expected, "x-before", List[Byte](String("fine").as_bytes()), latin1)
            _ = _expect(expected, "x-after", List[Byte](String("fine too").as_bytes()), latin1)
            var name = _header_name(c)
            var kept = not _breaks(name) and not _breaks(c.value)
            if kept:
                var l = List[Byte](Span(name))
                l.append(0x3A)
                l.append(0x20)
                l.extend(Span(_on_wire(c.value, latin1)))
                expected.append(l^)
            if c.app_names_server:
                _ = _expect(expected, "server", c.server, latin1)
            _ = _expect(expected, "set-cookie", List[Byte](String("a=1; Path=/").as_bytes()), latin1)
            var raw_kept = _expect(expected, "set-cookie", c.cookie_raw, latin1)
            # A built cookie is dropped for a `;` or a control byte in its
            # value (LF55) before G2's line-break rule is asked.
            var built_lf55 = _adds_an_attribute(c.cookie_value)
            var built_kept = not built_lf55 and _expect(
                expected, "set-cookie", _cookie_line_value(c), latin1
            )
            var reason_ok = not _breaks(c.reason)
            var status = List[Byte](String("HTTP/1.1 200 ").as_bytes())
            if reason_ok:
                status.extend(Span(c.reason))
            var wire = _written(_head_response(c), writer)
            var lines = _head_lines(wire, String(BODY), seed, it, writer, c)
            _check(lines, expected^, status, not c.app_names_server, String(BODY).byte_length(), seed, it, writer, c)
            if writer == 1:
                if kept:
                    t.kept_value += 1
                    if latin1 and not _eq(_transcode(c.value), c.value):
                        t.transcoded += 1
                    if _has_lead(c.value):
                        t.overlong_kept += 1
                else:
                    t.dropped_value += 1
                if raw_kept and built_kept:
                    t.kept_cookie += 1
                if built_lf55 and not _breaks(c.cookie_value):
                    t.built_dropped += 1
                if not reason_ok:
                    t.emptied_reason += 1

            # The redirect: a target is request data, so a control byte in
            # it is percent-encoded and the Location is always sent.
            var rexpected = List[List[Byte]]()
            rexpected.append(_line("location", _on_wire(_controls_encoded(c.target), latin1)))
            var rwire = _written(_redirect_response(c), writer)
            var rlines = _head_lines(rwire, String(""), seed, it, writer, c)
            _check(rlines, rexpected^, List[Byte](String("HTTP/1.1 303 See Other").as_bytes()), True, 0, seed, it, writer, c)
            if writer == 1:
                t.redirects += 1
    return t^


def _seed() raises -> Int:
    var s = getenv(SEED_ENV, "")
    if s.byte_length() == 0:
        return DEFAULT_SEED
    return Int(s)


def test_random_bytes_never_put_a_line_break_in_a_head() raises:
    """The property: for seeded random bytes, from every header-bearing
    place a request's bytes reach, every head writer writes exactly the
    lines the rules give and none holds CR, LF or NUL.

    covers: G24
    """
    var seed = _seed()
    print("header-bytes seed", seed, "iterations", ITERATIONS)
    var t = _run(seed, ITERATIONS)
    print(
        "header-bytes kept", t.kept_value, "dropped", t.dropped_value,
        "transcoded", t.transcoded, "with-a-lead", t.overlong_kept,
        "cookies kept", t.kept_cookie, "built cookies dropped", t.built_dropped,
        "reasons emptied", t.emptied_reason,
        "redirects", t.redirects,
    )
    # A run that dropped everything, or kept only ASCII, proved nothing.
    assert_true(t.kept_value * 2 > ITERATIONS, "most headers must be KEPT")
    assert_true(t.dropped_value * 20 > ITERATIONS, "some headers must hold a raw break")
    assert_true(t.transcoded * 10 > ITERATIONS, "the transcoder must have work to do")
    assert_true(t.overlong_kept * 4 > ITERATIONS, "lead bytes must reach the transcoder")
    assert_true(t.kept_cookie * 4 > ITERATIONS, "cookies must be KEPT")
    assert_true(
        t.built_dropped * 50 > ITERATIONS,
        "some built cookies must hold a `;` or a control byte G2 lets through",
    )
    assert_true(t.emptied_reason * 20 > ITERATIONS, "some reason phrases must be emptied")


def test_the_clean_value_is_still_transcoded_and_the_model_agrees() raises:
    """The control: `C3 A9` goes out as `E9`, and the property's model of
    the transcoder agrees with the transcoder on every generated value."""
    var wire = _written(
        HTTPResponse(
            body_bytes=String(BODY).as_bytes(),
            headers=Headers(Header("x-latin", "café")),
            status_code=200,
            status_text="OK",
        ),
        0,
    )
    var want = List[Byte](String("x-latin: caf").as_bytes())
    want.append(0xE9)
    want.append(0x0D)
    want.append(0x0A)
    assert_true(_find(Span(wire), Span(want)) >= 0, "a clean value was not transcoded")
    var rng = Rng(UInt64(7))
    for _ in range(2000):
        var b = _bytes(rng, False)
        var got = encode_latin1_header_value(_str(b))
        assert_true(_eq(got, _transcode(b)), "the model and the transcoder differ on " + _hex(b))
        assert_true(not _breaks(got), "the transcoder made a break of " + _hex(b))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
