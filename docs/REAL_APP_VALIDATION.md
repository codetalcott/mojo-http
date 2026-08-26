# Exercising the server against real applications

A plan, not a record. Nothing here has been run yet.

Every application this server has been tested against so far was written to
test it. `apps/` holds bare WSGI and ASGI apps that pin spec clauses,
a Django demo built around the realtime feature, and a FastHTML row — all
of them small, all of them ours, none of them carrying a dependency tree
somebody else chose. That is the right shape for a smoke suite and the
wrong shape for the question **"would this serve my application?"**

The gap is not hypothetical. The one time the wheel met a real Django
project it produced a defect that no in-repo app could have shown: the
`--app-dir` flag *appends* to `sys.path` where gunicorn, uvicorn and
`runserver` all prepend, so an application module can be shadowed by an
installed package of the same name
([Known issues](ROADMAP.md#known-issues)). One dogfooding session, one
real bug, and it is still open.

## The three applications

Local Django projects, chosen because they stress different parts of the
server rather than because they are convenient:

| app | shape | what it should stress |
|---|---|---|
| `transcripts` | plain WSGI, no streaming, no channels | the **baseline**: does an ordinary Django app just work? |
| `color-separation` | image/halftone processing, `StreamingHttpResponse` | **CPU-bound views** — the case `--blocking-threads` exists for — plus the buffering limit |
| `textshelf` | production-shaped: AI streaming, a pubsub module, djstripe, Docker/Fly deploy | the **hard case**, and the closest thing to the launch claim: an app that already needs streaming and pub/sub |

`textshelf` is the interesting one. It has `ai/streaming.py`, `ai/views.py`
and `notate/pubsub.py` — an application that has already built the thing
this server claims to remove infrastructure for. If the realtime story is
real, it should be visible there; if it is not, that is worth knowing
before it is announced rather than after.

## Ground rules

These are working projects with real data. The plan is **read-only against
them**:

- run from a **copy or a clean checkout**, never the working tree
- a scratch database (`DATABASES` pointed at a temp SQLite/Postgres), never
  the development one; no `migrate` against real data
- their own dev settings, unmodified — the point is to serve the app as it
  is, not an app adapted to us
- any change needed to make an app serve is a **finding about m0serve**,
  recorded, not a patch to their repo

Findings land in exactly one of three places, and the triage is the
deliverable:

1. **a fix** in this repo, with a test
2. **a documented limit** in `README.md` / `docs/WSGI_CONFORMANCE.md`,
   stated where a user will meet it
3. **a smoke**, when the behaviour is worth pinning permanently

A finding that lands nowhere has been forgotten, not resolved.

## Phase 0 — will it even load? (minutes)

`m0serve --doctor` answers this without binding a port, forking, or
importing twice, and reports the resolved spec, protocol and topology:

```bash
m0serve --doctor --app-dir <app> <project>.wsgi
```

Pass: `"ok": true`. Any failure here is a bug or a documented limit before
a single request is served. Run it for all three, WSGI and ASGI entry
points both, since each project ships `wsgi.py` and `asgi.py`.

**Expect `--app-dir` shadowing to bite here.** It is a known open issue and
these are the projects that can demonstrate it.

## Phase 1 — parity against the incumbent

For each app, serve the same routes under `m0serve` and under whatever the
project already uses (`runserver`, gunicorn, uvicorn) and **diff the
responses byte for byte** — status, headers, body — the way `smoke-hybrid`
already does for `reverse()`/`url_for()`.

Routes worth diffing, in order of how much they have historically hidden:

- `/` and any unauthenticated page
- the **Django admin** — sessions, CSRF, its own static files, and the
  largest middleware stack most projects run
- a **login round trip**: cookies set, redirect chain, CSRF token accepted
- any page with `{% static %}` — the URLs must resolve identically
- a 404 and a 500 (with `DEBUG=False`)

A header-level difference that does not change rendering is still a
finding: `Content-Length` vs chunked, `Vary`, cookie attributes.

## Phase 2 — the feature matrix

The properties this server is known to handle differently. Each row is a
yes/no against each app, and a "no" is triaged by the rule above.

| property | why it is on the list |
|---|---|
| static files via WhiteNoise | the common Django answer; does it work, and is `--static` better? |
| static files via `--static PREFIX=DIR` | served from Mojo without entering Python — the claim |
| file upload > 4 MB | request bodies are buffered and capped at `--max-body` (default 4m) |
| `StreamingHttpResponse` | **WSGI responses are fully buffered** — it will be materialized in memory |
| `FileResponse` / large download | same buffering limit, plus whether sendfile applies |
| long-running view | the case for `--blocking-threads` |
| a view that calls out over HTTP | on macOS under `--workers>1`, `urlopen` consults `_scproxy` → CoreFoundation → **abort in a forked child**; `http.client` is the documented workaround |
| management commands | not served, but they must still run against the same settings |

The upload cap and the streaming buffering are **expected** to fail. They
are documented limits; the point of running them is to find out whether the
failure is *legible* — a clear error, or a silent truncation.

## Phase 3 — the topology matrix

Each app, each mode, same request set:

```
--workers 1                      the reference
--workers 4                      prefork; where the fork/CoreFoundation hazard lives
--blocking-threads 4             the handler pool (zero-config default anyway)
--workers 4 --blocking-threads 4 both
--threads 4                      free-threaded CPython only
```

Watch for what only appears at concurrency: database connections per
worker, module-level mutable state, thread-unsafe third-party middleware,
and anything that opens a file descriptor per request.

## Phase 4 — the realtime retrofit (`textshelf`)

The launch claim is that a plain sync view can hold an SSE stream or a
WebSocket with two response headers and no added infrastructure. `textshelf`
already streams AI responses and already has a pubsub module, so it is the
honest test: **can its existing streaming endpoint be converted to
`M0-Hold` + `m0pub.publish()`, and is the result simpler than what it
replaces?**

Success is not "it works" — it is a diff a maintainer would accept. If the
conversion needs more code than it removes, the claim is weaker than the
README says and the README should change.

## Phase 5 — soak

The one thing a request-count test cannot show. Serve each app for an
extended run under mixed load and watch:

- **RSS** — `smoke-django` already guards 0 KB growth over 10k requests
  against the bare app; a real app with a real dependency tree is the
  harder case
- **file descriptors** — per-request fd growth is invisible until it is a
  crash
- **database connections** — Django's `CONN_MAX_AGE` against a
  worker/thread model it was not written for

## What would make this worth repeating

If the pass turns up findings, the ones that generalize should become
`apps/` fixtures or smokes so they are checked forever rather than
rediscovered. The value of a real application is finding the defect; the
value of a smoke is that it stays found.
