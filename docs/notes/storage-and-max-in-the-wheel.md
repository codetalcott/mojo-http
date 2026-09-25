# Storage and MAX in the m0 wheel — 2026-09-25

The `m0` wheel carried five source trees and no way to a database, and no
word about MAX. This round adds both, on the two decisions the rounds
before it made: `m0-sqlite` opens its library at run time (D49), so it can
ride where `m0 build` takes no link flag; and an m0 application reaches N
cores as threads (D48), so a binary that links MAX's parallel runtime has
a served shape. SPEC N39–N41 are the rows; D50 is the decision; `m0` is
`0.3.0`.

## Storage rides because it links nothing

`hatch_build.py`'s table gains `packages/m0-sqlite/src` and
`packages/m0-postgres/src`, and `smoke-m0-wheel`'s second spelling of it
gains the same two lines — the guard, as before. Nothing else about the
wheel changes: the trees are `git ls-files` of the two directories, mapped
under `m0/_mojo/m0_sqlite` and `m0/_mojo/m0_postgres`.

What makes them shippable is what they do not do. Neither names its C
library on any link line — libpq never did, libsqlite3 stopped in D49's
round — so an application's `m0 build` needs no flag, and `m0 test`, which
is `mojo run` and resolves nothing from its own image, can open a database.
The wheel smoke writes a test that does (`test_store.mojo`, in-memory
SQLite through the installed tree) into its project and requires it green
under `m0 test`; that is the property the trees ride on, held from outside.

The library still has to be on the machine. macOS has it in the shared
cache; Debian's slim image does not, so the scaffold's Dockerfile installs
`RUNTIME_LIBS` in the runtime stage — `libsqlite3-0` by default, `libpq5`
one build argument away — and records what it installed in `about.json`'s
`libs`. The image smoke asks the running container for
`/usr/lib/*/libsqlite3.so.0`, because "the storage package is in the
wheel" and "the image can open a database" are two claims.

## The `live` scaffold keeps its kick count

A template with a database in it is what shows an application author the
rules. `store.mojo` is one row in SQLite — `counters(name, value)` — and
the producer owns it: opened on the producer's own thread at its FIRST
step, never in `make`, because `make` runs before the host forks and a
SQLite connection carried across `fork()` is the one thing SQLite's own
documentation says not to do. At that first step the stored count seeds
the shared board (added, since kicks may already have landed) and the wave
is told not to react to history; after that the count is written whenever
it moved, before the pause branch, so a kick posted while nobody watches is
kept too.

`smoke.sh` restarts the server on the same file and polls `/stats` for the
kick; `smoke-scaffold` runs that script, and `sabotage-scaffold` reverts
the write and expects the restart to come back empty. The template's own
test opens the store in memory (`open()` wants a file it can put in WAL
mode) and runs under `uv run m0 test` with nothing linked, on both
platforms, which is the first thing this round wanted.

The `views` template stays in memory on purpose. Its list is the smallest
htmx example there is, and a second database template would be a second
copy of the rules above; an application that wants both starts from
`live`'s store and `views`' routes.

## MAX is a pinned companion, not a dependency

`max-core` pins its own `mojo-compiler` exactly, so a MAX beside the wrong
mojo is a second toolchain in the venv. The wheel therefore records the
pair it was gated beside: `gated_max`, read from the root's `max`
dependency group — the one `smoke-parallel-runtime` syncs — the way
`gated_mojo` is read from the root pin, refusing anything but one exact
`max-core==X`. `max-gated` joins the ONE list in `checks.py`, after
`mojo-gated`: absent, it passes saying how to add MAX; present at another
version, it refuses with the sentence naming the fix; present at the
gated version, it passes naming it. The doctor's JSON carries `gated_max`
and `max` beside their mojo twins.

The wheel smoke's refusal arm is a stub `max-core` 9.9.9 beside the REAL
mojo, so `mojo-gated` passes and the sentence is `max-gated`'s alone; a
stub, because MAX is a gigabyte of wheels and nothing of it needs to run
to read a version from metadata. What does need to run is measured where
MAX is already installed: `smoke-parallel-runtime` gained a phase that
runs the release recipe — `relocate.py`, then `bundle_artifact.py`, the two
scripts the wheel ships unedited — on a copy of the probe and requires
`libAsyncRTMojoBindings` to land beside it, then answers `--doctor` and
serves `/par` from that directory with the build venv unreachable. The
bundler discovers the closure from what the binary names rather than from
a list, which is why it needed no change: MAX's runtime sits in
`modular/lib` like the rest.

The scaffold says the rest: `pyproject.toml` carries the `uv add` line
with the gated version substituted (`__M0_MAX_VERSION__`, the fourth token,
`pyproject.toml`-only like the other two versions), and `AGENTS.md` the
four rules — the capture list on `parallelize`'s closure, where it
belongs (a producer's step, a heavy view rarely busy twice), that a binary
linking it is served as threads and refused as forked workers (E32), and
that the release build bundles its runtime.

## What building it turned up

**`uvx --from WHEEL` runs the m0 it cached, not the wheel it was handed.**
The first run of `sabotage-scaffold`'s new rule — the `__M0_MAX_VERSION__`
substitution reverted in `new.py`, the wheel rebuilt, `m0 new` run through
`uvx --offline --from dist/m0/…whl` — was MISSED: the written
`pyproject.toml` carried the version, substituted. uv keys a tool
environment by the wheel's name and version, and every smoke's wheel is
rebuilt under the one version `0.3.0+tree`, so on a machine that had run
the smoke before, `uvx` served the m0 it built the first time. Measured
with a marker printed from `new.py`: absent through a plain `uvx`, present
through `uvx --refresh-package m0` and through `--no-cache`. The venv half
of the smokes already carried `uv sync --refresh-package m0` for the same
hazard; the three `uvx` sites (the scaffold, image and dev smokes) now
carry `--refresh-package m0` too, and the rule is caught. CI's fresh runner
never saw it, which is the shape of a gate that passes with the bug live.

## What follows

An application outside the tree on `live`'s store, deployed with a volume,
is the soak this layer still lacks (`poe milestones`). Postgres in a
scaffold waits for one that needs it: the package rides, the image takes
libpq by one argument, and the rules are in `AGENTS.md`.
