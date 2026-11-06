# Releasing

Releases are tag-driven: pushing a `v*` tag runs the `Release` workflow
(`.github/workflows/release.yml`), which builds the m0serve wheel for each
platform, installs and serves each one on a machine that did not build it,
and publishes a GitHub release with the wheels attached.

## A train

A minor leaves every other Thursday ([Releases](RELEASES.md) is the
policy; `uv run poe milestones` names the next train, the days to it, and
a soak that must run before it). On the day:

1. The pre-release gates below, on a cool machine, and `m0`'s
   ([Releasing m0](#releasing-m0)) when anything it bundles changed.
2. The release pull request: the version bumped, the changelog's section
   dated, and the next-train sentences moved one train on, on
   [Releases](RELEASES.md) and in `llms.txt`. `check-docs` refuses it
   until they move: once the version is bumped, they name a train that has
   left.
3. Once the tags are pushed, the train's milestone is closed, what did not
   make it moves to the next one, and the milestone two trains out is
   opened, so the next two are always open.

A train whose gates fail leaves when they pass, and the train after it
keeps its date.

**The run's order.** From a release worktree with its own venv. First,
apply every pre-release harness's anchors to the tree in memory
(`sabotage_lib.apply` over each harness's `RULES`): an anchor gone stale is
found in seconds there, and an hour into `sabotage-scaffold` otherwise.
Install the browsers before the browser gates (`uv run --no-project --with
playwright playwright install --only-shell chromium firefox webkit`), or
all four fail at launch. Then the quiet stage, on a cool machine with
nothing else running and `mediaanalysisd` stopped for it alone:
`probe-pool-fairness`, `probe-pool`, the benches when due,
`bench-linux-conclusions`, and `stress-asgi` last, since its CPU hogs'
load reaches whatever is measured next. The pool A/Bs, when owed, run
before `stress-asgi` or long after it, never straight after. The
deterministic gates and the sabotages after. The container gates
(`stress-pool`, `bench-linux-conclusions`, `autobahn`, `probe-mojo-image`,
`sabotage-mojo-image` and `sabotage-scaffold`'s `image:` rules) each run
with docker otherwise idle, and `autobahn` with a gap after the one before
it: any other use of the VM, even a `docker exec` or a container stopping,
can thin an Autobahn section. Each run is recorded in
[Release records](RELEASE_RECORDS.md).

The pre-release gates, in the run's order:

| gate | command | needs | about | SPEC |
|---|---|---|---|---|
| [Pool fairness on the reference Mac](#pool-fairness-on-the-reference-mac) | `uv run poe probe-pool-fairness` | the quiet stage, on the reference Mac | the GIL hand-off answers twenty connections in job order | E11, E34 |
| [Pool timing](#pool-timing) | `uv run poe probe-pool` | the quiet stage | the pooled row's p99 under slow views | E37 |
| [Pool A/Bs](#pool-abs) | `uv run --no-sync python scripts/probes/pool_ab.py LF24`, then `LF22` | the quiet stage, when the pool's records or its park path change | the records' stride and the park's look at its lane socket | — |
| [Benchmarks](#benchmarks) | the recorders its section lists | the quiet stage, a clean checkout, when `check-docs` says so | every table on [BENCHMARKS.md](BENCHMARKS.md) | — |
| [Linux conclusions](#linux-conclusions) | `uv run poe bench-linux-conclusions` | the quiet stage; docker idle and the `m0lin` container | whether the benchmark page's conclusions hold on Linux | — |
| [ASGI stress](#asgi-stress) | `uv run poe stress-asgi` | the quiet stage, last | the executor's slot ownership under CPU hogs, in both loop modes | L9, L29 |
| [PostgreSQL on the reference Mac](#postgresql-on-the-reference-mac) | `uv run poe test-postgres-server` | a local PostgreSQL on the reference Mac | libpq found and driven on macOS | O9–O16, O24 |
| [Deep fuzz](#deep-fuzz) | `uv run poe fuzz-request-long` | — | the request decoder, eight seeds x 250k iterations | G13 |
| [Soak driver shakedown](#soak-driver-shakedown) | `uv run poe soak-apps` | — | the soak driver against two in-tree subjects | — |
| [Datastar form in a browser](#datastar-form-in-a-browser) | `uv run poe browser-datastar-form` | Chromium | what the pinned Datastar bundle sends from a form | N12 |
| [Notes login in a browser](#notes-login-in-a-browser) | `uv run poe browser-notes-login`, `uv run poe sabotage-notes-login` | Chromium | what htmx 4 sends behind the notes app's login | N13, N22 |
| [Blobs demo in a browser](#blobs-demo-in-a-browser) | `uv run poe browser-blobs`, `uv run poe sabotage-blobs` | Chromium | the blobs demo's signals, clicks and reconnect | N16 |
| [SVG sandbox in three browsers](#svg-sandbox-in-three-browsers) | `uv run poe browser-svg-sandbox` | Chromium, Firefox and WebKit | SVGs draw, and their scripts do not run | J14 |
| [Host sabotage](#host-sabotage) | `uv run --group max poe sabotage-host` | the `max` group; two runs on the reference Mac | each rule of the Mojo host | E21–E32, N18, N19 |
| [m0 wheel sabotage](#m0-wheel-sabotage) | `uv run poe sabotage-m0-wheel` | — | each rule of the `m0` wheel's recipe and CLI | N23–N26 |
| [Scaffold sabotage](#scaffold-sabotage) | `uv run poe sabotage-scaffold` | docker idle and 9 GiB free for the `image:` rules | each rule of `m0 new` and its templates | N27, N29 |
| [Outbox-cap sabotage](#outbox-cap-sabotage) | `uv run poe sabotage-outbox-cap` | — | each outbox-cap rule against the I17 probe | I17 |
| [Parser differential sabotage](#parser-differential-sabotage) | `uv run poe sabotage-differential` | — | each request rule of the fork's parser and loop | B26 |
| [Pool lost-wake stress](#pool-lost-wake-stress) | `uv run poe stress-pool` | docker idle and the `m0lin` container | the pool's lost-wake reproducers, in three wake modes | E18 |
| [Autobahn](#autobahn) | `uv run poe autobahn` | docker idle, and a gap after the gate before it | Autobahn\|Testsuite against the pinned baseline | I13 |
| [Mojo image floor](#mojo-image-floor) | `uv run poe probe-mojo-image` | docker idle | the size and RSS of a Mojo image that only answers | — |
| [Mojo image sabotage](#mojo-image-sabotage) | `uv run poe sabotage-mojo-image` | docker idle | twelve sabotaged images against `smoke-blobs-image` | M26, M27 |

### Pool fairness on the reference Mac

`uv run poe probe-pool-fairness` runs on the reference Mac (SPEC E11,
E34). The loop thread holds no thread state while it serves
(docs/notes/detached-loop.md), so the pool's hand-off barrier is the only
thing keeping five handler threads from convoying on the GIL under a
CPU-bound view. CI runs it on Linux on every pull request, in the
`pool-fairness` job; the Mac is the arm CI does not have. Twenty
connections against `/busy` must be answered in job order, at most five
requests passed over by more than a hundred sent after them. The run's
other two arms disable the barrier (`M0_POOL_TURN=0`) and the keep rule
(`M0_POOL_TURN_KEEP=0`), and each must be out of order, which proves the
probe can see the failures it guards. A fair arm out of order is a
finding: a pause of the whole process passes nobody over, so the
machine's noise cannot cause it. A keep arm in order is a finding of
another kind. The load starves every machine measured, the Mac included.
On Linux the arithmetic behind that rests on how glibc's condition
variable queues its waiters; how macOS's queues them was not traced. If
the keep arm answers in order, record that, and run the other two arms
again with `M0_FAIRNESS_EXPECT_STARVATION=0`, which skips it.

### Pool timing

`uv run poe probe-pool` is the Mojo handler pool's timing half,
pre-release for the same reason as `stress-asgi`: a p99 table from a
shared runner is noise. The pooled row must hold single-digit
milliseconds at `slow=1` and `slow=2`; the loop-only row collapsing to
about the blocking duration is expected. A pooled p50 near a millisecond
means the loop no longer looks at a waiting job when its lane's threshold
runs out (SPEC E37). The final column has more blockers than threads, and
there the pooled row is expected to collapse too. The deterministic
halves, `test_mojo_pool` and `poe sabotage-pool`, run in CI.

### Pool A/Bs

When the pool's records or its park path change, the two pool A/Bs in
`scripts/probes/quiet-machine-ab.md` (fork review LF24 and LF22) measure
whether the pool's wake and thread records on 128-byte lines beat 64, and
what the park's look at its lane socket costs. Each is a few microseconds a request,
which only this stage's quiet machine resolves. The page names arm B's
edit for each, the builds, and the result that changes the code;
`uv run --no-sync python scripts/probes/pool_ab.py LF24` (then `LF22`)
alternates the arms, records `uptime` and the busiest processes beside
every cell, and writes its artifact under a `pool-ab-` subdirectory of
`bench/results/`. Both ran in the 1.13.0 quiet stage and found no
difference (the page has the figures), so neither is owed again until
that code changes.

### Benchmarks

The benchmarks are re-recorded when `check-docs` says so. Every table in
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
only, and Granian, the mixed workload's comparator row, is in the `bench`
group, so run `uv sync --frozen --python 3.14t --group bench` after the swap
and put `.venv/bin` first on `PATH` for the bench. The bench refuses to
start without Granian, and `render_bench_docs.py --check` refuses an
artifact of any kind that holds none of its comparator rows. Commit the artifacts and run
`poe render-bench-docs`. Its `--check` refuses a new artifact whose
non-comparator rows moved more than 5 % against the comparators' own
move since the previous artifact of that kind — the contamination
signature, and also what a real change looks like; when the code did
change, `render_bench_docs.py --accept-drift` stamps the artifact with
the comparison it accepts, and the stamp is committed beside it. The
mixed-workload artifact needs three rounds (its p99 is bimodal on a GIL
build and the table renders the min–max beside each median). The three
shell benches write no artifact when port 8080 is already held, when an
arm never answers, or when the parity check differs. `--check` refuses an
artifact whose thinnest row has fewer rounds than it says.

### Linux conclusions

`uv run poe bench-linux-conclusions` asks whether the benchmark page's
conclusions still hold on Linux. Every artifact
[BENCHMARKS.md](BENCHMARKS.md) renders is macOS arm64, and a cross-thread
handoff costs less on epoll and futex than on kqueue; the handoff is what
m0serve's two-thread shape pays for its isolation
([the note](notes/the-conclusions-on-linux.md)). The task runs the three
headline shapes in the `m0lin` container, records artifacts under
`bench/results/linux-<YYYY-MM>/`, and prints each of the page's five
conclusions as holds or INVERTS. It provisions colima the way `autobahn`
does and stops only what it started.

Read the verdict column, not the rates: absolutes carry two layers of
virtualization and the server shares the VM's cpus with the load generator,
so nothing here is comparable to the macOS tables in absolute terms. A run
whose comparison table is empty fails.

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

### ASGI stress

`uv run poe stress-asgi` is the quiet stage's last gate. Each round
drives `chunked_keepalive.py` and then `apps/asgi_bare/ws_probe.py` under
CPU hogs, thirty rounds per loop mode: once on the pump and once under
`M0_INVERTED=1`. That order is the shape that finds a slot-ownership race
in the ASGI executor: the probe's HTTP/1.0 request closes after its head,
so what follows lands on the connection slot it just released, and the
hogs make the previous task's cancellation and done-callback land late
enough to collide with its successor. On shared CI runners it passed for a
whole day with the bug live, so it runs here. The WebSocket half covers
the combination a CI flake landed in and nothing gated: the WS path, the
inversion and contention together
([the entry](notes/websocket-close-rst.md), closed 2026-08-30). Reverting
the `websocket.send` credit gate is caught on round 1, and the streamed
rounds alone do not catch it. The deterministic half of the same guard,
`poe test-shim`, runs in CI inside `test-all`. Tune with
`M0_STRESS_ITERS` and `M0_STRESS_HOGS`, and narrow a rerun to the mode a
failure named with `M0_STRESS_MODES=inverted`; it must be N of N in both
modes.

### PostgreSQL on the reference Mac

`uv run poe test-postgres-server` runs on a Mac with a local PostgreSQL
(SPEC O9–O16, O24). CI runs these on Linux on every pull request, in a
job with a service container. GitHub's service containers require a Linux
runner, so that job has no macOS arm. The rules the job pins are toolchain
behaviour, so Linux covers them; this arm catches a macOS-only difference
in how the library is found, since the search path differs by platform
and Homebrew's libpq is keg-only. Point it at a server with
`M0_PG_TEST_URL`, or let it default to `postgres:///postgres`. A role with
a password needs a URL whose host matches its `~/.pgpass` line: the
default connects over the Unix socket, which a `localhost` entry does not
cover, and fails every test with `fe_sendauth: no password supplied`,
where `M0_PG_TEST_URL=postgres://postgres@localhost:5432/postgres` passes.
It fails without a server; it never skips. Of its four files,
`test_pin.mojo` (SPEC O24) also runs in CI's `postgres-macos` job on every
pull request, against the libpq that job installs; here it runs against
the reference Mac's.

### Deep fuzz

`uv run poe fuzz-request-long` is the deep fuzz sweep, eight seeds x
250k iterations (G13's release depth; CI runs the short form every PR).

### Soak driver shakedown

`uv run poe soak-apps` is the soak driver's shakedown against the two
in-tree subjects (`apps/hybrid_mix`, `apps/asgi_bare`). This is **not** the
1.0 soak, which is third-party applications and lives in
[REAL_APP_VALIDATION.md](REAL_APP_VALIDATION.md); it is what keeps the
DRIVER honest between passes, because a harness exercised only against
somebody else's Django project rots unnoticed. It runs five populations at
once: keep-alive bursts, streams, uploads and logins, WebSocket echoes,
and abandoners that vanish mid-body and let the freed slot be recycled at
once. Its legs run the server with `--max-keepalive-requests 100`, so each
120-request keep-alive burst crosses the cap, the boundary at which the
2026-08-31 pass found its defect. It asserts a digest of every verified
body rather than its status, the shape three of the six real-app defects
had. Two of its three legs **churn the server under that
load**: one SIGTERMs and restarts it (the drain must exit 0 inside its
budget and leave no worker behind), one re-forks it through `--reload`;
connection errors are tolerated only between the signal and readiness, and
a body cut short is a failure even then. Its comparator's `--selftest` (also
`poe soak-selftest`, which is deterministic) runs first, so a green run
cannot mean the comparator checks nothing. Against a real subject the same
driver takes a manifest with a `login` block and a capture recorded from a
reference server (`--baseline`, gunicorn or uvicorn) — see
`scripts/soak_manifests/bakerydemo.json` for the worked example. Four rules
for a pass against real subjects, each from a pass that broke it:
re-record every reference capture before the pass, since the soak's own
traffic changes the applications' databases and a stale capture fails on
content; re-pin a manifest's fixture sizes with the captures; soak against
the application's scratch database, never its development one; and put the
checkout's `.venv/bin` on `PATH`, or `m0serve` embeds the system
interpreter.

### Datastar form in a browser

`uv run poe browser-datastar-form` (SPEC N12) is the Datastar form
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

### Notes login in a browser

Two gates hold the notes app's login (SPEC N13).
`uv run poe browser-notes-login` drives the notes app's login in Chromium
and prints what the bundle actually sent — the point being what htmx 4.0.0
does that no wire gate can see (SPEC N22): every swap says
`HX-Request-Type`, the header `page_or_fragment` decides by; the DELETE
carries its CSRF token as an `X-CSRF-Token` header with no `csrf` in its
URL, htmx 4 sending a DELETE's fields in the query string with no setting to
change it; and a 401 answered to a swap lands where the list was. Only
a browser can prove where the token went. `uv run poe sabotage-notes-login`
reverts each session, CSRF and htmx 4 rule, in the app and in the layer's
`grant.mojo`, `session.mojo`, `login.mojo`, `html.mojo` and `fragment.mojo`
(a rule in the layer rebuilds `m0-http` on the way in and out), and insists
the gate catches every one.

### Blobs demo in a browser

Two gates hold the blobs demo (SPEC N16). `uv run poe browser-blobs`
drives `apps/blobs` in Chromium: a patched `_`-signal must draw a slot's `clip-path`, a click must post exactly `x` and `y`, and two
tabs must reopen the stream after the server restarts, which Datastar's
default retry does not do after a clean close. It prints the body the
bundle sent. Pre-release for the reason `browser-datastar-form` is: it
needs Chromium, and the bundle is pinned (D20). Ten seconds.
`uv run poe sabotage-blobs` breaks each rule in `apps/blobs/` and requires
a gate to fail for every one: `smoke-blobs` for what reaches the wire, a twist and
both kinds of pop among them, and the kernel's unit tests for the kernel's.
Each rule rebuilds the app and reruns its gate, about six minutes in all
(`--only unit` runs the kernel's in about fifteen seconds).

### SVG sandbox in three browsers

`uv run poe browser-svg-sandbox` (SPEC J14) serves SVGs from a `--static`
mount through the tree's `bin/m0serve` and drives Chromium, Firefox and
WebKit: an `<img>`, a CSS background and a `<use>` sprite must draw, judged by pixels, and a scripted
SVG must leave no mark in the origin's storage, framed or opened directly.
Its second arm replaces the policy with one that allows script and insists
the probe then sees the script run, so the first arm's silence is evidence.
Pre-release because it needs three browsers; `smoke-serve` holds the header
on every pull request. About twenty seconds.

### Host sabotage

`uv run --group max poe sabotage-host` (SPEC E21–E32, N18, N19)
breaks each rule of the host, in `m0_host/host.mojo` and `m0_host/flags.mojo`
and in the shared pieces under it (`src/prefork.mojo`, `src/cmdline.mojo`,
`src/multiworker.mojo`, `src/views.mojo`, `accept_share.mojo` and the loop's
shutdown), and requires a gate to fail for every one: `smoke-host` for what
the wire shows, `smoke-host-threads` for the loops on threads (`--only
threads`, about six minutes), `smoke-fragment-notes` for the `ViewsApp`
adapter's worker and loop limits, `test_host.mojo`, `test_prefork.mojo`
(the pre-fork pieces both hosts share), `test_respawn.mojo` (the
supervisor's part) and `test_views.mojo`; the command line's against
`smoke-host-doctor` (`--only doctor`, about five minutes),
`test_host_flags.mojo` (`--only flags`) and `test_cmdline.mojo`; and the
parallel-runtime refusal against `smoke-parallel-runtime` (`--only
parallel`), which builds against MAX — the reason for `--group max`. The
harness's docstring lists every `--only`, and a run's last line counts the
rules it proved. On Linux every other gate holds in
that venv too: the unit tests supply the parallel runtime's fact rather
than read the one `mojo run` gives them beside MAX (ROADMAP Known issues).
**On the reference Mac the run splits in two.** A macOS build beside
`max-core` links the runtime into every binary, so E32 refuses the prefork
baselines with 78. There, run `uv run poe sabotage-host --skip parallel` (every
rule but that one, about thirty minutes) and then `uv run --group max poe
sabotage-host --only parallel`, and follow both with a plain `uv sync`,
which takes `max-core` back out; a build made while it is installed reads
as linked. A sabotage that
does not compile is reported as MISSED (does not compile)
and counted as a miss, not a catch. Pre-release because each rule reruns
the whole smoke, about fifteen minutes; `--only unit` is about a minute.

### m0 wheel sabotage

`uv run poe sabotage-m0-wheel` (SPEC N23–N26) reverts each rule
of the `m0` wheel's recipe and CLI in `packaging/m0/` and requires
`smoke-m0-wheel` to fail AND to say the expected thing; a smoke that fails
somewhere else is reported MISSED. The rules a refusal arm claims run with
the smoke's unit phase off, so the arm and not a unit test is what must
fail. Pre-release because each rule rebuilds the wheel and reruns the
smoke, a minute or two apiece, after the unsabotaged smoke (the baseline)
passes once per phase setting; `--only LABEL` runs one. Nothing here
publishes the wheel; "Releasing m0" below does.

### Scaffold sabotage

`uv run poe sabotage-scaffold` (SPEC N27, N29) breaks each rule of
`m0 new` and its templates from the template side, rebuilds the wheel,
and requires `smoke-scaffold` to fail for that template AND to say the
expected thing; its `dev:` rules run `smoke-scaffold-dev` (N30) and its
`image:` rules `smoke-scaffold-image` (N31, docker needed). Every image rule is a COLD build,
about 1.2 GB of BuildKit cache apiece; the runner prunes the records its
own run created, but under colima the host gets the space back only after
a trim, and only one that names the mount: `colima ssh -- sudo fstrim -v
/var/lib/docker` (in 1.15.0 it freed 4.3 GiB where `fstrim -av` freed 229
MiB). So run the rules outside `image:` in one pass, then each `image:`
rule alone with `--only`, a `docker builder prune` and that trim between
them, and 9 GiB free before each: an image rule writes 4.6–7.5 GiB inside
the VM before its trim. Check `df -h` first: a full disk here aborted the
docker volume's journal, and what that looks like is a column of MISSED.
Never `docker system prune`: it removes the `m0lin` container
`stress-pool` runs in. In a shell loop over the labels, give every command
`< /dev/null`, or read each label by its line number: `uv`, `docker` and
`colima ssh` read the rest of the list from standard input, and the loop
runs one label. The rules the wire holds run with the template's own tests
switched off, so the wire assertion and not `m0 test` is what must fail;
one rule runs the other way round, to show the template's test goes red.
About a minute a rule, after a baseline for each smoke the chosen rules
use (nine in a full run, the image's a cold build of its own); `--only
LABEL` runs one.

### Outbox-cap sabotage

`uv run poe sabotage-outbox-cap` reverts each outbox-cap rule
and insists the I17 probe fails; pre-release because its harness rebuilds
`bin/m0serve` per sabotage, which is minutes of compile CI does not spend.

### Parser differential sabotage

`uv run poe sabotage-differential` (SPEC B26) undoes one
request rule of the fork's parser or loop at a time (a bare LF ending the
head or a field line, obs-fold, `Content-Length` beside `Transfer-Encoding`,
a second `Host`, a `Host` value that is no uri-host, a coding before
`chunked`, CONNECT, a 100 Continue sent to an HTTP/1.0 client) and
requires `smoke-differential` to fail with the
MISMATCH line of the case that shows it. Pre-release because each of the
nine arms builds the echo server again, cold. An anchor that no
longer matches is NOT APPLICABLE: re-point it with the line it names.

### Pool lost-wake stress

`uv run poe stress-pool` (SPEC E18) runs the handler pool's lost-wake
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

### Autobahn

`uv run poe autobahn` runs Autobahn|Testsuite against the pinned baseline
(SPEC I13). Pre-release because it needs Docker and about ten minutes, and
what only it checks, close-code validation (I16), is a defect fixed once
rather than a regression that recurs (ROADMAP, "A conformance-suite
tier"). On a Mac with no daemon running the task provisions its own: it
starts a 4 GiB colima VM and stops that VM when the run ends, pass or
fail. A daemon that was already up is used as found and left running.

The route from a container to the host drops a connect now and then, with
docker idle too, and wstest runs no more cases after a connect it cannot
make and still exits 0. So the runner RESUMES a thin section, up to three
times, on the same server, when wstest reported that failure
(`Connection to ws://host.docker.internal:9301 failed (User timeout caused
connection failure.)`) and the server is alive and answering. A resume
runs only the cases no attempt has scored yet (wstest's `exclude-cases`
takes exact case ids), so each makes fewer connects than the attempt
before it. The run's last line says how many sections were resumed. The
docstring of `scripts/autobahn_runner.py` has the measurements.

- The attempts' verdicts are merged, and the merge must hold each of the
  section's pinned cases exactly once. A case scored twice fails the run:
  wstest did not take the exclusions, and the second verdict would hide
  the first.
- A thin section with any other cause fails the run, and so does one still
  thin after three resumes.
- Every thin attempt prints wstest's line and the server's log, and keeps
  both under `bin/logs/autobahn/`.
- Every verdict any attempt scored is judged, so a failure scored before a
  drop is not hidden by the resume.
- After the tally the run lists the ids of every case not scored OK, so a
  tally that moves between runs can be traced to a case.

A failure is still possible, so read its kept `wstest said:` lines before
believing it: four of the same connect message is the route again, and the
task is worth one rerun. The
runner drives the sections separately (a single pass wedges on the slot a
cap-killed connection just released), skips 9 (performance: every case
exceeds the cap) and 12/13 (`permessage-deflate`, I14), and compares in
both directions: any failure outside I17's seven cap cases
(1.1.6–1.1.8, 1.2.6–1.2.8, 10.1.1) is new and fails the run, and one of
those seven *passing* fails it too — the cap moved and SPEC I17 is wrong;
do not absorb that silently. The comparator's `--selftest` runs first, so
a green run cannot mean the parser checks nothing.

### Mojo image floor

`uv run poe probe-mojo-image` builds `deploy/mojo/Dockerfile`
for `apps/hello` and probes it from outside, recording the floor under
every Mojo image: the size and RSS of an app that only answers. The
image's properties themselves (PID 1, no interpreter, the drain) are
`smoke-blobs-image`'s on every pull request (SPEC M26, M27); this is the
figure `deploy/mojo/README.md` sets beside the blobs demo's. Needs docker
(colima locally). The target CPU follows the
daemon's architecture (`M0_TARGET_CPU` overrides, never `native`), and the
README names the architecture each figure was taken on.

### Mojo image sabotage

`uv run poe sabotage-mojo-image` (SPEC M26, M27) builds twelve
sabotaged images from a copy of the build context and requires
`smoke-blobs-image` to fail each one in the phase it names: a shell at PID
1, a stop signal the server ignores, a size written rather than measured, a
page without its footer, and so on, plus the rules the Dockerfile refuses
itself. Nothing tracked is edited. Pre-release because it is fourteen
image builds, the unsabotaged baseline of each of the two gates and then
the twelve, most of them a layer or two from the cache.

## The release steps


1. **Update [CHANGELOG.md](../CHANGELOG.md).** Move `[Unreleased]`'s
   entries into a `## [X.Y.Z] — date` section below an empty
   `## [Unreleased]`, and add a link reference at the bottom. The release
   notes point here, so this is the document of record.
2. **Bump the version.** The version is `version` in `pyproject.toml` and
   `M0SERVE_VERSION` in `packages/m0-wsgi/src/cli.mojo`; `uv.lock` and
   QUICKSTART.md's echo follow them, and `check-docs` fails on any of the
   four that disagrees or on a literal version in
   `packaging/m0serve/pyproject.toml`. Edit the first two, then run
   `uv lock` so `uv.lock`'s project version follows (a bare `uv run` later
   rewrites it otherwise), and update the `m0serve X.Y.Z` echo in
   [QUICKSTART.md](../QUICKSTART.md), which sits in a ```text block that
   `run_quickstart.py` displays and does not assert. Rebuild the package
   before the binary (`poe build-wsgi`, then `poe build-serve`):
   `M0SERVE_VERSION` is compiled into the m0-wsgi `.mojoc`, and
   `build-serve` alone links whatever version that artifact holds, so a
   `bin/m0serve --version` that prints the old number after a bump is a
   stale artifact. `smoke-serve` checks the built binary's `--version`
   against `pyproject.toml`.
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
     run can). Delete the branch afterwards: `poe check-docs` fails on a
     `release/v*` branch whose tag exists.

5. The workflow does the rest. If a build or the artifact proof fails, no
   release is created — fix, delete the tag if it was pushed
   (`git push origin :vX.Y.Z`), and re-run.

Versioning is SemVer. From 1.0 the served contract does not break in a
minor release: `m0serve`'s flags and environment variables, the
`M0-Hold`/`M0-Channel` headers, and `m0pub.publish()`. The README and the
changelog carry the same statement.

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
  on drift. `check-docs` refuses a literal version there.

- **The platform tag is measured, not declared.** `scripts/wheel_tag.py`
  reads `LC_BUILD_VERSION` and versioned glibc symbols out of the staged
  binaries and takes the strictest floor across all of them, naming the
  file that set it. Copying the toolchain's own tag would have shipped a
  `macosx_13_0` wheel containing a binary that requires macOS 26. On Linux
  the file is the toolchain's runtime library, not the binary, so the
  floor moves with the Mojo pin and not with the runner
  (docs/notes/the-floor-is-the-runtime.md).

- **There is no ABI tag, on purpose.** `m0serve` does not link libpython, so
  one wheel per platform serves CPython 3.10–3.14 including free-threaded
  builds. If a future change ever puts libpython on the link line, this stops
  being true and the wheel needs a tag per interpreter — a much larger matrix.

- **A PyPI filename is burned permanently.** It cannot be re-uploaded after a
  delete, and a yank (PEP 592) leaves the file installable by exact pin. So
  rehearse on TestPyPI first with an `rc`, upload the *identical* files to
  PyPI without rebuilding, and treat rc numbers as the cheap resource.

### Trusted publishing

PyPI and TestPyPI trust one publisher for `m0serve`: owner `codetalcott`,
repository `mojo-http`, workflow `release.yml`, environment `pypi`. The
`pypi` environment is configured in this repository's settings, and what
it enforces is below. The repository variable `PUBLISH_TO_PYPI` is
`true`; any other value skips `publish-pypi`, and a tag then produces a
GitHub release and no upload.

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

# 3. Collect the three wheels the CI run built and tested; do not rebuild them.
#    gh extracts each artifact into a directory named after it.
gh run download <run-id> --pattern 'wheel-*' --dir dist/ci

# 4. TestPyPI. Filenames there are worthless, so burn rc numbers freely.
uvx twine check --strict dist/ci/*/*.whl
uvx twine upload --repository testpypi dist/ci/*/*.whl

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

## Releasing m0

`m0`, the wheel under `packaging/m0/`, is versioned apart from the
repository (DECISIONS D43) and published by `.github/workflows/release-m0.yml`
from tags `m0-v*`. **No gate runs that workflow; only a tag does** (SPEC
N32): it is held to its rules by `check-docs` (`m0_release_problems`),
because the only rehearsal PyPI offers burns a filename. So every tag is
an execution nothing rehearsed since the last one; read its log as one.

**The records.** How each release's run went — every step below as it
went, what each gate found and cost, and the traps met — is
[Release records](RELEASE_RECORDS.md), newest first. What those runs
taught is written into the steps.

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
   commit to be tagged — the build job refuses the tag otherwise, reading
   the latest run on that commit or, for a merge commit, on the pull
   request head it merges (a merge the `automerge` label makes starts no
   workflow, so it has no run of its own; a commit that changes docs alone
   gets none either, so tag the commit that carries the code) — then locally `uv run poe sabotage-m0-wheel` and
   `uv run poe sabotage-scaffold`, read for MISSED and NOT APPLICABLE at
   the head.
2. `__version__` in `packaging/m0/src/m0/__init__.py` is the version to
   publish and its one home, and CHANGELOG says what changed for someone
   who writes applications, not for m0serve's users. Merge that.
3. Run the build job's own checks by hand on the merged commit, clean
   tree: `env -u M0_WHEEL_LOCAL uv build --wheel packaging/m0 -o /tmp/m0-rc`.
   The filename must be `m0-X.Y.Z-py3-none-any.whl`, no `+`. Build it on
   the merge commit, not the branch head: the wheel records the commit it
   was cut from (`_build_info.json`), so one built on the head differs from
   the published file by a byte, and their SHA-256s cannot be compared. Then, in an
   empty directory, `uvx --from /tmp/m0-rc/m0-*.whl m0 new probe` and read
   `probe/pyproject.toml`: it pins `m0==X.Y.Z`. Do NOT `uv sync` that
   probe and expect it to resolve — the version is not on the index yet,
   which is the one thing about a scaffold no gate can ask before a
   release exists.
4. `git tag m0-vX.Y.Z <sha> && git push origin m0-vX.Y.Z`. Approve the
   `pypi-m0` deployment when the `build` job is green and you have read
   its "cut from" line and its "Tests passed on" line. If it says `Tests`
   is still running, re-run the job once it has passed; the tag stays. A
   merge made by hand starts a `Tests` run on the merge commit, which the
   job reads first, so the tag waits for it; an `automerge` label applied
   after the pull request's run completed fires the merge only once one of
   that run's jobs is re-run. While the run waits for approval, `gh run
   view --log` cannot fetch the job's log: read it in the browser or
   through the jobs API (`gh api repos/OWNER/REPO/actions/jobs/ID/logs`),
   or download its wheel artifact and compare its SHA-256 with the local
   wheel's.

   **The order of the tags.** `m0-vX.Y.Z` first, and `vX.Y.Z` only once the
   index has the `m0` wheel and steps 5 and 6 have run against it, so the
   site the `v*` release deploys never names an `m0` the index lacks. When
   the owner cannot approve twice that day, both tags may go together at
   one commit, `pypi-m0` approved before `pypi`: the site deploys after the
   `pypi` approval, and steps 5 and 6 run after both uploads.
5. After the upload: in an empty directory, `uvx --refresh-package m0 m0
   new probe && cd probe && uv sync && uv run m0 build && ./smoke.sh`, then
   `uv run m0 image` if docker is up — the published-wheel path through
   `uv sync --frozen` in the builder, which `smoke-scaffold-image` can only
   approximate with a find-links lock. The refresh is because the index
   page is cached for 600 s: a plain `uvx` minutes after the upload can
   write a scaffold pinning the previous `m0`. Then `uvx m0 --version` and
   `uvx --from m0serve==X.Y.Z m0serve --version`, and each m0serve file on
   the index against the SHA-256 the release's `SHA256SUMS.txt` names.
   Record the run in [Release records](RELEASE_RECORDS.md); a failure here
   is a yank and a patch release, never a re-upload.
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
