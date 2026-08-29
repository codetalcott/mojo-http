"""Where the Mojo HTTP layer's per-request cost actually goes.

The companion to `bench_bridge_parts.mojo`, one layer down. Every number in
`docs/SERVER_PERFORMANCE.md` came from `wrk` plus gdb stack sampling, which is
the right instrument for "is the server syscall-bound" and the wrong one for
"did this change to `parse_http_version` do anything" — the executor row
swings ±10% between wrk rounds, and a 100 ns change is invisible inside that.
This splits the user-space request path by part, in isolation, so a change
to one part is measured against that part and not against loopback noise.

    uv run mojo run -I packages/m0-http -I packages/m0-core \\
      scripts/bench_http_parts.mojo

Deliberately NOT a poe task: a diagnostic, not a gate. The parts, in the
order the event loop runs them on a keep-alive request:

  1. `find_header_end`       the SIMD scan for CRLFCRLF
  2. `parse_request_headers` request line + headers into `ParsedRequestHeaders`
                             (this is where the `Array[HTTPHeader, 100]` fill
                             and `parse_http_version`'s List live)
  3. `HTTPRequest.from_parsed` the request object: URI, cookie jar, body move
  4. header lookups          what a handler asks of `Headers`
  5. `Router.match`          a hit with a captured param, and a miss
  6. response construct + `encode_into` with a rotating buffer, as the loop does

The last row is the sum: the user-space share of one request. At 116k
rps/core the whole request costs ~8.6 µs including both syscalls, so that
row is the ceiling on what any user-space change can buy.
"""

from std.time import perf_counter_ns

from lightbug_http.header import (
    HeaderKey,
    ParsedRequestHeaders,
    find_header_end,
    parse_request_headers,
)
from lightbug_http.http import HTTPRequest, HTTPResponse, OK
from lightbug_http.io.bytes import Bytes

from src.router import Router


comptime N = 20000
comptime SERVER_ADDR = "127.0.0.1:8080"
comptime MAX_URI = 8192


def _browser_get() -> List[UInt8]:
    """The twelve-header browser GET, as the bytes the socket delivers."""
    var s = String(
        "GET / HTTP/1.1\r\n"
        "Host: 127.0.0.1:8080\r\n"
        "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
        " AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36\r\n"
        "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,"
        "image/avif,image/webp,*/*;q=0.8\r\n"
        "Accept-Language: en-US,en;q=0.9\r\n"
        "Accept-Encoding: gzip, deflate, br\r\n"
        "Cache-Control: max-age=0\r\n"
        "Upgrade-Insecure-Requests: 1\r\n"
        "Sec-Fetch-Mode: navigate\r\n"
        "Sec-Fetch-Dest: document\r\n"
        "Referer: http://127.0.0.1:8080/\r\n"
        "Connection: keep-alive\r\n"
        "Content-Length: 0\r\n"
        "\r\n"
    )
    var out = List[UInt8](capacity=s.byte_length())
    out.extend(s.as_bytes())
    return out^


# The parse functions raise TYPED errors (RequestParseError, RequestBuildError)
# and a `try` infers one type from its first raising call, so each gets an
# untyped wrapper. The call costs a few ns against parts measured in µs.


def _parse(span: Span[Byte, _]) raises -> ParsedRequestHeaders:
    try:
        return parse_request_headers(span)
    except:
        raise Error("parse_request_headers failed on the browser GET")


def _build(var parsed: ParsedRequestHeaders) raises -> HTTPRequest:
    try:
        return HTTPRequest.from_parsed(SERVER_ADDR, parsed^, Bytes(), MAX_URI)
    except:
        raise Error("from_parsed failed on the browser GET")


def _report(label: String, ns_total: Int) -> Float64:
    var us = Float64(ns_total) / Float64(N) / 1000.0
    print(label, ":", us, "us")
    return us


def _router() -> Router:
    """The notes_api shape: five routes, two with a captured id."""
    var r = Router()
    r.add("GET", "/notes", 0)
    r.add("POST", "/notes", 1)
    r.add("GET", "/notes/:id", 2)
    r.add("PUT", "/notes/:id", 3)
    r.add("DELETE", "/notes/:id", 4)
    return r^


def main() raises:
    var raw = _browser_get()
    var span = Span(raw)
    print("request bytes:", len(raw), " iterations:", N)
    print("")

    # Warm the allocator and the caches before the first timed row: once
    # the parse dropped under a microsecond its row, being the first heavy
    # loop, read 0.85 in one run and 1.20 in the next — with the next row
    # (parse PLUS from_parsed) below it, which cannot be.
    for _ in range(N // 10):
        var req = _build(_parse(span))
        _ = req.method

    # 1. The CRLFCRLF scan alone.
    var t0 = perf_counter_ns()
    var end_hits = 0
    for _ in range(N):
        var e = find_header_end(span)
        if e:
            end_hits += 1
    _ = _report("find_header_end              ", perf_counter_ns() - t0)
    if end_hits != N:
        raise Error("find_header_end missed the terminator")

    # 2. Request line + twelve headers into ParsedRequestHeaders.
    t0 = perf_counter_ns()
    var consumed = 0
    for _ in range(N):
        var parsed = _parse(span)
        consumed = parsed.bytes_consumed
    var us_parse = _report("parse_request_headers        ", perf_counter_ns() - t0)
    if consumed != len(raw):
        raise Error("parse consumed " + String(consumed) + " of " + String(len(raw)))

    # 3. parse + from_parsed: the request object on top of the parse.
    t0 = perf_counter_ns()
    for _ in range(N):
        var req = _build(_parse(span))
        _ = req.method
    var us_parse_build = _report("parse + from_parsed          ", perf_counter_ns() - t0)

    # 4. Header lookups, on one parsed request: the questions a handler asks.
    var req_once = _build(_parse(span))
    var hits = 0
    t0 = perf_counter_ns()
    for _ in range(N):
        if HeaderKey.CONNECTION in req_once.headers:
            hits += 1
    _ = _report("Headers: `in` (hit)          ", perf_counter_ns() - t0)
    t0 = perf_counter_ns()
    for _ in range(N):
        var a = req_once.headers.get(HeaderKey.ACCEPT)
        if a:
            hits += 1
    _ = _report("Headers: get -> String       ", perf_counter_ns() - t0)
    t0 = perf_counter_ns()
    for _ in range(N):
        if req_once.headers.value_equals_ignore_case(HeaderKey.CONNECTION, "close"):
            hits += 1
    _ = _report("Headers: value_equals_ic     ", perf_counter_ns() - t0)
    t0 = perf_counter_ns()
    for _ in range(N):
        hits += req_once.headers.content_length()
    _ = _report("Headers: content_length      ", perf_counter_ns() - t0)
    if hits < 0:
        raise Error("unreachable; keeps the lookups live")

    # 5. Routing: a hit that captures a parameter, and a miss.
    var router = _router()
    t0 = perf_counter_ns()
    var matched = 0
    for _ in range(N):
        var m = router.match("GET", "/notes/7")
        if m.matched:
            matched += 1
    _ = _report("Router.match (hit, 1 param)  ", perf_counter_ns() - t0)
    t0 = perf_counter_ns()
    for _ in range(N):
        var m = router.match("GET", "/nothing/here/at/all")
        if m.matched:
            matched += 1
    _ = _report("Router.match (miss)          ", perf_counter_ns() - t0)
    if matched != N:
        raise Error("router matched " + String(matched) + " of " + String(N))

    # 6. The response: construction alone, then construction + encode_into
    #    with the loop's rotating buffer, so the encode is the difference.
    t0 = perf_counter_ns()
    for _ in range(N):
        var resp = OK("hello from m0", "text/plain")
        _ = resp.status_code
    var us_ok = _report("OK() construct               ", perf_counter_ns() - t0)
    var scratch = Bytes(capacity=4096)
    t0 = perf_counter_ns()
    for _ in range(N):
        var resp = OK("hello from m0", "text/plain")
        scratch = resp^.encode_into(scratch^)
    var us_ok_enc = _report("OK() + encode_into (rotating)", perf_counter_ns() - t0)
    if len(scratch) == 0:
        raise Error("encode produced nothing")

    # 7. The sum the loop pays in user space for one keep-alive GET.
    t0 = perf_counter_ns()
    for _ in range(N):
        var e = find_header_end(span)
        if not e:
            raise Error("no terminator")
        var req = _build(_parse(span))
        var close = req.headers.value_equals_ignore_case(HeaderKey.CONNECTION, "close")
        var resp = OK("hello from m0", "text/plain")
        if close:
            resp.status_code = 200
        scratch = resp^.encode_into(scratch^)
    var us_all = _report("WHOLE user-space request     ", perf_counter_ns() - t0)

    print("")
    print("derived: from_parsed alone   :", us_parse_build - us_parse, "us")
    print("derived: encode_into alone   :", us_ok_enc - us_ok, "us")
    print("derived: parse share of whole:", us_parse / us_all * 100.0, "%")
    print("")
    print("At 116k rps/core one request is ~8.6 us all-in, syscalls included.")
    print("User-space share measured here:", us_all, "us")
