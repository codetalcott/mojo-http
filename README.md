# mojo-http

[![Tests](https://github.com/codetalcott/mojo-http/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/codetalcott/mojo-http/actions/workflows/test.yml)
[![Docs](https://github.com/codetalcott/mojo-http/actions/workflows/docs.yml/badge.svg?branch=main)](https://github.com/codetalcott/mojo-http/actions/workflows/docs.yml)

**Realtime from a synchronous Python app, with no added infrastructure.**

*(New here? The documentation site is [m0serve.dev](https://m0serve.dev):
the quickstart, the operations guide and the capability matrix, with
[docs/README.md](docs/README.md) as the map; for an agent, [llms.txt](llms.txt)
at the site's root indexes every page, each also served as Markdown with
`.md` in place of its trailing slash. For where the project stands,
run `uv run poe milestones` — it computes what is left for 1.0 rather than
reporting what someone last wrote down.)*

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
of a sidecar. Under gunicorn the two headers mean nothing (they are passed
through to the client) and the same view degrades to a short plain
response, so adopting it is not a fork of your codebase. The Flask version
is the same four views with one extra flag: the socket route is declared
`websocket=True`, because Werkzeug's router refuses an upgrade request on
an ordinary rule before any view runs; [After the quickstart](docs/QUICKSTART_NEXT.md) has it.

**[QUICKSTART.md](QUICKSTART.md) is ten minutes from `pip install` to live
multi-tab sync**, and CI executes every command in it on every pull request
— so it works, or the build is red.

### What else it does

- <!-- observed: docs/notes/wsgi-vs-asgi-history.md §9, pinned by smoke-hybrid -->**Several
  applications in one process, each in its native mode.**
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
- **Where it stands on throughput**, from [docs/BENCHMARKS.md](docs/BENCHMARKS.md):
  <!-- num:asgi-vs-uvloop@2 -->1.63<!-- /num -->x uvicorn with uvloop on bare ASGI at 16 connections
  (<!-- num:asgi-vs-uvicorn@2 -->2.42<!-- /num -->x `uvicorn --loop asyncio`), on <!-- num:asgi-m0-cores@1 -->1.6<!-- /num -->
  measured cores where uvicorn has one; the fast-request tail under mixed
  load ahead of uvicorn in every recorded run; and <!-- num:m0-vs-granian-rps@2 -->1.00<!-- /num -->x
  Granian on bare WSGI at one worker and one handler thread each
  (<!-- num:m0-per-granian@2 -->1.01<!-- /num -->x per measured core). Every figure is rendered from a
  dated artifact, and CI refuses one more than a minor version old.

### What it is not

- **No TLS and no HTTP/2.** Terminate at a proxy — gunicorn's answer, and
  the same one applies here.
- **The served contract is stable from 1.0** — flags and environment
  variables, the `M0-Hold`/`M0-Channel` headers, and `m0pub.publish()`.
  A minor release does not break them; everything else — the Mojo APIs,
  the package layout, the fork's internals — is still free to move
  ([CHANGELOG](CHANGELOG.md)).
- **macOS arm64 and Linux x86_64/aarch64 only.** No Intel Mac (no
  toolchain), no Windows, no musl.

---

Underneath, `mojo-http` is an HTTP/1.1 server and a small web framework for
[Mojo](https://docs.modular.com/mojo/): routing, content negotiation, ETags,
Server-Sent Events and WebSockets, with a [Datastar](https://data-star.dev/)
adapter for hypermedia UIs and SQLite and PostgreSQL bindings. The Python
server above is one package in it (`m0-wsgi`).

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
same command serves WSGI and ASGI. **Then: [QUICKSTART.md](QUICKSTART.md)**,
and [docs/RUNNING.md](docs/RUNNING.md) for every flag, mode, limit and exit
code.

**One wheel per platform covers every supported CPython**, 3.10 through 3.14
including free-threaded 3.14t. That is not a shortcut: `m0serve` does not
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

**The exact floors live in the wheel filename**, measured from the built
binary rather than copied from the toolchain's own tag, so `pip` declines
an older system rather than install something that crashes at startup. The
Linux floor is the Mojo runtime's, not the build host's
([the measurement](docs/notes/the-floor-is-the-runtime.md)).

To **write an application in Mojo** (preview), the `m0` package writes the
project and installs the toolchain into it:

```bash
uvx m0 new shop
cd shop && uv sync
uv run m0 build && bin/server --port 8080
```

[packaging/m0/QUICKSTART.md](packaging/m0/QUICKSTART.md) is that path to a
served page, tests, rebuild on save and a deploy image, executed by CI like
the one above; [docs/MOJO.md](docs/MOJO.md) is the index of its pages.

To **develop against the Mojo packages in this repository**, clone it:

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


def main() raises:
    print("Starting hello server on 0.0.0.0:8080")
    var server = Server()
    var handler = HelloHandler()
    # The non-blocking loop multiplexes keep-alive connections instead of
    # serving one at a time — measurably better tail latency under
    # concurrent clients, and the same one-liner to call.
    server.listen_and_serve_nonblocking("0.0.0.0:8080", handler)
```

`func` is the one method a handler must write. The streaming hooks (`sse_*`, shared by SSE and WebSocket slots), the `tick` timer and `ws_message` all have default bodies, so a handler declares only the hooks it uses.

## What's in the box

| Package | Description | Tests |
| --- | --- | --- |
| `m0-core` | wyhash64, SHA-256 and HMAC-SHA256, SIMD JSON escape, HTML escape, JSON field parser, a C-ABI export | 83 |
| `m0-http` | Router, content negotiation, ETag, SSE, WebSockets, CORS, config, health, logging, multi-worker supervisor, cross-worker broadcast bus, accept sharing, the Mojo host, request-parsing hardening, view table, HTML builder and fragment, fragment-or-page, url_for and Query, form bodies, signed session cookies, CSRF and a one-user login | 1166 |
| `m0-datastar` | Datastar v1.0.4 wire format, `DatastarStream` fan-out with `Last-Event-ID` replay or the newest state at open and cross-worker broadcast, `read_signals`, a `Fragment[Datastar]` inside a frame, checked against the SDK's own conformance cases | 96 |
| `m0-wsgi` | WSGI/ASGI gateway — run Django, Flask, FastHTML, or any WSGI/ASGI app on this server | 198 |
| `m0-sqlite` | SQLite bindings, libsqlite3 opened with `dlopen` rather than linked — connections, statements, typed columns, transactions, bulk read-out, array virtual table, scalar functions written in Mojo, stamps that say which rows changed | 164 |
| `m0-postgres` | PostgreSQL bindings over libpq, opened with `dlopen` rather than linked — connections, bound parameters, text and binary results, SQLSTATE, `LISTEN`/`NOTIFY` | 81 |
| **Total** | | **1788** |

Modules are named `m0_*` — `mojo-http` is the repository, `m0` is the import prefix. Every capability, with the gate that proves it, is a row of [docs/SPEC.md](docs/SPEC.md).

Strict layering, no upward imports: `m0-core` has zero dependencies, and `m0-http` imports from it, never the reverse. `m0-datastar` splits in two — `consts` and `sse` are the pure wire format with no dependencies at all, while `stream` and `signals` are the server glue and are the only parts that pull in `m0-http`. `m0-wsgi` is the only package that embeds CPython, which is exactly why it is a separate package. `m0-core` also builds the C-ABI library `m0pub` numbers its events through; it ships inside the m0serve wheel and is not an artifact of its own ([docs/FFI_DISTRIBUTION.md](docs/FFI_DISTRIBUTION.md)).

[apps/notes_api/](apps/notes_api/server.mojo) composes most of the HTTP
layer in one small app: CRUD with `:id` routes and a real `405` with
`Allow`, one note negotiated as JSON or HTML by the `Accept` header,
`ETag`/`304`, static files, RFC 9457 `problem+json` on every error, and
CORS from a single `after_response` hook. `uv run poe serve-notes` runs it;
`poe smoke-notes` asserts each feature end to end.

[apps/fragment_notes/](apps/fragment_notes/server.mojo) is the same
resource as a server-rendered htmx app, and the reference for the
application layer: views a URL table names, fragments that name themselves,
page-or-fragment decided from the request's headers, `comptime` routes
reversed by `url_for`, and a signed-cookie login with CSRF from
`m0_http.login`. [docs/MOJO_VIEWS.md](docs/MOJO_VIEWS.md) is that layer's
page; `poe smoke-fragment-notes` pins the app's wire contract, which did
not change while the app was refactored onto each piece
([a-fragment-that-names-itself](docs/notes/a-fragment-that-names-itself.md)).

## Datastar

`m0-datastar` speaks the [Datastar](https://data-star.dev/) wire format, and
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

`read_signals(req)` is the other direction — the browser sends its whole signal store, as a
`datastar` query parameter on GET and DELETE and as the body otherwise.

- [apps/datastar_counter/](apps/datastar_counter/) (`uv run poe
  serve-counter`): a button pressed in one tab updates every other, on
  every worker under `M0_WORKERS=2`. It is the reference for cross-worker
  fan-out.
- [apps/datastar_todo/](apps/datastar_todo/) (`serve-todo`): mutations
  broadcast rendered HTML that every tab morphs by id, the list is rows in
  SQLite, and the stream's frames are restored at boot, so a restart loses
  neither the list nor a reconnecting tab's place in it.
- [apps/blobs/](apps/blobs/) (`serve-blobs`): a stream of *states* rather
  than changes — a shared world stepped by a producer thread and published
  whole, so a new tab gets the current world instead of a replay. It runs
  on the Mojo host, whose `serve[H, P](AppConfig())` is an application's
  whole `main` ([docs/MOJO_HOST.md](docs/MOJO_HOST.md)).

Datastar 1.0 opens a stream from `data-init` and spells keyed attributes
with a colon — `data-on:click`, `data-bind:draft`; the hyphenated forms
fail silently. The fragment layer speaks Datastar too: `Fragment[Datastar]`
renders the same code as `Fragment[Htmx]` with Datastar's attributes
([one-renderer-two-transports](docs/notes/one-renderer-two-transports.md)).

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
proves the wire format against a from-scratch stdlib client.

[apps/ws_chat/](apps/ws_chat/server.mojo) grows that into the multi-worker
shape: `m0_http.WSHub` is the handler-side registry, and under
`M0_WORKERS>1` it rides the same `BroadcastBus` the SSE counter uses, so a
message sent on one worker's socket reaches every socket on every worker
(`poe smoke-chat`).

## Django, and anything else that speaks WSGI

`m0-wsgi` embeds CPython, and **`m0serve`** is the binary built on it, the
uvicorn-shaped entry point the top of this page installs from PyPI. From
this repository:

```bash
uv run poe build-serve                                     # -> bin/m0serve
bin/m0serve myproject.wsgi:application --app-dir /path/to/project --workers 4
```

[docs/RUNNING.md](docs/RUNNING.md) is its reference: how the callable is
found and its protocol detected, the ready line, the execution modes and
when to use each, mounts, `--realtime`, `--doctor`, limits, exit codes and
what to put in front of it. [docs/WSGI_VS_ASGI.md](docs/WSGI_VS_ASGI.md) is
why there are two execution modes, and [docs/BENCHMARKS.md](docs/BENCHMARKS.md)
how the result compares with gunicorn, uvicorn and Granian.

The example applications are Python-only projects that `bin/m0serve`
serves, each with a smoke test of its own:

- [apps/django_wsgi/](apps/django_wsgi/) and [apps/flask_wsgi/](apps/flask_wsgi/)
  run the same assertions ([scripts/wsgi_framework_contract.sh](scripts/wsgi_framework_contract.sh))
  — routing, cookies in both directions, body round trips, error
  handling — because every WSGI framework does those identically.
- [apps/wsgi_bare/](apps/wsgi_bare/) is a plain PEP 3333 callable with no
  third-party imports, the conformance target for the parts of the spec a
  framework never exercises ([docs/WSGI_CONFORMANCE.md](docs/WSGI_CONFORMANCE.md)).
- [apps/django_realtime/](apps/django_realtime/) is the realtime contract
  on Django: views hold SSE streams and WebSockets by answering with
  `M0-Hold`, publish with `m0pub`, and receive inbound WebSocket messages
  as ordinary `POST`s — Pushpin's GRIP collapsed into one process.

How the bridge crosses into CPython (each request's environ built in Mojo
through the C API, bodies moved as real `bytes`) and the rules that keep it
from leaking are [packages/m0-wsgi/AGENTS.md](packages/m0-wsgi/AGENTS.md).

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
contended write waits instead of failing on contact. It raises on a target
that cannot do WAL — `:memory:`, a temp database, some network filesystems
— rather than quietly falling back to a rollback journal; use
`open_memory()` for an in-memory database. Transactions are explicit
(`begin` / `commit` / `rollback`); there is no scope guard, because Mojo has
no `defer` and a destructor that rolled back would make correctness depend
on drop order.

**Wrap bulk writes in a transaction.** Autocommit gives each row its own
transaction, the largest single effect measured in
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
`column_blob_into` reuses a caller buffer across a scan instead of
allocating per row. `fetch_ints` / `fetch_floats` / `fetch_texts` append a
whole column into a caller-owned `List`; they are a shape convenience
rather than a speed-up — SQLite has no bulk column API — but a `List` per
column is what a SIMD pass over the results wants. They signal exhaustion
with a **short read**, so stop when you get fewer rows than you asked for
rather than looping until zero.

`prepare()` compiles exactly one statement; text after the first — or text that
compiles to nothing, like a lone comment — is an error rather than silently
ignored. Use `execute()` for a multi-statement script. Column indices are
checked: an out-of-range index raises rather than reading back as a stored
NULL.

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

**Functions written in Mojo.** `create_function` registers a type as a scalar
SQL function on a connection. It runs inside the query plan and reads each
argument where SQLite holds it, so a kernel over a large column costs the
kernel and not a copy out of the database, which sqlite-vec's
`vec_distance_l2` makes of both vectors on every call.

```mojo
struct Dot(ScalarFunction):
    comptime arity: Int = 2
    comptime deterministic: Bool = True

    def __init__(out self):
        pass

    def call(mut self, args: Args, mut answer: Answer) raises:
        answer.float(dot_f32(args.blob(0), args.blob(1)))   # SQLite's bytes, no copy

db.create_function("dot", Dot())
var q = db.prepare("SELECT id FROM notes ORDER BY dot(embedding, ?1) DESC LIMIT 10")
```

**Do not name a registered function in the schema.** SQLite refuses one in
a CHECK constraint, a generated column or an index when they are created,
but not in a view, a trigger or a column DEFAULT, and such a trigger then
fails every write to its table, from every program, until it is dropped.
What a function may and may not do, and the SQLite version each kind needs,
is [docs/notes/functions-inside-the-query.md](docs/notes/functions-inside-the-query.md).

**Loading.** libsqlite3 is opened at run time, not linked: nothing in this
repo carries it on a link line, so a binary that never opens a database
needs no library present, and `mojo run` works for every test on both
platforms. `Connection` opens it from `M0_LIBSQLITE3`, else a search path
that tries the bare name and then the places a package manager puts one; an
absent library is one error naming every path tried, and one too old, built
without threads, or missing an entry point is refused naming what it found.
Linux needs the runtime library (`libsqlite3-0` on Debian and Ubuntu); the
`-dev` package is only for the C layout guard's `sqlite3.h`.

**Stamps.** `install_stamps(db)` and `watch(db, "notes")` put four
triggers on a table, after which every row written there, by any program,
has one entry in `m0_changes` holding the stamp of its last change. "What
changed since N" is then one query and the asker keeps one number
([the note](docs/notes/a-database-that-remembers-what-changed.md) has the
costs and the two writes a stamp cannot see).

**Bulk arrays.** `m0_array(?)` is an opt-in virtual table that streams a Mojo
`List` into SQL without copying it, so N rows insert in one `sqlite3_step`
instead of N (`uv run poe bench-sqlite` measures it).

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
not for `IN` clauses.

**Not implemented:** statement caching, and a connection pool. Caching was
measured in the benchmark that chose SQLite and came out within noise at
realistic row counts, so it is not worth the ownership complexity yet.

## PostgreSQL

`m0-postgres` is the same kind of layer over libpq — no ORM, no query builder,
no connection pool — and the other **sibling**: it imports nothing else in this
repo.

```mojo
from m0_postgres import Params, open

var db = open("postgres://localhost/app")

var p = Params()
p.text("ada")
_ = db.query("INSERT INTO users (name) VALUES ($1)", p)

var rows = db.query("SELECT id, name FROM users ORDER BY id", Params())
for r in range(rows.rows):     # rows and columns are both 0-based
    print(rows.int(r, 0), rows.text(r, 1))
```

**libpq is opened at run time, not linked.** Nothing in this repo carries a
libpq dependency on its link line — `bin/m0serve` and the wheel included — so a
server that never names a database needs no library present, and an absent one
is a single error naming every path that was tried. `M0_LIBPQ` names the file
outright.

**Parameters are bound with explicit types.** A parameter Postgres resolves as
`unknown` means whatever the surrounding expression makes it, so `Params` sends
an OID with every value: `int`, `float`, `bool`, `text`, `bytes`, `null`, and
`literal` for a type this package does not encode — a timestamp, a uuid, an
array, a numeric — sent as text for the server to coerce, which is how `psql`
sends every literal.

**Results are values, not cursors.** libpq hands back a complete result that
owns its memory, so a `Result` can outlive the query and be read in any order;
it clears itself on destruction. Text is the default and `binary=True` is
per-query, because libpq's result format is one choice for the whole query and
only the caller knows whether every column it selected has a binary decoder. A
binary column whose type has none raises naming the way out rather than
returning plausible bytes.

**`open()` applies what a server wants** and merges rather than appends, so
every default is overridable by naming it in the URL: a connect timeout, a
statement timeout (the twin of SQLite's busy timeout — a pool thread stuck in a
slow query is a thread gone), `client_encoding=UTF8`, an application name, and
TCP keepalive timings plus `tcp_user_timeout` that notice a dropped connection
far sooner than the operating system would.
`open_readonly()` adds a read-only transaction default, the belt to a read-only
role's braces. Every URL is redacted before it reaches an error, a log or
`--doctor`.

**Errors carry their SQLSTATE**, recovered with `sqlstate(String(e))`, with the
codes an application branches on exported by name — `UNIQUE_VIOLATION`,
`SERIALIZATION_FAILURE`, `TOO_MANY_CONNECTIONS` and the rest. There is no retry
anywhere in the package: re-running a statement whose effects the caller cannot
see is a hidden double write.

**One connection per thread**, never shared, which is libpq's own rule. Count
them before deploying: workers times blocking threads times Postgres-backed
mounts is what the server opens, against the server's `max_connections`.

**`LISTEN`/`NOTIFY` is supported**, which is what lets a writer outside the
server process — a trigger, a cron job, `psql` — reach a held SSE stream that
the in-process datagram bus cannot.

**Not implemented:** `COPY`, pipeline mode, row-at-a-time results, and binary
decoders for `numeric`, dates, intervals and arrays, which read as text. Each
is a deliberate absence rather than an oversight; `numeric`'s binary form is a
base-10000 digit vector with its own NaN encoding, and a wrong decoding of one
is silently a different number.

## Status and limits

[docs/SPEC.md](docs/SPEC.md) is the full capability matrix — every row carries its evidence, and `poe check-docs` fails if a row claims a CI gate that does not exist or does not run. [docs/ROADMAP.md](docs/ROADMAP.md#known-issues) holds the known issues, each with what would retire it. The bullets below are what building on this repository needs to know.

- The Mojo toolchain is pinned in `uv.lock`. `.mojoc` artifacts are locked to the exact compiler that produced them, so rebuild after any toolchain change.
- Building on Linux needs two system packages: a C compiler (`mojo build` shells out for linking) and `patchelf` (the binaries record a `$ORIGIN` `DT_RUNPATH` so they find the Mojo runtime beside themselves). `build-essential patchelf` covers it; `m0-sqlite` opens the runtime `libsqlite3` at run time, and `verify-vtab-layout` alone wants `libsqlite3-dev` for its header. None are needed on macOS.
- `m0-wsgi` needs a discoverable `libpython`. Mojo resolves the interpreter from `PATH`, which is why the poe tasks — running inside the venv — pick up the venv's Python and its packages.
- **SSE fan-out is per process unless the application joins the `BroadcastBus`.** Under `M0_WORKERS>1` each worker has its own subscribers; the bus, created before the fork, carries every broadcast to every worker's. The Mojo host wires it ([docs/MOJO_HOST.md](docs/MOJO_HOST.md)), and `apps/datastar_counter` is the reference. Cross-worker ordering is best-effort, and the redelivery filter keeps the newer id.
- SSE replay is journal-deep. `DatastarStream` honours `Last-Event-ID` from a bounded in-memory frame journal; a client further behind than that is sent none of the history, `caught_up(slot)` answers false, and the view queues its current state for that connection alone with `send_to`. Replay across a *restart* needs the application to persist the journal and restore it at boot, as the todo demo does. A WSGI hold is caught up from m0serve's own per-loop journal, and told with one `m0-gap` frame when it cannot be ([docs/RUNNING.md](docs/RUNNING.md#the-realtime-contract)).

## Development

```bash
uv run poe                  # every task, with what it does
uv run poe build-all        # compile each package to .mojoc
uv run poe test-all         # 1788 unit tests, then compiles every example
uv run poe check-docs       # the docs gate, as the required check runs it
uv run poe canary           # the whole suite against the Mojo nightly, then restore the pin
```

Cross-package imports resolve through the `.mojoc` files, so run `build-all` after changing a package's sources — including for the editor, or the LSP reports phantom unresolved imports. Copy `.vscode/settings.example.json` to `.vscode/settings.json` and fill in your absolute path.

## License and attribution

MIT — see [LICENSE](LICENSE).

`packages/m0-http/lightbug_http/` is a hard fork of MIT-licensed work by Valentin Erokhin. Upstream was archived and there is nothing to rebase onto or send patches to; this copy is maintained here. [NOTICE](NOTICE) records the provenance and every category of modification, and [PROVENANCE.md](PROVENANCE.md) explains how this repository was extracted from a private monorepo.
