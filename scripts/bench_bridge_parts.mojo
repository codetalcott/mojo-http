"""Where the WSGI bridge's per-request cost actually goes.

`docs/WSGI_PERFORMANCE.md` splits the bridge by part rather than guessing at
it, because guessing was wrong twice: the ~1 ms per request was "obviously"
the Python shim and it was 48 µs of `serialize_request` in Mojo; then the
remaining 1.07 µs was described as three costs and it was one of them. This
is the instrument that settled both, and every later change to the boundary
is measured with it before and after.

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


def _browser_headers() raises -> Headers:
    """The twelve-header browser shape every bridge benchmark drives."""
    return Headers(
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


def _get_request() raises -> HTTPRequest:
    """A twelve-header GET: the keep-alive fast path, no body."""
    return HTTPRequest(
        uri=URI.parse("http://127.0.0.1:8080/"), headers=_browser_headers()
    )


def _post_request() raises -> HTTPRequest:
    """The same shape with a 1 KB body: the request-body staging path."""
    var req = HTTPRequest(
        uri=URI.parse("http://127.0.0.1:8080/echo"),
        headers=_browser_headers(),
        method="POST",
    )
    req.headers["content-length"] = "1024"
    req.body_raw = List[UInt8](capacity=1024)
    for i in range(1024):
        req.body_raw.append(UInt8(i & 0xFF))
    return req^


def _report(label: String, ns_total: Int) -> Float64:
    var us = Float64(ns_total) / Float64(N) / 1000.0
    print(label, ":", us, "us")
    return us


def main() raises:
    var get_req = _get_request()
    var post_req = _post_request()
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

    print(
        "headers:",
        get_req.headers.count(),
        " post body:",
        len(post_req.body_raw),
    )
    print("iterations:", N)
    print("")

    # 1. The whole environ dict, built in Mojo through the CPython C API:
    #    PyDict_New, the base replay, four request-line fields and twelve
    #    CGI-transformed headers. No Python bytecode runs here at all.
    var t0 = perf_counter_ns()
    for _ in range(N):
        bridge.probe_build_environ(get_req)
    var us_env = _report("build_environ (C API)     ", perf_counter_ns() - t0)

    # 2. build_environ + wsgi.input + the args tuple + PyObject_CallObject +
    #    everything the shim does: start_response, the app, the joins.
    t0 = perf_counter_ns()
    for _ in range(N):
        var r = bridge.run(get_req)
        _ = r
    var us_get = _report("run() GET, no body        ", perf_counter_ns() - t0)

    # 3. The same request carrying 1 KB: what staging a request body costs
    #    on top of row 2.
    t0 = perf_counter_ns()
    for _ in range(N):
        var r = bridge.run(post_req)
        _ = r
    var us_post = _report("run() POST, 1 KB body     ", perf_counter_ns() - t0)

    # 4. The whole round trip a GET actually pays.
    t0 = perf_counter_ns()
    for _ in range(N):
        var result = bridge.run(get_req)
        var body = bridge.body_bytes(result[2])
        _ = len(body)
    var us_full = _report("FULL GET round trip       ", perf_counter_ns() - t0)

    print("")
    print("derived: shim + call      :", us_get - us_env, "us")
    print("derived: 1 KB body staging:", us_post - us_get, "us")
    print("derived: response body out:", us_full - us_get, "us")
