# Running m0serve

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
`MODULE` tries `MODULE:application`, `MODULE.asgi:application`,
`MODULE.wsgi:application`, `MODULE:app` and `MODULE.main:app`, in that
order. `--app-dir DIR` is
prepended to `sys.path` and defaults to the current directory.

The protocol is detected from the object: a coroutine-function callable is
served as ASGI, anything else as WSGI. `--protocol wsgi|asgi` overrides.

The server listens on `127.0.0.1:8000`, this machine alone, unless told
otherwise: `--host 0.0.0.0` (or `M0_HOST=0.0.0.0`) takes every IPv4
interface, which a container needs for its published port to reach the
server.

m0serve carries no interpreter. It loads the `libpython` of the `python3`
on `PATH`, so run it where that is the interpreter your application is
installed into, an activated virtualenv being the usual way;
`MOJO_PYTHON_LIBRARY` names the shared library outright. The `m0serve`
a wheel installs names its own interpreter's library itself, and exits 78
naming `MOJO_PYTHON_LIBRARY` when that interpreter has none.

The ready signal is one line per worker, printed after the application has
imported and, for ASGI, after its lifespan startup has completed:

```text
🔥 m0serve: myproject.wsgi:application on http://127.0.0.1:8000 (protocol=wsgi workers=1) blocking-threads=8 (auto)
```

An application that fails to import, or whose lifespan startup fails (it
sends `lifespan.startup.failed`, as Starlette and FastAPI do when a startup
handler raises), prints the error and exits 1 before that line. For
orchestration, use `--health-path /health` (answered in the server, before
Python) or a TCP check.

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
| `--spawn-workers` | a worker uses Core ML, Objective-C, MAX's parallel runtime or anything else a forked child cannot. Without it, `--workers N` and `--reload` refuse a Mojo mount that calls `parallelize`, with exit 2 | each worker execs the binary afresh after the fork; same supervisor, one extra process start per worker |
| `--blocking-threads N` | you want more or fewer handler threads per loop | more threads overlap only work that releases the GIL, such as a database driver, a codec or numpy, and never pure Python ([which yours is](WSGI_VS_ASGI.md)). `0` turns the pool off. For ASGI, `N>0` selects the buffered path instead of the executor |
| `--realtime` | sync views hold SSE streams or WebSockets with `M0-Hold` | WSGI only; the [Quickstart](../QUICKSTART.md) is the contract. Keeps the zero-config pool: a view holds its stream from a pool thread and the loop keeps every held connection, so one slow view stalls nothing. `--blocking-threads 0` runs every view on the loop |
| `--mount PREFIX=SPEC` | several applications in one process | repeatable; each mount detects its own protocol and runs in its own mode, longest prefix wins |
| `--mount PREFIX=hold` | a stream held against a grant the application signed | needs `--realtime` and `M0_GRANT_KEY`; the application renders `m0serve.grant.stream_url(PREFIX, channel, session=...)` into an `EventSource` and the mount holds on a Mojo pool thread, never asking Python; `M0_GRANT_KEY_PREV` rotates the key, `M0_GRANT_COOKIE` names the session cookie (`sessionid`); [the note](notes/grant-verified-holds.md) |
| `--threads N` | free-threaded CPython (3.14t or newer, GIL off), N loops in one process | WSGI only on this toolchain: an ASGI app is refused with exit 78 ([why](ROADMAP.md#known-issues)) |
| `--reload [--reload-dir DIR]` | development | re-forks workers when a watched `.py` changes |
| `--qos` (`M0_QOS`) | on macOS under CPU contention | the loop runs at user-interactive QoS and pool and executor threads at user-initiated, which keeps them on performance cores; ignored elsewhere |
| `M0_INVERTED=1` | an ASGI app on **one** usable CPU | environment variable, not a flag: the Mojo event loop runs inside the asyncio loop on one thread instead of beside it on two. Unmounted, pool-free ASGI without `--realtime` only. Where it wins and where it loses: [Benchmarks](BENCHMARKS.md) |

Any topology flag or `M0_*` topology variable turns the zero-config pool
off for an unmounted application: `--workers 4` alone runs each worker's
views on its loop, and `--workers 4 --blocking-threads 8` keeps a pool of
eight per worker. A mount set that cannot run without handler threads (a
Mojo or hold mount, or an ASGI mount beside a WSGI one) keeps its pool.
`--realtime` sits beside a pool or a mount, and a mounted server mixes a
WSGI pool with an ASGI executor in one process. The design behind the split
is [Why two execution modes](WSGI_VS_ASGI.md).

A mount's prefix reaches its application the way its protocol expects:
`SCRIPT_NAME`, with `PATH_INFO` trimmed, for WSGI, and `root_path` beside
the whole `path` for ASGI, so `reverse()` and `url_for()` build links that
work under it. A path no mount claims is answered `404` by the server,
never entering Python. Each ASGI mount gets an executor of its own, and the
WSGI mounts share the pool.

`--doctor` reports which loop an ASGI deployment resolved to as
`topology.loop` — `pump` (the default, two threads), `inverted`, or `n/a`
where no executor serves the application.

## The realtime contract

Under `--realtime`, a sync view approves a held connection by answering with
`M0-Hold: stream` (SSE) or `M0-Hold: websocket` and `M0-Channel: NAME`; the
server holds it from there. `from m0serve import m0pub; m0pub.publish(NAME,
data)` from any view, command or cron job reaches every subscriber on every
worker. Inbound WebSocket messages arrive at the application as a `POST` to
`/ws/message` with `M0-Channel`, `M0-Slot` and `M0-Opcode` headers; that view
must be CSRF-exempt. Channel names beginning with a control byte are
reserved and refused. The [Quickstart](../QUICKSTART.md) builds all of it.

**A held WebSocket opens from its own origin.** A browser attaches the
site's cookies to a WebSocket whatever page opens it, and the same-origin
policy that keeps another page from reading a `fetch` does not cover one.
So a handshake whose `Origin` names another host than the request's `Host`
(or the first `X-Forwarded-Host`) is answered `403`, whatever the view
approved, and the first refusal prints a line naming the origin. A handshake
without `Origin`, which no browser sends, is upgraded. `--ws-origin ORIGIN`,
repeatable, names an origin beside the server's own, such as a front end on
another port in development (`M0_WS_ORIGIN` takes a comma-separated list;
`*` allows every origin). Behind a proxy that
rewrites `Host` and sets no `X-Forwarded-Host`, nginx's default among them,
name the public origin or forward the host (`proxy_set_header Host $host`).
An ASGI application accepts its own sockets, and checks their origin
itself as it would under uvicorn.

**A hold replays what the journal holds, and says when it cannot.** Event
ids are numbered from one counter across every worker, and each loop
journals the last `--replay-frames` published frames (`M0_REPLAY_FRAMES`,
default 64; 0 keeps none; at most 4096, since a loop holds up to that
many frames of up to 64 KB each and m0serve refuses more with exit 78,
as does `--doctor`). A client that reconnects with `Last-Event-ID`
is not re-sent what it already has, and is sent every frame of its channel
published while it was away (a phone asleep, a proxy that dropped the
stream), in order, before anything live. When the journal cannot supply
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
`m0pub.bus_write_fds()` passed, the child still publishes, unnumbered.

**Across machines, Postgres `NOTIFY` is the bus.** `--pg-listen URL`
(`M0_PG_LISTEN`) holds one `LISTEN` on worker 0, on the Postgres channel
`m0`, and publishes each notification to the held streams of the channel
its payload names. A publisher runs
`cur.execute(*m0pub.notify_sql(channel, data, event=None))` on a connection
it already has. A trigger or `psql` sends `pg_notify('m0', payload)`, where
the payload is a JSON object of strings, at most 7999 bytes: `channel`,
required, and `event` and `data`, each empty when absent. A payload that is
not such an object, or whose field holds another type (`row_to_json(NEW)`
where `row_to_json(NEW)::text` was meant), is refused and counted. `NOTIFY`
is delivered at commit, so a publish inside a transaction that rolls back
is never sent. The flag needs `--realtime` (exit 2). On macOS it is refused
wherever a worker is forked (`--workers N`, `--reload`; exit 2), and
`--spawn-workers` lifts that. A host with no libpq exits 78; `M0_LIBPQ`
names the library.

One framework-specific line: in Flask the socket route is declared
`@app.route("/ws", websocket=True)`, because Werkzeug's router answers 400
to a request carrying `Upgrade: websocket` on an ordinary rule before any
view runs. Django has no such check. [After the quickstart](QUICKSTART_NEXT.md)
has the Flask version of the whole thing.

## In front of it

- Terminate TLS at a proxy. The server speaks plain HTTP/1.1. Fly, nginx,
  Caddy and a cloud load balancer all speak HTTP/1.1 to the app.
- Compression is the proxy's, and a stream needs two things from it.
  The server sends no `Content-Encoding` (SPEC J8). A proxy that
  compresses a held SSE stream must flush at every event, or the stream
  stalls, and must keep one compression
  context for the life of the connection, or repeated whole-state frames
  (`DatastarStream(send_latest=True)`) gain nothing from the frames
  before them. Caddy's `encode` and nginx's `gzip` can be set either way;
  check the proxy's streaming behaviour with `curl -N --compressed`
  before trusting it on a stream. Fly's proxy leaves a stream alone;
  a Mojo application's stream can compress itself
  (SPEC I45).
- A header whose name holds an underscore is dropped before a WSGI
  application sees it, so behind HAProxy, Caddy or Traefik, which forward
  such names, a client's `X_Forwarded_For` cannot replace the proxy's
  `X-Forwarded-For`; an ASGI application under the executor receives both
  ([Coming from uvicorn](#coming-from-uvicorn)).
- Held connections are kept alive through the proxy by default. Every
  15 s an idle SSE stream gets a comment and an idle WebSocket a ping
  (`M0_SSE_HEARTBEAT_MS`, default `15000`). Set the variable only to change
  the cadence, and keep it below the proxy's idle timeout: a proxy that
  closes at 60 s is fine with the default, and `25000` would be too.
- An SSE event is followed by a comment. 150 ms after an event goes out
  on a stream the server holds, it sends `: flush`, unless another event
  went first, so a stream at 7 Hz or faster is sent none. Behind an HTTP/2
  proxy that forwards an event in two pieces, Safari's `fetch` reader holds the second piece until a third arrives,
  and Datastar reads its streams through `fetch` (SPEC I47).
  `M0_SSE_FLUSH_MS` sets the delay; `0` turns it off. A stream your ASGI
  application writes itself gets none.
- A client that vanishes from a quiet stream is dropped in about a
  minute. A stream's socket has TCP keepalive on: after 15 s with
  nothing received the kernel probes the client every 15 s, and closes the
  connection at the third probe left unanswered. That covers the streams
  the comment above does not reach: one your ASGI application writes
  itself, while it has nothing to send, and any stream with the heartbeat
  set to `0`. `M0_STREAM_KEEPALIVE_S` sets the seconds; `0` turns it off.
  A stream the server heartbeats is dropped when the heartbeat goes
  unanswered for as long as the kernel retries, about 16 minutes on Linux
  at its defaults.
- `--static PREFIX=DIR` serves a directory from the server
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
- `--health-path PATH` answers a liveness JSON in the server.
- `--host ::` listens on IPv6 and IPv4 at once, and `--host ::1`
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
- `M0_THREAD_HEADER=1` names the handler-pool thread that served each
  response in an `x-thread` header, for matching interleaved log lines to
  responses. It is off by default. The server's own `Server` header is
  `mojo-http`; an application that sets one sends only its own.
- `--doctor` prints the whole resolved configuration as JSON and starts
  nothing. It exits with the code the server itself would use for the same
  arguments, so it answers "will this run?" in a CI step. The JSON names
  the platform, the interpreter and its virtualenv, the application spec
  discovery chose and the protocol it classified, the resolved topology,
  and a `checks` array whose failures each carry a `detail`, a `fix` and
  the `exit` that check causes. With no application, `m0serve --doctor`
  checks the environment alone.
- `--version` prints `m0serve X.Y.Z`.

## Limits and lifecycle

- `--max-connections N` (or `M0_MAX_CONNECTIONS`) is the connections one
  event loop holds open at once: 1024 by default, at most 65536. It counts
  per loop, so `--workers 4` holds four times as many, and so does
  `--threads 4`. **Streams leave a reserve:** held SSE streams and
  WebSockets take all but a sixteenth of the slots, at most 16 (1008 of
  the default 1024). The stream after that is answered `503` with
  `Retry-After: 5`, so the health path and ordinary requests are still
  answered while streams hold the rest. The first refused stream prints
  one line naming the knob; `/__metrics` counts `http_streams_held` and
  `http_streams_refused_total`, and `--doctor` reports `max_connections`
  and `stream_limit`. **A full loop takes a slot back.** A connection that
  finds every slot in use gets the slot of the connection idle longest
  between requests, once that one has been idle a second; that connection
  is closed as `--idle-timeout` closes it. With none idle that long, it
  gets the slot of the connection that has spent longest sending its
  request's head, once that is a second; that connection is answered
  `408`, as the header timeout answers it. With neither, the new
  connection is refused at accept and closed unread. A stream, a body
  arriving, a response going out and a request being answered are never
  taken. With `--idle-timeout 0`, no idle connection is taken. The first
  full loop prints one line saying what it takes back; `/__metrics` counts
  `http_connections_reclaimed_total` and `http_connections_refused_total`.
  Idle streams cost a WSGI server's requests nothing: each pass drains only
  the streams with something to send, and `/__metrics` counts
  `http_stream_drain_visits_total`, one per stream drained. Under the ASGI
  executor's default loop each pass still visits every stream. A browser's
  `EventSource` does not reconnect after a `503`, as it does after a
  dropped connection, so a page that should keep trying listens for
  `error` and reconnects itself.
- **The server raises its own open-file limit** to what its connections
  need (each loop's count, twice on Linux, where a stream's heartbeat
  timer is a descriptor of its own; what the server holds itself; and 256) before
  it binds, so launchd's default of 256 and systemd's soft 1024 do not
  cap it below `--max-connections`. It never lowers the limit or passes
  the hard one, or on macOS `kern.maxfilesperproc`. Where the hard limit
  stops it short, **each loop holds what the limit leaves**, and its stream
  reserve is kept from that, so the health path is still answered when
  streams fill it: it prints the limit, what it wanted, what a loop holds
  and the fix (`ulimit -Hn`, systemd's `LimitNOFILE=`); `--doctor` reports
  the fitted `max_connections` and `descriptor_limit` beside
  `descriptors_wanted`. A hard limit too low for
  the server's own startup (its pool's channels, the bus, the loop) and a
  few connections beside is refused with 78 before anything starts, the
  line naming what the configuration holds; fewer `--blocking-threads`
  lower that.
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
- **A WSGI body the application did not size streams; a sized one is
  buffered.** A generator or iterator with no `Content-Length` (Django's
  `StreamingHttpResponse`, a Flask `Response(generator)`) is sent from a
  pool thread as it is produced: chunked on HTTP/1.1, close-delimited on
  HTTP/1.0, `close()` called, and the thread back in the pool when the
  client leaves. A body with a `Content-Length` (every Flask page, Django
  behind `CommonMiddleware`, `FileResponse`) and every list body is
  buffered and sent with its measured length, as is every body on a server
  with no pool (`--blocking-threads 0`). A generator that raises after its
  head ends the connection without the chunked terminator, so the client
  sees a truncated body.
- `--idle-timeout SECONDS` closes idle keep-alive connections (default 60,
  0 = never). The idle sweep also ends two lingers, which run only while
  the timeout is above 0: a WebSocket this side closed waits up to 2 s for
  the peer's Close, and a refused upload is read and discarded for up to
  5 s. At 0 both close at once. The timeout also bounds a response the
  client stops reading: one that goes that long without a
  send making progress is closed, however long a response read steadily
  takes.
- `--body-timeout SECONDS` (or `M0_BODY_TIMEOUT`) refuses a request body
  still arriving that long after its headers (default 30, 0 = never): `408`
  on a connection's first request, then the connection closes. The first
  such refusal prints one line naming the timeout and both knobs.
- `--max-keepalive-requests N` (or `M0_MAX_KEEPALIVE_REQUESTS`) closes a
  keep-alive connection after N requests (default 1000, 0 = never). Every
  close is a reconnect for the client, so a cap of N puts one reconnect in
  the client's tail at the 1/N quantile
  ([the measurement](notes/pool-tail.md)).
- **SIGTERM drains.** In-flight requests finish, held connections close, and
  the process exits 0 well inside a container's stop grace. Under
  `--workers`, signalling the supervisor reaps the workers. m0serve runs as
  PID 1 correctly.
- **Exit codes.** 2 is a command line that cannot be read or a flag
  combination wrong on any machine, 1 a startup failure (the application's
  import or lifespan, the bind), 78 a configuration this machine or build
  cannot serve (a value above its cap, a port out of range, a missing
  library, an interpreter the mode cannot use); each prints one sentence
  on stderr naming the fix.

## Configuration precedence

These flags have an `M0_*` variable: `--host`, `--port`, `--workers`,
`--threads`, `--blocking-threads`, `--access-log`, `--qos`,
`--spawn-workers`, `--max-body`, `--body-timeout`, `--max-connections`,
`--replay-frames`, `--max-keepalive-requests`, `--ws-origin` and
`--pg-listen`, each named in `--help`. These variables have no flag:
`M0_SSE_HEARTBEAT_MS`, `M0_SSE_FLUSH_MS`, `M0_STREAM_KEEPALIVE_S`,
`M0_THREAD_HEADER`, `M0_INVERTED`, `M0_GRANT_KEY`, `M0_GRANT_KEY_PREV` and
`M0_GRANT_COOKIE`. A flag beats the
variable, which beats the default. Flags are strict: `--port 80eighty` is
a usage error. Variables are lenient: `M0_PORT=80eighty` serves on the
default port, and m0serve prints a line at startup naming the value it
ignored and what it used instead. A port outside 1-65535, 0 among them, is
read and then refused with 78, whether `--port` or `M0_PORT` names it.
`--doctor` prints the values the server would use.

## Coming from uvicorn

What a uvicorn command line does not show. `m0serve --doctor APP` prints
the values this server would use, and `m0serve --help` names every flag.

- A request body is buffered, and capped. It arrives whole before the
  application runs, and one over `--max-body` (`M0_MAX_BODY`) is answered
  `413` without reaching it. uvicorn streams bodies and caps none.
  [Limits and lifecycle](#limits-and-lifecycle).
- A body that stops arriving is refused after `--body-timeout`
  (`M0_BODY_TIMEOUT`). uvicorn has no body timer.
- An idle keep-alive connection is kept longer than uvicorn's
  `--timeout-keep-alive` keeps it: `--idle-timeout`.
- The access log is off until `--access-log` (`M0_ACCESS_LOG`), and is
  JSON lines ([its fields](#observability)). uvicorn logs requests by
  default, as text.
- Forwarded headers are not applied. The client is the socket's peer
  and the scheme `http`; `X-Forwarded-For` and `X-Forwarded-Proto` reach
  the application as ordinary headers, for it to trust (Django's
  `SECURE_PROXY_SSL_HEADER`, Werkzeug's `ProxyFix`, or uvicorn's own
  `ProxyHeadersMiddleware` around an ASGI application). uvicorn applies
  them for the proxies `--forwarded-allow-ips` names. A header whose name
  holds an underscore never reaches a WSGI application, as under gunicorn:
  CGI's mapping would file a client's `X_Forwarded_For` under the
  proxy's `HTTP_X_FORWARDED_FOR`. An ASGI application under the executor
  receives both spellings as sent, as the ASGI spec requires; under
  `--blocking-threads` above 0 its scope is built from the same environ
  on the buffered path, and underscore names are dropped as for WSGI.
- A lifespan startup that fails exits 1, where uvicorn exits 3
  ([Install and start](#install-and-start)).
- ASGI needs a GIL-enabled CPython. A free-threaded build is refused
  with exit 78 ([why](ROADMAP.md#known-issues)), and uv can land on one
  unasked: a `3.14` pin is satisfied by 3.14t, which uv picks where it is
  the only 3.14 installed, and a venv already on 3.14t is kept. Install the
  GIL build beside it, then rebuild the venv on it:
  `uv python install 3.14 && uv sync --python 3.14+gil`. The refusal says
  so too.

## Platforms

macOS arm64 (13+), Linux x86_64 and aarch64 with glibc 2.35 or newer: Ubuntu
22.04, Debian 12 and RHEL 10 and later. RHEL 9 and Amazon Linux 2023 ship
glibc 2.34 and are below the floor; there `pip` declines the wheel rather
than install one that would crash. The floor is measured from the binary at
each release and is in the wheel's filename (`manylinux_2_35`). CPython 3.10
to 3.14, free-threaded builds included for WSGI. Not supported: Windows,
musl, Intel Mac.
