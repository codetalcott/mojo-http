# CI and the one required check: why the workflows are shaped as they are — moved out of CLAUDE.md 2026-09-28

> A design note from the engineering record, moved out of CLAUDE.md on
> 2026-09-28 (review record C11) and kept as written, with that day's
> changes to the docs gate (H4) and the CI setup (H5) applied. CLAUDE.md
> keeps each rule in a line or two and points here for the reason. The
> spec sheet's own history is [traceability](traceability.md); the
> measurement recorder's first results are
> [structured-ci-results](structured-ci-results.md).

## Measurements are recorded, not echoed

Several smokes compute a real quantity and print it — RSS growth over 10k
requests, a fast request's latency behind two slow views, sendfile's RSS
delta. A guard tells you pass or fail; it does not tell you the number has
moved from 300 KB to 11000 KB against a 12288 KB limit and is one commit from
red. `scripts/emit.py` appends each to `$M0_RESULTS` as one JSON line, and
each job that collects them renders them into its run summary (with a
**headroom** column, which is the point) and uploads them as a
`ci-results-*` artifact, through `.github/actions/record-measurements`.
Three properties are load-bearing:

- **It never fails.** Exit status is 0 whatever happens — bad argument,
  unwritable path, full disk. A recording failure must never turn a passing
  gate red, and must never be mistaken for the thing being measured.
  `scripts/bench_asgi.py` already applied this discipline to its artifact
  write; this is the same rule.
- **It is a no-op without `$M0_RESULTS`**, which is what makes a call site
  safe inside a task body with no CI conditional around it — and is also
  exactly how the whole thing could become decorative, since deleting the
  workflow's `env:` block leaves every call running, exiting 0 and recording
  nothing, with an identical job log because the `echo` beside it still
  prints. `check_ci_measurements_are_collected` refuses that, plus a
  collected-but-never-rendered file, a missing upload, and the recorder's
  own selftest dropping out of CI — per job since review record B16, when
  one job's render had lapsed unseen for two weeks.
- **`--selftest` is a CI step**, beside `warning_ratchet.py --selftest` and
  `binfmt.py --selftest`, for the reason those are: a regression in a
  recorder drops records rather than failing. It caught two real bugs while
  being written — an unserialisable value losing its whole record, and rows
  keyed so that the same metric from two runners raced instead of showing as
  two.

## The docs workflow is unfiltered, and is the one required check

`.github/workflows/docs.yml` is named `Docs`, not `Tests`, because the
automerge workflows key on that exact name. It has **no path filter**, and
that is the point: `test.yml` ignores `*.md` and `docs/**`, so the ratchet
was silent on exactly the pull requests that edit prose, and a filtered
workflow would have the same defect inverted. Unfiltered it always reports,
which is what makes it the one check `main` can require. It is not in the
automerge triggers because `QUICKSTART.md` is a file CI *executes*: a
doc-only pull request merging on a doc lint alone would land quickstart
edits that were never run. Since review record H4 its job runs
`scripts/docs_gate.sh`, the file `poe check-docs` runs; the two kept separate
lists before, and each skipped checks the other ran.

`main` is protected by a ruleset: pull request required (0 approvals), no
force push, no deletion, no bypass actor — a push to `main` is rejected with
`GH013`. It requires **exactly one status check, `check-docs`**, and
requiring more would be a mistake: by the `paths-ignore` above, a doc-only
pull request produces no `Tests` run at all, so requiring `Tests` would leave
every such pull request unmergeable on a check that never reports. The
ruleset declared no check at all until the `Docs` workflow existed.

The required context is `check-docs`, the **job** id in `docs.yml`, not
`Docs`, the workflow name; GitHub names a check run after its job. Three
edits stop it reporting — renaming the job, giving it a matrix (which
suffixes the context), or adding a path filter — and none of them fails
anything. Every pull request simply hangs on "Expected — Waiting for status
to be reported", with no bypass actor to merge past it and the fix living in
a repository setting rather than this tree. `check_required_context_intact`
in `scripts/check_docs.py` is the guard, sabotaged all three ways plus
deletion.

## Merging: the label, never repository auto-merge

A pull request carrying the `automerge` label merges itself as soon as
`Tests` passes for its current head commit. The label is the gate and it is
deliberately not a branch namespace: applying it needs write access, so a
session can open work autonomously but cannot land it. `gh pr merge --auto`
does not work here: repository auto-merge is disabled, so it errors — and it
would not gate on CI even if enabled, because auto-merge waits only on
required status checks, and the one the ruleset requires is `check-docs`,
not `Tests`.

The Dependabot gate resolves the pull request's author through the REST API
(`user.login` and `user.type`), never through `gh pr list --json author`:
the CLI renders a bot's login for display and moved it from
`dependabot[bot]` to `app/dependabot` between gh releases, so a compare
against one spelling refused every Dependabot pull request from 2026-08-17
to 2026-09-12 — a green run each time, the reason one log line nobody read.
The two refusals that are never routine on a `dependabot/` branch, not
Dependabot's or from a fork, exit 1 so the next drift is red;
`check_dependabot_gate` in `scripts/check_docs.py` pins the source and the
exit codes, sabotaged four ways in its selftest.

## The smokes are three jobs, and no job waits on another

`test.yml`'s comment on its `smoke` job carries the measurements. One job ran
30m17s green on `main` against a 35-minute cap and was cancelled at the cap
four times on slower runners (the slowest seen ran 1.45 times the usual), so
on 2026-09-21 the work was halved and each cap left at about twice the
measured run.

The halves were planned on 12.0 and 13.1 minutes on ubuntu and 13.2 and 12.8
on macOS, and no job ever ran that fast. Those figures were the smoke steps
alone, summed from a one-job run on `main` (35551249696). A job also pays its
own setup, `build-all` and serve CLI, about 1.4 minutes on ubuntu and 1.0 on
macOS. And that run's `Compile every example app` had just filled Mojo's
compile cache, so every app smoke after it compiled warm. Cold, the steps that
compile an app took about 250 seconds more on ubuntu, against the medians of
the sixteen one-job runs before the split, while the other smoke steps took 15
more: the blobs smoke went from 23 seconds to 48, fragment notes from 9 to 33.
So `smoke` ran a median of 18.5 minutes on ubuntu from its first day. By
2026-09-29 it ran 21.4, the median of that day's 15 green runs, with 22.9 the
slowest. Seven steps had arrived, about 3 minutes: the 413 that reaches a
client still uploading, MAX's runtime under each host, the accept batch, the
body timeout, the client that resets and the connections that stop reading.
The scaffold's third template, `auth` (52950e6), added 70 seconds. A 1.45x
runner puts 21.4 minutes at 31, past the cap of 30.

So the smokes are three jobs, divided by the step medians of those 15 runs.
`smoke` carries the server: its wire, its command line and its packaging.
`smoke-app-layer` carries the Mojo host and the applications on it, the m0
wheel and its scaffold. `smoke-gateway` carries the WSGI and ASGI bridges, the
mounts, the pool and `--realtime`. They come to 11.9, 12.6 and 13.5 minutes on
ubuntu and 10.7, 10.4 and 11.3 on macOS, each capped at 25. Cold, on the pull
request that divided them (#484), they ran 10.6, 13.1 and 12.2 minutes on
ubuntu and 13.9, 13.2 and 14.1 on macOS, where every leg ran about a quarter
over its steps' medians. When one passes about 15, rebalance or divide again.

A third job pays the setup again, a minute and a half. It is also a run's
seventh macOS job, and the account runs five at once, so two of a run's
macOS jobs wait: one for the first to finish (`apple-silicon`, 1.5
minutes), one for the second (`scaffold-dev`, 2 to 4). GitHub does not start
them in file order. In the two runs with six, the job that waited was a
smoke job once and `scaffold-dev` once. A job that waits ends up to 4
minutes late. The unit jobs set the run's length, at about 17 minutes cold
on ubuntu once their halves were balanced (the next section), so a waiting
smoke job (13 to 14 minutes on macOS) or `unit-tests` (14.5) ends the run
up to 2 minutes later, and `scaffold-dev` or `unit-gates` (13) about when
it would have ended anyway. When several pull requests run at once, the five
macOS runners are shared among them. Across the 76 runs since 2026-09-28
17:00, a macOS job waited a median of 4.4 minutes and a p90 of 34, and one
more job in each run adds its minute of setup to that queue.

A server's smokes stay in one job, because the smokes that compile one app
share the runner's compile cache: apps/hello's seven are in `smoke`, and so
are the counter and the accept batch, whose apps the shutdown smoke compiles
first. The shards are separate JOBS, never one job with `if: matrix.shard`,
because `scripts/spec_sheet.py` refuses a SPEC row whose cited step carries an
`if:` — a conditional step is not evidence that it ran — so the matrix form
would fail every cited row at once. Moving a step between the jobs is free:
the sheet reads step NAMES out of the file and does not care which job holds
one.

Two costs are larger than any rebalancing, and no job's to fix by moving
steps. Every step whose task depends on `build-serve` relinks `bin/m0serve`
before it runs, about 8.5 seconds each, though its job built the binary
first: 44 steps, about six minutes a leg across the jobs. The `--doctor`
smoke waited out an 8-second watchdog for each configuration that serves,
seven of them, 56 of its 77 seconds, until review record CI1: it now polls
until the server answers and allows it 2 seconds more, and an application
that answers once and then exits proves on every run that the watchdog
still reads such a server as its exit code, not as served.

No job `needs:` another, and the smokes used to: that gate put `unit-tests`
on the front of every run and caught nothing (the comment on `smoke` names
the three runs). What it really protected against — a doc-fact drift, or a
broken `build-all` lighting up every job at once — is answered by `Docs`.

No smoke job compiles the example apps. `build-apps` builds each app into a
mktemp directory and discards the binaries, but not the compile cache, which
is what made the app smokes after it faster in the one job that ran it. There
it saved most of what it cost, about 250 seconds of 300 on ubuntu. It would
cost that again in each smoke job to warm that job's cache. It is a compile
gate, and `poe test-gates` runs it in `unit-gates` on every pull request.

## The unit tests are two jobs too

`poe test-all` was one step of the `unit-tests` job until it took 34-35
minutes of that job's 40-minute cap on the ubuntu leg, and train 19 (#481)
was cancelled at the cap, green in every step it reached. The step took 6-8
minutes in late August and 14-18 by mid-September. Most of the growth was
`test-shim`: 15 seconds until 2026-09-23, then about 8 minutes on ubuntu and
13.5 on macOS. Its sabotage ran every test once per guard, so it cost tests
times guards: 9 tests and 10 guards then, 59 and 55 by 2026-09-29. Since
pull request #483 each guard runs only the test written for it, so it costs
tests plus guards, and `test-shim` takes 26 seconds on ubuntu and 33 on
macOS. Then `test-http`, which compiles `m0-http` from source once per test
file (62 files, about 575 seconds on ubuntu, 3 of them spent running
tests). Then the gates added since.

So `test-all` is now `build-all` and two halves, and CI runs each half in a
job of its own: `unit-tests` runs `poe test-packages` and `unit-gates` runs
`poe test-gates`. Locally `poe test-all` is still the whole. On the pull
request that split them (#482), cold, `unit-tests` ran 20.7 minutes on
ubuntu and 13.9 on macOS and `unit-gates` 20.1 and 19.8, against caps of
40. Two halves could not go lower while `test-shim` was 8-14 minutes in one
piece. On #483, cold, `unit-gates` ran 12.7 minutes on ubuntu and 9.4 on
macOS, and `unit-tests` 20.6 and 17.7, every run's longest job. On train 20
(#485) they ran 12.6 and 10.2 against 23.8 and 17.2; that `unit-tests`
ubuntu leg drew a Xeon 8370C, which took 1.16 times the EPYCs' time on the
same tasks.

So five tasks went from `test-packages` to `test-gates`, chosen by those
runs' cold task times, read from the `Poe =>` lines' timestamps in the
logs: the Datastar SDK's conformance and its sabotage (164-192 seconds on
ubuntu, about 115 on macOS), `test-sqlite` and `sabotage-vtab` (50-59 and
35-40), and `check-phase-stamps` (25-27 on both). None shares a compile
with a task that stayed, and `unit-gates` now installs `libsqlite3-dev`,
for the layout guard's `sqlite3.h`. What stayed is the packages' Mojo tests
but m0-sqlite's, the fork's and the host's whole-package compiles, and the
chunked decoder's trailer sabotage and fuzzer, whose compiles the
`unit-tests` steps that run them again reuse. By those runs, both jobs come
to about 16.5 minutes cold on ubuntu's EPYCs, and `unit-tests` to 14.5 and
`unit-gates` to 13 on macOS, so both are capped at 35. `test-http` is most
of `unit-tests` (563-666 seconds) and grows 20-30 seconds with each event
loop test, so that half is the one to lighten next. The split is measured,
not thematic, and moving a task between the halves is free. A task added to
`test-all`'s own sequence, beside the halves, would run locally and in no
job, so `check-docs` refuses anything `test-all` reaches that no
unconditional step does.

Both jobs restore Mojo's compile cache and save it after. The cache holds
one entry per whole program, keyed by everything the program compiles and
by the CPU it compiles for, which for `mojo run` is the host. So a warm run
skips every compile its commit left alone, on a CPU the cache has met:
`unit-tests` re-run warm on ubuntu took 9.2 minutes against 20.7 cold
(`test-http` 138 seconds against 574), from a 43 MB cache restored in 3
seconds, and 5.7-7.3 against 13.9 on macOS. GitHub's ubuntu runners are
not all one CPU model. Keyed without the CPU, two later ubuntu runs of
`unit-tests` missed every entry of the cache they restored (19.4 and 20.4
minutes, on the same sources, image and toolchain as the warm re-run),
while `unit-gates` hit both times. A one-file probe shows the key includes
the CPU compiled for: `mojo build --target-cpu apple-m1`, then `apple-m2`,
each add entries beside the host's. So the cache's key names the runner's
CPU model. A runner on a model the pull request has not met then says so in
its restore's log, instead of restoring entries it cannot use, and a cache
no longer accumulates every model's entries. The four jobs' caches come to
about 145 MB a run, compressed. But the cache is not what makes the caps
fit. GitHub scopes a cache to the pull request that saved it, and
`main`, the only scope every pull request can read, gets no push runs: the
`automerge` label merges with the workflow token, which starts no workflow.
So a pull request's first run, 70% of runs since 2026-09-20, is always
cold. An edit also makes every program that reaches the edited file cold
again, a one-line comment included, and most of the review's pull requests
edit the fork that every event-loop test reaches. A cap has to hold a cold
run.

## The warning floor

The warning ratchet's baseline stood at 68 until 2026-09-05, described in
CLAUDE.md as unfixable on the pinned toolchain, and every one of those
claims failed to reproduce when probed against that toolchain: `abi("C")` is
a function *effect* that goes before the return arrow (`m0-core/
ffi_exports.mojo`), `unsafe_alloc` is importable from `std.memory.alloc`, and
the doc-string lint accepts a summary that opens with a backticked
identifier (`` `wants_html` convenience... ``), which the style guide asks
for anyway. The baseline is 0 since, and the ratchet fails on the first
warning anyone adds.

## Sabotage anchors fail on the pull request, not locally

`scripts/pool_sabotage.py` and several other harnesses revert a rule by
matching EXACT source lines. CI runs `sabotage-pool` on Linux only, so an
edit to an anchored line in `mojo_pool.mojo` passed every local gate and
failed the pull request, the harness reporting the rule it could no longer
apply. That is why CLAUDE.md says to run the harness after touching an
anchored file and to re-point the anchor with the line. Since review record
H1 the harnesses share `scripts/sabotage_lib.py`, which also counts a
sabotage that merely breaks the build as a miss rather than a catch.
