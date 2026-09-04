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
from src.response import build_asgi_response, build_response


comptime N = 20000

comptime ASGI_BATCH = 1000
"""Requests spawned before the loop is run: 20k parked tasks at once is
memory, not measurement, and a batch of a thousand is what the pump's own
job batches look like at saturation."""

comptime ASGI_SETUP = (
    "import asyncio, socket, time\n"
    "from http.client import responses as _reasons\n"
    "DJANGO_ISH_B = [(b'content-type', b'text/html; charset=utf-8'),\n"
    "  (b'x-frame-options', b'DENY'), (b'vary', b'Cookie'),\n"
    "  (b'x-content-type-options', b'nosniff'),\n"
    "  (b'referrer-policy', b'same-origin'),\n"
    "  (b'cross-origin-opener-policy', b'same-origin')]\n"
    "async def asgi_app(scope, receive, send):\n"
    "    await send({'type': 'http.response.start', 'status': 200,\n"
    "                'headers': DJANGO_ISH_B})\n"
    "    await send({'type': 'http.response.body', 'body': b'bare asgi app'})\n"
    "class Port:\n"
    "    # The stand-in for ExecutorPort: records what the executor would\n"
    "    # dispatch into Mojo, so the row measures the shim's work alone.\n"
    "    def __init__(self):\n"
    "        self.events = []\n"
    "    def dispatch(self, ev):\n"
    "        self.events.append(ev)\n"
    "        return False\n"
    "    def flush(self):\n"
    "        pass\n"
    "port = Port()\n"
    "sub_r, sub_w = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)\n"
    "ack_r, ack_w = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)\n"
    "for s in (sub_r, sub_w, ack_r, ack_w):\n"
    "    s.setblocking(False)\n"
    "def drain():\n"
    "    # Run every spawned task to its done-callback, timed from inside\n"
    "    # Python so the loop's own overhead is in the row, as it is in the\n"
    "    # executor thread's.\n"
    "    t0 = time.perf_counter_ns()\n"
    "    _loop.run_until_complete(asyncio.gather(*list(_exec_tasks)))\n"
    "    return time.perf_counter_ns() - t0\n"
    "def head_decode_ns(n):\n"
    "    # What the shim did to a head before handing it over: the reason\n"
    "    # lookup, the '%d %s', a latin-1 decode of every name and value.\n"
    "    hs = DJANGO_ISH_B\n"
    "    status = 200\n"
    "    t0 = time.perf_counter_ns()\n"
    "    for _ in range(n):\n"
    "        headers = [(a.decode('latin-1'), b.decode('latin-1')) for a, b in hs]\n"
    "        s = '%d %s' % (status, _reasons.get(status, ''))\n"
    "    return time.perf_counter_ns() - t0\n"
)
"""The ASGI half of the bench: a six-header app, a recording port, the
two socket pairs `asgi_executor_init` registers readers on (never
written to here), and two Python-timed helpers."""


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

    # Response-header shapes. The bare app returns ONE header, which is not
    # what a framework returns: Django's default set is six before the app
    # adds anything, and a session view adds two Set-Cookie lines on top --
    # and Set-Cookie takes a different path (ResponseCookieJar) because
    # `Headers` is a Dict and would keep only the last one.
    builtins.exec(
        PythonObject(
            "DJANGO_ISH = [('Content-Type','text/html; charset=utf-8'),\n"
            "  ('X-Frame-Options','DENY'), ('Vary','Cookie'),\n"
            "  ('X-Content-Type-Options','nosniff'),\n"
            "  ('Referrer-Policy','same-origin'),\n"
            "  ('Cross-Origin-Opener-Policy','same-origin')]\n"
            "COOKIES = [\n"
            "  ('Set-Cookie','sessionid=abc123; Path=/; HttpOnly; SameSite=Lax'),\n"
            "  ('Set-Cookie','csrftoken=xyz789; Path=/; SameSite=Lax')]\n"
            "def app6(environ, start_response):\n"
            "    start_response('200 OK', list(DJANGO_ISH))\n"
            "    return [b'bare wsgi app']\n"
            "def app6c(environ, start_response):\n"
            "    start_response('200 OK', DJANGO_ISH + COOKIES)\n"
            "    return [b'bare wsgi app']\n"
        ),
        ns,
    )

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

    # 5. The RESPONSE path: what `app.serve` does with what `run` returned.
    #    Never measured before -- `bench_bridge_parts` stopped at the bridge,
    #    so `build_response` (which iterates the app's response headers as
    #    PythonObjects, two `String(py=...)` each) was outside every split
    #    this document has ever printed.
    print("")

    # Inlined three times rather than a helper: a nested function capturing
    # `bridge` mutably has no inferable capture convention in Mojo 1.0.
    bridge.set_app(ns["app"])
    var res1 = bridge.run(get_req)
    t0 = perf_counter_ns()
    for _ in range(N):
        var resp = build_response(
            bridge, String(py=res1[0]), res1[1], res1[2]
        )
        _ = resp.status_code
    var us_r1 = _report("build_response, 1 header  ", perf_counter_ns() - t0)
    _ = res1

    bridge.set_app(ns["app6"])
    var res6 = bridge.run(get_req)
    t0 = perf_counter_ns()
    for _ in range(N):
        var resp = build_response(
            bridge, String(py=res6[0]), res6[1], res6[2]
        )
        _ = resp.status_code
    var us_r6 = _report("build_response, 6 headers ", perf_counter_ns() - t0)
    _ = res6

    bridge.set_app(ns["app6c"])
    var res6c = bridge.run(get_req)
    t0 = perf_counter_ns()
    for _ in range(N):
        var resp = build_response(
            bridge, String(py=res6c[0]), res6c[1], res6c[2]
        )
        _ = resp.status_code
    var us_r6c = _report(
        "build_response, 6 + 2 cookie", perf_counter_ns() - t0
    )
    _ = res6c

    # 6. run + build_response, which is exactly `WSGIApp.serve`.
    bridge.set_app(ns["app6"])
    t0 = perf_counter_ns()
    for _ in range(N):
        var res = bridge.run(get_req)
        var resp = build_response(bridge, String(py=res[0]), res[1], res[2])
        _ = resp.status_code
    var us_serve = _report("serve() = run + response  ", perf_counter_ns() - t0)
    bridge.set_app(ns["app"])

    # 7. The ASGI executor's per-request Python work, by part -- the layer
    #    the 2026-09-04 executor handoff prices (docs/notes/ names it). A
    #    stand-in port records the events the executor's ExecutorPort
    #    would dispatch, and the loop is driven from here in batches, so
    #    the rows split as: `spawn` (the crossing, the scope build and
    #    create_task), the task's run to its done-callback (the app, both
    #    sends, the completion's dispatch into the stub), and the head read
    #    on the Mojo side -- plus, timed in Python alone, the decode the
    #    shim applies to a head before it crosses.
    print("")
    var abridge = PyBridge()
    # Into the SHIM's namespace, not the bench's: `drain` reads the shim's
    # `_loop` and `_exec_tasks` as globals, exactly as the shim's own
    # functions do.
    builtins.exec(PythonObject(ASGI_SETUP), abridge._ns)
    abridge.set_base("0.0.0.0", "8080", False, False)
    # No lifespan: the app above does not speak it, and the executor's own
    # fallback bridge is built the same way.
    _ = abridge.set_app(abridge._ns["asgi_app"], "auto", False)
    abridge.set_port(abridge._ns["port"])
    abridge.executor_init(
        Int(py=abridge._ns["sub_r"].fileno()),
        Int(py=abridge._ns["ack_r"].fileno()),
    )

    t0 = perf_counter_ns()
    for _ in range(N):
        abridge.probe_build_scope(get_req)
    var us_scope = _report("ASGI build_scope (C API)  ", perf_counter_ns() - t0)

    var ns_spawn = 0
    var ns_drain = 0
    for _ in range(N // ASGI_BATCH):
        t0 = perf_counter_ns()
        for _ in range(ASGI_BATCH):
            abridge.spawn_asgi(0, get_req)
        ns_spawn += perf_counter_ns() - t0
        ns_drain += Int(py=abridge._ns["drain"]())
    var us_spawn = _report("ASGI spawn (scope + task) ", ns_spawn)
    var us_drain = _report("ASGI task run -> dispatch ", ns_drain)
    # What the shim used to do to a head before handing it over, kept as
    # the row it was retired from: it no longer runs per request.
    var us_decode = _report(
        "ASGI head decode, retired ",
        Int(py=abridge._ns["head_decode_ns"](PythonObject(N))),
    )

    var events = abridge._ns["port"].events
    var last = events[len(events) - 1]
    if String(py=last[0]) != "done":
        raise Error("the last executor event is not a completion: " + String(py=last[0]))
    t0 = perf_counter_ns()
    for _ in range(N):
        var resp = build_asgi_response(
            abridge, Int(py=last[2]), last[3], last[4]
        )
        _ = resp.status_code
    var us_ahead = _report("ASGI head -> HTTPResponse ", perf_counter_ns() - t0)
    _ = last
    _ = events

    print("")
    print("derived: shim + call      :", us_get - us_env, "us")
    print("derived: 1 KB body staging:", us_post - us_get, "us")
    print("derived: response body out:", us_full - us_get, "us")
    print("derived: per response hdr :", (us_r6 - us_r1) / 5.0, "us")
    print("derived: 2 Set-Cookie cost:", us_r6c - us_r6, "us")
    print("")
    print("REQUEST  side (run, GET)  :", us_get, "us")
    print("RESPONSE side (6 headers) :", us_r6, "us")
    print("serve() total             :", us_serve, "us")
    print("")
    print("ASGI scope build (C API)  :", us_scope, "us")
    print("ASGI executor, Python side:", us_spawn + us_drain, "us (spawn + task)")
    print("ASGI head decode, retired :", us_decode, "us (no longer paid)")
    print("ASGI head read, Mojo side :", us_ahead, "us")
