# mojo-http

`mojo-http` is an HTTP/1.1 server and a small web framework for [Mojo](https://docs.modular.com/mojo/): routing, content negotiation, ETags, response caching, and Server-Sent Events, with a [Datastar](https://data-star.dev/) adapter for hypermedia UIs and SQLite bindings for storage.

The server underneath is a hard fork of [lightbug_http](https://github.com/Lightbug-HQ/lightbug_http), taken from v26.1.2 and maintained here since upstream was archived on 2026-05-12 — not a vendored snapshot. It adds hardening against request smuggling, slowloris, and integer overflow in request parsing, connection timeouts, an SSE-aware event loop, and a fix for `epoll` struct layout on non-x86_64. See [NOTICE](NOTICE) for the full record.

It is a small library in a small ecosystem: HTTP/1.1 only, no TLS, Linux and macOS, and the API will change before 1.0.

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


def main() raises:
    print("Starting hello server on 0.0.0.0:8080")
    var server = Server()
    var handler = HelloHandler()
    server.listen_and_serve("0.0.0.0:8080", handler)
```

The four `sse_*` hooks are the streaming interface; a handler that does not stream returns the empty defaults shown here.

## What's in the box

| Package | Description | Tests |
| --- | --- | --- |
| `m0-core` | FNV-1a, xxHash32, wyhash64, SIMD JSON escape, JSON field parser | 59 |
| `m0-http` | Router, content negotiation, ETag, response cache, SSE, auth, CORS, config, health, logging, multi-worker supervisor | 107 |
| `m0-datastar` | Datastar v1.0.2 wire format, `DatastarStream` fan-out, `read_signals` | 56 |
| `m0-sqlite` | SQLite bindings — connections, statements, typed columns, transactions | 30 |
| **Total** | | **252** |

Modules are named `m0_*` — `mojo-http` is the repository, `m0` is the import prefix.

Strict layering, no upward imports: `m0-core` has zero dependencies and `m0-http` uses three functions from it. `m0-datastar` splits in two — `consts` and `sse` are the pure wire format with no dependencies at all, while `stream` and `signals` are the server glue and are the only parts that pull in `m0-http`.

**HTTP essentials** — path router with `:param` extraction · content negotiation with quality factors, case-insensitive media ranges, and wildcards · weak ETags (wyhash) with `304 Not Modified` · URL-keyed response cache · SSE with backpressure and `Last-Event-ID` reconnect replay.

**Production bits** — API key auth with constant-time comparison · CORS config · `M0_`-prefixed env-var configuration · health/readiness registry with a shutting-down flag · JSON-lines access logs to stdout · graceful shutdown that drains in-flight requests · multi-worker fork supervisor with `SO_REUSEPORT` (`M0_WORKERS=4`).

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
```

`read_signals(req)` is the other direction — the browser posts its whole signal store, as a
`datastar` query parameter on GET and as the body otherwise.

Run [apps/datastar_counter/](apps/datastar_counter/) with `uv run poe serve-counter` and open
it in two tabs; pressing a button in one updates the other.

**SSE needs `listen_and_serve_nonblocking`,** not `listen_and_serve`. Only the non-blocking
event loop assigns `req.slot_id` and drains the outbox; the plain accept loop leaves
`slot_id` at `-1` and every stream open answers `409`.

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
`synchronous=NORMAL`, `foreign_keys=ON`. Transactions are explicit
(`begin` / `commit` / `rollback`); there is no scope guard, because Mojo has no
`defer` and a destructor that rolled back would make correctness depend on drop
order.

**Linking.** Tests build to a binary with `-Xlinker -lsqlite3` rather than using
`mojo run`. The JIT resolves symbols only from libraries already in its process:
on macOS libsqlite3 lives in the dyld shared cache so `mojo run` happens to
work, but on Linux it fails with `JIT session error: Symbols not found:
[sqlite3_open_v2, ...]`. Linking explicitly behaves the same on both. Linux also
needs `libsqlite3-dev` present at link time; CI installs it.

**Not implemented:** statement caching. It was measured in the benchmark that
chose SQLite and came out within noise at realistic row counts (~10% at N=50),
so it is not worth the ownership complexity yet.

## Status and limits

- HTTP/1.1 only. No HTTP/2, no TLS — terminate at a proxy.
- Linux (`epoll`) and macOS (`kqueue`).
- Mojo 1.0, pinned in `uv.lock`. `.mojoc` artifacts are locked to the exact compiler that produced them, so rebuild after any toolchain change.
- Pre-1.0: the API will break.
- **SSE fan-out is single-process.** `M0_WORKERS>1` forks, and each worker gets its own subscriber registry, so a push on one worker never reaches subscribers on another.
- **No server-side timer hook.** Every push must be triggered by an inbound request.
- `m0-sqlite` has no statement cache and no connection pool; see above.
- No SSE replay across restarts. `DatastarStream` ignores `Last-Event-ID` because event ids restart per process; `PatchJournal` is the building block if you need it.

## Development

```bash
uv run poe                  # list every task
uv run poe build-all        # compile each package to .mojoc
uv run poe test-all         # 252 unit tests, then compiles every example
uv run poe serve-counter    # the Datastar demo on :8080
uv run poe smoke-hello      # start the hello server, assert /health, stop
uv run poe smoke-counter    # assert an SSE broadcast reaches a live client
uv run poe bench-core       # benchmark m0-core hot paths
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
