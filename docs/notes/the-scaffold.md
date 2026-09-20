# The scaffold: two templates that compile where they lie — 2026-09-20

The second of three pull requests that let an application in Mojo be
written outside this repository. The first added the `m0` wheel and the
commands that need no template
([the-m0-wheel](the-m0-wheel.md)). This one adds `m0 new`, the two
templates it writes, the `AGENTS.md` that goes with them, and the gate that
proves the path from `uvx m0 new` to an answer on the wire. It does not add
`m0 dev`, `m0 image` or the release workflow, and nothing is published.
SPEC N27–N29; decision D44.

## What was built

`m0 new NAME [--template views|live]` writes a directory a person can read
in one sitting:

    pyproject.toml   AGENTS.md   CLAUDE.md   README.md   smoke.sh
    src/server.mojo  src/views.mojo  src/pages.mojo      (live: board, wave)
    test/test_*.mojo
    deploy/Dockerfile  deploy/fly.toml  deploy/README.md
    .github/workflows/test.yml   .gitignore   .dockerignore

- **`views`** is `apps/fragment_notes`' shape without its login: a
  `Views` table over a list held in the state, rendered by one
  `Fragment[Htmx]` that a form, a link and a delete button all swap.
- **`live`** is `apps/blobs`' shape without its kernel: a `Producer`
  stepping a small wave twice a second, each step published as ONE
  `datastar-patch-elements` frame whose `elements` are, verbatim, the
  fragment the document painted first; a `DatastarStream(send_latest=True)`
  behind the four SSE hooks; a shared page carrying kicks and viewer counts
  between the workers and the producer, which pauses while nobody watches.

Both are sessionless (D44). A scaffold that refuses to start until a
password variable is set is a bad first minute, and with no ambient
authority there is no CSRF token to carry — so D38 stands, its scaffold
clause not met, and `AGENTS.md` says what changes the day a login arrives.

## Templates are source, not text

The templates are real `.mojo` files under
`packaging/m0/src/m0/templates/`, and `poe check-templates` — inside
`test-all` — builds each `server.mojo` and runs each test file IN PLACE,
against the tree. A layer change that breaks a template therefore fails in
the pull request that made it.

That only works if a template compiles unsubstituted, which sets the rule:
the application's name appears only where a compiler does not look —
inside string literals, TOML and Markdown — as `__M0_APP__`. The two
version tokens appear in `pyproject.toml` alone. Substitution is
`str.replace`; there is no template engine, and a file that needed one
does not belong in a template. The layout is what makes the rule cheap to
keep: `server.mojo` imports `views` and `pages` as siblings under the
wheel's one include root, tests reach them with the second root `m0 test`
already passes, and there is no package named for the app — so every
scaffolded application has the same paths and a hyphenated name is fine.

What is written is a closed manifest in `new.py`, spelled a second time in
the gate. Hatch includes `templates/` by walking the directory — the one
place this wheel is not git's manifest — so a stray file there could ship;
it could never be WRITTEN, and `check-templates` fails on a file no
manifest names. Dot-files are stored as `dot-gitignore`, `dot-github/`:
a real `.gitignore` inside the package would be read by the tools that
build it.

## The reason phrase

The design pass found that `page_or_fragment(..., status=422)` answers
`422 OK`: `text` defaulted to the literal `"OK"`. Rather than ship an
`AGENTS.md` rule that exists to paper over a default, `text` now defaults
to empty and an empty `text` takes `reply.reason_phrase(status)`. An
explicit `text` still wins, so `fragment_notes`' `401 Unauthorized` is
untouched. N29 is the row; the `views` template's bad form is the first
caller that leaves `text` alone.

## The editor setting that was not written

The plan left one thing for this round to verify before writing: a
`.vscode/settings.json` giving the Mojo extension the include root. Read
from the installed extension (vscode-mojo 26.6.1): the setting is
`mojo.lsp.includeDirs`, its entries are passed to the language server as
`-I` VERBATIM — no variable is expanded — and the server is started with no
working directory of its own, so a relative entry resolves against
wherever the editor's extension host happens to be. The only entry that
works is an absolute one, and an absolute path is a fact about one
machine. So the scaffold writes no settings file; `README.md` gives the
two lines, `.vscode/` is ignored, and `m0 include` prints the path. The
`.m0/include` symlink the plan held in reserve would not have helped: the
path to the symlink would be just as absolute.

## The gate, and what breaking each rule did

`smoke-scaffold` runs on every pull request, both legs; its docstring lists
the phases. Three things about it are deliberate:

- **`m0 new` runs through `uvx --offline` with no toolchain reachable** —
  `PATH` is uv's directory and the system's. That is the claim "needs no
  toolchain and no network", asked as a question.
- **The build is the user's literal command**, `uv run m0 build`, against
  the tree's wheel through `UV_FIND_LINKS`. The wheel is `0.1.0+tree`, a
  local version no index can serve, so the scaffold's exact `m0==` pin can
  never resolve to a published release.
- **Resolution is online.** A scaffold's sync cannot resolve offline from
  the cache a locked sync leaves (measured in the design pass), so it asks
  the index with every wheel already cached — the dependency the job's own
  sync has.

`poe sabotage-scaffold` (pre-release) breaks each rule from the template
side, rebuilds the wheel, and requires the smoke to fail for that template
AND to say the expected thing. The rules the WIRE holds run with the
template's own `m0 test` switched off: those tests come first and catch
several of the same breaks, which is the template doing its job and not an
answer to "does the wire assertion fail?" One rule runs the other way
round, to show the template's test is what goes red. `check-templates`'
own five rules run first, against that gate.

Twenty-nine rules, all caught, at this pull request's head — after the
first run of the smoke's twenty-four caught twenty-three, and the one it
missed was the gate's own defect:

- **The layer's reason-phrase fix, reverted, PASSED.** The scaffold's own
  files reach the project through `uvx --from <path>`, which notices a
  rebuilt wheel. The framework underneath them is resolved by NAME —
  `m0==0.1.0+tree` through `UV_FIND_LINKS` — and uv served the
  `0.1.0+tree` it had cached from the run before. So every template rule
  was caught and the one rule that edited `m0-http` was not: the gate was
  compiling yesterday's framework. Confirmed before fixing, by asserting
  first that every file the wheel carries under `m0/` is byte-equal in the
  venv — which failed naming `m0/_mojo/m0_http/fragment.mojo`. The gate now
  runs `uv sync --refresh-package m0` itself, keeps the byte-equal
  assertion, and then runs the user's literal `uv run m0 build`. The
  refresh is the gate's step and not the user's: only a gate rebuilds a
  wheel under one version, and a published version is immutable. A CI
  runner that persists uv's cache between runs would have had the same
  hole, silently.

## Not covered

`deploy/` is written and not gated: nothing builds the scaffold's image
until the next pull request's `smoke-scaffold-image`, which also has to
answer how the tree's wheel reaches `uv sync` inside `docker build`. The
Dockerfile is `deploy/mojo/Dockerfile` with the package chain replaced by
`uv sync` and `uv run m0 build --release`; its runtime stage and its
self-measurement are unchanged. Until that gate exists, SPEC N27 says so.

Probed once by hand, so the next round inherits a fact rather than a
guess: a scaffolded `views` app built with `docker build` in a Linux
aarch64 VM and answered `/health` and the 422 from the container —
`about.json` reading `"python":false`, `app_bytes` 2,953,336 (the binary
and four runtime libraries), built `for generic`. The probe ADDED what that
round has to design, because the wheel is on no index: the wheel copied
into the context under `.wheels/`, `UV_FIND_LINKS` pointing at it in the
builder, and a sync that wrote its own lock in place of `--frozen`. The
file as the scaffold writes it has not been built; x86-64 has not been
built at all.

## Timings

Measured by the gate on an M4, all-source from the installed wheel, the
toolchain's wheels already in uv's cache:

| what | `views` | `live` |
|---|---|---|
| `uv run m0 build`, first build | 13.4 s | 13.5 s |
| `uv run m0 build` after one string literal changed | 10.9 s | 11.3 s |
| `uv run m0 build`, nothing changed | 3.3 s | 3.3 s |
| `uv run m0 test` | 4.0 s | 2.4 s |

The second row is the one a developer lives on and is a changed LITERAL on
purpose; `AGENTS.md` quotes it as 10–13 s and names `m0 test` as the fast
loop. The first-build and test figures go to `emit.py` on every run,
recorded and never gated; the after-edit row was measured by hand, at a
load average near 5.
