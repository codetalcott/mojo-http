# WSGI conformance

m0serve's WSGI bridge is held to PEP 3333 three ways: the standard
library's validator wrapped around two applications, a bare callable
that pins the parts of the spec no framework reaches, and one contract
every framework row runs. The 2026-08 plan behind them, and what they
found on their first run, are [a dated note](notes/a-framework-neutral-wsgi-suite.md).

## The validator pass

`wsgiref.validate` is the stdlib's own WSGI checker and the closest thing that
exists to a conformance suite for a *server*. `M0_WSGI_VALIDATE=1` wraps the
application in it, and `poe smoke-django` and `poe smoke-wsgi` each run a pass
with it set. In that pass a non-conforming route in each app, Django's
`/pep3333/canary` and the bare app's `/no-content-type`, must answer 500,
which proves the wrapper is engaged.

## The PEP 3333 surface

[`apps/wsgi_bare/`](../apps/wsgi_bare/) is a plain PEP 3333 callable with
zero third-party dependencies, 40 routes, each pinning one paragraph of
the spec. It is served by the same `m0serve` binary as the Django and
Flask rows, as
`bin/m0serve bareapp.wsgi:application --app-dir apps/wsgi_bare`, so a
failure against it is the server's: there is no framework in between. It runs whether or not Django is installed.

`poe smoke-wsgi` runs against it with `M0_WORKERS=2` throughout, then
repeats a subset under `M0_WSGI_VALIDATE=1`. It reaches PEP 3333 surface
no framework-based test can reach: the `write()` callable, a second
`start_response` with and without `exc_info`, multi-chunk iterables,
`close()` on the response iterable, arbitrary status passthrough, and
`wsgi.input` read patterns (`read()`, `readline()`, iteration, reading
past EOF). It also asserts HTTP/1.1 on the wire, `QUERY_STRING` arriving
still percent-encoded, keep-alive not leaking one request's body into the
next, and a re-entrant request. That request calls back into the server
through `http.client.HTTPConnection`, because on macOS `urlopen` kills a
forked worker ([RUNNING.md](RUNNING.md#a-forked-worker-and-the-system-frameworks)).

## The framework contract

`smoke-wsgi` asks whether the bridge implements PEP 3333. The framework
rows ask whether a real framework's idioms survive the crossing: its
router, its cookie jar, its body parsing, its error handling. Every
framework answers those the same way, so the assertions live once, in
[`scripts/wsgi_framework_contract.sh`](../scripts/wsgi_framework_contract.sh):

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
`smoke-django` and `smoke-flask` both call the same script. A row that
needed assertions of its own would show the host is not
framework-agnostic.

Django keeps its own extra assertions — signed-cookie sessions, the RSS leak
guard, `wsgi.multiprocess`, the prefork parallelism check, the validator pass —
because those genuinely are Django-specific or server-specific rather than
framework-contract material.

Adding Pyramid or Bottle costs an app directory and a task, not a CI
dependency and not a line of the contract. Flask is a dev dependency and
`smoke-flask` skips cleanly when it is absent.

## Beyond WSGI

The fork matters for how much of this is reusable:

- **Flask, Pyramid, Bottle, Werkzeug** are WSGI. Same bridge, adapter only:
  they are matrix rows, and the suite above covers them.
- **FastAPI, Starlette and Litestar are ASGI.** m0serve hosts them through the
  ASGI executor, a Python event loop beside each Mojo loop
  ([the design record §8](notes/wsgi-vs-asgi-history.md)).
