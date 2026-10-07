---
name: m0
description: Write a web application in Mojo on the m0 framework, compiled to one binary with no Python at run time — scaffold it with `uvx m0 new`, then views, htmx 4 or Datastar fragments, Server-Sent Events pushed to every open tab, SQLite. Use when the user mentions m0, `m0 new`, or the Mojo stack under m0serve, or wants a web server or live-updating page written in Mojo.
---

# m0

`m0` writes a project, builds it against the framework's source, tests it,
rebuilds it on save and builds its image. It needs uv and a C compiler
named `cc`; macOS arm64 and glibc Linux. Every command inside a project is
`uv run m0 …`; `uvx` is for `m0 new` alone.

## Read before you write

1. The project's own `AGENTS.md`: the rules that are not obvious from the
   code.
2. https://m0serve.dev/mojo/views.md (the views table, `form`, `reply`,
   fragments, a page or a fragment from one view, URLs, sessions, streams)
   and https://m0serve.dev/mojo/host.md (`main`, workers and threads,
   flags, every refusal). https://m0serve.dev/llms.txt indexes the rest.
3. The framework's source, last: `uv run m0 include` prints where it is
   installed.

## Start from the nearest template

| template | what it is |
|---|---|
| `views` (default) | a server-rendered list that htmx 4 swaps in place |
| `board` | a list every tab shares: a POST view appends and pushes the board to every open tab over SSE, with Datastar |
| `live` | a producer thread steps a state on a cadence and pushes it to every tab; a count kept in SQLite |
| `auth` | the `views` list behind a login, with a CSRF token on every write |

```bash
uvx m0 new . --template board     # the empty current directory, named for it
uv sync                           # installs the exact m0 and mojo pins
uv run m0 test                    # 2-4 s: no link, no server
uv run m0 build                   # 10-13 s after an edit: bin/server
bin/server --host 127.0.0.1 --port 8080
uv run m0 dev -- --host 127.0.0.1 --port 8080   # rebuild on save
```

`uvx m0 new NAME` writes `./NAME` instead. `board` and `m0 new .` arrived
after m0 0.8.0; `uvx m0 new --help` lists what the installed one has.
Without `--host` the server listens on every interface.

## Rules that cost a build when missed

- A view is a free function `(req, params, state) raises -> HTTPResponse`
  in a `Views[S]` table: `add_read` borrows the state, `add_write` takes it
  `mut`, `add_loop` has none. No decorators and no middleware: a guard is
  an early return.
- `reply.problem(status, title, detail, instance)` takes all four;
  `instance` is the request's path. `reply.html`, `reply.json(status,
  text, body)`, `reply.redirect`, `reply.no_content`.
- `form(req)` is `Optional`: `None` unless the body is urlencoded.
  `var f = form(req)`, then `if not f:` refuses, then
  `f.take().first("text")` reads a field.
- `void("input", attrs)` writes a void element; `el` closes its tag.
  `text(x)` and `attr(name, x)` escape; a bare string does not.
- `Fragment[Htmx]` or `Fragment[Datastar]` writes the swap attributes from
  the fragment's id: never type `hx-*` or `data-on:*` by hand.
- Routes are `comptime` constants given to the table and to `url_for`.
- A request-derived `String` may not be UTF-8: never slice it with
  `s[byte=a:b]`; use `String(unsafe_from_utf8=s.as_bytes()[a:b])`.

## Streams

- A view sends: `st.stream.patch_elements(EVENTS, html)` on a
  `DatastarStream` the state holds reaches this process's open streams.
  Send the whole state in every frame; a dropped frame is healed by the
  next.
- Every view that opens a stream, or reads or writes what one sends, is
  `on_loop=True`. Under `--blocking-threads` each pool thread builds a
  state of its own, and nothing drains its stream.
- The registry's capacity is `ctx.capacity`.
- State in one process declares `max_workers() -> 1`. Reaching other
  workers' tabs takes the bus and an `AppHandler` of your own that
  forwards `sse_peer_frame`; `ViewsApp` does not.
- Work on a cadence is a `Producer` (`live`), never the loop's `tick`.
- Datastar 1.0 applies an action's answer only on a 200: a 4xx is
  dropped. An `application/json` answer patches signals, so
  `{"text":""}` empties an input bound with `data-bind:text`.

## Checking it

- `./smoke.sh` builds, serves on its own port, probes the wire and stops
  by pid. Probe a server the same way: a free port, wait for `/health`,
  stop by pid, never by name.
- `uv run m0 doctor --json` prints every toolchain check and the binary's
  resolved configuration as one object.
- Exit codes from `m0` and the binary: 0; 1 the compiler or a test
  failed; 2 a command line that cannot be read; 78 a refusal, one line
  naming the fix. Read the line; do not retry.
- A build does not check a function nothing calls; a test that calls it
  does.
