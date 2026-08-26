# Changelog

Notable changes to `mojo-http`. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[SemVer](https://semver.org/) with the standard pre-1.0 caveat: **minor
versions may break the API**.

## [Unreleased]

### Documentation

- **Hold on a pool thread** (ROADMAP, under *Next*). The real-application
  pass produced one finding about the shape of the server rather than a
  defect in it: `--realtime` refuses `--blocking-threads`, so the cheapest
  way to hold a stream (M0-Hold: +2 MB per 200 held, no Python state, no
  database connection) costs the pool that cures the hostage pathology —
  measured on textshelf as a 1 543 ms fast-path p50 under `--realtime`
  against 0.3 ms with the pool, with eight slow views in flight. The entry
  records the numbers, the mechanism the executor already uses to solve the
  identical problem (a reserved begin frame the loop's handler turns into a
  subscription), a staged design for SSE holds then sockets, the narrower
  `--mount` refusal that follows from it, and what must be shown before it
  is built. Verdict recorded with it: the larger of the two is the
  difference between the realtime claim being demonstrable and deployable.

- **Three real Django projects, served — the record**
  ([REAL_APP_VALIDATION.md](docs/REAL_APP_VALIDATION.md)). The plan that
  file used to hold has been executed: `transcripts` (plain WSGI, `src/`
  layout), `color-separation` (numpy/Pillow pipelines, uploads, downloads)
  and `textshelf` (four SSE endpoints, three pubsub modules, WhiteNoise,
  djstripe) served from clean clones against scratch databases, through
  `--doctor`, byte-parity against `runserver`, the feature matrix, the
  topology matrix, a realtime retrofit and a soak. Four defects, all fixed
  below, three of which no application in `apps/` could have shown. After
  the cookie fix, every remaining parity difference on every route of all
  three apps is `connection: keep-alive`, `x-thread`, or Django's debug page
  echoing its own port.

- **The desktop-Mac hypothesis, and the packaging tension under it**
  (ROADMAP, Open questions). Recorded because the relevant decision is
  already shipped and otherwise invisible: `poe build-serve` pins
  `--target-cpu` to `apple-m1`, the *oldest* Apple Silicon, so the PyPI
  wheel deliberately forfeits M-series-specific capability — including the
  +sme/+sme2 matrix extension the build comment notes this M4 would
  otherwise target. The pin exists because the first release crashed with
  SIGILL in a clean container, so it is not a mistake to undo; it is a
  tradeoff that points the other way from "exploit the Mac's silicon", and
  the two should be reconciled deliberately. Also recorded: what has to be
  established first, including that this toolchain has no `gpu` module at
  all, and that the neural engine is a CoreML surface rather than something
  a language targets directly.


### Fixed

- **Every `Set-Cookie` an application set lost its `expires` and `SameSite`
  attributes.** The WSGI/ASGI bridge parsed each `Set-Cookie` line into a
  `Cookie` and re-serialised it, and that round trip was lossy four ways:
  `Expiration` is a stub whose `from_string` parses nothing, `SameSite`
  matched only lowercase values, a value was cut at its first `=` (base64
  pads with one), and any attribute the struct does not model was dropped.
  Django's session and CSRF cookies therefore reached every browser without
  `expires` or `SameSite` — a persistent cookie silently demoted to a
  session cookie, and a CSRF cookie without its defence. Application lines
  are now transmitted **verbatim** (`ResponseCookieJar.add_raw`), which is
  also the cheaper path on the measured response half of the bridge. Found
  by serving three real Django projects; `smoke-django` now reads the cookie
  off the wire and requires all four attributes, because curl's jar stores
  name and value only and could never have seen it.

- **Uploads between ~1.5 MB and `--max-body` were refused with `400`.** The
  per-connection receive buffer had its own 2 MB ceiling that `--max-body`
  never raised, so a body the server advertised as acceptable was rejected
  by the wrong check with the wrong status — under the default 4 MB cap too.
  The limit is now derived (`ServerConfig.recv_buffer_limit()` = headers plus
  body allowance, floored by `recv_buffer_max`), so raising the body cap
  raises the buffer with it. A 7.1 MB image upload to a real Django app
  found it.

- **Concurrent ASGI streams truncated each other, and enough of them wedged
  the executor.** The chunk credit window is per stream (64 KB) while the
  chunk channel is one shared `SOCK_DGRAM` pair, so N streams over-commit it;
  `send_stream_chunk` then dropped the datagram it could not place — a short
  body under a clean terminator, or, with the end frame dropped, a response
  that never completed at all. Twelve concurrent WhiteNoise `FileResponse`s
  under Django were enough. Now bounded globally (`_ASGI_TOTAL_WINDOW` in the
  shim, where waiting is an `await` rather than a Mojo spin that would hold
  the GIL against the very loop that has to drain the channel), with the loop
  keeping owed credit and retrying it when the ack channel is momentarily
  full. `smoke-asgi` runs 32 concurrent `FileResponse`-shaped streams and
  checks every byte.

- **`SIGTERM` never returned while a handler thread sat in a response that
  never ends.** A `StreamingHttpResponse` served under WSGI is buffered, so
  an SSE generator never returns and its pool thread never comes back;
  `stop_and_join` waited for it forever, turning `docker stop` into a
  `SIGKILL` after the grace period. The join now has the same 5 s budget as
  the drain (`ThreadSet.join_within`), after which the process exits naming
  how many threads it left inside the application. Nothing in the process can
  unwind Python on another thread, so leaving is the only correct answer;
  waiting was not.


- **`smoke-wheel` leaked a server on every run, and could pass against the
  wrong binary.** Nine orphaned `m0serve` processes accumulated over one
  day of development, all still `LISTEN`ing on port 8129, one of them still
  answering `200 OK` a day after the run that made it.

  Two independent defects. The launch was
  `(cd "$work/app" && env ... m0serve ...) &` — a *list*, which bash cannot
  exec-optimize, so `$!` was the **subshell** rather than the server.
  `kill $pid` killed the wrapper and left `m0serve` orphaned to init. Adding
  `exec` makes the subshell become the server, which is how
  `bench_mixed_workload.sh` had been doing it all along. And the `EXIT` trap
  only removed the temp directory, so every `fail` after the launch leaked
  one too; the server pid is in the trap now.

  The consequence was worse than untidiness. The server sets `SO_REUSEPORT`
  because prefork needs it, so the kernel adds a new listener **alongside**
  a stale one and load-balances between them: a leaked server from an
  earlier run can answer this smoke's request, and the assertions then pass
  against a binary that is not the one under test. `smoke-wheel` now refuses
  to start when 8129 already has a listener, naming the pids and the command
  to clear them.

  Verified by running the pre-fix task once (leaks exactly one process,
  `ppid 1`) against the fixed one (leaks none, on both the success and the
  failure path), and by putting a decoy listener on 8129 to trip the new
  refusal.

### Added

- **The isolation benchmark has an artifact, and the ratchet caught sixteen
  stale sentences.** Gate 3's last item. `bench/results/` now carries a
  `mixed-workload-*.json` — the pool's ~100x p99 claim, the largest effect
  in this repository and previously the only one with no machine-readable
  source — plus a post-pin re-run of the WSGI layer split.

  Re-rendering moved every derived figure, and `check_bench_prose` failed
  the build naming **all sixteen** prose sentences that had gone stale
  across README.md, docs/BENCHMARKS.md and docs/WSGI_PERFORMANCE.md, each
  with the value it claimed and the value the artifact computes. That is
  the whole reason it exists: the tables re-render themselves, and before
  this the sentences around them would have quietly kept the old numbers.
  Per-core ratio 0.83x → **0.85x**, bridge tax 1.44x → **1.36x**.

  Two findings the run itself produced. **Granian's `--blocking-threads`
  row is better than ours** — ~0.6 ms flat against our best ~2 ms — which
  is now on the page, because the honest claim is that the pool removes a
  hundredfold *stall*, not that it wins the tail that remains. And the
  earlier note that granian "is not in this repo's lock file" was wrong: it
  is, in the `bench` group at the pinned 2.8.1, one `uv sync --group bench`
  away. That is why its row had been missing from the isolation table.

  Recorded because it changes how these are read: **one anomalous round per
  run is normal on this box.** Three recorded layer-split runs each had
  exactly one round land well off the other two, in a different position
  each time, while their medians agreed to within 0.03 on the per-core
  ratio. Median-of-three is doing real work here, not ceremony.

- **The first screen leads with what the server is for.** Gate 5. All three
  surfaces that have a first screen now open on the same claim — *realtime
  from a synchronous Python app, with no added infrastructure* — with the
  hero shown as six lines of ordinary sync Django rather than described:
  README.md, `packaging/m0serve/README.md` (which is what PyPI renders, and
  is the one nothing was checking until this release), and `llms.txt`.

  The gaps are on the first screen rather than in an issue: no TLS or
  HTTP/2 (terminate at a proxy), the platform floors, pre-1.0, and — stated
  with numbers and a link — that this is **not** the fastest server on raw
  throughput. A page that hid that would be contradicted by the benchmark
  page two clicks away.

  The snippet was run before it was published: a Django app containing
  exactly those six lines, served by `bin/m0serve --realtime`, delivers
  `id: 2 / data: deploy finished` to a live `curl -N` subscriber. The
  fuller path stays covered in CI by `smoke-quickstart`.

- **[docs/BENCHMARKS.md](docs/BENCHMARKS.md): the public benchmark page,
  and it leads with the losses.** Gate 3 of the launch checklist. Four
  generated regions across two documents, all driven by
  `render_bench_docs.py` and all CI-checked — hand-edit a table, or land a
  new artifact without re-rendering, and `check-docs` fails naming the file.

  Two things it does on purpose. It states plainly that m0serve is **~0.83x
  Granian per measured core on bare WSGI and 0.72x uvicorn on ASGI
  throughput**, because the win it does claim — fast-request p99 under
  mixed load — is only credible next to them. And it renders a *stated
  absence* for the mixed-workload bench rather than omitting it: the
  handler pool's ~100x p99 improvement is the strongest claim in this
  repository and currently the only one with no machine-readable source.

  `render_bench_docs.py` grew from one region in one document to a table of
  targets, with a renderer per bench kind. The isolation bench gets its own:
  its finding is a comparison *across* slow levels within one configuration,
  so the rows are pivoted — a flat row isolated the slow work, a climbing
  one did not — and the percentiles are re-medianed from `rows`, since
  `bench_record.medians()` folds only rps and cores. It also stops naming a
  comparator the artifact's environment stamp recorded but the bench never
  ran: on a public page, "granian 2.8.1" beside a table with no granian row
  reads as if it had been measured and lost.

- **`m0serve --doctor`: the configuration as JSON, starting nothing.** The
  launch checklist's machine-readable startup diagnostic, and the reason is
  narrower than "nice to have": every refusal this server makes already
  names its fix, but seeing one meant *attempting the run* — which binds a
  port, forks, and imports the application. `--doctor` reports platform and
  wheel architecture, the interpreter it resolved and the virtualenv it came
  from, the spec discovery chose and the protocol it classified as, the
  resolved topology (including whether the handler pool is a default or
  configured), and a `checks` array whose failures each carry `detail`,
  `fix` and `exit`.

  **The contract is the exit code: `--doctor` exits with the code `m0serve`
  itself would exit with for the same arguments** — 0 serve, 2 usage,
  1 startup, 78 `EX_CONFIG`. A diagnostic that reports "fine" where the
  server refuses is worse than no diagnostic, and the doctor mirrors the
  startup path's check order rather than sharing its control flow, so
  nothing but a test keeps them in step: `poe smoke-doctor` runs *both*
  binaries over every refusal and compares.

  That test earned its place before it was committed. The first
  implementation recorded the free-threading check before the usage
  conflicts, so `--workers 2 --threads 2` reported 78 where the server exits
  2 — the interpreter is never reached, because `main` decides topology
  conflicts before any Python runs. `Report.exit_code` returns the *first*
  failure rather than the largest for the same reason, and
  `test_doctor.mojo` pins it.

  A bare `m0serve --doctor` with no application is the "is this environment
  sane" call and exits 0 — reporting the interpreter facts is precisely what
  a failed install needs, and previously libpython not resolving was visible
  only as a traceback at serve time.


### Fixed

- **The README quoted a decomposition its own measurements had retired.**
  It said the one-worker gap to Granian "splits evenly, 1.58x HTTP layer and
  1.58x bridge" — numbers from before the CPU-normalized re-run, which
  WSGI_PERFORMANCE.md had already replaced with ~1.0x × 1.35x and explicitly
  marked as "records of what was measured, not descriptions of the
  present". The README kept quoting them, in raw rps, against a comparator
  since found to be running 1.75 cores. Rewritten from the artifact.

- **"There is no chunked encoding" was no longer true.** The server has
  chunked transfer-encoding and ASGI responses stream through the executor
  chunk-framed on HTTP/1.1. WSGI responses are still fully buffered, but
  the reason is PEP 3333 — a WSGI response carries a `Content-Length`,
  which means knowing the length — not a missing feature.

- **The PyPI project page told aarch64 users their wheel did not exist.**
  0.11.0 shipped a `manylinux_2_35_aarch64` wheel and its release notes
  claimed "the platform matrix on the README is the platform matrix on the
  index" — which was true of the repository's README and false of
  `packaging/m0serve/README.md`, the `readme` named by the wheel's
  pyproject.toml and therefore the page PyPI renders. That one still read
  `Linux aarch64 | buildable, not yet shipped` for the whole of the
  release. Two READMEs, one of them published, and the ratchet was pointed
  at the other.

- **A README number quoted twice, guarded once.** The mounted-isolation
  p99 (2.8 ms) now appears on the first screen as well as in the mounts
  section. It is not artifact-backed — `hybrid_isolation.py` asserts a
  deliberately generous ceiling rather than recording the figure — so
  `check_hybrid_p99_consistent` checks the two copies against *each other*
  instead. A number edited in one place and not the other is the ordinary
  way a README starts contradicting itself.

- **The bench prose was answerable to nothing, and it was wrong.**
  `render_bench_docs` kept the generated *tables* honest; the sentences
  around them — where the headline claims actually live — were checked by
  no one. docs/WSGI_PERFORMANCE.md stated the WSGI result as a
  decomposition, "roughly 1.0x HTTP layer × ~1.35x bridge", and it does not
  reconcile with the artifact directly beneath it: the measured per-core gap
  is **1.21x**, and a 1.35x bridge term requires an HTTP layer term of
  0.89x — this server's HTTP layer *slower* than the comparator's, which
  the same sentence denies.


- **The boolean-flag dispatch had a fallthrough.** `parse_args` ended its
  chain with `else: opts.metrics = True`, so a new flag added to `_is_bool`
  and forgotten in the dispatch silently enabled Prometheus metrics instead
  of doing its job. `--doctor` would have been the first victim. The `else`
  now raises, and `test_cli.mojo` asserts each boolean sets only itself.

### Changed

- **The mounted-isolation guard had 138x headroom and now has 12x.**
  `hybrid_isolation.py`'s `ISOLATION_BUDGET_MS` was 400 ms against an
  observed p99 of 1.4–4.1 ms, so it discriminated "isolated" from "sharing
  an execution mode" (~2000 ms, the sync view's hold) and nothing in
  between: a regression that parked the async mount for 300 ms — a
  hundredfold degradation, plainly visible to a user — passed. It is now
  50 ms, chosen from 17 recorded CI runs across both runners rather than
  from the gap to the failure signal, and the docstring carries that
  evidence and its one limit (every run is the prefork phase; the
  `--threads` phase is skipped wherever there is no free-threaded
  interpreter with fasthtml).

  Every run now prints its headroom, pass or fail, because a number
  drifting from 12x to 2x is the warning that comes before the failure.

- **A total loss of isolation reported a stack trace.** With the pool off
  (`--blocking-threads 0`) the sync mount's warm-up never returns at all,
  and the script exited on a urllib `TimeoutError` — the smoke failed, but
  whoever read the log had to work out why from a traceback. A request that
  never returns is now reported as what it is, with the two things to check
  named. The ordinary failure still reports a number: sample timeouts are
  bounded well above the 2000 ms hold, so a request genuinely queued behind
  the sync work is measured rather than erroring.

- **`check_wheel_platform_claims` now checks what its docstring always
  said.** It asserted that a wheel gets built at all and that neither README
  points at 3.13t; it never compared a platform table to anything. It now
  reads the `plat:` entries out of `release.yml`'s `build-wheels` matrix —
  the only place a wheel that reaches PyPI is declared — and holds **both**
  READMEs to them in both directions: a built platform must be marked
  supported, and a platform marked supported must be built. Either failure
  is a claim with no artifact behind it, which is the whole premise of this
  file.

  Recorded while wiring it, because it is the opposite of the guess:
  `test.yml`'s `paths-ignore` lists `*.md`, and a GitHub path glob's `*`
  does not cross `/`. A PR touching only the root `README.md` therefore
  skips CI entirely, while one touching only `packaging/m0serve/README.md`
  runs the full suite. The published README is the guarded one.

- **The quickstart's version echo is machine-checked.** QUICKSTART.md showed
  `m0serve 0.10.0` against a 0.11.0 tree. The doc promises every command in
  it is executed by CI, and that promise is kept for ```bash blocks —
  but the echo lives in a ```text block, which `run_quickstart.py`
  displays rather than asserts. That is the right design (the other text
  block interleaves output from three commands and is not byte-stable), so
  the check belongs in `check_docs.py`, where prose facts with a machine
  source live. [docs/RELEASING.md](docs/RELEASING.md) names the fourth bump
  site; `poe check-docs` fails on all four.

## [0.11.0] — 2026-08-26

The release that makes three published claims true at once: the quickstart
works against the PyPI package, `pip install m0serve` includes the publish
helper the realtime story depends on, and the platform matrix on the
README is the platform matrix on the index.

### Added

- **`m0serve.m0pub` ships in the wheel.** The publish half of the realtime
  feature — `m0pub.publish(channel, data)` from any sync view, one
  `os.write` per worker plus an atomic fetch-add for the globally unique
  event id. It was previously only in the repository's demo app, so a pip
  user had a server that could hold connections and no way to publish to
  them. Pure stdlib; degrades to 0 workers under any other WSGI server and
  to unnumbered frames without the shared counter, exactly as documented.

- **[QUICKSTART.md](QUICKSTART.md), and it is executable.** Ten minutes from
  `pip install m0serve` to live multi-tab sync from one synchronous Django
  file — SSE verified by curl with expected output stated, WebSockets in
  the browser, cross-worker fan-out with `--workers 2`. CI extracts the
  fenced blocks and runs them against the tree's own wheel on every pull
  request (`poe smoke-quickstart`), so the doc a stranger follows is pinned,
  not aspirational. It caught its own author before anyone else: a first
  draft asserted event ids survive a server restart, and the runner failed
  the doc — ids are unique across one server's workers, by design.

- **`llms.txt`** — the operating contract for agents: strict flags, exit 78
  refusals that explain themselves, the `M0-Hold` protocol, where to start.

- **Linux aarch64 wheels** (Graviton, Ampere, arm64 Docker). The platform
  was already proven — built by hand in an arm64 container, passing the full
  wheel smoke including the removal sabotage — so the only thing between it
  and users was a CI runner. `build-wheels` and `wheel-consume-linux` are
  now matrices over both Linux architectures, and the aarch64 wheel is
  consumed on real arm64 hardware rather than under emulation, which would
  defeat the purpose of a job that exists to run an artifact on a machine
  that did not build it.

  Also added to `test.yml`, not just the release path: `release.yml` runs on
  a tag, so aarch64-only would have meant discovering a break *during* a
  release, after the GitHub release exists and with the upload gated behind
  it. That is the failure shape the consume jobs were built to prevent.

  The README claimed Linux arm64 support before the wheel existed, so a
  Graviton user would have got `No matching distribution found` — the
  literal "didn't install" comment the release checklist names as its
  first risk.

- **`scope["client"]` and `REMOTE_ADDR`: the peer reaches Python.** The
  fork's `accept()` passed a 4-byte `addrlen`, so the kernel truncated
  the peer address before the IP bytes — it was unreadable even in
  principle. `accept_with_peer` keeps the full sockaddr, the event loop
  stamps each request (`HTTPRequest.remote_addr`/`remote_port`, captured
  once per connection on the provision), and the peer crosses to Python
  on both protocols: WSGI gets `REMOTE_ADDR`/`REMOTE_PORT` in the environ
  (per request, C-API only, same no-leak discipline), ASGI gets
  `scope["client"] = (host, port)` on http and websocket scopes. Django
  populates `request.META` from these only when present — `client: None`
  doesn't error, it silently logs every visitor as address-less, which
  disables rate limits, IP allow-lists and audit logs.

- **`apps/django_asgi` + `poe smoke-django-asgi`: Django's own ASGI
  handler, proven.** A bare `djasgi` discovers `djasgi.asgi:application`,
  detection classifies it ASGI, and the executor serves it zero-config.
  The smoke pins: discovery + the `asgi-loop` banner; `/meta` showing the
  real peer (verified load-bearing against a server sending `None` — it
  answers empty); four overlapping 400 ms async views completing in ~1x;
  `StreamingHttpResponse` streaming live rather than buffered; a
  signed-cookie session counter surviving three round trips; SIGTERM.
  `smoke-wsgi` gains the environ-side `REMOTE_ADDR` assertion.

- **Cross-worker fan-out for ASGI applications: `state["m0"]`.** Every
  ASGI app now finds a pub/sub object in its lifespan state — the
  Channels channel-layer shape with no Redis, riding the `BroadcastBus`
  that already existed for GRIP. `m0.publish(channel, payload)` writes
  one datagram per worker channel (m0pub's exact protocol, shared-atomic
  event ids included, best-effort on a full or dead channel);
  `m0.subscribe(channel)` is an async iterator fed by frames the loop's
  handler forwards to each executor as tagged submit datagrams. The bus
  fd conflict that blocked this — the executor consumes `bus_read_fd`
  for its ASGI chunk channel — is answered by a second registered fd on
  the loop (`peer_bus_fd`), same codec, same drain, same handler entry.
  The bus (plus `SharedAtomics` ids and env exports) is now created
  unconditionally pre-fork: an ASGI app cannot be detected until after
  the fork, and a single worker publishing to its own subscribers rides
  its own channel — there is no separate local-delivery path to keep in
  sync. `poe smoke-asgi-fanout` pins the spread (6 streams over 2
  workers), delivery of one publish to every stream on both workers,
  distinct cross-worker ids, supervisor SIGTERM with a live subscriber,
  and the single-worker case.

- **An ASGI server validator — the `wsgiref.validate` that never got
  written.** WSGI has a stdlib conformance checker and this repo runs it;
  ASGI has nothing standard (the `asgiref` testing helper plays the
  server rather than checking one, and uvicorn/hypercorn/daphne verify
  themselves bespoke). `apps/asgi_bare/bareapp/validate.py` is the
  analog, written from the ASGI 3 spec: every required scope key with its
  exact type (bytes-vs-str is THE classic server bug), the receive
  stream's protocol, `server`/`client` tuple shapes. `M0_ASGI_VALIDATE=1`
  wraps the app; violations raise and answer 500. `smoke-asgi` gains the
  validated pass, with `/validate/canary` proving the wrapper is engaged
  — a bogus message type the unvalidated server ignores (200) and the
  validator refuses (500), the `/pep3333/canary` pattern exactly.

- **`--mount PREFIX=SPEC`: several applications in one process.** A
  `m0serve` process can now host more than one application, routed by
  longest prefix before either sees the request — `--mount /=djangoproj
  --mount /portal=portal.wsgi:app` serves a Django project and a Flask app
  from one listener, one set of workers and one graceful shutdown. Each
  mount detects its own protocol (discovery included) and gets its own
  bridge and shim namespace; a path no mount claims is a 404 answered in
  Mojo, never entering Python; prefixes match on segment boundaries, so
  `/app` never swallows `/application`.

  The prefix reaches both protocols through one seam, because they
  disagree about what it means: WSGI gets `SCRIPT_NAME` with `PATH_INFO`
  trimmed to the remainder, ASGI gets `root_path` with `path` left whole
  (Django's `ASGIHandler` strips it itself). Getting that backwards leaves
  every direct request working while every generated URL breaks, so
  `smoke-hybrid` compares Django's `reverse()`, Flask's `url_for()` and
  both frameworks' `request.path` byte for byte. New row:
  `apps/hybrid_mix`, deliberately two frameworks rather than two Django
  projects — those would share `django.conf.settings` and the first import
  would win, which would make the isolation claim a lie.

  Refused rather than guessed, each with a message saying why: mixed
  WSGI/ASGI mounts (routing them is done; giving each its native execution
  mode is the next stage), `--mount` with `--realtime` (an inbound
  WebSocket message has no defensible destination among several urlconfs),
  and a mounted server taking the asyncio executor (one submit channel
  cannot say which mount a job is for). See docs/WSGI_VS_ASGI.md §9.

- **Mixed mounts, each in its native execution mode.** A sync Django app
  and an async FastHTML app now run in ONE process, sharing one listener
  and one graceful shutdown, with Django's requests on handler-pool
  threads and FastHTML's on the asyncio executor. The mechanism is a
  submit **lane** per mount — the single submit channel became one
  `SOCK_DGRAM` pair each — so the loop hands a job to the worker that can
  run it; one `ProvisionPool` per loop stays, since a slot indexes that
  loop's provisions. `match_path_prefix` is now the single implementation
  of the matching rule, so the lane a job takes and the application the
  handler picks cannot disagree, and each worker builds only its own
  mount's application rather than every mount's.

  Measured and smoke-pinned: with four blocking 2-second Django views
  holding every pool thread, the FastHTML mount answers at p50 1.3 ms /
  p99 2.8 ms. `apps/hybrid_mix` is now Django + Flask + FastHTML in one
  process.

- **Several ASGI mounts, one executor each.** The one-ASGI-mount limit is
  lifted: every ASGI mount gets its own executor thread, its own bridge
  and lifespan, and its own drain-ack pair (`OffloadPool.enable_stream_ack`),
  with the loop routing each ack by the lane recorded at submit
  (`slot_lane`) — credit belongs to the executor that owns the slot, and
  an ack routed anywhere else is a stream stalled forever rather than an
  error, which is why the smoke streams 256 KB (four credit windows) from
  two executors concurrently and byte-counts both. Executors share the
  one chunk channel: its datagrams were always slot-addressed, and a
  single `SOCK_DGRAM` queue is globally FIFO across writers, so the
  recycled-slot safety argument survives. The reserved channel names now
  carry the executor's lane (`\x01<kind>/<slot>/<lane>`; the unmounted
  wire format is unchanged), which is how disconnect tags and inbound
  WebSocket messages route back to the owning executor — parsed from the
  slot's own subscription record, no side table to drift. Shutdown sends
  one pill per executor on its own lane. `apps/hybrid_mix` gains
  `feed.asgi`, a second async mount beside FastHTML's.

## [0.10.0] — 2026-08-25

Promotes 0.10.0rc1 unchanged. The rc's whole purpose was to run the upload
path once on a filename that could be spent: it published, installed from
the real index on machines that never built it, and served. Nothing needed
fixing afterwards, so this is the same artifact under a stable number.

What the release candidate cost, kept here because the reasoning outlives
the incident: three attempts and four defects, every one of them invisible
from the machine that built the artifact.

- The binaries were compiled for the build host's CPU (`mojo build` defaults
  `--target-cpu` to it), so `m0serve --version` died with SIGILL in a clean
  container after passing on the runner that produced it. Not detectable by
  static inspection at all — only by running the artifact on different
  silicon.
- `wheel-inspect` runs on Linux and checks both wheels, but read Mach-O
  through `otool`, which macOS has and Linux does not.
- The glibc negative control ran `pip` with no shell in the container, so
  its glob stayed literal and pip refused the wheel for the wrong reason.
  The guard caught precisely that and declined to score it as a pass.
- The release published as "Latest", above the current stable, because
  `gh release create` does not infer pre-release status from a tag.

### Changed

- Version only. No source changes from 0.10.0rc1.

## [0.10.0rc1] — 2026-08-25

First release published to PyPI, as a release candidate: it claims the name
and exercises the production upload path — trusted publishing, the
two-platform wheel set, the tag/version cross-check — before a stable number
is spent on an untried path.

One correction, because this entry originally claimed otherwise: **`pip
install m0serve` does install it.** pip excludes pre-releases only when a
stable version also exists, and there is none here, so the rc is the only
candidate and pip takes it. The rc therefore buys rehearsal, not
invisibility; quietness rests on nothing being announced. The upside is that
the index-install path — pip choosing the right file from several platform
wheels, from a real index, on a machine that never built them — is proven
rather than deferred.

### Added

- **`pip install m0serve` — the server as an installable binary.** A
  WSGI/ASGI server for Python applications, with no Mojo toolchain on the
  target machine and nothing fetched at install time (the wheel declares no
  dependencies). `m0serve myproject.wsgi:application` serves either protocol,
  detected from the object.

  **One wheel per platform covers every supported CPython** — 3.10 through
  3.14 including free-threaded builds — because `m0serve` does not link
  libpython; Mojo `dlopen`s the interpreter at run time, so there is no
  CPython ABI in the archive to be compatible with and no CPython in it to
  redistribute. Verified across all five, and by serving Django 5.2.17 on
  CPython 3.11 from a wheel built on 3.13 with Django 6.1.

  Built from `packaging/m0serve/`, a separate project holding the only
  `[build-system]` in the repository: one in the root would make uv treat
  the repo as installable, and that build needs `bin/m0serve`, which needs
  the `.venv` uv is creating.

- **The platform tag is measured, not declared** (`scripts/wheel_tag.py`).
  It reads `LC_BUILD_VERSION` and versioned glibc symbols out of the staged
  binaries and takes the strictest floor. Copying the toolchain's own
  `macosx_13_0` tag would have shipped a wheel requiring macOS 26.

- **`poe bundle-serve` and `poe check-serve-portable`**, mirroring the
  `libm0core` pair, plus `stage-wheel`/`build-wheel`/`smoke-wheel`.

- **Clean-consumer release jobs.** The wheel is installed and made to serve
  in containers and on a runner that never built it — four CPython minors,
  `--network none`, and a permanent negative control asserting an older
  glibc is *refused* by pip rather than crashed at startup. Each job asserts
  its own cleanliness first, and `check-docs` fails the build if one ever
  acquires a checkout.

### Fixed

- **Binaries were compiled for the machine that built them.** `mojo build`
  defaults `--target-cpu` to the host CPU, so every artifact this project has
  produced was effectively `-march=native`. The first release run proved the
  consequence: `m0serve --version` died with `Illegal instruction (core
  dumped)` in a clean container after passing on the runner that built it,
  and on a developer machine the effective target was `apple-m4` with
  `+sme`/`+sme2` — Scalable Matrix Extension, which no M1, M2 or M3 has.
  `build-ffi` and `build-serve` now pin the oldest CPU each platform must
  support (`apple-m1`, `x86-64-v2`, `generic`), and `check-docs` asserts they
  do. Unlike the rpath defect this resembles, it is invisible to static
  inspection — only running the artifact on different silicon can find it,
  which is exactly what the clean-consumer jobs do.

- **The portability checker could not see an executable, and the bundler was
  blind the same way.** `otool -L` prints a *dylib's* own `LC_ID_DYLIB`
  before its dependencies; an `MH_EXECUTE` has none, so dropping the first
  entry discarded `bin/m0serve`'s only real dependency. The checker reported
  `SELF-CONTAINED` for a binary that resolved the Mojo runtime through a
  developer's `.venv`, and `bundle_ffi.py` would have copied zero runtime
  libraries and called the bundle complete. The parse now lives once in
  `scripts/binfmt.py`, keyed on the load command's presence, self-tested in
  CI against both cases.

- **`build-serve` had no post-link surgery at all**, so every `bin/m0serve`
  ever built recorded a search path into the venv that produced it. It now
  shares `build-ffi`'s, via `scripts/relocate.py`, and completes its bundle
  in place — so `bin/` is the shipped shape rather than a development
  arrangement that worked for a different reason.

- **The macOS deployment target is pinned to 13.0.** `mojo build` honours
  `MACOSX_DEPLOYMENT_TARGET`; without it the binary inherited the build
  host's SDK, making the wheel's reach a property of whichever image GitHub
  calls `macos-latest`.

- **"The Linux artifact is statically linked" was true of one file only.**
  Measured on `libm0core.so` and carried as a platform fact; the `m0serve`
  executable links the three Mojo runtime `.so` files on Linux exactly as on
  macOS. Nothing in the tooling decides by platform now, only by what the
  file records. `patchelf` is a Linux build requirement in consequence, and
  `nightly-canary.yml` — which builds `m0serve` — had no dependency step at
  all.

### Changed

- **NOTICE describes artifacts, not just the source tree.** The wheel is the
  first artifact to redistribute the lightbug_http fork in object form, and
  MIT requires its notice to travel with copies — so
  `licenses/LICENSE.lightbug_http.txt` and `licenses/NOTICE.m0serve.txt`
  ship inside the wheel and the `m0serve` bundle. NOTICE gains a table of
  which notice covers which artifact, and no longer implies the Linux builds
  contain no Modular code.

- **The README's platform claim is architecture-qualified**, because once
  wheels exist `pip` enforces it: macOS Intel is not untested but
  *impossible* (no toolchain wheel), Linux aarch64 is buildable and
  unshipped, and the glibc floor excludes musl. The free-threading claim
  moved from "3.13t+" to 3.14t, which is what is actually tested — 3.13t
  systematically immortalizes objects, as `pyproject.toml` and
  `docs/WSGI_VS_ASGI.md` already recorded.

## [0.9.0] — 2026-08-24

### Added

- **ASGI WebSockets (Phase 3b): `app.ws` works.** A WebSocket handshake
  on an ASGI app gets a `websocket` scope on the executor's loop. The
  ready 101 (built by the loop's own validator from the original
  request's key) is held until the application's `websocket.accept` —
  the same approve/perform split as M0-Hold — and released through the
  completion channel behind a FIFO-anchoring begin frame; outbound
  frames are RFC 6455-encoded executor-side and ride the 3a chunk
  channel into the `sockets` registry; `websocket.close` queues the
  close frame plus the end marker and the loop closes after both land;
  inbound messages travel as tagged submit-channel datagrams into
  per-slot queues behind `receive()`; a disconnect cancels the task and
  a never-answered handshake resolves as 403 so no slot leaks.
  `smoke-asgi` drives a raw RFC 6455 probe (verified accept, text and
  binary echo, close(1000) to the FIN, abrupt-vanish cleanup);
  `smoke-fasthtml` proves FastHTML's `app.ws` end to end — its full
  surface (pages, SSE `EventStream`, WebSockets) now runs on `m0serve`
  with zero configuration.

- **ASGI streaming responses (Phase 3a): SSE actually streams.**
  FastHTML's `EventStream`, Starlette's `StreamingResponse`, and Datastar
  patch streams now stream live through the asyncio executor instead of
  meeting the buffered watchdog's 500. Response chunks travel from the
  executor thread to the event loop as datagrams on a private per-loop
  channel and ride the existing `SSERegistry` per-slot outboxes under
  reserved channel names (a leading control byte no HTTP header value can
  carry, so GRIP channels cannot collide). Correctness is ordering and
  credit, both smoke-pinned: a stream's begin frame precedes its head on
  one FIFO channel (so a recycled slot can never receive another
  stream's chunks), a 64 KB credit window with 32 KB chunk split means
  the loop's drain acks pace the producer (a 100 MB stream behind a slow
  reader grows server RSS ~2 MB), bodies are close-delimited and the
  loop closes on end-of-stream via the previously-uncalled
  `sse_is_streaming` hook, client disconnects cancel the app task
  (uvicorn's contract), and comment heartbeats are suppressed on ASGI
  streams so an SSE event split across chunks can never be corrupted —
  asserted byte-exact under a 300 ms cadence, alongside an md5-checked
  1 MB streamed body. `smoke-fasthtml` now asserts live `/sse` ticks;
  the buffered escape hatch (`--blocking-threads` + ASGI) keeps its
  watchdog refusal. WebSocket scopes are Phase 3b.

- **The asyncio executor: real await-concurrency for ASGI (Phase 2).**
  Zero-config ASGI now serves through one executor thread per event loop
  (`m0_wsgi.asgi_executor`) running the bridge's persistent asyncio loop:
  the loop parks each request and submits its slot through the unchanged
  `OffloadPool` datagram channel, `loop.add_reader` turns slots into
  tasks, and completions answer through `put_response`/`complete`.
  Requests overlap wherever the application awaits — eight concurrent
  1.5 s awaits complete in 1.51 s on one loop with zero threads — and the
  banner says `asgi-loop`. The executor path crosses method, path, query,
  headers (ready lowercase byte-pairs), and body straight through the C
  API as stolen tuple slots — no environ, no CGI names, no Python-side
  re-transform — and the RSS guard stays flat (20 KB–1.7 MB across runs,
  allocator noise against the 12 MB limit). Exactly
  one lifespan runs per loop (fallback handlers are built with
  `lifespan=False`); the executor picks uvloop for its own loop where
  installed. An explicit `--blocking-threads N` keeps the Phase-1
  buffered pool as the escape hatch; `--threads N` composes (one executor
  per loop, free-threaded CPython only, as before). `poe bench-asgi` is
  the standing gate against uvicorn: the mixed slow/fast fast-request p99
  passes (2.87 ms vs 3.27 ms); hello-world throughput stands at
  0.88–0.94x with the remainder located and its fix paths recorded in
  docs/WSGI_PERFORMANCE.md §"The ASGI executor vs uvicorn".

- **`m0serve` is now a hybrid WSGI/ASGI gateway with zero-config
  detection.** The protocol is detected from the application object at load
  (coroutine-function duck typing — the rule uvicorn and asgiref share;
  `--protocol auto|wsgi|asgi` overrides it), so FastHTML, Starlette,
  FastAPI, and Django's `asgi.py` serve from the same binary that serves
  Django/Flask WSGI. ASGI requests run on a persistent per-bridge asyncio
  loop, buffered: the scope is derived in the shim from the same C-API
  environ, `send()` events collect into the same `(status, headers, body)`
  tuple, and no new per-request Mojo↔Python object traffic exists —
  `smoke-asgi`'s RSS guard (same 12 MB/10k-request limit as the Django
  row) measured 356 KB on day one. Lifespan startup/shutdown run with
  uvicorn's "auto" semantics, and lifespan `state` reaches request scopes.
  Streaming responses are the recorded limit: a response still unfinished
  10 s after its first `more_body=True` is answered with an explanatory
  500 pointing at docs/WSGI_VS_ASGI.md §8 (the buffered bridge cannot
  carry an infinite SSE/EventStream; that surface is the design's Phase 3).
- **Spec discovery**: a bare `m0serve MODULE` now tries
  `MODULE:application`, `MODULE.asgi:application`, `MODULE.wsgi:application`,
  `MODULE:app`, `MODULE.main:app` in order — a Django project or a
  FastHTML/FastAPI `main.py` serves without learning either convention. An
  explicit `:ATTR` never falls back. A total miss lists every spec tried,
  and a non-callable names both expected signatures.
- **Zero-config concurrency**: with no `--workers`/`--threads`/
  `--blocking-threads` flag and no `M0_*` topology variable, `m0serve` now
  starts a handler pool of `min(cores, 8)` blocking threads, so one slow
  view no longer stalls every connection out of the box. Any explicit
  topology value wins — `M0_WORKERS=1` or `M0_BLOCKING_THREADS=0` restore
  the old single-loop shape — and `--realtime` keeps the single loop
  (its streaming hooks run on the loop's handler). The banner reports
  `protocol=` and marks the pool `(auto)`.
- New rows and gates: `apps/asgi_bare` (the ASGI sibling of `wsgi_bare` —
  every route pins one clause of the contract) with `poe smoke-asgi`, and
  `apps/fasthtml_demo` with `poe smoke-fasthtml` (skips where
  python-fasthtml is absent). `python-fasthtml` joined the dev dependency
  group.

### Changed

- `wsgi.multithread` is `True` under the zero-config pool (it is a real
  thread pool), and ASGI apps refuse `--realtime` with an explanatory
  message — the M0-Hold contract is a WSGI response-header protocol.
- docs/WSGI_VS_ASGI.md gained §8: the deliberate revisit of its §6
  verdict, with the three-phase gateway design (buffered bridge →
  per-loop asyncio executor over the offload channel → ASGI realtime over
  the existing bus/registry transport).

## [0.8.0] — 2026-08-24

### Added

- **`poe bundle-ffi` — a self-contained, redistributable `libm0core`.** The
  macOS artifact resolves the Mojo runtime at load time and is useless
  without it, so releases now ship `<asset>.tar.gz` containing the library,
  the runtime it loads, and both licences — 1.65 MB, verified to `dlopen`
  from an unrelated directory with `DYLD_LIBRARY_PATH` and
  `DYLD_FALLBACK_LIBRARY_PATH` unset. The bare library remains a separate
  asset so existing download URLs keep working; the Linux `.so` is
  statically linked and self-contained already.

  The dependency closure is **discovered, not listed** — a hand-written
  first attempt shipped only the library named in the error message and
  then failed on *its* dependency, so `bundle_ffi.py` walks the graph and a
  toolchain bump that adds a fourth library is picked up rather than
  silently producing a broken bundle. The task refuses to finish unless the
  result is self-contained, so assembly and assertion cannot drift apart,
  and CI runs it on every commit: **a release can no longer publish an asset
  that only loads on the build machine.**

  The Mojo runtime is Apache 2.0 with LLVM Exceptions. Rather than rely on
  the exception excusing attribution for separately shipped files, the
  bundle **complies with section 4 in full** — licence text, attribution,
  and an explicit 4(b) notice that install name, rpath and code signature
  were changed while the executable code is byte-for-byte as built. See
  `NOTICE` and [docs/FFI_DISTRIBUTION.md](docs/FFI_DISTRIBUTION.md), which
  also record the one piece of contrary evidence: the `mojo_compiler` wheel
  still declares the proprietary MAX licence, though it contains only the
  compiler and runtime — no MAX components — and ships no licence file of
  its own.

### Changed

- **The WSGI response path was never measured, and was 10x the request
  path. `build_response` now costs 3.30 µs instead of 22.97** for a
  six-header Django-shaped response; `serve()` 25.51 → 5.65 µs. End to end
  on `apps/wsgi_bare` — one response header, the *least* favourable shape —
  **49,517 → 56,896 rps (+14.5%)**, p50 291 → 252 µs.

  The cause was not the Python boundary. Splitting it put the
  `PythonObject` header read at 1.27 µs (5%) and `name.lower()` at
  **19.36 µs (84%)** — a Unicode-lowercased copy of every header name,
  allocated solely to compare against one constant. `name_is` was already in
  the repo doing this correctly for the identical Set-Cookie dispatch on the
  request side, and its docstring already named the mistake. The fix is that
  one call.

  `scripts/bench_bridge_parts.mojo` now covers both directions, at one, six,
  and six-plus-two-cookie response headers, so this cannot go unpriced
  again. `name_is` and `ascii_lower_byte` gained unit tests
  (`test_headers.mojo`) — they had none despite being the whole of header
  case folding, now in both directions; the boundary test was verified to
  fail when the `A`–`Z` range is widened by one byte.

- **The Granian layer split is re-measured on 3.14.7t, and the gap it was
  written to explain is spent.** After five bridge changes, the row that has
  driven every roadmap priority since it was taken: **at four workers
  m0serve is now ahead of Granian, 101,892 rps against 98,489**; at one
  worker the gap is **2.50x**, down from 4.31x.

  The re-measurement carries its own validity check. Nothing here touched
  the HTTP layer or Granian, and all three rows that should not have moved
  reproduced within 2% — `apps/hello` 0.99x, Granian 0.98x at one worker and
  0.99x at four — across five weeks and a Granian bump to 2.8.2. The two
  rows that moved are the two the bridge work touched: **3.94x at one worker,
  2.91x at four.**

  What is left at one worker is **1.58x HTTP layer × 1.58x bridge** — dead
  even, and their product is the whole 2.50x. The original conclusion, *"the
  headroom is in the bridge, not the HTTP layer"*, was right when measured
  (6.30x against 1.59x) and no longer is. Part of the four-worker result is
  Granian's own 19% loss from one worker to four on a four-performance-core
  box; m0serve scales 2.08x over the same step. Both stated.

- **m0-sqlite: the text-scan cost is measured, and the zero-allocation read
  is documented.** `bench_sqlite.mojo` gained TEXT rows — the one column
  type it never priced — showing `column_text` pays **2.1x** for its
  per-row `String` at 64 B and at 4 KB alike. The fast path already
  existed: `column_blob_into` works on TEXT columns (SQLite's UTF-8
  TEXT→blob conversion is a pointer handoff), and the two docstrings now
  point at each other. No new API, per the package's own rule. Also
  recorded in SQLITE_PERFORMANCE.md: the WSGI-bridge techniques checked
  item-by-item against this package — most already applied or without an
  analog, and the one fresh suspect (a hidden `StringLiteral` → `String`
  conversion on every binder's happy path) measured at 0.0 ns and was
  left alone.

- **Each request's environ starts as `PyDict_Copy` of a finished base
  template — `build_environ` 1.78 → 1.56 µs, the bridge 2.35 µs.** One C
  call replaces ten per-request hash-and-stores (58 ns vs 214 measured),
  and `Python().cpython()` is acquired once per request instead of sixteen
  times. The template is copy-isolated: an app may overwrite or delete
  anything in its environ without touching the next request's, probed with
  ten vandal/inspect cycles and a second `set_base`. The decision that
  *didn't* ship matters as much: an intern cache for recurring header
  names/values measured as a net loss — its hit-path byte-compares cost
  more than the 15 ns decodes they would skip — so it was never built, and
  the bridge is now near the structural floor WSGI's environ shape sets.

- **The response body is read through `PyBytes_AsString` instead of
  `ctypes` — the bridge costs 2.50 µs per request instead of 3.52.**
  `body_bytes` was 31% of what the bridge had left, and the split named one
  cause: the shim's `body_addr()`, which built two `ctypes` objects per
  request. It now runs **no Python at all** — `PyObject_Length` for the
  length, `PyBytes_AsString` for the address, one `memcpy` for the copy.
  **1.07 µs → 0.13 µs**, and end to end on one worker serving
  `apps/wsgi_bare`: **45,891 → 48,852 rps, +6.7%**, p50 315 → 295 µs. That
  is **1.69x cumulative** against the 28,853 rps measured before any of the
  bridge work.

  **The general finding matters more than the optimisation.**
  `Python().cpython()` binds no `PyBytes_*` and no `PyUnicode_DecodeLatin1`,
  and `external_call` cannot reach them either, because libpython is not on
  the link line — Mojo `dlopen`s it, which is why `CPython` is a struct of
  loaded function pointers. But that struct exposes its handle, and the
  stdlib's own `ExternalFunction[name, type].load(cpy.lib.borrow())` opens
  the functions it omitted. **The whole CPython C API is reachable**, which
  retires "there is no binding for it" as a constraint on this boundary.

  `PyBytes_AsString` is stable-ABI and checked — NULL plus `TypeError` on a
  non-`bytes`, where the `PyBytes_AS_STRING` macro would read wrong offsets
  and is not a symbol anyway. The pointer is resolved once at construction;
  the call it returns is 1.0 ns. `smoke-django`'s RSS guard still reports
  **0 KB over 10k requests** — reading through a raw pointer takes no
  reference.

  The **request** body followed in the next entry — see below.

- **The request body crosses as a real `bytes` via
  `PyBytes_FromStringAndSize` — the blob design is fully retired.** Mojo
  builds the `bytes` straight from the request's own buffer (one copy,
  inside the call) and hands it to the shim as a stolen tuple slot;
  `io.BytesIO(bytes)` shares the buffer copy-on-write, so `wsgi.input`
  costs no second copy where the old bytearray protocol always paid one.
  Staging a 1 KB body: **1.6 µs → 0.07 µs (~23x)**; end to end, a 1 KB POST
  to `apps/wsgi_bare`'s `/input/read`: **42.1k → 47.3k rps (+12%)**, GETs
  unchanged. Deleted outright: the shim's 64 KB transfer bytearray,
  `buf_addr()`, the grow protocol, and the shim's `ctypes` and `sys`
  imports — it now imports nothing but `io`. Every request costs exactly
  one call into Python, the `PyObject_CallObject` that runs
  `run(environ, body)`.

### Fixed

- **The C-ABI artifact no longer records the machine that built it.**
  `build-ffi` rewrites both paths after the link — install name
  `packages/m0-core/libm0core.dylib` → `@rpath/libm0core.dylib`, search path
  `/Users/runner/work/.../modular/lib` → `@loader_path` — taking the macOS
  artifact from **BROKEN to SATISFIABLE**: it now looks beside itself, so a
  consumer can supply the runtime. Neither path can be suppressed with a
  linker flag, because `mojo build` adds them itself; macOS also needs an
  ad-hoc `codesign`, since arm64 invalidates the signature on any Mach-O
  edit and an unsigned dylib will not load at all.

  **`smoke-ffi` was silently undoing this**: it ran its own `mojo build` into
  the same output path, so it overwrote `build-ffi`'s output and tested an
  unfixed artifact. It now depends on `build-ffi` and tests what that task
  emits, supplying the runtime through `DYLD_LIBRARY_PATH` — the documented
  consumer requirement, exercised rather than accidentally bypassed.

  **Linux was never broken the way macOS is.** The published `.so` has no
  `DT_NEEDED` entries at all and is statically linked; its `DT_RUNPATH` was
  inert debris. The missing-runtime problem is macOS-only, and
  `check-ffi-portable` now reports three states — `BROKEN`, `SATISFIABLE`,
  `SELF-CONTAINED` — because pass/fail could not express that. It also reads
  ELF itself rather than shelling out: the previous version used
  `llvm-objdump`, which exists on macOS, formats ELF differently, matched
  nothing, and reported a Linux artifact as portable. A guard that answers
  "fine" when it cannot read the file is worse than no guard.

  Still not self-contained: shipping the runtime turns on a licensing
  question, and the **2026-08-23 nightly still declares the proprietary MAX
  Platform license** — five days after the Apache-2.0 relicensing, so the
  discrepancy is not a same-day packaging slip. Building the runtime from
  the Apache-licensed sources was assessed and rejected as disproportionate
  (an MLIR/Bazel compiler stack for a 1.57 MB macOS-only bundle). See
  [docs/FFI_DISTRIBUTION.md](docs/FFI_DISTRIBUTION.md).

- **The published `libm0core` artifacts do not load off the machine that
  built them, and now there is a check that says so.** Every release from
  v0.1.0 has shipped a C-ABI library whose recorded search path is the CI
  runner's own directory, so `dlopen` — the entire point of the artifact —
  fails for anyone who downloads it. `smoke-ffi` could never catch this: it
  loads the library **in the build tree**, where the venv it was linked
  against still exists, so it passes on exactly the machine where the defect
  cannot appear.

  `poe check-ffi-portable` checks what a load attempt cannot — that every
  recorded search path is self-relative and every dependency is a system
  library or shipped alongside — and fails on the current artifact and on
  every published one, which is how it was verified. The README no longer
  claims the prebuilt artifacts are usable as-is.

  The fix is demonstrated in [docs/FFI_DISTRIBUTION.md](docs/FFI_DISTRIBUTION.md)
  (the bundled artifact loads from an unrelated directory with a clean
  environment) but not yet applied: two of the three defects are ours and
  need no permission, while shipping the Mojo runtime's 1.57 MB
  three-file closure turns on a licensing question that is genuinely
  unresolved — Mojo's sources went Apache-2.0 with LLVM Exceptions on
  2026-08-18, but the wheel shipping those prebuilt binaries still declares
  the proprietary MAX Platform license. Recorded in NOTICE.

- **`body_bytes` no longer swallows a pending exception.** `PyObject_Length`
  answers -1 with the exception *set*; folding that into the empty-body case
  returned an empty list and left the error pending, poisoning whatever
  C-API call ran next. Unreachable through the shim contract today (`_body`
  is always `bytes`), found by review, fixed before it could become
  reachable.

## [0.7.0] — 2026-08-23

### Added

- **`m0serve --blocking-threads N` / `M0_BLOCKING_THREADS` — Stage B, the
  acceptor and its handler pool.** The event loop stops calling
  `HTTPService.func`. It parses the request, hands it to one of N handler
  threads, and returns to `wait()`; the thread calls the handler and pokes
  the loop back, which encodes and writes the response through the same
  `RESPONDING` path every other response takes. **One slow view no longer
  stalls the connections pinned behind it**: on `apps/wsgi_bare`, a fast
  request answered in **1 ms** with two 1.5 s views in flight, against
  **2.7 s** for the identical server without the flag — the same code, the
  same load, the flag as the only variable.

  This is the failure the mixed-workload benchmark measured and Stage A did
  not touch (fast-request p99 1.6 ms → ~194 ms, ~120x, under `--workers`
  *and* `--threads` alike), because a keep-alive connection belongs to the
  loop that accepted it in both modes and adding loops does not change that.
  Granian's `--blocking-threads` is the same architecture and the reason the
  design had a working reference.

  Composes with both execution modes — `--workers W` gives W processes of N
  handler threads, `--threads T` gives T loops of N each, one pool per loop
  because a job names a slot and a slot means nothing outside the loop whose
  provision pool it indexes. Off by default: it costs N threads and N
  handlers' worth of per-thread state per loop, and a server whose views are
  all fast gains nothing.

  Unlike `--threads`, it is **not** refused on a GIL-enabled interpreter. A
  pool under the GIL is what gunicorn's `--threads` is: CPU-bound views
  serialize, but a view waiting on a database, a socket or a sleep releases
  the GIL and the isolation is real — which is the workload the mode exists
  for. It **is** refused together with `--realtime`, because the streaming
  hooks (`sse_drain_slot`, `sse_slot_disconnected`, `ws_message`) are called
  on the loop's handler while `func` would run against a pool thread's own
  registries; half-wiring that would fail quietly.

- **`lightbug_http.offload`** — the queue itself, and it knows nothing about
  Python. Two `SOCK_DGRAM` socketpairs (submit, and a completion channel the
  loop registers exactly as it registers a `BroadcastBus` channel) plus
  per-slot request/response storage. Datagrams because they preserve message
  boundaries: N threads receiving on one channel each dequeue one whole job,
  so the kernel is the queue and there is no mutex to write. Each handoff is
  published by the socketpair syscall that names it, which is the whole
  memory-ordering argument. `m0_wsgi.blocking_pool` is the thread side —
  the only half that attaches to an interpreter, which is what keeps
  libpython off everything else's link line.

  **Retiring the pool is one method, `BlockingPool.stop_and_join`, and that
  is a safety property rather than tidiness.** `next_job` blocks with no
  timeout, so the poison-pill count must equal the thread count exactly: a
  thread that receives no pill blocks forever, which is a hung
  `pthread_join`. Closing the queue does not rescue it — on Linux, closing
  the write end of a connected `AF_UNIX` `SOCK_DGRAM` pair does **not** wake
  a peer already blocked in `recv`, while macOS returns 0 and looks fine.
  That asymmetry cost a 20-minute CI timeout: `test_offload.mojo` read one
  pill more than `stop` had sent, to "prove" the close was a backstop, and
  passed locally while hanging ubuntu. The claim is gone from the code and
  the count is now a property of the type instead of an agreement between
  call sites.

  Three things a slot in flight is *not*: touched by the loop, swept by the
  idle or header timeout, or recycled. A client that disconnects mid-job
  detaches the fd but leaves the provision borrowed until the completion
  arrives, so a late completion has nowhere wrong to land — a generation
  counter would detect that race, holding the slot removes it. Past 256
  jobs in flight the loop runs requests inline rather than queueing them,
  which is a bound on what the channels must hold and degrades to exactly
  the behaviour of a server without the flag.

- **`c/socketpair.mojo`**, extracted from `broadcast.mojo` — one binding, two
  callers, and one deprecated-`alloc` warning site instead of two. See
  [NOTICE](NOTICE).

- **`poe smoke-blocking-threads`.** Phase 1 runs everywhere: the `--realtime`
  refusal, the isolation measurement, four clients abandoned mid-job leaving
  every slot recovered, HEAD through the pool (the loop has to remember it —
  by completion time the request belongs to another thread), a raising
  handler, and SIGTERM answering an in-flight request rather than dropping
  it. Phase 2 needs the GIL off and is `py-canary`'s new phase F: two loops
  of four handler threads each, proving Stage B composes with Stage A — and
  deliberately loading only half a pool, because past saturation a request
  queues for a thread, which is what a thread pool is and not what the row
  asserts. Measured at **1 ms against a 400 ms gate**, so the row fails on a
  broken pool rather than on a busy machine.

### Changed

- **The WSGI environ is built in Mojo through the CPython C API — the bridge
  costs 3.5 µs/request instead of 14.9.** `PyDict_New` and `PyDict_SetItem`
  build the dict, `PyUnicode_DecodeUTF8` builds every key and value, and
  `PyTuple_New`/`PyTuple_SetItem`/`PyObject_CallObject` hand the finished
  dict to the shim. End to end on one worker serving `apps/wsgi_bare` with a
  browser-shaped keep-alive request: **28,853 → 45,715 rps, 1.57x**, p50
  508 → 315 µs, p99 1.06 ms → 681 µs.

  This retires the last large measured item in the Granian gap. The shim
  used to rebuild the environ in **pure Python on every request**, parsing a
  binary blob Mojo had just written — 28 `_read_str` calls for a
  twelve-header request, 12.09 µs of the bridge's 14.23, 85% of it.

  The blob existed because Mojo 1.0's `PythonObject` leaks a reference per
  call argument, so the environ could not be passed as one. The raw C API
  refcounts explicitly and is not that path, which is what made this
  possible at all. `smoke-django`'s RSS guard — the instrument for any
  change to this boundary — still reports **0 KB over 10k requests**.

  The **request body still crosses as bytes** through the persistent
  bytearray, because Mojo 1.0 has no `PyBytes_*` binding of any kind and a
  `bytes` object therefore cannot be built from Mojo. A request with no body
  now skips that path entirely — `buf_addr()` is not called and nothing is
  copied. There is no `PyUnicode_DecodeLatin1` either, so PEP 3333's
  latin-1 tunneling is spelled as a UTF-8 encode in `environ.mojo` and
  decoded by `PyUnicode_DecodeUTF8` into exactly the same `str`; ASCII, the
  overwhelming case, is its own UTF-8 and costs no copy.

### Removed

- **`serialize_request` and the request blob format.** Nothing crosses the
  boundary positionally any more except the request body, which needs no
  framing because its length is passed as an argument. `environ.mojo` keeps
  the pure half — `cgi_header_name` and the CGI/latin-1 byte transforms —
  so the mapping stays testable without an interpreter, and
  `test_environ.mojo` still asserts the two statements of the CGI rule
  agree on every shape it distinguishes.

### Fixed

- **Graceful shutdown no longer waits the full 5 s drain for connections
  that are already finished.** `active_count` counts a connection that is
  merely *open* the same as one with a request in flight, so a server
  holding idle keep-alive connections waited out the whole
  `DRAIN_TIMEOUT_NS` budget at SIGTERM — **5.02 s to exit against 0.02 s
  idle, in every execution mode**, which is most of what `docker stop`
  allows before it escalates to SIGKILL.

  The shutdown path now closes slots in `READING_HEADERS` whose receive
  buffer is empty — "between requests" — before it starts the drain clock.
  Those connections could never have been served by the drain loop anyway:
  it dispatches `EVFILT_WRITE` only, so a request arriving mid-drain is not
  read there. **5.02 s → 0.03 s** under `--workers 4`, under
  `--blocking-threads 4`, and on a single loop.

  A slot mid-request, mid-response, or with a job in a pool thread is left
  alone, and the SSE/WebSocket farewell still runs first, so streaming
  clients get their close comment or 1001 frame. Both halves of the
  contract are pinned: `smoke-blocking-threads` already asserted that a
  request in flight at SIGTERM is answered rather than dropped, and
  `smoke-shutdown` gained a phase (`scripts/drain_idle_probe.py`) asserting
  idle keep-alive connections do not hold the drain open — checked against
  the unfixed loop, where it fails at 5.01 s.

  This also retires the standing suspicion that `--threads` shuts down
  slowly. It does not, and neither does the pool: every mode exited at
  5.02 s, and a 5 s wait loses that race.

## [0.6.0] — 2026-08-23

The release that finished moving the WSGI examples off their own
`server.mojo`, and made the bridge 2.35x faster. `--realtime` and
`--health-path` carry the hold machinery `apps/django_realtime` used to own,
`--reload` re-forks workers onto changed Python in ~300 ms, and
`serialize_request` — 77% of the bridge's per-request cost — went from 48 µs
to 0.44 µs, taking `apps/wsgi_bare` from 12,289 to 28,911 rps. The
benchmarking also settled what comes next: one slow view raises fast-request
p99 by ~120x in *both* execution modes, which is the failure Stage B was
built to remove.

### Added

- **`m0serve --realtime` — the hold machinery behind a flag.**
  `apps/django_realtime` was the last example carrying its own
  `server.mojo`; everything in it now lives in `WSGIHandler`. The flag turns
  on two `SSERegistry`s (streams and sockets, holding disjoint slots),
  `take_hold` on every application response, the WebSocket handshake a
  buffered WSGI response cannot produce, `ws_message_request` for inbound
  frames, and — created before the fork and before the first Python call —
  the `BroadcastBus` and the `SharedAtomics` id slot with their
  `M0_BUS_WRITE_FDS` / `M0_SHARED_ID_ADDR` exports. `M0_CORE_LIB` is
  *discovered* rather than demanded: beside the binary first, then
  `poe build-ffi`'s output, and left alone if already set. Off by default,
  because it costs two slot arrays and because it makes `M0-Hold` a header
  the server consumes rather than one an application may emit for its own
  reasons.
- **`--realtime` works under `--threads N`.** The bus is built on the main
  thread before spawning and loop `i` drains `read_fd(i)`, exactly as worker
  `i` does. A `SOCK_DGRAM` socketpair does not care whether the peer is a
  process or a thread, so `m0pub.py` and `sse_peer_frame` are unchanged —
  the publisher reaches N threads with the N `os.write`s it used to reach N
  processes and never learns which it is talking to. `smoke-django-realtime`
  phase 4 pins it where the GIL is off (`py-canary` C3): six streams spread
  over four loops, one publish from one thread's Django reaching all six
  with numbered ids, then a clean four-loop drain on SIGTERM.
- **`m0serve --reload [--reload-dir DIR]` — hot reload.** A changed `.py`
  under a watched directory stops the workers and forks replacements onto
  the new module, in ~300 ms plus a drain. The flag forces a supervisor even
  at one worker and even under `--threads N`, and that composes with both
  execution modes for one reason: the supervisor never touches Python. It
  watches with `listdir` and `stat` — libc, and therefore safe in a process
  forked without `exec` — and the fork still precedes the first Python call
  because the supervisor never makes one. A reload is a graceful shutdown
  followed by a fork: workers leave through the existing `SIGTERM` →
  drain → `exit_worker()` path, unchanged, and the exits are accounted as a
  reload rather than a retirement, so the crash-respawn budget is untouched.
  Stragglers past a 5 s drain deadline get `SIGKILL`. What reloads is the
  worker; the Mojo binary is never re-exec'd, so a changed `.mojo` still
  needs a rebuild.
- **`--reload` sets `PYTHONDONTWRITEBYTECODE=1`,** which is not a tidiness
  choice. CPython validates a cached `.pyc` against its source's mtime in
  whole **seconds** and its size, so a rewrite landing in the same second at
  the same length looks unchanged to the import system. The reloader sees it
  — it compares nanoseconds — re-forks, and the fresh worker imports the old
  bytecode: a reload that visibly happened and changed nothing. Writing no
  bytecode means there is never a cache to go stale. `smoke-reload` pins it
  by editing same-length versions in the same second, and asserts no
  `__pycache__` appears.
- **The `wrk` keep-alive tail row, and the Stage B go/no-go**
  (`docs/WSGI_PERFORMANCE.md`, `scripts/bench_wsgi_tail.sh` +
  `scripts/bench_wsgi_tail_ka.sh`). Three rounds on 3.14.7t:
  keep-alive p99 is 1.6–2.9 ms across `--workers` and `--threads` at both
  2 and 4, so the 84 ms tail does not reproduce as a property of the
  design; the single excursion in seventeen valid rows was in *prefork*.
  **Stage B is a no-go on this evidence**, and the gate is restated as a
  mixed-workload run, because a hello-route benchmark cannot exercise the
  slow-view isolation Stage B is half about. Granian 2.8.1 measured at
  1.4–2.0x either mode on the same interpreter with a byte-identical
  response — recorded as the better-evidenced target. Also recorded: the
  ephemeral-port exhaustion that made the first `wrk` table report a
  spurious 8–10x threads-vs-prefork tail gap and five empty rows, and why
  gunicorn cannot appear in a keep-alive table at all.
- **`scheme_separator`** (`lightbug_http/uri.mojo`, so also in
  [NOTICE](NOTICE)). See Fixed.
- **`MtimeScanner`** (`m0-http`): the change detector, suffix-filtered with
  the suffix supplied by the caller so `m0-http` keeps no notion of what a
  source file is. One number per pass — newest mtime *and* file count,
  because deleting the newest file leaves the maximum in the past — compared
  against the previous pass rather than a high-water mark. `__pycache__`,
  `.git`, `node_modules` and dotfiles are skipped; the first pass records
  and never reports. `waitpid_nonblocking` (`WNOHANG`) is what lets the
  supervisor poll instead of parking in `wait`.
- **`--health-path PATH`** answers `PATH` in Mojo with a liveness JSON —
  under `--realtime`, with the live `subscribers` and `sockets` counts, which
  is how the smokes assert that a vanished client was actually unsubscribed.
  Opt-in, and separate from `--realtime`, for the mirror-image reason: an
  application may already route `/health`, and a server that took the path
  silently would shadow it.

### Changed

- **The WSGI bridge is 2.35x faster: 12,289 → 28,911 rps** on
  `apps/wsgi_bare` at one worker, p50 1.21 ms → 508 µs, p99 2.47 ms →
  1.07 ms (same interpreter, two rounds). `serialize_request` cost **48 µs
  per request — 77% of the bridge's whole per-request cost**, and six times
  what the Python shim it feeds costs. Enumerating headers with `keys()` +
  `get()` allocated a String per name and per value and linear-scanned for
  each, and `cgi_header_name` allocated three more per header: ~70 String
  allocations to move twelve headers. The projection now walks `count()`
  with the header map's own spans and writes the CGI name's bytes directly,
  uppercasing and mapping `-` to `_` in place — **48.10 µs → 0.44 µs**. PEP
  3333 conformance green; `smoke-django`'s RSS guard still 0 KB over 10k
  requests.

  Recorded because the suspicion was wrong: the Python shim's environ parse
  looked like the culprit and is only 11.5 µs. `scripts/bench_bridge_parts.mojo`
  is the split that found it, and `handle()` is now five-sixths of what
  remains.
- `Headers.name_span`/`value_span` are public (were `_name_span`/
  `_value_span`), so headers can be projected into another representation
  without allocating. `keys()` is unchanged and still right for callers that
  want owned Strings. A fork change; see [NOTICE](NOTICE).

- **Stage B is justified — reversing the no-go recorded earlier in this
  release cycle.** That verdict came from a keep-alive benchmark on a hello
  route, which cannot produce the failure Stage B is half designed for, and
  it named a mixed-workload run as the gate. That run
  (`scripts/bench_mixed_workload.sh`, 3.14.7t, two rounds) is decisive: one
  slow view alongside fast traffic takes fast-request p99 from **1.6 ms to
  ~194 ms (~120x)** while p50 does not move — a subset of connections
  stopped dead, not general slowdown. `--threads` is affected identically,
  because a keep-alive connection belongs to the loop that accepted it in
  both modes. Granian's `--blocking-threads`, which *is* the Stage B
  architecture, is flat under the same load (0.96 → 1.22 ms).
- **The Granian throughput gap is the WSGI bridge, not the HTTP layer or
  the concurrency model** (`scripts/bench_layer_split.sh`). Three rows
  differing by one layer, byte-identical 13-byte response: `apps/hello`
  (zero Python) 78.3k rps at 178 µs, the same HTTP layer through the bridge
  12.4k at 1.18 ms, Granian through its own bridge 124.6k at 109 µs. The
  bridge costs ~1 ms per request because the shim rebuilds the WSGI environ
  in pure Python every time (~28 string decodes for a twelve-header
  request) — itself downstream of the `PythonObject` reference leak that
  forced the blob design. Building the environ through the raw CPython C
  API sidesteps the leak; `PyDict_New`/`PyDict_SetItem` were compile-checked
  as reachable via `Python().cpython()`.
- `apps/django_wsgi`'s `/slow` accepts `?ms=`, defaulting to the 1500 ms
  `smoke-django` expects. The mixed-workload benchmark needs a much shorter
  hold — 1.5 s swamps the signal instead of measuring it.

### Fixed

- **A bare `://` anywhere in a request target was read as a scheme**, so a
  query parameter carrying an unencoded URL (`/go?url=http://x`) was parsed
  as a URI whose scheme was `/go?url=http` and answered `400` before
  reaching the application. `URI.parse` searched the whole target for `://`;
  `scheme_separator` now accepts one only when everything before it is a
  scheme as RFC 3986 §3.1 defines it — ALPHA, then ALPHA / DIGIT / `+` /
  `-` / `.` — a character set that by construction cannot contain `/`, `?`
  or `#`. It is computed before the `ByteReader` borrows the string: a
  second interior reference taken while the reader holds one invalidates
  it. Clients that percent-encode — every browser form, every `urlencode` —
  never hit this, which is what kept it a Known issue rather than a bug
  report. `test_uri_scheme.mojo` covers both directions and `smoke-wsgi` now
  sends its `/reentrant?url=` unencoded as well as encoded, so a real server
  proves it.

### Removed

- `apps/django_realtime/server.mojo`, and with it `M0_DJANGO_PROJECT`. The
  row keeps `m0pub.py`, `djangoproj/`, `realtime_probe.py` and `static/`, and
  is served by `bin/m0serve djangoproj.wsgi:application --app-dir
  apps/django_realtime --realtime --health-path /health`. No WSGI row has a
  `server.mojo` any more.

## [0.5.0] — 2026-08-22

The release the server grew a command line and a second way to be
concurrent. `m0serve` is one built binary that serves any WSGI application,
so three example apps stopped carrying a `server.mojo` each; `--threads N`
runs N event loops on N pthreads in one process on free-threaded CPython,
at throughput parity with prefork for ~60% of its RSS.

### Added

- **`--threads N` / `M0_THREADS` — the threaded execution mode** (free-threaded
  CPython only). N event loops on N pthreads in one process, one interpreter:
  each thread runs its own `run_event_loop` with its own `WSGIHandler`, and
  so its own `WSGIApp`, bridge and shim namespace — the bridge's per-process
  singletons become per-thread without a line of the bridge changing, and
  the event loop is untouched. What it buys: one RSS instead of N, the app
  imported once, and the whole fork-after-init hazard class gone. What it
  does not: a keep-alive connection stays pinned to its loop, exactly as
  under prefork, so the keep-alive p99 shape is unchanged (the thread-pool
  stage is recorded in ROADMAP.md). `m0_wsgi.threaded` is the choreography —
  main initializes and imports before spawning and then detaches; every
  thread attaches once, serves, and releases; `DetachingBackend` wraps the
  loop's one blocking wait so a parked thread never stalls the others'
  stop-the-world; the process-wide signal pipe wakes a coordinator that
  pokes one shutdown pipe per thread. A GIL-enabled interpreter **refuses to
  start** with exit 78 and a sentence naming the requirement — never
  warns-and-runs. `--threads` and `--workers` are mutually exclusive.
  `wsgi.multithread` is finally True somewhere; every response carries
  `x-thread`. `smoke-threads` pins the guard on every runner and the mode
  itself on the free-threaded canary (phase D of `py-canary`) — green on
  **both** backends as of 2026-08-23: kqueue on macOS and epoll on Linux,
  with all four loops accepting in each, so a listener dup'd into N epoll
  instances under `EPOLLET` wakes every one of them and no `EPOLLEXCLUSIVE`
  follow-up is owed.
- **The threads-vs-prefork benchmark row** (`docs/WSGI_PERFORMANCE.md`,
  `scripts/bench_wsgi_modes.sh`): on 3.14.7t, `--threads N` is at throughput
  parity with `--workers N` (0.92–1.05x) at ~60% of its RSS, ~3.5x gunicorn
  on the same free-threaded interpreter.
- **`ThreadHandler`** (`m0-wsgi`): an `HTTPService` that constructs itself on
  a serving thread via a static `make(ctx)`. A trait rather than a function
  parameter because Mojo 1.0 cannot materialize a function-parameterized
  `def` as the runtime value a pthread needs; `WSGIHandler` implements it
  from the `ServeOptions` at `ctx.user`.
- **`m0_http.threads`** — raw pthreads from Mojo, packaged: `ThreadSet`
  (malloc'd Int64 argument blocks, `pthread_create`/`pthread_join` through
  `external_call`, a `def`'s address as the start routine), `ThreadBlock`,
  `ShutdownFanout` (one shutdown pipe per thread, poked together — the
  event loop never drains its pipe, so N loops cannot share one), `dup_fd`
  and `read_one_byte_blocking`. The idiom `scripts/py_thread_probe.mojo`
  proved, now importable under `mojo run` and tested without an interpreter
  (`test_threads.mojo`). Knows nothing about Python; that discipline belongs
  to `m0-wsgi`. The substrate for the threaded execution mode — nothing
  consumes it yet.
- **`M0_THREADS`** is read by `AppConfig` (default 1) and
  `threads_conflict(workers, threads)` answers the one message for asking
  for both execution modes at once. Mutually exclusive with `M0_WORKERS>1`.
  Read and validated ahead of the mode that will consume it, so the
  environment and `m0serve --threads` will say the same sentence.
- **`m0serve` — the uvicorn-shaped serve CLI.** One built binary
  (`poe build-serve` → `bin/m0serve`) serves any WSGI application:
  `m0serve MODULE[:ATTR] --host --port --workers --app-dir --static
  PREFIX=DIR --static-cache-control --access-log --max-body --metrics`.
  `ATTR` defaults to `application`; `--app-dir` (default `.`) is prepended to
  `sys.path`. Every `M0_*` variable keeps its meaning with the matching flag
  winning over it, and flags are strict where the environment loader is
  lenient — `--port 80eighty` is a usage error (exit 2), not a silent
  default. Startup failures exit 1 and name the thing (a missing app dir is
  caught before any interpreter starts; a module or attribute that will not
  import is reported in Python's own words). `--max-body` and `--metrics`
  are the first two server-only `ServerConfig` tunings a command line can
  reach. The entry file lives at the package root
  (`packages/m0-wsgi/m0serve.mojo`), outside `src/`, for the reasons
  `m0-core/ffi_exports.mojo` documents; the parser (`src/cli.mojo`) is pure
  and interpreter-free, tested in `test-wsgi`.
- **`WSGIHandler`** (`m0-wsgi`): the one copy of the handler three example
  apps used to carry identically, with static mounts (`List[StaticFiles]`)
  answered in Mojo ahead of the bridge.
- **`M0_HOST`**: the listen address, read by `AppConfig` and honoured by
  `address()`. An IPv4 literal, or `localhost` for `127.0.0.1`; the listener
  is IPv4-only and resolves nothing.
- `poe smoke-serve`: `--help`/`--version`, the usage and startup exit codes
  (including a supervisor that gives up under `--workers`), flag-over-env
  precedence, a static mount with its `Cache-Control`, `--max-body` → 413,
  `--metrics`, and a graceful SIGTERM.

### Changed

- The Django, Flask and bare-WSGI rows are Python-only projects served by
  `m0serve`; `serve-django`, `serve-flask`, `serve-wsgi-bare` and the three
  smokes build the CLI once and reuse it. What the rows assert is unchanged.
- `WorkerSupervisor` exits **1**, not 0, when its respawn budget runs out
  with a worker still dead — a worker that crashes on every attempt usually
  could not start at all (a bad module path), and exiting 0 reported success
  to whatever launched the server. `test_respawn.mojo` pins it.

### Removed

- `apps/django_wsgi/server.mojo`, `apps/flask_wsgi/server.mojo` and
  `apps/wsgi_bare/server.mojo`, and with them the `M0_FLASK_PROJECT` and
  `M0_WSGI_PROJECT` variables — replaced by `m0serve … --app-dir`.
  `apps/django_realtime/server.mojo` keeps its own `main()` and
  `M0_DJANGO_PROJECT` until the hold/publish machinery moves behind
  `m0serve` flags.

## [0.4.0] — 2026-08-22

The release the WSGI host grew up in. `m0-wsgi` went from a spike to a
framework-agnostic PEP 3333 server with a conformance suite, a second
framework row, and a realtime story that gives synchronous Django the SSE
and WebSocket surface people adopt ASGI for. Separately, the HTTP hot path
got substantially faster — headers alone are worth +72% throughput.

### Added

- **In-process GRIP: sync Django holds SSE streams and WebSockets.** A view
  answers an ordinary buffered response carrying `M0-Hold: stream` or
  `M0-Hold: websocket` plus `M0-Channel`, and the server takes the
  connection from there. `take_hold` (`m0-wsgi`) consumes the instruction
  headers; an SSE hold keeps the view's body as the head of the stream, and
  a WebSocket hold cannot — a handshake answers `101` with a
  `Sec-WebSocket-Accept` derived from the client's key, which a buffered,
  re-encoded WSGI response has no way to produce. So Django *approves* and
  the Mojo layer *performs* the upgrade. Inbound frames make the return trip
  as ordinary requests: `ws_message_request` gives a message the shape of a
  `POST` (payload as body, channel/slot/opcode as `M0-` headers) and a plain
  synchronous view handles it.

  Under a server that has never heard of these headers the same views
  degrade to short buffered responses — the GRIP property. The header names
  are M0-prefixed because this is GRIP-shaped, not GRIP-compatible.

- **Publishing that never enters Mojo.** The server exports its
  `BroadcastBus` write fds once, pre-fork, as `M0_BUS_WRITE_FDS`; `m0pub.py`
  (stdlib only) frames an event and `os.write`s one datagram per worker,
  including its own. No `PythonObject` crosses the bridge, so the reference
  leak rule and `smoke-django`'s RSS guard are untouched. One line in a sync
  view reaches SSE *and* WebSocket subscribers on every worker: the bus
  carries one SSE frame and delivery re-encodes per slot, so an
  `EventSource` client and a WebSocket client on the same channel see
  byte-identical messages.

- **Numbered event ids, so `Last-Event-ID` means something.** Each publish
  fetch-adds one `Int64` on the `MAP_SHARED` page the server allocates
  pre-fork, and the number goes into the bus datagram's id field and onto
  the wire as an `id:` line — which engages `SSERegistry`'s redelivery
  filter. An SSE hold seeds that filter from the request's `Last-Event-ID`.
  Python has no atomic read-modify-write over a raw address, so
  `m0_shared_fetch_add` joins m0-core's C ABI and `m0pub` calls it through
  `ctypes`. Absent `M0_CORE_LIB`/`M0_SHARED_ID_ADDR` it degrades to
  unnumbered frames — the only behaviour available under a plain WSGI host.
  Suppression, not replay: catching a client up on missed events needs a
  journal, which `DatastarStream` has and the raw registry does not.

  `apps/django_realtime` is the working demo; `poe smoke-django-realtime`
  and `poe smoke-django-realtime-ws` pin it, the latter with four held
  connections across two workers — one SSE stream and one socket each — all
  reached by ONE synchronous Django publish.

- **PEP 3333 conformance testing, framework-free.** `apps/wsgi_bare` is a
  plain WSGI callable with no third-party imports, and `poe smoke-wsgi` is
  the conformance suite over it: the `write()` callable, a second
  `start_response`, multi-chunk iterables, `close()`, arbitrary status
  passthrough, and `wsgi.input` read patterns. `smoke-django` gains a pass
  under `M0_WSGI_VALIDATE=1`, wrapping the app in `wsgiref.validate`, with a
  `/pep3333/canary` route that must fail under the wrapper so a misspelled
  variable cannot silently downgrade it to a second unvalidated run.
  Reasoning, including why repointing Django's own `tests/servers/` here was
  rejected, is in [docs/WSGI_CONFORMANCE.md](docs/WSGI_CONFORMANCE.md).

- **Flask as a second framework row.** `apps/flask_wsgi` and `poe
  smoke-flask`, with the assertions both rows share extracted into
  `scripts/wsgi_framework_contract.sh` — routing, both directions of the
  cookie path, body round trips past the shim's 64KB transfer buffer, binary
  safety, query parsing, the framework's own 404, and a raising view
  becoming a 500. A row needing assertions of its own would be evidence the
  host is not framework-agnostic after all. Adding Flask needed no change to
  `m0-wsgi`.

- **Graceful shutdown on SIGTERM/SIGINT.** The loop always knew how to drain
  — close the listener, `: close` to SSE clients, a 1001 frame to WebSocket
  clients, in-flight requests for up to 5s — and nothing could ask it to.
  `install_shutdown_signals()` returns the fd to pass as `shutdown_read_fd`.
  Mojo has no global `var` and a POSIX handler gets no user-data pointer, so
  `src/global_slot.mojo` reaches `pop.global_alloc` for what C spells
  `static`; if that ever stops working nothing is installed and the default
  disposition stands, which `shutdown_signals_active()` reports.
  `WorkerSupervisor` propagates a signal aimed at the supervisor alone to
  its children — what `docker stop` does, and what used to leave workers
  orphaned on the port. `poe smoke-shutdown` covers both paths.

- **Static files ahead of the bridge.** `StaticFiles` grew a `Cache-Control`
  policy, emitted on 200/206/304 (a validator response carries freshness
  too, per RFC 9110), and the Django rows mount it: asset requests are
  answered in Mojo with type, ETag revalidation and traversal 404s, and
  never enter Python. WhiteNoise has nothing left to do. Zero-copy
  `sendfile` remains recorded, not built — it needs event-loop support for
  fd-backed response bodies.

- **`m0-sqlite`:** the result codes callers actually branch on are exported
  (`SQLITE_CONSTRAINT`, `SQLITE_RANGE`, `SQLITE_NOMEM`, plus
  `SQLITE_OPEN_NOMUTEX`/`FULLMUTEX` so a caller assembling flags can
  reproduce the package's threading model). `sum_ints`, `min_ints`,
  `max_ints` and `stats_ints` are the SIMD pass `fetch_ints`' column-major
  layout was written for: over 200k rows, `fetch_ints + stats_ints` beats
  `SELECT sum(v), min(v), max(v)` 8.63 ms to 11.84 ms — mostly because the
  read-out runs one column fetch per row where SQLite runs three aggregate
  steps through its bytecode VM, not because of the vectorization, which is
  0.5% of that pipeline.

- **`sse_data_payload`** (`m0-http`) — the inverse of `format_sse_event`,
  returning what a browser's `EventSource` hands to `onmessage`; and
  `SSERegistry.filter_url`, the inverse of `subscribe`.

- **CI that cannot quietly rot.** A warning ratchet
  (`scripts/warning_ratchet.py`, `poe check-warnings`) holds the unique
  warning count at a committed baseline, because `mojo` has no per-warning
  suppression and warning number 69 would otherwise land among 68 residual
  ones unnoticed. `poe canary` runs the whole Mojo-nightly probe in one
  command, with the toolchain restore in an `EXIT` trap so it happens even
  when the canary fails. `poe py-canary` runs the WSGI suite against
  free-threaded CPython 3.14t and now runs weekly; `poe py-thread-probe`
  measures Mojo-spawned pthreads calling Python — 3.96x at 4 threads on
  thread-local state, and 0.71x on a shared dict, a confirmed per-object
  `PyMutex` mechanism recorded in
  [docs/WSGI_VS_ASGI.md](docs/WSGI_VS_ASGI.md).

### Performance

Each figure is against its own baseline in its own session;
[docs/SERVER_PERFORMANCE.md](docs/SERVER_PERFORMANCE.md) records a 1.7x
session-to-session swing on identical binaries, so they do not chain.

- **Headers stored as spans into a flat buffer, not a `Dict`: +72%
  throughput** — 29,000 → 50,000 req/s on `apps/hello`, p50 535 → 320 µs,
  five alternating A/B rounds. A `Dict[String, String]` cost two allocations
  per header to fill, a third to lowercase each name, and a fourth per
  lookup, because `key.lower()` builds a probe copy before it can hash. One
  blob indexed by parallel (offset, length) arrays makes a lookup a linear
  scan that compares lengths first and allocates nothing — and preserves
  insertion order, which the `Dict` never guaranteed.
- **The hot path cut to two syscalls per request: +24%** — 15.2k → 18.9k
  req/s, p50 1.03 → 0.83 ms. Persistent read-filter registration
  (`slot_read_armed`) removes an `epoll_ctl` ADD that failed `EEXIST` every
  time and the MOD it fell back to; idle timeouts move to a once-a-second
  deadline sweep instead of a per-request `timerfd_settime`; `TCP_NODELAY`
  on accepted sockets.
- **`Router.match` on spans: 2.8x on `/health`** (158 → 57 ns). Patterns
  live in one flat blob and matching walks the path by moving span
  endpoints; nothing allocates until a parameter is captured on a route that
  matched, and a 404 allocates nothing at all.
- **WebSocket unmasking and UTF-8 validation vectorized** — the 4-byte mask
  splats across 64 lanes (64 is a multiple of 4, so the pattern stays
  phase-aligned and the scalar tail needs no special case), and text
  validation skips pure-ASCII runs 64 bytes at a time while every non-ASCII
  byte still goes through the same strict decoder.
- **Startup RSS down 47–64%** — connection buffers are sized on first use
  rather than at pool construction, so a server no longer allocates for its
  configured ceiling before accepting anything. `apps/hello`: 26.5 → 14.1 MB
  at one worker, 77.7 → 28.0 MB at four.
- Log lines assemble in one buffer instead of a dozen `String`s.
- The per-slot response buffer is reused via `encode_into`, which had sat
  unused behind a comment claiming Mojo could not move out of a list-element
  field. It can, by `swap`. The honest result is 1.04x, and
  `SERVER_PERFORMANCE.md` was corrected to say so rather than leaving the
  item ranked first.

### Changed

- The Django example enables `django.contrib.sessions` on the signed-cookie
  backend, so it still needs no database. `poe smoke-django` asserts request
  cookies reach a view intact (including a value containing `=`), that split
  `Cookie` fields rejoin, that a cookieless request stays cookieless, and
  that a session counter advances across three requests.
- `AppConfig` maps to `ServerConfig` in one place instead of once per app.
- Mojo 1.0 deprecations cleared across the repo where a replacement ships:
  the memory and origin APIs, positional pointer indexing, `memcpy` →
  `unsafe_memcpy`, `deinit take:` → `deinit move:`, and
  `http/common_response.mojo` importing the names it uses instead of
  resolving them through a star-import — that pattern alone accounted for 57
  of the repository's then-143 unique warnings.
- The cross-worker smokes place one stream per worker deterministically
  (SIGSTOP the worker that won the first open, then open the second) rather
  than racing accept. Which worker wins is the kernel's choice and it is not
  a fair one: a macOS runner handed a single worker all 24 opens across six
  rounds, and opening in bursts made it worse, because the accept path
  drains the backlog until `EAGAIN` and the first worker to wake takes the
  whole burst.

### Fixed

- **Request cookies never reached a WSGI application.** The request parser
  diverted `Cookie` out of the header map into `RequestCookieJar`, and the
  WSGI environ is built by walking the header map — so `HTTP_COOKIE` was
  absent and `request.COOKIES` was always empty. Every Django session,
  login, CSRF check and message silently behaved as though the visitor had
  arrived with no cookies at all. `Cookie` now stays in `headers` as well as
  feeding the jar, and several `Cookie` fields are rejoined into one
  `"; "`-separated list (RFC 6265 §5.4) rather than collapsing to the last
  one. `Set-Cookie` on a *request* is no longer folded into the request's
  own cookies — it is a response field, and treating it as one invented a
  cookie the client never sent.

  Because a parsed request now carries its cookies in both places, `encode`
  and `write_to` write the jar only when `headers` does not already carry
  the field, so re-encoding a parsed request still emits one `Cookie`.

- **`RequestCookieJar` mis-parsed values, and its lookups did not match its
  storage.** Pairs were split on every `=` rather than the first, so any
  value containing one was truncated at the first segment — base64 pads with
  `=`, so a Django `sessionid` routinely lost its tail. Splitting also ran
  over the whole field instead of per cookie, so `a=1; b=2` parsed as one
  cookie `a` holding `1; b`. A pair with no `=` was stored under the empty
  name instead of being ignored (RFC 6265 §5.2). And `__getitem__`
  lowercased the key while stores, `__contains__` and `to_header` did not,
  so a jar holding `sessionId` answered nothing to any spelling; cookie
  names are case-sensitive (RFC 6265 §4.1.1) and are now treated that way
  throughout. The jar's own `parse_cookies` was dead code — `HTTPRequest`
  hand-rolled a separate, buggier copy — and both now share one path.

- **A request body that could not be read in one `recv` never completed.**
  The event loop registered read interest only while a connection was in
  `READING_HEADERS`; once headers parsed and the state moved to
  `READING_BODY`, nothing armed `EVFILT_READ` again. Since epoll is
  edge-triggered, body bytes already waiting in the socket buffer raised no
  further edge either, so the connection stalled until `body_read_timeout`
  answered `408`. Both the transition into `READING_BODY` and each
  incomplete body read now re-register read interest.

  This hit every request whose body did not arrive inside the first 4KB
  staging read — any POST or PUT over ~4KB, and any request at all whose
  client flushed headers before the body, regardless of size. It affected
  every app in the repo, not just the WSGI host: Django form posts, file
  uploads and JSON APIs all timed out. `poe smoke-django` now posts a 256KB
  binary body and a header-flushed-first body to `/echo` and compares the
  echo byte for byte.

- **`write()` discarded every byte.** The WSGI shim returned `lambda data:
  None`, so an application using the legacy write callable got a 200 with an
  empty body and no error anywhere. Django never calls `write()`, so nothing
  Django-shaped could have caught it — including the `wsgiref.validate`
  pass, which type-checks the call and not its effect. The iterable is now
  drained *before* the writes are joined, because an application may call
  `write()` from inside the generator it returned. Found by `apps/wsgi_bare`
  within minutes of its existing.

- **A second `start_response` without `exc_info` was silently accepted**,
  last call winning. PEP 3333 makes it an application error; it now raises.
  With `exc_info`, replacing the stored status and headers is always correct
  for a fully-buffering server, since nothing has ever been sent.

- **Keep-alive connections answered `408` to prompt requests.**
  `slot_header_start` was re-stamped in `_after_send`, so the header read
  deadline measured from the end of the *previous* response rather than the
  start of the current request: any connection idle longer than
  `header_read_timeout` got a `408` for a request the client had just sent
  promptly and completely. Measured at the boundary — a 9s gap answered 200,
  an 11s gap answered 408.

- **`m0-sqlite` answered questions it should have refused.**
  `sqlite3_column_name` returns NULL past `column_count()` and `cstr_len`
  dereferenced it, segfaulting on an out-of-range index; NULL is now guarded
  in `cstr_len`, one place for every caller. Out-of-range reads were
  indistinguishable from NULL — `column_int` answered 0, `column_text` `""`,
  and `is_null` answered True for a column that does not exist, so the one
  accessor whose job is removing that ambiguity was adding one. Every reader
  now bounds-checks, re-reading the count per call because `prepare_v2`
  silently re-prepares after a schema change and a `SELECT *` can change its
  column count mid-life.

- **`verify_layout.c` guarded shipped code and nothing ran it.** It
  re-derives with `_Static_assert` every SQLite struct offset `vtab.mojo`
  hardcodes as a flat word buffer, but sat in `experiments/`, which nothing
  builds — so the claim that "every offset used here is asserted against the
  real headers" was aspirational, guarding a failure mode (a wrong offset
  silently corrupting every row after the first) this repo has shipped once
  before. It moved into `packages/m0-sqlite/test/` and `poe test-sqlite`
  runs it first.

- **Three latent faults in the lightbug fork**, each reachable only when the
  import graph is entered from a particular direction and so invisible until
  one was: `cookie/request_cookie_jar.mojo` used `Headers` without importing
  it (it resolved through the `header` ↔ `http.parsing` cycle on the usual
  path), and `uri.mojo`'s `__str__` and `is_http` still called
  `len(String)`, which Mojo 1.0 rejects. Bodies elaborate on demand, so all
  three compiled cleanly until a consumer reached them.

### Known limits

Newly documented rather than newly true, and worth knowing before turning on
more workers:

- `urlopen` from inside a view SIGKILLs the worker on macOS under
  `M0_WORKERS>1`: `_scproxy` calls into CoreFoundation, and Objective-C
  aborts rather than run in a process forked without exec. Use
  `http.client.HTTPConnection`, which does no proxy lookup;
  `apps/wsgi_bare`'s `/reentrant` route is the worked example and `poe
  smoke-wsgi` pins it. The general rule — after `fork()` without `exec`,
  platform runtimes are off limits, from application code too — is what the
  free-threading path is expected to retire.

## [0.3.0] — 2026-08-18

- WebSocket text messages are now validated as UTF-8 (RFC 6455 §8.1) on
  the assembled message — a multi-byte character split across fragments is
  fine; an invalid sequence closes with 1007. Binary frames still carry
  any bytes.
- `StaticFiles` honours single byte ranges (RFC 9110 §14): `bytes=a-b`,
  `bytes=a-`, and `bytes=-suffix` answer `206` + `Content-Range`;
  parseable-but-past-the-end answers `416` with `bytes */total`; multiple
  ranges and other units are ignored (full `200`, as the RFC permits).
  `Accept-Ranges: bytes` is advertised; `If-Range` deliberately never
  matches (weak ETags, strong comparison required) and falls back to the
  full representation.
- `apps/hello` (and the README example) now use the non-blocking event
  loop — the blocking accept loop remains in the fork but has no in-repo
  app consumers left.
- `Client` keep-alive: response boundaries are now computed
  (`classify_response` — Content-Length, chunked terminal chunk + trailers,
  bodiless statuses, HEAD) instead of inferred from EOF, and the connection
  is kept warm and reused across requests to the same host and port. Reuse
  rules are conservative (a `Connection: close` response, an HTTP/1.0 peer,
  a close-delimited body, or stray bytes past the boundary all retire the
  connection); a reused connection that dies before yielding a single
  response byte is retried once on a fresh dial. `keep_alive=False`
  restores one-connection-per-request. `connections_opened` reports dials;
  the smoke asserts a six-request conversation (HEAD included) rides one
  connection. Breaking: `request`/`get`/`post` now take `mut self`.
- `m0_http.WSHub` — the handler-side WebSocket registry: connected slots,
  per-slot outboxes, room broadcast, and cross-worker fan-out over the
  same `BroadcastBus` SSE uses (the bus is transport-agnostic;
  `sse_peer_frame` delivers encoded WebSocket frames as readily as SSE
  events). New `apps/ws_chat` demo — one room, every message reaching
  every socket across `M0_WORKERS` — and `poe smoke-chat`, which proves a
  message sent on one worker's socket arrives on the other worker's.

## [0.2.0] — 2026-08-17

- WebSockets (RFC 6455), server side: `websocket_upgrade` answers the
  opening handshake from an ordinary handler, the event loop parses frames
  (client masking enforced, fragments assembled, ping/pong and the close
  handshake answered in the loop), and complete messages arrive at the new
  `HTTPService.ws_message` hook — the ninth trait method, empty in handlers
  that never upgrade. Outbox, heartbeat (a protocol ping on the
  `M0_SSE_HEARTBEAT_MS` cadence), and disconnect plumbing are shared with
  SSE. Protocol violations answer with the RFC's close codes (1002/1009).
  New `apps/ws_echo` demo; `poe smoke-ws` proves the wire format against a
  from-scratch stdlib client. Also fixed in passing: a stale keep-alive
  idle timer could fire mid-stream and kill an SSE connection opened on a
  reused keep-alive connection.
- `m0_http.StaticFiles` — static file serving: a directory mounted under a
  URL prefix, with lexical path-traversal defense (decoded `..`/`.`/empty
  segments answer 404), extension-based content types, and ETag/`304`
  revalidation. The notes example serves `/static/` with it.
- `HTTPService.tick(now_ms)` — the application timer hook, fired every
  `M0_APP_TICK_MS` milliseconds (0 = off, the default) on the event loop's
  timer. Server-initiated pushes no longer need an inbound request; the
  counter demo gained a live uptime clock driven by it, ticking on one
  designated worker and reaching every worker's tabs over the broadcast
  bus. Breaking for handler authors: the trait gains an eighth method
  (empty `tick` in non-scheduling handlers).

## [0.1.0] — 2026-08-17

First release. Everything below is new.

### The server (`lightbug_http`, a maintained hard fork)

- HTTP/1.1 server, Linux (`epoll`) and macOS (`kqueue`), forked from
  lightbug_http v26.1.2 after upstream was archived — see [NOTICE](NOTICE)
  and [PROVENANCE.md](PROVENANCE.md).
- Non-blocking event loop: multiplexed keep-alive connections,
  header/body/idle timeouts, graceful shutdown that drains in-flight
  requests, opt-in Prometheus-format `/__metrics`.
- Request-parsing hardening: request smuggling (CL+TE, duplicate
  `Content-Length`, `chunked` not last), header-count and size caps,
  request-target normalization, chunked-size integer overflow — each guard
  pinned by a test verified to fail without it.
- SSE as a first-class server concern: per-slot outboxes with backpressure,
  `Last-Event-ID` redelivery suppression, heartbeats on idle streams
  (`M0_SSE_HEARTBEAT_MS`) that double as dead-subscriber detection.
- Cross-worker SSE fan-out: a pre-fork `BroadcastBus` (one datagram channel
  per worker) plus `SharedAtomics` event ids make `M0_WORKERS>1` and SSE
  compose; a broadcast on any worker reaches every worker's subscribers.
- `fcntl(F_SETFL)` fixed on ARM64 macOS (Darwin passes variadic arguments
  on the stack): `set_nonblocking` now actually works there, which is what
  lets two workers race on one shared listener without the loser blocking
  inside `accept()`.
- Outbound `Client`: GET/POST/any method with full response parsing —
  Content-Length with loud truncation detection, chunked, and
  close-delimited bodies.

### The framework (`m0-http`)

- Router with `:param` captures and real `405` + `Allow`.
- Content negotiation: `Accept` (quality factors, wildcards, `*/*` resolves
  to JSON), `Accept-Encoding` (codec-agnostic, RFC 9110 `identity`/`*`/q=0
  rules), `Accept-Language` (RFC 4647 matching, serve-something-over-406).
- Weak ETags (wyhash) with `304 Not Modified`, URL-keyed response cache.
- API-key auth with constant-time comparison, CORS hooks, health/readiness
  registry, JSON-lines access logging, `M0_`-prefixed env configuration.
- Multi-worker fork supervisor with crash respawn: workers accept from one
  shared pre-fork listener; a respawned worker takes over its predecessor's
  identity (index, bus channel).

### Datastar (`m0-datastar`)

- Datastar v1.0.2 wire format with zero dependencies (`consts`, `sse`), so
  frames are usable without the framework.
- `DatastarStream`: subscriptions, five broadcast shapes, `read_signals`,
  and `Last-Event-ID` replay from a bounded frame journal — including
  across restarts when the app persists the journal (the todo example
  does, in ~15 lines of SQLite).

### WSGI (`m0-wsgi`)

- Runs Django (or any WSGI app) on this server by embedding CPython. Bodies
  cross the boundary as raw addresses (Mojo 1.0 binds no `bytes` API), and
  per-request data avoids the toolchain's `PythonObject` reference leak by
  design — an RSS guard in CI keeps it that way. Prefork via `M0_WORKERS`,
  benchmarked at ~1.6–2.2x gunicorn's throughput on the same Django app.

### SQLite (`m0-sqlite`)

- Connections, statements, typed columns, transactions, bulk read-out —
  WAL by default, busy timeouts, honest error text. A sibling package that
  imports nothing else here. Measured guidance in
  [docs/SQLITE_PERFORMANCE.md](docs/SQLITE_PERFORMANCE.md).

### C ABI (`libm0core`)

- `poe build-ffi` emits `libm0core.so`/`.dylib` (FNV-1a, xxHash32,
  wyhash64, JSON escape) for Bun `dlopen`, N-API, or `ctypes`; release
  artifacts for Linux and macOS are attached to GitHub releases.

### Examples (`apps/`)

- `hello` — the whole server in one file.
- `notes_api` — the framework showcase: negotiation, ETags, problem+json,
  CORS, validation.
- `datastar_counter` — multi-tab live sync; the reference wiring for
  cross-worker fan-out and shared-memory state.
- `datastar_todo` — the flagship: HTML-over-SSE broadcasts, SQLite
  persistence, and SSE replay across restarts.
- `django_wsgi` — a real Django project served by the WSGI host.

[0.9.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.9.0
[0.8.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.8.0
[0.7.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.7.0
[0.6.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.6.0
[0.5.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.5.0
[0.4.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.4.0
[0.3.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.3.0
[0.2.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.2.0
[0.1.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.1.0
