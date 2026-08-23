# Changelog

Notable changes to `mojo-http`. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[SemVer](https://semver.org/) with the standard pre-1.0 caveat: **minor
versions may break the API**.

## [Unreleased]

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

## [Unreleased]

### Changed

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

[0.5.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.5.0
[0.4.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.4.0
[0.3.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.3.0
[0.2.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.2.0
[0.1.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.1.0
