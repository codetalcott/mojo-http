# mojo-http

**Realtime from a synchronous Python app, with no added infrastructure.**

A plain sync Django or Flask view can hold a Server-Sent Events stream or a
WebSocket by answering with two response headers, and reach every subscriber
on every worker with one function call. No Channels, no Redis, no daphne, no
Pushpin, no second process.

```python
from m0serve import m0pub


def events(request):                    # an ordinary synchronous view
    r = HttpResponse(": connected\n\n", content_type="text/event-stream")
    r["M0-Hold"] = "stream"             # m0serve holds the connection open
    r["M0-Channel"] = "news"            # ...subscribed to this channel
    return r                            # Django's part in it ends here


def announce(request):                  # any view, command, or cron job
    m0pub.publish("news", "deploy finished")
    return HttpResponse("ok")
```

```bash
pip install m0serve
m0serve myproject.wsgi --realtime
```

The view runs *first*, with sessions and permissions in hand — which is
where your auth belongs, and why this is a feature of your app rather than
of a sidecar. Under gunicorn the two headers are ignored and the same view
degrades to a short plain response, so adopting it is not a fork of your
codebase.

**[QUICKSTART.md](QUICKSTART.md) is ten minutes from `pip install` to live
multi-tab sync**, and CI executes every command in it on every pull request
— so it works, or the build is red.

### Two more things it does

- **Several applications in one process, each in its native mode.**
  `m0serve --mount /=shop.wsgi --mount /app=live.asgi` runs sync Django on
  handler threads and async FastHTML on an asyncio executor, behind one
  listener with one shutdown. With four blocking 2-second sync views holding
  every pool thread, the async mount still answers at p99 2.8 ms.
- **It runs the app you already have.** WSGI or ASGI, detected from the
  object. Django, Flask and FastHTML each have their own smoke test in CI
  (FastHTML is Starlette-based, and is the flagship ASGI row), alongside
  bare WSGI and ASGI apps that pin the specs clause by clause. PEP 3333
  conformance is validated by `wsgiref`, ASGI by a validator written from
  the spec.

### What it is not

- **No TLS and no HTTP/2.** Terminate at a proxy — gunicorn's answer, and
  the same one applies here.
- **Not the fastest server on raw throughput**, and
  [docs/BENCHMARKS.md](docs/BENCHMARKS.md) says so with numbers: ~0.83x
  Granian per measured core on bare WSGI, 0.72x uvicorn on ASGI. What it
  does win is the fast-request tail under mixed load. Every figure there
  cites a dated artifact and CI recomputes the prose against it.
- **Pre-1.0**, and the API will change ([CHANGELOG](CHANGELOG.md)).
- **macOS arm64 and Linux x86_64/aarch64 only.** No Intel Mac (no
  toolchain), no Windows, no musl.

---

Underneath, `mojo-http` is an HTTP/1.1 server and a small web framework for
[Mojo](https://docs.modular.com/mojo/): routing, content negotiation, ETags,
response caching, and Server-Sent Events, with a
[Datastar](https://data-star.dev/) adapter for hypermedia UIs and SQLite
bindings for storage. The Python server above is one package in it
(`m0-wsgi`), and the rest of this README is the Mojo side.

The server itself is a hard fork of
[lightbug_http](https://github.com/Lightbug-HQ/lightbug_http), taken from
v26.1.2 and maintained here since upstream was archived on 2026-05-12 — not
a vendored snapshot. It adds hardening against request smuggling, slowloris,
and integer overflow in request parsing, connection timeouts, an SSE- and
WebSocket-aware event loop, and a fix for `epoll` struct layout on
non-x86_64. See [NOTICE](NOTICE) for the full record.

## Install

To **serve a Python application**, no Mojo toolchain is needed — install the
server binary from PyPI and point it at your app:

```bash
pip install m0serve
m0serve myproject.wsgi:application
```

Install it into the same virtual environment as your application, the way you
would gunicorn or uvicorn. The protocol is detected from the object, so the
same command serves WSGI and ASGI.

**Then: [QUICKSTART.md](QUICKSTART.md)** — ten minutes from `pip install` to
live multi-tab sync from one synchronous Django file. Every command in it is
executed by CI on every pull request, so it works or the build is red.

**One wheel per platform covers every supported CPython**, 3.10 through 3.14
including free-threaded builds. That is not a shortcut: `m0serve` does not
link libpython — Mojo `dlopen`s the interpreter at run time — so there is no
CPython ABI in the wheel to be compatible with, and no CPython inside it to
redistribute. It has no Python dependencies and fetches nothing at install
time.

| platform | status |
|---|---|
| macOS arm64 (Apple Silicon), macOS 13+ | supported |
| Linux x86_64, glibc | supported |
| Linux aarch64 (Graviton, Ampere, arm64 Docker) | supported |
| macOS x86_64 (Intel) | **not possible**: Modular ships no Intel Mac toolchain |
| musl / Alpine, Windows | not supported |

**The exact floors live in the wheel filename**, because they are measured
from the built binary rather than copied from the toolchain's own tag. macOS
is pinned at 13.0; Linux currently measures `manylinux_2_35`, so Ubuntu
22.04, Debian 12 and newer. An older distribution is declined by `pip`
rather than installed and crashed at startup — RHEL 9 and its rebuilds sit
at glibc 2.34 and miss by one minor version. Reaching them means building
inside a `manylinux_2_34` container rather than relabelling the artifact.

To **develop against the Mojo packages**, you do need the toolchain:

```bash
uv sync                     # installs the Mojo toolchain
uv run poe serve-hello      # http://localhost:8080
curl localhost:8080/health  # {"status":"ok"}
```

## The whole server

[apps/hello/server.mojo](apps/hello/server.mojo), in full:

```mojo
from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse, OK


@fieldwise_init
struct HelloHandler(HTTPService):
    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        if req.uri.request_uri == "/health":
            return OK('{"status":"ok"}', "application/json")
        return OK("hello from m0", "text/plain")

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        pass

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return List[UInt8]()

    def sse_is_streaming(self, slot: Int) -> Bool:
        return False

    def sse_slot_disconnected(mut self, slot: Int):
        pass

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        pass

    def tick(mut self, now_ms: Int):
        pass

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        pass


def main() raises:
    print("Starting hello server on 0.0.0.0:8080")
    var server = Server()
    var handler = HelloHandler()
    # The non-blocking loop multiplexes keep-alive connections instead of
    # serving one at a time — measurably better tail latency under
    # concurrent clients, and the same one-liner to call.
    server.listen_and_serve_nonblocking("0.0.0.0:8080", handler)
```

The four `sse_*` hooks are the streaming interface (shared by SSE and WebSocket slots), `tick` is the opt-in timer hook, and `ws_message` receives WebSocket messages; a handler that uses none of them returns the empty defaults shown here.

## What's in the box

| Package | Description | Tests |
| --- | --- | --- |
| `m0-core` | FNV-1a, xxHash32, wyhash64, SIMD JSON escape, JSON field parser, C-ABI exports | 66 |
| `m0-http` | Router, content negotiation, ETag, response cache, SSE, WebSockets, auth, CORS, config, health, logging, multi-worker supervisor, cross-worker broadcast bus, HTTP client, request-parsing hardening | 360 |
| `m0-datastar` | Datastar v1.0.2 wire format, `DatastarStream` fan-out with `Last-Event-ID` replay and cross-worker broadcast, `read_signals` | 73 |
| `m0-wsgi` | WSGI/ASGI gateway — run Django, Flask, FastHTML, or any WSGI/ASGI app on this server | 11 |
| `m0-sqlite` | SQLite bindings — connections, statements, typed columns, transactions, bulk read-out, array virtual table | 108 |
| **Total** | | **618** |

Modules are named `m0_*` — `mojo-http` is the repository, `m0` is the import prefix.

`m0-core`'s hash functions are also exported over a C ABI: `uv run poe build-ffi` emits `packages/m0-core/libm0core.so` (`.dylib` on macOS) for Bun's `dlopen`, Node's N-API, or Python's `ctypes` — `poe smoke-ffi` proves that path against public hash vectors in CI, and prebuilt Linux/macOS artifacts ship with each [GitHub release](https://github.com/codetalcott/mojo-http/releases).

> Each release ships **two macOS assets**: `libm0core-macos-arm64.dylib`, the
> bare library for anyone who already has a Mojo install, and
> `libm0core-macos-arm64.dylib.tar.gz`, a **self-contained bundle** (1.65 MB)
> that carries the three Mojo runtime libraries it loads, plus both licences.
> Extract it and `dlopen` the `.dylib` — nothing else needed. The Linux `.so`
> is statically linked and self-contained on its own.
>
> `poe bundle-ffi` builds that bundle and refuses to finish unless the result
> is genuinely self-contained; CI runs it on every commit, so a release cannot
> ship an asset that only loads on the build machine.
>
> **Releases up to and including v0.7.0 predate this** and record the CI
> runner's own directory, so their macOS asset does not load anywhere else.
> Build locally with `poe build-ffi` for a usable one, or use v0.8.0 onward.

Strict layering, no upward imports: `m0-core` has zero dependencies and `m0-http` uses three functions from it. `m0-datastar` splits in two — `consts` and `sse` are the pure wire format with no dependencies at all, while `stream` and `signals` are the server glue and are the only parts that pull in `m0-http`. `m0-wsgi` is the only package that embeds CPython, which is exactly why it is a separate package.

**HTTP essentials** — path router with `:param` extraction · content negotiation with quality factors, case-insensitive media ranges, and wildcards · `Accept-Encoding` negotiation (codec-agnostic: it picks among the precompressed codings you can serve, with the RFC 9110 `identity`/`*`/q=0 rules, and tells you when the honest answer is 406) · `Accept-Language` negotiation (RFC 4647 matching — `de` finds your `de-CH`, `en-US` falls back to your `en` — preferring to serve *something* over a 406, as RFC 9110 advises) · weak ETags (wyhash) with `304 Not Modified` · URL-keyed response cache · static file serving with lexical traversal defense, extension content types, ETag/304, and single byte ranges (206/416) · SSE with backpressure and `Last-Event-ID` reconnect replay · WebSockets (RFC 6455): handshake, fragmented messages, UTF-8 validation of text (1007), protocol-error refusals, ping/pong heartbeats, clean close.

**Production bits** — API key auth with constant-time comparison · CORS config · `M0_`-prefixed env-var configuration · health/readiness registry with a shutting-down flag · JSON-lines access logs to stdout · graceful shutdown on SIGTERM/SIGINT that drains in-flight requests, propagated to workers when only the supervisor is signalled · multi-worker fork supervisor (`M0_WORKERS=4`) — workers accept from one shared pre-fork listener, with a cross-worker SSE broadcast bus when the app wires it in.

**Outbound too** — `Client` speaks HTTP/1.1 the other way: `client.get(url)` / `client.post(url, body)` with DNS, timeouts, keep-alive connection reuse (framing boundaries computed per response — Content-Length, chunked with trailers, bodiless statuses, HEAD — with conservative retirement rules and a single stale-connection retry), and full response parsing with loud truncation detection. No TLS, no redirect following — the same honest constraints as the server, documented in `client.mojo`. `poe smoke-client` proves a six-request conversation rides one TCP connection in CI.

Most of that composed, in one small app: [apps/notes_api/](apps/notes_api/server.mojo)
— CRUD with `:id` routes and a real `405` with `Allow`, the same note negotiated
as JSON or HTML by the `Accept` header, `ETag`/`304`, static files under
`/static/` (traversal probes get a `404`, asserted with `curl --path-as-is`),
RFC 9457 `problem+json` on every error, CORS from a single `after_response`
hook, and `M0_PORT` config.
`uv run poe serve-notes` runs it; `poe smoke-notes` asserts each feature end to
end.

## Datastar

`m0-datastar` speaks the [Datastar](https://data-star.dev/) v1.0.2 wire format, and
`DatastarStream` connects it to the server. A handler holds one, wires the four SSE hooks
through it, and broadcasts after a mutation:

```mojo
struct CounterHandler(HTTPService):
    var count: Int
    var stream: DatastarStream

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        if req.uri.path == "/events":
            return self.stream.open(req, "/events")       # opens the SSE stream
        if req.uri.path == "/increment":
            self.count += 1
            _ = self.stream.patch_signals(                 # reaches every open tab
                "/events", '{"count":' + String(self.count) + "}"
            )
            return HTTPResponse(body_bytes=String("").as_bytes(), status_code=204)
        ...

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return self.stream.drain(slot)
    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.stream.is_streaming(slot)
    def sse_slot_disconnected(mut self, slot: Int):
        self.stream.closed(slot)
    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        self.stream.deliver_peer(url, event_id, frame)   # cross-worker fan-out
```

`read_signals(req)` is the other direction — the browser posts its whole signal store, as a
`datastar` query parameter on GET and as the body otherwise.

Run [apps/datastar_counter/](apps/datastar_counter/) with `uv run poe serve-counter` and open
it in two tabs; pressing a button in one updates the other. It is also the
reference wiring for **cross-worker fan-out**: with `M0_WORKERS=2` it creates a
`BroadcastBus` and a shared-memory counter before the fork, and a button press
handled by any worker updates tabs connected to every worker (`poe
smoke-counter` proves its streams span workers before asserting exactly that).
[apps/datastar_todo/](apps/datastar_todo/) is the same idea grown up: mutations
broadcast rendered *HTML* (`patch_elements` morphs `<section id="todos">` by id
in every tab), the per-item actions are `Router` routes with `:id`, todo
text is HTML-escaped before it is broadcast, and the list is rows in SQLite
(`M0_DB`, default `todos.db`) — kill the server and restart it, the list comes
back. So does the *stream*: broadcast frames are logged to SQLite and restored
into the `DatastarStream` journal at boot, so a tab reconnecting with
`Last-Event-ID` is caught up by the new process instead of waiting for the
next mutation. `poe smoke-todo` asserts both. `uv run poe serve-todo`.

A note on Datastar v1.0.2 attribute syntax, learned the hard way in a real
browser: the stream opens from `data-init` (there is no `on-load` plugin), and
keyed attributes are colon-separated — `data-on:click`, `data-bind:draft`. The
hyphenated forms fail silently.

**SSE and WebSockets need `listen_and_serve_nonblocking`,** not `listen_and_serve`. Only
the non-blocking event loop assigns `req.slot_id`, drains the outbox, and parses
WebSocket frames; the plain accept loop leaves `slot_id` at `-1` and every stream
open answers `409`.

## WebSockets

[apps/ws_echo/](apps/ws_echo/server.mojo) shows the whole contract in one
screen. `websocket_upgrade(req)` answers the opening handshake inside `func`
(101 on success, 426/400 for near-misses, `None` when the request isn't an
upgrade at all so ordinary routing continues); `ws_message(slot, opcode,
payload)` receives each complete message — fragments already assembled,
control frames already answered by the event loop — and replies are queued
as `encode_ws_frame(...)` bytes that the shared outbox hook delivers. Idle
sockets get protocol pings on the `M0_SSE_HEARTBEAT_MS` cadence, and every
close path — close handshake, vanished client, failed ping — lands in
`sse_slot_disconnected`. Run it with `uv run poe serve-ws`; `poe smoke-ws`
proves the wire format against a from-scratch stdlib client, from the
accept key to the closing TCP FIN.

[apps/ws_chat/](apps/ws_chat/server.mojo) grows that into the multi-worker
shape: one chat room, every message reaching every socket, across workers.
`m0_http.WSHub` is the handler-side registry (who is connected, what each
socket should be sent), and under `M0_WORKERS>1` it rides the same
`BroadcastBus` the SSE counter uses — the bus never cared what its payload
bytes were. `uv run poe serve-chat` with `M0_WORKERS=2`, open a few tabs;
`poe smoke-chat` proves a message sent on one worker's socket arrives on
the other worker's, over the bus.

## Django, and anything else that speaks WSGI

`m0-wsgi` embeds CPython and runs a WSGI application, so mojo-http can stand in
for gunicorn. The whole integration is one field and one call:

```mojo
from m0_wsgi import WSGIApp

struct DjangoHandler(HTTPService):
    var app: WSGIApp

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return self.app.serve(req)
    ...

def main() raises:
    var app = WSGIApp(
        "djangoproj.wsgi", server_name="0.0.0.0", server_port="8080",
        project_path="apps/django_wsgi",
    )
    Server().listen_and_serve("0.0.0.0:8080", DjangoHandler(app^))
```

That handler is written once, as `WSGIHandler`, and **`m0serve`** is the
binary that runs it — the uvicorn-shaped entry point:

```bash
uv run poe build-serve                                     # -> bin/m0serve
bin/m0serve myproject.wsgi:application --app-dir /path/to/project \
    --host 0.0.0.0 --port 8000 --workers 4 \
    --static /static/=/path/to/static --static-cache-control 'public, max-age=3600'
```

`MODULE[:ATTR]` names the callable (`ATTR` defaults to `application`, and a
bare `MODULE` also tries `MODULE.asgi`, `MODULE.wsgi`, `MODULE:app` and
`MODULE.main:app` by convention); **the protocol is detected from the
object** — a coroutine-function callable is served as ASGI, anything else as
WSGI, `--protocol` overrides — so `bin/m0serve main:app` runs a FastHTML,
Starlette, or FastAPI app from the same binary, with real await-concurrency
on a per-loop asyncio executor — requests overlap wherever the application
awaits, streaming responses stream for real, and `websocket` scopes work,
so FastHTML's whole surface runs with no configuration
([docs/WSGI_VS_ASGI.md](docs/WSGI_VS_ASGI.md) §8).
`--app-dir` is prepended to `sys.path` so the module imports, relative to the
current directory and defaulting to `.`.

**`--mount PREFIX=SPEC` hosts several applications in one process**, routed
by longest prefix before either sees the request:

```bash
bin/m0serve --mount /=shop.wsgi --mount /app=live.asgi \
    --app-dir apps/hybrid_mix --port 8099
```

**Each mount runs in its own native execution mode** — the sync Django app
on handler-pool threads, the async FastHTML app on the asyncio executor —
sharing one listener, one set of workers and one graceful shutdown. With
four blocking 2-second Django views holding every pool thread, the async
mount still answers at p99 2.8 ms. uvicorn, daphne and Granian each host
exactly one callable, so mixing otherwise means two processes behind a
proxy.

Each mount detects its own protocol and gets its own bridge, and the prefix
reaches the application the way its protocol expects it — `SCRIPT_NAME` with
`PATH_INFO` trimmed for WSGI, `root_path` with the whole `path` for ASGI —
so `reverse()` and `url_for()` generate links that actually work. A path no
mount claims is a 404 answered in Mojo, never entering Python. Any mix:
every ASGI mount gets its own executor, any number of WSGI mounts share
the pool ([§9](docs/WSGI_VS_ASGI.md)). Every `M0_*` variable keeps its
meaning (`M0_HOST`, `M0_PORT`, `M0_WORKERS`, `M0_ACCESS_LOG`, …) with the
matching flag winning over it, and flags are strict: `--port 80eighty` is a
usage error, not a silent default. `--max-body` and `--metrics` reach two
server tunings the environment cannot; `--blocking-threads N` puts a pool of
handler threads behind each event loop so a slow view stops holding the
connections pinned behind it — and when no topology flag or variable is
given at all, the protocol picks the default: WSGI gets a pool of
`min(cores, 8)`, ASGI gets the asyncio executor (any explicit value wins,
`M0_BLOCKING_THREADS=0` restores the WSGI single loop, `--realtime` keeps
the single loop); and `--reload [--reload-dir DIR]` re-forks the
workers onto changed Python in ~300 ms without re-exec'ing the binary.
`--help` has the rest; exit codes are
2 for a bad command line and 1 for an application that would not load —
including under `--workers N`, where a supervisor that gives up on respawning
says so instead of exiting 0.

**`--doctor` answers "will this run?" without running it.** It prints one
JSON object — platform and wheel architecture, the interpreter it resolved
and the virtualenv it came from, the spec discovery actually chose and the
protocol it classified as, the resolved topology, and a `checks` array whose
failures each carry a `detail`, a `fix` and the `exit` code that check would
cause — then starts nothing: no bind, no fork, no second import.

```console
$ m0serve --doctor myproject.wsgi --threads 4 | jq '{exit, checks: [.checks[] | select(.ok | not)]}'
{
  "exit": 78,
  "checks": [
    {
      "name": "free-threading",
      "ok": false,
      "detail": "--threads 4 requires free-threaded CPython with the GIL disabled; this is not a free-threaded build",
      "fix": "use --workers N instead, or run on 3.14t with PYTHON_GIL=0",
      "exit": 78
    }
  ]
}
```

The contract worth relying on is the exit code: **`--doctor` exits with the
code `m0serve` itself would exit with for the same arguments.** That is kept
true by running both over every refusal and comparing (`poe smoke-doctor`),
because the doctor mirrors the startup path's check order rather than sharing
its control flow — a diagnostic that reports "fine" where the server refuses
would be worse than none. A bare `m0serve --doctor` with no application is
the environment check: platform, interpreter, cores, and exit 0.

The binary resolves libpython from the `python3` on `PATH`: run it from a
virtualenv that has your framework installed, or set `MOJO_PYTHON_LIBRARY` to
the shared library. Build once, serve anywhere the interpreter is.

[apps/django_wsgi/](apps/django_wsgi/) is a real Django project with no Mojo
in it, served by exactly that command (`uv run poe serve-django`).

[apps/flask_wsgi/](apps/flask_wsgi/) is the same binary running Flask instead.
Both rows run the same assertions —
[scripts/wsgi_framework_contract.sh](scripts/wsgi_framework_contract.sh) — because
routing, cookies in both directions, body round trips and error handling are
things every WSGI framework does identically. Adding Flask needed no change to
`m0-wsgi` at all, and the rows are now Python-only: one binary serves all
three, which is the host-is-framework-agnostic claim made structural.

[apps/wsgi_bare/](apps/wsgi_bare/) is the same binary with no framework at all —
a plain PEP 3333 callable, zero third-party imports. It is what makes the claim
above demonstrable rather than merely asserted, and it is the conformance target
for `uv run poe smoke-wsgi`, which checks the parts of the spec a framework
never exercises: the `write()` callable, a second `start_response`, multi-chunk
iterables, `wsgi.input` read patterns, and the CGI environ transform. See
[docs/WSGI_CONFORMANCE.md](docs/WSGI_CONFORMANCE.md).

[apps/django_realtime/](apps/django_realtime/) is the row that answers the
question WSGI is usually retired over. A synchronous Django view holds a
connection by *answering with headers* — `M0-Hold: stream` for SSE,
`M0-Hold: websocket` for a WebSocket — and the Mojo layer takes it from
there: the 101 handshake Django cannot emit, the heartbeats, the disconnect
cleanup, the fan-out. Inbound WebSocket messages come back to Django as
ordinary `POST`s. Publishing is `os.write` from pure Python onto the
server's broadcast bus, so one line in a sync view reaches SSE clients *and*
WebSocket clients on every worker, with numbered event ids that make
`Last-Event-ID` work. No ASGI, no Channels, no async. The pattern is
Pushpin's GRIP collapsed into one process; the reasoning, the measurements,
and the remaining limits are in
[docs/WSGI_VS_ASGI.md](docs/WSGI_VS_ASGI.md). Like the other WSGI rows it is
a Python-only project: `m0serve --realtime --health-path /health` is the
whole server side of it. Run it with `uv run poe serve-django-realtime`.

**Why the boundary looks the way it does.** WSGI hands the application a
`start_response` callable that the *server* supplies, and building a Python
callable that closes over Mojo state is the hardest thing at this boundary — so
a small Python shim does it instead. The shim is a string `exec`'d at startup,
not a file, so there is nothing to locate at run time. Mojo builds each
request's WSGI environ itself, through the raw CPython C API — `PyDict_New`,
`PyDict_SetItem`, `PyUnicode_DecodeUTF8` — and hands the finished dict to the
shim, which supplies `start_response`, calls the application, and returns
`(status, headers, body)`.

The C API is not a micro-optimization but the only door available: Mojo 1.0's
`PythonObject` interop leaks a reference per call argument and per
`__setitem__` value, so any per-request Python object passed the obvious way
is pinned forever. The C API refcounts explicitly, which is what lets the
environ be built at all — and it is why every string is `Py_DecRef`'d after
`PyDict_SetItem` takes its own reference. `poe smoke-django` asserts the
result: flat memory across 10k requests. Building the environ here rather
than in Python is also worth 1.57x end to end
([docs/WSGI_PERFORMANCE.md](docs/WSGI_PERFORMANCE.md)).

Bodies cross through the same door: `std.python` binds no `bytes` API, but
the stdlib's own symbol loader reaches the functions it left out, so the
request body becomes a real `bytes` via `PyBytes_FromStringAndSize` (one
copy, and `io.BytesIO(bytes)` shares it rather than copying again) and the
response body is read back through `PyBytes_AsString`. A `String` round trip
would corrupt any byte above 0x7F; a smoke asserts a body of all 256 byte
values returns unchanged.

**Limits**, all inherited from the server rather than the bridge:

- **Concurrency is loops, and optionally a handler pool behind each.**
  `--workers N` preforks N processes that all accept from one shared
  listener, gunicorn-style — the fork happens *before* the first Python
  call, never after, because forking a live CPython is unsafe — or, on
  free-threaded CPython (3.14t or newer with the GIL off — 3.13t is a
  dead end that systematically immortalizes objects, which is why Django
  dropped it from its own CI), `--threads N` runs N
  loops on N threads in **one** process: one RSS, the app imported once, and
  none of the fork-after-init hazards. A GIL-enabled interpreter refuses
  `--threads` outright (exit 78) rather than run loops the GIL would
  serialize.

  Either way a keep-alive connection stays pinned to the loop that accepted
  it, and by default that loop calls `HTTPService.func` itself — so one slow
  view stops every connection it holds. That is measurable and it is large:
  one slow view beside fast traffic leaves fast-request p99 ~120x worse in
  *both* modes while p50 does not move at all. **`--blocking-threads N` is
  the fix**, and it composes with either mode: the loop becomes an acceptor
  that hands each request to one of N handler threads and goes straight back
  to waiting, so no connection is hostage to whichever request some other
  connection is running. On `apps/wsgi_bare` a fast request is answered in
  1 ms with two 1.5 s views in flight, against 2.7 s for the same server
  without the flag. It works on a GIL-enabled interpreter too — a view
  waiting on a database or a socket releases the GIL, which is the workload
  it exists for — and it is refused together with `--realtime`, whose
  streaming hooks run on the loop's own handler.

  Benchmarked against gunicorn at 1.4–1.5x its throughput on a GIL-enabled
  3.13 container and ~3.5x on free-threaded 3.14.7t, with
  comparable-or-better p99 in both keep-alive and close-per-request modes.
  Against **Granian**, whose own `--blocking-threads` is the architecture
  copied above, m0serve is **behind on raw WSGI throughput and the gap is
  located**: normalized per measured core, 83.8k against 101.1k rps/core on
  a bare callable — about 0.83x. The split says where it goes. `apps/hello`,
  the same server with no Python in the path, runs at 121.0k rps/core —
  above Granian's end-to-end rate — so m0serve's own bridge costs 1.44x, and
  essentially all of the deficit is that crossing rather than HTTP parsing
  or the event loop. How much of Granian's rate its *own* bridge costs is
  not measurable from this run: there is no Granian-without-Python row.

  Per *core*, because the comparator was not running one: Granian's
  `--workers 1` was measured at ~1.75 cores across its runtime's I/O
  threads, so raw-rps ratios had been comparing 1.75 cores against one.
  Every number here cites a dated artifact —
  [docs/BENCHMARKS.md](docs/BENCHMARKS.md) is the page, and it states the
  ASGI comparison against uvicorn (also a loss) beside this one;
  [docs/WSGI_PERFORMANCE.md](docs/WSGI_PERFORMANCE.md) is the working record,
  including the leak that once made this paragraph less flattering and the
  re-measurement that retired its previous numbers.
- **WSGI responses are fully buffered**, so `StreamingHttpResponse` and
  `FileResponse` are materialized in memory. Not for want of chunked
  encoding — the server has it, and ASGI responses stream through the
  executor chunk-framed on HTTP/1.1. It is PEP 3333: a WSGI response
  carries a `Content-Length`, which means knowing the length.
- **Request bodies are fully buffered too**, capped by
  `ServerConfig.max_request_body_size` (4 MB default). Raise it for uploads.
- **No TLS.** `wsgi.url_scheme` is always `http`; terminate at a proxy and set
  Django's `SECURE_PROXY_SSL_HEADER`.
- Django is a **dev dependency** here, for the example and its smoke test. The
  package itself has no opinion about which WSGI framework you run.

## SQLite

`m0-sqlite` is a thin, honest layer over the SQLite C API — no ORM, no query
builder, no connection pool. It is a **sibling** of the HTTP packages, not a
layer on them, and imports nothing else in this repo.

```mojo
from m0_sqlite import open_memory

var db = open_memory()
db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

var ins = db.prepare("INSERT INTO users (name) VALUES (?)")
ins.bind_text(1, "ada")        # parameters are 1-based
_ = ins.step()

var q = db.prepare("SELECT id, name FROM users")
while q.step():                # columns are 0-based
    print(q.column_int(0), q.column_text(1))
```

`Connection` and `Statement` own their handles and release them on destruction.
Both are `Movable` but **not** `Copyable`, so a handle cannot be duplicated into
a second owner that would close it twice — move with `^` to transfer ownership.
`open()` applies the pragmas a server actually wants: `journal_mode=WAL`,
`synchronous=NORMAL`, `foreign_keys=ON`, plus a 5-second busy timeout so a
contended write waits instead of failing on contact. Transactions are explicit
(`begin` / `commit` / `rollback`); there is no scope guard, because Mojo has no
`defer` and a destructor that rolled back would make correctness depend on drop
order.

**Wrap bulk writes in a transaction.** Ten thousand inserts take 7 ms inside one
`begin`/`commit` and 325 ms without — autocommit gives each row its own
transaction. It is a 46x difference, and the largest single effect measured in
[docs/SQLITE_PERFORMANCE.md](docs/SQLITE_PERFORMANCE.md), which also covers
`mmap_size`, variable-length `IN` lists, and how `m0_array` relates to the
`carray()` extension it replaces.

```mojo
db.begin()
for row in rows:
    ins.reset()
    ins.bind_text(1, row)
    _ = ins.step()
db.commit()
```

**Reading in bulk.** `column_blob` copies with one `memcpy`, and
`column_blob_into` reuses a caller buffer across a scan instead of allocating
per row (3.3x on 4KB blobs over 100k rows). `fetch_ints` / `fetch_floats` /
`fetch_texts` append a whole column into a caller-owned `List`; they are a
shape convenience rather than a speed-up — SQLite has no bulk column API — but
a `List` per column is what a SIMD pass over the results wants. They signal
exhaustion with a **short read**, so stop when you get fewer rows than you
asked for rather than looping until zero.

`prepare()` compiles exactly one statement; text after the first — or text that
compiles to nothing, like a lone comment — is an error rather than silently
ignored. Use `execute()` for a multi-statement script.

**Errors carry a code.** Every failure that had a SQLite result code raises a
message ending in `(rc=NN)`, and `error_code()` recovers it, so retrying a
`SQLITE_BUSY` or reporting a `SQLITE_CONSTRAINT` does not mean parsing text.
The codes worth branching on are exported by name.

```mojo
from m0_sqlite import error_code, SQLITE_BUSY, SQLITE_CONSTRAINT

try:
    db.begin_immediate()
except e:
    if error_code(String(e)) == SQLITE_BUSY:
        ...
```

**Column indices are checked.** SQLite calls an out-of-range index undefined
behaviour and in practice answers 0, `""` and `SQLITE_NULL` to it — so a typo
used to read back as a stored NULL, and `column_name` dereferenced the NULL
pointer it got and crashed. Every reader now raises instead. It costs one
`sqlite3_column_count` per cell, measured at 1.02 ns/row.

`open()` raises on a target that cannot do WAL — `:memory:`, a temp database,
some network filesystems — rather than quietly falling back to a rollback
journal and delivering none of the concurrency it advertises. Use
`open_memory()` for an in-memory database.

**Linking.** Tests build to a binary with `-Xlinker -lsqlite3` rather than using
`mojo run`. The JIT resolves symbols only from libraries already in its process:
on macOS libsqlite3 lives in the dyld shared cache so `mojo run` happens to
work, but on Linux it fails with `JIT session error: Symbols not found:
[sqlite3_open_v2, ...]`. Linking explicitly behaves the same on both. Linux also
needs `libsqlite3-dev` present at link time; CI installs it.

**Bulk arrays.** `m0_array(?)` is an opt-in virtual table that streams a Mojo
`List` into SQL without copying it, so N rows insert in one `sqlite3_step`
instead of N — measured at ~3x against the per-row bind/step/reset loop at both
10k and 200k rows (`uv run poe bench-sqlite`).

```mojo
db.register_array_module()          # per connection, not per process
var ins = db.prepare("INSERT INTO t (v) SELECT value FROM m0_array(?1)")
ins.execute_over(1, values)         # binds, runs to completion, unbinds
```

Arrays bind **only** through `execute_over` and `fetch_ints_over`, and that is
a safety property rather than a style preference. Binding a raw pointer lends
SQLite the buffer for the statement's life, but Mojo frees a value at its last
syntactic use — which would be before `step()` runs. Taking the array as an
argument to the call that also finishes the statement is what keeps it alive;
there is no `bind_array` to get wrong. The trade is that these do not compose
with incremental stepping. See
[docs/sqlite-vtab-feasibility.md](docs/sqlite-vtab-feasibility.md) for the
measurements and the reasoning, including why this is worth it for ingest and
not for `IN` clauses. Needs SQLite 3.26+; `register_array_module` says so if not.

**Not implemented:** statement caching. It was measured in the benchmark that
chose SQLite and came out within noise at realistic row counts (~10% at N=50),
so it is not worth the ownership complexity yet.

## Status and limits

- HTTP/1.1 only. No HTTP/2, no TLS — terminate at a proxy.
- Linux `x86_64` and `aarch64` (`epoll`), macOS `arm64` (`kqueue`). Architectures matter here: Modular ships no Intel Mac toolchain, so macOS `x86_64` is not buildable at all. See the install table above.
- Mojo 1.0, pinned in `uv.lock`. `.mojoc` artifacts are locked to the exact compiler that produced them, so rebuild after any toolchain change.
- Building on Linux needs three system packages: a C compiler (`mojo build` shells out for linking), `patchelf` (the binaries record a `$ORIGIN` `DT_RUNPATH` so they find the Mojo runtime beside themselves), and `libsqlite3-dev` for `m0-sqlite`. `build-essential libsqlite3-dev patchelf` covers it. None are needed on macOS.
- `m0-wsgi` needs a discoverable `libpython` (Python 3.10–3.14; this repo pins 3.13). Mojo resolves the interpreter from `PATH`, which is why the poe tasks — running inside the venv — pick up the venv's Python and its packages.
- Pre-1.0: the API will break.
- **SSE fan-out is single-process by default.** `M0_WORKERS>1` forks, and each worker gets its own subscriber registry. The `BroadcastBus` lifts this when wired in: created before the fork (one datagram channel per worker, alongside a `SharedAtomics` slot that keeps event ids unique across workers), it carries every broadcast to every worker's subscribers — `apps/datastar_counter` is the reference wiring, asserted by `poe smoke-counter`. Cross-worker ordering is best-effort: two workers broadcasting concurrently can reach a subscriber in either order, and the redelivery filter keeps the newer id.
- **Server-initiated pushes go through `tick`.** The `tick(now_ms)` hook fires every `M0_APP_TICK_MS` milliseconds (0, the default, disables it) on the event loop's own timer — broadcast from it and the same loop pass delivers, no inbound request involved; the counter demo's live uptime clock is the reference. It runs on the event loop thread, so keep it quick; handlers with slower cadences sub-schedule off `now_ms`. (Idle-stream `: heartbeat` comments are separate and automatic, every `M0_SSE_HEARTBEAT_MS`.)
- `m0-sqlite` has no statement cache and no connection pool; see above.
- SSE replay is journal-deep. `DatastarStream` honours `Last-Event-ID` from a bounded in-memory frame journal (default 64 frames); a client further behind than that resumes live instead of being caught up. In-process replay works out of the box — replay across a *restart* additionally needs the app to persist the journal and restore it at boot, which the todo demo does (SQLite `events` table, ~15 lines).

## Development

```bash
uv run poe                  # list every task
uv run poe build-all        # compile each package to .mojoc
uv run poe test-all         # 618 unit tests, then compiles every example
uv run poe serve-notes      # the framework showcase (notes CRUD) on :8080
uv run poe serve-counter    # the Datastar counter demo on :8080
uv run poe serve-todo       # the Datastar todo demo (multi-tab sync) on :8080
uv run poe serve-django     # the Django WSGI example on :8080
uv run poe serve-wsgi-bare  # the framework-free WSGI example on :8086
uv run poe serve-flask      # the Flask WSGI example on :8087
uv run poe smoke-hello      # start the hello server, assert /health, stop
uv run poe smoke-notes      # assert routing, negotiation, ETag/304, static files, CORS
uv run poe smoke-ws         # speak RFC 6455 raw: handshake, echo, fragments, ping/pong, close
uv run poe smoke-chat       # one chat message reaches sockets on BOTH workers, over the bus
uv run poe smoke-counter    # assert SSE broadcast, heartbeats, disconnect cleanup, app tick, fan-out
uv run poe smoke-todo       # assert broadcasts, restart survival, and Last-Event-ID replay
uv run poe smoke-client     # run the Mojo HTTP client against a Mojo server
uv run poe smoke-wsgi       # PEP 3333 conformance against a bare WSGI callable
uv run poe smoke-flask      # the same framework contract, against Flask
uv run poe smoke-django     # assert a Django request/response cycle end to end
uv run poe build-ffi        # emit the C-ABI shared library (libm0core.so/.dylib)
uv run poe smoke-ffi        # load the shared library via ctypes, assert known vectors
uv run poe bench-core       # benchmark m0-core hot paths
uv run poe bench-sqlite     # benchmark m0-sqlite blob reads and bulk ingest
```

Cross-package imports resolve through the `.mojoc` files, so run `build-all` after changing a package's sources — including for the editor, or the LSP reports phantom unresolved imports. Copy `.vscode/settings.example.json` to `.vscode/settings.json` and fill in your absolute path.

To probe an upcoming Mojo nightly without changing the pin:

```bash
uv run poe nightly-try           # swap the venv onto the latest nightly
uv run --no-sync poe test-all    # --no-sync is REQUIRED while on a nightly
uv run poe nightly-restore       # back to the pinned stable toolchain
```

A plain `uv run` re-syncs the venv to `uv.lock` and silently reverts the nightly, which would make the check a no-op.

## License and attribution

MIT — see [LICENSE](LICENSE).

`packages/m0-http/lightbug_http/` is a hard fork of MIT-licensed work by Valentin Erokhin. Upstream was archived and there is nothing to rebase onto or send patches to; this copy is maintained here. [NOTICE](NOTICE) records the provenance and every category of modification, and [PROVENANCE.md](PROVENANCE.md) explains how this repository was extracted from a private monorepo.
