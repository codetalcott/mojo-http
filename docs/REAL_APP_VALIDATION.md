# Exercising the server against real applications

**A record. Last run 2026-09-04**, against m0serve 0.17.1 as merged at
`0766272` — the tree with the detached event loop (PR #229) — all four
applications, seven rows, in the newest section below. The full pass it
re-runs was **2026-09-01 and 2026-09-02**, against 0.16.0 (`bin/m0serve`
from the tree at `c823198`), macOS 26 on an M4, CPython 3.13.6. The plan
and the previous records are below and in the history of this file.

Every application this server had been tested against was written to test
it — until the 2026-08-26 pass below, which put three real Django projects
in front of it and found five defects. This pass re-runs those three
against a server five minor versions on, adds a fourth application nobody
here wrote at all, and replaces the pass's phase 5 — six thousand requests
sampling RSS — with a driver that asserts **bytes**: every response
compared, status and headers and body digest, against a capture recorded
from a reference server (gunicorn, uvicorn, daphne), under five concurrent
populations, with logins, and with the server SIGTERM'd and restarted
underneath. Three of the previous six defects were silent — a clean status
over a short or empty body — and a request loop passes every one.

## The four applications

Clean clones served from their own directories, each with its own venv,
scratch databases, their own settings unmodified except where the row says.

| app | shape | what it stressed |
|---|---|---|
| `transcripts` | Django 5, `src/` layout (`--app-dir src`), allauth, a dev auto-login middleware, PDFs rendered per request by a `typst` subprocess | the **baseline** and the CPU + generated-file row; SQLite |
| `color-separation` | Django 6, numpy/scipy/Pillow, `FileResponse` downloads, a synchronous separation pipeline | **9.7 MB multipart uploads** as a population, 4.7 MB zips and a 9.7 MB original as streams; SQLite; WSGI **and** ASGI |
| `textshelf` | Django 6.1, allauth, WhiteNoise, **Postgres**, four SSE endpoints (one an async generator over psycopg `LISTEN/NOTIFY`), daphne in production; the Fly dog-food candidate | the **hard case**, run the way it will deploy: `config.asgi` on the executor with a real login, bot detection, rate limiting, and holds abandoned mid-stream |
| Wagtail `bakerydemo` | Wagtail 8 / Django 6, the CMS's official demo | the **admin surface** behind a login: 60–130 KB pages, image renditions, a 670 KB static bundle; WSGI and ASGI |

## What was found

**One server defect, open, with its reproducer and its row.** And six
things that were not the server, each measured rather than assumed.

| # | finding | triage |
|---|---|---|
| 1 | **A request body still arriving at SIGTERM holds the drain to its deadline.** With 9.7 MB uploads in flight every color-separation drain took exactly 5.0 s; bisected to the uploads population alone, then reproduced directly: a 10 MB POST with 5 MB delivered when SIGTERM lands and the rest sent a second later is never read — the drain loop dispatches writes only — so the client is reset at 5.03 s and the process exits at 5.09 s. gunicorn's graceful timeout keeps reading. The request-side twin of the response-side defect `drain_inflight_probe.py` fixed. | **open** — SPEC D9 (`planned`), ROADMAP "The drain does not read a request body in flight", `scripts/drain_upload_probe.py` as the two-sided gate-to-be |
| 2 | textshelf's SSE views **stall the whole server under WSGI**: the `LISTEN/NOTIFY` async generator is consumed synchronously (Django's own warning), blocks 30 s per abandoned client, and eight abandoned clients hold the whole pool — every other request then times out. Without abandoners the WSGI row is clean; on the executor the same workload is clean with them. | **the documented WSGI limit meeting an app whose generators sleep 30 s** — bounded at shutdown as CLAUDE.md says, a full stall in service, which that sentence does not say. A deployment rule, recorded: this app's SSE views run on the executor or as holds, never on pool threads |
| 3 | textshelf at `--workers 4` fails with Postgres's `FATAL: sorry, too many clients already` | **the application**: per-thread connections, `CONN_MAX_AGE = 10`, no pool configured despite `psycopg[pool]` in its dependencies; four processes exceed a default `max_connections` of 100. daphne × 4 would do the same |
| 4 | bakerydemo bodies differ between gunicorn and m0serve in a CSS class order and site history's "model/page log entries" label | **Wagtail renders both from Python sets**, so they follow the interpreter's hash seed: ten seeds split 4/6 on the first, four seeds on m0serve alone split 2/2 on the second. gunicorn's workers agree with each other only because they fork from one master |
| 5 | transcripts' PDF and XLSX differ on every request at identical size | **timestamps and per-process font tags**: `/CreationDate`, `/ModDate`, XMP dates and IDs, typst's six-letter subset-font prefix (constant per process, four workers give four); openpyxl's creation second. All bounded substitutions that pass the driver's blinding lint |
| 6 | RSS oscillates ~100 MB with a ~100 s period on textshelf, and sits at 1.2 GB on color-separation | **the applications**: daphne under the identical workload oscillates the same (174 ↔ 278 MB against m0serve's 163 ↔ 266); gunicorn's two workers on color-separation sum to 1.5–1.8 GB and rising against m0serve's 1.2–1.3 GB flat |
| 7 | m0serve's process shows a ~490 MB spike in its first 20 s on textshelf, settling to ~170 MB | **unexplained**; daphne's warm process could not be compared. Watch the first minute after a deploy |

Finding 1 could not have come from `apps/`: it needs a multi-megabyte
upload in flight at the instant of the signal, which only a population
that uploads continuously produces. Finding 2 could not have come from
the previous pass either, whose textshelf row never abandoned a stream.

## Phase 0 — will it even load?

`m0serve --doctor` `ok: true` on every entry point: `transcript_manager.wsgi`
(`--app-dir src`), `halftone_studio.wsgi` and `.asgi`, `config.wsgi` and
`config.asgi`, `bakerydemo.wsgi` and an `asgi.py` added for it (the
`startproject` file; bakerydemo ships only `wsgi.py`). Protocol detection
right every time; WSGI apps got the zero-config pool of 8, ASGI apps the
executor.

Two applications did not load from a clean clone, and the doctor could see
only one of them. transcripts' README installs `.[dev]`, which does not
contain `django-watchfiles` although `settings.py` lists it
unconditionally (it is in the uv lockfile's dev group; `uv sync` works).
color-separation keeps real source under `output/` — `composite.py`,
`raster.py`, `vector.py` — and `.gitignore` excludes `output/`, so a clone
fails on its first request with `No module named 'output'`; the doctor
passed, because Django imports its URLconf lazily. **Phase 0 answers "does
the callable import", not "does the first request work".**

## Phase 1 — parity, byte for byte

Each application captured from a reference server and every response of
the soak held to it. The only differences that survived were named
substitutions (findings 4 and 5), a framing choice — uvicorn frames an
undeclared-length body as chunked where m0serve buffers it and sends
`Content-Length`; the decoded bytes are identical — and the four
security headers `runserver`'s `StaticFilesHandler` bypasses, on which
gunicorn agrees with m0serve byte for byte.

## Phases 3 and 5 — topology, churn, and the soak

Every row: five populations at once (keep-alive bursts at 120 requests per
connection, over the cap of 100; streams read to completion; uploads, slow
views and logins; WebSocket echoes where the app has any; abandoners that
vanish mid-body by FIN and by RST and reuse the slot at once), sampling
RSS, descriptors, threads and the server's own `/__metrics`. "verified"
is responses byte-identical to the reference capture.

| app | mode | seconds | verified | failures | churn | RSS |
|---|---|---|---|---|---|---|
| transcripts | WSGI, pool 8 | 150 | 41,693 | 0 | SIGTERM ×2, drains 0.14 s | 123.2 → 124.2 MB |
| transcripts | WSGI, `--workers 4 --blocking-threads 4` | 90 | 38,145 | 0 | SIGTERM ×1, 0.14 s, no orphans | 4 workers, 419 → 421 MB summed |
| color-separation | WSGI, pool 8, 370 uploads (185 of 9.7 MB) | 150 | 61,327 | 0 | SIGTERM ×2, **5.1 s each** (finding 1) | 1.24 → 1.28 GB (finding 6) |
| color-separation | ASGI executor vs uvicorn, 250 uploads | 90 | 18,274 | 0 | — | 1.32 → 1.31 GB |
| textshelf | ASGI executor vs daphne, 3 sessions | 90 | 32,843 | 0 | — | settles at ~170 MB (finding 7) |
| textshelf | ASGI executor vs daphne | 240 | 81,819 | 0 | — | 163 ↔ 266 MB sawtooth (finding 6) |
| textshelf | ASGI executor, churn | 100 | 30,933 | 0 | SIGTERM ×2, 5.0 s each: held streams never end, the drain waits its budget by design | 179 → 162 MB |
| textshelf | WSGI, pool 8, abandoners on | 90 | 1,689 | **13 timeouts** | — | **stalled** (finding 2) |
| textshelf | WSGI, pool 8, no abandoners | 60 | 23,883 | 0 | — | clean |
| textshelf | ASGI, `--workers 4` | 90 | 61,108 | 28,078 | drain 5.05 s | Postgres connection limit (finding 3) |
| bakerydemo | WSGI, pool 8, 4 sessions + 402 logins | 240 | 28,781 | 0 | — | 197 → 207 → 196 MB, flat |
| bakerydemo | WSGI, churn | 75 | 8,730 | 0 | SIGTERM ×2, 0.13 s and 0.26 s | — |

Descriptors and threads were flat in every clean row. `--threads` was
not run: none of the four dependency trees builds on free-threaded CPython
(psycopg-binary ships no wheel; the record above says the same).

## What this changes about the guards

- **The driver itself** (`scripts/soak.py`, `poe soak-apps`,
  `poe soak-selftest`): its comparator is a pure function with a
  self-test that found the driver's own first hole — a substitution greedy
  enough to absorb a truncation blinds the instrument — so a capture now
  refuses any route its patterns blind and carries a fingerprint of the
  rules it was recorded under. Sabotaging a manifest's byte count makes the
  task exit 1 naming the failure.
- **`scripts/drain_upload_probe.py`**, finding 1's reproducer and the gate
  the fix will land with, two-sided like its sibling: the upload must be
  answered whole, and the process must exit inside 3 s of the signal.
- Four manifests under `scripts/soak_manifests/` are the re-runnable
  record of each application's shape, including every substitution and
  the reason for it.

## Re-soak — 2026-09-04, against 0.17.1 as merged at `0766272`, all four applications

The event loop stopped holding a thread state while it serves (PR #229,
`docs/notes/detached-loop.md`): the default runtime shape of every pooled
and executor deployment changed, and the smokes that gated it were all
written here. So the corpus was run again the same night — the four
checkouts of 2026-09-01 under `/tmp/soak/`, each with its own venv on PATH,
`bin/m0serve` built from main at `0766272`, CPython 3.13.6 (the GIL build a
`pip install` gets), macOS 26 on an M4. Same driver, same five populations,
same reference captures except where noted. Raw driver outputs are in
`.claude/handoffs/soak-2026-09-04/`.

| app | mode | seconds | verified | failures | churn | RSS | fds / threads |
|---|---|---|---|---|---|---|---|
| transcripts | WSGI, pool 8 | 150 | 41,749 | 0 | SIGTERM ×2, drains 0.14 s | 120.2 → 124.4 MB | 69 → 72 / 13 → 13 |
| bakerydemo | WSGI, pool 8, 4 sessions + 300 logins | 180 | 21,980 | 0 | SIGTERM ×2, 0.14 s | 186.8 → 198.1 MB | 69 → 69 / 13 → 13 |
| color-separation | WSGI, pool 8, 361 uploads | 120 | 53,394 | 0 | SIGTERM ×1, 0.08 s | 0.95 → 1.30 GB | 136 → 142 / 17 → 17 |
| color-separation | ASGI executor vs uvicorn, 302 uploads | 90 | 20,980 | 0 | — | 1.11 → 1.60 GB | 132 → 128 / 20 → 20 |
| textshelf | ASGI executor vs daphne, 3 sessions | 180 | 71,669 | 0 | SIGTERM ×1, **0.19 s** | 176.1 → 158.7 MB | 96 → 92 / 17 → 16 |
| textshelf | WSGI, pool 8, no abandoners, 3 sessions | 60 | 24,588 | 0 | — | 497.3 → 195.2 MB (a startup transient) | 83 → 83 / 13 → 13 |

Every row: descriptors and threads flat, the server's free-slot count back
at its starting 1,015 at every sample (every slot returned), zero 5xx, and
800–1,850 abandoners per run (half FIN, half RST) absorbed. The
color-separation gigabytes are the application's image renditions, as in
the 0.16.0 record; textshelf's executor RSS fell over the run, the
sawtooth the record describes. **No server defect.**

**Two rows failed first, and neither was the server.** Recorded because
each cost an hour and the next pass should not pay it again:

- **transcripts, 2,798 "failed" stream reads** — every read of the typst
  PDF. Its normalised digest no longer matched the 2026-09-01 capture; a
  fresh gunicorn from the same checkout produced the *same* digest as
  m0serve, four fetches out of four, so the capture was stale: the soak's
  own traffic had changed the database it renders from (`db/transcript.db`
  modified that evening). Re-captured from gunicorn, re-run: the row above.
  The rule this adds to the driver's page: **re-baseline before every
  pass**, not only after a normalisation change — and before blaming the
  server, fetch the route from the reference server and compare.
- **textshelf, 3 of 3 logins answered 200** in both modes. The runs had
  been pointed at the database the checkout's `.envs/.local/.django` names
  — the *development* database — where no soak account exists; daphne
  answered the same 200. The soak's database is the scratch `textshelf_soak`
  (the 0.16.0 record's setup), and the rows above are against it. A soak
  account created in the development database while diagnosing this was
  removed the same minute.

**One observation, not investigated.** textshelf's churn drain took 0.19 s
with two stream clients and an abandoner in flight, where the 0.16.0
record measured 5.0 s ("held streams never end, the drain waits its budget
by design"). What changed between is D9 (2026-09-02): the drain now runs
ordinary loop passes, so a stream whose client has gone is closed rather
than waited for. Consistent, and not a defect either way; a pass that wants
the claim can open a stream, hold it, and time the drain.

**What this pass did not do**, unchanged from the record above:
`--threads` (none of the four dependency trees builds on free-threaded
CPython), NiceGUI (phase 0 only, no manifest), the proxy and worker shapes.

## What would make this worth repeating

The shapes these four still lack: a WebSocket application (NiceGUI passed
phase 0 — its socket.io transport works in a real browser through the
executor — and has no manifest yet), a real proxy in front
(`X-Forwarded-Proto` → `SECURE_PROXY_SSL_HEADER`, which textshelf on Fly
will supply), a background worker, and free-threaded `--threads`. And a
week of real traffic, which is the plan.

---

**The previous record. Run 2026-08-26**, against 0.11.0 (the PyPI-shaped wheel,
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
| 5 | `--app-dir` is appended to `sys.path`, not prepended | Confirmed again at the time: a probe app reported `--app-dir` at position 5, after site-packages. It did **not** bite any of the three (no top-level module name collides with an installed package in any of them), which is why it was a latent hazard rather than a visible failure. | **fixed in 0.12.0** — `prepend_to_path` puts `--app-dir` at `sys.path[0]` the way gunicorn, uvicorn and `runserver` do, and `smoke-serve`'s shadowing case (a project module named like an installed package) pins it; struck through in [Known issues](ROADMAP.md#known-issues) |

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
| `StreamingHttpResponse` under WSGI | buffered, as documented — and for `textshelf`'s never-ending SSE generators that means the response never completes and the thread is held. **Legible? No.** The client sees an open connection that yields nothing; nothing is logged. This is the documented limit meeting an app that does not know it, and it produced defect 4. **Since 2026-08-27 it streams**: a pool thread produces it through the loop's chunk channel, chunk by chunk (`smoke-wsgi-stream`); the thread returns when the client leaves, and a generator asleep between events is the bounded straggler at shutdown rather than a hang |
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
buffered wherever they run. So the choice was between the cheapest way to
hold a stream and no application changes at all — and what forced it to be
a choice was that `--realtime` and `--mount` could not be combined
(measured the day this was written: exit 1, refused before the bind).

**That is no longer true, and this pass is why.** The ROADMAP entry it
produced was implemented the same day: `--realtime` now composes with
`--blocking-threads`, with `--mount`, and with WebSocket holds under both
(ROADMAP, *Hold on a pool thread*, stages 1–3). So the row this table calls
"convert 4 pub/sub endpoints" no longer costs the pool or the ASGI mount —
an application can hold its pub/sub streams, run its generator streams on
an executor mount, and keep pool isolation for its slow views, in one
process. What is left for `textshelf` is application work: converting the
four endpoints, and making `ai/streaming.py`'s generator async so it
streams at all.

## Re-soak — 2026-08-31, against 0.16.0, `textshelf` only

Five minor versions landed in five days after the record above — `--mount`,
per-mount lanes, the batched pump, `ExecutorPort`, the WebSocket credit gate,
the close linger — all on the request path, none of it seen by a real
application. `textshelf` was re-run first because it is the app with four SSE
endpoints, so it stresses the seam that churned most.

**It found one defect, and the defect was on the ASGI path the WSGI record
above could never have reached.** Clean clone, scratch SQLite,
`config.settings.local`, the 0.16.0 wheel, CPython 3.13.6, macOS 26 on an M4.

| phase | result |
|---|---|
| 0, load | `--doctor` `ok: true` on `config.wsgi` and `config.asgi`; protocol detection right, WSGI got the pool of 8, ASGI the executor |
| 1, parity | 10 routes. Two apparent differences against `runserver` both resolved in m0serve's favour by measuring **gunicorn**: static-file headers (runserver's `StaticFilesHandler` bypasses the middleware stack; gunicorn's headers are byte-identical to m0serve's) and the debug page's env table (`wsgiref` copies `os.environ` into the environ, gunicorn and m0serve do not). Against gunicorn the only m0serve-only header is `x-thread`, and every residual environ key is a legitimate per-server one — `wsgi.multithread: True` correctly reporting the pool |
| 3, topology | `--workers 1`, `--workers 4`, `--blocking-threads 4`, `--workers 4 --blocking-threads 4`, `--blocking-threads 0`, and ASGI. Every route correct, 192/192 burst at concurrency 16, 16/16 concurrent logins, zero 5xx. `--threads` not run: `psycopg-binary` ships no free-threaded wheel, so the 3.14t venv cannot be built |
| 5, soak | 6,000 keep-alive requests over a mixed route set |

| | RSS 1k → 6k | fds | db fds | threads | errors |
|---|---|---|---|---|---|
| WSGI | 167.2 → 171.5 MB | 69 → 69 | 8 | 13 | 0 |
| ASGI | 177.5 → 216.0 MB | 58–110 | 3–56 | 7 | **9 truncated** |

The WSGI row matches the 0.11.0 shape: +4.3 MB over 5,000 requests, flattening
to +0.4 MB across the last 2,000, with descriptors, database descriptors and
threads all flat and the thread count identical at 13. 540 rps, inside the
record's 363–819 range. The ASGI descriptor and RSS churn is `asgiref`'s
thread pool opening a connection per thread — application behaviour, not a
leak.

### The defect: the keep-alive cap destroyed the response it fired on

Nine of the 6,000 ASGI requests came back truncated, all of them on the same
124 KB WhiteNoise file, at intervals of exactly 700 requests — every hundredth
time that route was hit. `max_keepalive_requests` is 100.

Isolated on one connection, and the two faces are the same bug:

| request 100 of a keep-alive connection | before | after |
|---|---|---|
| streamed body (124 KB `FileResponse`) | `200`, `Content-Length: 124926`, **0 bytes** | complete |
| WebSocket upgrade | `101`, **no frame ever** | 101 and a live echo |
| ordinary 45-byte response | `Connection: close` + complete body | unchanged |
| same file under WSGI | `Connection: close` + complete body | unchanged |

`_finish_response` clears `should_close` for a stream and for a 101, because
each owns its connection until it ends. The cap check below those branches was
guarded by `not should_close` — precisely the state they had just established
— so the two shapes that had opted out were the two it caught, and
`_after_send` closed the slot as soon as the head drained, before any body
frame arrived over the chunk channel. Both faces are silent: correct status
line, nothing in the server log.

Gated by `poe smoke-keepalive-cap` (SPEC A3), whose third phase asserts the
cap still fires for an ordinary response — without it the gate would pass on
a build whose cap never fires. Four sabotages: reverting the fix, each guard
alone, and raising the cap, each caught by the phase that should catch it.

The `m0serve X.Y.Z` marker in this file's opening line is the ONE the
milestone gate reads, and it deliberately stays at the version the full
three-application pass was run against. A second marker anywhere in the page
would become a fallback for `_real_app_version` and silently defeat the
sabotage that proves the gate can miss an unreadable record — which is why
this heading says "against 0.16.0" rather than naming the binary.

**This pass is not the 1.0 soak.** `transcripts` and `color-separation` have
not been run against 0.16.0, so the record above still stands at 0.11.0 for
them and the milestone stays stale until they are.

## What would make this worth repeating

It already was: four defects in one pass, three of them invisible to any
application written to test this server. The next pass should use applications
with shapes these three lack — a background worker, an app behind a proxy with
`SECURE_PROXY_SSL_HEADER`, an upload-heavy API, and something that is not
Django.
