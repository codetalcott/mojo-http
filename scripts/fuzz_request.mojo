"""Fuzz the request decoder: mutate a seed corpus, assert its invariants.

SPEC G13, B29, B30. The decoder is a pure function over bytes with its own
unit suite, which is what makes the harness small -- there is no socket, no
server and no event loop here, just `parse_request_headers`,
`frame_request_head` (the event loop's framing decision, SPEC B29) and
`HTTPChunkedDecoder.decode` over bytes somebody made up.

Deterministic on purpose. The PRNG is seeded from `--seed` (default 1), so a
CI failure names the seed and the iteration that produced it and the same run
reproduces it exactly; a fuzzer whose failures cannot be replayed reports a
crash nobody can fix. `--iterations` sizes the run.

What it checks, beyond "does not crash" -- which is the whole point of the
exercise but is also the only thing a fuzzer gets for free:

  * PARSING IS DETERMINISTIC. The same bytes twice must give the same answer.
  * INVALID IS STICKY. If a buffer is rejected as invalid, appending bytes to
    it must not make it valid. This is the smuggling-relevant one: "invalid,
    not incomplete" is the discipline test_parsing.mojo exists to defend, and
    its failure mode is an attacker's payload left in the buffer to be read as
    the start of the next request. A request refused as asking for what the
    server does not implement (answered 501, not 400) is held to the same
    rule.
  * SUCCESS IS STABLE UNDER APPEND. A request that parses must parse the same
    way with more bytes after it, consuming the same count -- the parser stops
    at the header terminator or it is reading somebody else's request.
  * THE PARSER ENDS A HEAD ON CRLF CRLF, the terminator the loop frames by.
    A parser that ended one on a bare-LF empty line (LF2) disagreed with the
    loop about where the head stops, and the bytes between were lost.
  * THE CHUNKED DECODER STAYS INSIDE ITS BUFFER. `ret` is a byte count, -1 or
    -2; decoded output never exceeds input; `pending_bytes` indexes the
    buffer. Those bounds feed `memcpy` sizes and buffer offsets in the loop.

And the invariants that span the parser and the loop, over the loop's own
framing decision (SPEC B29):

  * A FRAMED REQUEST'S HEAD ENDS WHERE THE PARSER STOPPED. The head end the
    decision frames by -- where the body starts and `request_end` is taken
    from -- is the count the parser consumes from those bytes, or the
    request is refused. Its framing adds up: the head ends in CRLF CRLF
    within the limit, and `request_end` is the head plus its length.
  * A HEAD SPLIT ACROSS READS IS FRAMED AS IT IS WHOLE. The bytes are fed in
    pieces the way the loop sees them -- each call told how far the last one
    scanned -- and the decision must be the one the whole buffer gets: the
    same head end, body and `request_end`, or a refusal. A head refused
    early for a bare LF may be refused whole by another rule.
  * A REFUSAL STAYS ONE, AND A FRAMED REQUEST IS UNCHANGED, whatever bytes
    arrive behind it.

And over a chunked body as the loop reads it (SPEC B30):

  * A COMPLETED CHUNKED BODY NEVER ENDS A LINE ON A BARE LF. Every framing
    line -- each chunk's size line, the CRLF after its data, each trailer
    line and the empty line that ends them -- ends in CRLF, and the decoded
    bytes are the chunks' data, read by a walker of this file's own.
  * ONE DECODER FED A READ AT A TIME DECODES AS IT DOES WHOLE: the same
    answer, the same body, and the bytes behind it kept for the next
    request -- the loop's layout, `[decoded][pending][new]`.

Every check is run before any mutation over the unmutated corpus, the head
fed a byte at a time, so the shapes the corpus holds for a defect are
tried every run whatever the mutations do.

Usage:
    mojo run -I packages/m0-http -I packages/m0-core scripts/fuzz_request.mojo
    ... --seed 7 --iterations 20000
"""

from std.sys import argv

from lightbug_http.framing import (
    BODY_CHUNKED,
    BODY_LENGTH,
    BODY_NONE,
    FRAME_INCOMPLETE,
    FRAME_REFUSED,
    FRAME_REQUEST,
    HeadFraming,
    REFUSED_BARE_LF,
    REFUSED_BODY_TOO_LARGE,
    REFUSED_FRAMERS_DISAGREE,
    REFUSED_HEAD_TOO_LARGE,
    REFUSED_MALFORMED,
    REFUSED_NOT_IMPLEMENTED,
    REFUSED_URI_TOO_LONG,
    frame_request_head,
)
from lightbug_http.header import (
    ParsedRequestHeaders,
    parse_request_headers,
    InvalidHTTPRequestError,
    IncompleteHTTPRequestError,
    UnsupportedHTTPRequestError,
)
from lightbug_http.http.chunked import HTTPChunkedDecoder
from lightbug_http.io.bytes import Bytes


# The limits the framing decision runs under here: small, so a mutated
# corpus reaches every refusal (431, 414, 413) and still frames requests.
comptime FUZZ_MAX_HEADER = 512
comptime FUZZ_MAX_URI = 64
comptime FUZZ_MAX_BODY = 1024


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
        if n <= 0:
            return 0
        return Int(self.next() % UInt64(n))


def _seed_corpus() -> List[String]:
    """Real requests, and the shapes the hardening exists for.

    Mutation finds far more starting from something nearly valid than from
    random bytes: a random buffer is rejected at the first byte and exercises
    one branch.
    """
    var c = List[String]()
    c.append("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    c.append("GET /a/b?q=1 HTTP/1.1\r\nHost: x\r\nAccept: */*\r\n\r\n")
    c.append(
        "POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n"
        "Content-Type: text/plain\r\n\r\nhello"
    )
    c.append(
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
        "5\r\nhello\r\n0\r\n\r\n"
    )
    c.append(
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
        "5\r\nhello\r\n0\r\nX-Trailer: v\r\n\r\n"
    )
    # Smuggling shapes: both framing headers, a bare LF, an absolute target.
    c.append(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n"
        "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
    )
    c.append("GET / HTTP/1.1\nHost: x\n\n")
    c.append("GET http://e.example/p HTTP/1.1\r\nHost: x\r\n\r\n")
    c.append("GET / HTTP/1.0\r\n\r\n")
    # Refused as not implemented (501), not as malformed.
    c.append("CONNECT h:443 HTTP/1.1\r\nHost: h:443\r\n\r\n")
    c.append(
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n"
        "5\r\nhello\r\n0\r\n\r\n"
    )
    # Long-ish header block: the 8 KB-class shapes that stalled reads.
    c.append(
        "GET / HTTP/1.1\r\nHost: x\r\nCookie: " + String("a") * 600 + "\r\n\r\n"
    )
    # Chunked framing on its own, for the decoder half.
    c.append("5\r\nhello\r\n0\r\n\r\n")
    c.append("1e\r\n" + String("z") * 30 + "\r\n0\r\nX: y\r\n\r\n")
    c.append("ffffffffffffffff\r\nx\r\n0\r\n\r\n")
    c.append("0\r\n\r\n")
    # LF2's two shapes (SPEC B12): a bare-LF empty line inside what the loop
    # frames as one head -- a request pipelined behind it, and a
    # `Content-Length` behind it.
    c.append(
        "GET / HTTP/1.1\r\nHost: x\r\n\nGET /x HTTP/1.1\r\nHost: x\r\n\r\n"
    )
    c.append(
        "POST / HTTP/1.1\r\nHost: x\r\n\nContent-Length: 5\r\n\r\nhello"
    )
    # Two requests pipelined, and the framing decision's own refusals under
    # this file's limits: a target past FUZZ_MAX_URI, a length past
    # FUZZ_MAX_BODY (the long cookie above is past FUZZ_MAX_HEADER).
    c.append("GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n")
    c.append("GET /" + String("p") * 80 + " HTTP/1.1\r\nHost: x\r\n\r\n")
    c.append("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4096\r\n\r\nabc")
    # Two empty lines before the request line: their CRLFCRLF opens the
    # buffer, which the terminator search missed when a read had ended
    # inside it -- refused whole, served split (found here, SPEC B29).
    c.append("\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n")
    return c^


def _mutate(mut rng: Rng, base: Span[Byte, _], other: Span[Byte, _]) -> Bytes:
    """One mutation of `base`, sometimes splicing in `other`."""
    var out = Bytes()
    var n = len(base)
    var op = rng.below(7)

    if op == 0 and n > 0:  # flip a bit
        for i in range(n):
            out.append(base[i])
        var at = rng.below(n)
        out[at] = out[at] ^ (UInt8(1) << UInt8(rng.below(8)))
    elif op == 1 and n > 0:  # replace a byte
        for i in range(n):
            out.append(base[i])
        out[rng.below(n)] = UInt8(rng.below(256))
    elif op == 2:  # insert a byte
        var at = rng.below(n + 1)
        for i in range(at):
            out.append(base[i])
        out.append(UInt8(rng.below(256)))
        for i in range(at, n):
            out.append(base[i])
    elif op == 3 and n > 0:  # delete a byte
        var at = rng.below(n)
        for i in range(n):
            if i != at:
                out.append(base[i])
    elif op == 4 and n > 0:  # truncate
        var keep = rng.below(n)
        for i in range(keep):
            out.append(base[i])
    elif op == 5 and n > 0 and len(other) > 0:  # splice
        var cut = rng.below(n)
        for i in range(cut):
            out.append(base[i])
        var from_ = rng.below(len(other))
        for i in range(from_, len(other)):
            out.append(other[i])
    else:  # duplicate a span — the repetition shapes (many headers, chunks)
        for i in range(n):
            out.append(base[i])
        if n > 0:
            var start = rng.below(n)
            var span = rng.below(n - start) + 1
            for _ in range(rng.below(3) + 1):
                for i in range(start, start + span):
                    out.append(base[i])
    return out^


struct ParseOutcome(Copyable, ImplicitlyCopyable, Movable):
    """What the parser said: 0 ok, 1 invalid, 2 incomplete, 3 other,
    4 not implemented."""

    var kind: Int
    var consumed: Int
    var method: String
    var path: String

    def __init__(out self, kind: Int, consumed: Int, method: String, path: String):
        self.kind = kind
        self.consumed = consumed
        self.method = method
        self.path = path


def _parse(buf: Span[Byte, _]) -> ParseOutcome:
    try:
        var parsed = parse_request_headers(buf)
        var out = ParseOutcome(0, parsed.bytes_consumed, parsed.method, parsed.path)
        _ = parsed^
        return out^
    except e:
        if e.isa[InvalidHTTPRequestError]():
            return ParseOutcome(1, 0, String(""), String(""))
        if e.isa[IncompleteHTTPRequestError]():
            return ParseOutcome(2, 0, String(""), String(""))
        if e.isa[UnsupportedHTTPRequestError]():
            return ParseOutcome(4, 0, String(""), String(""))
        return ParseOutcome(3, 0, String(""), String(""))


def _hex(buf: Span[Byte, _], limit: Int) -> String:
    var digits = String("0123456789abcdef")
    var out = String("")
    var n = len(buf) if len(buf) < limit else limit
    for i in range(n):
        var b = Int(buf[i])
        out += String(StringSpan(digits)[byte = b >> 4])
        out += String(StringSpan(digits)[byte = b & 15])
    if len(buf) > limit:
        out += "..."
    return out^


def _report(seed: Int, it: Int, rule: String, buf: Span[Byte, _]) -> None:
    print("fuzz-request: FAIL")
    print("  seed      :", seed)
    if it < 0:
        print("  iteration : none -- the unmutated corpus, entry", -1 - it)
    else:
        print("  iteration :", it)
    print("  invariant :", rule)
    print("  length    :", len(buf))
    print("  bytes     :", _hex(buf, 400))
    print("  replay    : mojo run -I packages/m0-http -I packages/m0-core \\")
    print(
        "              scripts/fuzz_request.mojo --seed", seed,
        "--iterations", it + 1 if it >= 0 else 1,
    )


# --- the framing decision (SPEC B29) ---------------------------------------


struct FramingTally(Movable):
    """What the framing checks reached, for the coverage floor."""

    var request: Int
    var length_body: Int
    var chunked_body: Int
    var bare_lf: Int
    var too_large: Int
    var malformed: Int
    var not_implemented: Int
    var disagree: Int
    var uri_too_long: Int
    var body_too_large: Int
    var split_early: Int
    var split_whole: Int

    def __init__(out self):
        self.request = 0
        self.length_body = 0
        self.chunked_body = 0
        self.bare_lf = 0
        self.too_large = 0
        self.malformed = 0
        self.not_implemented = 0
        self.disagree = 0
        self.uri_too_long = 0
        self.body_too_large = 0
        self.split_early = 0
        self.split_whole = 0

    def count(mut self, d: HeadFraming):
        if d.outcome == FRAME_REQUEST:
            self.request += 1
            if d.body == BODY_LENGTH:
                self.length_body += 1
            elif d.body == BODY_CHUNKED:
                self.chunked_body += 1
        elif d.outcome == FRAME_REFUSED:
            if d.rule == REFUSED_BARE_LF:
                self.bare_lf += 1
            elif d.rule == REFUSED_HEAD_TOO_LARGE:
                self.too_large += 1
            elif d.rule == REFUSED_MALFORMED:
                self.malformed += 1
            elif d.rule == REFUSED_NOT_IMPLEMENTED:
                self.not_implemented += 1
            elif d.rule == REFUSED_FRAMERS_DISAGREE:
                self.disagree += 1
            elif d.rule == REFUSED_URI_TOO_LONG:
                self.uri_too_long += 1
            elif d.rule == REFUSED_BODY_TOO_LARGE:
                self.body_too_large += 1


def _frame(buf: Span[Byte, _], scanned: Int, mut head: Optional[ParsedRequestHeaders]) -> HeadFraming:
    return frame_request_head(
        buf, scanned, FUZZ_MAX_HEADER, FUZZ_MAX_URI, FUZZ_MAX_BODY, head
    )


def _same_request(a: HeadFraming, b: HeadFraming) -> Bool:
    return (
        a.outcome == b.outcome
        and a.head_end == b.head_end
        and a.body == b.body
        and a.content_length == b.content_length
        and a.request_end == b.request_end
    )


def _framing_adds_up(buf: Span[Byte, _], d: HeadFraming, has_head: Bool) -> Bool:
    """A framed request's numbers, against the bytes and the limits."""
    if not has_head:
        return False
    var h = d.head_end
    if h < 4 or h > len(buf) or h > FUZZ_MAX_HEADER:
        return False
    if buf[h - 4] != 13 or buf[h - 3] != 10 or buf[h - 2] != 13 or buf[h - 1] != 10:
        return False
    if d.body == BODY_CHUNKED:
        return d.content_length == 0 and d.request_end == 0
    if d.body == BODY_LENGTH:
        if d.content_length <= 0 or d.content_length > FUZZ_MAX_BODY:
            return False
    elif d.body == BODY_NONE:
        if d.content_length != 0:
            return False
    else:
        return False
    return d.request_end == h + d.content_length


def _check_framing(
    buf: Span[Byte, _], mut frng: Rng, bytewise: Bool, mut tally: FramingTally,
) -> String:
    """Every framing invariant over one buffer: "" when all hold, else the
    one that broke."""
    var head = Optional[ParsedRequestHeaders](None)
    var whole = _frame(buf, 0, head)
    tally.count(whole)

    if whole.outcome == FRAME_REQUEST:
        # The head end is where the parser stops over those same bytes.
        var parsed = _parse(buf[: whole.head_end])
        if parsed.kind != 0 or parsed.consumed != whole.head_end:
            return String("a framed request's head end is not where the parser stopped")
        if not _framing_adds_up(buf, whole, Bool(head)):
            return String("a framed request's framing does not add up")
        if head.value().method != parsed.method or head.value().path != parsed.path:
            return String("a framed request's head end is not where the parser stopped")
    elif Bool(head):
        return String("a framed request's framing does not add up")

    # Split: the loop's reads, each call told how far the last one scanned.
    var n = len(buf)
    var cuts = List[Int]()
    if bytewise:
        for p in range(1, n):
            cuts.append(p)
    elif n > 1:
        var marks = List[Bool](length=n, fill=False)
        for _ in range(frng.below(3) + 1):
            marks[frng.below(n - 1) + 1] = True
        for p in range(1, n):
            if marks[p]:
                cuts.append(p)
    cuts.append(n)
    var scanned = 0
    var split = HeadFraming(FRAME_INCOMPLETE, 0, 0)
    var split_head = Optional[ParsedRequestHeaders](None)
    var decided_at = n
    for k in range(len(cuts)):
        var p = cuts[k]
        split = _frame(buf[:p], scanned, split_head)
        if split.outcome != FRAME_INCOMPLETE:
            decided_at = p
            break
        scanned = p
    if decided_at < n:
        tally.split_early += 1
    else:
        tally.split_whole += 1
    var split_agrees: Bool
    if split.outcome == FRAME_REQUEST:
        split_agrees = _same_request(split, whole)
    elif split.outcome == FRAME_REFUSED:
        split_agrees = whole.outcome == FRAME_REFUSED and (
            split.status == whole.status or split.rule == REFUSED_BARE_LF
        )
    else:
        split_agrees = whole.outcome == FRAME_INCOMPLETE
    if not split_agrees:
        return String(
            "a head split across reads was framed differently from the same"
            " bytes whole"
        )

    # Append: what arrives behind a decision does not change it.
    if whole.outcome != FRAME_INCOMPLETE:
        var extended = Bytes(buf)
        for _ in range(frng.below(12) + 1):
            extended.append(UInt8(frng.below(256)))
        var later_head = Optional[ParsedRequestHeaders](None)
        var later = _frame(Span(extended), 0, later_head)
        if whole.outcome == FRAME_REFUSED and later.outcome != FRAME_REFUSED:
            return String("a refused head was framed when bytes were appended")
        if whole.outcome == FRAME_REQUEST and not _same_request(later, whole):
            return String("a framed request changed when bytes were appended")
    return String("")


# --- a chunked body as the loop reads it (SPEC B30) -------------------------


def _chunk_bounds(ret: Int, decoded: Int, pending: Int, n: Int) -> String:
    """The decoder's counts must index the buffer it was given."""
    if ret < -2 or ret > n:
        return String("chunked ret is outside [-2, len]")
    if decoded < 0 or decoded > n:
        return String("chunked decoded length is outside the buffer")
    if pending < 0 or pending > n:
        return String("chunked pending_bytes is outside the buffer")
    return String("")


comptime WALK_OK = 0
comptime WALK_BARE_LF = 1
comptime WALK_ELSEWHERE = 2
comptime WALK_DATA = 3


def _walk_chunked(
    raw: Span[Byte, _], consumed: Int, trailer: Bool, decoded: Span[Byte, _],
) -> Int:
    """Read a body the decoder called complete, line by line, as RFC 9112
    §7.1 frames it: WALK_BARE_LF when a framing line does not end in CRLF,
    WALK_ELSEWHERE when the body does not end where the decoder said,
    WALK_DATA when the decoded bytes are not the chunks' data."""
    var n = consumed
    if n < 0 or n > len(raw):
        return WALK_ELSEWHERE
    var at = 0
    var out = 0
    while True:
        # The size line: hex digits, then anything to its CRLF.
        var size = 0
        var digits = 0
        while at < n:
            var c = raw[at]
            var v = -1
            if c >= 48 and c <= 57:
                v = Int(c) - 48
            elif c >= 65 and c <= 70:
                v = Int(c) - 55
            elif c >= 97 and c <= 102:
                v = Int(c) - 87
            if v < 0:
                break
            if size > len(raw):
                return WALK_ELSEWHERE
            size = size * 16 + v
            digits += 1
            at += 1
        if digits == 0:
            return WALK_ELSEWHERE
        while at < n and raw[at] != 13:
            if raw[at] == 10:
                return WALK_BARE_LF
            at += 1
        if at + 1 >= n or raw[at + 1] != 10:
            return WALK_BARE_LF if at < n else WALK_ELSEWHERE
        at += 2
        if size == 0:
            break
        if size > n - at:
            return WALK_ELSEWHERE
        for k in range(size):
            if out >= len(decoded) or decoded[out] != raw[at + k]:
                return WALK_DATA
            out += 1
        at += size
        if at + 1 >= n:
            return WALK_ELSEWHERE
        if raw[at] != 13 or raw[at + 1] != 10:
            return WALK_BARE_LF
        at += 2
    if trailer:
        # Trailer lines to the empty one, each ending in CRLF.
        while True:
            if at >= n:
                return WALK_ELSEWHERE
            var empty = raw[at] == 13
            while at < n and raw[at] != 13:
                if raw[at] == 10:
                    return WALK_BARE_LF
                at += 1
            if at + 1 >= n or raw[at + 1] != 10:
                return WALK_BARE_LF if at < n else WALK_ELSEWHERE
            at += 2
            if empty:
                break
    if at != n:
        return WALK_ELSEWHERE
    if out != len(decoded):
        return WALK_DATA
    return WALK_OK


struct ChunkTally(Movable):
    """What the chunked checks reached, for the coverage floor."""

    var whole_complete: Int
    var split_complete: Int
    var split_refused: Int
    var body_complete: Int

    def __init__(out self):
        self.whole_complete = 0
        self.split_complete = 0
        self.split_refused = 0
        self.body_complete = 0


def _check_chunked(
    raw: Span[Byte, _], trailer: Bool, mut frng: Rng, mut tally: ChunkTally,
) -> String:
    """Every chunked-body invariant over one buffer: "" when all hold."""
    var n = len(raw)
    # Whole, as one read.
    var whole_buf = Bytes(raw)
    var dec = HTTPChunkedDecoder()
    dec.consume_trailer = trailer
    var res = dec.decode(Span(whole_buf))
    var ret = res[0]
    var decoded = res[1]
    var bounds = _chunk_bounds(ret, decoded, dec.pending_bytes, n)
    if bounds != "":
        return bounds
    if ret >= 0:
        tally.whole_complete += 1
        var walked = _walk_chunked(
            raw, n - ret, trailer, Span(whole_buf)[:decoded]
        )
        if walked == WALK_BARE_LF:
            return String(
                "a completed chunked body has a framing line that does not"
                " end in CRLF"
            )
        if walked != WALK_OK:
            return String(
                "a completed chunked body is not the chunks its framing holds"
            )

    # In pieces, through ONE decoder fed only the new bytes, laid out as
    # the loop lays its buffer out: [decoded][pending][new].
    var marks = List[Bool](length=n + 1, fill=False)
    if n > 1:
        if frng.below(4) == 0:
            for p in range(1, n):
                marks[p] = True
        else:
            for _ in range(frng.below(4) + 1):
                marks[frng.below(n - 1) + 1] = True
    marks[n] = True
    var pieces = HTTPChunkedDecoder()
    pieces.consume_trailer = trailer
    var buf = Bytes()
    var done = 0
    var fed = 0
    var split_ret = -2
    for p in range(1, n + 1):
        if not marks[p]:
            continue
        for k in range(fed, p):
            buf.append(raw[k])
        fed = p
        if len(buf) <= done:
            continue
        var given = len(buf) - done
        var r = pieces.decode(Span(buf)[done:])
        var b = _chunk_bounds(r[0], r[1], pieces.pending_bytes, given)
        if b != "":
            return b
        if r[0] == -1:
            split_ret = -1
            break
        buf.resize(done + r[1] + pieces.pending_bytes, 0)
        done += r[1]
        if r[0] >= 0:
            split_ret = r[0]
            break

    var agrees: Bool
    if ret == -1:
        agrees = split_ret == -1
    elif ret == -2:
        agrees = split_ret == -2
    else:
        # Complete both ways, at the same byte, with the same body, and the
        # bytes behind it kept whole for the next request.
        agrees = split_ret >= 0 and fed - split_ret == n - ret and done == decoded
        if agrees:
            for k in range(done):
                if buf[k] != whole_buf[k]:
                    agrees = False
                    break
        if agrees:
            var tail = Bytes(Span(buf)[done:])
            for k in range(fed, n):
                tail.append(raw[k])
            if len(tail) != ret:
                agrees = False
            else:
                for k in range(ret):
                    if tail[k] != raw[n - ret + k]:
                        agrees = False
                        break
    if split_ret >= 0:
        tally.split_complete += 1
    elif split_ret == -1:
        tally.split_refused += 1
    if not agrees:
        return String(
            "a chunked body fed in pieces decoded differently from the same"
            " bytes whole"
        )
    return String("")


def _chunked_pass_one(
    buf: Span[Byte, _], trailer: Bool, mut crng: Rng, mut tally: ChunkTally,
) -> String:
    """The chunked checks over `buf` as a body, and -- when it frames as a
    request with a chunked body -- over that body as the loop decodes it:
    from the head's end, its trailer section consumed."""
    var broke = _check_chunked(buf, trailer, crng, tally)
    if broke != "":
        return broke
    var head = Optional[ParsedRequestHeaders](None)
    var d = _frame(buf, 0, head)
    if d.outcome == FRAME_REQUEST and d.body == BODY_CHUNKED:
        var before = tally.whole_complete
        broke = _check_chunked(buf[d.head_end :], True, crng, tally)
        if tally.whole_complete > before:
            tally.body_complete += 1
    return broke


def main() raises:
    var seed = 1
    var iterations = 5000
    var args = argv()
    var i = 1
    while i < len(args):
        if args[i] == "--seed" and i + 1 < len(args):
            seed = Int(args[i + 1])
            i += 2
        elif args[i] == "--iterations" and i + 1 < len(args):
            iterations = Int(args[i + 1])
            i += 2
        else:
            i += 1

    var corpus = _seed_corpus()
    var rng = Rng(UInt64(seed))
    # The framing and chunked checks draw from streams of their own, so
    # adding to them never moves the mutations the parser's checks see.
    var frng = Rng(UInt64(seed) ^ 0xD1B54A32D192ED03)
    var crng = Rng(UInt64(seed) ^ 0x94D049BB133111EB)
    var failures = 0
    # Coverage, asserted at the end. A mutation engine that produced only
    # garbage would be rejected at the first byte every time, exercise one
    # branch, and report success -- the shape of a gate that is green
    # having tested nothing.
    var n_ok = 0
    var n_invalid = 0
    var n_incomplete = 0
    var n_unsupported = 0
    var n_chunk_ok = 0
    var n_chunk_err = 0
    var framing = FramingTally()
    var chunks = ChunkTally()

    # --- the unmutated corpus, a head fed a byte at a time ---------------
    for k in range(len(corpus)):
        var entry = corpus[k].as_bytes()
        var broke = _check_framing(entry, frng, True, framing)
        if broke != "":
            _report(seed, -1 - k, broke, entry)
            raise Error("fuzz-request: invariant violated")

    for it in range(iterations):
        var a = corpus[rng.below(len(corpus))]
        var b = corpus[rng.below(len(corpus))]
        var buf = _mutate(rng, a.as_bytes(), b.as_bytes())

        # --- the header parser -------------------------------------------
        var first = _parse(Span(buf))
        var again = _parse(Span(buf))
        if first.kind == 0:
            n_ok += 1
        elif first.kind == 1:
            n_invalid += 1
        elif first.kind == 2:
            n_incomplete += 1
        elif first.kind == 4:
            n_unsupported += 1
        if first.kind != again.kind or first.consumed != again.consumed:
            _report(seed, it, String("parsing is deterministic"), Span(buf))
            failures += 1
            break

        if first.kind == 0:
            if first.consumed < 0 or first.consumed > len(buf):
                _report(
                    seed, it,
                    String("bytes_consumed lies outside the buffer"), Span(buf),
                )
                failures += 1
                break

        # Append a suffix and re-parse: invalid must stay invalid, and a
        # success must be unchanged by bytes it should never have read.
        var extended = Bytes()
        for k in range(len(buf)):
            extended.append(buf[k])
        for _ in range(rng.below(12) + 1):
            extended.append(UInt8(rng.below(256)))
        var after = _parse(Span(extended))

        if first.kind == 1 and after.kind != 1:
            _report(
                seed, it,
                String("an INVALID request became valid when bytes were appended"),
                Span(extended),
            )
            failures += 1
            break
        if first.kind == 4 and after.kind != 4:
            _report(
                seed, it,
                String("a NOT IMPLEMENTED refusal changed when bytes were appended"),
                Span(extended),
            )
            failures += 1
            break

        if first.kind == 0:
            if after.kind != 0 or after.consumed != first.consumed:
                _report(
                    seed, it,
                    String("a parsed request changed when bytes were appended"),
                    Span(extended),
                )
                failures += 1
                break
            if after.method != first.method or after.path != first.path:
                _report(
                    seed, it,
                    String("method or path changed when bytes were appended"),
                    Span(extended),
                )
                failures += 1
                break
            # The loop frames a head by its first CRLF CRLF, so a head the
            # parser ends anywhere else is two framers disagreeing (LF2).
            var c = first.consumed
            if (
                c < 4 or buf[c - 4] != 13 or buf[c - 3] != 10
                or buf[c - 2] != 13 or buf[c - 1] != 10
            ):
                _report(
                    seed, it,
                    String("the parser ended a head on something other than CRLF CRLF"),
                    Span(buf),
                )
                failures += 1
                break

        # --- the framing decision ----------------------------------------
        var broke = _check_framing(Span(buf), frng, it % 8 == 0, framing)
        if broke != "":
            _report(seed, it, broke, Span(buf))
            failures += 1
            break

        # --- the chunked decoder -----------------------------------------
        # `decode` rewrites its buffer in place, so it gets its own copy.
        var chunk_buf = Bytes()
        for k in range(len(buf)):
            chunk_buf.append(buf[k])
        var dec = HTTPChunkedDecoder()
        dec.consume_trailer = (rng.below(2) == 1)
        var res = dec.decode(Span(chunk_buf))
        var ret = res[0]
        var decoded = res[1]
        if ret >= 0:
            n_chunk_ok += 1
        elif ret == -1:
            n_chunk_err += 1

        var bounds = _chunk_bounds(ret, decoded, dec.pending_bytes, len(chunk_buf))
        if bounds != "":
            _report(seed, it, bounds, Span(buf))
            failures += 1
            break

    if failures > 0:
        raise Error("fuzz-request: invariant violated")

    # --- a chunked body as the loop reads it -----------------------------
    # A pass of its own, after the decoder's bounds have had every
    # iteration above: a decoder that breaks a bound breaks these too, and
    # the bound is the finding to report first. The unmutated corpus first,
    # with and without a trailer section consumed.
    for k in range(len(corpus)):
        var entry = corpus[k].as_bytes()
        var broke = _chunked_pass_one(entry, True, crng, chunks)
        if broke == "":
            broke = _chunked_pass_one(entry, False, crng, chunks)
        if broke != "":
            _report(seed, -1 - k, broke + " (the chunked pass)", entry)
            raise Error("fuzz-request: invariant violated")
    for it in range(iterations):
        var a = corpus[crng.below(len(corpus))]
        var b = corpus[crng.below(len(corpus))]
        var buf = _mutate(crng, a.as_bytes(), b.as_bytes())
        var broke = _chunked_pass_one(Span(buf), crng.below(2) == 1, crng, chunks)
        if broke != "":
            _report(seed, it, broke + " (the chunked pass)", Span(buf))
            raise Error("fuzz-request: invariant violated")

    # Every bucket must have been reached, or the run proved nothing about the
    # branches it never entered.
    var thin = String("")
    if n_ok == 0:
        thin += " no-request-ever-parsed"
    if n_invalid == 0:
        thin += " nothing-ever-rejected-as-invalid"
    if n_incomplete == 0:
        thin += " nothing-ever-reported-incomplete"
    if n_unsupported == 0:
        thin += " nothing-ever-refused-as-not-implemented"
    if n_chunk_ok == 0:
        thin += " no-chunked-body-ever-decoded"
    if n_chunk_err == 0:
        thin += " no-chunked-body-ever-rejected"
    if framing.request == 0:
        thin += " no-head-ever-framed"
    if framing.length_body == 0:
        thin += " no-content-length-body-ever-framed"
    if framing.chunked_body == 0:
        thin += " no-chunked-body-ever-framed"
    if framing.bare_lf == 0:
        thin += " no-head-refused-for-a-bare-lf-while-incomplete"
    if framing.too_large == 0:
        thin += " no-head-refused-as-too-large"
    if framing.malformed == 0:
        thin += " no-framed-head-refused-as-malformed"
    if framing.not_implemented == 0:
        thin += " no-framed-head-refused-as-not-implemented"
    if framing.uri_too_long == 0:
        thin += " no-target-refused-as-too-long"
    if framing.body_too_large == 0:
        thin += " no-length-refused-as-too-large"
    if framing.split_early == 0:
        thin += " no-split-head-decided-before-its-last-read"
    if chunks.split_complete == 0:
        thin += " no-chunked-body-ever-completed-in-pieces"
    if chunks.split_refused == 0:
        thin += " no-chunked-body-ever-refused-in-pieces"
    if chunks.body_complete == 0:
        thin += " no-framed-request's-chunked-body-ever-completed"
    if thin != "":
        print("fuzz-request: the run never reached:" + thin)
        print(
            "  Mutation is not producing inputs that exercise these branches,",
            "so the iterations above prove nothing about them.",
        )
        raise Error("fuzz-request: coverage too thin to mean anything")

    print(
        "  outcomes: ok", n_ok, "invalid", n_invalid, "incomplete", n_incomplete,
        "not implemented", n_unsupported,
        "| chunked: decoded", n_chunk_ok, "rejected", n_chunk_err,
    )
    print(
        "  framing: requests", framing.request, "(length", framing.length_body,
        "chunked", String(framing.chunked_body) + ")",
        "| refused: bare LF", framing.bare_lf, "431", framing.too_large,
        "400", framing.malformed, "501", framing.not_implemented,
        "414", framing.uri_too_long, "413", framing.body_too_large,
        "framers disagreed", framing.disagree,
        "| split: decided early", framing.split_early,
        "at the last read", framing.split_whole,
    )
    print(
        "  chunked as the loop reads it: complete", chunks.whole_complete,
        "| in pieces: complete", chunks.split_complete,
        "refused", chunks.split_refused,
        "| framed bodies complete", chunks.body_complete,
    )
    print(
        "fuzz-request OK:", iterations, "iterations, seed", seed,
        "-- no crash, no invariant violated",
    )
