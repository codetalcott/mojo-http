# m0 (the wheel): rules for changing this package

`packaging/m0/` builds the `m0` wheel: the framework's source and the CLI
that builds an application against it. The repository's `CLAUDE.md` still
applies; this page adds what is specific to the wheel, its scaffold
templates, the three `scripts/` it ships, and the six `/mojo/…` docs pages.

`packaging/m0/` builds the `m0` wheel — the framework's SOURCE and the
stdlib-Python CLI that builds an application against it (SPEC N23–N26,
D39–D43; docs/notes/the-m0-wheel.md). Pure Python, `py3-none-any`,
versioned apart from the repo (`__version__` in `src/m0/__init__.py`, its
one home; `0.x` until the layer soak). Rules:

- **Nothing is staged.** `hatch_build.py` force-includes `git ls-files` of
  the seven source trees into `m0/_mojo/<import name>/`, and the three
  `scripts/` a release build runs into `m0/_tools/`, unedited. A new
  framework file ships by being tracked; a new TREE goes in the hook's
  table AND in `scripts/m0_wheel_smoke.py`'s second spelling of it, which
  is the guard. Editing `relocate.py`, `bundle_artifact.py` or `binfmt.py`
  edits what the wheel ships — `bundle_artifact.py` finds the runtime under
  `./.venv`, which is where `uv run m0 build` has it.
- **`gated_mojo` is read from the root pin**, never written: bumping
  `mojo==X` in the root moves the wheel's table with it, and the hook
  refuses anything but one exact `==`. **`gated_max` is read the same way
  from the root's `max` dependency group** (the one `smoke-parallel-runtime`
  syncs), and `max-gated` holds an installed `max-core` to it — absent is
  a pass, since MAX is optional (D50, SPEC N41). The two storage trees ride
  because they link nothing (N39); the scaffold's `pyproject.toml` carries
  the `uv add` line for MAX with `__M0_MAX_VERSION__` substituted, the
  fourth token and `pyproject.toml`-only like the other two versions.
- **`checks.py` holds the ONE list** (`platform`, `mojo-installed`,
  `mojo-gated`, `max-gated`, `c-compiler`, `project`) that every command reads to its
  first failure and `m0 doctor` reads whole — `host_checks`' rule. Add a
  refusal THERE. Every one is 78 and one `m0: detail (fix)` line, and
  `smoke-m0-wheel` asserts the sentences WHOLE, so rewording one means
  rewording its arm.
- **mojo runs from `sys.prefix`, never `PATH`** (`paths.mojo_bin`), and
  the smoke runs every real build with a stub `mojo` first on `PATH`.
- **The C-compiler check is the name `cc` plus a link test** — mojo 1.1.0
  looks for no other name, and a `cc` that cannot link fails after the
  whole compile. `m0 test` skips it: `mojo run` links nothing.
- **Builds rename into place** (`bin/.server.next` → `bin/server`); never
  `-o` onto a binary that may be running. **One build of a project at a
  time**: a build holds `bin/.build.lock` (`flock`, dropped with its
  process) for its whole length, since every build stages at the same
  paths.
- **`m0 new` writes from REAL files** (`src/m0/templates/`, SPEC N27–N29,
  N45, D53; docs/notes/the-scaffold.md): four templates, `views`
  (htmx 4), `auth` (the `views` list behind `m0_http.login`, its `main`
  reading `APP_KEY`, `APP_PASSWORD` and `APP_SECURE` BEFORE `serve` so the
  doctor refuses what the run would; `new.py`'s `ENV_HINT` prints their
  `export`, `APP_SECURE=0` for `http://localhost`, and the common
  `deploy/fly.toml` states `APP_SECURE = "1"` beside `force_https` while
  the image states none — `smoke-scaffold`'s deploy phase signs in under
  that file's `[env]` and requires a `Secure` cookie) `board` (a list every tab shares: a POST view appends, renders and
  publishes the whole fragment through the state's `DatastarStream`, no
  producer, no database, `max_workers() -> 1`) and `live` (a
  producer and Datastar frames, its kick count kept
  in SQLite by a store the handler opens in `make` — once per worker, loop
  or pool thread, after the fork — and counted inside the kick's own
  request, so it is a committed row when the 204 is answered; a producer
  writing it back on its poll lost the kick posted just before SIGTERM,
  on CI — N40), behind a closed
  `--template`. A template compiles UNSUBSTITUTED — the app's name only
  inside string literals, TOML and Markdown, as `__M0_APP__` — which is
  what lets substitution be `str.replace`; `poe check-templates` (in
  `test-all`) builds each in place against the tree, so a layer change
  that breaks one fails in its own pull request. A new template file goes
  in `new.py`'s manifest AND in `scripts/m0_scaffold_smoke.py`'s second
  spelling; dot-files are stored as `dot-x`. `_common/AGENTS.md` is the
  product's agent page: a rule an app author needs goes THERE, once it is
  true of the layer. Run `poe sabotage-scaffold` after touching a template,
  `new.py`, `dev.py` or `image.py`; its wire rules run with the template's
  own tests off.
- **`m0 dev` builds, THEN swaps** (SPEC N30; docs/notes/dev-image-and-a-release.md):
  the old server serves through a build and after a failed one, and the
  new binary starts only once the old PID has exited (6 s, then SIGKILL,
  named). `smoke-scaffold-dev` breaks the ENTRY file for its syntax
  error: mojo 1.1.0 builds an imported module holding a malformed `def`
  nothing calls with exit 0.
- **`m0 image` checks `project` and nothing else** (N31): the compiler runs
  in the builder, and a `docker` check in the ONE list would turn every
  docker-less machine's doctor red. `smoke-scaffold-image` builds the
  scaffold's Dockerfile AS WRITTEN, `--frozen` included: the tree's wheel
  rides in `.wheels/` behind a RELATIVE `UV_FIND_LINKS` (uv records a
  relative one relatively, an absolute one absolutely) and reaches the
  builder in a base image swapped in with `--build-context`. Do not make
  the gate edit the Dockerfile; a change users need goes in the template.
  `about.json`'s `cpu` is read from the image because a cached layer
  prints nothing.
- **`release-m0.yml` runs on a tag and nothing else** (N32; `m0-v0.1.0`
  on 2026-09-21 and `m0-v0.2.0` on 2026-09-25, each green first time,
  docs/RELEASING.md recording every run — no gate exercises it) — tags `m0-v*`, environment
  `pypi-m0`, `M0_WHEEL_LOCAL` unset and never through `poe
  build-m0-wheel`. `m0_release_problems` in `check_docs.py` holds its
  rules; docs/RELEASING.md has the order. Push no `m0-v*` tag casually.
- **The Mojo stack's docs are six pages at permanent URLs** (`/mojo/…`,
  D45, SPEC N33–N35; docs/notes/the-mojo-stack-pages.md). Rewrite a page
  freely; never move one. `packaging/m0/QUICKSTART.md` is EXECUTED by
  `smoke-quickstart-mojo` (the `scaffold-dev` job) and lives under
  `packaging/` on purpose: `test.yml` ignores `docs/**` and root `*.md`,
  so there an edit to the page alone still runs it. Its `uvx m0 new` and
  bare `uv sync` lines are what `run_quickstart.py` re-points at the
  tree's wheel — reword either and the runner refuses the page — its
  `--port 8080` becomes a free port wherever a block spells it as one (a
  port named any other way is refused too), and its
  block counts are pinned in the task AND read by `check-docs`. The host
  page's refusal and flag tables, the index's command table and the two
  loop times are held to `host.mojo`, `flags.mojo`, `cli.py`, `checks.py`
  and the scaffold's `AGENTS.md` by `mojo_pages_problems`: a new
  `HostCheck`, host flag or `m0` subcommand fails `check-docs` until the
  page has it. All six are FIGURE_PAGES: a figure sits in an
  `observed:` block. A scaffold's first build must print no `warning:`
  (N34) — `check-templates` cannot see one that only the SUBSTITUTED name
  causes.
- `poe build-m0-wheel` stamps `<version>+tree` (`M0_WHEEL_LOCAL`) so an exact
  pin on the smoke's wheel can never resolve to a published one. Run
  `poe sabotage-m0-wheel` after touching `packaging/m0/`: its anchors are
  exact source lines, and its arm rules run with the unit phase OFF so the
  arm, not a unit test, is what must fail.
