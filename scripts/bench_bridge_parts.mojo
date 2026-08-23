"""Where the ~1ms per request in the WSGI bridge actually goes.

`docs/WSGI_PERFORMANCE.md` measures the bridge at ~1ms/request against a
Python callable that does nothing. A standalone Python microbenchmark of the
shim's `handle()` — the blob parse, the app call, the joins — costs only
~12us of that. So most of the cost is on the Mojo side of the boundary or in
the crossing itself, and this splits it.

    uv run mojo run -I packages/m0-wsgi -I packages/m0-http -I packages/m0-core \\
      scripts/bench_bridge_parts.mojo

Deliberately NOT a poe task: it needs a Python interpreter with nothing
installed but the stdlib, and it is a diagnostic, not a gate.
"""

from std.python import Python, PythonObject
from std.time import perf_counter_ns

from lightbug_http import HTTPRequest
from lightbug_http.header import Headers, Header
from lightbug_http.uri import URI

from src.bridge import PyBridge
from src.environ import serialize_request


comptime N = 20000


def _browser_request() raises -> HTTPRequest:
    """A twelve-header GET, the shape the benchmarks drive."""
    var h = Headers(
        Header("Host", "127.0.0.1:8080"),
        Header(
            "User-Agent",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
            " AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
        ),
        Header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,"
            "image/avif,image/webp,*/*;q=0.8",
        ),
        Header("Accept-Language", "en-US,en;q=0.9"),
        Header("Accept-Encoding", "gzip, deflate, br"),
        Header("Cache-Control", "max-age=0"),
        Header("Upgrade-Insecure-Requests", "1"),
        Header("Sec-Fetch-Mode", "navigate"),
        Header("Sec-Fetch-Dest", "document"),
        Header("Referer", "http://127.0.0.1:8080/"),
        Header("Connection", "keep-alive"),
        Header("Content-Length", "0"),
    )
    return HTTPRequest(uri=URI.parse("http://127.0.0.1:8080/"), headers=h^)


def _report(label: String, ns_total: Int):
    var us = Float64(ns_total) / Float64(N) / 1000.0
    print(label, ":", us, "us")


def main() raises:
    var req = _browser_request()
    var bridge = PyBridge()
    bridge.set_base("0.0.0.0", "8080", False, False)

    # A trivial WSGI callable, defined in Python so nothing framework-shaped
    # is in the measurement.
    var builtins = Python.import_module("builtins")
    var ns = Python.dict()
    builtins.exec(
        PythonObject(
            "def app(environ, start_response):\n"
            "    start_response('200 OK', [('Content-Type','text/plain')])\n"
            "    return [b'bare wsgi app']\n"
        ),
        ns,
    )
    bridge.set_app(ns["app"])

    var blob = serialize_request(req)
    print("blob bytes:", len(blob))
    print("iterations:", N)
    print("")

    # 1. Mojo-side blob construction.
    var t0 = perf_counter_ns()
    for _ in range(N):
        var b = serialize_request(req)
        _ = len(b)
    _report("serialize_request        ", perf_counter_ns() - t0)

    # 2. One zero-argument call into Python, nothing else.
    t0 = perf_counter_ns()
    for _ in range(N):
        bridge.probe_buf_addr()
    _report("buf_addr() zero-arg call ", perf_counter_ns() - t0)

    # 3. The blob copy into the shim's buffer (address fetch + byte loop).
    t0 = perf_counter_ns()
    for _ in range(N):
        bridge.probe_copy(Span(blob))
    _report("copy blob into buffer    ", perf_counter_ns() - t0)

    # 4. handle() alone — the call plus everything Python does inside it.
    t0 = perf_counter_ns()
    for _ in range(N):
        var r = bridge.probe_handle()
        _ = r
    _report("handle() call + shim     ", perf_counter_ns() - t0)

    # 5. The whole round trip a request actually pays.
    t0 = perf_counter_ns()
    for _ in range(N):
        var result = bridge.handle(Span(blob))
        var body = bridge.body_bytes(result[2])
        _ = len(body)
    _report("FULL round trip          ", perf_counter_ns() - t0)
