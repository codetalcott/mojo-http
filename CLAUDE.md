# CLAUDE.md

Guidance for Claude Code in this repository: the rules, each pointing to the
note (`docs/notes/…`) that holds its incident, measurement or argument.
[docs/README.md](docs/README.md) says what every other page is for.

## Where the project stands

**Run `uv run poe milestones` before planning work.** It computes what
remains from `docs/SPEC.md`, ROADMAP's Known issues and the soak record, so
it cannot disagree with them or depend on what the last session remembered;
every `Tests` run prints it, and the docs gate runs its rot checks.
`docs/SPEC.md`, the capability matrix (one row per capability, each naming
the gate that proves it), is where to look for "is X covered?". The
milestones derive from row status:

- **beta** — no row is `implemented` (the sheet's word for "in the tree, no
  gate dedicated to it"). Nothing ships ungated.
- **1.0** — beta, every `planned` row outside section N resolved (built, or
  moved to `out of scope` with a reason), a current real-application soak,
  and Known issues that each declare what would retire them. Shipped; the
  report says whether its conditions still hold.
- **the application layer** — no section-N row `implemented`, every
  section-N `planned` row resolved, and a soak on the layer: an application
  outside `apps/` on `Views`/`Fragment`, recorded in
  `docs/REAL_APP_VALIDATION.md`'s application-layer section. MET on
  2026-10-02 by `unotes`, a dogfood application and the owner's alone;
  the staleness rule applies to it as to the server's. Its standing decisions are `docs/DECISIONS.md`
  (permanent ids, each with a retiring condition), kept resolvable by
  `check-docs`.

No row is `implemented` now. Gating one has always found real defects (an
unbounded WebSocket close linger, close codes echoed rather than validated,
2932 of 3000 inbound WebSocket messages dropped, `Expect: 100-continue`
failing on case and on HTTP/1.0), never a capability already correct, so a
capability that lands ungated is the highest-yield work there is.

## What this is

`mojo-http` — an HTTP/1.1 server and web framework for Mojo, extracted from a
private monorepo ([PROVENANCE.md](PROVENANCE.md)).

```
m0-core     (zero deps)   hashing, JSON escape, JSON parse, crypto
└── m0-http               router, negotiation, ETag, SSE, CORS, views, sessions
    └── lightbug_http     the forked HTTP server (lives inside m0-http)
m0-datastar               Datastar wire format (zero deps) + server glue (m0-http)
m0-wsgi                   WSGI/ASGI gateway — embeds CPython, layers on m0-http
m0-sqlite   (zero deps)   SQLite bindings — a SIBLING, never nested
m0-postgres (zero deps)   PostgreSQL bindings over libpq — a SIBLING too
```

**Imports point down.** `m0-core` depends on nothing; `m0-http` imports it
from nine files (`etag`, `health`, `reply`, `doctor`, `html`, `log`,
`grant`, `session`, `login`) — an inventory, not the constraint, which is the
direction, and that no libpython reaches the link line.

- **`m0-datastar`'s wire format imports nothing outside itself**: never add
  an `m0_http` import to `consts.mojo` or `sse.mojo`; the server glue
  (`stream.mojo`, `signals.mojo`) may. Datastar facts come from the bundle
  and the SDK's vendored spec and cases, never memory:
  [packages/m0-datastar/AGENTS.md](packages/m0-datastar/AGENTS.md).
- **`m0-wsgi` is the only package that embeds CPython.** Keep it that way: a
  Python import in `m0-http` or `m0-core` puts libpython on every build's
  link line. **Read [packages/m0-wsgi/AGENTS.md](packages/m0-wsgi/AGENTS.md)
  before editing m0-wsgi, the shim or `m0serve.mojo`, and before editing the
  pool and executor seams outside it** — `lightbug_http/offload.mojo`,
  `lightbug_http/ring.mojo`, `lightbug_http/loop/offload.mojo` and
  `m0_http.mojo_pool` — whose directories do not load it. Its costliest rules:
  - The bridge's per-request path is the raw C API: `PyDict_SetItem` does
    not steal, so every string built for it is `Py_DecRef`'d after the
    store; `PyTuple_SetItem` does, so its value must not be. `smoke-django`'s
    RSS guard stays at 0 KB over 10k requests.
  - Bytes never round-trip through a `String` (UTF-8; it corrupts every byte
    above 0x7F). `std.python` binds no `bytes` API; the way in is
    `ExternalFunction[name, type].load(cpy.lib.borrow())`, resolved once at
    construction.
  - Fork before the first Python call, never after.
  - No thread waits holding the GIL. Mojo takes it on its own only to destroy
    a `PythonObject`; waits go through `DetachingBackend`, and a loop with a
    handler pool holds no thread state while it serves.
  - The executor shim is a Python file rendered into Mojo: edit
    `shim/m0_shim.py`, run `poe render-shim`, commit both; `poe test-shim`
    holds its ownership rules.
  - Every lane needs a thread — a mount set that leaves one without is
    refused, never served — and a stream's begin frame goes out before its
    head.
- **`m0-postgres` and `m0-sqlite` import nothing else here and link
  nothing**: libpq and libsqlite3 are opened with `dlopen` at run time, and a
  `-Xlinker -lsqlite3` anywhere in the tree is a regression. Their three
  loader rules, each found by crashing (one struct holds the handle and its
  pointers, every entry point is private behind a method, the library is
  pinned `RTLD_NODELETE` with one handle kept open, since on macOS the flag
  alone let a reopen map a fresh copy, and every handle is `RTLD_LOCAL`,
  since a global image captures the calls of a second copy on Linux —
  m0-sqlite also refuses a second image at open, SPEC O23; m0-postgres
  pins one beside the first, O24),
  why m0-sqlite's `Connection` and `Statement` are
  deliberately not `Copyable`, why `test-postgres-server` is not in
  `test-all`, and six SQLite invariants that look like bugs and are not:
  [packages/m0-postgres/AGENTS.md](packages/m0-postgres/AGENTS.md),
  [packages/m0-sqlite/AGENTS.md](packages/m0-sqlite/AGENTS.md).

**One import cycle, on purpose (DECISIONS D33).** `src/` imports
`lightbug_http` throughout (`cors`, `signal`, `multiworker` …), and
ONE fork module imports back: `lightbug_http/loop/state.mojo` imports
`m0_http.log`; both sides are inside `packages/m0-http/`. **Nothing in
`src/` may reach the event loop — `event_loop.mojo` or any module of `loop/`
— at any depth**: `m0_http.log` resolves through the `m0_http.mojoc` that
`build-http` is writing while it compiles `src/`, so a `src/` module naming
`run_event_loop` fails with `invalid magic bytes` from a clean checkout on.
A function-local import does not help: a precompile parses every body it
reaches (`Server.serve_nonblocking`'s local import works only because
nothing in `src/` calls it).

**The pool and the host left the fork on 2026-09-18** (D28 retired;
docs/notes/the-host-leaves-the-fork.md), once Mojo 1.1.0 fixed a package's
lost trait witness tables (docs/notes/a-trait-and-a-directory-name.md; `poe
check-mojoc-trait` guards the fix, and `build-apps` compiling
`apps/pool_spike` is a second guard).

- **`mojo_pool.mojo` is `m0_http.mojo_pool`**, in `src/`: `MojoPool`,
  `PoolContext`, `PoolHandler` and `JOIN_TIMEOUT_NS` import from `m0_http`,
  and `lightbug_http` does not export them. An edit reaches apps after
  `build-http`, and `bin/m0serve` after `build-http`, `build-wsgi` and
  `build-serve`; its own test imports `src.mojo_pool`.
  `scripts/pool_sabotage.py` anchors exact source lines (the
  `T.make(PoolContext(...))` call among them) and CI runs it on Linux only,
  so an edit to one passes every local gate and fails the pull request: run
  `poe sabotage-pool` after touching the file, and re-point an anchor with
  its line.
- **`host.mojo` is the package `m0_host`** (`packages/m0-http/m0_host/`): it
  calls `run_event_loop`, so it cannot be in `src/`. Above the fork and
  `m0_http`, imported by neither, and resolved from SOURCE like the fork —
  never build an `m0_host.mojoc`: a directory beside a `.mojoc` of its name
  shadows it. `poe check-host-package` (in `test-all`) compiles it whole.
  `test_host.mojo` imports `m0_host.host` and every shared type from
  `m0_http.*`, never `src.*` (`src.threads.ThreadSet` is a different type).
- Renaming each `src/` is still NOT a quick fix: a source directory beside a
  `.mojoc` of its name shadows it, and every consumer would silently compile
  from source.

**Two entry files sit at package roots, outside `src/`, on purpose.**
`m0-core/ffi_exports.mojo` holds the C-ABI export `m0pub` calls
(`poe build-ffi` → `libm0core.so`/`.dylib`, shipped inside the m0serve wheel
and never as a release asset, D56; `poe smoke-ffi` loads it through `ctypes`).
It must stay the shared-lib entry file: relative imports don't compile
there, and `@export` symbols are only emitted from the entry module (its docstring
records the dead ends). `@export` cannot take a parametric function, so an
entry point names concrete types (`m0_shared_fetch_add` takes its address as
a `UInt64`). `m0-wsgi/m0serve.mojo` is the `m0serve` binary (`poe
build-serve` → `bin/m0serve`): `precompile src` must never see it, and it
imports `m0_wsgi` through the `.mojoc`. The WSGI example apps are
Python-only projects it serves; there is no `server.mojo` in them.

**Holds, from the server side.** The application contract (`M0-Hold` and
`M0-Channel`, `m0pub.publish()`, inbound WebSocket messages as a POST) is
[QUICKSTART.md](QUICKSTART.md), which `poe smoke-quickstart` executes, then
`docs/QUICKSTART_NEXT.md`, against the tree's own wheel: editing either can
break CI. The seam is the fork's `lightbug_http/hold.mojo`. **A hold that
reconnects with `Last-Event-ID` is caught up by `WSGIHandler._resume`** from
the loop's `ReplayJournal` (`--replay-frames`, SPEC I33, D65;
docs/notes/a-hold-that-replays.md) — one site, reached by the inline
subscribe and the `h` frame alike, so a Mojo mount's and a hold mount's
holds are covered too; all or nothing, and a gap is one unnumbered
`m0-gap` frame, never a partial history. The handler has TWO constructor
calls, `build` and `for_options`: a new per-loop setting goes through both,
or the pool path (the default under `--realtime`) runs without it, which is
how the first run of its smoke found the flag reaching nothing. A Mojo view on
`--mount X=mojo` holds with the same two headers from its `MojoPool` thread,
only under `--realtime`; a streaming response that is not a hold is still
refused from a pool thread, and a `websocket` instruction degrades there
(SPEC N11, `smoke-mojo-mount-hold`; docs/notes/hold-from-a-mojo-mount.md).
`--mount PREFIX=hold` holds for a Python application that authorizes in its
own views: the view signs channel, expiry and session binding into the
stream URL with `m0serve.grant` (its byte-identical twin in
`apps/django_realtime` is held to it by `check-docs`), and `HoldMount`
verifies it on the pool thread with `m0_http.grant` — HMAC in constant time,
expiry against the host clock, the session cookie against the binding — then
holds. `M0_GRANT_KEY` is the one secret both
sides read; the mount refuses to start without it or without `--realtime`
(SPEC I21, `smoke-hold-mount`; docs/notes/grant-verified-holds.md). The
verifier's test vectors are grants the issuer signed, so the two sides
cannot drift silently.

**Packaging.** The ROOT `pyproject.toml` never gets a `[build-system]`: `uv
sync` would then build the repo, which needs `bin/m0serve`, which needs the
venv `uv sync` is creating (`check_root_has_no_build_system` holds it). Each
wheel's lives under `packaging/<name>/`; both are wheels only,
`dependencies` deliberately empty. `packaging/m0serve/` is
`pip install m0serve` (no sdist: it cannot build without the toolchain; the
platform tag is measured from the binary; `poe smoke-wheel` proves it outside
the tree). `packaging/m0/` is the `m0` wheel, the framework's source and the
CLI that builds an application against it (SPEC N23–N26, D39–D43;
docs/notes/the-m0-wheel.md): read [packaging/m0/AGENTS.md](packaging/m0/AGENTS.md)
before touching it, its templates, the three `scripts/` it ships
(`relocate.py`, `bundle_artifact.py`, `binfmt.py`), the root `mojo` pin or
`max` group, or the six `/mojo/…` docs pages, whose URLs are permanent —
rewrite a page freely, never move one. Push no `m0-v*` tag casually: one
publishes to PyPI.

## The lightbug fork

`packages/m0-http/lightbug_http/` is a **hard fork**, not a vendored
snapshot: upstream was archived 2026-05-12, so changes there are ordinary
changes to this repo, with nothing to rebase onto.

- Keep it isolated from framework code. Do not refactor it to match
  framework style.
- Record anything materially new in [NOTICE](NOTICE) — a licensing record,
  not documentation.
- Do not "fix" the `m0_http.log` back-edge by inverting it.
- **The event loop is a door and a package.** `event_loop.mojo` holds
  `prepare_loop`, `run_event_loop`, `run_pass_once` and `_run_pass`; the
  rest is `loop/`, a module per job (`state`, `timers`, `accept`, `request`,
  `response`, `streams`, `offload`, `shutdown`). **Each per-slot reset has
  one owner** in `loop/state.mojo` (review C4): read interest belongs to
  `_arm_reads`, `_rearm_reads`, `_stop_reads`, `_await_write` and
  `_spend_read_edge` (a read that filled its buffer); the idle
  deadline to `_begin_request`, `_end_request`, `_arm_send_deadline` and
  `_arm_ws_linger`; a phase to `_stream_idle`, `_ws_linger`,
  `_record_response` and `_farewell_streams`. Change a reset there, never
  beside a call site: each bug of the class (review B1, B2, the arm-once
  bug) was a site that forgot a reset or made one twice.
  `test_slot_lifecycle.mojo` drives the transitions.
- **Socket errors are one `SysError`** (`c/socket_error.mojo`, review C1):
  the call and its errno, raised by every wrapper whatever the errno. Ask it
  (`would_block()`, `interrupted()`, `connection_aborted()`,
  `address_in_use()`, `errno`); do not bring back a type per errno, whose
  unlisted errnos returned -1 as a descriptor.
- **`c/fcntl.mojo` holds the program's one `fcntl` declaration** (with the
  Darwin arm64 variadic workaround) and imports nothing from the fork, so
  `socket`, `socketpair`, `pipe` and `fdpass` can mark what they create
  close-on-exec through it (SPEC G16). A second `external_call["fcntl"]` with
  another signature does not compile.
- **`poe check-fork-package` compiles the fork whole, and is in
  `test-all`.** `build-http` precompiles `src` only and Mojo checks method
  bodies lazily, so a body no app instantiates is never type-checked (ten
  errors collected that way). It throws its artifact away; apps still
  resolve `lightbug_http` from source.

## Commands

`mojo` lives in `.venv`, so every invocation needs `uv run` or an activated
venv.

```bash
uv run poe                  # list every task
uv run poe build-all        # each package -> .mojoc, in dependency order
uv run poe test-all         # builds first, then runs all tests
uv run poe check-fork-package  # the fork type-checks whole (lazy bodies too)
uv run poe test-shim        # the executor shim's ownership rules, sabotage-proven
uv run poe stress-asgi      # PRE-RELEASE: N streamed + WebSocket rounds, both loop modes
uv run poe stress-pool      # PRE-RELEASE: the pool's lost-wake reproducers, in the Linux container
uv run poe smoke-hello      # start hello, assert /health, stop
uv run poe smoke-counter    # assert an SSE broadcast reaches a live client
uv run poe smoke-shutdown   # SIGTERM drains; signalling the supervisor reaps workers
uv run poe smoke-blocking-threads  # a slow view must not stall what is behind it
uv run poe test-sqlite      # needs the runtime libsqlite3 on the system (opened, not linked)
uv run poe check-keepalive-barrier # the `_ = x` at an FFI site still pins the buffer
uv run poe sabotage-keepalive      # revert each of the probe's rules; all must be caught
uv run poe canary           # full suite against the Mojo nightly, then restore
uv run poe check-warnings compile.log            # the warning ratchet
uv run poe check-warnings compile.log --update   # after genuinely fixing some
uv run poe check-docs         # the docs gate the required check runs
uv run poe render-bench-docs  # after committing a new bench artifact
uv run poe render-spec        # after editing docs/SPEC.md's capability tables
uv run poe sabotage-spec      # revert each spec-sheet rule; all must be caught
uv run poe check-citations    # every RFC cited is current, by the committed snapshot
uv run poe check-citations --update   # refetch scripts/rfc_status.json (network)
python3 scripts/emit.py --selftest   # the CI measurement recorder

# One test file, without poe; the -I chain mirrors the package's dependencies.
uv run mojo run -I packages/m0-http -I packages/m0-core \
  packages/m0-http/test/test_router.mojo
# m0-sqlite too: libsqlite3 is opened at run time, so nothing links it.
uv run mojo run -I packages/m0-sqlite packages/m0-sqlite/test/test_sqlite.mojo
```

Tests are `std.testing`: `test_*` functions in a `test_*.mojo`, dispatched by
`TestSuite.discover_tests[__functions_in_module()]().run()` in `main()`.
Adding a test means adding a function — there is no registration list.

**The warning ratchet** pins warnings to a count (Mojo has no per-warning
suppression) over one log of `build-all` and `test-all` — both, since only
`test-all` compiles `test/` sources.
The 0 warnings the baseline records are a floor, not a target: the ratchet
fails on the first warning anyone adds. Before believing a warning cannot be
fixed, write the ten-line probe and run it under `uv run mojo run`
(docs/notes/ci-and-the-one-required-check.md).

**The doc-fact ratchet** does the same for prose: a number with a machine
source (this file's warning count, smoke coverage in `test.yml`, the bench
table in `WSGI_PERFORMANCE.md`) is checked against it. Benchmark runs leave
environment-stamped artifacts in `bench/results/`, and the table renders
from the newest. In `BENCHMARKS.md` prose a figure is a num span or sits in
an `observed: WHERE` block; a bare one fails `check-docs` naming its line.
Cut sentences freely.

**A `.mojoc` is locked to the exact compiler that produced it**: after any
toolchain change run `build-all`, or you get `Mojo precompiled file is
incompatible with the current version of the Mojo compiler`. The VS Code LSP
resolves cross-package imports through the same files, so stale artifacts
show as unresolved imports. If *every* prelude type (`String`, `List`, …)
reports "unable to locate module 'std'", the LSP is running a different Mojo
than `uv.lock` pins — an editor problem; check with the compiler before
believing it.

**`uv run poe canary` is the whole nightly probe** — swap, `build-all` +
`test-all`, then restore the pin and rebuild the `.mojoc` artifacts in an
`EXIT` trap. It exits 0 if the nightly is clean, 1 if it broke something, 2
if the environment could not be put back. Prefer it to driving the steps by
hand, which has a trap: **on a nightly, every task needs `--no-sync`** —
`poe nightly-try` swaps the venv's toolchain without touching `uv.lock`, and
a plain `uv run` silently re-syncs it to stable. Use
`uv run --no-sync poe <task>` until `poe nightly-restore`; the rule reaches
the `uv run` calls made inside tasks too, which is why each carries
`--no-sync` (`poe check-task-shells`).

## CI and the gates

The reasons are docs/notes/ci-and-the-one-required-check.md.

**Measurements are recorded, not echoed**: `scripts/emit.py` appends each
quantity a smoke already computes (RSS growth, a fast request's latency) to
`$M0_RESULTS` as one JSON line, and each job that sets it renders the file,
with a headroom column, and uploads it through
`.github/actions/record-measurements`. The recorder **never fails** — a
recording failure must never turn a passing gate red, nor be mistaken for
the thing measured — and is a **no-op without `$M0_RESULTS`**;
`check_ci_measurements_are_collected` refuses a job that collects without it,
a file never rendered, a missing upload, and the recorder's `--selftest` (a
CI step, beside `warning_ratchet.py --selftest` and `binfmt.py --selftest`)
dropping out. Adding a measurement is one line beside the `echo` that
already computes it. Do not add one that can fail, and do not make a gate
depend on a recorded value: the gate stays the
`[ "$x" -lt "$limit" ] || fail` beside it.

**`docs/SPEC.md` is a requirements traceability matrix**: one row per
capability, a permanent **id** (`A7`), four status words (`verified`,
`implemented`, `planned`, `out of scope`), and every row names its evidence
— a `test.yml` **step name** plus a cadence, a `test_x.mojo:test_fn` that
must exist, a `docs/ROADMAP.md` heading that must resolve, or a reason.
`scripts/spec_sheet.py` holds the rules (docs/notes/traceability.md):

- **Cadence is part of the evidence.** CI pins GIL-enabled 3.13, so every
  `--threads` phase skips and `smoke-threads` proves only the refusal (its
  step is named "the threaded mode's **guard**"). Free-threaded serving is
  `(weekly)` (`py-canary.yml`), the RFC snapshot's live comparison
  `(monthly)` (`citations.yml`), `stress-asgi` and `stress-pool`
  `(pre-release)`. A row citing a `test.yml` step must say `(every PR)`, and
  the checker rejects a cited step that carries an `if:`.
- **Both directions, over two closed sets.** Every `smoke-*` step in
  `test.yml` must be cited by some row, and every flag m0serve's `cli.mojo`
  or the host's `m0_host/flags.mojo` accepts (each file's
  `_takes_value`/`_is_bool` lists) must be named by some row. A gate that
  `exit 0`s on a missing import must have that module in
  `[dependency-groups] dev`, or it is green having tested nothing.
- **Refer to a row by its id, never its prose.** Ids are assigned once,
  never renumbered and never reused (a deleted row's id is retired). Reuse is
  the one rule not enforced — it would need a ledger of retired ids — so it
  is written down instead.
- **Gates declare what they cover** (F12): every `verified (every PR)` row is
  declared by its own gate — a `covers: A7` line in the cited test's
  docstring, or a `scripts/emit.py --covers A7` call in what the cited step
  runs — and the declaration must agree with the citation. Adding or
  re-pointing a row means adding the declaration too.
- **The rules are pure functions of text**, so `--sabotage` reverts one in
  memory and insists the checker catches it. Fourteen of the thirty-two
  sabotages mutate `pyproject.toml`, `test.yml`, `cli.mojo`, the host's
  `flags.mojo` or the test index rather than the sheet, so every source
  arrives as an argument. Do not "simplify" the checker into something that
  reads paths.

What the sheet cannot do, and says so: prove that a cited gate exercises the
capability its row claims.

**Sabotage harnesses share `scripts/sabotage_lib.py`**: exact-once anchors,
the restore in `finally`, and a sabotage that only breaks the build counted a
MISS, never a catch (review H1). After editing a line a harness anchors, run
that harness and re-point the anchor in the same change. A run compiles into a
Mojo cache of its own (`MODULAR_CACHE_DIR`, removed on the way out): the shared
cache never evicts, and a sabotaged tree is a program nobody builds again. A
new harness not on the lib enters `throwaway_mojo_cache()` around its arms, as
`mojo_suite`, `datastar_conformance` and `sabotage_views` do.

**The docs gate is `scripts/docs_gate.sh`**, run by both `poe check-docs` and
the `check-docs` job of `.github/workflows/docs.yml`, so what you run before
a push is what the required check runs. `check-docs` reads tracked files
only: `git add` before the final run. The workflow is named **`Docs`**, not
`Tests` (the automerge workflows key on that exact name), and has **no path
filter**, so it always reports. Do not add it to the automerge triggers —
`QUICKSTART.md` is a file CI *executes*.

**`test.yml` is named `Tests`**, and `dependabot-automerge.yml` and
`label-automerge.yml` trigger on that exact name, so renaming it silently
disables both. It ignores `*.md`, `docs/**` and `.claude/**`: a doc-only
change runs nothing, and never reaches the auto-merge workflows. Its jobs
open with `.github/actions/setup` and, where they collect, close with
`.github/actions/record-measurements`.

- **The smokes are THREE jobs and the unit tests two**, a cap rather than
  taste (the measurements are in `test.yml`'s comments on `smoke` and
  `unit-tests`): `smoke` carries the server, `smoke-app-layer` the Mojo
  host, its applications and the m0 wheel, `smoke-gateway` the WSGI and
  ASGI bridges, the mounts, the pool and `--realtime`; `unit-tests` runs
  `poe test-packages` and `unit-gates` `poe test-gates`, the halves of
  `poe test-all`. A new task goes in one half, never beside them
  (`check-docs` refuses it). Shards are separate JOBS, never one job with
  `if: matrix.shard`, since the sheet refuses a cited step with an `if:`;
  moving a step or task between them is free.
- **No job `needs:` another** — the serialization cost minutes and caught
  nothing `Docs` does not.
- **No smoke job compiles the example apps**: `build-apps` is a compile
  gate, run in `unit-gates` by `poe test-gates`.
- **Smokes on `scripts/smoke/lib.sh` take free ports** and write their logs
  to `$SMOKE_DIR` (a mktemp directory), kept only on failure. No task body
  but a `serve-*` one names a fixed port (`poe check-task-shells` refuses
  it), and a probe, sabotage or quickstart page that starts a server takes a
  free one; only the bench scripts keep fixed ports, and a bench runs alone.
- **`fail`'s `=== name ===` log output is a contract** with
  `scripts/host_sabotage.py` and `scripts/notes_login_sabotage.py`, which
  parse it: `lib.sh` owns it, and `poe check-task-shells --selftest` pins it.
- **poe task bodies must be POSIX sh as dash reads it**, and a `uv run`
  inside a task carries `--no-sync`; `poe check-task-shells` enforces both.

**`main` is protected by a ruleset**: pull request required (0 approvals),
no force push, no deletion, no bypass actor — so branch first, or the push is
rejected with `GH013`. It requires **exactly one status check,
`check-docs`**, the **job** id in `docs.yml` (a check run is named after its
job). Requiring `Tests` would be a mistake: a doc-only pull request produces
no `Tests` run. Renaming that job, giving it a matrix or adding a path
filter stops it reporting without failing anything;
`check_required_context_intact` in `scripts/check_docs.py` guards all three,
and deletion.

**`automerge` is a standing order**: a pull request carrying the label
merges itself as soon as `Tests` passes for its head commit. Applying it
needs write access, so a session can open work autonomously but cannot land
it: add the label when the work is meant to go in unattended; leave it off
and the pull request waits. Never reach for `gh pr merge --auto`: repository
auto-merge is disabled, so it errors, and it would not wait for `Tests`
anyway. The Dependabot gate resolves an author through the REST API
(`user.login`, `user.type`), never `gh pr list --json author`; its two
refusals that are never routine on a `dependabot/` branch (not Dependabot's,
or from a fork) exit 1, and `check_dependabot_gate` pins the source and the
exit codes.

## Imports resolve two ways

Inside a package's own `test/`, imports are `src.*` and compile the package's
source, so the package under test needs no rebuild. `test/__init__.mojo`
makes that safe: with it, a test file is part of its package and its own
`src` wins regardless of `-I` order; without it, the first `-I` root's `src`
wins — every package's `test_resolution.mojo` fails loudly if that erodes.
Keep the package under test first in `-I` lists anyway; it is the convention
the tasks follow.

Everywhere else — across packages, and from `apps/` — imports are `m0_*` and
resolve through the `.mojoc`, so a change to `m0-core` is invisible to
`m0-http` until `build-core` runs. A `.mojoc` does not bundle its
dependencies: a consumer passes every `-I` in the chain, and apps add
`-I apps/` for their sibling modules (`datastar_counter.page`).
`apps/hello/server.mojo` imports only `lightbug_http` yet needs
`-I packages/m0-core`: `event_loop.mojo` → `loop/state.mojo` → `m0_http.log`
→ `m0_core.json_escape`.

## The handler contract

`HTTPService` (`lightbug_http/service.mojo`) has fourteen methods, and **only
`func` is required**: the other thirteen carry default bodies, so a handler
declares just the hooks it uses.

- `func` answers; `before_request` runs on the LOOP before a request is
  offloaded to a pool thread, and what it answers never becomes a job
  (`WSGIHandler` answers static mounts and the health path this way);
  `after_response` follows.
- Streams: `sse_drain_slot`, `sse_is_streaming`, `sse_slot_disconnected`,
  and `sse_peer_frame` (frames from the cross-worker `BroadcastBus`). The
  `sse_*` names are historical: they serve WebSocket slots identically — a WS
  handler queues `encode_ws_frame(...)` bytes and returns them from
  `sse_drain_slot`.
- `tick` fires every `app_tick_ms` when configured, ON the event loop
  thread, so keep it quick.
- WebSockets: `ws_message` gets complete messages (fragments assembled,
  control frames answered by the loop); the loop calls `ws_message_take`,
  which forwards by default, and a False parks the message and stops reading
  until the handler names the slot in `take_ws_resumes` — parked is owed,
  never dropped. `ws_close_code` is the code a close carried, called as the
  loop parses it (SPEC L28; the executor's disconnect tag carries it on, 1006
  when none was parsed). `take_ws_closes` names the sockets the handler closed
  itself with a Close queued, which the loop then lingers on as after its own
  (SPEC I26).
- `direct_job` lets the inverted executor take a parked request on the
  loop's thread; the default declines.

Adding a method **with** a default is non-breaking; one **without** breaks
every implementer (every app under `apps/`, `ViewService`, `WSGIHandler`, the
README examples), so give a new hook a default unless there is a reason not
to. `test_service.mojo`'s `MinimalService` implements `func` alone: reverting
any default to `...` fails its compile.

**Every `Server` entry point runs the event loop**, which assigns
`req.slot_id`, drains the outbox and parses WebSocket frames:
`listen_and_serve` and `serve` are the `_nonblocking` pair with their
defaults; the blocking accept loop is gone. Slots index the registry
directly, so a stream's capacity (`DatastarStream(1024)`) must be at least
the server's max connections. A WebSocket upgrade is signalled on the wire:
the loop switches a slot to frame mode when the response is `101` +
`Upgrade: websocket` (what `websocket_upgrade` builds). On the
`sse_heartbeat_ms` cadence an SSE slot gets a `: heartbeat` comment and a WS
slot a protocol ping; a stream the application writes through the chunk
channel gets no comment (an event may span two chunks). Every stream's
socket has TCP keepalive on, which is what reaps a vanished client where
nothing is in flight (SPEC I32, `_keep_stream_alive`; D57's note).

## Writing an application in Mojo

The API is [docs/MOJO_HOST.md](docs/MOJO_HOST.md) and
[docs/MOJO_VIEWS.md](docs/MOJO_VIEWS.md), its rows SPEC section N; these are
the rules for changing the layer. `apps/fragment_notes` is the reference,
gated on the wire by `smoke-fragment-notes`
(docs/notes/a-fragment-that-names-itself.md). It was written ugly first and
refactored onto each piece under that green gate — do the same for any new
piece: an app that asks, a wire gate, then the lift.

- **The Mojo host** (`m0_host/host.mojo`, SPEC E21–E33;
  docs/notes/the-mojo-host.md):
  - `serve[H, P](AppConfig())` is a Mojo app's whole `main` below its own
    configuration checks. The host owns the process order — listen, pages
    and bus pre-fork (the bus at one worker too), fork, accept sharing,
    signals after the fork, `H.make` per worker, the producer's channels
    through a `Publisher`, the drain, the 5 s join with `_exit` for a
    straggler, `exit_worker` — so an app cannot spell it wrong (D27).
  - A producer (on worker 0 alone) numbers frames through
    `Publisher.next_id`, never a counter of its own, which restarts at 1
    when worker 0 is respawned (SPEC E25).
  - A `make` that raises, handler or producer, is refused with 78, never
    crash-looped, and one worker's refusal ends its siblings (D30).
  - Under `M0_BLOCKING_THREADS=N` (one GIL-free pool lane per worker; D31,
    SPEC E26) `PoolLane[H]` builds the handler again per thread, and the host
    serves only once every one is built. A stream opens on the loop
    (`on_loop=True`, `add_loop`, or `before_request`): one begun in `func` is
    refused 409 from a pool thread (D32). The pool's and the producer's
    joins count from the stop word the loop stamps as its drain begins, so
    the shutdown bounds overlap rather than stack.
  - `M0_THREADS=N` is N loops on threads of ONE process (D35, SPEC E27–E29,
    `smoke-host-threads`; docs/notes/loops-on-threads.md): `_serve_threaded`
    is the prefork order with the fork struck out, and `main` returns.
  - **Threads are the way to N for an m0 application** (D48;
    docs/notes/threads-first-for-m0-apps.md): MAX's parallel runtime does not
    survive a fork, so `M0_WORKERS>1` in a binary that links
    `libAsyncRTMojoBindings` is refused with 78 (`workers-vs-parallel-runtime`,
    the last entry of `host_checks`; SPEC E32, `smoke-parallel-runtime`).
    `m0_http.parallel_runtime_linked` reads that off the loaded images, for
    m0serve's Mojo mounts too (SPEC E33).
  - **`host_checks` is the ONE list** that `serve` (its first failure) and
    `--doctor` (all of them, same exit) read: add a refusal THERE, never
    beside it (`m0_host/flags.mojo`, SPEC E30–E31, D37, `smoke-host-doctor`;
    docs/notes/flags-and-a-doctor-for-the-host.md). `serve` lays the flags
    over the `AppConfig` it is handed — flag > env > default, strict, exit 2
    for what cannot be READ, 78 for what cannot be SERVED — idempotently, so
    an app that prints its own address may take `host_config()`.
    `AppConfig()` must never read argv itself: m0serve builds one. The
    doctor's `m0_http.doctor.Report` is the LAST line of stdout. The gate
    app, `apps/host_check`, runs the flag rows in both shapes
    (`M0_HOSTCHECK_ENV_CONFIG=1` is `serve(AppConfig())`).
  - `apps/blobs`, `sim_loop`, `datastar_counter`, `datastar_todo`,
    `fragment_notes` and `ramp` run on the host, as do the gate apps
    `host_check` and `host_parallel` (entry file `probe.mojo`, which
    `build-apps` skips). `apps/ramp` is ONE views module built into m0serve
    as a mount and into a host binary, compared byte for byte and by
    placement by `smoke-ramp` (SPEC N20; docs/notes/the-ramp-test.md). An app
    broadcasting a whole rendered state from several workers holds a lock
    from the change until the frame is numbered and published, or a stale
    render can take the newer id (`datastar_todo`, SPEC N17).
  - Run `poe sabotage-host` after touching `host.mojo`: its anchors are
    exact source lines. The whole run wants `uv run --group max` for its
    `parallel` arm; on macOS, where a build beside `max-core` links the
    runtime into every binary, run `--skip parallel` in the default venv,
    then `--only parallel` under `--group max`.
- **`Views[S]`** (`src/views.mojo`; docs/notes/views-the-mojo-way.md): views
  are `thin` function pointers, and a capturing closure is not `thin`, so
  there is **no decorator or middleware story** — guards are early returns
  of `Optional[HTTPResponse]`. `params` stays positional (origins are not
  spellable as struct parameters on the pinned toolchain). `add_read` hands
  the state borrowed and `add_write` `mut`, and `poe sabotage-views` insists
  the counter-examples are refused. An `add_loop` view is answered in
  `before_request`, and from `dispatch` for a handler that forgot the hook.
  The routers are private; an app reads `Views.allow_header`.
- **`Fragment[V]` and `Html`** (`src/html.mojo`;
  docs/notes/one-renderer-two-transports.md): helpers, not a safety type —
  `String` stays the currency. `attr` owns the quotes and escapes, `text`
  escapes, `raw` says so by name, `finish` consumes the builder, and the
  constructor refuses an id `#id` cannot select.
  - **The vocabulary is the type parameter**: `Htmx.swap` and
    `Datastar.swap` are the only places either spelling lives, and an app
    names its vocabulary once (`comptime Frag = Fragment[Htmx]`). `Htmx` is
    gated against htmx **4.0.0** (docs/notes/the-layer-moves-to-htmx-4.md),
    which sends a DELETE's fields in the query and swaps every 4xx: a CSRF
    token on a DELETE is a header (`header=csrf_header(token)`, SPEC N44),
    and an error a person may see is answered as a fragment. Both
    vocabularies pick the event from the OPEN element by htmx's
    default-trigger rule; a Datastar field sends the signal store, so bind it.
    `Datastar.swap` refuses a URL carrying `'`, `\`, CR or LF (`url_for`
    encodes them; an app building a query from request data must too), and
    a verb the vocabulary does not name is refused.
  - **`Vocabulary` is open to an application's own** (D34, SPEC N21;
    docs/notes/a-vocabulary-an-application-defines.md). Nothing behind a
    `.mojoc` is private, so a conformance is written WITHOUT AN UNDERSCORE
    (`h.open_kind()`, `verbs()`). The verb check is the LAYER's (`_swap[V]`,
    which every call site goes through): do not put it back in a
    conformance, and do not call `V.swap` directly. `poe
    check-app-vocabulary` (in `test-all`) lints an outside vocabulary's
    output with `hxlint`; `scripts/hxlint.py` and `hx_vocab.py` are
    hx-flask's, vendored byte for byte under a hash guard in `check-docs` —
    never edit them here.
  - **`push=True` moves the address bar** (SPEC N37, D46;
    docs/notes/a-swap-that-moves-the-address-bar.md):
    `Vocabulary.push_url`'s default REFUSES, the layer refuses it for any
    verb but `get`, and `Datastar` raises — a refusal, never a no-op. One
    swap mode, on purpose: an app that appends puts its mode beside
    `page_or_fragment`, where both libraries take a header.
  - `apps/datastar_todo` is the Datastar reference: its list is one line,
    verbatim as the `elements` of every broadcast frame
    (`m0-datastar/test/test_fragment_frame.mojo`, SPEC N7).
  - **Two tiers over one buffer**: the builder (allocates once) and the
    expression tier (`el`, `void`, `attr`, `flag`, `text`, `Fragment.el`;
    every `el` allocates). `fragment_notes` keeps its list in the tier and
    its detail in the builder on purpose (SPEC N10; byte-identical in
    `test_html.mojo`). The tag goes to `Fragment.el` once (the vocabulary
    reads it), so there is no swap-attributes-as-a-string function.
    `Html.raw_attrs` refuses a non-empty value that does not open with a
    space, so `el("p", "none")` raises instead of rendering `<pnone>`.
- **`page_or_fragment`** (`src/fragment.mojo`, SPEC N22) decides from five
  headers, and **`HX-Request-Type` decides when present**
  (docs/notes/the-layer-moves-to-htmx-4.md). Every answer names all five in
  `Vary` through `reply.vary`, which APPENDS and keeps `*` alone. The shell
  is the app's own `PageShell` (docs/notes/the-page-shell-becomes-a-trait.md).
- **`url_for(PATTERN, params...)`** (`src/router.mojo`): the pattern is a
  `comptime` constant given to both `add` and `url_for`, so a misspelled
  route is a compile error; `thin` values are not `==`-comparable, so
  routes-as-function-values is closed. `Router.pattern_of` and
  `test_every_registered_route_reverses_and_matches` keep the two directions
  honest. A mounted table reverses through `Mount` (a request under
  `--mount /native=mojo` arrives with its path whole; `smoke-mojo-mount`
  follows a rendered link, SPEC N9), and a `PoolHandler` learns the prefix
  from `PoolContext.prefix`. **An application supplies its own mount as a
  module, never a copy of the entry file**: `m0serve.mojo` imports
  `MojoMount` from `m0serve_mount`, the demo lives in
  `packages/m0-wsgi/mount/`, and `M0SERVE_MOUNT_DIR` on `build-serve`
  REPLACES that directory on the include path. Never add a second mount root
  beside it: the first `-I` root wins silently (SPEC N14, `smoke-mount-seam`;
  docs/notes/a-mount-from-somewhere-else.md).
- **Sessions and the login** (`src/session.mojo`, `src/login.mojo`; SPEC
  N43, D53; docs/notes/a-login-on-the-notes-app.md,
  docs/notes/a-login-in-the-layer.md). A session is a signed cookie on the
  envelope and key ring grants use (`SignedToken`, `find_key`): a session
  key and a grant key are the same thing. It is refused in the order
  malformed / unknown key / bad signature / expired — the signature BEFORE
  the expiry. `session_cookie_line` builds the `Set-Cookie` for
  `ResponseCookieJar.add_raw`, never the parsed path, which drops four
  attributes. No store: a session ends at its expiry or when its key leaves
  the ring (D24), and the app supplies the identity (D25).
  `Login.from_env(PREFIX, cookie)` refuses an incomplete configuration by
  name — `PREFIX_KEY`, `PREFIX_PASSWORD` and `PREFIX_SECURE` are required,
  the last `1` or `0` and nothing else (the server cannot see the scheme a
  proxy terminated). `sign_in` is the credential check and the session in
  ONE call; `csrf_refusal` reads the header before the field, never the
  query, and is closed on a refused session. `m0 new --template auth` is
  written on it (N45); `smoke-fragment-notes` (against sessions a CPython
  issuer signed) and `sabotage-notes-login` (whose CSRF arms revert
  `login.mojo` itself) hold it.
- **`form(req)`** (`src/form.mojo`) is `Optional`: None unless the content
  type is the form's, compared whole, so "not a form" cannot be read as an
  empty one. Deliberately NOT factored out of `URI.parse`, which fills a
  last-wins `Dict` by contract; `test_form.mojo`'s encoding table is the
  anti-drift device, and stays a test rather than a shared loop.
- **A resource over a table** (SPEC N46–N48, O25, D60–D62;
  docs/notes/a-resource-over-a-table.md). `Views.resource` is a
  registration: seven optional slots typed by the table's read/write rule,
  `update` on PUT and on the POST a plain form sends, no guard (D3), and
  `new` registered before `show` because the router takes the first match.
  There is no `Resource` type, because `m0-http` and `m0-sqlite` are
  siblings: the clock crosses as a number. `Connection.data_version()` is
  asked on a READ-ONLY connection beside the writer, on the connection
  that renders and BEFORE the rendering; do not add a commit hook (D60).
  `Cached` keeps a rendering against the clock and `conditional` hashes
  the response's own body, never the clock, which is the database's and
  would move every table's tag. A view that fills a `Cached` writes, so it
  is `add_write`, not `resource`'s `list` slot. `apps/table_notes` is the
  reference, gated by `smoke-table-notes` at one loop and at two.
- **Stamps** (`m0_sqlite`'s `watch`; SPEC O26–O27, N49, D63–D64;
  docs/notes/a-database-that-remembers-what-changed.md). Triggers give
  every row a watched table writes one entry with the stamp of its last
  change, so "what changed since N" is a query and whoever asks keeps one
  number. A stamp can be got past and the clock cannot: `Cached` stays on
  `data_version`. A delta is sent whole, never cut at a stamp. The stream
  over it is `m0_http.Feed` (`src/feed.mojo`, N51): ids are the
  application's, no journal, fan-out per subscriber from its own number,
  `behind(head)` names clients above the head too; `ViewState` carries
  the stream hooks with defaults. `apps/table_notes`' list is live on it
  (N50). Read [packages/m0-sqlite/AGENTS.md](packages/m0-sqlite/AGENTS.md)
  first.
- **A table that streams** (`apps/blobs`, SPEC N16;
  docs/notes/a-world-the-page-cannot-hold.md): `ViewService` forwards only
  `func` and `before_request`, so an app that also owns the SSE hooks writes
  its own handler over `Views.dispatch`, its `DatastarStream` in the state. A
  producer publishing whole states opens its stream with
  `DatastarStream(send_latest=True)`, counts what `publish_to_channels`
  returns (a frame over `BUS_MAX_FRAME` is refused, not sent), and reaches
  the loop's counters through the pre-fork `SharedAtomics` page, never
  `malloc`'d memory. **Every Mojo app's image is `deploy/mojo/Dockerfile`**
  (SPEC M26–M27; docs/notes/the-demo-in-its-own-image.md): `APP` names the
  directory, the binary is `/app/server`, and the last layer measures the
  image into `/app/about.json`, failing the build if an interpreter is in it
  (read through `M0_IMAGE_FACTS`; `smoke-blobs-image` checks it from
  outside). `.dockerignore` is an allowlist: a new app's directory is let in
  by name. The blobs deploy serves ONE loop (D36). An app's own tests live in
  `apps/<app>/test/` (no `__init__.mojo`) and run in `poe test-apps`.

What is not built — templates (D2), middleware (D3), named params (D4),
routes as function values (D5), multipart (D16), `HX-*` header setters
(D17), streaming from a Mojo mount other than as an `M0-Hold` (D22, which
superseded D18), a session store (D24), a password KDF (D25) — is each a row
of `docs/DECISIONS.md` with its note and the condition that would retire it.
Section N has no `planned` rows left, and the layer's soak is recorded. Read the ledger and `poe milestones` before
proposing a piece; the process is one pull request per round carrying the
note, the rows, the ledger update and the milestone line, reviewed from a
separate session before it merges.

## Runtime constraints

Properties of the design, not defects to fix in passing. Each names its note.

- **Fan-out is per process unless the app joins the `BroadcastBus`**
  (docs/notes/the-bus-and-its-doors.md). Under `M0_WORKERS>1` a broadcast
  reaches other workers' subscribers only when everything shared is created
  *before* the fork (listener, `BroadcastBus`, `SharedAtomics` id slot) and
  each worker wires `enable_bus` + `bus_read_fd` + `sse_peer_frame` →
  `deliver_peer` (the Mojo host passes `bus_read_fd` itself); partial wiring
  fails quietly. `apps/datastar_counter` is the reference; `WSHub`
  (`src/ws.mojo`, `apps/ws_chat`) rides the same bus. Cross-worker ordering
  is best-effort: the redelivery filter keeps the newer of two racing ids.
- **ASGI apps get cross-worker pub/sub as `scope["state"]["m0"]`**:
  `publish(channel, payload)` is m0pub's bus protocol, and
  `subscribe(channel)` an async iterator in executor mode only, fed through
  the loop's second bus fd, `peer_bus_fd`. The bus, `SharedAtomics` and the
  env exports are created unconditionally pre-fork, and a single worker's own
  subscribers ride its own channel: there is deliberately no separate
  local-delivery path.
- **`--pg-listen URL` is the bus's second door**: one `LISTEN` on worker 0
  turns `pg_notify` into a bus frame built by `format_sse_event`, the payload
  three JSON string fields (`channel`, `event`, `data`); `m0pub.notify_sql`
  builds the statement for a caller with a cursor. Refused without
  `--realtime`, and on macOS wherever a worker is FORKED (what `cli.mojo`
  calls `supervised`: `--workers N`, and `--reload` even at one), both before
  the bind and the fork; `--spawn-workers` is the escape. A host with no
  libpq exits 78. Four rules: worker 0 only; `skip_worker` is -1; a malformed
  payload (an `event` or `data` that is not a JSON string) is refused and
  counted, never guessed at; a reset re-`LISTEN`s, and the listener drains
  once after connecting and after every reset. Its thread never attaches to
  the interpreter (SPEC I22, `smoke-pg-notify`).
- **A channel name opening with `\x01` is RESERVED, and every publish
  boundary refuses one**: the namespace addresses a connection SLOT on the
  loop. `channel_is_reserved` in `broadcast.mojo` guards
  `publish_to_channels`, and the shim's `_M0Broadcast.publish` and both
  copies of `m0pub.publish_frame` spell the same rule; internal senders
  build `encode_bus_frame` datagrams directly.
- **`/ws/message` is the server's path, not the application's**: under
  `--realtime` an inbound WebSocket frame reaches the app as a synthetic
  `POST` there, carrying `M0-Channel`/`M0-Slot`/`M0-Opcode`, and the view
  must be CSRF-exempt. A wire request for that path is answered 404 in
  `serve_local`, so only the synthetic one reaches the app.
- **Server-initiated work goes through the `tick` hook** (`M0_APP_TICK_MS`,
  0 = off), on the loop thread, where its duty cycle is what costs
  (docs/notes/periodic-work-off-the-loop.md); handlers with slower cadences
  sub-schedule off `now_ms` (the counter's uptime clock). Schedule from the
  tick, do not work in it: periodic work with a real budget goes on a thread
  of its own, publishing through the `BroadcastBus` as `--pg-listen`'s
  listener does. Under `M0_WORKERS>1` every worker ticks; an app that must
  act once per interval designates an owner (the counter uses worker 0) and
  lets the bus carry the result. Loop timers (tick, SSE heartbeat) are
  one-shot on both backends, so the firing handler re-arms FIRST — on epoll,
  skipping it is a level-triggered event storm.
- **Under `--workers N` the worker that wins an accept gives the connection
  away** (`lightbug_http/accept_share.mojo`, SPEC E16;
  docs/notes/accept-sharing.md, which holds the shared page's layout and
  `pick`'s rules): the socket goes to the least-loaded sibling
  (`active + pending`) over its `AF_UNIX` channel with `SCM_RIGHTS`
  (`c/fdpass.mojo`) and is admitted by the accept path's own tail
  (`_admit_connection`). A send that fails for any reason keeps the
  connection where it is, never drops it; `pending` is raised by the sender
  before it sends and retired by the receiver at the END of the pass that
  admitted it; `leave` wins over the per-pass stores. One worker pays
  nothing (`active()` is false). `M0_ACCEPT_SHARE=0` is the A/B knob;
  `smoke-accept-spread` gates both CI legs, its knob-off negative arm on
  macOS only. On macOS each channel stays in flight (`_anchor_channels`) or
  XNU's collector flushes its hand-offs, and `recv_fd` omits `MSG_DONTWAIT`,
  which fails EAGAIN while the collector's scan holds the buffer lock.
- **A pass admits one batch of new connections, AFTER the events of those
  it holds** (`ACCEPT_BATCH`, 16; SPEC C8; docs/notes/the-accept-batch.md).
  Both listeners are edge-triggered, so what a batch leaves is OWED
  (`LoopState.accept_owed`, and `handoffs_owed` for the accept-share channel)
  and taken by the next pass even with no event; the wait does not block
  while anything is owed (`_wait_for_events`); and the flags are cleared
  where the listener closes. Owed only when the BATCH stopped the drain —
  never for an error accepting harder will not cure (EMFILE). `run_pass_once`
  takes owed batches inside its callback, up to `max_connections` accepts.
  `M0_ACCEPT_BATCH=0` is the A/B knob; `smoke-accept-batch` counts the batch
  and the knob's drain on both legs.
- **Graceful shutdown is opt-in, and armed after the fork**
  (docs/notes/workers-signals-and-the-fork.md): `install_shutdown_signals()`
  returns the fd to pass as `shutdown_read_fd`, and its handler writes one
  byte and nothing else. Each worker arms itself once `fork_all()` returns;
  the supervisor arms its own handler (`kill` each child) inside `fork_all`.
  **A forked worker must end with `exit_worker()`, never by returning from
  `main`** (the runtime's teardown dies in libdispatch after a fork). **Once
  told to stop, the supervisor respawns nothing** (SPEC D10): a worker that
  then fails its drain is not replaced, and the supervisor exits 1 once the
  rest are gone.
- **After `fork()` without `exec`, platform runtimes are off limits —
  including from application code** (docs/notes/workers-signals-and-the-fork.md).
  On macOS `urlopen`'s proxy lookup enters CoreFoundation, which kills a
  forked worker: use `http.client.HTTPConnection` (`apps/wsgi_bare`'s
  `/reentrant`, pinned by `poe smoke-wsgi`). Apple's libsqlite3 can fault in
  a forked child (docs/notes/a-signpost-in-a-forked-child.md), so a worker
  that opens an m0-sqlite connection after the fork on macOS wants
  `--spawn-workers` or `OS_ACTIVITY_MODE=disable`, which `test-sqlite` sets.
  A rerun is not the answer: the crash is rare, real and not ours.
- **SIGPIPE is ignored where every server starts** (SPEC A25):
  `ListenConfig.listen` calls `ignore_sigpipe` before any fork, thread or
  write, and `run_event_loop` does again, so a write to a peer that reset is
  an error the loop handles, never a death by signal.
- **Mojo has no global `var`, but it has `pop.global_alloc`**, which
  `src/global_slot.mojo` uses for what C spells `static` (a POSIX handler
  gets no user-data pointer). `@no_inline` on the accessors is load-bearing
  (the op is `Pure`, so each inlined copy makes its own global), the slots
  are private to m0-http so writer and reader share one emission, and fork
  copies them — cross-process state is `SharedAtomics`. m0-sqlite keeps two
  words the same way, for a scalar function's callbacks and the pinned
  library ([packages/m0-sqlite/AGENTS.md](packages/m0-sqlite/AGENTS.md)), and
  m0-postgres one, for its pinned libraries. If the op stops
  working nothing is installed and the default signal behaviour stands;
  `shutdown_signals_active()` reports which, and `test_lifecycle.mojo`
  asserts it.
- **A pointer handed to C does not keep its buffer alive; the bare `_ = x`
  after the call does** (docs/notes/workers-signals-and-the-fork.md): without
  it the free is emitted BEFORE the call that reads through the pointer, a
  use-after-free with no symptom at the call site. Only an OWNING value is
  at risk. `poe check-keepalive-barrier` (in `test-all`) compares
  `scripts/keepalive_probe.mojo`'s pinned and bare forms in LLVM IR, the bare
  arm being the load-bearing half, and `poe sabotage-keepalive` reverts each
  of the probe's rules; a failure is a finding about the toolchain, not
  noise. The `_ = x^` transfer form is NOT this idiom.
- **A request-derived `String` may hold bytes that are not UTF-8, and is
  never sliced with `[byte=a:b]`**, which asserts a codepoint boundary — a
  trap, not an error (docs/notes/the-loop-on-the-wire.md). The target, every
  header value and the body become `String`s via `unsafe_from_utf8`; slice
  one as `String(unsafe_from_utf8=s.as_bytes()[a:b])`. SPEC G14 is the row,
  one test per site declares it, and `smoke-hello` and `smoke-notes` send the
  bytes over a socket; adding a slice of a request string means adding it
  there. Duplicating a function duplicates its traps: fix both copies
  (m0-datastar's `split_data_lines` is one), or import one.
- **A response header carrying CR, LF or NUL is dropped, not transmitted**:
  the fork's head writers refuse it for every response — `write_latin1_to`
  drops the header, the cookie jar the `Set-Cookie` line, and
  `encode`/`encode_into` empty an injected reason phrase (SPEC G1, G2) — and
  m0-wsgi refuses it too as it reads an application's head. Dropping rather
  than raising: the application has already run and its body is real.
- **An application's `Set-Cookie` goes to the wire verbatim**:
  `ResponseCookieJar.add_raw` transmits it unparsed, subject only to the
  refusal above. Do not "normalise" that path: round-tripping it through
  `Cookie.from_set_header` dropped attributes from every Django session and
  CSRF cookie (docs/notes/the-loop-on-the-wire.md).
- **The two backends do not trigger alike, and every read path must satisfy
  the stricter one** (docs/notes/the-loop-on-the-wire.md): kqueue's
  `add_read` is level triggered (`EV_ADD`, no `EV_CLEAR`); epoll registers
  `EPOLLIN | EPOLLET | EPOLLRDHUP`, where bytes already buffered when the edge
  fired produce no further edge; `add_read_listen` is edge triggered on both;
  and a write registration replaces the read one on both (kqueue since
  review R4), which is what `slot_read_armed` tracks. macOS passes without a
  re-arm Linux requires (`poe smoke-large-request`).
- **`EV_EOF` on a read event means "no more request bytes", not
  "connection over"**: after a half-close the loop finishes the buffered
  request and turns off keep-alive, an SSE stream closes, a WebSocket reads
  what its peer left and then closes, and an INCOMPLETE request closes at
  once. A real EOF travels as `recv_eof`/`peer_eof`, never as a zero byte
  count, the header path's EAGAIN-with-buffered-data sentinel.
  `poe smoke-half-close` pins the answer and the prompt release.
- **Pipelined requests are answered from the buffer, not from events** (RFC
  9112 §9.3): `request_end` stamps where the answered request ends,
  `prepare_for_new_request(keep_pipelined=True)` is passed ONLY by the
  keep-alive reset (so one client's tail never reaches another connection),
  and `_drain_pipelined` answers what the buffer holds after every
  response, iteratively, and READS NOTHING: a pass answers one read's
  worth, a read that fills its buffer marks its edge spent
  (`_spend_read_edge`), and the drain's last step registers for the rest
  (LF72). `poe smoke-pipelining` pins it.
- **A WebSocket this side closes LINGERS for the peer's Close reply** (RFC
  6455 §5.5.1): `WSState.closing` marks the wait and a `WS_CLOSE_LINGER_NS`
  deadline in `slot_idle_deadline` bounds it; with idle timeouts off the
  socket closes at once rather than leak a slot, and the read path drops the
  parser's close echo while `closing`. **The deadline is armed ONCE**, by
  `_arm_ws_linger`, which writes it only while it is 0 (`_stream_idle` zeroes
  it when the 101 lands, and leaves a `closing` socket's alone). **Nothing
  follows this side's Close** (RFC 6455 §1.4): the heartbeat skips a
  `closing` slot. Gates: `ws_probe.py`'s close-order phase, whose concurrency
  is load-bearing (L15), its quiet-linger phase (L29), and
  `poe smoke-idle-timeout`, which asserts both bounds (L16).
- **Chunked request bodies**: a body ends where RFC 9112 says, because the
  request decoder is built with `consume_trailer = True`; it is bounded
  twice, decoded size by `max_request_body_size` and raw bytes by twice that,
  read from the decoder's `_total_read`; and ONE decoder per connection
  (`ConnectionProvision.chunk_decoder`) is fed only the new bytes, the buffer
  `[headers][decoded][raw tail]` with `pending_bytes` marking the next batch.
  Do not rebuild it per read event: that was O(N^2) on the loop thread and
  reset `_total_overhead`, disarming the abuse-ratio guard.
- **A body the server accepts must fit its receive buffer**: the
  per-connection cap is `ServerConfig.recv_buffer_limit()` — headers plus
  body allowance, floored by `recv_buffer_max` — never the bare field. An
  incomplete head is compared against it, alone (LF72); the body path does
  not compare (review record LF70: that buffer also holds the next
  request), and holds a body to its own sizes.

## Configuration

Env vars, all `M0_`-prefixed: `M0_HOST`, `M0_PORT`, `M0_BASE_URL`,
`M0_WORKERS`, `M0_THREADS` (mutually exclusive with `M0_WORKERS>1`;
free-threaded CPython only), `M0_BLOCKING_THREADS` (handler threads per
loop; composes with either and with `--realtime`),
`M0_ACCESS_LOG`, `M0_SSE_HEARTBEAT_MS`, `M0_STREAM_KEEPALIVE_S` (keepalive
on a stream's socket: idle seconds and probe interval, default 15; `0`
off), `M0_APP_TICK_MS`, `M0_QOS` (macOS:
keeps the loop and its workers on performance cores; accepted and ignored
elsewhere), `M0_MAX_KEEPALIVE_REQUESTS` (the keep-alive cap; 0 = never close
for count; docs/notes/pool-tail.md), `M0_GRANT_KEY`, `M0_GRANT_KEY_PREV` and
`M0_GRANT_COOKIE` (the hold mount's key, its previous key during a rotation,
and the cookie a grant binds to; `sessionid`), `M0_SPAWN_WORKERS`,
`M0_PG_LISTEN`, `M0_MAX_BODY`, `M0_BODY_TIMEOUT` and `M0_REPLAY_FRAMES` (the env forms of those
m0serve flags, read by m0serve's `from_env`, which reports every `M0_*`
value it cannot read rather than ignoring it silently), `M0_INVERTED` (`1`
runs the loop inside the executor's asyncio loop, where the topology
allows), and `M0_LIBPQ` and `M0_LIBSQLITE3` (the library to `dlopen`).

A/B knobs, not flags, each a gate's negative arm or a measurement's:
`M0_ACCEPT_SHARE` (`0` off), `M0_ACCEPT_BATCH` (default 16; `0` takes the
whole backlog), `M0_POOL_TURN` (`0` drops the pool's GIL hand-off barrier),
`M0_POOL_TURN_KEEP` (`0` drops the GIL between every job of a thread's
slice, the shape that starved a waiter), `M0_LOOP_ATTACHED` (`1` keeps
m0serve's loop thread attached, the pre-0.18 shape), `M0_POOL_RING` (`0`
puts the `--blocking-threads` handoff back on datagrams), `M0_POOL_ELASTIC`
(`0` restores the eager pool wakes), `M0_POOL_WAKE_AGE_US` (how long a job
waits at a ring's head before the loop wakes a parked sibling; default 200)
and `M0_POOL_PARALLEL` (`1`/`0` forces the free-threaded wake rule; unset,
the interpreter decides). For measurement only: `M0_POOL_SPIN_US` (the idle
spin before a pool thread parks) and `M0_POOL_DEBUG` (per-thread histograms
and the loop's wait counters at shutdown). What the server exports to its
own workers (`M0_WORKER_SPAWNED`, `M0_WORKER_INDEX`, `M0_LISTEN_FD`,
`M0_BUS_*_FDS`, `M0_ACCEPT_*_FDS`, `M0_SHARED_ID_*`, `M0_CORE_LIB`) is
plumbing, not configuration.

`m0serve` layers flags on top (flag > env > default) and is strict where the
env loader is lenient. `--doctor` prints the resolved configuration as JSON
and starts nothing, and **exits with the code `m0serve` would exit with for
the same arguments**, held by `smoke-doctor`, which runs both and compares.
Both read one ordered list (`m0_wsgi.checks`: the flags before the bind, the
interpreter's under `--threads`, the application after the import), so add a
refusal THERE, never beside it.

## Mojo 1.1 patterns

This project targets **Mojo 1.1** (pinned in `uv.lock`; moved from 1.0.0 on
2026-09-18, [docs/notes/the-pin-moves-to-1-1-0.md](docs/notes/the-pin-moves-to-1-1-0.md)),
which cost `Atomic[Int64]` for `Atomic[DType.int64]`, `_CTimeSpec.tv_nsec`
for `tv_subsec`, `Hasher.update` taking a `Span[UInt8]`, `Array` for
`InlineArray`, and `ptr`/`as_c_string_span` for the deprecated
`unsafe_ptr`/`as_c_string_slice`.

1. **`comptime` constants** — replaces deprecated `alias` for compile-time values
2. **No `@value` decorator** — removed in 26.3; structs auto-derive copy/move
3. **Explicit `__init__`** — memberwise init must be written explicitly
4. **`from std.` imports** — implicit stdlib imports deprecated
5. **`String.as_bytes()`** — `s[i]` indexing removed; use `s.as_bytes()[i]` or `s[byte=i]`
6. **`Writable` over `Stringable`** — always add `write_to` when migrating
7. **`Variant` for tagged unions** — `from std.utils.variant import Variant`
8. **`Optional[T]` and `List[T]` take Movable-only elements** — a struct
   that is not `Copyable` can be appended, popped and wrapped (verified on
   1.0.0); do not add `Copyable` to a handle type just to store it
9. **Parallel arrays (SoA)** — `SSERegistry` keeps parallel `List` fields
   for cheap per-field scans, not because `List[Struct]` is refused (the
   `ImplicitlyCopyable` constraint that first motivated them is
   gone); the fork's private `OwningList` was retired on 2026-09-05 at
   measured parity (NOTICE) — do not reintroduce a private list
10. **A `mut` argument is not a reference**: from `-O1` one of ≤256 B, `self`
   included, is copied in and stored back — pass a struct that is written by
   address as its address (docs/notes/mut-arguments-and-raw-addresses.md)

## Design principles

- **Functional core / imperative shell** — pure logic in Mojo, I/O at the edges.
- **Content negotiation stays format-agnostic.** `AcceptResult` knows the four
  standard media types; everything else is a caller-supplied vendor type. Do not
  add a vendor media type to `content_negotiation.mojo` — that is exactly the
  coupling this repo was split out to remove.
- **`*/*` resolves to JSON only**, and vendor types must be named exactly. A
  plain `curl` sends `Accept: */*`; it should not receive an opaque binary.

## Mojo reference (fetch on demand)

- Changelog: https://docs.modular.com/mojo/changelog
- Ownership: https://docs.modular.com/mojo/manual/values/ownership
- Structs: https://docs.modular.com/mojo/manual/structs/
- Traits: https://docs.modular.com/mojo/manual/traits
- Collections: https://docs.modular.com/mojo/std/collections/
