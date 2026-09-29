# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Where the project stands

**Run `uv run poe milestones` before planning work.** It computes what
remains between here and 1.0 from `docs/SPEC.md`, ROADMAP's Known issues and
the soak record — so it cannot disagree with them, and it does not depend on
what the last session happened to remember. CI prints it on every pull
request.

`docs/SPEC.md` is the capability matrix (one row per capability, each naming
the gate that proves it) and is the right place to look for "is X covered?".
[docs/README.md](docs/README.md) says what every other page is for.

Three milestone definitions, all derived from row STATUS rather than a
per-row annotation:

- **beta** — no row is `implemented`, the sheet's word for "in the tree, no
  gate dedicated to it". Nothing ships ungated.
- **1.0** — beta, plus every `planned` row outside section N resolved
  (built, or moved to `out of scope` with a reason), plus a current
  real-application soak, plus Known issues each declaring what would
  retire them. Shipped; the report says whether its conditions still hold.
- **the application layer** — no section-N row `implemented`, every
  section-N `planned` row resolved, plus a soak on the layer: an
  application outside `apps/` running on `Views`/`Fragment`, recorded in
  `docs/REAL_APP_VALIDATION.md`'s application-layer section. NOT MET until
  one exists, on purpose. Its standing decisions are `docs/DECISIONS.md`
  (D1–D46, permanent ids, each with a retiring condition), which
  `check-docs` keeps resolvable.

**Gating an ungated row keeps finding real defects** — so far an unbounded
WebSocket close linger (a slot held for the life of the process), close
codes echoed rather than validated, inbound WebSocket messages dropped 2932
of 3000, and `Expect: 100-continue` failing on both case and HTTP/1.0, with
nothing gated yet that turned out to be already correct. So the remaining
`implemented` rows are the highest-yield work available, not merely
bookkeeping.

## What this is

`mojo-http` — an HTTP/1.1 server and web framework for Mojo. Extracted from a
private monorepo; see [PROVENANCE.md](PROVENANCE.md).

```
m0-core     (zero deps)   hashing, JSON escape, JSON parse
└── m0-http               router, negotiation, ETag, cache, SSE, auth, CORS, health
    └── lightbug_http     the forked HTTP server (lives inside m0-http)
m0-datastar               Datastar wire format (zero deps) + server glue (m0-http)
m0-wsgi                   WSGI/ASGI gateway — embeds CPython, layers on m0-http
m0-sqlite   (zero deps)   SQLite bindings — a SIBLING, never nested
m0-postgres (zero deps)   PostgreSQL bindings over libpq — a SIBLING too
```

**Zero upward imports.** `m0-core` depends on nothing. `m0-http` reaches into
it from nine files: `wyhash64` and `format_hash64` in `etag.mojo`,
`escape_json_string` in `health.mojo`, `reply.mojo`, `doctor.mojo` and
`html.mojo`, `escape_json_string_into` in `log.mojo`, `escape_html_into` in
`html.mojo`, and the cryptography — `HmacSha256`, `sha256`, `hex_digest`,
`constant_time_equal` — in `grant.mojo`, `session.mojo` and `login.mojo`.
That list is an inventory, not the constraint: the constraint is the
direction (m0-http importing m0-core is downward) and that no libpython
reaches the link line. `m0-datastar` splits deliberately: `consts.mojo` and
`sse.mojo` import nothing outside themselves so the wire format is usable
without the framework — do not add an `m0_http` import to either — while
`stream.mojo` and `signals.mojo` are the server glue and may. Where
Datastar facts come from (the bundle and the SDK's vendored spec and cases,
never memory), the wire rules and how to move the pin are
`packages/m0-datastar/AGENTS.md`.

`m0-wsgi` is the **only** package that embeds CPython. Keep it that way: a
Python import in `m0-http` or `m0-core` would put libpython on the link line of
every build in the repo. Everything else about the gateway — the bridge's
raw-C-API interop, mounts and their per-mount lanes, the zero-config pool,
and the execution modes (prefork, threaded, the asyncio executor, the
handler pool) with the ordering rules each depends on — is
[packages/m0-wsgi/AGENTS.md](packages/m0-wsgi/AGENTS.md). **Read it before
editing m0-wsgi, the shim or `m0serve.mojo`, and before editing the pool
and executor seams outside the package** — `lightbug_http/offload.mojo`,
`lightbug_http/ring.mojo`, the event loop's offload paths and
`m0_http.mojo_pool` — whose own directories do not load that page for you.
The rules that have cost the most, in brief:

- **The bridge's per-request path is the raw C API.** `PyDict_SetItem` does
  not steal, so every string built for it is `Py_DecRef`'d after the store;
  `PyTuple_SetItem` does, so its value must not be. `smoke-django`'s RSS
  guard stays at 0 KB over 10k requests.
- **Bytes never round-trip through a `String`**: Mojo strings are UTF-8 and
  it corrupts every byte above 0x7F. `std.python` binds no `bytes` API; the
  way in is `ExternalFunction[name, type].load(cpy.lib.borrow())`, resolved
  once at construction.
- **Fork before the first Python call, never after.**
- **No thread waits holding the GIL.** Mojo acquires it on its own only to
  destroy a `PythonObject`; waits go through `DetachingBackend`, and a loop
  with a handler pool holds no thread state at all while it serves.
- **The executor shim is a Python file rendered into Mojo**: edit
  `shim/m0_shim.py`, run `poe render-shim`, commit both; `poe test-shim`
  holds its ownership rules.
- **Every lane needs a thread** — a mount set that leaves one without is
  refused, never served — and **a stream's begin frame goes out before its
  head**.

`m0-postgres` and `m0-sqlite` import nothing else here and link
**nothing**: libpq and libsqlite3 are opened with `dlopen` at run time, so
no binary in the repo carries either dependency, and a `-Xlinker -lsqlite3`
anywhere in the tree is a regression. Both obey three rules, each found by
crashing — the handle and the pointers loaded from it live in one struct,
every entry point is private behind a method, and the library is pinned
`RTLD_NODELETE` so it is never unloaded. m0-sqlite's `Connection` and
`Statement` are `Movable` but deliberately not `Copyable`, and
`test-postgres-server` needs a server, so it is not in `test-all`. The rest,
including three SQLite invariants that look like bugs and are not, is
[packages/m0-postgres/AGENTS.md](packages/m0-postgres/AGENTS.md) and
[packages/m0-sqlite/AGENTS.md](packages/m0-sqlite/AGENTS.md).

There is one cycle, and it is intentional: files throughout `m0-http/src/`
import from `lightbug_http` — `cors`, `signal`, `auth` and `multiworker` among
them — and ONE fork file imports back: `lightbug_http/loop/state.mojo`, a
module of the event loop, imports `m0_http.log`. Both sides live inside
`packages/m0-http/`, so the cycle never crosses a package boundary. **That
edge has a consequence: nothing in `src/` may reach the event loop —
`event_loop.mojo` or any module of `loop/` — at any depth** (DECISIONS
D33). `m0_http.log` resolves through `m0_http.mojoc`, which is the file
`build-http` is writing while it compiles `src/`, so a `src/` module that
names `run_event_loop` fails with `invalid magic bytes` from a clean
checkout and every build after. A function-local import does not help — a
precompile parses every body it reaches, and `Server.serve_nonblocking`'s
local import works only because nothing in `src/` calls it.

Until 2026-09-18 two more fork files imported back, `mojo_pool.mojo` and
`host.mojo`, placed there because an app conforming to `PoolHandler` or
`AppHandler` behind the `.mojoc` got no witness table on Mojo 1.0. **The
cause was never the package boundary** (probed 2026-09-15): a package
compiled from a directory named other than the package recorded its traits
under the DIRECTORY's name — `trait 'src::fragment::PageShell'` — while a
consumer resolved them under the package's, and every package here runs
`mojo precompile src -o <name>.mojoc`. Mojo 1.1.0 fixed it, `poe
check-mojoc-trait` is the regression guard, and both files left the fork
(D28, retired; docs/notes/the-host-leaves-the-fork.md):

- **`mojo_pool.mojo` is `m0_http.mojo_pool`**, in `src/`. `MojoPool`,
  `PoolContext`, `PoolHandler` and `JOIN_TIMEOUT_NS` import from `m0_http`,
  and `lightbug_http` no longer exports them. An edit there is invisible to
  apps until `build-http` runs, and to `bin/m0serve` until `build-http`,
  `build-wsgi` and `build-serve` have — the opposite of the habit formed
  while it was source-resolved. Its own test imports `src.mojo_pool`.
- **`host.mojo` is the package `m0_host`** (`packages/m0-http/m0_host/`),
  because it calls `run_event_loop` and so cannot be in `src/`. It sits
  above the fork and `m0_http`, is imported by neither, and is resolved
  from SOURCE like the fork: the directory carries the package's name and
  there is no `m0_host.mojoc` — never build one beside it, a directory
  next to a `.mojoc` of its name shadows it. `poe check-host-package`
  compiles it whole (lazy bodies, the fork's blind spot), inside
  `test-all`. `test_host.mojo` imports `m0_host.host` and takes every
  shared type from `m0_http.*`, never `src.*`: the host resolves them
  through the `.mojoc`, and `src.threads.ThreadSet` is a different type.

Renaming each `src/` was the other way out of the trait bug and is still
NOT a quick fix: a source directory beside a `.mojoc` of the same name
shadows it, so every consumer would silently compile from source.
`build-apps` compiling `apps/pool_spike` has reversed with the move: it
was the guard against putting `mojo_pool.mojo` in `src/`, and is now a
second guard on the fix, failing for the real `PoolHandler` if a toolchain
takes it away. `scripts/pool_sabotage.py`
reverts six of that file's rules by matching EXACT source lines (the
`T.make(PoolContext(...))` call among them), and CI runs it on Linux only —
so an edit to one of those lines passes every local gate and fails the
pull request with `NOT APPLICABLE`; run `poe sabotage-pool` after touching
`mojo_pool.mojo`, and re-point the anchor with the line.

`m0-core/ffi_exports.mojo` (package root, deliberately outside `src/`) holds
the C-ABI exports for foreign callers (Bun `dlopen`, N-API, `ctypes`); `poe
build-ffi` emits `libm0core.so`/`.dylib` from it, and `poe smoke-ffi` proves
the artifact through `ctypes` in CI. It must stay the shared-lib entry file —
relative imports don't compile there, and `@export` symbols are only emitted
from the entry module (its docstring records the dead ends). `@export` cannot
be applied to a parametric function, so the entry points name a concrete
pointer origin, and Mojo-side callers erase the origin explicitly — see
`test_ffi_exports.mojo`.

`m0-wsgi/m0serve.mojo` is the second package-root entry file, for the same
reasons: it is the `m0serve` CLI binary (`poe build-serve` → `bin/m0serve`),
`precompile src` must never see it, and it imports `m0_wsgi` through the
`.mojoc` rather than `src.*`. All four WSGI example apps — `django_realtime`
included, since `--realtime` moved its hold machinery into `WSGIHandler` —
are Python-only projects it serves; there is no `server.mojo` in them to
edit.

Holds are described here from the server side only. The **application**
contract — a sync view approving a connection with `M0-Hold`/`M0-Channel`
headers, `m0pub.publish()`, inbound WebSocket messages arriving as a plain
POST — is [QUICKSTART.md](QUICKSTART.md), which is executable: `poe
smoke-quickstart` runs its fenced blocks, then `docs/QUICKSTART_NEXT.md`'s, against the tree's own wheel, so
editing it can break CI. The seam itself lives in the fork
(`lightbug_http/hold.mojo`), because a Mojo view on a `--mount X=mojo`
takes an SSE hold with the same two headers: its `MojoPool` thread does
what a WSGI pool thread does — rewrites the response into the head, sends
the loop the `h` frame before completing — and the loop drains it from
its own registries (SPEC N11, `smoke-mojo-mount-hold`;
docs/notes/hold-from-a-mojo-mount.md). Only under `--realtime`; a
streaming response that is not a hold is still refused from a pool thread,
and a `websocket` instruction degrades there. `--mount PREFIX=hold` is the
built-in mount on that mechanism for a Python application that keeps its
authorization in its own views: the view signs channel, expiry and a
session binding into the stream URL with `m0serve.grant` (stdlib Python,
byte-identical twin in `apps/django_realtime`, `check-docs` insists), and
`HoldMount` verifies it on the pool thread with `m0_http.grant` — HMAC
in constant time, expiry against the host clock, the session cookie
against the binding — then holds. `M0_GRANT_KEY` is the one secret both
sides read; the mount refuses to start without it or without
`--realtime`, and `--doctor` mirrors both (SPEC I21, `smoke-hold-mount`;
docs/notes/grant-verified-holds.md). The verifier's test vectors are
grants the issuer signed, so the two sides cannot drift silently.

**The ROOT pyproject.toml never gets a `[build-system]`**: one there would
make `uv sync` build the repo, which needs `bin/m0serve`, which needs the
venv `uv sync` is creating. Each wheel's lives under `packaging/<name>/`,
and `check_root_has_no_build_system` in `scripts/check_docs.py` holds the
root to it (the rule was prose, "the repo's only `[build-system]`", until
there were two wheels). Both are wheels only, with `dependencies`
deliberately empty.

`packaging/m0serve/` builds the `pip install m0serve` wheel: an sdist cannot
build without the toolchain, and the platform tag is measured from the
binary rather than declared. `poe smoke-wheel` proves the lot outside the
tree.

`packaging/m0/` builds the `m0` wheel — the framework's SOURCE and the
stdlib-Python CLI that builds an application against it (SPEC N23–N26,
D39–D43; docs/notes/the-m0-wheel.md). Its rules are
[packaging/m0/AGENTS.md](packaging/m0/AGENTS.md): read it before touching
`packaging/m0/` or its scaffold templates, the three `scripts/` the wheel
ships (`relocate.py`, `bundle_artifact.py`, `binfmt.py`), the root `mojo`
pin or `max` group it reads, or the six `/mojo/…` docs pages, whose URLs
are permanent — rewrite a page freely, never move one. Push no `m0-v*` tag
casually: one publishes to PyPI.

## The lightbug fork

`packages/m0-http/lightbug_http/` is a **hard fork**, not a vendored snapshot.
Upstream was archived 2026-05-12; there is nothing to rebase onto and nowhere to
send patches. Changes there are ordinary changes to this repo.

- Keep it isolated from framework code. Do not refactor it to match framework style.
- Record anything materially new in [NOTICE](NOTICE) — that file is a licensing
  record, not documentation.
- Do not "fix" the `m0_http.log` back-edge by inverting it.
- **`c/fcntl.mojo` holds the program's one `fcntl` declaration** (with
  the Darwin arm64 variadic workaround), and it imports nothing from the
  fork. The lowest layers (`socket`, `socketpair`, `pipe`, `fdpass`)
  mark what they create close-on-exec through it (SPEC G16), and
  `kqueue.mojo`, its old home, imports `socket.mojo`, so they could not
  reach it there without a cycle. A second `external_call["fcntl"]` with
  another signature does not compile.
- **`poe check-fork-package` compiles it whole, and is in `test-all`.**
  `build-http` precompiles `src` only and Mojo checks method bodies lazily,
  so a body no app instantiates is never type-checked — ten errors had
  collected that way, one of them a write past the end of a stack
  allocation. The task throws its artifact away; nothing about how an app
  resolves `lightbug_http` changes (still from source, for the reason the
  trait rule above gives).

## Commands

```bash
uv run poe                  # list every task
uv run poe build-all        # each package -> .mojoc, in dependency order
uv run poe test-all         # builds first, then runs all tests
uv run poe check-fork-package  # the fork type-checks whole (lazy bodies too)
uv run poe test-shim        # the executor shim's ownership rules, sabotage-proven
uv run poe stress-asgi      # PRE-RELEASE: N streamed + WebSocket rounds, both loop modes
uv run poe stress-pool      # PRE-RELEASE: the pool's lost-wake reproducers, per wake mode, in the Linux container
uv run poe smoke-hello      # start hello, assert /health, stop
uv run poe smoke-counter    # assert an SSE broadcast reaches a live client
uv run poe smoke-shutdown   # SIGTERM drains; signalling the supervisor reaps workers
uv run poe smoke-blocking-threads  # a slow view must not stall what is behind it
uv run poe test-sqlite      # needs the runtime libsqlite3 on the system (opened, not linked)
uv run poe check-keepalive-barrier # the `_ = x` at an FFI site still pins the buffer
uv run poe sabotage-keepalive      # revert each of the probe's rules; all must be caught
uv run poe canary           # full suite against the Mojo nightly, then restore

# The warning ratchet. mojo has no per-warning suppression, so the residual
# warnings that cannot be fixed on the pinned toolchain are pinned to a count
# instead. CI tees build-all + test-all into one log and checks it; both are
# needed, because only test-all compiles test/ sources.
uv run poe check-warnings compile.log
uv run poe check-warnings compile.log --update   # after genuinely fixing some

# The doc-fact ratchet, same philosophy for prose: numbers with a machine
# source (this file's warning counts, smoke coverage in test.yml, the
# generated bench table in WSGI_PERFORMANCE.md) are CI-checked against it.
# Benchmark runs leave environment-stamped artifacts in bench/results/;
# the doc table renders from the newest one.
uv run poe check-docs         # fails naming the drifted fact
# BENCHMARKS.md prose: a figure is a num span or sits in an `observed: WHERE`
# block; a bare one fails check-docs naming its line. Cut sentences freely.
uv run poe render-bench-docs  # after committing a new bench artifact
uv run poe render-spec        # after editing docs/SPEC.md's capability tables
uv run poe sabotage-spec      # revert each spec-sheet rule; all must be caught
uv run poe check-citations    # every RFC cited is current, by the committed snapshot
uv run poe check-citations --update   # refetch scripts/rfc_status.json (network)
python3 scripts/emit.py --selftest   # the CI measurement recorder
```

**CI measurements are recorded rather than echoed into an expiring log.**
Several smokes compute a real quantity and print it — RSS growth over 10k
requests, a fast request's latency behind two slow views, sendfile's RSS
delta. A guard tells you pass or fail; it does not tell you the number has
moved from 300 KB to 11000 KB against a 12288 KB limit and is one commit from
red. `scripts/emit.py` appends each to `$M0_RESULTS` as one JSON line, and
each smoke job renders them into the run summary (with a **headroom** column,
which is the point) and uploads them as `ci-results-<os>` and
`ci-results-<os>-gateway`. Three properties
are load-bearing:

- **It never fails.** Exit status is 0 whatever happens — bad argument,
  unwritable path, full disk. A recording failure must never turn a passing
  gate red, and must never be mistaken for the thing being measured.
  `scripts/bench_asgi.py` already applies this discipline to its artifact
  write; this is the same rule.
- **It is a no-op without `$M0_RESULTS`**, which is what makes a call site
  safe inside a task body with no CI conditional around it — and is also
  exactly how the whole thing could become decorative, since deleting the
  workflow's `env:` block leaves every call running, exiting 0 and recording
  nothing, with an identical job log because the `echo` beside it still
  prints. `check_ci_measurements_are_collected` refuses that, plus a
  collected-but-never-rendered file, a missing upload, and the recorder's own
  selftest dropping out of CI.
- **`--selftest` is a CI step**, beside `warning_ratchet.py --selftest` and
  `binfmt.py --selftest`, for the reason those are: a regression in a recorder
  drops records rather than failing. It caught two real bugs while being
  written — an unserialisable value losing its whole record, and rows keyed
  so that the same metric from two runners raced instead of showing as two.

Adding a measurement is one line beside the `echo` that already computes it.
Do not add one that can fail, and do not make a gate depend on a recorded
value — the gate stays the `[ "$x" -lt "$limit" ] || fail` beside it.

`docs/SPEC.md` is the public capability matrix -- a requirements traceability
matrix, and the same philosophy applied to claims rather than numbers. One row
per capability, a permanent **id** (`A7`), four status words (`verified`,
`implemented`, `planned`, `out of scope`), and every row names its
evidence: a `test.yml` **step name** plus a cadence, a `test_x.mojo:test_fn`
that must exist, a `docs/ROADMAP.md` heading that must resolve, or a reason.
`scripts/spec_sheet.py` holds the rules and `check_spec_sheet` forwards them.
Three things about it are load-bearing:

- **Cadence is part of the evidence, because a green tick does not cover
  everything.** CI pins GIL-enabled 3.13, so every `--threads` phase skips and
  `smoke-threads` proves only the refusal — the step is named "the threaded
  mode's **guard**" for that reason. Free-threaded serving is `(weekly)`,
  proven by `py-canary.yml`; the RFC snapshot's live comparison is
  `(monthly)`, proven by `citations.yml`; `stress-asgi` and `probe-pool` are
  `(pre-release)`. A row citing a `test.yml` step must say `(every PR)`, and
  the checker rejects one that carries an `if:`.
- **Both directions, over two closed sets.** Every `smoke-*` step in
  `test.yml` must be cited by some row, and every flag in `cli.mojo`'s
  `_takes_value`/`_is_bool` lists must be named by some row — so a gate or a
  flag cannot ship unrecorded. A gate that `exit 0`s on a missing import must
  have that module in `[dependency-groups] dev`, or it is green having tested
  nothing.
- **Refer to a row by its id, never its prose.** Ids are assigned once, never
  renumbered and never reused -- a deleted row's id is retired, so an id in an
  old commit still means what it meant. This exists because prose keys broke
  things twice: sabotages quoting a row reported NOT APPLICABLE the moment an
  audit legitimately re-pointed it. Reuse is the one rule not enforced, because
  checking it needs a ledger of retired ids that is itself a second source of
  truth; it is written down instead. The inverse of this page -- gates
  DECLARING what they cover rather than being cited by it -- is BUILT (F12):
  every `verified (every PR)` row must be declared by its own gate (a
  `covers: A7` docstring line in the cited test, or a
  `scripts/emit.py --covers A7` call in what the cited step runs), and the
  checker requires the declaration to agree with the citation. Adding or
  re-pointing a row means adding the declaration too; the checker's failure
  names which side is missing.
- **The rules are pure functions of text**, which is what lets
  `--sabotage` revert one in memory and insist the checker catches it —
  `shim_ownership.py`'s shape. Fourteen of the thirty-two sabotages mutate
  `pyproject.toml`, `test.yml`, `cli.mojo`, the host's `flags.mojo` or the
  test index rather than the sheet, so every source arrives as an argument. Do not "simplify" the
  checker into something that reads paths.

What it deliberately cannot do, and the page says so: prove that a cited gate
exercises the capability its row claims.

`.github/workflows/docs.yml` (**`Docs`**, not `Tests` — the automerge
workflows key on that exact name) runs `check-docs` and the sabotage with
**no path filter**. That is the point: `test.yml` ignores `*.md` and `docs/**`,
so the ratchet was silent on exactly the pull requests that edit prose, and a
filtered workflow would have the same defect inverted. Unfiltered it always
reports, which is what makes it the one check `main` can require. Do not add
it to the automerge triggers — `QUICKSTART.md` is a file CI *executes*.

One test file, without going through poe — the `-I` chain mirrors the package's
dependencies. `mojo` lives in `.venv`, so every invocation needs `uv run`
(or an activated venv):

```bash
uv run mojo run -I packages/m0-http -I packages/m0-core \
  packages/m0-http/test/test_router.mojo

# m0-sqlite too: libsqlite3 is opened at run time, so nothing links it.
uv run mojo run -I packages/m0-sqlite packages/m0-sqlite/test/test_sqlite.mojo
```

Tests are `std.testing`: `test_*` functions in a `test_*.mojo`, dispatched by
`TestSuite.discover_tests[__functions_in_module()]().run()` in `main()`. Adding
a test means adding a function — there is no registration list to update.

The 0 warnings the baseline records are a floor, not a target: the ratchet
now fails on the first warning anyone adds. It stood at 68 until 2026-09-05,
described here as unfixable on the pinned toolchain, and every one of those
claims failed to reproduce when probed against that toolchain: `abi("C")` is
a function *effect* that goes before the return arrow (`m0-core/
ffi_exports.mojo`), `unsafe_alloc` is importable from `std.memory.alloc`, and
the doc-string lint accepts a summary that opens with a backticked
identifier (`` `wants_html` convenience... ``), which the style guide asks
for anyway. Before believing a warning cannot be fixed, write the ten-line
probe and run it under `uv run mojo run`.

A `.mojoc` is locked to the exact compiler version that produced it. After any
toolchain change run `build-all`, or you get:

```
Mojo precompiled file is incompatible with the current version of the Mojo compiler
```

The VS Code LSP resolves cross-package imports through these same files, so
stale artifacts appear as unresolved imports in the editor. If *every* prelude
type (`String`, `List`, …) reports "unable to locate module 'std'", the LSP is
running a different Mojo than `uv.lock` pins — that is an editor problem, not a
code problem; check with the compiler before believing it.

**`uv run poe canary` does the whole nightly probe in one command** — swap,
`build-all` + `test-all`, then restore the pin and rebuild the `.mojoc`
artifacts, with the restore in an `EXIT` trap so it happens even when the
canary fails. It exits 0 if the nightly is clean, 1 if the nightly broke
something, and 2 if the environment could not be put back. Prefer it to
driving the steps by hand, which has a trap:

**On a nightly, every task needs `--no-sync`.** `poe nightly-try` swaps the
venv's toolchain without touching `uv.lock`; a plain `uv run` re-syncs the venv
and silently puts you back on stable, so `uv run poe test-all` after
`nightly-try` reports a green *stable* run and the canary means nothing. Use
`uv run --no-sync poe <task>` until `poe nightly-restore`.

CI lives in `.github/workflows/test.yml` and is named `Tests`. Both
`dependabot-automerge.yml` and `label-automerge.yml` trigger on that exact
name, so renaming the workflow silently disables both. `test.yml` ignores
`*.md`, `docs/**` and `.claude/**` — a doc-only change runs nothing, and
therefore never reaches the auto-merge workflows either.

**The smokes are TWO jobs, `smoke` and `smoke-gateway`, and the split is a
cap rather than taste.** One job ran 30m17s green on `main`, which left four
minutes under its 35-minute cap; the ubuntu leg was cancelled at that cap
four times across two pull requests, each time inside `Smoke test the
Django realtime example over WebSockets` near the end of the list, on
runners that were simply slower (26m1s for a unit-tests leg that usually
takes 18m0s — nothing in the tree had changed). Halving the work AND
leaving the cap at roughly twice the measured run is what keeps a cap able
to catch a wedged server without cancelling a green one: the two jobs
divide `main`'s own step times into 12.0 and 13.1 min on ubuntu, 13.2 and
12.8 on macOS, against 30. `smoke` carries the server and the Mojo layer,
`smoke-gateway` the WSGI and ASGI bridges, the mounts, the pool and
`--realtime`. Three rules come with the shape:

- **Shards are separate JOBS, never one job with `if: matrix.shard`.**
  `scripts/spec_sheet.py` refuses a SPEC row whose cited step carries an
  `if:`, a conditional step not being evidence that it ran — so the matrix
  form would fail every cited row at once. Moving a step between the two
  jobs is free: the sheet reads step NAMES out of the file and does not
  care which job holds one.
- **No job in `test.yml` `needs:` another, and the smokes used to.** That
  gate put `unit-tests` — 18 min on `main`, 26 on a slow runner — on the
  front of every run, and caught nothing: in the three most recent failing
  `Tests` runs (35515503893, 35477118692, 35477093973) the failure was in
  a smoke job every time and `unit-tests` was green every time. The
  repository is PUBLIC, so the minutes are free (the macOS 10x multiplier
  does not bill) and observed queueing is under 90 s, which makes the
  serialization pure latency. What the gate really protected against — a
  doc-fact drift, or a broken `build-all` lighting up every job at once —
  is answered by `Docs`, the one required check on `main`.
- **Neither smoke job compiles the example apps.** `build-apps` builds each
  app into a mktemp dir and DISCARDS the binaries, so no smoke can consume
  it — every row either `mojo run`s its app, `mojo build`s its own copy, or
  serves through `bin/m0serve`. It is a compile gate, `poe test-all` runs
  it in `unit-tests`, and it cost 4 min a leg twice over to re-answer a
  settled question. The reason is the discarded output, NOT the `needs:`
  that used to sit above it: the gate still runs on every pull request, it
  just no longer runs before the smokes, and nothing there was waiting on
  it.

**`main` is protected by a ruleset**: pull request required (0 approvals),
no force push, no deletion, no bypass actor — so branch first, or the push is
rejected with `GH013`. It requires **exactly one status check, `check-docs`**,
and requiring more would be a mistake: by the `paths-ignore` above, a doc-only
PR produces no `Tests` run at all, so requiring `Tests` would leave every such
PR unmergeable on a check that never reports. `Docs` is unfiltered precisely so
it always reports, which is what makes it the one check that can be required —
the ruleset declared none at all until that workflow existed.

The required context is `check-docs`, the **job** id in `docs.yml`, not `Docs`,
the workflow name; GitHub names a check run after its job. Three edits stop it
reporting — renaming the job, giving it a matrix (which suffixes the context),
or adding a path filter — and none of them fails anything. Every PR simply
hangs on "Expected — Waiting for status to be reported", with no bypass actor
to merge past it and the fix living in a repository setting rather than this
tree. `check_required_context_intact` in `scripts/check_docs.py` is the guard,
sabotaged all three ways plus deletion.

**`automerge` is a standing order.** A PR carrying that label merges itself as
soon as `Tests` passes for its current head commit. The label is the gate and
it is deliberately not a branch namespace: applying it needs write access, so
a session can open work autonomously but cannot land it. Add the label when
the work is meant to go in unattended; leave it off and the PR waits.

Never reach for `gh pr merge --auto` here. Repository auto-merge is disabled,
so it errors — and it would not gate on CI even if enabled, because
auto-merge waits only on required status checks and the ruleset declares
none. The label is the mechanism.

The Dependabot gate resolves the PR's author through the REST API
(`user.login` and `user.type`), never through `gh pr list --json author`:
the CLI renders a bot's login for display and moved it from
`dependabot[bot]` to `app/dependabot` between gh releases, so a compare
against one spelling refused every Dependabot PR from 2026-08-17 to
2026-09-12 — a green run each time, the reason one log line nobody read.
The two refusals that are never routine on a `dependabot/` branch, not
Dependabot's or from a fork, exit 1 so the next drift is red;
`check_dependabot_gate` in `scripts/check_docs.py` pins the source and the
exit codes, sabotaged four ways in its selftest.

## Imports resolve two ways

Inside a package's own `test/`, imports are `src.*` and compile the package's
source directly, so the package under test needs no rebuild. What makes that
binding safe is `test/__init__.mojo`: with it, a test file is part of its
package and its own `src` wins regardless of `-I` order; without it, the first
`-I` root's `src` wins instead — every package's `test_resolution.mojo` fails
loudly if that ever erodes. Keep the package under test first in `-I` lists
anyway; it is the convention the tasks follow.

Everywhere else — across packages, and from `apps/` — imports are `m0_*` and
resolve through the `.mojoc`. A change to `m0-core` is therefore invisible to
`m0-http` until `build-core` runs.

A `.mojoc` does not bundle its dependencies, so a consumer passes every `-I` in
the chain, and apps add `-I apps/` for their own sibling modules
(`datastar_counter.page`). The non-obvious case: `apps/hello/server.mojo`
imports only `lightbug_http` yet still needs `-I packages/m0-core`, because the
back-edge pulls it in — `event_loop.mojo` → `loop/state.mojo` →
`m0_http.log` → `m0_core.json_escape`.

## The handler contract

`HTTPService` (`lightbug_http/service.mojo`) has nine methods, and **only
`func` is required** — the other eight carry default bodies in the trait
(`return None`, `pass`, an empty list, `False`), so a handler declares just
the hooks it uses. The methods are: `func`, `before_request` (called on the LOOP before a request
is offloaded to a pool thread — what answers it there never becomes a
job; `WSGIHandler` answers static mounts and the health path this way),
`after_response`, four SSE hooks —
`sse_drain_slot`, `sse_is_streaming`, `sse_slot_disconnected`,
`sse_peer_frame` (frames arriving over the cross-worker `BroadcastBus`; empty
in non-streaming handlers) — `tick`, the application timer hook (fires
every `app_tick_ms` when configured; runs ON the event loop thread, so keep
it quick), and `ws_message`, which receives complete WebSocket messages
(fragments assembled, control frames already answered by the loop), with
`ws_close_code` beside it: the code a socket's close carried, called the
moment the loop parses it (SPEC L28; the executor's disconnect tag carries
it to the application, 1006 when none was parsed), and `take_ws_closes`,
the sockets the handler closed itself with a Close already queued, which
the loop then lingers on as after its own Close (SPEC I26). The
`sse_*` names are historical: the outbox drain and the disconnect hook serve
WebSocket slots identically — a WS handler queues `encode_ws_frame(...)`
bytes and returns them from `sse_drain_slot`. A handler that streams
nothing and schedules nothing writes none of them.

Adding a method **with a default** is now a non-breaking change; adding one
**without** a default still breaks every implementer at once — every app
under `apps/`, `WSGIHandler`, and the example in README.md — so give a new
hook a default unless there is a reason not to. The guard is
`packages/m0-http/test/test_service.mojo`, whose `MinimalService`
implements `func` and nothing else: reverting any
default in the trait to `...` makes that file fail to compile, which is
checked by sabotaging all eight.

**Every `Server` entry point runs the event loop**, which assigns
`req.slot_id`, drains the outbox, and parses WebSocket frames:
`listen_and_serve` and `serve` are the `_nonblocking` pair with their
defaults, and the blocking accept loop that answered every stream `409` is
gone. Slots index the registry directly, so a stream's capacity
(`DatastarStream(1024)`) must be at least the server's max connections.
A WebSocket upgrade is signalled on the wire, not by a flag: the loop
switches a slot to frame mode when the handler's response is
`101` + `Upgrade: websocket` (what `websocket_upgrade` builds). The
heartbeat timer is shared: on the `sse_heartbeat_ms` cadence an SSE slot
gets a `: heartbeat` comment and a WS slot gets a protocol ping.

## Writing an application in Mojo

`apps/fragment_notes` is the reference: the notes resource as an htmx app
on the framework layer, gated on the wire by `smoke-fragment-notes` (SPEC
section N; the design and the refusals are
`docs/notes/a-fragment-that-names-itself.md`). It was written ugly first
and refactored onto each piece under that green gate — do the same for any
new piece of this layer: an app that asks, a wire gate, then the lift. The
pieces, and the language fact each rests on:

- **The Mojo host** (`m0_host/host.mojo`, SPEC E21–E23; the note is
  `docs/notes/the-mojo-host.md`): `serve[H, P](AppConfig())` is a Mojo
  app's whole `main` below its own configuration checks. `H: AppHandler`
  is an `HTTPService` with a static `make(ctx)` (and `page_slots(workers)`
  for a pre-fork page of its own at `ctx.page`); `P: Producer` has
  `make(ctx)` and `step(mut self, mut out: Publisher) -> Int`, the
  nanoseconds to the next step, and runs on worker 0 alone; `NoProducer`
  is the default. A `Views` table needs no handler: `ViewsApp[S]` serves a
  `ViewState` (`make`, `urls`), as `apps/fragment_notes` does. State that
  lives in one process answers `max_workers() -> 1`, and `M0_WORKERS`
  above it is refused (SPEC N18). The host owns the order the runtime constraints below
  demand — listen, pages and bus pre-fork (the bus at one worker too),
  fork, accept sharing bound, signals after the fork, `H.make` per worker,
  the producer handed every channel through a `Publisher` that hides the
  descriptors and the shared id word through `Publisher.next_id` (a
  producer numbering from its own counter restarts at 1 when worker 0 is
  respawned, and every stream held on a sibling goes silent for the
  pre-crash uptime, the loop dropping ids at or below what a slot has
  seen — SPEC E25), the drain, the 5 s join with `_exit` for a straggler,
  `exit_worker` — so an app cannot spell them wrong (D27 is what it
  decides for every producer). A `make` that raises, handler or producer,
  is refused with 78 rather than crash-looped, the producer being built on
  the spawning thread before the listen, and one worker's refusal ends its
  siblings (D30). It is a source-resolved package of its own, `m0_host`,
  above the fork and `m0_http` (D33; it left the fork on 2026-09-18, D28
  retired), serves `M0_BLOCKING_THREADS=N` as one GIL-free pool lane
  per worker (D31, SPEC E26: `PoolLane[H]` builds the app's handler again
  on each thread, `HostContext.thread` names the instance, the host waits
  for every thread's handler before it serves and a raising pool `make`
  is the same 78; a stream begun in `func` is refused 409 from a pool
  thread, so a stream open is `on_loop=True` or `add_loop` on its table —
  D32 — or lives in `before_request`; the loop stamps the producer's stop
  word as its drain begins and the pool and producer joins count from
  it, so the shutdown bounds overlap rather than stack), serves
  `M0_THREADS=N` as N loops on N threads of ONE process (D35, SPEC E27–E29,
  `smoke-host-threads`; docs/notes/loops-on-threads.md: `_serve_threaded`
  is the prefork order with "fork" struck out — page, bus and accept-share
  channels made once and sized by the LOOP count, signals armed BEFORE the
  threads exist and the one pipe fanned out to a pipe per loop, the
  handler, pool and loop per thread in `_loop_run`, behind a barrier so no
  loop serves until every `make` has returned; `ctx.worker`/`workers`
  count loops and `ctx.threaded` names the kind, so an app is served by
  either mode unchanged; `max_threads()` DEFAULTS to `max_workers()`, so
  state that lives in one handler refuses loops without being asked;
  there is no supervisor, so a loop that dies takes the process; nothing
  was forked, so `main` returns. Measured at parity with prefork on
  throughput and tail, 20–35 % less RSS; threads are the documented way
  to N for an m0 application since 2026-09-25 (D48, superseding D35's
  "prefork first"), because MAX's parallel runtime does not survive a
  fork: `M0_WORKERS>1` in a binary that links `libAsyncRTMojoBindings`
  is refused with 78 (`workers-vs-parallel-runtime`, the last entry of
  `host_checks`, SPEC E32, `smoke-parallel-runtime`; the fact is read
  off the loaded images, `RTLD_NOLOAD` on Linux and dyld's list on
  macOS, by `m0_http.parallel_runtime_linked`, which m0serve reads for
  the same refusal on a Mojo mount — SPEC E33), since a `parallelize`
  in a forked worker never returns — the
  request hung, its loop with it, and SIGTERM did not end the process;
  docs/notes/threads-first-for-m0-apps.md), and refuses `M0_SPAWN_WORKERS`,
  and `M0_WORKERS>1` beside `M0_THREADS>1`, with 78. **It has a command
  line and a doctor** (`m0_host/flags.mojo`, SPEC E30–E31, D37, `smoke-host-doctor`;
  docs/notes/flags-and-a-doctor-for-the-host.md): `serve` lays the flags
  over the `AppConfig` it is handed — flag > env > default, strict, exit 2
  for what cannot be READ — and the overlay is idempotent, which is what
  lets an app that prints its own address take `host_config()` instead
  (`AppConfig()` must never read argv itself: m0serve builds one). A count
  that cannot be SERVED is a 78 whichever way it arrived, because
  `host_checks` is the ONE list both `serve` (its first failure) and
  `--doctor` (all of them, same exit) read — add a refusal THERE, never
  beside it. The report is `m0_http.doctor.Report`, m0serve's shape, as the
  LAST line of stdout (an app's banner comes first). The gate app runs the
  flag rows in both shapes (`M0_HOSTCHECK_ENV_CONFIG=1` is
  `serve(AppConfig())`): with `host_config()` alone two sabotages were
  MISSED, the flags having been applied before `serve` saw them.
  `apps/host_check` is
  its gate app;
  `apps/blobs`, `sim_loop`, `datastar_counter`, `datastar_todo`,
  `fragment_notes` and `ramp` run on it — `apps/ramp` being ONE views
  module built into m0serve as a mount and into a host binary, compared
  byte for byte and by placement on both by `smoke-ramp` (SPEC N20;
  docs/notes/the-ramp-test.md). An app that broadcasts a whole rendered state
  from several workers holds a lock from the change until the frame is
  numbered and published, or a stale render can take the newer id
  (`datastar_todo`, SPEC N17). Run `poe sabotage-host` after
  touching `host.mojo`: its anchors are exact source lines. The whole run
  wants the `max` group (`uv run --group max poe sabotage-host`), which
  its `parallel` arm builds against; on Linux every other gate holds
  either way. On macOS they do not, because a build beside `max-core` links
  the runtime into every binary and E32 refuses the prefork baselines, so
  run `--skip parallel` in the default venv and then `--only parallel`
  under `--group max`.
- **`Views[S]`** (`m0-http/src/views.mojo`): a view is a free function
  `(req, params, state) raises -> HTTPResponse`; `add_read` hands the state
  borrowed, `add_write` hands it `mut` (`poe sabotage-views` compiles the
  counter-examples and insists they are refused), `add_loop` registers a
  stateless view answered in `before_request` so it never becomes a pool
  job (and answered from `dispatch` too, one round trip slower, by a
  handler that forgot to wire the hook); `dispatch` answers 405 with an
  `Allow` merged across both tables and `OPTIONS` on any registered path
  with 204; the routers are private, `Views.allow_header` is what an app
  reads. Views are stored as `thin` function pointers. A capturing closure is
  not `thin`, so there is **no decorator or middleware story**: guards are
  early returns of `Optional[HTTPResponse]`. `params` stays positional —
  origins are not spellable as struct parameters on the pinned toolchain,
  which kills both a borrowing request wrapper and named route params.
- **`Fragment[V]` and `Html`** (`m0-http/src/html.mojo`): a fragment writes
  its root id once and `swap(verb, url)` generates the attribute targeting
  it from that id; `attr` owns the `="` and `"` and escapes, `text`
  escapes, `raw` says so by name; `finish` consumes the builder, so a
  second call is a compile error; the constructor refuses an id `#id`
  cannot select. Helpers, not a safety type — `String` stays the currency
  and `reply.html(String)` is unchanged. In m0-http beside its consumer
  (it was first put in m0-core to keep the import count at four, which
  mistook the inventory for the rule). **The vocabulary is the type
  parameter**: `Fragment[Htmx]` emits `hx-*` and `Fragment[Datastar]`
  emits `data-on:EVENT="@verb('url')"` with no target (Datastar morphs a
  `text/html` answer into the element whose id it carries — the
  fragment's own; `Htmx` is gated against htmx **4.0.0** since 2026-09-19,
  D6 retired: the same three per-element attributes, which explicit
  inheritance leaves intact, plus `query`, the sixth verb. htmx 4 sends a
  DELETE's fields in the QUERY STRING with no setting to change it, so a
  CSRF token on one is a header — `hx-headers`, which
  `header=csrf_header(token)` on the swap writes (SPEC N44; D38 retired)
  — and it swaps every 4xx, so an error a person may see is
  answered as a fragment), the event picked from the OPEN element by htmx's own
  default-trigger rule (a form submits with `__prevent` and
  `{contentType: 'form'}`, a field changes, an `a`/`button` clicks with
  `__prevent`, the rest click — WHEN agrees; WHAT travels is each
  library's own, and a Datastar field sends the signal store, so bind it).
  A Datastar URL sits inside a JavaScript string literal that `attr`'s
  HTML escaping does not protect, so `Datastar.swap` refuses a URL
  carrying `'`, `\`, CR or LF (`url_for` encodes them; an app building a
  query from request data must too), and both vocabularies refuse a verb
  that is not one of the five. `Htmx.swap` and `Datastar.swap` are the
  only places either spelling lives; an app names its vocabulary once
  (`comptime Frag = Fragment[Htmx]`). Those two are the ones the layer
  ships; **`Vocabulary` is open to an application's own** (D7 retired
  2026-09-18, D34, SPEC N21). Nothing behind a `.mojoc` is private — an
  app reads `h._open_kind` and imports `_check_verb`, both measured — so
  the contract is a rule, not a fence: a conformance is written WITHOUT
  AN UNDERSCORE. `h.open_kind()` (`is_form`/`is_field`/`is_link`) is how
  it learns the element, `verbs()` — static, defaulted to the five — is
  how it names a sixth (htmx 4's `query`), and the verb check is the
  LAYER's (`_swap[V]`, the one function all three call sites go through),
  so do not put it back in a conformance and do not call `V.swap`
  directly. `Datastar` is written against that surface on purpose.
  `poe check-app-vocabulary` (in `test-all`) builds an htmx 4 vocabulary
  from a directory outside the repo and reads its output with `hxlint` —
  `scripts/hxlint.py` and `hx_vocab.py` are hx-flask's, vendored byte for
  byte under a hash guard in `check-docs`: never edit them here.
  **`push=True` on `swap`/`el` moves the address bar** (SPEC N37, D46;
  docs/notes/a-swap-that-moves-the-address-bar.md): `Htmx` writes
  `hx-push-url="true"` through `Vocabulary.push_url`, whose default
  REFUSES, the layer refuses it for any verb but `get`, and `Datastar`
  raises — its free bundle has no history code at all (re-read at 1.0.4;
  `data-replace-url` and `data-query-string` are Pro), so a push there is
  an address the back button cannot rebuild. A refusal, never a no-op.
  One mode, on purpose: Datastar keeps a non-default mode on the
  RESPONSE (`datastar-mode`) and htmx on the element, so a `mode` on
  `swap` is a spelling one of them cannot honour; when an app appends,
  the mode belongs beside `page_or_fragment`, where both libraries take
  a header. `apps/datastar_todo` is the Datastar reference — its list is
  one line, verbatim as the `elements` of every broadcast frame
  (`m0-datastar/test/test_fragment_frame.mojo`, SPEC N7) — and
  `docs/notes/one-renderer-two-transports.md` records what was checked
  against the v1.0.3 bundle. **Two tiers over one buffer**: the builder
  (one call per attribute, allocates once) and the expression tier —
  `el(tag, attrs, children...)`, `void`, `attr`, `flag`, `text`, and
  `Fragment.el(tag, verb, url, ...)` for an element that swaps the
  fragment — where an element is a `String`, each hole names its
  escaping and every `el` allocates. `fragment_notes` keeps its list in
  the tier and its detail in the builder on purpose (SPEC N10; the two
  are pinned byte-identical in `test_html.mojo`). The tag goes to
  `Fragment.el` once because the vocabulary reads it; there is no
  swap-attributes-as-a-string function, which would spell it twice. The
  attrs slot is positional and `Html.raw_attrs` refuses a non-empty
  value that does not open with a space, so `el("p", "none")` raises
  instead of rendering `<pnone>`.
- **`page_or_fragment`** (`m0-http/src/fragment.mojo`): the framework
  decides page-versus-fragment from FIVE headers — `Datastar-Request:
  true` is a fragment; **`HX-Request-Type` DECIDES when present**
  (`partial` a fragment, `full` a page; htmx 4 sends it on every request
  and htmx 2 never does, so which rule runs is keyed on a header only one
  major sends — SPEC N22, docs/notes/the-layer-moves-to-htmx-4.md. It
  decides rather than advises because a v4 boosted element with its own
  target says `partial` beside `HX-Boosted: true` and means it, and a v4
  history restore carries `full` and NO `HX-Request`); without it,
  `HX-Request: true` is a fragment unless
  `HX-History-Restore-Request: true` or `HX-Boosted: true` is beside it,
  because htmx 2.0.4's history restore sends both and swaps the answer's
  BODY into the page it is rebuilding, and a boosted navigation targets
  the body and takes a full document's body (a bare fragment there is a
  page with no head, or a body that is one section) — and every answer
  names all five in `Vary` through `reply.vary`, which
  APPENDS (`vary_accept` used to overwrite, unnoticed while nothing set
  `Vary` twice) and keeps `*` alone. A `status` parameter makes a styled
  404 a 404. The shell is
  the app's own struct conforming to **`PageShell`**, whose one method
  `wrap(fragment)` is called only on the document branch — the context and
  the function as one value, and a shell that needs no context is a struct
  with no fields, which is why there is no second form for one. It was a
  `thin` function over a separate context struct until 2026-09-18, because
  on Mojo 1.0 an app's conformance to `PageShell` got no witness table.
  **The discriminant was a NAME, and Mojo 1.1.0 fixed it**: a package
  compiled from a directory named other than the package used to lose its
  traits' witness tables, and every package here builds `src` into
  `<name>.mojoc`. The pin moved on 2026-09-18, so `poe check-mojoc-trait`
  has flipped from a countdown to a regression guard — all four of its
  arms compile, its `mismatch` arm now passing an app conformance through
  `page_or_fragment` itself, and it fails if a toolchain takes the fix
  away. All three decisions the bug shaped are retired (2026-09-18): D28
  (`PoolHandler` is in `m0_http`, the host in `m0_host`), D12, and D7 —
  `Vocabulary` opened to an application-defined conformance.
- **`url_for(PATTERN, params...)`** (`router.mojo`): the pattern is a
  `comptime` constant given to both `add` and `url_for`, so a misspelled
  route is a compile error; it raises on an arity mismatch and
  percent-encodes each value. `thin` values are not `==`-comparable, so
  routes-as-function-values is closed. `Router.pattern_of` plus
  `test_every_registered_route_reverses_and_matches` keep the two
  directions honest. **A mounted table reverses through `Mount`**:
  `Views[S](Mount("/native"))` registers every pattern under the prefix
  and `Mount.url_for(PATTERN, ...)` puts it in front, one value used
  twice, because a request under `--mount /native=mojo` arrives with its
  path whole and a link rendered as `/notes` lands on the root
  application — dead until clicked, which is why `smoke-mojo-mount`
  follows a rendered link (SPEC N9). `PoolContext.prefix` is how a
  `PoolHandler` learns it: filled by the pool from its own lane table, the
  one the loop routes by. The state an app hands its views is the carrier
  (`st.at.url_for(...)`); `m0serve`'s `MojoMount` is the worked example.
  **An application supplies its own mount as a module, never a copy of
  the entry file**: `m0serve.mojo` imports `MojoMount` from
  `m0serve_mount`, the demo lives in `packages/m0-wsgi/mount/`, and
  `M0SERVE_MOUNT_DIR` on `build-serve` REPLACES that directory on the
  include path. Never add a second mount root beside it: the first `-I`
  root wins silently, which built cleanly and served the demo when
  measured (SPEC N14, `smoke-mount-seam`).
- **`session.mojo`** (beside `grant.mojo`): a stateless signed session
  cookie — `v1.<kid>.<exp>.<subject>.<tag>`, HMAC-SHA256 over the rest,
  refused in the order malformed / unknown key / bad signature / expired
  (the signature BEFORE the expiry, so an expired cookie nobody signed is
  not reported as merely expired) — plus `csrf_token`, a MAC over the
  session's own tag under the same key with a domain-separating prefix,
  and `session_cookie_line`, which builds the `Set-Cookie` for
  `ResponseCookieJar.add_raw` rather than going through the parsed path
  that drops four attributes. It shares the grant's key ring (`find_key`),
  because a session key and a grant key are the same thing. No store: a
  session ends at its expiry or when its key leaves the ring (D24), and
  the app supplies the identity (D25). `apps/fragment_notes` is the
  worked application; the note is
  `docs/notes/a-login-on-the-notes-app.md`.
- **`login.mojo`** (SPEC N43, D53): the glue over `session.mojo` that
  `fragment_notes` wrote by hand and the soak application copied with its
  names changed — `Login.from_env(PREFIX, cookie)` refusing an incomplete
  configuration by name, `sign_in(user, password)` the credential check
  and the session in ONE call (`.session` for the page behind it,
  `set_cookie(resp)` after, because a swap-login renders that page before
  the response exists), `session_of`, `sign_out`, `refuse_signed_out`
  (303 to a navigation, 401 with the form to a swap), `csrf_refusal`
  (header before field, never the query, closed on a refused session),
  `csrf_input`/`csrf_header` and `no_store`. `m0 new --template auth` is
  the application written on it (N45), and `fragment_notes` runs on it:
  the gates that held its hand-written copy hold the module now —
  `smoke-fragment-notes` on the wire, against sessions a CPython issuer
  signed, and `sabotage-notes-login`, whose CSRF arms revert `login.mojo`
  itself and one of whose arms removes the header `html.mojo` writes.
- **`form(req)`** (`form.mojo`): `Optional` — None unless the content
  type is the form's, compared whole, so "not a form" cannot be read as an
  empty one and the check cannot be forgotten — holding an ordered
  multimap that keeps every value of a repeated key.
  Deliberately NOT factored out of `URI.parse`, which fills a last-wins
  `Dict` by contract; `test_form.mojo`'s encoding table is the anti-drift
  device, and it stays a test rather than a shared loop.

- **A table that streams** (`apps/blobs`, SPEC N16; the note is
  `docs/notes/a-world-the-page-cannot-hold.md`): `ViewService` forwards
  two hooks, so an app that also owns the SSE hooks writes its own
  handler over `Views.dispatch` and keeps its `DatastarStream` in the
  state. A producer thread that publishes whole states opens its stream
  with `DatastarStream(send_latest=True)` (a new subscriber gets the
  newest frame, never a replay), counts what `publish_to_channels`
  returns (a frame over `BUS_MAX_FRAME` is refused, not sent), and
  reaches the loop's clicks and viewer counts through the pre-fork
  `SharedAtomics` page, never `malloc`'d memory. It runs on the Mojo
  host, two workers gated. **Its deploy image is `deploy/mojo/Dockerfile`**
  (SPEC M26–M27; docs/notes/the-demo-in-its-own-image.md) -- ONE
  Dockerfile for every Mojo app, `APP` naming the directory, the binary
  at `/app/server` -- whose last layer measures the image (unpacked
  bytes, and no interpreter anywhere, failing the build if one is) into
  `/app/about.json`; the page's footer and `/about` read it through
  `M0_IMAGE_FACTS`, so "no Python in this image" and its size are
  measurements, and `smoke-blobs-image` (every PR, the only x86-64 Mojo
  build CI makes) checks both again from outside. The build context is
  `.dockerignore`'s allowlist: a new app's directory is let in by name.
  Its deploy serves ONE loop (D36). An app's own tests live in
  `apps/<app>/test/` (no `__init__.mojo`) and run in `poe test-apps`.

Not built, each a row of `docs/DECISIONS.md` with the note that argues it
and the condition that would retire it: templates (D2), middleware (D3),
named params (D4), routes as function values (D5), multipart (D16),
`HX-*` header setters (D17), streaming from a Mojo mount other than as an
`M0-Hold` (D22, which superseded D18 when the hold landed as N11), a
session store (D24) and a password KDF (D25). Section N has **no
`planned` rows left**: N12, the Datastar form, shipped 2026-09-12 with
`poe browser-datastar-form` as its pre-release browser run, and N13, the
login, the same day — which retired D15 and added D24 and D25 in its
place. What stands between the layer and its milestone is the soak alone.
Read the ledger and `poe milestones` before proposing a piece; the
process is one pull request per round carrying the note, the rows, the
ledger update and the milestone line, reviewed from a separate session
before it merges.

## Runtime constraints

Properties of the design, not defects to fix in passing:

- **ASGI apps get cross-worker pub/sub as `scope["state"]["m0"]`.**
  `publish(channel, payload)` is m0pub's bus protocol from Python
  (one datagram per worker channel, shared-atomic ids, best-effort);
  `subscribe(channel)` is an async iterator, executor mode only — the
  loop forwards GRIP-named bus frames to each executor as tag-3 submit
  datagrams and the shim fans them out to per-connection asyncio queues
  (drop-oldest at 256). The loop grew a second bus fd (`peer_bus_fd`)
  because the executor's chunk channel consumes `bus_read_fd`; same
  codec, same drain, same `sse_peer_frame` entry. The bus + `SharedAtomics`
  + env exports are created unconditionally pre-fork — protocol
  detection is post-fork, and a single worker's own subscribers ride its
  own channel (there is deliberately no separate local-delivery path).
- **`--pg-listen URL` is the bus's second door.** `m0pub` writes datagram
  descriptors the server hands down at fork, so a management command, a
  cron job, a database trigger or `psql` publishes to nobody — which
  textshelf's own realtime module records as a known limitation. One
  `LISTEN m0` on worker 0 turns `pg_notify` into a bus frame: the payload
  is three JSON string fields (`channel`, `event`, `data`), so the
  listener needs no value scanner, and the frame is built by the same
  `format_sse_event` every other publisher uses, so a client cannot tell
  which door an event came through. `m0pub.notify_sql` builds the
  statement for a caller that already has a cursor, without importing a
  driver into a stdlib-only module. **Refused on macOS wherever a worker
  is FORKED** — `--workers N`, and `--reload`, which supervises even one
  worker — because libpq's connect reaches GSSAPI, then Kerberos, then
  CoreFoundation, and Objective-C aborts a forked child — measured as the
  worker killed by signal 9 and respawned until the supervisor gave up,
  which is the same disguise the `_scproxy` entry above records. The
  predicate asks what `main` calls `supervised`, not the worker count:
  testing `workers > 1` alone let `--reload` through, doctor included.
  `--spawn-workers` is the escape, as it is for Core ML. Both `--pg-listen`
  refusals run BEFORE the bind and the fork: placed after it they ran in
  every child and never in the supervisor, so a usage error read as a crash
  loop. A host with no libpq exits 78 rather than serving without a
  listener, asserted on the wheel's own binary. Four rules: **worker 0
  only** (the
  tick-owner rule — every worker would deliver its own copy), **skip_worker
  is -1** (nothing has queued it locally, unlike an in-process publish), **a
  malformed payload is refused and counted rather than guessed at** (the
  check that is uniquely the listener's, in `pg_envelope.mojo`; an `event`
  or `data` present as anything but a JSON STRING is malformed, because
  `parse_json_field` reads an object as `""` and a trigger's
  `'data', row_to_json(NEW)` reached every subscriber as an empty event,
  counted as delivered — `parse_json_string` is the reader that can say
  no; a reserved channel is refused here
  too, but `publish_to_channels` refuses the same names at the bus
  boundary, so that one is defence in depth and measured to be — removing
  it leaves the gate green), and **a reset re-`LISTEN`s** — a
  reconnected connection is a new backend session listening to nothing, and
  a listener that skipped that would deliver nothing forever while logging
  no error — and it **drains once after connecting and after every reset**,
  because a notification read during the `LISTEN` round trip sits in libpq's
  queue where `poll` cannot see it (`test_notify.mojo` shows the mechanism;
  the listener-level race is not reproducible on demand, so no gate fails
  when that drain is removed). The thread never attaches to the interpreter. Refused without
  `--realtime`, which is what creates the bus. SPEC I22,
  `smoke-pg-notify`.
- **A channel name opening with `\x01` is RESERVED, and every publish
  boundary refuses one.** That namespace is how the executor and pool
  threads address a connection SLOT on the loop (`\x01<kind>/<slot>[/<lane>]`
  — queue these bytes into its stream, unsubscribe it, re-point it), and
  `WSGIHandler.sse_peer_frame` acts on it before looking at any
  subscription. An application's channel is frequently user input, and
  `%01` in a form body decodes to a real control byte, so the separation
  is enforced where an untrusted name crosses in: `channel_is_reserved`
  in `broadcast.mojo` guards `publish_to_channels`, and the shim's
  `_M0Broadcast.publish` and both copies of `m0pub.publish_frame` spell
  the same rule. Internal senders bypass those helpers — they build
  `encode_bus_frame` datagrams directly — which is what makes refusing at
  the boundary sufficient. It was previously argued that an HTTP header
  cannot carry a control byte and so a collision was impossible; that
  covers the `M0-Channel` header alone, and an unauthenticated POST
  reached another client's SSE stream through `publish()`.
- **`/ws/message` is the server's path, not the application's.** Under
  `--realtime` an inbound WebSocket frame is delivered as a synthetic
  `POST` there, carrying `M0-Channel`/`M0-Slot`/`M0-Opcode`; the view must
  be CSRF-exempt to accept it. A request for that path that arrived over
  the wire is therefore answered 404 in `serve_local`, so only the
  synthetic one (built in-process, bypassing `serve_local`) reaches the
  app. Without the reservation the CSRF exemption and the trusted headers
  were available to anyone who could POST.
- **SSE fan-out is per-process unless the app joins the `BroadcastBus`.**
  `M0_WORKERS>1` forks, and each worker gets its own subscriber registry; a
  broadcast reaches other workers' subscribers only when everything shared is
  created *before* the fork (listener, `BroadcastBus`, `SharedAtomics` id
  slot) and each worker wires `enable_bus` + `bus_read_fd` +
  `sse_peer_frame` → `deliver_peer`. `apps/datastar_counter` is the
  reference; partial wiring fails quietly (publishing without draining just
  fills peer channels). Cross-worker ordering is best-effort — the
  redelivery filter keeps the newer of two racing ids. The bus itself is
  transport-agnostic: `WSHub` (`src/ws.mojo`) rides it for WebSocket
  fan-out the same way (`apps/ws_chat` is that reference), with
  `sse_peer_frame` carrying encoded WS frames instead of SSE events.
- **Server-initiated work goes through the `tick` hook** (`M0_APP_TICK_MS`,
  0 = off). It runs ON the event loop thread — a slow tick stalls every
  connection — and handlers with slower cadences sub-schedule off `now_ms`
  (see the counter's uptime clock). What costs is the DUTY CYCLE, work over
  period: retention tracks `1 - duty` and the work transfers into p99 about
  one for one, so under 5% is noise, 25% costs a fifth of the throughput
  and 50% costs half; a rare expensive tick hides, leaving p50 and p99
  healthy and showing only in the maximum. Schedule from the tick, do not
  work in it — periodic work with a real budget goes on a thread of its
  own, publishing through the `BroadcastBus` as `--pg-listen`'s listener
  does, which the loop drains into `sse_peer_frame`. Under `M0_WORKERS>1`
  every worker ticks; an app that must act once per interval designates an
  owner (the counter uses worker 0) and lets the bus carry the result. All
  loop timers (tick, SSE heartbeat) are one-shot on both backends, so the
  firing handler re-arms FIRST — on epoll the re-arm is also what clears
  the fired timerfd's readability, and skipping it is a level-triggered
  event storm.
- **Under `--workers N` the worker that wins an accept gives the
  connection away** (`lightbug_http/accept_share.mojo`, SPEC E16). Every
  worker waits on the one listener and the first to wake drains the
  backlog — the same one nearly every time: 32 of 32 on macOS, 23–31 of
  32 on Linux, so a keep-alive load ran at one worker's throughput. The
  kernel offers nothing portable (`SO_REUSEPORT` hashes on Linux and sends
  everything to the last-bound socket on macOS, measured 64 of 64), so the
  acceptor asks `pick` — least `active + pending` off the pre-fork shared
  page, ties to itself, a sibling inside a pass for over 2 ms or one that
  has left skipped — and passes the socket over the sibling's `AF_UNIX`
  channel with `SCM_RIGHTS` (`c/fdpass.mojo`). The receiver admits it by
  the accept path's own tail (`_admit_connection`). Rules: a send that
  fails for any reason keeps the connection where it is, never drops it;
  `pending` is incremented by the sender and retired by the receiver at
  the END of the pass that admitted it (retiring on receipt let the
  acceptor underestimate a sibling for a pass); `leave` wins over the
  per-pass stores, or the shutdown drain's passes would un-announce the
  departure; the page's per-worker words sit one cache line apart; the
  channels ride the exec under `--spawn-workers` by fd like the bus. One
  worker pays nothing — `active()` is false and every entry is a Bool
  check. `M0_ACCEPT_SHARE=0` is the A/B knob; the gate is
  `smoke-accept-spread` on both CI legs, with the knob-off negative arm on
  macOS only, because Linux's bare race sometimes lands within 2:1.
- **A pass admits one batch of new connections, AFTER the events of the
  ones it already holds** (`ACCEPT_BATCH`, 16; SPEC C8,
  docs/notes/the-accept-batch.md). Admitting is the connection's eager
  read, and on a loop that runs `func` itself that is the whole request,
  so the old drain to EAGAIN — the only bound epoll gives, which reports
  no backlog depth, so up to `max_connections` and through arrivals during
  it — held a keep-alive request behind every queued connection (625 ms
  behind 120 queued 5 ms requests; 79 ms after). Three rules come with it,
  because both listeners are edge-triggered and no edge announces the same
  backlog twice: what a batch leaves is OWED (`LoopState.accept_owed`, and
  `handoffs_owed` for the accept-share channel, batched the same way) and
  taken by the next pass even with no event; the wait does not block while
  anything is owed (`_wait_for_events`); and the flags are cleared where
  the listener closes, since the drain must neither accept on a dead
  descriptor nor spin for it. Owed only when the BATCH stopped the drain:
  a kqueue budget of the reported depth that runs out leaves nothing its
  next edge will not announce, and an error accepting harder will not cure
  (EMFILE) is never owed, or the loop would retry it every pass without
  blocking. The inversion runs a pass only on readiness, so
  `run_pass_once` takes owed batches inside its callback, up to
  `max_connections` accepts' worth — the old bound, because under a flood
  the backlog never empties and the callback must return for the
  application's tasks to run. `M0_ACCEPT_BATCH=0` is the A/B knob;
  `smoke-accept-batch` is the gate on both legs, its negative arm on Linux.
- **Graceful shutdown is opt-in, and armed after the fork.**
  `install_shutdown_signals()` returns the fd to pass as `shutdown_read_fd`;
  its handler writes one byte to that pipe and nothing else. Dispositions and
  fds are both inherited across `fork()`, so a pre-fork install points every
  worker at the supervisor's pipe, which nothing watches — each worker arms
  itself once `fork_all()` returns, and the supervisor arms a different
  handler (`kill` each child) from inside `fork_all`, which is what makes
  `docker stop` on the supervisor alone reap the workers. **A forked worker
  must end with `exit_worker()`, never by returning from `main`**: the
  runtime's teardown calls into libdispatch, which is unusable after a fork
  without exec, and the worker dies with a SIGTRAP the supervisor reads as a
  crash. **Once told to stop, the supervisor respawns nothing** (SPEC D10):
  its handler records the stop before forwarding the signal, and a worker
  that then fails its drain is let go (exit 1), because a replacement would
  never be signalled and `docker stop` would end in SIGKILL.
- **After `fork()` without `exec`, platform runtimes are off limits — including
  from application code.** The `exit_worker()` rule above is one instance; the
  general form bites WSGI apps directly. On macOS `urlopen` consults the system
  proxy through `_scproxy`, which calls into CoreFoundation, and Objective-C
  aborts the process rather than run in a forked child: under `M0_WORKERS>1` the
  worker dies with SIGKILL and the supervisor respawns it, so it reads as a
  dropped connection and a churning worker, not a crash. `M0_WORKERS=1` runs the
  identical code cleanly, which is what makes it look like a load bug. Use
  `http.client.HTTPConnection` (no proxy lookup) — `apps/wsgi_bare`'s
  `/reentrant` route is the worked example and `poe smoke-wsgi` pins it.
  **Apple's libsqlite3 is in this family too**, and it needs no application
  code at all: it instruments `openDatabase` with os_signpost, and in a
  forked child that path can fault — both children of a round killed by
  SIGSEGV inside `_os_log_preferences_refresh`, 3 of 60 runs of
  `test_file.mojo` on an M4 (docs/notes/a-signpost-in-a-forked-child.md).
  So a worker that opens an m0-sqlite connection after the fork is exposed
  on macOS, and the answers are this family's usual one, `--spawn-workers`,
  or `OS_ACTIVITY_MODE=disable` in the environment, which is measured at
  0 of 200 and is what `test-sqlite` sets. A rerun is not the answer:
  the crash is rare, real and not ours.
- **Mojo has no global `var`, but it does have `pop.global_alloc`.** A POSIX
  handler gets no user-data pointer, so `src/global_slot.mojo` reaches an
  internal MLIR op for what C spells `static`. `@no_inline` on the accessors
  is load-bearing (the op is `Pure`, so each inlined copy makes its own
  global), the slots are private to m0-http so writer and reader share one
  emission, and fork copies them rather than sharing — cross-process state is
  `SharedAtomics`, not this. If the op ever stops working nothing is
  installed and the default signal behaviour stands, because a handler over a
  dead slot would swallow SIGTERM; `shutdown_signals_active()` reports which
  happened and `test_lifecycle.mojo` asserts it.
- **A pointer handed to C does not keep its buffer alive; the bare `_ = x`
  after the call does.** Mojo destroys a value at its last *tracked* use,
  and an address laundered into a C argument is not one — `unsafe_ptr()`
  and `Pointer(to=x).unsafe_bitcast[Int]()[]` both erase the origin tying
  it back to the local. Measured on this toolchain: without the line the
  allocator free is emitted BEFORE the call that reads through the
  pointer. Roughly thirty sites end that way, `c/fdpass.mojo`'s `data`
  and `control` (the `SCM_RIGHTS` hand-off under `--workers N`),
  `c/process.mojo`'s `argv`/`bufs`/`path_c` (the `execv` behind
  `--spawn-workers`) and `m0-wsgi/src/bridge.mojo`'s `body` among them;
  deleting one is a use-after-free with no symptom at the call site.

  **Only an OWNING value is at risk.** The release is Mojo's own
  destructor call, placed by the frontend, which is why nothing
  downstream moves it back. A plain stack local whose ADDRESS escapes —
  `fdpass.mojo`'s `iov` — is kept alive by LLVM's escape analysis
  without help, so those keep-alives are belt-and-braces; and
  `signal.mojo`'s and `multiworker.mojo`'s
  `Pointer(to=handler).unsafe_bitcast[Int]()[]` LOADS the function value
  rather than taking the local's address, so nothing escapes there at
  all. One level of indirection separates the three cases.

  `poe check-keepalive-barrier` is the gate (inside `test-all`):
  `scripts/keepalive_probe.mojo` is compiled to LLVM IR and the pinned
  and bare forms are compared. The BARE arm is the load-bearing half —
  without a counterfactual the gate would pass on a toolchain where the
  line does nothing and would have stopped being evidence — and
  `poe sabotage-keepalive` reverts each of the probe's own rules and
  insists the check reports every one. A failure is a finding about the
  toolchain, not gate noise; each outcome prints what it means for the
  tree. The `_ = x^` transfer form is a different thing and is NOT this
  idiom: the compiler warns it has no effect on a trivially
  register-passable type, and the 16 such sites here are genuine
  destroy-now uses on owning values.
- **A request-derived `String` may hold bytes that are not UTF-8, and is
  never sliced with `[byte=a:b]`.** The request target, every header
  value (the parser passes obs-text, bytes above 0x7F, through) and the
  body all become `String`s via `unsafe_from_utf8`, so String's UTF-8
  invariant does not hold for them — and `String[byte=a:b]` asserts a
  codepoint boundary at both ends, which is a trap, not an error. Five
  sites had it: `unquote` (one `GET /?x=<0x80>%41` killed the loop thread
  before any handler, every app and the production WSGI deployment
  alike), the cookie jar (built for every request: `Cookie: a=<0x80>`),
  the static mount's path, the `Accept` negotiator and the ETag matcher.
  A sixth and seventh were not request bytes at all: `split_sse_lines` and
  `sse_data_payload`, which a `--pg-listen` NOTIFY payload reaches on worker
  0's listener thread, and a `SQL_ASCII` database converts nothing. An
  eighth is `m0-datastar`'s `split_data_lines`, the deliberate COPY of
  that splitter (the wire format stays dependency-free, so the fix had to
  be made twice and the copy kept trapping for a release): what reaches it
  is a rendered fragment, and an application renders request data — a todo
  whose text is `a\n<0x80>b` put a non-boundary byte after a line break,
  because HTML escaping touches neither, and one unauthenticated POST
  killed the whole server on the loop thread. Duplicating a function
  duplicates its traps: fix both, or import one.
  Every such slice is now `String(unsafe_from_utf8=s.as_bytes()[a:b])`,
  a byte-span slice with no boundary check; `unquote` is a single byte
  walk. SPEC G14 is the row, one test per site declares it, and both
  `smoke-hello` and `smoke-notes` send the bytes over a socket. Adding a
  slice of a request string means adding it there.
- **A response header carrying CR, LF or NUL is dropped, not transmitted.**
  A value an application built out of user input could otherwise end the
  header block and add headers, or a body, of its own. The fork's head
  writers refuse it for every response: `write_latin1_to` drops the
  header, the cookie jar the `Set-Cookie` line, and `encode`/`encode_into`
  empty an injected reason phrase (SPEC G1, G2); m0-wsgi also refuses it
  as it reads an application's head. Dropping rather than raising: the
  application has already run and its body is real.
- **An application's `Set-Cookie` goes to the wire verbatim.** A `Cookie`
  is what the server builds for itself; a line a WSGI/ASGI application
  returned IS the header, and `ResponseCookieJar.add_raw` transmits it
  unparsed — subject only to the CR/LF refusal above. Round-tripping it through `Cookie.from_set_header` +
  `build_header_value` silently dropped `expires` (the `Expiration` stub
  parses nothing), `SameSite` (lowercase-only match), everything after the
  first `=` in a value, and any unmodelled attribute — on every Django
  session and CSRF cookie of every app. Do not "normalise" that path.
- **The two backends do not have the same trigger semantics, and every read
  path must satisfy the stricter one.** `add_read` is `EV_ADD` on kqueue —
  no `EV_CLEAR`, so connection reads are LEVEL triggered and a partial drain
  is simply reported again — while epoll registers `EPOLLIN | EPOLLET`,
  where bytes already in the socket buffer when the edge fired produce no
  further edge. (`add_read_listen` differs the other way: both edge
  triggered. A write registration replaces the read registration on epoll
  and not on kqueue, which is what `slot_read_armed` tracks.)

  So each platform forgives a different mistake, and macOS will pass without
  the re-arm that Linux requires. `_handle_read_headers` performs exactly
  ONE `recv` of `recv_staging.capacity()` (4096) per call and did not re-arm
  while headers were incomplete: a request bigger than the eager read at
  accept plus one edge — 8192 bytes exactly, measured — stalled on Linux
  until the header timeout answered 408, while macOS served any size. 8 KB
  of request headers is a large cookie jar or a JWT, not an attack. The body
  path had the fix already, with a comment giving this exact reason; it just
  had not been extended to headers. `poe smoke-large-request` pins it.
- **`EV_EOF` on a read event means "no more request bytes", not "connection
  over".** A client may half-close (`shutdown(SHUT_WR)`) to say it has sent
  the whole request and still be waiting to read the answer, so the loop
  finishes the buffered request and only turns off keep-alive; an SSE
  stream still closes, having no request left to answer; a WebSocket first
  reads what its peer left buffered -- a last message, its Close with the
  code the application is told (SPEC L28) -- and closes once nothing is
  left; and a request that is still INCOMPLETE closes at once (`peer_eof`)
  rather than waiting out the header timeout. Closing there discarded a response already written, which
  the client sees as an RST and a lost answer.

  **The two backends used to disagree here, and that is why this was
  invisible in CI**: kqueue sets `EV_EOF` on the read filter for a
  half-close (data may still be pending), while epoll only reports it
  because `add_read` registers `EPOLLRDHUP` — which it originally did not,
  so on Linux a half-close was an ordinary readable event that the header
  path happened to handle. Measured before the fix, 30 requests per shape:
  macOS lost 24-30 of 30 on GET, Content-Length and chunked alike; Linux
  lost none — and conversely a half-closed INCOMPLETE request released its
  slot at once on macOS while Linux held it the full 10 s to the header
  timeout's 408. Registering `EPOLLRDHUP` was once recorded here as a
  deliberate non-change "adding an event source per connection"; that was
  wrong on its own terms — it is one more bit in the existing
  registration, delivering events only when a peer actually half-closes —
  and both platforms now behave identically. `poe smoke-half-close` pins
  the answered response AND the prompt release. One consumer of the flag
  is subtle: `_handle_read_headers` reuses `bytes_read = 0` as its
  EAGAIN-with-buffered-data sentinel, so "the peer really hit EOF" travels
  as `recv_eof`/`peer_eof`, never as a zero byte count — collapsing the
  two closed every request that was partial at an EAGAIN pass.
- **Pipelined requests are answered from the buffer, not from events**
  (RFC 9112 §9.3). The bytes of request N+1 arrive in the same read that
  completes request N and get no readiness event of their own — the edge
  that carried them is spent on epoll, and the socket buffer kqueue's
  level trigger watches no longer holds them. Three pieces make the tail
  answered rather than silently dropped, which is what every release
  through v0.12.0 did: `request_end` stamps where the answered request
  ends (at parse for Content-Length, at completion for chunked — whose
  completion paths now PRESERVE the bytes past the terminator instead of
  resizing them away); the keep-alive reset keeps the tail
  (`prepare_for_new_request(keep_pipelined=True)` — passed ONLY by the
  keep-alive resets, so accept and close still clear whole and one
  client's tail can never leak into another connection's first request);
  and `_drain_pipelined` re-parses the preserved buffer after every
  completed response, one request per iteration. It is iterative on
  purpose (recursing through the handler chain nests a call stack per
  request) and unbounded on purpose (the send buffer is the real bound:
  an iteration whose response cannot go out whole leaves the slot
  RESPONDING and exits). `poe smoke-pipelining` pins all of it.
- **A WebSocket this side closes LINGERS for the peer's Close reply.** RFC
  6455 §5.5.1: the endpoint that sends Close first waits to RECEIVE one
  before closing the connection. Closing as soon as the Close frame drained
  — which is what the loop did — closes the socket before a reply can exist,
  so the reply reaches a socket that is gone and TCP answers with an RST;
  that reset flushes the peer's receive queue, taking the FIN and, for a
  client far enough behind, the Close frame itself (33 of 200 concurrent
  closes reached the `websockets` library as `no close frame received or
  sent` rather than the app's own 1000). `WSState.closing` marks the wait,
  and the three stream-ended close sites plus `_after_send`'s
  `should_close` branch set a `WS_CLOSE_LINGER_NS` deadline in
  `slot_idle_deadline` — a WebSocket's is otherwise 0, so a non-zero one IS
  the linger, and the existing idle sweep reaps a peer that never replies.
  Two consequences worth keeping straight: with idle timeouts off there is
  nothing to bound the wait, so that configuration deliberately keeps the
  old close-at-once behaviour rather than leaking a slot; and the read path
  drops the parser's close echo while `closing`, because this side already
  sent one. `ws_probe.py`'s close-order phase is the guard and its
  CONCURRENCY is load-bearing — one close at a time passes on the broken
  server, which is how this survived two investigations.

  **The deadline is armed ONCE, and that is the whole of the bound.** None
  of the four sites is a transition: the drain reaches its linger branches
  again on every pass while a slot lingers (`sse_is_streaming` stays false
  once the app's close unsubscribed it), and `_after_send` runs again for
  every send that completes while `should_close` and `closing` are both
  set — a heartbeat ping's, at the top of the list, until the heartbeat
  learned to skip a lingering slot. Re-stamping there
  pushed the deadline two seconds into the future about once a second, so
  the sweep never overtook it and a peer that received Close and never
  answered held its slot for the life of the process — the exact leak the
  gating on `idle_timeout > 0` says it exists to avoid. **And nothing
  follows this side's Close** (RFC 6455 §1.4): the heartbeat handler skips
  a slot whose `closing` is set, because a ping sent during the linger
  raced the peer's Close reply and a client that had answered our Close
  read `0x89 0x02 "hb"` where it expected the FIN — `stress-asgi` found it
  in 3 rounds of 30 under CPU hogs, which widen the window between the
  Close going out and the reply being read; `ws_probe.py`'s quiet-linger
  phase holds its reply for three heartbeat periods and requires silence,
  then a FIN (SPEC L29). Every site now
  writes the deadline only `if slot_idle_deadline == 0`, which is a
  reliable test because `_finish_response`'s 101 branch zeroes it. The
  guard is `poe smoke-idle-timeout` (SPEC L16), which asserts BOTH bounds:
  a close inside the linger is v0.15.1's bug, and a slot never reclaimed is
  this one. L15's 64-way concurrent close phase passes on both broken
  servers, which is why the bound needed a gate of its own.
- **A chunked request body ends where RFC 9112 says it ends**, because the
  request decoder is built with `consume_trailer = True`. Without it the
  decode completed at `0\r\n` and the terminating `\r\n` every conforming
  client sends stayed in the receive buffer — and closing a socket with
  unread data queued makes the kernel send RST rather than FIN, discarding
  the response already written. On `Connection: close` that is a response
  the client never sees: measured at up to 53% of chunked requests, and
  100% when the client paced its writes. Keep-alive hid it by never
  closing. The cost of the rule is that a client which omits the final
  CRLF now waits for it, as it would for any truncated body.
- **A chunked body is bounded twice: decoded size AND raw bytes consumed.**
  `max_request_body_size` caps what the application receives; twice that
  caps what the connection cost, read from the decoder's `_total_read`.
  Framing is consumed and dropped as it is decoded, so the first bound
  alone leaves the raw stream limited only by the ratio guard — which
  allows roughly three times the body limit in chunk-extension bytes
  before it fires. The cost is that a body whose framing outweighs its
  payload several times over (1 MB in 3-byte chunks is 3.6 MB on the wire)
  now answers 413, which is what it is.
- **A chunked request body is decoded incrementally, by ONE decoder per
  connection.** `ConnectionProvision.chunk_decoder` is fed only the bytes
  that just arrived and carries its chunk state across reads; the buffer is
  `[headers][decoded][raw tail]` and `pending_bytes` says where the next
  batch lands. Do not rebuild it per read event, which is what it used to
  do: that re-copied and re-scanned the whole body every time, making a
  chunked body O(N^2) on the loop thread (1 MB 0.15 s, 2 MB 0.61 s, 3 MB
  1.37 s, dribbled in 1 KB segments; 0.003/0.004/0.006 s after), and it
  reset `_total_overhead` so the decoder's own abuse-ratio guard could
  never trip.
- **A body the server accepts must fit its receive buffer.** The
  per-connection cap is `ServerConfig.recv_buffer_limit()` — headers plus
  body allowance, floored by `recv_buffer_max` — never the bare field,
  which was a second, lower ceiling that `--max-body` did not raise and
  that refused oversized bodies as `400` where the body cap sends `413`.
- Configuration is env vars, all `M0_`-prefixed: `M0_HOST`, `M0_PORT`,
  `M0_BASE_URL`, `M0_API_KEY`, `M0_WORKERS`, `M0_THREADS` (mutually
  exclusive with `M0_WORKERS>1`; free-threaded CPython only),
  `M0_BLOCKING_THREADS` (handler threads per loop; composes with either of
  those and with `--realtime`), `M0_ACCESS_LOG`, `M0_SSE_HEARTBEAT_MS`,
  `M0_APP_TICK_MS`, `M0_QOS` (macOS: the loop at user-interactive and its
  worker threads at user-initiated QoS, so they stay on performance cores
  under contention; accepted and ignored elsewhere), `M0_ACCEPT_SHARE`
  (`0` turns accept sharing off under `--workers N`; an A/B knob, not a
  flag), `M0_ACCEPT_BATCH` (new connections one pass admits, default 16;
  `0` takes the whole backlog in one pass as the loop used to; the same
  kind of knob), `M0_POOL_TURN_KEEP` (`0` drops the GIL between every job
  of a pool thread's slice again, the shape that starved a waiter; the
  same kind of knob), `M0_POOL_RING` (`0` puts the `--blocking-threads` handoff back
  on datagrams; the same kind of knob), `M0_POOL_ELASTIC` (`0` restores
  the eager pool wakes — every idle thread spinning, every push into a
  parked lane poking it; the same kind of knob) and `M0_POOL_WAKE_AGE_US`
  (how long a job may wait at a ring's head before the loop wakes a
  parked sibling, default 200; a measurement knob) and `M0_POOL_PARALLEL`
  (`1`/`0`: the free-threaded rule — a push wakes a parked thread whenever
  there is one and that wait counts from the push — forced on or off;
  unset, the interpreter decides), `M0_MAX_KEEPALIVE_REQUESTS` (the
  keep-alive request cap, `--max-keepalive-requests` over it; 0 = never
  close for count — every close is a client reconnect, and one per N
  requests is the client's tail at the 1/N quantile, docs/notes/pool-tail.md)
  `M0_GRANT_KEY`, `M0_GRANT_KEY_PREV` and `M0_GRANT_COOKIE` (the hold
  mount's key, its previous key during a rotation, and the session cookie a
  grant binds to; `sessionid`)
  and, for measurement only, `M0_POOL_SPIN_US` (the idle spin before a pool
  thread parks) and `M0_POOL_DEBUG` (per-thread ring/GIL/service histograms
  and the loop's wait counters at shutdown). `m0serve` layers flags on top (flag > env > default) and
  is strict where the env loader is lenient. `--doctor` prints the whole
  resolved configuration as JSON and starts nothing; its contract is that
  it **exits with the code `m0serve` would exit with for the same
  arguments**, held by `smoke-doctor` running both and comparing — both
  read one ordered list (`m0_wsgi.checks`: the flags before the bind, the
  application after the import), so add a refusal THERE, never beside it.

## Mojo 1.1 patterns

This project targets **Mojo 1.1** (pinned in `uv.lock`; moved from 1.0.0 on
2026-09-18, recorded in
[docs/notes/the-pin-moves-to-1-1-0.md](docs/notes/the-pin-moves-to-1-1-0.md)).
What the move cost: `Atomic[Int64]` rather than `Atomic[DType.int64]`,
`_CTimeSpec.tv_nsec` rather than `tv_subsec`, `Hasher.update` taking a
`Span[UInt8]`, `Array` rather than `InlineArray`, and
`ptr`/`as_c_string_span` for the deprecated
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
9. **Parallel arrays (SoA)** — `SSERegistry` and `PatchJournal` keep parallel
   `List` fields for cheap per-field scans, not because `List[Struct]` is
   refused: the `ImplicitlyCopyable` constraint that first motivated them is
   gone. The fork's `OwningList` — a copy of `List` from before that change —
   was retired on 2026-09-05 with the swap measured at parity (the numbers
   are in NOTICE's fork change list); do not reintroduce a private list

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
