# Exercising the server against real applications

**A record. Run 2026-08-26**, against m0serve 0.11.0 (the PyPI-shaped wheel,
`dist/wheels/m0serve-0.11.0-py3-none-macosx_13_0_arm64.whl`), macOS 26 on an
M4, CPython 3.13.6 — plus one row on free-threaded 3.14.7t. The plan this
replaces is in the history of this file.

Every application this server had been tested against was written to test it.
`apps/` holds bare WSGI and ASGI apps that pin spec clauses, a Django demo
built around the realtime feature, and a FastHTML row — all small, all ours,
none carrying a dependency tree somebody else chose. That is the right shape
for a smoke suite and the wrong shape for the question **"would this serve my
application?"**

The gap was not hypothetical. The one time the wheel had met a real Django
project it produced the `--app-dir` shadowing defect
([Known issues](ROADMAP.md#known-issues)). This pass produced **four more**,
three of which no in-repo app could have shown, and every one of them is now
fixed with a test that fails without the fix.

## The three applications

Local Django projects, chosen because they stress different parts of the
server rather than because they are convenient. Served from clean clones
against scratch databases; their own settings, unmodified.

| app | shape | Django | what it stressed |
|---|---|---|---|
| `transcripts` | plain WSGI, `src/` layout, allauth, 137 modules | 5.2 | the **baseline** — and the `--app-dir` case, since its code is under `src/` |
| `color-separation` | image/halftone processing, numpy/scipy/Pillow, `FileResponse` | 6.0 | **CPU-bound views**, uploads, downloads |
| `textshelf` | production-shaped: 4 SSE endpoints, 3 pubsub modules, djstripe, WhiteNoise, Docker/Fly | 6.1 | the **hard case** — an app that already built what this server claims to remove infrastructure for |

## What was found

Five defects. Four are fixed in this repo with a guard; one was already known
and stays open on purpose.

| # | defect | how it presented | triage |
|---|---|---|---|
| 1 | **Every `Set-Cookie` lost `expires` and `SameSite`** | Django's session and CSRF cookies reached the browser as `sessionid=…; Max-Age=…; Path=/` where every other server sends `expires=…; HttpOnly; Max-Age=…; Path=/; SameSite=Lax`. Sessions still worked, so nothing failed loudly — but a persistent cookie became a session cookie for [any client that prefers `expires`](https://datatracker.ietf.org/doc/html/rfc6265#section-5.3), and CSRF cookies shipped without their `SameSite` defence. On all three apps, on every response. | **fixed** — `ResponseCookieJar.raw`, + `test_response_cookies.mojo`, + `smoke-django` asserts the attributes on the wire |
| 2 | **Uploads between ~1.5 MB and `--max-body` were refused `400`** | `color-separation`'s image upload (7.1 MB) failed with a truncated connection under `--max-body 64m`; on a bare echo app the threshold was between 1.5 MB and 2 MB whatever the flag said, including the default. The receive buffer had its own 2 MB ceiling that `--max-body` never raised, and it answers `400 Bad Request` rather than the `413` the body cap sends — so the error named the wrong thing. | **fixed** — `ServerConfig.recv_buffer_limit()`, + a `test_config.mojo` case, + `smoke-serve` now asserts a 3 MB body at the default cap and 7 MB at `--max-body 8m` |
| 3 | **Concurrent ASGI streams truncated each other** | `textshelf` serves its static files through WhiteNoise, so every page load is several `FileResponse`s. Twelve concurrent fetches of one 232 KB file left bodies short — a clean `200` with fewer bytes — and enough of them wedged the executor entirely: the server stopped answering and `SIGTERM` needed 12+ s and then `SIGKILL`. Cause: the credit window is **per stream** (64 KB) while the chunk channel is **shared and finite**, so N streams over-commit it and `send_stream_chunk` dropped the datagram it could not place. | **fixed** — a global in-flight budget in the shim (`_ASGI_TOTAL_WINDOW`), an owed-ack retry on the loop side, and a full channel that **waits detached** rather than dropping; + `smoke-asgi` runs 32 concurrent `FileResponse`-shaped streams and checks every byte |
| 4 | **`SIGTERM` never returned when a handler thread was inside a response that never ends** | `textshelf`'s SSE endpoints served under WSGI are buffered, so the generator never returns and its pool thread never comes back. `stop_and_join` waited for it forever: the drain finished, the process did not exit, and `docker stop` would end in `SIGKILL` after its grace. | **fixed** — `ThreadSet.join_within` and a 5 s join budget matching the drain's, after which the process leaves and says what it left behind; + a `smoke-blocking-threads` phase with two never-returning views |
| 5 | `--app-dir` is appended to `sys.path`, not prepended | Confirmed again: a probe app reports `--app-dir` at position 5, after site-packages. It did **not** bite any of the three (no top-level module name collides with an installed package in any of them), which is why it stays a latent hazard rather than a visible failure. | **unchanged** — still open in [Known issues](ROADMAP.md#known-issues); a fix changes import precedence and wants its own change |

Findings 1, 3 and 4 could not have come from `apps/`: they need a real cookie
policy, a real static-file middleware, and a real never-ending response
respectively. Finding 2 needed a file somebody wanted to upload.

## Phase 0 — will it even load?

`m0serve --doctor` against each entry point. **All six passed** (`"ok": true`,
exit 0): `transcript_manager.wsgi`, `halftone_studio.wsgi`,
`halftone_studio.asgi`, `config.wsgi`, `config.asgi`, and
`transcript_manager.wsgi` again under `--threads 4` on 3.14.7t, which reported
`free_threaded_build: true` and `mode: threads`. Protocol detection was right
every time; the WSGI apps got the zero-config pool of 8, the ASGI apps got the
executor.

`transcripts` keeps its code in `src/`, so it is the shape the `--app-dir`
defect targets. It loaded from both `--app-dir src` and `--app-dir .` (it is
also installed as an editable package), and neither path was shadowed.

## Phase 1 — parity against `runserver`

Same routes under `m0serve` and `manage.py runserver`, raw HTTP/1.1, no
redirect following, diffed on status, headers and body after normalising what
is per-process by design (`Date`, CSRF token, session id). Home, admin index,
admin login, allauth login, a static asset, a 404, a 500, and a full login
round trip on each app.

**After the cookie fix, every remaining difference is one of three, and all
three are the server being itself:**

- `connection: keep-alive` — m0serve sends it explicitly; `runserver` does not.
- `x-thread: N` — which handler-pool thread served the request. Documented,
  and absent under `--blocking-threads 0`.
- Django's debug pages embed the request's own `host:port`, which differs
  because the two servers are on different ports.

Bodies were byte-identical on every route on all three apps, admin included.
The login round trip — `GET` the form, `POST` credentials, `GET` the
destination with the session — produced **identical headers at all three
steps** on `color-separation` and `textshelf`. Before the fix the same
comparison reported 15–24 differences per app, every one of them a cookie.

Two app-level failures appeared identically under both servers and are the
applications', not ours: `transcripts` answers `403` on `/accounts/login/`
(its dev auto-login middleware logs you in, and allauth's login view forbids
an authenticated user), and `textshelf` answers `500` on `/accounts/signup/`
(no `SocialApp` row in a scratch database).

## Phase 2 — the feature matrix

| property | result |
|---|---|
| static via WhiteNoise (`textshelf`) | works; **found defect 3** under concurrency on ASGI. After the fix, 200 fetches of a 232 KB file at concurrency 16 take 0.35 s against uvicorn's 0.29 s on the same app |
| static via `--static PREFIX=DIR` | works (`smoke-serve` covers it; not re-exercised here) |
| upload > 4 MB | **found defect 2.** After the fix: a 7.1 MB multipart upload under `--max-body 64m` reaches Django, is validated, stored, and processed. Over the cap the answer is a legible `413 Payload Too Large` before the body is read |
| `StreamingHttpResponse` under WSGI | buffered, as documented — and for `textshelf`'s never-ending SSE generators that means the response never completes and the thread is held. **Legible? No.** The client sees an open connection that yields nothing; nothing is logged. This is the documented limit meeting an app that does not know it, and it produced defect 4 |
| `StreamingHttpResponse` under ASGI | streams for real, chunk-framed |
| `FileResponse` / download (`color-separation`) | byte-identical zip to `runserver`, correct `Content-Type`, `Content-Length` and `Content-Disposition` |
| long-running view | `color-separation` runs its whole separation pipeline synchronously inside the request (`ImmediateBackend`); served correctly in every mode |
| view that calls out over HTTP | not reached by these apps' fixtures; the documented `_scproxy` hazard is unchanged and pinned by `smoke-wsgi` |
| management commands | `check`, `makemigrations`, `migrate`, `collectstatic`, `createsuperuser` all ran against the same settings; that is how the scratch databases were built |

## Phase 3 — the topology matrix

Each app, each mode: a route sweep, a 200-request burst at concurrency 16,
and 16 concurrent logins (a session write per request).

Every mode served every route correctly on all three apps, with **zero 5xx
and zero dropped connections in the bursts** — `--workers 1`, `--workers 4`,
`--blocking-threads 4`, `--workers 4 --blocking-threads 4`, and `--threads 4`
on free-threaded 3.14.7t (`transcripts`, which is the app whose dependency
tree is thread-clean).

The 16-concurrent-login column found nothing about the server and one thing
about the fixture: `textshelf` answers some of them `500` with
`sqlite3.OperationalError: database is locked`. That is the scratch SQLite —
the project runs PostgreSQL — and it reproduces at the same rate under
**gunicorn `--workers 4` and under `runserver`**, so it is attributed there
rather than here. `transcripts` answers all 16 with the same app-level `403`
as in Phase 1. `textshelf` also rate-limits its own auth endpoints (`429`),
which is the application working as designed.

## Phase 4 — the realtime retrofit (`textshelf`)

The claim is that a plain sync view can hold an SSE stream with two response
headers and no added infrastructure. `textshelf/notifications/` was the
honest test: an async `notification_stream` view, an `async_subscribe`
generator over PostgreSQL `LISTEN/NOTIFY`, a polling fallback for SQLite, a
sync copy of both, and a hard dependency on running under Daphne.

The conversion is 20 lines of view:

```python
@login_required
@require_http_methods(["GET"])
def notification_stream(request):
    response = HttpResponse(f"event: connected\ndata: {head}\n\n",
                            content_type="text/event-stream")
    response["M0-Hold"] = "stream"
    response["M0-Channel"] = NotificationPubSub.get_user_channel(request.user.id)
    return response
```

plus one `m0pub.publish` beside the existing `pg_notify` in the publish path,
deferred to commit the same way.

**Measured result: `+52 / −293` across two files — a net 241 lines removed**,
because holding the connection in the server strands all four subscription
implementations (sync, async, and a polling fallback for each: 236 of
`pubsub.py`'s 336 lines), and with them the `psycopg` import that existed
only for `LISTEN/NOTIFY`.

It works: four `EventSource` clients held across **two prefork workers**, one
`POST` to an ordinary synchronous Django view, and all four receive the same
numbered event. No Daphne, no asyncio, no `LISTEN/NOTIFY`, and the database
is SQLite — where the code being replaced had no delivery mechanism at all,
only a 5-second poll.

**The degradation is better than what it replaces, which was the surprise.**
Under gunicorn the converted view answers a short buffered
`text/event-stream` that the browser's `EventSource` reconnects on — the GRIP
property. The *original* async view under gunicorn hangs: 12 s with no bytes,
and the worker never serves again. So this is not a change that trades
portability for the feature.

The honest caveats: the app loses its SQLite polling fallback (nothing
delivers under gunicorn now, where before it polled — at the cost above), and
`M0-Channel` is one channel per connection, which suits a user-scoped
notification stream and would not suit an endpoint that multiplexes several.

**Verdict: a diff a maintainer would accept.** The claim survives contact.

## Phase 5 — soak

6,000 keep-alive requests per app over a mixed route set (home, admin, login,
static, 404, an authenticated page), sampling RSS, open descriptors and
threads.

| app | RSS at 1k → 6k | fds | db fds | threads | errors |
|---|---|---|---|---|---|
| `transcripts` | 103.6 → 105.1 MB | 34 → 34 | 0 | 13 | 0 |
| `color-separation` | 99.6 → 101.6 MB | 71 → 71 | 0 | 13 | 0 |
| `textshelf` | 261.4 → 267.9 MB | 52 → 52 | 8 | 13 | 0 |

Descriptors and threads are flat — nothing accumulates per request, and
Django's `CONN_MAX_AGE = 10` holds its connections steady rather than growing
them. RSS rises 1.5–6.5 MB over the 5,000 requests after warm-up and then
stops, which is Python's allocator reaching steady state rather than a leak;
`smoke-django`'s 10k-request guard still measures 0 KB against the bare app.
Throughput was 363–819 rps single-worker on a laptop, which is not a
benchmark and is not offered as one.

## What this changes about the guards

Every fix landed with something that fails without it, and each was checked by
sabotage rather than assumed:

- `test_response_cookies.mojo` — 4 of 6 cases fail when `add_raw` is reverted
  to parse-and-reserialise.
- `test_config.mojo::test_recv_buffer_limit_covers_headers_plus_body` — fails
  when `recv_buffer_limit()` returns the bare field.
- `smoke-django` — now reads the session cookie off the wire and requires
  `expires`, `HttpOnly`, `Max-Age` and `SameSite=Lax`, because curl's cookie
  jar stores name and value only and could never have seen this.
- `smoke-serve` — a 3 MB body at the default cap and 7 MB at `--max-body 8m`
  must be `200`; 5 MB and 9 MB must be `413`. Both sizes straddle the old
  ceiling.
- `smoke-asgi` — 32 concurrent 4 KB-piece streams, every body byte-exact.
  **This one paid for itself on its first CI run**, and is why the fix looks
  the way it does. It passed on macOS and failed on Linux: two streams short,
  because the budget had been sized against a 256 KB socket buffer and Linux
  clamps `SO_RCVBUF` to `net.core.rmem_max` and charges each datagram's whole
  `skb` against it. Raising the number would have made this platform pass and
  left the next to find out, so the number stopped being load-bearing instead
  — a full channel now waits (detached, so the loop can drain it) rather than
  dropping. Verified by removing the budget rather than trusting it: at
  `_ASGI_TOTAL_WINDOW = 64 MB`, effectively no budget at all, 64 concurrent
  streams still deliver every byte and log no drops.
- `smoke-blocking-threads` — two views that never return, `SIGTERM`, and the
  process must exit inside 20 s naming what it abandoned.

## Revisited after stage 1 (2026-08-26)

`--realtime` composing with `--blocking-threads` changed the answer this
record originally implied, so the question was re-measured rather than
re-reasoned. Same laptop, same scratch SQLite, five events 0.3 s apart,
arrival time of each event recorded by a client that reads incrementally —
`curl -w %{time_starttransfer}` will not do, because several of these
servers send an empty first body chunk that satisfies it.

| server | a **sync** generator | an **async** generator |
|---|---|---|
| `runserver` | 0.31, 0.61, 0.92, 1.23, 1.53 — streams | all at 1.51 — buffered |
| daphne (their production) | all at 1.53 | 0.30, 0.61, 0.91, 1.21, 1.51 |
| uvicorn | all at 1.53 | 0.30, 0.61, 0.91, 1.21, 1.51 |
| m0serve, ASGI executor | all at 1.53 | 0.31, 0.60, 0.91, 1.21, 1.51 |
| m0serve, `--realtime --blocking-threads` | all at 1.53 | all at 1.51 |

Two things fall out, and the first is about their application rather than
any server. **`textshelf`'s AI streaming endpoints do not stream, on their
own production server.** `ai/views.py:summarize_submission` is a sync view
returning `create_sse_response(...)` over
`services.summarize_document_stream`, whose annotation is
`Generator[str, None, None]` — a *sync* generator, which Django's ASGI
handler must consume before it can serve it (it says so in a warning). Every
ASGI server buffers it identically; the token-by-token delivery the endpoint
is written for arrives in one lump at the end. The rows above are a
same-shaped instrument rather than their endpoint (which needs an API key),
but the shape is what decides it, and the shape is theirs.

The second: **m0serve's executor matches uvicorn and daphne to the
millisecond in both rows.** Whatever streams under them streams under it,
and what buffers buffers everywhere.

That changes the recommendation this record's Phase 4 pointed at. Before
stage 1, holds cost the pool, so the hybrid mount was the only shape with
both isolation and working streams. Now:

| shape (4 workers) | pub/sub streams | AI endpoints | fast path, 8 slow views | app changes |
|---|---|---|---|---|
| `--realtime --blocking-threads 4` | held by the server: +2 MB per 200, no Python state, no database connection | buffered — exactly as they are today under daphne | 0.3 ms | convert 4 pub/sub endpoints (the notifications one was −241 lines) |
| `--mount /=wsgi --mount /rt=asgi`, pool 4 | executor: one Postgres connection each in production | buffered — as today | 0.7 ms | none but a URL prefix |
| daphne, as deployed | as today | buffered | 4.9 ms | none |

**The AI endpoints cost nothing to move**, because they are already
buffered wherever they run. So the choice is now between the cheapest way
to hold a stream and no application changes at all — and what still forces
it to be a choice is that `--realtime` and `--mount` cannot be combined
(measured: exit 1, refused before the bind). An application that wants
holds for its pub/sub streams *and* an ASGI mount for genuinely async ones
needs two processes today.

For the ROADMAP's stage 2 that is a re-ordering, recorded there: **the
`--mount` half unblocks a real application, the WebSocket half does not.**
`textshelf` opens no WebSocket against its own server — the `new WebSocket`
calls in its JavaScript address a local MCP process — so the ambiguity the
refusal was written for cannot arise for it.

## What would make this worth repeating

It already was: four defects in one pass, three of them invisible to any
application written to test this server. The next pass should use applications
with shapes these three lack — a background worker, an app behind a proxy with
`SECURE_PROXY_SSL_HEADER`, an upload-heavy API, and something that is not
Django.
