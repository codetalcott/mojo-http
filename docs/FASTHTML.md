# FastHTML on m0serve

A FastHTML application is an ASGI application, and m0serve serves it
unchanged: one event loop, an asyncio executor
([Which mode](RUNNING.md#which-mode)). This page holds only what is specific
to FastHTML. Flags, limits and what a uvicorn command line does not show are
[Running m0serve](RUNNING.md), from
[Coming from uvicorn](RUNNING.md#coming-from-uvicorn) down.

## Run it

```sh
pip install m0serve          # into the virtualenv that has python-fasthtml
m0serve main:app             # where you ran `python main.py`
m0serve main:app --reload    # development: restarts on a saved file
```

- Leave `serve()` at the end of `main.py`. It starts uvicorn only when the
  file is run as a script, and does nothing when m0serve imports the module.
- `fast_app(live=True)` reloads the browser under `--reload`, as it does
  under `serve()`.
- m0serve loads the `python3` first on `PATH`
  ([Install and start](RUNNING.md#install-and-start)).

## What to change in the application

- **Work scheduled at import does not load.** A module that calls
  `asyncio.create_task` at its top level is refused at start, by name, with
  the fix: start the work from `fast_app(on_startup=[...])` or a `lifespan`.
  uvicorn fails the same way unless it was started with `--reload` or
  `--workers`, which is how `serve()` starts it.
- **An upload over 4 MB is answered `413` before the application runs.** Raise
  the cap with `--max-body` (`M0_MAX_BODY`); uvicorn has none.
- **A list of connections in a module is one process's.** Under `--workers N`
  each worker holds its own WebSockets and streams, as under uvicorn. To
  reach every worker's, publish through `scope["state"]["m0"]`.
- **Keep the default mode.** `--blocking-threads` above 0 moves an ASGI
  application off the executor, onto a path that opens no WebSocket
  ([Which mode](RUNNING.md#which-mode)).

## Where it answers differently from uvicorn

Every other response the comparison below makes is the same from both
servers.

<!-- generated: fasthtml-differences -- edit EXPECTED in scripts/fasthtml_compare/compare.py, not this table -->
| | under m0serve | under uvicorn | row |
|---|---|---|---|
| `scope["state"]` | carries `m0`, the cross-worker publisher, beside what the application's lifespan put there | only what the lifespan put there | [L12](SPEC.md) |
| the scope's headers for a request sent with `Transfer-Encoding: chunked` | `content-length`, the size of the body the server already de-chunked | `transfer-encoding: chunked` | [L25](SPEC.md) |
| a multipart upload sent chunked, to a handler taking an `UploadFile` | the handler receives the file | FastHTML answers `400`: it reads a missing `Content-Length` as an empty form | [L25](SPEC.md) |
| `%2F` in a path, on a route with a `{name}` parameter | stays encoded in `scope["path"]`: the route matches and the parameter is `a%2Fb` | decoded to `/`, so the route does not match: `404` | this comparison |
<!-- /generated: fasthtml-differences -->

## How this is checked

| when | what | row |
|---|---|---|
| every pull request | `apps/fasthtml_demo` at the versions `uv.lock` pins: a page, an `EventStream`, a `BackgroundTask`, an error's own 500 and its traceback, `app.ws`, a module ending in `serve()` | [L11, L22, L23](SPEC.md) |
| weekly | the newest python-fasthtml and uvicorn releases: FastHTML's example applications and this repository's probe applications, each served by m0serve and by uvicorn and compared response by response. A difference the table above does not list fails the run, and so does a listed one that is gone | [L36](SPEC.md) |

```sh
uv run poe fasthtml-canary   # the weekly run, from a checkout; prints the versions it compared
```

Dated runs, with the defects the first one found, are in
[Real applications](REAL_APP_VALIDATION.md).
