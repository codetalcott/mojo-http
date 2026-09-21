# AGENTS.md — __M0_APP__

A web application in Mojo on the `m0` framework: one compiled binary, no
Python at run time. This page is the rules that are not obvious from the
code. The framework's own source is installed and readable — `uv run m0
include` prints where. Grep it before guessing an API.

## Commands

Always `uv run m0 …` (the project's own venv; `uvx` is for `m0 new` alone).

| command | what it does | time |
|---|---|---|
| `uv run m0 test` | runs `test/test_*.mojo`; no link, no server | 2–4 s |
| `uv run m0 build` | compiles `src/server.mojo` to `bin/server` | 10–13 s after an edit |
| `uv run m0 dev` | builds, serves, and rebuilds when `src/` or `pyproject.toml` changes; the old server keeps serving until a build SUCCEEDS, so a syntax error costs a compiler message and not the page; `-- --port 8080` goes to the binary | a build per save |
| `uv run m0 doctor` | every toolchain check, then the binary's resolved configuration; `--json` for a machine | < 1 s |
| `uv run m0 build --release` | a relocatable `dist/` for the baseline CPU | a build, plus the bundling |
| `uv run m0 image` | `docker build -f deploy/Dockerfile`, then the image's own `about.json`; needs docker and a committed `uv.lock`, and no local toolchain | minutes the first time |
| `./smoke.sh` | build, serve on its own port, probe the wire, stop | a build, plus a second |

The test loop is three to five times faster than the build loop. **Put logic in
functions a test can reach** — a renderer that takes values, a state struct
with methods — and keep views thin. A test is also the only thing that
vouches for a function nothing calls yet: in an imported module the compiler
does not diagnose one, malformed signature included, so a green build says
nothing about it. `bin/server --port 8080` runs the app;
`--doctor` prints its configuration and starts nothing.

Every refusal, from `m0` and from the binary, is exit **78** and one line
naming the fix. Exit 1 is the compiler's or a test's own failure; exit 2 is
a command line that cannot be read. Read the line; do not retry.

## Layout

`src/server.mojo` is `main` and imports its siblings by bare name (`from
views import …`); tests reach them the same way. There is no
`__init__.mojo` and no package named for the app. Tests are `test_*`
functions in `test/test_*.mojo`; adding one needs no registration.

## Views

- A view is a free function `(req, params, state) raises -> HTTPResponse`.
  `add_read` hands it the state borrowed, `add_write` hands it `mut`,
  `add_loop` registers a stateless view answered on the event loop.
- **No middleware, no decorators**: a stored view is a `thin` function
  pointer and a closure is not one. A guard is an early return of
  `Optional[HTTPResponse]` on the view's first lines.
- Routes are `comptime` patterns given to the table AND to `url_for`, so a
  misspelled route is a compile error. Never build a path by hand, and
  never a query string: `Query().add(name, value)` then `q.on(url_for(X))`
  encodes both halves, request data included.
- State that lives in one process answers `max_workers() -> 1`, and
  `M0_WORKERS=2` is then refused rather than served as two different
  copies. Move the state out (a database, the shared page) before raising it.
- `form(req)` is `None` unless the body is a urlencoded form. Check it.

## Rendering

- `Fragment[V]("id")` writes the root id once; `f.el(tag, verb, url, …)`
  and `f.swap(verb, url)` generate the attributes that target it. **Never
  type an `hx-*` or `data-on:*` swap attribute by hand**, and never retype
  the id as `#id`.
- Escaping is named at every hole: `text(x)` for data in an element,
  `attr(name, x)` for data in an attribute (it owns the quotes), `raw`/a
  bare string only for markup this code wrote. Request data in a bare
  string is an injection.
- `page_or_fragment(req, fragment, Shell(...))` decides document-or-fragment
  from the request's headers and sets `Vary`. No view branches on a header.
- **htmx 4 swaps every answer, 4xx included.** An error a person may see is
  the fragment with the message in it and the right status
  (`status=422`); `reply.problem` is for routes no browser swaps.
- Moving a `Fragment[Htmx]` app to Datastar is `Fragment[Datastar]` and the
  script tag. A Datastar URL sits inside a JavaScript string: build it with
  `url_for`, which encodes; a URL carrying `'`, `\`, CR or LF is refused.

## When a login arrives

Both scaffolds are sessionless, so no write carries a token. The day a
session cookie exists, **every write needs a CSRF token**: a POST's as a
hidden field; a DELETE's as an `X-CSRF-Token` header from a hand-written
`hx-headers` attribute (htmx 4 puts a DELETE's fields in the query string,
and a token in a URL is a token in every log) — the ONE `hx-` attribute
typed by hand. `m0_http.session` has the signed cookie and `csrf_token`.
The worked example is not installed with the framework: it is
`apps/fragment_notes/server.mojo` at
https://github.com/codetalcott/mojo-http — read its renderer as well as
its views.

- **Login and logout are PLAIN forms** (`el("form", attr("method", "post")
  + attr("action", url))`), answered with a 303 — never `f.el("form", …)`.
  A swap changes the fragment and not the address bar, so signing in
  leaves the application under `/login` and signing out leaves the login
  form under whatever was open.
- **A hand-built request parses no `Cookie` header**; only the server's
  parser fills `req.cookies`. A test of a view behind a session fills the
  jar itself: `var jar = RequestCookieJar()` (from
  `lightbug_http.cookie.request_cookie_jar`), `jar.add_pairs("name=value")`,
  then `HTTPRequest(uri, headers=…, cookies=jar^)`. Without it every such
  test is answered as signed out.

## Streaming (SSE)

- Opening a stream is an `add_write` view: it subscribes a connection slot.
- A stream registry's capacity must be at least the server's connection
  count (`ctx.capacity`): slots index it directly.
- **Every frame is the full state, never a delta.** A slow viewer's 64 KB
  outbox DROPS frames, it does not queue them; a dropped full frame is
  healed by the next one.
- Work on a cadence goes in a `Producer` (`step` returns the nanoseconds to
  the next step), never in the loop's `tick`, which stalls every
  connection. Number frames with `out.next_id()`, and COUNT a publish that
  returns `False`: a refused frame is otherwise invisible.
- What workers and the producer share crosses a process boundary: it lives
  on the `page_slots` shared page, never in `malloc`'d memory.

## Mojo traps this framework has paid for

- A `String` that came from a request may not be UTF-8. **Never slice one
  with `s[byte=a:b]`** — it traps on a non-boundary byte and takes the
  server down. Use `String(unsafe_from_utf8=s.as_bytes()[a:b])`.
- A pointer handed to C does not keep its buffer alive. After an FFI call
  that reads through `x.unsafe_ptr()`, write a bare `_ = x`. Deleting that
  line is a use-after-free with no symptom at the call site.
- `from std.…` imports; `comptime` for constants; `s.as_bytes()[i]`, not
  `s[i]`; write `__init__` explicitly.

## Configuration the host reads

Flag > environment > default; `bin/server --doctor` prints the result.
`M0_HOST`, `M0_PORT`, `M0_BASE_URL`, `M0_WORKERS` (processes),
`M0_THREADS` (loops in one process; not beside `M0_WORKERS>1`),
`M0_BLOCKING_THREADS` (handler threads per loop), `M0_SPAWN_WORKERS`
(refused), `M0_ACCESS_LOG`, `M0_SSE_HEARTBEAT_MS`, `M0_APP_TICK_MS`,
`M0_MAX_KEEPALIVE_REQUESTS`, `M0_QOS`. A count that cannot be
served is a 78 whichever way it arrived.

## Probing a running server

One port per run, never a shared one; wait for `/health` before the first
probe; stop the server **by pid**, never by name; take the exit status from
the probe, not from the last command of a pipe. `smoke.sh` does all four.

## Not built, on purpose

No template engine, middleware, ORM, multipart parsing, session store or
password hashing. Documentation: https://m0serve.dev/mojo/ (the host, views
and fragments, deploy), and https://m0serve.dev/llms.txt for an agent.
