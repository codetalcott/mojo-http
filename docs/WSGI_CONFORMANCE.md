# WSGI conformance

`m0-wsgi` hosts WSGI applications. Django is one, and the package has no
opinion about which one you run — `grep -i django packages/m0-wsgi/**/*.mojo`
returns nothing. What *is* Django-shaped is the evidence: `apps/django_wsgi` is
the only WSGI example, `smoke-django` is the only proof the bridge works, and
the example handler is named `DjangoHandler`. This document is about closing
that gap without deepening it.

## Tier 1 — PEP 3333 conformance (done)

`wsgiref.validate` is the stdlib's own WSGI checker and the closest thing that
exists to a conformance suite for a *server*. `poe smoke-django` runs a pass
with `M0_WSGI_VALIDATE=1`, which wraps the application in it, plus a
`/pep3333/canary` route that proves the wrapper is engaged. See the "PEP 3333
conformance" section of [ROADMAP.md](ROADMAP.md).

It rides on the Django example today only because that is the WSGI example
that exists. It should move to the bare app below.

## Tier 2 — do not vendor Django's test tree

The earlier plan was to repoint `tests/servers/tests.py` (21 tests, real HTTP
over a socket) at this server via `LiveServerTestCase.server_thread_class`.
That is mechanically easy and it is the wrong trade.

Auditing the 12 tests that would pass, by what the assertion actually targets:

| Target | Tests |
|---|---|
| **The wire — our server** | `test_protocol`, `test_environ`, `test_keep_alive_connection_clears_previous_request_data`, `test_view`/`test_404` (trivially) |
| Django's staticfiles handler | `test_static_files`, `test_no_collectstatic_emulation`, `test_media_files` |
| Django's ORM across processes | `test_fixtures_loaded`, `test_database_writes` |
| The harness's own port allocation | `test_port_bind`, `test_specified_port_bind` |

The three static/media tests exercise the
`_StaticFilesHandler(_MediaFilesHandler(WSGIHandler()))` stack Django builds
for itself (testcases.py:1761), not anything this server does. So the real
yield is **four assertions**, each a handful of lines against a plain WSGI
callable — and the price is a pinned third-party *source tree* in CI (the wheel
has no `tests/`; only the sdist does), an expectations file that must be
re-read every time that pin moves, and a conformance story told in Django's
vocabulary rather than PEP 3333's.

Not worth it. **Harvest the ideas, not the tree**: `tests/servers/tests.py` is
worth reading once for assertions to port, and nothing more.

## Tier 2, revised — a framework-neutral suite (built)

### 1. A bare WSGI example

[`apps/wsgi_bare/`](../apps/wsgi_bare/) — a plain PEP 3333 callable with zero
third-party dependencies, 19 routes, each pinning one paragraph of the spec.
`apps/wsgi_bare/server.mojo` is `apps/django_wsgi/server.mojo` with the
framework removed, and the diff between them is the point: it is empty apart
from the module name. It is the primary conformance target because a
failure against it is unambiguously the server's: there is no framework in
between to blame. It also gives CI a WSGI smoke test that runs whether or not
Django is installed, and it makes the README's "any WSGI app" claim
demonstrable rather than asserted.

### 2. Conformance assertions over it

`poe smoke-wsgi`, wired into CI ahead of `smoke-django`. It runs
`M0_WORKERS=2` throughout, then repeats a subset under `M0_WSGI_VALIDATE=1`.

It reaches PEP 3333 surface no framework-based test can, which is what makes it
a *better* corpus than Django's suite rather than merely a cheaper one: the
`write()` callable, a second `start_response` with and without `exc_info`,
multi-chunk iterables, `close()` on the response iterable, arbitrary status
passthrough, and `wsgi.input` read patterns (`read()`, `readline()`, iteration,
reading past EOF).

Plus the four worth porting from Django: HTTP/1.1 on the wire, `QUERY_STRING`
arriving still percent-encoded (the raw-vs-decoded distinction `environ.mojo`
documents and nothing else pins), keep-alive not leaking one request's body
into the next, and a re-entrant request.

### What it found immediately

**`write()` discarded every byte.** The shim returned `lambda data: None`, so
an application using the legacy write callable got a 200 with an empty body and
no error anywhere. Django never calls `write()`, so no Django-based test could
have found it at any level of effort — and neither could tier 1, because
`wsgiref.validate` type-checks the call and not its effect. Fixed in
`bridge.mojo`: `start_response` now returns a real appender, and the iterable is
drained *before* the writes are joined, because an application may call
`write()` from inside the generator it returned.

**A second `start_response` without `exc_info` was silently accepted**, last
call winning. PEP 3333 makes it an application error; the shim now raises and
the server answers 500. With `exc_info` the spec requires replacing the stored
status and headers unless the headers have already gone out — which for a
fully-buffering server is never, so replacing is always the correct branch.
That part was already right by accident; it is now right on purpose and pinned.

**`urlopen` from inside a view SIGKILLs the worker on macOS.** Not a bug in
this server, but a trap for anyone using it. `urlopen` consults the system
proxy configuration through `_scproxy`, which calls into CoreFoundation;
Objective-C refuses to run in a process forked without `exec` and aborts:

```
objc[13802]: +[NSNumber initialize] may have been in progress in another
thread when fork() was called. We cannot safely call it or ignore it in the
fork() child process. Crashing instead.
```

The supervisor respawns the worker, so the symptom is a dropped connection and
a churning worker rather than an obvious crash. Confirmed fork-specific:
`M0_WORKERS=1` runs the identical code with zero objc lines in the log. Use
`http.client.HTTPConnection`, which performs no proxy lookup — that is what
`/reentrant` does, and its docstring says why. This is the same family as the
`exit_worker()` rule already in CLAUDE.md: after `fork()` without `exec`,
platform runtimes are off limits.

**Single-worker re-entrancy deadlocks, as predicted.** `/reentrant` on one
worker blocks for the full 10s timeout and returns 504; on two workers it
answers in ~14 ms. Django's equivalent test calls `urlopen` with no timeout and
hangs forever — the difference between a red test and a CI job that runs until
the runner kills it.

### 3. Frameworks as a matrix (Django + Flask)

`smoke-wsgi` asks whether the bridge implements PEP 3333, against a bare
callable with no framework to blame. The rows ask a different question:
whether a real framework's idioms survive the crossing — its router, its
cookie jar, its body parsing, its error handling. Those need a framework, and
every framework answers them identically, so the assertions live once in
[`scripts/wsgi_framework_contract.sh`](../scripts/wsgi_framework_contract.sh)
rather than once per row:

| | |
|---|---|
| `GET /` | the row's own body, passed in as an argument |
| `GET /cookies` | two Set-Cookie headers on one response |
| `GET /cookies/echo` | request cookies, sorted `k=v`, joined with `\|` |
| `POST /echo` | the request body unchanged, and again at 256KB |
| `GET /binary` | all 256 byte values |
| `GET /query?name=` | the framework's own parameter parsing |
| `GET /boom` | raises, so the 500 path is reachable |
| any unrouted path | the framework's own 404 |

[`apps/django_wsgi`](../apps/django_wsgi/) and
[`apps/flask_wsgi`](../apps/flask_wsgi/) both implement it, and
`smoke-django` and `smoke-flask` both call the same script. A row that needed
assertions of its own would be evidence the host is *not* framework-agnostic,
so the shared script is the test — not a convenience.

Flask required **no changes to `m0-wsgi`**: the app, a `server.mojo` identical
to the other two apart from the module name and port, and a task that calls the
contract. It passed on the first run. One framework is an anecdote; two that
share a contract are a claim.

Django keeps its own extra assertions — signed-cookie sessions, the RSS leak
guard, `wsgi.multiprocess`, the prefork parallelism check, the validator pass —
because those genuinely are Django-specific or server-specific rather than
framework-contract material.

Adding Pyramid or Bottle now costs an app directory and a task, not a CI
dependency and not a line of the contract. Flask is a dev dependency and
`smoke-flask` skips cleanly when it is absent.

### What landed

| | |
|---|---|
| `apps/wsgi_bare/` — 19 routes, no third-party imports | built |
| `apps/wsgi_bare/server.mojo` | built |
| `poe smoke-wsgi`, `poe serve-wsgi-bare` | built |
| `write()` + double-`start_response` fixes in `bridge.mojo` | fixed |
| CI step ahead of `smoke-django`, `wsgi.log` in failure artifacts | wired |
| Shared `scripts/wsgi_framework_contract.sh`, with `smoke-django` refactored onto it | built |
| Flask row: `apps/flask_wsgi/`, `poe smoke-flask`, `poe serve-flask` | built |

`M0_WSGI_VALIDATE` stayed on the Django example as well as moving onto the bare
app. Removing it there would have dropped real coverage — Django is the
realistic-traffic case — and it costs four lines to keep.

Warning ratchet unchanged at 68. No sdist fetch, no pinned source tree, no
expectations file.

## A note on "beyond Django"

The fork matters for how much of this is reusable:

- **Flask, Pyramid, Bottle, Werkzeug** are WSGI. Same bridge, adapter only —
  they are matrix rows, and the suite above covers them the day it exists.
- **FastAPI, Starlette, Litestar are ASGI**, which is a different protocol and
  a different package, not an adapter. The current architecture is actively
  hostile to it: the handler runs synchronously on the event loop, the process
  is single-threaded, Mojo never acquires the GIL, and the fork must happen
  before the first Python call. ASGI wants a Python event loop coexisting with
  the Mojo one. That is a design problem to be taken on deliberately, not
  reached by extending `m0-wsgi`.

The HTTP-level assertions in the suite above are protocol-agnostic and would
carry over to an ASGI host unchanged — which is a further argument for writing
them against a bare callable now rather than against Django's test tree.
