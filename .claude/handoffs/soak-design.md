# Design: the 1.0 soak — corpus, traffic model, harness

Written 2026-09-01, after the session that closed M11/F5/I13/F12. `milestones`
now reports **0 rows between here and 1.0**; what remains is the soak (last
run against 0.11.0, current 0.16.0 — STALE) and 4 known issues.

## 0. The constraint that decides everything else

The soak's value comes from **authorship, not from size**. `docs/REAL_APP_VALIDATION.md`
states the rule and earned it: three of its five defects "could not have come
from `apps/`… they need a real cookie policy, a real static-file middleware,
and a real never-ending response respectively."

So a demo application we design cannot retire the STALE marker, however
adversarial we make it — it would be `apps/`-shaped by construction, and we
would only find the bugs we already knew to look for. **The demo half already
exists anyway**: `apps/hybrid_mix` (Django + Flask + FastHTML at three
prefixes, one process), `apps/datastar_todo`, `apps/ws_chat`,
`apps/django_realtime`, `apps/notes_api`. What does not exist is a corpus of
third-party subjects and a driver that can soak them.

**The milestone mechanics** (`scripts/milestones.py`, `_real_app_version`):
the gate reads the **first** `m0serve X.Y.Z` string in
`docs/REAL_APP_VALIDATION.md` and compares it to `pyproject.toml`'s version.
One marker only — a second one anywhere in the page becomes a silent fallback
and defeats the sabotage that proves the gate can miss an unreadable record.
A pass that is meant to retire STALE rewrites the opening line; a partial pass
adds a section that names the version in prose (the 2026-08-31 re-soak is the
worked example of the second shape).

## 1. What has never met a real application

Everything below is gated by a smoke *we* wrote against an app *we* wrote.
That is what the last two passes' yield says about such gates: gating an
ungated row keeps finding real defects, and so does pointing a real app at a
gated one (the keep-alive cap was gated, and `textshelf` still broke it).

| shape | real-app evidence today |
|---|---|
| WSGI request/response, sessions, auth | all three apps ✓ |
| ASGI buffered | `textshelf` ✓ |
| ASGI streaming (`FileResponse`, `StreamingHttpResponse`) | `textshelf` + WhiteNoise ✓ — found defects 3 and the keep-alive cap |
| WSGI streaming from a pool thread | `textshelf`'s SSE ✓ — found defect 4 |
| uploads, CPU-bound views | `color-separation` ✓ — found defect 2 |
| **WebSockets** | **none.** Every byte of WS evidence is `apps/ws_*`, `apps/asgi_bare`, or Autobahn — and Autobahn's client always closes first, so app-initiated closes are structurally outside it |
| **`--mount`, per-mount lanes, several executors** | **none.** Landed in 0.12–0.16, entirely post-dating the three-app pass; `smoke-hybrid` is ours |
| **`--realtime` holds** | only our own retrofit *of* `textshelf` — our code in their tree |
| **Range / conditional GET / 304 storms** | **none** |
| **a client that aborts mid-stream** | **none** under load (isolated gates only) |
| **behind a real proxy** (`X-Forwarded-*`, `SECURE_PROXY_SSL_HEADER`) | **none** — named as a gap by the record's own closing line |
| **a background worker / out-of-process producer** | **none** — same |
| **`--threads` on free-threaded CPython** | attempted, blocked: `psycopg-binary` ships no free-threaded wheel |
| **a non-Django app with a real dependency tree** | **none** — `apps/fasthtml_demo` and `apps/flask_wsgi` are ours |

Two of those are the highest-risk rows on the sheet: the WebSocket seam and
`--mount` are where 0.12–0.16's churn landed, and no application that was not
written here has ever touched either.

## 2. The corpus

Ordered by expected defects per hour of setup. Each row says which gap it
closes; **none of these were written to test this server**, which is the
point. Every one must clear phase 0 (`m0serve --doctor`) before it earns a
slot — that is a 60-second check and it is where a bad candidate drops out.

| # | subject | what it is | gaps it closes | protocol | risk |
|---|---|---|---|---|---|
| 1 | **Wagtail `bakerydemo`** ([wagtail/bakerydemo](https://github.com/wagtail/bakerydemo)) | the official demo of a real CMS, maintained, `venv`-installable | baseline, CPU (image renditions generated on request), uploads, a **static/admin storm** with conditional GETs, search, forms | Django WSGI **and** ASGI | low — standard `wsgi.py`/`asgi.py` |
| 2 | **NiceGUI** ([zauberzeug/nicegui](https://github.com/zauberzeug/nicegui), its own `examples/`) | FastAPI + Vue/Quasar; `python-socketio` mounted at `/_nicegui_ws/` | **the WebSocket application the corpus has never had** — and socket.io brings the transport dance for free: HTTP long-poll first, upgrade to WS, app-initiated close in *both* directions | ASGI, `ui.run_with(app)` for an external server | medium — verify the socket.io mount serves under `m0serve` at phase 0 |
| 3 | **httpbin** (PSF fork, [psf/httpbin](https://github.com/psf/httpbin)) + a client's suite | a standard HTTP behaviour fixture, Flask/WSGI | `/drip`, `/stream/N`, `/stream-bytes/N`, `/delay/N`, `/range/N`, `/bytes/N`, `/gzip`, `/redirect-to`, `/cookies`, `/status/N` — a checklist of wire behaviours written by people who never heard of us | WSGI (pool + streaming path) | low to install; the *suite* is the work (see below) |
| 4 | **Gradio** (any Space-shaped demo, `gr.mount_gradio_app` into FastAPI) | ML UI: SSE queue, chunked uploads, Range on media, a large static bundle | modern streaming + upload + Range in one app, huge dep tree | ASGI | medium — `mount_gradio_app` + external uvicorn is documented; confirm the queue's SSE survives phase 0 |
| 5 | **`AnswerDotAI/fasthtml-example`** | ~25 small third-party apps | **breadth**, cheaply: `00_game_of_life` (multi-client WS), `04_sse`, `file_upload_form_example`, `infinite_scroll`, `image_app_*`, `xtermjs` | ASGI (`main:app`) | low — same shape as `apps/fasthtml_demo`, which already serves |
| 6 | **`starfederation/datastar-python` `examples/`** | per-framework snippets (Django WSGI **and** ASGI, FastAPI, Litestar, Sanic, Quart, FastHTML) + `sdk-test.py` | the **`--mount` fixture we lack** (their Django WSGI and ASGI examples are the same app twice), plus `sdk-test.py` as an SSE-framing conformance run against `m0-datastar` | both | low |
| 7 | **any of the above behind Caddy**, plus one worker-backed app (Paperless-ngx is the stretch: Celery, large PDFs, Range) | deployment shape rather than an app | `X-Forwarded-*` / `SECURE_PROXY_SSL_HEADER`, and a producer outside the request | — | Paperless-ngx needs redis + tesseract; budget a day or drop it |

**On the user's own suggestions.** FastHTML examples are worth running and are
cheap, but they are ~25 apps of 50–200 lines: they buy breadth, not depth, and
they will not produce a defect of the "every `Set-Cookie` lost `expires`"
class. Datastar's Python examples are snippets rather than an application —
their value here is the mount pair and `sdk-test.py`, not a soak. Neither is a
substitute for rows 1 and 2, and the local Django apps are exactly right that
they under-stretch: all three are Django, all three are request/response +
SSE, and **none has a WebSocket, a mount, a proxy or a worker between them.**

**What to keep from the old corpus.** Re-run `transcripts` (the baseline,
`src/` layout, `--app-dir`) and `color-separation` (uploads, CPU) against
0.16.0 — that alone is what the record says is outstanding, and it is a few
hours. But do not stop there: a re-run of a corpus that has already been
soaked twice mostly re-proves what two passes proved.

## 3. The traffic model — what "soak" has to mean now

Phase 5 today is *6,000 keep-alive requests over a mixed route set, sampling
RSS, fds and threads.* That shape found nothing on its own; the keep-alive-cap
defect fell out of it only because one route happened to be hit 700 times, and
it presented as **9 truncated bodies under a clean `200`**. Two lessons:

**(a) Assert bytes, not statuses.** Three of the six defects across both
passes were silent — correct status line, short or empty body, nothing in the
log. A driver that counts non-2xx would have passed every one. The soak must
checksum every response against a baseline.

**(b) Get the baseline from another server.** Run the same manifest against
`gunicorn` (WSGI) or `uvicorn` (ASGI) first, record status + headers + body
digest per route, then require m0serve to match modulo the three known
per-server differences (`connection`, `x-thread`, the debug page's host:port).
That is the record's phase-1 parity method generalised, and it is what makes
byte-exactness checkable without understanding the app.

**(c) Four populations at once, for hours.** The bugs this server produces
live at the seams between shapes, and every one of the three hardest to find
(the shim's slot ownership, the WS credit gate, the close linger) needed
*concurrency plus recycling plus contention*, not volume:

| population | why |
|---|---|
| short keep-alive bursts, near `max_connections` | forces **slot recycling** — a stream's slot reused within an iteration or two, which is the shape that found the shim-ownership bug |
| long-lived streams and sockets (SSE, WS, big downloads) | the credit windows, the close linger, the idle sweep |
| big transfers both ways (uploads, Range downloads) | the receive-buffer ceiling, the chunk channel, sendfile |
| **abandoners** — clients that abort mid-stream and mid-upload | `stream_lost`, credit refunds, `peer_eof`, the half-close path. A browser does this every time someone navigates away; the record has never done it |

Plus three dimensions the record has no row for at all:

- **Cross the keep-alive cap on every route class**, deliberately — ≥100
  requests per connection on a streamed route, a WS upgrade, and an ordinary
  route. That is the one previous silent defect; it should now be traffic, not
  luck.
- **One window under CPU contention** (`stress-asgi`'s hogs). Timing-shaped
  bugs here do not reproduce on an idle laptop; that is the entire reason
  `stress-asgi` is pre-release rather than CI.
- **Churn**: `SIGTERM` + restart under load, `--reload` on a touched file,
  and a killed worker — each with in-flight streams. The drain's 5 s budget
  and `stop_and_join` have never been measured against a real app's
  never-ending generator except by accident (defect 4).

Sample throughout: RSS, fds, db fds, threads, **and `/__metrics`** — F5 just
landed latency histograms, and this is the first workload that can say whether
they move under a real app.

## 4. The harness — the part worth writing ourselves

Not an app. A driver, a manifest format, and a recorder.

- **`scripts/soak.py`** — manifest-driven. A manifest per subject: base URL,
  route classes (method, body, auth, whether streamed), upload fixtures, WS/SSE
  endpoints, and the population mix + duration. Two modes: `--baseline` (drive
  gunicorn/uvicorn, write digests) and `--run` (drive m0serve, compare).
- **Records through `scripts/emit.py`**, so the numbers land in the same
  recorder CI already renders — with its three properties intact (never fails,
  no-op without `$M0_RESULTS`, selftest). Then a soak's RSS curve is comparable
  to the CI smokes' and to the previous pass.
- **A browser population, via Playwright.** Half the missing shapes are only
  produced by a browser: conditional GETs and 304s, Range on media, parallel
  connection pools, socket.io's upgrade, and app-initiated aborts. The
  `webapp-testing` skill in this environment already drives Playwright; point
  it at bakerydemo and NiceGUI rather than hand-rolling a client.
- **`poe soak`**, **not in CI** — it needs third-party checkouts and hours.
  It belongs in `docs/RELEASING.md` beside `stress-asgi` and `autobahn`.
- **A self-test for the comparator**, per the standing rule that negative
  results need one: feed it a doctored capture with one truncated body and one
  changed header and insist both are flagged. A digest checker that cannot
  fail is the "green having tested nothing" trap, and this one is the whole
  instrument.

For row 3 the harness is different and cheaper: **point an existing client
test suite at a running m0serve.** `pytest-httpbin` starts httpbin in a thread
and injects a `.url`; a `conftest.py` that instead starts `bin/m0serve` and
yields the same shape turns `requests`' / `urllib3`'s / `httpx`'s integration
suites into thousands of third-party assertions about our wire behaviour.
Caveat to check first: `pytest-httpbin` has had no release in over a year, so
pin what installs and be ready to drive httpbin directly instead.

## 5. Order of work

1. **Harness + manifest, proven against a known subject.** Build `soak.py`
   against `apps/hybrid_mix` (which is already the three-framework mount
   shape) so the driver is debugged before a real app is in the picture. Then
   its self-test.
2. **bakerydemo** — phases 0–5. Highest-value single subject; also the
   cheapest re-baseline for the rows `transcripts` and `color-separation`
   cover.
3. **NiceGUI** — the WebSocket gap. Expect this to be where defects are, and
   budget for them: the WS seam is the newest code in the tree.
4. **httpbin + a client suite** — breadth of wire behaviour, in an afternoon.
5. **`transcripts` and `color-separation` against 0.16.0** — closes what the
   record explicitly leaves open.
6. **Gradio, the FastHTML sweep, the Datastar mount pair** — as time allows.
7. **Proxy and worker shapes** — the record's own named gaps; cheapest as a
   Caddy front-end over subject 2 or 4 rather than as a new application.

## 6. Definition of done

- Every defect lands **fix + gate + sabotage, together**, with the sabotage
  caught by the invariant it names — and a SPEC row (or a re-pointed one)
  citing the gate, declared per F12.
- `docs/REAL_APP_VALIDATION.md` rewritten with the pass, its opening
  `m0serve X.Y.Z` marker moved to the version actually run, and **no second
  marker**.
- `uv run poe milestones` reports the soak current; `check-docs`,
  `check-milestones` and `sabotage-spec` green.
- A section in that record naming what the corpus still lacks — the closing
  line is load-bearing, and this pass's version of it should be honest about
  what a browser-driven population did and did not reach.

---

# Phase 0 results — 2026-09-01, subjects 1 and 2

Run against `bin/m0serve` 0.16.0, macOS 26 / M4, CPython 3.13.6, clean clones
under `/tmp/soak/`, each in its own venv installed from the project's own
requirements. **Both subjects are viable. No server defect found yet.**

## Wagtail bakerydemo — VIABLE

Wagtail 8.0 / Django 6.0, installed from `requirements/development.txt`,
`manage.py migrate` + `load_initial_data` against scratch SQLite, settings
`bakerydemo.settings.dev` unmodified.

| phase | result |
|---|---|
| 0, load | `--doctor` `ok: true`, exit 0, both entry points. `bakerydemo.wsgi` → `protocol: wsgi`, zero-config pool of 8. `bakerydemo.asgi` → `protocol: asgi`, executor on, pool 0 |
| serve | `/`, `/blog/`, `/breads/`, `/locations/`, `/search/?query=`, `/static/…` all 200; `/admin/` 302. No traceback in the server log |
| 1, parity vs `runserver` | **9 routes, 9 equivalent.** 7 byte-identical (headers and body). `/admin/login/` differs on exactly one line — Wagtail's embedded `CSRF_TOKEN`, per-request by design; blanking every `value=` attribute leaves the files identical. `/static/css/main.css` differs by four security headers, and **gunicorn agrees with m0serve byte for byte** — `runserver`'s `StaticFilesHandler` bypasses the middleware stack. That is the same difference the 2026-08-31 re-soak resolved the same way |

**One modification was necessary and is recorded here**: bakerydemo ships
`wsgi.py` only, so `bakerydemo/asgi.py` was added — the file
`django-admin startproject` generates, plus the two lines `wsgi.py` itself
adds (`dotenv.load_dotenv()`, the dev-settings default). The WSGI row is
unmodified.

**A design claim measured and wrong.** The corpus table above credits
bakerydemo with the **Range / conditional-GET** gap. It does not deliver it:
under `dev` settings media is served by Django's debug static view, which
emits `Last-Modified` and no `ETag`, advertises no `Accept-Ranges`, and
answers `Range: bytes=0-99` with a full `200` — **and gunicorn does exactly
the same**, so this is Django, not us. Two consequences:

- To get that shape from bakerydemo, run it the way its own
  `requirements/production.txt` implies — with **WhiteNoise**, which does
  ETag, conditional GET and Range. That is a deployment-shape change, not an
  application change, and is what `textshelf` already exercised for statics.
- The gap is narrower than written anyway: `--static`'s own Range handling is
  gated (SPEC J2–J5). What is untested is an **application-produced `206` and
  `Content-Range` crossing the WSGI/ASGI bridge.**

## NiceGUI — VIABLE, and it closes the WebSocket gap

NiceGUI 3.16.0 on FastAPI, served as `main:fastapi_app` from the project's own
`examples/fastapi/` (which exists precisely to run NiceGUI under an external
ASGI server via `ui.run_with`). Nothing modified.

| phase | result |
|---|---|
| 0, load | `--doctor` `ok: true`, exit 0, `protocol: asgi`, executor on |
| serve | `/` (FastAPI JSON) 200, `/gui` 307 → `/gui/` 200 (9.8 KB page). No traceback |
| socket.io **polling** | `GET /gui/_nicegui_ws/socket.io/?EIO=4&transport=polling` → `200`, a real handshake: `0{"sid":…,"upgrades":["websocket"],…}` |
| socket.io **WebSocket** | `101` accepted; engine.io OPEN received; socket.io `40` CONNECT acked with a session sid; **three server-initiated ping/pong cycles over 12 s** at the app's own 4 s `pingInterval` |
| **real browser, end to end** | Chromium via Playwright: page renders, a checkbox click round-trips over the WebSocket and the server patches the DOM (`body--light` → `body--dark`), a reload reconnects on a fresh socket. 3 frames sent, 6 received, **zero page errors** |

The mount path is `/gui/_nicegui_ws/socket.io/`, not `/_nicegui_ws/…`:
`ui.run_with(fastapi_app, mount_path='/gui')` mounts NiceGUI's whole app —
socket.io included — under the prefix. Worth knowing before writing a
manifest. Note also that the browser opens `transport=websocket` **directly**
(`implicit_handshake=true`), so the long-poll path is a fallback rather than
the first leg; a manifest that wants the polling transport exercised has to
ask for it.

## What this changes about the plan

- Both subjects clear phase 0, so the ordering in §5 stands.
- NiceGUI is confirmed as the WebSocket subject: a real third-party app, a
  real browser, closes initiated from both ends, and server-driven pings —
  none of which the corpus has ever had. It is now the highest-value target
  for phases 3–5, because the WS seam is the newest code in the tree.
- Neither subject has produced a defect yet, which is expected: phases 0–1 are
  the shallow end. Every defect in both previous passes came from phases 2–5
  (concurrency, streaming, uploads, soak) — which is where the harness in §4
  is the blocker, and therefore the next thing to build.
- Reusable assets left in `/tmp/soak/`: `parity.py` (status + normalised
  headers + body digest across two servers — the seed of the harness's
  baseline mode), `sio_probe.py` (raw engine.io/socket.io WS probe),
  `nicegui_browser.py` (the Playwright population, in miniature).

---

# The harness, as built — 2026-09-01

`scripts/soak.py` + `scripts/soak_manifests/*.json`, `poe soak-selftest`
(deterministic) and `poe soak-apps` (pre-release, in `docs/RELEASING.md`).

**Manifests are data, so the driver never learns an application.** A manifest
names route classes (`short`, `stream`, `slow`), uploads, and WebSocket
endpoints, plus the headers to ignore and the body substitutions to apply
before digesting. Two ship: `hybrid_mix.json` (four mounts, three frameworks,
two executors and a pool — every population except uploads and sockets) and
`asgi_bare.json` (those two).

**Modes.** `--baseline URL` records status + normalised headers + a body
digest per route from a REFERENCE server; `--capture FILE` then holds m0serve
to it. Without a capture the driver self-pins the first response per route and
holds every later one to that — weaker, and the report says so, because it
cannot catch a defect that was already there on request one.

**Populations, all concurrent**: `burst` (keep-alive connections issuing 120
requests each, deliberately over the cap of 100), `stream`, `bulk` (uploads
and slow views), `abandon` (reads for 0.5 s then vanishes — alternating clean
FIN and `SO_LINGER 0` RST — and immediately reuses the freed slot), and
`websocket` (hand-rolled frames, echo verified, closed from the client side).
Sampling is RSS/fds/threads **plus the server's own `/__metrics`**, so a
sample includes `http_active_connections` and `http_pool_available` — a soak
that never looks at slot occupancy cannot tell a leaked slot from a busy one.

## What building it found

**1. The self-test found a hole in the comparator on its first run.** A
`body_sub` pattern greedy enough to absorb a truncation — `"csrf": ".*` —
collapses a body and its own first twenty bytes to the same text, so a
truncated response digests identically to a whole one and the soak reports
nothing, forever, on that route. The instrument would have been silently
blind in exactly the way the three silent defects were. Fixed with
`truncation_visible()`, an **empirical** lint (does truncating THIS body
still change its normalised form?) rather than a regex heuristic: `--baseline`
refuses a route whose patterns blind it, naming the pattern, and the
self-pinning path fails the same way. The self-test now proves all three
legs — that `compare()` genuinely cannot see through a greedy pattern, that
the lint refuses it, and that the lint still passes a narrow one.

**2. The first run's three "failures" were the driver, not the server.** The
abandon population waited for a fixed byte count from a route that emits ~15
bytes every 150 ms, so it timed out reading rather than abandoning. Abandoners
now leave on a deadline. A driver whose own client bug reports as a server
failure is worse than no driver.

**3. One measured cross-server difference, now recorded in the manifests.**
Against a uvicorn-recorded baseline, the only difference in 293,615 responses
was framing: **uvicorn sends `Transfer-Encoding: chunked` for an app body with
no declared length; m0serve buffers it and sends `Content-Length`.** Both
legal, decoded bytes identical, and m0serve's is the better keep-alive shape.
It is in each manifest's `headers_ignore` with the measurement written beside
it — per-manifest rather than a driver default, so every future manifest has
to acknowledge it rather than inherit it silently.

**4. Failures are deduplicated by shape.** That first cross-server run
reported the same header mismatch 260,000 times and buried everything else;
the report now ranks distinct shapes with counts.

## Results

| run | verified | failures | RSS | fds | threads | slots |
|---|---|---|---|---|---|---|
| `hybrid_mix`, 30 s, self-pinned | 260,489 | 0 | 83.6 → 83.8 MB | 75 flat | 16 flat | 1015 flat |
| `asgi_bare`, 30 s, self-pinned | 434,954 | 0 | 54.9 → 58.2 MB | 43 flat | 6 flat | 1014 flat |
| `asgi_bare`, **240 s, against a uvicorn baseline** | **3,548,236** | **0** | 56.9 → 60.0 MB, **flat from 40 s** | 43 flat | 6 flat | 1014 flat |

The long run crossed the keep-alive cap 29,534 times, opened 129,765
WebSocket connections carrying 778,590 echoed messages, and abandoned 956
connections mid-body — each followed at once by a request on the recycled
slot. No defect, which is the expected result against applications written to
test this server; the point of this stage was the driver.

**The task can fail.** Sabotaging `asgi_bare.json`'s stream byte count made
`poe soak-apps` exit 1 with the failure named and counted, confirming the
trailing `echo` does not mask the status (the guards are `|| exit 1`).

## What is still missing before a real subject

- A **browser population.** Playwright drove NiceGUI by hand in phase 0; it is
  not in the driver, and conditional GETs, 304s, Range and parallel
  connection pools come only from a real browser.
- **Churn**: SIGTERM + restart, `--reload`, a killed worker, each with
  in-flight streams. The driver stops its own server at the end; it does not
  yet restart it mid-run.
- **CPU contention** — one window under `stress-asgi`'s hogs.
- Authenticated routes: a manifest has no login step, so every real subject's
  session-bearing pages are currently out of reach.

---

# Login and churn, as built — 2026-09-01 (later the same day)

Both landed in `scripts/soak.py`; `poe soak-apps` now has three legs (SIGTERM
churn, `--reload` churn, uploads + sockets). `scripts/soak_manifests/bakerydemo.json`
is the first real-subject manifest and the worked example for both.

**Login.** A manifest `login` block is a CSRF form round trip — GET the form,
extract the token by a named pattern, POST, then GET a `check` route that must
be 200 (a 302 from the POST alone is what a wrong password produces, so the
redirect is not the proof). Every jar is per session, never global; `auth`
routes get one round-robin, anonymous routes get none (a public page fetched
with a session renders differently — Wagtail's userbar). N sessions log in
concurrently at startup and the bulk population logs in afresh every round,
so a session write per request runs for the whole soak. The login POST's own
response is verified against the capture: `Set-Cookie` is normalised to
`name=X; expires=X; <attributes>`, so the attributes are the assertion and a
cookie minted with a new value is the same cookie — defect 1's exact shape.

**Churn** (`--churn-every S --churn-mode sigterm|reload`, needs `--serve`).
SIGTERM must exit 0 inside `--drain-budget`, leave no child behind (children
are recorded before the signal and checked after), and readiness must return.
Reload touches the manifest's `reload_touch` (nanosecond mtime; nothing for
git to see) and waits for the supervisor's own `reload N complete` line.
Connection errors are tolerated between the signal and readiness and nowhere
else; a body cut short is a failure even inside the window. RSS growth is
measured within the last epoch, since a restart is a fresh process. Under a
supervisor the driver samples the WORKERS, summed, not the parent.

## What building it found

1. **A capture recorded under one set of normalisation rules compared under
   another is wrong on every route and looks like the server changed.** The
   first bakerydemo run reported 1,700 failures in 17 shapes, all of them
   the capture predating an `Expires` normalisation and a new substitution.
   Captures now carry a fingerprint of (normalizer version, ignores, subs)
   and a mismatched one is refused with "re-run --baseline".
2. **The driver must keep bodies.** A digest says THAT two bodies differ;
   only bytes say WHERE. `--baseline` now writes each body beside the
   capture and a run dumps the first mismatching body per route — the
   site-history route cost two rounds of guessing before that existed.
3. **A real project has to be served from its own directory.** bakerydemo
   resolves templates relative to cwd; `--cwd` was added and the manifest
   says to give `--serve` an absolute `bin/m0serve`.
4. **Reload detection counted the word, not the line**, and never saw a
   reload the log plainly recorded (the banner ends in `reload`). Regex on
   `reload \d+ complete` now.
5. **The sampler spun at 20 Hz** after a churn was skipped near the end of
   the run (a due-but-skipped churn left `wait` at zero).

## Bakerydemo: three application non-determinisms, zero server defects

Every body difference between gunicorn and m0serve on bakerydemo's admin
traced to the application, and each was measured rather than assumed:

| difference | cause | evidence |
|---|---|---|
| `class="serious bulk-action-btn"` vs `"bulk-action-btn serious"` | `wagtailadmin_tags.py:525` builds it with a **set union** (`action.classes \| {"bulk-action-btn"}`) | ten `PYTHONHASHSEED` values split 4/6 between the orders; gunicorn's workers agree with each other because they fork from one master |
| `168 model log entries` vs `168 page log entries` | site history names whichever log model `log_action_registry.get_log_entry_models()` (a set) yields first | four seeds on m0serve alone: 3 and 5 say `page`, 4 and 6 say `model` |
| `Expires: <request time>` on every admin page | Django's `never_cache` stamps the request's own time | normalised in the driver to `<http-date>` (presence kept, timestamp dropped) |

Plus `N minutes ago` on site history, two-unit `timesince` included. All
four are bounded substitutions that pass the blinding lint.

## Results

| run | verified | failures | notes |
|---|---|---|---|
| hybrid_mix, 24 s, SIGTERM every 7 s | 198,946 | 0 | 2 drains, 185 ms max, window 655 ms, no orphans |
| hybrid_mix, 24 s, reload every 7 s | 201,560 | 0 | 2 reloads detected in 0.2 s; **no connection errors at all** — the supervisor holds the listener across a reload |
| **bakerydemo, 240 s, vs gunicorn, 4 sessions + 402 logins** | **28,781** | **0** | RSS 196.8 → 207.3 MB, then released to 196.0 at 220 s: net −0.8 MB. fds, threads, slots flat |
| **bakerydemo, 75 s, SIGTERM every 25 s** | 8,730 | 0 | drains **0.13 s and 0.26 s** with sessions, logins, streams and abandoners in flight; no orphans; 11,567 tolerated connection errors inside 1.2 s of windows, none outside |

**The first real subject has now been soaked with login and churn and found
nothing in the server.** That is a result, not an absence of one: the
2026-08-26 pass found four defects at this depth on its first app. The
shapes still missing from bakerydemo's manifest are uploads (Wagtail's image
upload is a multipart POST behind the admin — the login now makes it
reachable) and WebSockets (none; NiceGUI is that subject).

## Next

1. bakerydemo image upload as an authenticated `uploads` entry (multipart
   needs a small extension to the bulk population).
2. NiceGUI manifest: its socket.io endpoint needs an engine.io-aware
   `websockets` entry (the current WS population speaks raw echo), or a
   Playwright click-through per phase as in phase 0.
3. A CPU-contention window (`--hogs N`) — ~20 lines, deliberately last.
4. Then the record: a full pass on bakerydemo + NiceGUI + transcripts +
   color-separation against 0.16.0, written into
   `docs/REAL_APP_VALIDATION.md` with the version marker moved.

---

# textshelf, locally — 2026-09-01 (late)

The dog-food candidate, run the way it will run on Fly: `config.asgi` on the
executor as a daphne drop-in, **Postgres** (the notification stream is an
async view over psycopg LISTEN/NOTIFY, so SQLite would not exercise it),
`config.settings.local`, a scratch database derived from the developer's own
`DATABASE_URL`, one superuser. Manifest: `scripts/soak_manifests/textshelf.json`.
Checkout and captures in `/tmp/soak/textshelf/`, `textshelf-daphne.json`,
`textshelf-gunicorn.json` (bodies beside each).

## Getting the driver through the door cost four things, all the app's

| obstacle | what it was | what the driver learned |
|---|---|---|
| login POST answered `200` with no error | `ACCOUNT_LOGIN_METHODS = {"email"}` — the field is the address, not the username | nothing; the manifest names the field |
| then `200` again, a JSON `{"success": true}` with no form | `BotDetectionMiddleware`: a request scoring ≥ 60 on `users/fingerprint.py` gets a FAKE success (no UA +50, bot-ish UA +40 — `curl`, `python`… — no `Accept-Language` +20, `Accept: */*` +15, no `Accept-Encoding` +10, no `sec-ch-ua` +5). curl scores 75. | a manifest-level `headers` block, sent on every request; the driver sends its own UA (`http.client` sends none, which alone is +50) and leaves `Accept` alone |
| `AuthRateLimitMiddleware`: 10 login POSTs per IP per 15 min | the app's own limiter; a driver that trips it measures the limiter | `login.min_interval_seconds` paces the bulk population's logins; `--sessions 3` |
| a stream that never ends on its own | the LISTEN/NOTIFY SSE hold, 30 s idle timeout | an `abandon` route class: abandoners only, never read to completion, skipped by `--baseline` |

## Results

| row | verified | failures | notes |
|---|---|---|---|
| **ASGI executor vs daphne, 90 s, 3 sessions** | 32,843 | **0** | 405 abandons of the LISTEN/NOTIFY stream mid-hold |
| **ASGI executor vs daphne, 240 s** | 81,819 | **0** | RSS sawtooth 163 ↔ 266 MB (see below); fds 81–125 churn (asgiref's thread pool, as the record noted); threads 16–19 |
| **ASGI executor, SIGTERM every 30 s** | 30,933 | **0** | both drains **exactly 5.0 s, exit 0**: held streams never end, so the drain waits its whole budget and leaves. By design — but Fly's `kill_timeout` must exceed it, and every SSE client reconnects on deploy |
| WSGI + zero-config pool of 8, with abandoners | 1,689 | **13 client timeouts** | **the whole server stalled** — see below |
| WSGI + pool of 8, no abandoners | 23,883 | 0 | clean; the stall is the SSE hold and nothing else |
| daphne itself under the identical workload (comparator) | 103,932 | 0 | RSS **174 ↔ 278 MB, the same sawtooth** — the oscillation is the application |

**The WSGI stall, precisely.** `notification_stream` is an `async def` view
returning a `StreamingHttpResponse` over an async generator; under WSGI
Django consumes it synchronously (its own warning is in the log) and the
generator blocks in LISTEN/NOTIFY for its 30 s idle timeout. A pool thread
streaming it cannot see the client's disconnect until the generator yields,
so an abandoned client pins the thread for up to 30 s, and eight abandoned
clients — the abandon population manages that in four seconds — are the
whole pool. Every other request then queues behind them until the client's
30 s timeout. The log at shutdown: *"8 handler thread(s) still inside the
application 5 s after the drain; exiting without them"*. This is the
documented WSGI limit (CLAUDE.md, "a generator asleep between events is
the bounded straggler at shutdown") meeting an app whose generators sleep
for 30 s — bounded at shutdown, but a full stall in service. **Not a server
defect; a deployment-shape rule for the cutover: textshelf's SSE views run
on the executor (or as `--realtime` holds), never on WSGI pool threads.**
Worth one honest line in the record: the "bounded straggler" framing
describes shutdown, and in service N abandoned holds are N held threads.

**RSS.** m0serve's process oscillates 163 ↔ 266 MB over four minutes;
daphne's oscillates 174 ↔ 278 MB over the same four minutes of the same
workload, sampled the same way. Same period, same amplitude, m0serve ~10 MB
lower at both ends. The application allocates and releases ~100 MB
periodically; the server is not leaking. m0serve also showed a **~490 MB
spike in its first 20 s** on every start that daphne's warm process could
not be compared against — watch the first minute after a Fly deploy.

**Throughput is not compared here**: the m0serve four-minute run shared the
machine with the WSGI diagnostic, the daphne run had it to itself.

## What this says about the Fly plan

- **Serve `config.asgi`.** Confirmed as the drop-in: 145,595 responses
  byte-identical to daphne across three runs, with logins, abandoned holds
  and SIGTERM churn. The WSGI row is ruled out for this app by measurement,
  not preference.
- **`kill_timeout` > 6 s** in `fly.toml`; drains take the full 5 s budget
  whenever SSE holds are open, which in production is always.
- **Bot detection is a client property**, so a browser is fine; but any
  health check or synthetic probe pointed at an auth POST will get the fake
  200 — worth knowing before reading a monitor.
- Remaining before staging: the multipart upload row (submissions'
  `htmx-upload-chunk`, reachable now that login works), and a Dockerfile
  with the wheel from the GitHub release.

---

# transcripts and color-separation — 2026-09-02, and the first server defect

Both re-run against 0.16.0 with the driver; the record is rewritten in
`docs/REAL_APP_VALIDATION.md` with the marker moved. PR #205 (the driver)
merged; this work is on `claude/soak-record`.

**The server defect (SPEC D9, open).** A request body still arriving at
SIGTERM holds the drain to its 5 s deadline: `_run_shutdown`'s loop
dispatches `EVFILT_WRITE` only, so a half-received upload is neither read
on nor closed. Found because the uploads population kept 9.7 MB POSTs in
flight and every color-separation drain took 5.1 s; bisected (abandoners
alone 0.05 s, streams alone 0.08 s, uploads + abandoners 5.09 s), then
reproduced bare with `scripts/drain_upload_probe.py` against
`apps/asgi_bare`. The fix is sized in the ROADMAP section: mid-request
slots keep read interest through the drain; gate = the probe as a smoke
step, two-sided; sabotage = revert the read dispatch. **Not fixed in this
session** — it is a change to the event loop's drain, one concern, its own
PR.

**Driver additions this round**: multipart form uploads (CSRF from a form
page, a real file, `follow` to the page the 302 lands on), `verify: false`
status-only routes, `--supervised` for sampling a reference server's
workers, supervisor detection from argv (an app that spawns a child per
request — transcripts runs `typst` per PDF — had been summed as if it were
a worker), and a manifest `headers` block.

**Application issues found** are in the record's findings table and the
manifests' comments; the ones a maintainer would want:

- transcripts: README install path omits `django-watchfiles` (settings
  lists it unconditionally); `init_data --with-samples` fails on
  `students.owner_id NOT NULL`; `/static/` is served by runserver only
  under the dev settings.
- color-separation: `output/` is source AND gitignored, so a clone cannot
  serve a request; the settings form's default `n_colors=8` fails its own
  spot-mode validator (max 6); `/job/N/preview/` answers 500
  (`int64 is not JSON serializable`) on a completed job.
- textshelf: SSE views stall any WSGI server (no guard enforces
  ASGI-only); bot detection fakes a 200 for `python`/`curl` user agents;
  no Postgres pool, so 4 processes exceed a default `max_connections`;
  `createsuperuser` makes no allauth `EmailAddress` row.

**Results** (all vs reference captures, zero body differences): transcripts
41,693 + 38,145 (four workers), color-separation 61,327 (WSGI, 370 uploads)
+ 18,274 (ASGI), the textshelf and bakerydemo rows already recorded.
