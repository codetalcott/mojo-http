"""Where the WSGI bridge's per-request cost actually goes.

`docs/WSGI_PERFORMANCE.md` splits the bridge by part rather than guessing at
it, because guessing was wrong once: the ~1 ms per request was "obviously"
the Python shim, and it was 48 µs of `serialize_request` in Mojo. This is
the instrument that settled that, and every later change to the boundary is
measured with it before and after.

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


def _report(label: String, ns_total: Int) -> Float64:
    var us = Float64(ns_total) / Float64(N) / 1000.0
    print(label, ":", us, "us")
    return us


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

    print("headers:", req.headers.count())
    print("iterations:", N)
    print("")

    # 1. One zero-argument call into Python, nothing else. The serving path
    #    pays this only for a request that HAS a body -- it is the address
    #    fetch for the body buffer -- so it is here as the unit cost of a
    #    Python-level crossing, not as something every request pays.
    var t0 = perf_counter_ns()
    for _ in range(N):
        bridge.probe_buf_addr()
    var us_call = _report("buf_addr() zero-arg call  ", perf_counter_ns() - t0)

    # 2. The whole environ dict, built in Mojo through the CPython C API:
    #    PyDict_New, the base replay, four request-line fields and twelve
    #    CGI-transformed headers. No Python bytecode runs here at all.
    t0 = perf_counter_ns()
    for _ in range(N):
        bridge.probe_build_environ(req)
    var us_env = _report("build_environ (C API)     ", perf_counter_ns() - t0)

    # 3. build_environ + the args tuple + PyObject_CallObject + everything
    #    the shim does: wsgi.input, start_response, the app, the joins.
    t0 = perf_counter_ns()
    for _ in range(N):
        var r = bridge.run(req)
        _ = r
    var us_run = _report("run() = environ + shim    ", perf_counter_ns() - t0)

    # 4. The whole round trip a request actually pays.
    t0 = perf_counter_ns()
    for _ in range(N):
        var result = bridge.run(req)
        var body = bridge.body_bytes(result[2])
        _ = len(body)
    var us_full = _report("FULL round trip           ", perf_counter_ns() - t0)

    print("")
    print("derived: shim + call      :", us_run - us_env, "us")
    print("derived: response body out:", us_full - us_run, "us")
    _ = us_call
