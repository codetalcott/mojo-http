"""Fuzz the request decoder: mutate a seed corpus, assert its invariants.

SPEC G13. The decoder is a pure function over bytes with its own unit suite,
which is what makes the harness small -- there is no socket, no server and no
event loop here, just `parse_request_headers` and `HTTPChunkedDecoder.decode`
over bytes somebody made up.

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
    the start of the next request.
  * SUCCESS IS STABLE UNDER APPEND. A request that parses must parse the same
    way with more bytes after it, consuming the same count -- the parser stops
    at the header terminator or it is reading somebody else's request.
  * THE CHUNKED DECODER STAYS INSIDE ITS BUFFER. `ret` is a byte count, -1 or
    -2; decoded output never exceeds input; `pending_bytes` indexes the
    buffer. Those bounds feed `memcpy` sizes and buffer offsets in the loop.

Usage:
    mojo run -I packages/m0-http -I packages/m0-core scripts/fuzz_request.mojo
    ... --seed 7 --iterations 20000
"""

from std.sys import argv

from lightbug_http.header import (
    parse_request_headers,
    InvalidHTTPRequestError,
    IncompleteHTTPRequestError,
)
from lightbug_http.http.chunked import HTTPChunkedDecoder
from lightbug_http.io.bytes import Bytes


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
    # Long-ish header block: the 8 KB-class shapes that stalled reads.
    c.append(
        "GET / HTTP/1.1\r\nHost: x\r\nCookie: " + String("a") * 600 + "\r\n\r\n"
    )
    # Chunked framing on its own, for the decoder half.
    c.append("5\r\nhello\r\n0\r\n\r\n")
    c.append("1e\r\n" + String("z") * 30 + "\r\n0\r\nX: y\r\n\r\n")
    c.append("ffffffffffffffff\r\nx\r\n0\r\n\r\n")
    c.append("0\r\n\r\n")
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
    """What the parser said: 0 ok, 1 invalid, 2 incomplete, 3 other."""

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
    print("  iteration :", it)
    print("  invariant :", rule)
    print("  length    :", len(buf))
    print("  bytes     :", _hex(buf, 400))
    print("  replay    : mojo run -I packages/m0-http -I packages/m0-core \\")
    print("              scripts/fuzz_request.mojo --seed", seed, "--iterations", it + 1)


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
    var failures = 0
    # Coverage, asserted at the end. A mutation engine that produced only
    # garbage would be rejected at the first byte every time, exercise one
    # branch, and report success -- the shape of a gate that is green
    # having tested nothing.
    var n_ok = 0
    var n_invalid = 0
    var n_incomplete = 0
    var n_chunk_ok = 0
    var n_chunk_err = 0

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

        if ret < -2 or ret > len(chunk_buf):
            _report(seed, it, String("chunked ret is outside [-2, len]"), Span(buf))
            failures += 1
            break
        if decoded < 0 or decoded > len(chunk_buf):
            _report(
                seed, it,
                String("chunked decoded length is outside the buffer"), Span(buf),
            )
            failures += 1
            break
        if dec.pending_bytes < 0 or dec.pending_bytes > len(chunk_buf):
            _report(
                seed, it,
                String("chunked pending_bytes is outside the buffer"), Span(buf),
            )
            failures += 1
            break

    if failures > 0:
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
    if n_chunk_ok == 0:
        thin += " no-chunked-body-ever-decoded"
    if n_chunk_err == 0:
        thin += " no-chunked-body-ever-rejected"
    if thin != "":
        print("fuzz-request: the run never reached:" + thin)
        print(
            "  Mutation is not producing inputs that exercise these branches,",
            "so the iterations above prove nothing about them.",
        )
        raise Error("fuzz-request: coverage too thin to mean anything")

    print(
        "  outcomes: ok", n_ok, "invalid", n_invalid, "incomplete", n_incomplete,
        "| chunked: decoded", n_chunk_ok, "rejected", n_chunk_err,
    )
    print(
        "fuzz-request OK:", iterations, "iterations, seed", seed,
        "-- no crash, no invariant violated",
    )
