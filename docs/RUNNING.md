# Running m0serve

How to start the server for the application you have, what each mode is
for, and what to put around it in production. The [Quickstart](../QUICKSTART.md)
is the tutorial; this is the reference you come back to.

## Install and start

Install the wheel into the same virtual environment as your application, the
way you would gunicorn or uvicorn. It has no Python dependencies and fetches
nothing at install time.

```bash
pip install m0serve
m0serve myproject.wsgi:application          # an explicit callable
m0serve myproject                            # or let discovery find it
```

The name is spelled with a zero, `m0serve`, like the packages underneath it
(`m0-core`, `m0-http`, `m0-wsgi`); `moserve` with a letter is nothing.

`MODULE[:ATTR]` names the callable; `ATTR` defaults to `application`. A bare
`MODULE` tries `MODULE.asgi:application`, `MODULE.wsgi:application`,
`MODULE:app` and `MODULE.main:app`, in that order. `--app-dir DIR` is
prepended to `sys.path` and defaults to the current directory.

The protocol is detected from the object: a coroutine-function callable is
served as ASGI, anything else as WSGI. `--protocol wsgi|asgi` overrides.

The ready signal is one line per worker, printed after the application has
imported:

```text
🔥 m0serve: myproject.wsgi:application on http://0.0.0.0:8000 (protocol=wsgi workers=1) blocking-threads=8 (auto)
```

An application that fails to import prints its traceback and exits 1 before
that line. For orchestration, use `--health-path /health` (answered in the
server, before Python) or a TCP check, not the banner.

## Which mode

With no topology flag or `M0_*` topology variable, the protocol chooses:

| your application | what runs by default | why |
|---|---|---|
| WSGI (Django, Flask) | one event loop, a pool of `min(cores, 8)` handler threads | a slow view holds its thread, not the connections behind it |
| ASGI (FastHTML, Starlette, Django ASGI) | one event loop, an asyncio executor | requests overlap wherever the app awaits, uvicorn's shape |

Everything else is opt-in:

| flag | use it when | notes |
|---|---|---|
| `--workers N` | you want N processes on a multi-core host | prefork; a supervisor respawns crashes and drains on SIGTERM |
| `--spawn-workers` | a worker uses Core ML, Objective-C or anything else a forked child cannot | each worker execs the binary afresh after the fork; same supervisor, one extra process start per worker |
| `--blocking-threads N` | you want more or fewer handler threads per loop | `0` turns the pool off; for ASGI, `N>0` selects the buffered path instead of the executor |
| `--realtime` | sync views hold SSE streams or WebSockets with `M0-Hold` | WSGI only; the [Quickstart](../QUICKSTART.md) is the contract |
| `--mount PREFIX=SPEC` | several applications in one process | repeatable; each mount detects its own protocol and runs in its own mode, longest prefix wins |
| `--threads N` | free-threaded CPython (3.13t+), N loops in one process | WSGI only on this toolchain: an ASGI app is refused with exit 78 ([why](ROADMAP.md#known-issues)) |
| `--reload [--reload-dir DIR]` | development | re-forks workers when a watched `.py` changes |

The modes compose the way you would hope: `--workers` multiplies whatever
each worker runs, `--realtime` sits beside a pool or a mount, and a mounted
server mixes a WSGI pool with an ASGI executor in one process. The design
behind the split is [Why two execution modes](WSGI_VS_ASGI.md).

## The realtime contract, in one paragraph

Under `--realtime`, a sync view approves a held connection by answering with
`M0-Hold: stream` (SSE) or `M0-Hold: websocket` and `M0-Channel: NAME`; the
server holds it from there. `from m0serve import m0pub; m0pub.publish(NAME,
data)` from any view, command or cron job reaches every subscriber on every
worker. Inbound WebSocket messages arrive at the application as a `POST` to
`/ws/message` with `M0-Channel`, `M0-Slot` and `M0-Opcode` headers; that view
must be CSRF-exempt. Channel names beginning with a control byte are
reserved and refused. The [Quickstart](../QUICKSTART.md) builds all of it.

One framework-specific line: in Flask the socket route is declared
`@app.route("/ws", websocket=True)`, because Werkzeug's router answers 400
to a request carrying `Upgrade: websocket` on an ordinary rule before any
view runs. Django has no such check. [After the quickstart](QUICKSTART_NEXT.md)
has the Flask version of the whole thing, and CI drives that exact file.

## In front of it

- **Terminate TLS at a proxy.** There is no TLS and no HTTP/2 here, by
  design. Fly, nginx, Caddy and a cloud load balancer all speak HTTP/1.1 to
  the app.
- **Keep held connections alive through the proxy.** `M0_SSE_HEARTBEAT_MS`
  sends a comment on idle SSE streams and a ping on idle WebSockets at that
  cadence; set it below the proxy's idle timeout (25000 for a proxy that
  closes at 60 s).
- **Static files.** `--static PREFIX=DIR` serves a directory from the server
  with `sendfile`, ETags and byte ranges, never entering Python; a miss falls
  through to the application. `--static-cache-control V` sets the header.
- **Health.** `--health-path PATH` answers a liveness JSON in the server.

## Observability

- `--access-log` prints one JSON line per response.
- `--metrics` serves Prometheus exposition at `/__metrics`, with latency
  histograms.
- `--doctor` prints the whole resolved configuration as JSON and starts
  nothing. It exits with the code the server itself would use for the same
  arguments, so it answers "will this run?" in a CI step.

## Limits and lifecycle

- `--max-body SIZE` caps request bodies (default 4m; `512k`, `64m`, `1g`).
  A chunked body is bounded on the wire as well as decoded.
- `--idle-timeout SECONDS` closes idle keep-alive connections (default 60,
  0 = never). It also bounds a WebSocket's wait for the peer's close reply.
- **SIGTERM drains.** In-flight requests finish, held connections close, and
  the process exits 0 well inside a container's stop grace. Under
  `--workers`, signalling the supervisor reaps the workers. m0serve runs as
  PID 1 correctly.
- **Exit codes.** 2 is a usage error, 1 a startup failure, 78 a
  configuration the interpreter cannot run; each prints one sentence naming
  the fix.

## Configuration precedence

Every flag has an `M0_*` variable (`M0_HOST`, `M0_PORT`, `M0_WORKERS`,
`M0_THREADS`, `M0_BLOCKING_THREADS`, `M0_ACCESS_LOG`, `M0_SSE_HEARTBEAT_MS`,
`M0_APP_TICK_MS`). A flag beats the variable, which beats the default, and
flags are strict: `--port 80eighty` is a usage error, never a silent default.

## Platforms

macOS arm64 (13+), Linux x86_64 and aarch64 (glibc; the exact floor is in
the wheel filename, and `pip` declines an older system rather than crash).
CPython 3.10 to 3.14, free-threaded builds included for WSGI. No Windows, no
musl, no Intel Mac.
