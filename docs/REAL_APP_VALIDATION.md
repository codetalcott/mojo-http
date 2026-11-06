# Exercising the server against real applications

**A record. Last run 2026-11-02**, against m0serve 1.16.0 on main at
`1a3a0796`, the 1.17.0 train's code, all four applications, six rows, in
the current soak below. The full pass it re-runs was **2026-09-01 and
2026-09-02**, against 0.16.0 (`bin/m0serve` from the tree at `c823198`),
macOS 26 on an M4, CPython 3.13.6. The earlier re-soaks, the 2026-08
records and the full production record are
[a dated note](notes/the-soak-record.md).

<!-- The headline above is the line `poe milestones` reads for the server's
soak: `**Last run DATE**, against m0serve X.Y.Z`, on one line, ahead of every
other such line outside "The application layer". Move it with each re-soak. -->

The record is current while it is at most two minor versions behind
`pyproject.toml`'s version; `poe milestones` reports it (at 1.16.0
against 1.17.0: MET; it reads STALE at 1.19.0).

Every application this server had been tested against was written to test
it — until the 2026-08-26 pass, which put three real Django projects
in front of it and found five defects. The 2026-09-01 pass re-runs those three
against a server five minor versions on, adds a fourth application nobody
here wrote at all, and replaces the pass's phase 5, six thousand requests
sampling RSS, with a driver that asserts **bytes**: every response
compared, status and headers and body digest, against a capture recorded
from a reference server (gunicorn, uvicorn, daphne), under five concurrent
populations, with logins, and with the server SIGTERM'd and restarted
underneath. Three of the previous six defects were silent: a clean status
over a short or empty body. A request loop passes every one.

## The four applications

Clean clones served from their own directories, each with its own venv,
scratch databases, their own settings unmodified except where the row says.

| app | shape | what it stressed |
|---|---|---|
| `transcripts` | Django 5, `src/` layout (`--app-dir src`), allauth, a dev auto-login middleware, PDFs rendered per request by a `typst` subprocess | the **baseline** and the CPU + generated-file row; SQLite |
| `color-separation` | Django 6, numpy/scipy/Pillow, `FileResponse` downloads, a synchronous separation pipeline | **9.7 MB multipart uploads** as a population, 4.7 MB zips and a 9.7 MB original as streams; SQLite; WSGI **and** ASGI |
| `textshelf` | Django 6.1, allauth, WhiteNoise, **Postgres**, four SSE endpoints (one an async generator over psycopg `LISTEN/NOTIFY`), daphne in production; the Fly dog-food candidate | the **hard case**, run the way it will deploy: `config.asgi` on the executor with a real login, bot detection, rate limiting, and holds abandoned mid-stream |
| Wagtail `bakerydemo` | Wagtail 8 / Django 6, the CMS's official demo | the **admin surface** behind a login: 60–130 KB pages, image renditions, a 670 KB static bundle; WSGI and ASGI |

## The current soak — 2026-11-02, against 1.16.0 on main at `1a3a0796`, all four applications

**The staleness rule, ahead of the 1.17.0 train.** The 1.14.0 pass is
three minors behind 1.17.0, past the limit of two, so the train would read
it STALE. What moved under these applications since: the fixes of 1.15.0
and 1.16.0, and on main for 1.17.0 the loop's connection limits, the
comment that follows an SSE event (I47) and loopback by default (M31).
Under the limits, a full loop takes a slot back from an idle connection
(C23), a pass drains only the streams with output (C24), and a loop the
open-file limit cannot hold at its count holds what it leaves, the raise
counting two descriptors a connection on Linux (C25). Every keep-alive
request in the rows crosses C23's queues, every held stream C24's drain. `bin/m0serve` reports
1.16.0: the version moves on the release branch, and the code is the
train's. The access log is off in every row, as before.

`/tmp/soak/` had not survived, so every checkout was made fresh:
transcripts at `00dcb7a`, unchanged; bakerydemo at `c8f8255`, still on
GitHub though upstream has moved to Wagtail 8.1 (`890285b`); textshelf at
`7ada52ed`, 160 commits on from `7479ee7`, against its scratch database
`textshelf_soak`, which took 32 new migrations and kept its soak user; and
color-separation at `b927272`, two commits on, both moving its m0serve
pin. CPython 3.13.6 (3.12.11 for color-separation and bakerydemo), Django
6.0.4, 6.0.9 under Wagtail 8.0.1, 6.1.2 and 6.1.1; gunicorn 26.2.0,
uvicorn 0.54.0, daphne 4.2.3; macOS 27 on an M4. textshelf no longer has
the env file the older passes sourced (removed upstream on 2026-09-09),
so only `DATABASE_URL` and `DJANGO_SETTINGS_MODULE` were set, as the
2026-10-09 scripts did. Every reference capture was re-recorded the same
evening, with no route failing. One manifest moved: textshelf's
`components.css` is 106,118 bytes at `7ada52ed`, and its pin moved with
it. textshelf's venv, which imports `m0serve.m0pub`, carries the wheel
built from the same tree. Raw driver outputs and the scripts that set up
the corpus, recorded the captures and drove the rows are in
`bench/soak/2026-11-02/`.

| app | mode | seconds | verified | failures | churn | RSS | fds / threads |
|---|---|---|---|---|---|---|---|
| transcripts | WSGI, pool 8 | 150 | 46,750 | 0 | SIGTERM ×2, drains 146 ms max (window 709 ms) | 118.9 → 123.6 MB | 83 → 85 / 13 → 13 |
| bakerydemo | WSGI, pool 8, 4 sessions, 346 logins | 180 | 22,773 | 0 | SIGTERM ×2, drains 156 ms max (window 1104 ms) | 173.3 → 180.9 MB | 86 → 83 / 13 → 13 |
| color-separation | WSGI, pool 8, 328 uploads | 120 | 49,819 | 0 | SIGTERM ×1, drains 248 ms max (window 1000 ms) | 0.98 → 1.25 GB (finding 6) | 145 → 152 / 18 → 18 |
| color-separation | ASGI executor vs uvicorn, 256 uploads | 90 | 19,960 | 0 | — | 1.07 → 1.35 GB (finding 6) | 140 → 131 / 29 → 32 |
| textshelf | ASGI executor vs daphne, 3 sessions | 180 | 82,185 | 0 | SIGTERM ×1, drains 146 ms max (window 955 ms) | 177.1 → 287.7 MB (below) | 118 → 104 / 19 → 17 |
| textshelf | WSGI, pool 8, no abandoners, 3 sessions | 60 | 26,843 | 0 | — | 495.7 → 194.2 MB (the startup transient) | 99 → 100 / 13 → 13 |

**248,330 responses verified byte for byte, zero failures.** No row's
active connections rose above the nine its populations open, free slots
mirroring them, so no loop was full and C23 had nothing to take back: the
rows cross its queue moves on every request, and `smoke-max-connections`
holds its taking.
Uploads: 256 of 256 landed under the executor, and in the WSGI row 327 of
328: the 328th was answered, and its landing check, a second request,
met the restart and was counted as tolerated, not wrong.

textshelf's executor row reads 177 → 288 MB, and is flat within each of
its two epochs: the first came down from its import's transient (489 MB
at 5 s) to 186 MB by 30 s and held there to the restart; the second
started at 177 MB, rose to 281 MB as its own transient landed, and held
at 281 → 288 MB to the end. The figure compares the second epoch's first
sample, taken before its transient, with its plateau, which had not yet
come down as the first epoch's had. The 2026-10-09 row's second epoch
came down within the row (173 → 183 MB).

Against 2026-10-09 the counts moved up in five rows and down in one:
transcripts 46,750 against 26,041, color-separation's WSGI row 49,819
against 41,955, textshelf's executor row 82,185 against 74,016,
textshelf's WSGI row 26,843 against 27,435. The rows assert bytes rather
than rate, so the figures are recorded and not explained.

**Nothing was found on the wire.**

## What the 2026-09-01 pass found

**One server defect, since fixed and gated.** And six things that were not
the server, each measured rather than assumed.

| # | finding | triage |
|---|---|---|
| 1 | **A request body still arriving at SIGTERM holds the drain to its deadline.** With 9.7 MB uploads in flight every color-separation drain took exactly 5.0 s; bisected to the uploads population alone, then reproduced directly: a 10 MB POST with 5 MB delivered when SIGTERM lands and the rest sent a second later is never read — the drain loop dispatches writes only — so the client is reset at 5.03 s and the process exits at 5.09 s. gunicorn's graceful timeout keeps reading. The request-side twin of the response-side defect `drain_inflight_probe.py` fixed. | **fixed** — SPEC D9, gated every PR by `Smoke test the drain with an upload in flight`; `scripts/drain_upload_probe.py` became the two-sided gate, and the write-up is [A request body still arriving at SIGTERM held the drain to its deadline](notes/request-body-at-sigterm.md) |
| 2 | textshelf's SSE views **stall the whole server under WSGI**: the `LISTEN/NOTIFY` async generator is consumed synchronously (Django's own warning), blocks 30 s per abandoned client, and eight abandoned clients hold the whole pool — every other request then times out. Without abandoners the WSGI row is clean; on the executor the same workload is clean with them. | **the documented WSGI limit meeting an app whose generators sleep 30 s**: a streamed body holds a pool thread ([RUNNING.md](RUNNING.md#limits-and-lifecycle)), so the stall is bounded at shutdown and total in service. A deployment rule, recorded: this app's SSE views run on the executor or as holds, never on pool threads |
| 3 | textshelf at `--workers 4` fails with Postgres's `FATAL: sorry, too many clients already` | **the application**: per-thread connections, `CONN_MAX_AGE = 10`, no pool configured despite `psycopg[pool]` in its dependencies; four processes exceed a default `max_connections` of 100. daphne × 4 would do the same |
| 4 | bakerydemo bodies differ between gunicorn and m0serve in a CSS class order and site history's "model/page log entries" label | **Wagtail renders both from Python sets**, so they follow the interpreter's hash seed: ten seeds split 4/6 on the first, four seeds on m0serve alone split 2/2 on the second. gunicorn's workers agree with each other only because they fork from one master |
| 5 | transcripts' PDF and XLSX differ on every request at identical size | **timestamps and per-process font tags**: `/CreationDate`, `/ModDate`, XMP dates and IDs, typst's six-letter subset-font prefix (constant per process, four workers give four); openpyxl's creation second. All bounded substitutions that pass the driver's blinding lint |
| 6 | RSS oscillates ~100 MB with a ~100 s period on textshelf, and sits at 1.2 GB on color-separation | **the applications**: daphne under the identical workload oscillates the same (174 ↔ 278 MB against m0serve's 163 ↔ 266); gunicorn's two workers on color-separation sum to 1.5–1.8 GB and rising against m0serve's 1.2–1.3 GB flat |
| 7 | m0serve's process shows a ~490 MB spike in its first 20 s on textshelf, settling to ~170 MB | **unexplained**; daphne's warm process could not be compared. Watch the first minute after a deploy |

Finding 1 could not have come from `apps/`: it needs a multi-megabyte
upload in flight at the instant of the signal, which only a population
that uploads continuously produces. Finding 2 could not have come from
the previous pass either, whose textshelf row never abandoned a stream.

## Phase 0: the import

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
passed, because Django imports its URLconf lazily. Phase 0 checks that the
callable imports. It does not send a request.

## Phase 1 — parity, byte for byte

Each application captured from a reference server and every response of
the soak held to it. The only differences that survived were named
substitutions (findings 4 and 5), a framing choice (uvicorn chunks an
undeclared-length body; m0serve buffers it and sends `Content-Length`; the
decoded bytes match), and the four security headers `runserver`'s
`StaticFilesHandler` bypasses, on which gunicorn agrees with m0serve byte
for byte.

## Phases 3 and 5 — topology, churn, and the soak

Every row: five populations at once (keep-alive bursts of 120 requests per
connection; streams read to completion; uploads, slow views and logins;
WebSocket echoes where the app has any; abandoners that vanish mid-body by
FIN and by RST and reuse the slot at once), sampling RSS, descriptors,
threads and the server's own `/__metrics`. "verified" is responses
byte-identical to the reference capture. Through 0.18.0 the bursts crossed
the keep-alive cap of 100. The cap has been 1000 since 0.19.0, so the
bursts stay under it, and `smoke-keepalive-cap` (SPEC A3) holds the cap.

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

- The driver itself (`scripts/soak.py`, `poe soak-apps`,
  `poe soak-selftest`): its comparator is a pure function with a
  self-test that found the driver's own first hole (a substitution greedy
  enough to absorb a truncation blinds the instrument), so a capture now
  refuses any route its patterns blind and carries a fingerprint of the
  rules it was recorded under. Sabotaging a manifest's byte count makes the
  task exit 1 naming the failure.
- `scripts/drain_upload_probe.py`, finding 1's reproducer and now its gate
  (SPEC D9), two-sided like its sibling: the upload must be
  answered whole, and the process must exit inside 3 s of the signal.
- Four manifests under `scripts/soak_manifests/` are the re-runnable
  record of each application's shape, including every substitution and
  the reason for it.

## FastHTML's and FastAPI's own examples, beside uvicorn — 2026-09-22

A separate pass, not the soak above. FastHTML's official examples — the
`examples/` of AnswerDotAI's `fasthtml` repository and the
`fasthtml-example` repository, 37 applications — and FastAPI's documented
chat room, served side by side under `bin/m0serve` from `main` at
`ef2811e` and under uvicorn 0.53.0: python-fasthtml 0.14.14, Starlette
1.6.0, CPython 3.13.6, macOS 27 on an M4. Each application ran from its own
copy per server, so no SQLite file or session key was shared; the same
scripted scenario went to both; the responses were compared with only the
port normalised, and both logs were read. The gates below are what the pass
left in the tree.

Most of what the FastHTML tutorial teaches matched: sessions and
`Beforeware` logins, fastlite writes, HTMX out-of-band swaps, toasts,
cookies, multipart uploads, `FileResponse` with ranges, gzip, streamed and
SSE responses under 40 concurrent clients, disconnect detection, lifespan,
WebSockets, and `live=True` under `--reload`. Under `--workers 2` both
servers lost a worker to fastlite's schema race at import; m0serve's
supervisor respawned it, and uvicorn carried on with one.

What did not match, most harmful first:

| found | SPEC | now |
|---|---|---|
| a `send` kept for a client that had left reached the next client on its recycled slot: FastAPI's documented chat room delivered a departed client's messages to a stranger | L20 | fixed |
| a disconnect hook's sends to the sockets still connected were refused | L20 | fixed |
| a WebSocket disconnect cancelled the task, so an `except WebSocketDisconnect:` cleanup never ran | L21 | fixed |
| a response waited for its `BackgroundTask` | L22 | fixed |
| an application error's own 500 — the `debug=True` page included — was replaced, and the traceback lost | L23 | fixed |
| a WebSocket whose application raised was closed with 1000 | L24 | fixed |
| sockets survive `exec`: a shell the application started held a client connection open | G16 | fixed |
| `application/octet-stream` on responses sent without a type; a HEAD's `Content-Length` rewritten to 0; `Content-Length: 0` on 204 and 304 | A21, K12 | fixed |
| a chunked request's scope carries both `transfer-encoding` and `content-length`; a module that calls `asyncio.create_task` at import cannot load | L25, L26 | fixed |

Three more failures were FastHTML's own and identical under both servers:
`setup_ws` reads `scope.client` as an attribute of a dict, the terminal
example's disconnect hook takes an argument FastHTML does not pass, and
fastlite's `db.create` races across workers at import.

**Re-run on the response heads, 2026-09-23** (A21, K12, L27; python-fasthtml
0.14.13, Starlette 1.6.0, uvicorn 0.53.0). The probe application's heads,
read beside uvicorn: FastHTML's default 404, a `RedirectResponse`, a 204, a
304, `HEAD` of a `FileResponse` and of a 5 MB page, and `HEAD` of a sync and
an async `StreamingResponse`, each HEAD followed by a second of listening
for bytes after its head. All eight now match on status, `Content-Type`,
`Content-Length` and `Transfer-Encoding`, and neither server sends a byte
after a HEAD's head. Before, the 404, the redirect, the 204 and the 304 each
carried `application/octet-stream`, the 204 and 304 a `content-length: 0`,
and the `FileResponse` HEAD `content-length: 0` where uvicorn sent 3145735.
The streamed HEAD was found while fixing the rest, on `apps/asgi_bare`: all
10,000 bytes of a 10,000-byte stream followed its head (L27).

**Re-run of every scenario, 2026-09-23** (after L25 and L26; the same
versions). Sixteen scenarios, the heads probe and `--workers 2`, m0serve
beside uvicorn. A GET's scope and a sized POST's now carry exactly the
headers uvicorn's do. Before, m0serve's GET added a `content-length: 0`.
A chunked POST's scope differs by design, `content-length: 7` where
uvicorn passes `transfer-encoding: chunked`, and so FastHTML's multipart
check still accepts a chunked upload under m0serve that it refuses under
uvicorn. `00_game_of_life`, unmodified, now exits 1 naming what its module
did and the lifespan fix, where it printed only `no running event loop`.
Every other difference is the harness's own:
- file timestamps;
- the order of a `Set` Starlette joins into `Allow`;
- traceback paths;
- `m0` in the lifespan state;
- the `%2F` recorded above.

FastHTML's own three failures are unchanged, and identical under both
servers.

## In production — 2026-09-12, textshelf's streams on the hold mount (m0serve 1.2.0)

Not a soak: a production record, the first use of the grant-verified hold
mount (SPEC I21) by an application nobody wrote for this server.
textshelf (Django 6.1, allauth, Postgres, one Fly machine, `--realtime
--blocking-threads 8`) moved its five SSE streams from `M0-Hold` views
onto `--mount /_m0/rt=hold`. Each view keeps its authentication and
membership check and, asked with `?grant=1`, signs its decision into the
stream URL (`m0serve.grant.stream_url`, bound to the session cookie, an
hour's TTL). A Mojo pool thread verifies the grant and holds, with no
Django request per connection.

Locally, on staging and on `textshelf.com`, the mount held the stream
through Fly's proxy with its `: open` head and a heartbeat at 15 s. It
refused a missing cookie, another session's cookie, an expired grant and
a malformed one, each by name. The production check ran from the owner's
signed-in browser. A grant that expires renews through the view; the
browser side of that, `held_stream.js`, runs on every page that opens a
stream and is in no gate. This is the server holding for textshelf, which
writes no Mojo, so it is not the application layer's soak.

## Shapes not yet covered

The shapes these four still lack: a WebSocket application (NiceGUI passed
phase 0, its socket.io transport working in a real browser through the
executor, and has no manifest yet), a background worker, free-threaded
`--threads`, and a week of real traffic. A real proxy in front
(`X-Forwarded-Proto` → `SECURE_PROXY_SSL_HEADER`) is covered by textshelf,
in production behind Fly's proxy since 2026-09-12 (the record above).

## The application layer

**Last run 2026-11-02**, against m0-http 1.16.0 — `unotes` at `e1ac0f8`, built by an `m0` 0.13.0 wheel cut from main at `1a3a0796`, the 1.17.0 train's code, on Mojo 1.2.0, macOS 27 on an M4.

The application is [`unotes`](https://github.com/codetalcott/unotes), a
reader over a private notes corpus, written outside this repository on the
documented path: `m0 new` from `m0` 0.1.0 as published, `Views` and
`Fragment[Htmx]`, a login on `m0_http.login`, the corpus read from SQLite
through `m0_sqlite`, deployed as an image to Fly.io, and taken through
four upgrades (0.2.0 to 0.5.0) with `m0 doctor`. Its `SOAK_LOG.md` is
the running record. It was written to exercise the layer, by this
repository's owner: it is the layer's first application outside `apps/`,
not an independent adopter, and what it found is rows here already —
`Query` (N36), `push=True` (N37), HEAD answered by GET (N38), SQLite opened
at run time (O17, O18, N39, N40), the scaffold's login guidance, and the
login module and `auth` template (N43–N45).

**The synthetic soak.** `scripts/soak.py` against a local `bin/server` on
the real corpus, `tools/soak_manifest.json` its manifest, driven by
`bench/soak/2026-11-02/layer_unotes.sh`. The
reference is the same binary's answer to each route alone; every response
under load is compared with it, status, headers and a digest of the body,
the scan figure and the CSRF token normalised. Six keep-alive bursts over
eleven routes, nine of them behind the session, four sessions signed in,
two clients that abandon a response mid-body (FIN and RST alternating,
paced at 50 ms) and at once reuse the slot, and a SIGTERM and restart
every 40 s with everything in flight.

| row | seconds | verified byte for byte | failures | restarts | worst drain | RSS | fds, threads |
|---|---|---|---|---|---|---|---|
| two workers, forked | 180 | 2,119,557 | 0 | 4, each exit 0 | 4 ms | 17,728 → 17,728 kB | 54 → 53, 2 → 2 |
| two loops on threads | 90 | 1,067,377 | 0 | 2, each exit 0 | 45 ms | 23,408 → 23,408 kB | 37 → 37, 7 → 7 |

5,983 and 2,989 abandonments in the two rows. A request that met a restart
and was refused or cut is counted apart and not as a failure (12,875 and
6,887), within a window of at most 533 ms a restart. The login population
stays off (`--bulk 0`): the manifest sets no interval for it, and on
2026-10-02 it signed in about 170 times a second until the client ran out
of local ports, every failure `OSError 49` on a connect and no response
wrong (unotes' SOAK_LOG, finding 15).

The application's source is its deploy on `m0` 0.12.0 and Mojo 1.1.0;
only the two pins moved, in a scratch clone, to `mojo==1.2.0` and the
`m0` wheel by its path (so no cached build of the same local version could
stand in; the installed framework was compared with the tree's, byte for
byte). It built unchanged across the Mojo 1.2.0 pin move, in 14 s with no
warning. `m0 doctor` read framework 1.16.0 and passed its checks once
given the application's environment (without `UNOTES_KEY` the application
refuses with 78, as it should), `m0 test` passed 3 of 3 files (37 tests),
and `smoke.sh` passed. The 2026-10-09 run, on 1.14.0, verified 1,762,770
and 881,953 in the same times, with the same zero; the rows assert bytes,
not rate.

**The deployed instance on 2026-10-02**, `unotes.fly.dev` on a
`shared-cpu-1x`, then on `m0` 0.4.0. Signed in that day: the list, a note
and the themes page each answer 200, and the list signed out is a 303 to the
login. The corpus scan on that CPU, `x-scan-us`, six requests of each:

| query | µs |
|---|---|
| no filter | 6–9, and 60 on the first request |
| `q=the` | 164–189, and 573 on the first |
| `q=football` | 1,227–1,517 |
| `q=zzzzqqqq` (no match, the whole corpus read) | 1,256–1,595 |

The same figures as on 0.1.0. A deploy with a reader mid-session, and a
phone that sleeps and reconnects, were taken on the deployed instance on
2026-09-24 with the phone emulated (the application's log, "the real use
the log owed").

**What this does not show.** The framework as published: this run's is
main's at `1a3a0796`, in a wheel not yet on the index. Traffic from anyone but its owner, an
application with writes (unotes reads), a stream, or a second author's
habits. The layer's write path is gated by `apps/fragment_notes`,
`apps/datastar_todo` and `apps/table_notes` inside the tree and has no
soak outside it.

textshelf, first named here, is not the soak: its streams moved onto the
built-in hold mount in production on 2026-09-12 (above), and it writes no
Mojo.

A record here opens with ONE line that `poe milestones` reads, the way the
server's does:

`**Last run DATE**, against m0-http X.Y.Z` — on a single line; the version is the framework the application was built from, `versions.framework` in `m0 doctor --json`, not the `m0` wheel's own number, which the reader does not accept.

It then names the application and the path it moved onto the layer, and
carries the server soak's table: requests verified byte for byte against a
reference, failures, churn, RSS. The milestone applies the server soak's
staleness rule to that version.
