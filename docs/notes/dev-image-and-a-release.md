# `m0 dev`, `m0 image`, and a release nobody has run — 2026-09-20

The third of three pull requests that let an application in Mojo be written
outside this repository. The first added the wheel and the commands that
need no template ([the-m0-wheel](the-m0-wheel.md)); the second `m0 new` and
its two templates ([the-scaffold](the-scaffold.md)). This one adds the two
commands a scaffolded app still lacked, the gate that finally builds the
scaffold's image, and the workflow that will publish the wheel. SPEC
N30–N32. Nothing is published: no tag, no upload.

## `m0 dev`: the order is the feature

A build after an edit is ten to thirteen seconds. A dev loop that stops the
server and then builds is down for all of them, and down for good when the
edit does not compile. So the order is build, THEN swap:

    save -> build (the old server still answering) -> SIGTERM the old pid
         -> wait for that pid to exit -> start the new binary

`m0 build` already renames its output into place rather than writing over a
running binary (N24), which is what makes the first arrow safe. A build that
fails changes nothing: the compiler's message is on the terminal, the last
good build is in the browser, and `m0 dev` is still watching. The wait is
six seconds — the host's five-second drain plus one — after which the old
process is SIGKILLed and named, because the new one cannot bind beside it.
How the old server ended is always said (`pid N exited 0`); without that
line, a drain that failed would be invisible from inside the loop.

The watcher is `os.walk` and `st_mtime_ns` every half second over `src/` and
`pyproject.toml`. No watcher dependency: D40's reason for a stdlib CLI holds
for this command as for the others, and at a ten-second build a half-second
poll is noise. The snapshot is taken BEFORE a build starts, so an edit saved
during a build is seen by the next poll rather than lost.

Ctrl-C reaches `m0 dev` and the server together in a terminal, since they
share a process group. The gate does not test that; it sends SIGINT to
`m0 dev` ALONE, so the only signal the server can have seen is the one
`m0 dev` sent it by pid. The terminal's shape was probed once by hand
(`killpg` with SIGINT on a session holding `uv run`, `m0 dev` and the
server): the host drains on SIGINT as on SIGTERM, `m0 dev` reports
`exited 0`, `uv run` exits 0 and nothing is left listening.

## A finding: a malformed `def` nobody calls is not an error

The gate's first syntax error was the one `smoke-m0-wheel` uses — a line
`def broken(:` appended to a source file — but appended to `src/pages.mojo`,
an IMPORTED module. `m0 build` exited 0, and `m0 dev` swapped in a new
server as it should for a build that succeeded. Probed apart from the gate,
on mojo 1.1.0:

| appended to | the text | `m0 build` |
|---|---|---|
| `src/pages.mojo` (imported) | `def broken(:` | **exit 0**, no diagnostic |
| `src/pages.mojo` (imported) | `def broken() -> Int:` with the body `return "x" +` | **exit 0**, no diagnostic |
| `src/pages.mojo` (imported) | `this is not mojo at all !!!` | exit 1 |
| `src/server.mojo` (the entry file) | `def broken(:` | exit 1, `expected argument name` |

This is one step past what CLAUDE.md already records about lazily checked
method BODIES: in an imported module, a function nothing references is not
PARSED to the point of a diagnostic. Nothing here can change that. What it
changes: the gate breaks the entry file, and the scaffold's `AGENTS.md` now
says that a green build does not vouch for a function nothing calls — a
test that calls it does, which is the advice that page already gives for
another reason.

## `m0 image`, and what it does not check

`m0 image` is `docker build -f deploy/Dockerfile -t NAME .` from the project
root and then `docker run --rm --entrypoint cat NAME /app/about.json`, so the
last line of stdout is what the image measured of itself. Three decisions,
none of them large enough for the ledger:

- **It asks for no toolchain.** The compiler runs in the builder stage, so
  of `checks.py`'s one list only `project` is asked; a Mac with docker and
  no Xcode builds the image.
- **There is no `docker` check.** The kickoff allowed one on condition that
  it live in the one list — and `m0 doctor` reads that list whole, so every
  machine without docker would have a red doctor, the macOS CI leg among
  them. Docker missing is exit 1 naming docker; docker failing is exit 1
  with its output untouched.
- **What follows `--` goes to `docker build`.** `doctor` and `dev` already
  hand the rest of the line to what they run. `--platform`, `--no-cache` and
  `--build-arg BASE=…` are things a user needs and m0 should not re-spell;
  and it is how the gate below reaches the build without editing a file.

`--target-cpu` had nowhere to go: the scaffold's Dockerfile ran the release
build bare. It is now the Dockerfile's `TARGET_CPU` build argument, empty by
default, and `about.json` gained **`cpu`** — not the argument, but what the
builder's `m0 build --release` SAID it compiled for, carried across stages.
That was forced by the gate rather than planned: its first form read
`built dist/ for generic` from docker's output, and a second local run
failed, because a cached layer prints nothing. The image now says what it
needs to run, which is the fact someone debugging a SIGILL wants.

## How the tree's wheel reaches `uv sync` inside `docker build`

The question (b) left open. A published `m0` needs nothing: the lock names
the index, and the Dockerfile's `uv sync --frozen` is written for that case.
The gate has `0.1.0+tree`, which no index serves. Probed:

- **An absolute find-links is recorded absolutely.** `UV_FIND_LINKS=/…/dist/m0
  uv sync` writes `source = { registry = "/Users/…/dist/m0" }` into
  `uv.lock`. `--frozen` in the builder could never be satisfied.
- **A relative one is recorded relatively.** With the wheel copied to
  `.wheels/` in the project and `UV_FIND_LINKS=.wheels`, the lock says
  `source = { registry = ".wheels" }` and the wheel is a bare filename —
  and `uv sync --frozen` then succeeds with NO find-links variable set,
  the lock being enough. The lock means the same thing at `/src` in the
  builder. (Written by uv 0.12.5 on the host, read by the Dockerfile's
  pinned 0.9.)
- **`.wheels/` reaches the builder through a named build context**, not
  through the Dockerfile or the `.dockerignore`: the gate builds a base
  image that is `python:3.13-slim` plus `/src/.wheels`, and passes
  `--build-context python:3.13-slim=docker-image://<that image>` — BuildKit
  replaces the `FROM` by name. `WORKDIR /src` and the `COPY` of the two
  project files land beside it.

So the scaffold's Dockerfile is built byte for byte as `m0 new` wrote it
(hashed before and after), frozen sync included, by the user's own command.
What differs from a user's build is one line of the lock, and that a
published `m0` resolves in the builder is not claimed — no gate can ask it
before one exists.

The layer cache is (b)'s uv-cache trap in another place: a rebuilt
`0.1.0+tree` is the same name and version. The base image's digest changes
with the wheel's bytes, which invalidates every layer after `FROM` — and
the gate does not take that on trust. It builds the `build` stage by name
(all cached) and compares every file under the builder venv's `m0/` with the
wheel under test. The sabotage that proves the comparison can fail rewrites
one file inside the wheel the base image carries: there is no hash for a
path wheel in the lock, so the doctored wheel installs, and the gate says
`the builder's m0/include.py is not the wheel's`.

Measured in colima on an M4 (Linux aarch64), cold: apt 9.7 s, the frozen
sync 5.4 s, the release build 13.1 s; `app_bytes` 2,953,336 and
`image_bytes` 102,047,098, `"cpu":"generic"`.

## The release workflow, written and not run

`release-m0.yml` cannot be rehearsed: PyPI burns a filename for good. It is
kept short so that it can be read instead — one trigger (`m0-v*`, which
`release.yml`'s `v*` does not match), one wheel built with `M0_WHEEL_LOCAL`
unset and NOT through `poe build-m0-wheel` (which defaults the label to
`tree`), a refusal step, one scaffold from the built wheel, and an upload
from an environment of its own. The environment is separate because the
`pypi` environment's deployment policy admits m0serve's refs and is
m0serve's publisher tuple; `pypi-m0` admits `m0-v*` tags alone.

What a rehearsal would have shown is held by `check-docs` instead
(`m0_release_problems`, N32): ten rules reverted in its selftest against the
committed text. It reads the workflows with comments stripped — its first
run failed the control, because the workflow's own comments name what the
rules forbid.

## The gates, and what breaking each rule did

`poe sabotage-scaffold` grew nineteen rules, eight for `dev.py` and eleven
for the image; each rebuilds the wheel and reruns the one smoke that holds
it. All nineteen are caught at this pull request's head — after a first run
that caught fifteen, where each of the other four was a finding about the
gate or the rule rather than about `m0`:

- **"The old server is never stopped" failed the gate with the wrong
  sentence.** The new server cannot bind beside the old one and exits, so
  the gate timed out waiting for the new literal — the same words a watcher
  that saw nothing produces. Two rules with one sentence cannot be told
  apart (the wheel's note records the same lesson), so the gate now reads
  `m0 dev`'s "the server exited on its own" during a swap and says that.
- **"Docker's failure is exit 0" was caught by the wrong arm.** Docker
  absent and docker failing went through one `return 1`, and the absent arm
  runs first. They are two rules now: the exit docker RETURNED, and the
  `OSError` when there is no docker to run.
- **`sh -c /app/server` IS `/app/server` at PID 1.** dash execs the last
  simple command of `-c`, so the sabotage built the image it meant to
  break. `/app/server; exit $?` is a list, and a shell stays at PID 1.
- **The rest of the first run's misses were the disk.** Every image rule is
  a cold build — the wheel changes, so the base image does, so every layer
  after `FROM` does — and leaves about 1.2 GB of BuildKit cache. Fourteen of
  them took the machine to 117 MiB free: `uv build` could not make a
  temporary directory, and the docker volume inside colima aborted its
  journal and answered every command with an I/O error. `docker rmi` does
  not touch the cache, `docker builder prune`'s time filter selects OLD
  records, and colima's volume returns nothing to the host until
  `fstrim`. The runner now prunes the records its own run created, by id
  and in passes (a record with a child is not reclaimable until the child
  is gone), and docs/RELEASING.md names the `fstrim`.

Three more things the runs settled:

- **Stopping the old server before the build is caught by one answer.** The
  gate counts how often the OLD literal is answered between the save and
  the swap and wants three. Under the sabotage it counted 1, not 0: the
  gate's first poll beat `m0 dev`'s own half-second one. A threshold of one
  would have passed.
- **Two rules about the swap cannot be seen from outside**, and the sabotage
  script says so rather than counting them: starting the new server before
  the old pid is gone (it drains in milliseconds with nothing connected),
  and watching `pyproject.toml` (a fourth build for one line). Both are
  `test_m0.py`'s.
- **`uv sync --frozen` dropped from the Dockerfile changes nothing a gate
  can read** — a lock that satisfies a frozen sync satisfies a plain one.
  What is held is that the file is built as written.

## Cost

`smoke-scaffold-dev` is three real builds and a failed one: 60–70 s on an
M4. It is NOT in the `smoke` job. That job is capped at 35 minutes, and on
`main` the day this was written its macOS leg took 33:00 and its Linux leg
29:42 — a minute more on macOS is a cancelled run waiting for a slow
runner. The gate needs nothing `smoke` builds (the wheel is pure Python and
the scaffold compiles from the source it carries), so it is a two-leg job of
its own, `scaffold-dev`, which starts with the run and needs no
`build-all`. The cap was not raised. `smoke-scaffold-image` is a step in
`pid1`, beside `smoke-blobs-image` and for its reason (GitHub's macOS
runners have no docker); that job took 3:26 of its 30 minutes.
