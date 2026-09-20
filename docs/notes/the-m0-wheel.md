# The m0 wheel: source, an exact pair, and a CLI that refuses — 2026-09-20

Until this round an application in Mojo could be written in one place:
`apps/`, inside this repository, against `.mojoc` files a `poe` task had
built. This is the first of three pull requests that let one be written
anywhere. It adds the `m0` wheel — the framework's source and a small CLI —
and the gate that proves both from outside the tree. It does not add
`m0 new`, the templates, `m0 dev` or `m0 image`, and nothing is published.
SPEC N23–N26; decisions D39–D43.

## What was built

`packaging/m0/` is a second wheel recipe beside `packaging/m0serve/`, and a
much simpler one: pure Python, `py3-none-any`, no compiled payload. What it
carries:

- `m0/_mojo/{m0_core,m0_http,lightbug_http,m0_host,m0_datastar}/` — the five
  source trees, each renamed to the name Mojo imports it by, so an
  application compiles with ONE `-I` and no `.mojoc` anywhere;
- `m0/_tools/{relocate,bundle_artifact,binfmt}.py` — the release recipe's
  three scripts, unedited (three, not two: both of the others import
  `binfmt`);
- `m0/_build_info.json` — the release, the framework version and commit it
  was cut from, and `gated_mojo`, the one toolchain it was gated on;
- the CLI: `m0 include | build [--release] [--target-cpu] | test [FILE...] |
  doctor [--json] [-- HOST_ARGS]`.

## The wheel is git's manifest, not a directory walk

Nothing is staged or copied. The hatch build hook asks `git ls-files` for
each tree and force-includes every file it names under the renamed root.
The reason is what does NOT need maintaining: there is no exclude list. A
`__pycache__`, a stray `.mojoc`, a scratch file someone left in `src/`
cannot ship because git does not track them, and a tracked file cannot be
dropped because nothing chooses. The cost is stated in the hook's own
error: no git, no wheel.

Whether hatchling would accept a force-include map built file by file in a
hook was the one thing the design pass left open, with m0serve's
stage-then-`artifacts` shape as the fallback. It accepts it; 108 files map
in well under a second, and the fallback was not needed.

The guard against the map itself drifting is in the gate, not the recipe:
`smoke-m0-wheel` opens the wheel and requires the names under `m0/_mojo/` to
EQUAL the mapped manifest — spelled a second time, in the gate's own table,
so the two must agree — with every file byte-identical to the tree.

## The pair is a table, and the table is read

`gated_mojo` is not written anywhere. The hook reads the root pyproject's
`mojo==X` — the pin every gate in CI ran on — and refuses anything but one
exact `==`. Bumping the pin moves the table in the same commit, by
construction. The CLI compares it, by string equality, with the `mojo`
distribution installed in ITS OWN environment (`importlib.metadata`), and
runs `<sys.prefix>/bin/mojo`, never `PATH`'s: the check is a statement about
the compiler installed beside m0, so a global `mojo` earlier on `PATH` would
be a different compiler passing a check made about another.

The wheel deliberately declares no dependency on mojo (D39). The toolchain
is about 220 MB of wheels; as a `Requires-Dist` it would be downloaded
before `m0 new` wrote a file, and a mismatch would be read in a resolver's
prose rather than in a sentence that names the fix:

    m0: m0 0.1.0 is gated on mojo 1.1.0 and this environment has mojo 1.2.0 (uv add --dev 'mojo==1.1.0')

There is no override. The repository's grammar is refuse, never
warn-and-run.

## One list of checks

`checks.py` holds one ordered list — `platform`, `mojo-installed`,
`mojo-gated`, `c-compiler`, `project` — which every command that runs mojo
reads to its first failure and `m0 doctor` reads whole. It is R1's
`host_checks` rule for R1's reason: a doctor with a list of its own says
"fine" where the build refuses. Each check is a pure verdict over facts
plus the gathering of those facts, which is what lets the platform verdicts
be tested at all — no CI leg runs on a machine they refuse.

The C-compiler check is not the one first planned, on two counts the design
pass measured. mojo 1.1.0 looks for the literal name `cc` and nothing else
(`gcc` installed, `cc` removed: still "unable to find suitable c compiler";
`CC=` and a `clang` on `PATH` do not help), so a check that accepted `gcc`
would pass a machine mojo refuses. And a `cc` that exists but cannot link —
gcc without `libc6-dev` — gets past any `PATH` check and dies after the
whole compile with `ld: cannot find crti.o`. So the check is the name `cc`,
then a one-line program linked with `-lm`. macOS asks `xcode-select -p`
first, by absolute path, because `/usr/bin/cc` is a shim that opens a
dialog. `m0 test` skips the check: `mojo run` links nothing.

This retires the ROADMAP known issue "`mojo build` needs a C compiler on
Linux and nothing says so" — for an application built with `m0`. `mojo
build` by hand says what it always said.

## What building it turned up

**`bundle_artifact.py` finds the Mojo runtime under `./.venv`.** It globs
relative to the working directory, which in this repository is always the
root. Shipped unedited, that makes `m0 build --release` depend on the
project's venv being `./.venv` — which is exactly what `uv run m0 build`
gives, and what the foreign-prefix check already insists on. The gate's
project is therefore laid out as a user's is, `.venv` beside `src/`, rather
than with a venv somewhere convenient.

**A binary built from source carries its source files' paths.** The first
release assertion was the image recipe's — the build venv's path must not
appear in the binary — and it failed: `strings dist/server` names
`…/site-packages/m0/_mojo/lightbug_http/event_loop.mojo` and its
neighbours, for error locations. Those load nothing. The assertion now
reads the search path (`LC_RPATH`, `DT_RUNPATH`), which must be
`@loader_path`/`$ORIGIN` alone, and then runs the bundle from another
directory with the venv moved away, which is the real question. PR (c)'s
image will carry the builder's paths as strings the same way; they are not
a dependency.

**mojo run by absolute path misses what it looks up by name.** `.venv/bin/m0
build` printed `Failed to initialize Crashpad … unable to locate crashpad
handler executable` on every build, because the handler sits beside `mojo`
and is found through `PATH`, which an un-activated venv is not on. m0 puts
its prefix's `bin` first on the `PATH` it hands mojo. That is for mojo's
helpers; mojo itself is still named absolutely.

**Two checks with one sentence cannot be sabotaged apart.** `mojo-gated`
first answered a missing toolchain with `mojo-installed`'s own sentence, so
reverting `mojo-installed` changed nothing a gate could read. It now says
what it could not do (`no mojo to compare with the gated 1.1.0`), which
only the doctor ever prints.

## Timings

Measured by the gate on an M4, fragment_notes copied into a project outside
the tree, all-source from the installed wheel:

| what | seconds |
|---|---|
| `m0 build`, first build after install | 14.9 |
| `m0 build` after one string literal changed | 12.5 |
| `m0 test`, one file importing the framework and the app's modules | 2.1 |

The second row is the one a developer lives on, and it is a changed
LITERAL on purpose: a rebuild of an unchanged file is a cache hit nobody
waits for, and that mistake was made twice on the way here (0.74 s, then
2.5–3.5 s). Both figures go to `emit.py` on every run, recorded and never
gated.

## The gate, and what reverting each rule did

`smoke-m0-wheel` runs on every pull request, both legs; its docstring lists
the phases. The refusal arms need no network: the wrong toolchain is a
`mojo` 9.9.9 distribution zipped on the spot whose `mojo` script drops a
marker file. The same stub sits FIRST on `PATH` for every real build and
test in the gate, the marker must not exist at the end, and the stub is
then run once by name to show it could have — an absent marker from a stub
that cannot run would mean nothing.

`poe sabotage-m0-wheel` (pre-release) reverts each rule and requires the
smoke to fail AND to say the expected thing. The rules an arm claims to
hold run with the unit phase switched off: the unit tests come first and
would catch several of them alone, which is a catch but not an answer to
"does the refusal arm fail when its check is reverted?"

Twenty-two rules, all caught, at this pull request's head — after the
first run caught twenty of twenty-three and each of the other three was a
finding:

- **mojo from `PATH`** failed the smoke at "m0 build exited 1", not at the
  own-prefix assertion: a stub that runs builds nothing, so the build fails
  first and the reason is buried. The marker is now read BEFORE the exit
  code.
- **A directory walk instead of the manifest was MISSED outright.** With
  nothing untracked in the tree — which in CI is always — the two produce
  the same wheel, so the contents check could not tell them apart. The gate
  now builds a second wheel with a decoy planted in `m0-http/src` (named
  `.mojoc`, so it is ignored and never dirties the checkout) and requires
  it not to ship.
- **Writing the build straight onto `bin/server` was MISSED, and still is
  on macOS.** The design pass recorded "ETXTBSY on Linux, a killed process
  on macOS". Measured here with a hard link to the running binary: mojo
  1.1.0's link step replaces an existing output itself — a new inode, the
  old one's bytes intact — so the running server survives `-o` as well as
  it survives a rename. The gate asserts the OUTCOME on both legs (the old
  process alive and still serving the old literal; the old inode
  byte-identical), and the rename stays, because it does not depend on
  what a linker does with its output. What is not claimed is that the gate
  holds the mechanism on macOS; Linux is unmeasured. The rule is listed
  under "Not here, and why" in the sabotage script rather than counted.

Not claimed, and said so in the sabotage script and in N24: that
`--release` compiled for the baseline CPU rather than the host (the
artifact works where it was built, which is where the gate runs), and the
`relocate.py` call in the release recipe, whose removal `bundle_artifact.py`
covers by stripping foreign search paths from what it bundles.

## Decisions

D39 source in the wheel, an exact pair, no override · D40 a stdlib CLI with
a closed command line and closed exit codes, mojo from its own prefix · D41
no pixi or conda package yet · D42 deploy is a runbook, not a subcommand ·
D43 `m0` versioned apart, `0.x` until the soak. D44 (two sessionless
templates behind a closed `--template`) belongs to the next pull request.
