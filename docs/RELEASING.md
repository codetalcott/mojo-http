# Releasing

Releases are tag-driven: pushing a `v*` tag runs the `Release` workflow
(`.github/workflows/release.yml`), which builds `libm0core` on Linux and
macOS, proves each artifact through the same `ctypes` smoke that CI runs on
every commit, and publishes a GitHub release with both attached.

**Before any of it: `uv run poe stress-asgi`.** The one check CI cannot
run. Each round drives `chunked_keepalive.py` and then
`apps/asgi_bare/ws_probe.py` under CPU hogs — thirty rounds per loop
mode, once on the pump and once under `M0_INVERTED=1`. That order is the
shape that finds a slot-ownership race in the ASGI executor: the probe's
HTTP/1.0 request closes after its head, so what follows lands on the
connection slot it just released, and the hogs are what make the previous
task's cancellation and done-callback land late enough to collide with
its successor. Measured on the broken build it failed on round 5 of 15;
on shared CI runners it did not fail at all for a whole day with the bug
live, which is why this is a step here rather than a job there. The
WebSocket half is there because a CI flake landed in the one combination
nothing gated — the WS path, the inversion and contention together
(ROADMAP, "The WebSocket path is not stressed", now under Recently
resolved); reverting the `websocket.send` credit gate is caught on round 1
and was not caught at all by the streamed rounds alone. The deterministic half of the same
guard, `poe test-shim`, runs in CI inside `test-all`. Tune with
`M0_STRESS_ITERS` and `M0_STRESS_HOGS`, and narrow a rerun to the mode a
failure named with `M0_STRESS_MODES=inverted`; it must be N of N in both
modes.

**And `uv run poe probe-pool`**, the Mojo handler pool's timing half —
pre-release for the same reason stress-asgi is: a p99 table from a shared
runner is noise. The pooled row must hold single-digit milliseconds at
`slow=1` and `slow=2` (the loop-only row collapsing to ~the blocking
duration is expected and is the point). On an M4 that row measured
0.2–0.3 ms through the 1.3.0 artifact and 1.5–1.6 ms at 1.4.0 and 1.5.0,
the p50 moving with it. The step is a64d370, first in 1.4.0: Mojo pool
threads register on their lane (SPEC M22), which makes the lane elastic
(M25) where it had read as all-parked and woken on every push, so a fast
job behind a busy thread now waits for the loop's stall check, whose wait
is capped at `POOL_WAKE_WAIT_MS` (1 ms) — the price M25 records paying for
the trivial route's throughput. Dated by the artifacts rather than
bisected; a figure well past 1.6 ms is a change to look at. And
the final column is the deliberate saturation boundary — more blockers
than threads — where the pooled row is EXPECTED to collapse too. The
deterministic halves, `test_mojo_pool` and `poe sabotage-pool`, run in CI.

**And `uv run poe probe-pool-fairness`** (SPEC E11): the loop thread holds
no thread state while it serves (docs/notes/detached-loop.md), so the
pool's hand-off barrier is the only thing keeping four handler threads
from convoying on the GIL under a CPU-bound view. Sixteen connections
against `/busy` must hold a single-digit-millisecond p99 and a max under a
quarter second, and the same run with the barrier disabled
(`M0_POOL_TURN=0`) must show the convoy — a max of seconds — because the
negative arm is what proves the probe can see the failure. Pre-release for
the reason above: a p99 from a shared runner is the runner's.

**And `uv run poe test-postgres-server` on a Mac with a local PostgreSQL**
(SPEC O9-O15). CI runs these on Linux every pull request, in a job with a
service container, because GitHub's service containers require a Linux
runner — a platform fact, not a preference, so there is no macOS arm to
write in the workflow. The rules the job pins are toolchain behaviour
rather than OS behaviour, so Linux is the coverage that matters; this is
the arm that would catch a macOS-only difference in how the library is
found, since the search path differs by platform and Homebrew's libpq is
keg-only. Point it at a server with `M0_PG_TEST_URL`, or let it default to
`postgres:///postgres`. A role with a password needs a URL whose host
matches its `~/.pgpass` line: the default connects over the Unix socket,
which a `localhost` entry does not cover, and fails every test with
`fe_sendauth: no password supplied` (the 1.4.0 run), where
`M0_PG_TEST_URL=postgres://postgres@localhost:5432/postgres` passes. It
fails without a server; it never skips. The three files took 26 minutes on
the 1.4.0 run and 12 seconds on the 1.5.0 run; what made the difference
was not traced, so budget for the former.

**And `uv run poe stress-pool`** (SPEC E18): the handler pool's lost-wake
reproducers, in the `m0lin` Linux container — the only place a lost pool
wake has ever been caught (`smoke-django-realtime` phase 5, 2 of 10 rounds
on the ring's first build, docs/notes/pool-ring-handoff.md; never on macOS,
whose kernel wakes every receiver parked on a datagram socket and so never
leaves one parked beside a job). Per wake mode — the GIL rules,
`M0_POOL_PARALLEL=1` (the free-threaded default, forced on the container's
GIL build) and `M0_POOL_ELASTIC=0` (the eager wakes) —
`scripts/probes/phase5_probe.py` runs that phase twenty times with a fresh
server each round and `scripts/probes/hold_race_probe.py` opens forty holds
while three clients keep the loop busy; each must be N of N. The task copies
the tree into the container and rebuilds there, so it needs Docker and the
container that `scripts/probes/linux_setup.sh`'s header creates. Pre-release
rather than CI because CI has no such container and a shared runner's
scheduler is not the one under test; `M0_STRESS_POOL_ROUNDS` and
`M0_STRESS_POOL_MODES` tune it.

**And `uv run poe bench-linux-conclusions`** — do the benchmark page's
conclusions still hold on Linux? Every artifact
[BENCHMARKS.md](BENCHMARKS.md) renders is macOS arm64, and measured
2026-09-08 two of its four headline conclusions invert there — both of the
"No" answers — because a cross-thread handoff costs less on epoll and futex
than on kqueue, and the handoff is what m0serve's two-thread shape pays for
its isolation ([the note](notes/the-conclusions-on-linux.md)). The task runs
the three headline shapes in the `m0lin` container, records artifacts under
`bench/results/linux-<YYYY-MM>/`, and prints each conclusion as holds or
INVERTS. It provisions colima the way `autobahn` does and stops only what it
started.

Read the verdict column, not the rates: absolutes carry two layers of
virtualization and the server shares the VM's cpus with the load generator,
so nothing here is comparable to the macOS tables in absolute terms. A run
whose comparison table is empty FAILS rather than reporting success — the
first version of this compared nothing, printed "no data" on every row and
exited 0, which is how a check becomes decorative.

Pre-release rather than CI, and it must stay that way: the differences that
matter are narrow (0.98x → 1.08x), and a shared four-core runner cannot
resolve a ten-percent ratio shift. `ROUNDS=1` is a shape check; the default
three is what gives the 0.8–2.1 % per-arm spreads the record cites.

`--remote user@host --provision` runs the identical arms on a rented Linux
box instead, over ssh — hardware whose cpus the load generator is not also
sharing, which is the one confound the container cannot remove. Debian 12,
because that is what the container runs and so the toolchain path is one
that already works. **A rented host bills from creation to deletion whatever
this task does**, so the session is create, provision, run, delete; the task
says so when it finishes and deletes nothing itself. Provisioning is the
slow part, so image the host once and boot from that image afterwards.

Read the per-arm spread before the verdicts. The container gives 0.8–2.1 %
through two layers of virtualization with the server sharing cores with the
client; a box that cannot beat that is not buying anything, and the
container is then the right permanent answer.

**`uv run poe autobahn`** — Autobahn|Testsuite against the pinned baseline
(SPEC I13). Pre-release because it needs Docker and ~ten minutes, and its
unique value — close-code validation, I16 — is a defect fixed once rather
than a regression that recurs (ROADMAP, "A conformance-suite tier"). On a
Mac with no daemon running the task provisions its own: it starts a 4 GiB
colima VM and stops that VM when the run ends, pass or fail — a daemon
that was already up is used as found and left running, because only what
the run started is the run's to reap (a forgotten 8 GiB VM reservation was
half of a 16 GB machine, measured 2026-09-01). The
Run it with docker otherwise idle, and that includes the gate before it:
twice a section has come back thin ("a thin section proves nothing") while
something else used the VM -- once a `docker exec` into `m0lin`, and in the
1.4.0 run `bench-linux-conclusions` stopping that container as `autobahn`
started, where the rerun alone passed 247 of 247. Run it first, or leave a
gap after the other container gates. The
runner drives the sections separately (a single pass wedges on the slot a
cap-killed connection just released), skips 9 (performance: every case
exceeds the cap) and 12/13 (`permessage-deflate`, I14), and compares in
both directions: any failure outside I17's seven cap cases
(1.1.6–1.1.8, 1.2.6–1.2.8, 10.1.1) is new and fails the run, and one of
those seven *passing* fails it too — the cap moved and SPEC I17 is wrong;
do not absorb that silently. The comparator's `--selftest` runs first, so
a green run cannot mean the parser checks nothing.

**`uv run poe fuzz-request-long`** — the deep fuzz sweep, eight seeds x
250k iterations (G13's release depth; CI runs the short form every PR).

**`uv run poe soak-apps`** — the soak driver's shakedown against the two
in-tree subjects (`apps/hybrid_mix`, `apps/asgi_bare`). This is **not** the
1.0 soak, which is third-party applications and lives in
[REAL_APP_VALIDATION.md](REAL_APP_VALIDATION.md); it is what keeps the
DRIVER honest between passes, because a harness exercised only against
somebody else's Django project rots unnoticed. It runs five populations at
once — keep-alive bursts that cross the cap on every connection, streams,
uploads and logins, WebSocket echoes, and abandoners that vanish mid-body
and let the freed slot be recycled at once — and asserts a digest of every
verified body rather than its status, which is the shape three of the six
real-app defects had. Two of its three legs **churn the server under that
load**: one SIGTERMs and restarts it (the drain must exit 0 inside its
budget and leave no worker behind), one re-forks it through `--reload`;
connection errors are tolerated only between the signal and readiness, and
a body cut short is a failure even then. Its comparator's `--selftest` (also
`poe soak-selftest`, which is deterministic) runs first, so a green run
cannot mean the comparator checks nothing. Against a real subject the same
driver takes a manifest with a `login` block and a capture recorded from a
reference server (`--baseline`, gunicorn or uvicorn) — see
`scripts/soak_manifests/bakerydemo.json` for the worked example.

**And `uv run poe browser-datastar-form`** (SPEC N12) — the Datastar form
arm in Chromium. `smoke-todo` proves the server's half on every pull
request; only a browser can prove that the attribute `Fragment[Datastar]`
emits on a `<form>` makes the pinned bundle send the form's fields when a
person presses Enter, and a wrong modifier or option there fails silently
— the page looks fine until someone types. The run renames a todo from the
keyboard, prints the two request bodies the bundle made (the form's fields
urlencoded; a bound field's action the signal store as JSON, D21) and
checks a second tab morphed. Pre-release because it needs Chromium, and
because the bundle is pinned (D20): what the run guards changes when the
pin moves, and a release is where a moved pin ships. Ten seconds.

**And the login's two pre-release gates** (SPEC N13, new in 1.3.0):
`uv run poe browser-notes-login` drives the notes app's login in Chromium
and prints what the bundle actually sent — the point being what htmx 4.0.0
does that no wire gate can see (SPEC N22): every swap says
`HX-Request-Type`, the header `page_or_fragment` decides by; the DELETE
carries its CSRF token as an `X-CSRF-Token` header with no `csrf` in its
URL, htmx 4 sending a DELETE's fields in the query string with no setting to
change it; and a 401 answered to a swap lands where the list was. Only
a browser can prove where the token went. `uv run poe sabotage-notes-login`
reverts each of the fourteen session, CSRF and htmx 4 rules (three of them
rebuild `m0-http` for `fragment.mojo`, on the way in and out) and insists
the gate catches every one. Both were missing from this page until the 1.3.0 run, which is
how a pre-release gate becomes decorative: the row says `(pre-release)` and
nothing here tells the person cutting the release to run it.

**And the blobs demo's two pre-release gates** (SPEC N16). `uv run poe
browser-blobs` drives `apps/blobs` in Chromium: a patched `_`-signal must
draw a slot's `clip-path`, a click must post exactly `x` and `y`, and two
tabs must reopen the stream after the server restarts, which Datastar's
default retry does not do after a clean close. It prints the body the
bundle sent. Pre-release for the reason `browser-datastar-form` is: it
needs Chromium, and the bundle is pinned (D20). Ten seconds. `uv run poe
sabotage-blobs` breaks each of thirty-one rules in `apps/blobs/` and
requires a gate to fail for every one: seventeen against `smoke-blobs`,
among them a twist and both kinds of pop reaching the wire, and the
kernel's fourteen against its unit tests. Each rule rebuilds the app and
reruns its gate, about six minutes in all (`--only unit` runs the
kernel's fourteen in about fifteen seconds).

**And `uv run --group max poe sabotage-host`** (SPEC E21–E32, N18, N19) —
breaks each of fifty-nine rules in `m0_host/host.mojo`, `m0_host/flags.mojo`,
`src/prefork.mojo`, `accept_share.mojo`, `multiworker.mojo` and
`views.mojo` and requires a
gate to fail for every one: twenty-three against `smoke-host`, seven
against `smoke-host-threads` (the loops on threads; `--only threads`, about
six minutes), two against `smoke-fragment-notes` (the `ViewsApp` adapter's
worker and loop limits), six against `test_host.mojo`, six against
`test_prefork.mojo` (the pre-fork pieces both hosts share), one each
against `test_respawn.mojo` and `test_views.mojo`, the command line's
twelve: seven against `smoke-host-doctor` (`--only doctor`, about five
minutes) and five against `test_host_flags.mojo` (`--only flags`), and one
against `smoke-parallel-runtime` (`--only parallel`), which builds against
MAX — the reason for `--group max`. Every other gate holds in that venv
too: the unit tests supply the parallel runtime's fact rather than read
the one `mojo run` gives them beside MAX (ROADMAP Known issues), which
until 2026-09-26 failed `test_host.mojo`'s baseline there. A sabotage that
does not compile is reported as BROKEN
and counted as a miss, not a catch. Pre-release because each rule reruns
the whole smoke, about fifteen minutes; `--only unit` is about a minute.

**And `uv run poe sabotage-m0-wheel`** (SPEC N23–N26) — reverts each rule
of the `m0` wheel's recipe and CLI in `packaging/m0/` and requires
`smoke-m0-wheel` to fail AND to say the expected thing; a smoke that fails
somewhere else is reported MISSED. The rules a refusal arm claims run with
the smoke's unit phase off, so the arm and not a unit test is what must
fail. Pre-release because each rule rebuilds the wheel and reruns the
smoke, a minute or two apiece; `--only LABEL` runs one. Nothing here
publishes the wheel; "Releasing m0" below does.

**And `uv run poe sabotage-scaffold`** (SPEC N27, N29) — breaks each rule of
`m0 new` and its two templates from the template side, rebuilds the wheel,
and requires `smoke-scaffold` to fail for that template AND to say the
expected thing; its `dev:` rules run `smoke-scaffold-dev` (N30) and its
`image:` rules `smoke-scaffold-image` (N31, docker needed — and nothing
else may touch docker while they run). Every image rule is a COLD build,
about 1.2 GB of BuildKit cache apiece; the runner prunes the records its
own run created, but under colima the host gets the space back only after
`colima ssh -- sudo fstrim -av`. Check `df -h` first: a full disk here
aborted the docker volume's journal, and what that looks like is a column
of MISSED. The rules the wire holds run with the template's own tests
switched off, so the wire assertion and not `m0 test` is what must fail;
one rule runs the other way round, to show the template's test goes red.
About a minute a rule; `--only LABEL` runs one.

**And `uv run poe sabotage-outbox-cap`** — reverts each outbox-cap rule
and insists the I17 probe fails; pre-release because its harness rebuilds
`bin/m0serve` per sabotage, which is minutes of compile CI does not spend.

**And `uv run poe probe-mojo-image`** — builds `deploy/mojo/Dockerfile`
for `apps/hello` and probes it from outside, recording the floor under
every Mojo image: the size and RSS of an app that only answers. The
image's properties themselves (PID 1, no interpreter, the drain) are
`smoke-blobs-image`'s on every pull request (SPEC M26, M27); this is the
figure `deploy/mojo/README.md` sets beside the blobs demo's. Needs docker
(colima locally) — and per the Autobahn note above, do not touch docker
while another container gate is running. The target CPU follows the
daemon's architecture (`M0_TARGET_CPU` overrides, never `native`), and the
README names the architecture each figure was taken on.

**And `uv run poe sabotage-mojo-image`** (SPEC M26, M27) — builds ten
sabotaged images from a copy of the build context and requires
`smoke-blobs-image` to fail each one in the phase it names: a shell at PID
1, a stop signal the server ignores, a size written rather than measured, a
page without its footer, and so on, plus the rules the Dockerfile refuses
itself. Nothing tracked is edited. Pre-release because it is ten image
builds, most of them a layer or two from the cache; docker otherwise idle,
as above. Both rows cited it as `(pre-release)` from the day it landed, and
this page did not name it until the 1.5.0 run.

**And the benchmarks, when `check-docs` says so.** Every table in
docs/BENCHMARKS.md renders from the newest committed artifact, and
`render_bench_docs.py --check` (inside `poe check-docs`) refuses one that
is more than a minor version behind `pyproject.toml`, was recorded on a
dirty tree, or lacks a version stamp — so the bump in step 2 fails
`check-docs` once the artifacts are two minors old. Re-record on a clean
checkout of the bumped tree with nothing else running — the two shell
benches refuse to start, and refuse to begin a round, while any process
outside their own tree is above half a core across three samples
(`scripts/bench_guard.py`), because three system daemons once depressed
the pool rows 7 % with the comparators unmoved: build `apps/hello`
to `/tmp/bench_hello_server`, then `scripts/bench_layer_split.sh`,
`poe bench-asgi-wrk`, `poe bench-asgi`, `poe bench-mojo-mount` (the table in
docs/SERVER_PERFORMANCE.md, its comparators the numpy rows),
`poe bench-host-modes` (prefork against loops on threads under the Mojo
host, the same page; its comparators the one-worker rows), and
`scripts/bench_mixed_workload.sh`
under `poe py314t-try` (the swap's rules are in WSGI_PERFORMANCE.md's
Reproducing section; `.venv-pinned/` is ignored so the parked venv does not
stamp the artifact dirty). The swap builds its venv from the default groups
only, and Granian — the mixed workload's comparator row — is the `bench`
group, so run `uv sync --frozen --python 3.14t --group bench` after the swap
and put `.venv/bin` first on `PATH` for the bench. The 1.4.0 run skipped
that step and recorded a table with no Granian row; the bench now refuses to
start without it, and `render_bench_docs.py --check` refuses an artifact of
any kind that holds none of its comparator rows. Commit the artifacts and run
`poe render-bench-docs`. Its `--check` refuses a new artifact whose
non-comparator rows moved more than 5 % against the comparators' own
move since the previous artifact of that kind — the contamination
signature, and also what a real change looks like; when the code did
change, `render_bench_docs.py --accept-drift` stamps the artifact with
the comparison it accepts, and the stamp is committed beside it. The
mixed-workload artifact needs three rounds (its p99 is bimodal on a GIL
build and the table renders the min–max beside each median).

The steps, in order:

1. **Update [CHANGELOG.md](../CHANGELOG.md).** Add a `## [X.Y.Z] — date`
   section at the top and a link reference at the bottom. The release notes
   point here, so this is the document of record.
2. **Bump `version` in `pyproject.toml`** to match, and `M0SERVE_VERSION`
   in `packages/m0-wsgi/src/cli.mojo` — `smoke-serve` asserts the two agree,
   so CI catches a bump that forgot one. (Locally, rebuild the package
   before the binary — `poe build-wsgi` then `poe build-serve` — because
   `M0SERVE_VERSION` is compiled into the m0-wsgi `.mojoc`, and
   `build-serve` alone links whatever version that artifact already holds;
   a `bin/m0serve --version` that still prints the old number after a bump
   is that, not a bump that missed.) Then run `uv lock` so `uv.lock`'s
   own project version follows (a bare `uv run` later will rewrite it
   otherwise), and update the `m0serve X.Y.Z` echo in
   [QUICKSTART.md](../QUICKSTART.md) — it is the output of a command the
   quickstart promises is executed, but it sits in a ```text block, which
   `run_quickstart.py` displays rather than asserts. `poe check-docs` fails
   on all four, so none of this is remembered by hand.
3. **Land those changes on `main`** through an ordinary PR — CI green first,
   like any change.
4. **Tag and release**, either way:
   - Push a tag (needs tag-push rights):

     ```bash
     git tag vX.Y.Z <merge-commit>
     git push origin vX.Y.Z
     ```

   - Or dispatch the `Release` workflow (Actions → Release → Run workflow)
     with `tag` and `sha` inputs — it creates the tag *and* the release in
     one run.
   - Or push a `release/vX.Y.Z` branch at the commit to release — same
     one-run behavior, with the tag named by the branch. This is the path
     for automation whose credentials can push branches but not tags, and
     whose workflow dispatches run with a capped GITHUB_TOKEN (an
     integration-dispatched run cannot create releases; a push-triggered
     run can). Delete the branch afterwards — `poe check-docs` fails on a
     `release/v*` branch whose tag exists, so this is not remembered by
     hand either. It went unremembered four times before that check
     existed.

5. **The C-ABI bundle is gated, not checked by hand.** CI runs
   `poe bundle-ffi` on every commit and the release workflow runs it again,
   and it refuses to finish unless the bundle is genuinely self-contained —
   so a release cannot ship a `libm0core` that only loads on the runner,
   which is what every release through v0.7.0 did. Nothing to do here;
   `poe bundle-ffi` locally if you want to see what ships.
   [FFI_DISTRIBUTION.md](FFI_DISTRIBUTION.md) has the history and the
   licensing position.

6. The workflow does the rest. If a build or the artifact proof fails, no
   release is created — fix, delete the tag if it was pushed
   (`git push origin :vX.Y.Z`), and re-run.

Versioning is SemVer. From 1.0 the served contract does not break in a
minor release — `m0serve`'s flags and environment variables, the
`M0-Hold`/`M0-Channel` headers, and `m0pub.publish()` — which is the
statement the README and the changelog carry. The version lives in
`pyproject.toml`, the changelog, and `M0SERVE_VERSION` — the one constant
a package carries, because `m0serve --version` has to answer something.
Nothing else may add one: `smoke-serve` cross-checks exactly that pair, so
a fourth copy would drift silently.

## The PyPI wheel

`m0serve` is published to PyPI as a platform wheel. The distribution name is
`m0serve`, not `mojo-http`: it matches the command users type, it keeps
distance from Modular's `mojo` mark, and it names what is actually in the
archive — the server binary, not the Mojo packages. The GitHub repository
keeps its own name; a repository and a distribution need not agree.

```bash
uv run poe build-wheel     # stage, measure the tag, build into dist/wheels/
uv run poe smoke-wheel     # + install it outside the tree and serve from it
```

Four properties of this that are easy to get wrong later:

- **The version is derived, never bumped.** `packaging/m0serve/pyproject.toml`
  declares `dynamic = ["version"]` and `hatch_version.py` reads the root
  `pyproject.toml`, cross-checking `M0SERVE_VERSION` and *refusing to build*
  on drift. The two copies this document already names stay the only two;
  `check-docs` fails if a third appears.

- **The platform tag is measured, not declared.** `scripts/wheel_tag.py`
  reads `LC_BUILD_VERSION` and versioned glibc symbols out of the staged
  binaries and takes the strictest floor across all of them. Copying the
  toolchain's own tag would have shipped a `macosx_13_0` wheel containing a
  binary that requires macOS 26.

- **There is no ABI tag, on purpose.** `m0serve` does not link libpython, so
  one wheel per platform serves CPython 3.10–3.14 including free-threaded
  builds. If a future change ever puts libpython on the link line, this stops
  being true and the wheel needs a tag per interpreter — a much larger matrix.

- **A PyPI filename is burned permanently.** It cannot be re-uploaded after a
  delete, and a yank (PEP 592) leaves the file installable by exact pin. So
  rehearse on TestPyPI first with an `rc`, upload the *identical* files to
  PyPI without rebuilding, and treat rc numbers as the cheap resource.

### The first upload, concretely

One-time, and only you can do these — they need accounts this repository
cannot reach:

1. PyPI → *Your projects* → **Publishing** → add a **pending** publisher:
   project `m0serve`, owner `codetalcott`, repository `mojo-http`, workflow
   `release.yml`, environment `pypi`. Repeat on TestPyPI.
2. This repository → Settings → Environments → `pypi`. It exists and is
   configured; what it enforces is below.
3. Settings → Secrets and variables → Actions → Variables → set
   `PUBLISH_TO_PYPI` to `true`. Until then `publish-pypi` is skipped, so a
   tag pushed today produces a GitHub release and no upload.

**The environment is the authorization boundary, not `PUBLISH_TO_PYPI`.**
Trusted publishing trusts the tuple (owner, repository, workflow,
environment), so anything that can make `release.yml` reach the `pypi`
environment can upload under your name. The `PUBLISH_TO_PYPI` variable and
`publish-pypi`'s wheel-set validation both live inside the repository and are
editable by anyone with write access; the environment's rules are not. Two
gates enforce it:

- **A deployment branch policy** admitting only `release/v*` branches and
  `v*` tags. Those are already the only refs whose runs can pass
  `publish-pypi`'s version check, which derives the expected version from
  `GITHUB_REF_NAME` — so this refuses nothing that used to work. It stops a
  run from any other ref reaching the upload step at all.
- **A required reviewer.** Every release now *pauses* at `publish-pypi` and
  waits for an approval on the run's page. That is not a stuck workflow: it
  is the last moment at which a permanently-burned filename can be called
  off. Approve it and the upload proceeds.

Then rehearse before anything is burned:

```bash
# 1. Bump BOTH copies to the release candidate, and let the ratchet check you.
#    (pyproject.toml `version`, cli.mojo M0SERVE_VERSION -- see above.)
uv run poe check-docs

# 2. Build and prove it locally.
uv run poe smoke-wheel

# 3. Collect the OTHER platform's wheel from a CI run rather than rebuilding
#    it -- the wheels you upload must be the wheels that were tested.
gh run download <run-id> --pattern 'wheel-*' --dir dist/wheels

# 4. TestPyPI. Filenames there are worthless, so burn rc numbers freely.
uvx twine check --strict dist/wheels/*.whl
uvx twine upload --repository testpypi dist/wheels/*.whl

# 5. The assertion that matters: pip must pick the right file out of several
#    platform wheels, from an index, on a machine that never built them.
docker run --rm python:3.12-slim-bookworm sh -c \
  'pip install -i https://test.pypi.org/simple/ m0serve && m0serve --version'
```

Only then tag for real. Upload the **identical files**, verified by sha256 —
rebuilding between the rehearsal and the release means you tested a different
artifact.

**What an rc does and does not buy.** It rehearses the whole upload path on
a filename you can afford to burn. It does **not** hide the package: pip
excludes pre-releases only when a stable version also exists, so while `rcN`
is the only version on the index, `pip install m0serve` installs it. Assume
anything uploaded is installable by anyone who finds it.

Publishing and announcing are separate acts. The first releases are
deliberately quiet: the wheel exists, the README documents `pip install
m0serve`, and nothing is posted anywhere until the remaining release gates in
[ROADMAP.md](ROADMAP.md) are done.

## Releasing m0

`m0` — the wheel under `packaging/m0/` — is versioned apart from the
repository (DECISIONS D43) and published by `.github/workflows/release-m0.yml`
from tags `m0-v*`. **No gate runs that workflow; only a tag does** (SPEC
N32): it is held to its rules by `check-docs` (`m0_release_problems`),
because the only rehearsal PyPI offers burns a filename. So every tag is
an execution nothing rehearsed since the last one; read its log as one.

**The record.** `m0 0.1.0` — tag `m0-v0.1.0` at `e6823b6`, 2026-09-21, the
workflow's first run: `build` green at the first attempt ("m0 0.1.0, cut
from e6823b6…", 488,370 bytes, byte count equal to the local step-3
wheel), `publish-pypi` green after approval. Step 1's sabotages found one
rule MISSED (failed elsewhere) — a stale sabotage, not a product defect,
fixed in #361 before the tag. Step 5 on macOS arm64: `uvx m0 new` 1.4 s,
`uv.lock` naming `m0 0.1.0` from pypi.org, first build 12.6 s with no
warning, `smoke.sh`, six tests and every doctor check green; `m0 image`
NOT run (no docker daemon that day), so the published wheel's path through
`uv sync --frozen` in a builder is still unproven and falls to the first
scaffolded app's deploy. Step 6: 8 blocks passed against the published
package.

`m0 0.2.0`: tag `m0-v0.2.0` at `5a683eb`, 2026-09-25, cut beside m0serve
1.6.0 and pushed first, so that the site the `v1.6.0` release deploys never
names an `m0` the index lacks.
- Step 1: `sabotage-m0-wheel` 22 of 22, `sabotage-scaffold` 50 of 50.
- Step 3: the local wheel was `m0-0.2.0-py3-none-any.whl`, 504,587 bytes,
  and a scaffold from it pinned `m0==0.2.0`.
- Step 4: `build` green ("m0 0.2.0, cut from 5a683eb…", 504,587 bytes,
  equal to the local wheel), and `publish-pypi` green after approval.
- Step 5 on macOS arm64: the scaffold pinned `m0==0.2.0`, and `uv.lock`
  named it from pypi.org. The first build printed no warning, and
  `smoke.sh` passed.
- **`m0 image` ran, which closes 0.1.0's open item.** The builder's
  `uv sync --frozen` fetched mojo 1.1.0 and `m0==0.2.0` from the index.
  The image was built in 32 s: 102 MB, 2.97 MB of it the app, and no
  interpreter.
- Step 6: 8 blocks passed against the published package.

### One-time, and only the owner can do these

1. PyPI → project `m0` → Settings → **Publishing** → add a trusted
   publisher: owner `codetalcott`, repository `mojo-http`, workflow
   `release-m0.yml`, environment `pypi-m0`. The project exists — a
   placeholder `0.0.1` reserved the name on 2026-09-19 — so this is an
   ordinary publisher on an existing project, not a pending one.
2. This repository → Settings → Environments → create `pypi-m0`, with a
   deployment policy admitting the tag pattern `m0-v*` and nothing else,
   and yourself as required reviewer. `pypi` cannot be shared: its policy
   admits m0serve's refs, and it is m0serve's publisher tuple. The
   environment is the authorization boundary here exactly as it is there.

### Each release

1. Everything the gates below hold is green on `main`: `Tests` for the
   commit to be tagged, then locally `uv run poe sabotage-m0-wheel` and
   `uv run poe sabotage-scaffold`, read for MISSED and NOT APPLICABLE at
   the head.
2. `__version__` in `packaging/m0/src/m0/__init__.py` is the version to
   publish — its one home — and CHANGELOG says what changed for someone
   who writes applications, not for m0serve's users. Merge that.
3. Run the build job's own checks by hand on the merged commit, clean
   tree: `env -u M0_WHEEL_LOCAL uv build --wheel packaging/m0 -o /tmp/m0-rc`.
   The filename must be `m0-X.Y.Z-py3-none-any.whl`, no `+`. Then, in an
   empty directory, `uvx --from /tmp/m0-rc/m0-*.whl m0 new probe` and read
   `probe/pyproject.toml`: it pins `m0==X.Y.Z`. Do NOT `uv sync` that
   probe and expect it to resolve — the version is not on the index yet,
   which is the one thing about a scaffold no gate can ask before a
   release exists.
4. `git tag m0-vX.Y.Z <sha> && git push origin m0-vX.Y.Z`. Approve the
   `pypi-m0` deployment when the `build` job is green and you have read
   its "cut from" line.
5. After the upload: in an empty directory, `uvx m0 new probe && cd probe
   && uv sync && uv run m0 build && ./smoke.sh`, then `uv run m0 image` if
   docker is up — the published-wheel path through `uv sync --frozen` in
   the builder, which `smoke-scaffold-image` can only approximate with a
   find-links lock. Record the result in docs/REAL_APP_VALIDATION.md or
   the release notes; a failure here is a yank and a patch release, never
   a re-upload.
6. Then the front door, verbatim against the index:
   `python3 scripts/run_quickstart.py --doc packaging/m0/QUICKSTART.md`
   with `M0_WHEEL` UNSET and port 8080 free. On every pull request the page
   runs against the tree's wheel (SPEC N33); this is the only run in which
   its first line, `uvx m0 new`, means what a reader's does. The Mojo
   stack's pages say `uvx m0 new` plainly, and a scaffold pins the `m0`
   that wrote it. The site
   deploys only on a release or a "Deploy site" dispatch: never deploy it
   with those pages in the tree and no `m0` of that version on the index.

A mojo pin bump is an m0 release: `gated_mojo` is read from the root pin at
build time (D39), so the wheel on PyPI keeps refusing the new compiler until
a new `m0` is cut from a tree whose gates ran on it.
