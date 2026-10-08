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
imported and, for ASGI, after its lifespan startup has completed:

```text
🔥 m0serve: myproject.wsgi:application on http://0.0.0.0:8000 (protocol=wsgi workers=1) blocking-threads=8 (auto)
```

An application that fails to import, or whose lifespan startup fails (it
sends `lifespan.startup.failed`, as Starlette and FastAPI do when a startup
handler raises), prints the error and exits 1 before that line; uvicorn
exits 3 for the same failure. For orchestration, use `--health-path /health` (answered in the
server, before Python) or a TCP check, not the banner.

Before its banner each worker prints `[worker N] pid=P armed for a
graceful stop`, the Mojo host's line: a SIGTERM drains it from then on, and
kills it before then. Between the two, while an ASGI application's lifespan
startup runs, SIGTERM or SIGINT ends the worker with exit 0 and nothing
served; under `M0_INVERTED=1` a stop waits for the startup to finish. A script that stops the server soon after starting it
waits for that line from every worker, since one worker answering says
nothing of another still importing the application.

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
| `--spawn-workers` | a worker uses Core ML, Objective-C, MAX's parallel runtime (a Mojo mount that calls `parallelize`: `--workers N` and `--reload` refuse it otherwise, exit 2) or anything else a forked child cannot | each worker execs the binary afresh after the fork; same supervisor, one extra process start per worker |
| `--blocking-threads N` | you want more or fewer handler threads per loop | more threads overlap only work that releases the GIL — a database driver, a codec, numpy — never pure Python ([which yours is](WSGI_VS_ASGI.md)); `0` turns the pool off; for ASGI, `N>0` selects the buffered path instead of the executor |
| `--realtime` | sync views hold SSE streams or WebSockets with `M0-Hold` | WSGI only; the [Quickstart](../QUICKSTART.md) is the contract. Keeps the default pool: a view holds its stream from a pool thread and the loop keeps every held connection, so one slow view stalls nothing. Through 1.4.0 the flag turned the pool off, so every view ran on the loop; `--blocking-threads 0` is that shape by name |
| `--mount PREFIX=SPEC` | several applications in one process | repeatable; each mount detects its own protocol and runs in its own mode, longest prefix wins |
| `--mount PREFIX=hold` | a stream held against a grant the application signed | needs `--realtime` and `M0_GRANT_KEY`; the application renders `m0serve.grant.stream_url(PREFIX, channel, session=...)` into an `EventSource` and the mount holds on a Mojo pool thread, never asking Python; `M0_GRANT_KEY_PREV` rotates the key, `M0_GRANT_COOKIE` names the session cookie (`sessionid`); [the note](notes/grant-verified-holds.md) |
| `--threads N` | free-threaded CPython (3.13t+), N loops in one process | WSGI only on this toolchain: an ASGI app is refused with exit 78 ([why](ROADMAP.md#known-issues)) |
| `--reload [--reload-dir DIR]` | development | re-forks workers when a watched `.py` changes |
| `M0_INVERTED=1` | an ASGI app on **one** usable CPU | environment variable, not a flag: the Mojo event loop runs inside the asyncio loop on one thread instead of beside it on two. Unmounted, pool-free ASGI without `--realtime` only. [Measured](notes/inversion-on-a-constrained-box.md): 1.14x the default at saturation on one CPU, and slower than it from two cores up. At 16 connections it is the most work per core in every environment measured, and on Linux the most requests too ([the record](notes/asgi-per-core.md)) |

The modes compose the way you would hope: `--workers` multiplies whatever
each worker runs, `--realtime` sits beside a pool or a mount, and a mounted
server mixes a WSGI pool with an ASGI executor in one process. The design
behind the split is [Why two execution modes](WSGI_VS_ASGI.md).

`--doctor` reports which loop an ASGI deployment resolved to as
`topology.loop` — `pump` (the default, two threads), `inverted`, or `n/a`
where no executor serves the application. It reported `mode: single` for
both shapes until 2026-09-08, so the only way to tell them apart was the
startup banner.

## The realtime contract

Under `--realtime`, a sync view approves a held connection by answering with
`M0-Hold: stream` (SSE) or `M0-Hold: websocket` and `M0-Channel: NAME`; the
server holds it from there. `from m0serve import m0pub; m0pub.publish(NAME,
data)` from any view, command or cron job reaches every subscriber on every
worker. Inbound WebSocket messages arrive at the application as a `POST` to
`/ws/message` with `M0-Channel`, `M0-Slot` and `M0-Opcode` headers; that view
must be CSRF-exempt. Channel names beginning with a control byte are
reserved and refused. The [Quickstart](../QUICKSTART.md) builds all of it.

**A hold replays what the journal holds, and says when it cannot.** Event
ids are numbered from one counter across every worker, and each loop
journals the last `--replay-frames` published frames (`M0_REPLAY_FRAMES`,
default 64; 0 keeps none). A client that reconnects with `Last-Event-ID`
is not re-sent what it already has, and is sent every frame of its channel
published while it was away — a phone asleep, a proxy that dropped the
stream — in order, before anything live. When the journal cannot supply
all of them (the client is further behind than the journal is deep, the
worker it reached was started after the frames went out, or the id is from
a server that has since restarted and numbered from 1 again) it is sent
none of them and one unnumbered `event: m0-gap` frame, whose data names the
id it presented and the newest id allocated; the live feed follows. A client
that listens for `m0-gap` and fetches the current state needs no poll
beside the stream. The journal is per process and in memory: a restart
begins it empty, and the gap frame is what a client reconnecting across
one receives. A first connection, without the header, starts from the live
feed. The Mojo-side `DatastarStream` keeps a journal of its own with the
same all-or-nothing rule (README, "SSE replay is journal-deep").

Work that has to outlive its request can publish from a child process the
view starts. Pass the bus and the event-id page by descriptor:
`subprocess.Popen([...], pass_fds=m0pub.child_fds())`. The child's frames are
then numbered from the same counter as every worker's, so a client that
reconnects with `Last-Event-ID` is not re-sent one it already has. With only
`m0pub.bus_write_fds()` passed, the child still publishes, unnumbered. Up to 1.3.0 that second form was unsafe: a child that
inherited the environment took an event id at an address in its parent's
memory, and either died with SIGSEGV or published a wrong id that
subscribers then dropped (#322). There, remove `M0_SHARED_ID_ADDR` from the
child's environment.

One framework-specific line: in Flask the socket route is declared
`@app.route("/ws", websocket=True)`, because Werkzeug's router answers 400
to a request carrying `Upgrade: websocket` on an ordinary rule before any
view runs. Django has no such check. [After the quickstart](QUICKSTART_NEXT.md)
has the Flask version of the whole thing, and CI drives that exact file.

## In front of it

- **Terminate TLS at a proxy.** There is no TLS and no HTTP/2 here, by
  design. Fly, nginx, Caddy and a cloud load balancer all speak HTTP/1.1 to
  the app.
- **Held connections are kept alive through the proxy by default.** Every
  15 s an idle SSE stream gets a comment and an idle WebSocket a ping
  (`M0_SSE_HEARTBEAT_MS`, default `15000`). Set the variable only to change
  the cadence, and keep it below the proxy's idle timeout: a proxy that
  closes at 60 s is fine with the default, and `25000` would be too.
- **A client that vanishes from a quiet stream is dropped in about a
  minute.** A stream's socket has TCP keepalive on: after 15 s with
  nothing received the kernel probes the client every 15 s, and closes the
  connection at the third probe left unanswered. That covers the streams
  the comment above does not reach: one your ASGI application writes
  itself, while it has nothing to send, and any stream with the heartbeat
  set to `0`. `M0_STREAM_KEEPALIVE_S` sets the seconds; `0` turns it off.
  A stream the server heartbeats is dropped when the heartbeat goes
  unanswered for as long as the kernel retries, about 16 minutes on Linux
  at its defaults.
- **Static files.** `--static PREFIX=DIR` serves a directory from the server
  with `sendfile`, ETags and byte ranges, never entering Python; a miss falls
  through to the application. `--static-cache-control V` sets the header on
  successes. `--static-header 'Name: value'`, repeatable, adds a header to
  every static response, errors included: the security headers an
  application's middleware sets, which static responses never pass through.
  Every static response carries `X-Content-Type-Options: nosniff`. The
  type comes from the extension (the web's page, image, font, media and
  data formats, Markdown as `text/markdown`); an extension the server does
  not list is sent as `application/octet-stream`, which a browser
  downloads when the file is opened directly. An SVG carries a
  `Content-Security-Policy` that sandboxes it: opened directly or framed,
  a script inside it cannot act as your site, which matters for any SVG
  you did not write, uploads above all. In an `<img>`, a CSS background or
  a `<use>` sprite it renders as before. A `--static-header` naming
  `Content-Security-Policy` replaces it, on every static response.
- **Health.** `--health-path PATH` answers a liveness JSON in the server.
- **IPv6.** `--host ::` listens on IPv6 and IPv4 at once, and `--host ::1`
  on the IPv6 loopback alone (`[::1]`, as a URL writes it, is read the same).
  Fly's private network reaches an app on its `.internal` address only over
  IPv6, so an app a sibling calls there listens on `::`. An IPv4 client of
  `::` is reported as IPv4 (`127.0.0.1`), as a `0.0.0.0` listener reports
  it.

## Observability

- `--access-log` prints one JSON line per response:
  `{"time":"2026-10-04T17:02:51.789Z","level":"INFO","msg":"access","method":"GET","path":"/","status":200,"dur_us":1234,"bytes":64,"remote_addr":"127.0.0.1"}`.
  `time` is the wall clock in UTC, with milliseconds. `status`, `dur_us`
  (microseconds from the request's headers to its response being sent; a
  stream's, to its head) and `bytes` (the body as sent, a file's included,
  nothing for a HEAD) are numbers.
  `remote_addr` is the client's address as the application sees it, and is
  left out when the server could not read one.
- `--metrics` serves Prometheus exposition at `/__metrics`, with latency
  histograms.
- `--doctor` prints the whole resolved configuration as JSON and starts
  nothing. It exits with the code the server itself would use for the same
  arguments, so it answers "will this run?" in a CI step.

## Limits and lifecycle

- `--max-body SIZE` (or `M0_MAX_BODY`) caps request bodies (default 4m;
  `512k`, `64m`, `1g`). A chunked body is bounded on the wire as well as
  decoded. Over the cap
  the server answers `413` itself, as plain text, before the application
  runs, so an application that formats its own errors (Flask's
  `MAX_CONTENT_LENGTH` with a JSON error handler, say) keeps that shape
  only with its own limit set below this one. The refusal goes out while
  the client is still uploading; the server then reads and discards the
  rest for up to five seconds, so a client that writes its whole body
  before it reads, as `http.client` and `requests` do, still gets the
  `413`. The first such refusal prints one line naming the cap and both
  knobs; the application's own log never sees the request.
- `--idle-timeout SECONDS` closes idle keep-alive connections (default 60,
  0 = never). It also bounds a WebSocket's wait for the peer's close reply
  and a refused upload's linger; at 0 both close at once. And it bounds a
  response the client stops reading: one that goes that long without a
  send making progress is closed, however long a response read steadily
  takes.
- `--body-timeout SECONDS` (or `M0_BODY_TIMEOUT`) refuses a request body
  still arriving that long after its headers (default 30, 0 = never): `408`
  on a connection's first request, then the connection closes. The first
  such refusal prints one line naming the timeout and both knobs.
- `--max-keepalive-requests N` (or `M0_MAX_KEEPALIVE_REQUESTS`) closes a
  keep-alive connection after N requests (0 = never). Every close is a
  reconnect for the client, and one reconnect per N requests is the
  client's tail at the 1/N quantile — which is how a cap of 100 was found
  to be the fast route's p99 on a loopback benchmark
  ([notes/pool-tail.md](notes/pool-tail.md)).
- **SIGTERM drains.** In-flight requests finish, held connections close, and
  the process exits 0 well inside a container's stop grace. Under
  `--workers`, signalling the supervisor reaps the workers. m0serve runs as
  PID 1 correctly.
- **Exit codes.** 2 is a usage error, 1 a startup failure, 78 a
  configuration the interpreter cannot run; each prints one sentence naming
  the fix.

## Configuration precedence

These flags have an `M0_*` variable: `--host`, `--port`, `--workers`,
`--threads`, `--blocking-threads`, `--access-log`, `--qos`,
`--spawn-workers`, `--max-body`, `--body-timeout`, `--replay-frames`,
`--max-keepalive-requests` and `--pg-listen`, each named in `--help`.
`M0_SSE_HEARTBEAT_MS` and `M0_APP_TICK_MS` have no flag. A flag beats the
variable, which beats the default. Flags are strict: `--port 80eighty` is
a usage error. Variables are lenient: `M0_PORT=80eighty` serves on the
default port, and m0serve prints a line at startup naming the value it
ignored and what it used instead. A port outside 1-65535, 0 among them, is
read and then refused with 78, whether `--port` or `M0_PORT` names it.
`--doctor` prints the values the server would use.

## Coming from uvicorn

What a uvicorn command line does not show. `m0serve --doctor APP` prints
the values this server would use, and `m0serve --help` names every flag.

- **A request body is buffered, and capped.** It arrives whole before the
  application runs, and one over `--max-body` (`M0_MAX_BODY`) is answered
  `413` without reaching it. uvicorn streams bodies and caps none.
  [Limits and lifecycle](#limits-and-lifecycle).
- **A body that stops arriving is refused** after `--body-timeout`
  (`M0_BODY_TIMEOUT`). uvicorn has no body timer.
- **An idle keep-alive connection is kept longer** than uvicorn's
  `--timeout-keep-alive` keeps it: `--idle-timeout`.
- **The access log is off until `--access-log`** (`M0_ACCESS_LOG`), and is
  JSON lines ([its fields](#observability)). uvicorn logs requests by
  default, as text.
- **Forwarded headers are not applied.** The client is the socket's peer
  and the scheme `http`; `X-Forwarded-For` and `X-Forwarded-Proto` reach
  the application as ordinary headers, for it to trust (Django's
  `SECURE_PROXY_SSL_HEADER`, Werkzeug's `ProxyFix`, or uvicorn's own
  `ProxyHeadersMiddleware` around an ASGI application). uvicorn applies
  them for the proxies `--forwarded-allow-ips` names.
- **A lifespan startup that fails exits 1**, where uvicorn exits 3
  ([Install and start](#install-and-start)).
- **ASGI needs a GIL-enabled CPython.** A free-threaded build, which uv may
  pick for a project with no pin, is refused with exit 78
  ([why](ROADMAP.md#known-issues)). With uv, put `3.13` in
  `.python-version`; the refusal says so too.

## Platforms

macOS arm64 (13+), Linux x86_64 and aarch64 (glibc; the exact floor is in
the wheel filename, and `pip` declines an older system rather than crash).
CPython 3.10 to 3.14, free-threaded builds included for WSGI. No Windows, no
musl, no Intel Mac.
