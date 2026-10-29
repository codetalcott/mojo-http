# Release records

How each release's run went: every step of [Releasing](RELEASING.md) as
it went for that release, what each gate found and cost, and the traps met
on the way. Newest first, from `m0` 0.1.0 (2026-09-21), the first release
of both packages together. The rules these runs taught are in Releasing
itself; a release before `m0` 0.1.0 is recorded in the
[changelog](../CHANGELOG.md) alone.

## m0 0.13.0 and m0serve 1.16.0 — 2026-10-23

`m0 0.13.0`: tag `m0-v0.13.0` at `bc74dfd`, 2026-10-23, cut beside m0serve
1.16.0. A minor release for the Mojo 1.2.0 pin (#621): `gated_mojo` moved
to 1.2.0 and `gated_max` to 26.7.0, so `m0 0.12.0` refuses a project on the
new compiler and 0.13.0 refuses one still on 1.1.0. The framework's source
changed only by the pin's renames.

- Step 1: `sabotage-m0-wheel` 26 of 26 (620 s). `sabotage-scaffold` 84 of
  84: the 72 rules outside `image:` in one run (1418 s), then each of the
  twelve `image:` rules with `--only` (70–118 s each), with a builder prune
  and an `fstrim` between them. Before the run, every anchor of the eight
  pre-release harnesses was applied to the tree in memory
  (`sabotage_lib.apply` over each harness's `RULES`): 248 rules, none
  stale, after #621 had touched 56 Mojo files. Disk was the constraint:
  2.2 GiB free an hour before the run, 6 GiB at its start. The image rules
  waited for 9 GiB, since in 1.15.0 each wrote 4.6–7.5 GiB inside the VM
  before its trim; deleting two caches the owner approved, and space freed
  elsewhere on the machine, got there.
- Step 3: the local wheel, built on the merge commit, was
  `m0-0.13.0-py3-none-any.whl`, 722,926 bytes, its `_build_info.json`
  naming `bc74dfd`, a clean tree, mojo 1.2.0 and max-core 26.7.0; a
  scaffold from it pinned `mojo==1.2.0` and `m0==0.13.0`.
- Step 4: the release pull request (#624) was merged by hand, so `build`
  read the merge commit's own `Tests` run. It printed `m0 0.13.0, cut from
  bc74dfd…` and was green at the first attempt. Its wheel artifact, the
  local wheel and the file on the index share one SHA-256 (`503d2c04…`).
- The tags went out in order: `v1.16.0` once `m0 0.13.0` was on the index,
  the owner approving each upload.
- Step 5 on macOS arm64: `uvx --refresh-package m0 m0 new probe` pinned
  `m0==0.13.0`, and `uv.lock` named it from pypi.org. The first build took
  12 s with no warning, `smoke.sh` and `m0 test` passed, and every `m0
  doctor` check passed. `m0 image` built in 26 s: 103.5 MB, 2.90 MB of it
  the app, `libsqlite3-0` installed and no interpreter. The builder's `uv
  sync --frozen` installed `m0==0.13.0` and `mojo-compiler==1.2.0` from the
  index.
- Step 6: 8 blocks passed against the published package. `uvx m0
  --version` read `m0 0.13.0`, and `uvx --from m0serve==1.16.0 m0serve
  --version` read `m0serve 1.16.0`.
- m0serve 1.16.0: `v1.16.0` at `bc74dfd`. The Release run built the three
  wheels, inspected them, consumed each on a machine that did not build it,
  published the GitHub release, and uploaded after approval. Each file on
  the index has the SHA-256 the release's `SHA256SUMS.txt` names, each
  carries `LICENSE.max.txt` in both of its licence locations (the first
  release to ship the MAX License beside the runtime;
  [FFI_DISTRIBUTION](FFI_DISTRIBUTION.md)), and the site deployed after it.
- The pre-release run, for the record: every gate in this page, from the
  main checkout. `probe-pool-fairness` (32 s), `probe-pool` (891 s; pooled
  p99 0.2 ms at slow 0, 1 and 2), and `stress-asgi` 30 of 30 in both modes
  (191 s). `stress-pool` held 20 of 20 rounds and 40 of 40 holds in all
  three wake modes, `autobahn` held its baseline, `sabotage-host` caught 69
  of 69, and `bench-linux-conclusions` held all five conclusions. The four
  browser gates failed at launch until Playwright 1.64.1's browsers were
  installed (`playwright install --only-shell chromium firefox webkit`), and
  then passed: install them before stage A. The six macOS bench kinds were
  two minors stale and were re-recorded. Three first recordings were
  discarded, none for the code. `host-modes` read 6–8% low on its
  multi-loop rows while another session's browser tests ran, and an
  interleaved A/B of v1.15.0 on Mojo 1.1.0 against this tree on 1.2.0 put
  1.2.0 at parity or ahead. One `mixed-workload` row was low in two of its
  three rounds. In `asgi-wrk-hello`, m0serve's arm was "never healthy" and
  the bench still wrote its artifact, which `bench-linux-conclusions`
  refused as having no data. m0serve refuses a port another process holds
  on the wildcard, while uvicorn, binding 127.0.0.1, still serves there; a
  bench that writes an artifact over a never-healthy arm is a defect owed a
  fix.

## m0 0.12.0 and m0serve 1.15.0 — 2026-10-11

`m0 0.12.0`: tag `m0-v0.12.0` at `8e935fa`, 2026-10-11, cut beside m0serve
1.15.0. A minor release for the fixes of the 2026-10-10 review of the
gateway, the database packages, the `m0` wheel and m0-core (#615), and the
two issues reported against 1.14.0 (#611, #612): a WSGI header forged
through an underscore name, m0-sqlite's NULL handle after `close()`, a
drain that waited for a request nobody had made, and the wheel's libpython
search. The `m0` wheel ships the framework's source and the fixed
templates.

- Step 1: `sabotage-m0-wheel` 26 of 26 (633 s). `sabotage-scaffold` 84 of
  84: the 72 rules outside `image:` in one run (2086 s), then each of the
  twelve `image:` rules with `--only` (73–178 s each), with a `docker
  builder prune` and an `fstrim -v /var/lib/docker` between them. Two rules
  read NOT APPLICABLE in the first run, `new: writes over what is there`
  and `image: --tag is ignored`: #615 had moved the lines they anchor and
  re-run `sabotage-m0-wheel`, but not this harness, whose image rules need
  docker. Both were re-pointed in the release pull request and caught when
  re-run alone. The run began at 8.4 GiB free. Naming the mount
  (`fstrim -v /var/lib/docker`) returned 4.3 GiB where `fstrim -av`
  returned 229 MiB.
- Step 3: the local wheel, built on the merge commit, was
  `m0-0.12.0-py3-none-any.whl`, 722,663 bytes, its `_build_info.json`
  naming framework 1.15.0, `8e935fa` and a clean tree; a scaffold from it
  pinned `m0==0.12.0`.
- Step 4: the release pull request (#616) was merged by the `automerge`
  label as its `Tests` run passed, and `build` read the pull request
  head's run (`ff8c150`). It printed `m0 0.12.0, cut from 8e935fa…` and was
  green at the first attempt. Its wheel artifact had the local wheel's
  SHA-256 (`ca9ca02a…`), as does the file on the index.
- The tags went out in 1.14.0's order: the owner was away overnight, so
  `v1.15.0` was pushed a few minutes after `m0-v0.12.0`, at the same
  commit, and the owner approved `pypi-m0` before `pypi`. Steps 5 and 6 ran
  after both uploads.
- Step 5 on macOS arm64: `uvx --refresh-package m0 m0 new probe` pinned
  `m0==0.12.0`, and `uv.lock` named it from pypi.org. The first build took
  11 s, `smoke.sh` and `m0 test` passed, and every `m0 doctor` check
  passed. `m0 image` built in 30 s: 103.6 MB, 2.92 MB of it the app,
  `libsqlite3-0` installed and no interpreter.
- Step 6: 8 blocks passed against the published package. `uvx m0
  --version` read `m0 0.12.0`, and `uvx --from m0serve==1.15.0 m0serve
  --version` read `m0serve 1.15.0`.
- m0serve 1.15.0: `v1.15.0` at `8e935fa`. The Release run built the three
  wheels (`macosx_13_0_arm64`, `manylinux_2_35_aarch64`,
  `manylinux_2_35_x86_64`), inspected them, consumed each on a machine
  that did not build it, published the GitHub release, and uploaded after
  approval. Each file on the index has the SHA-256 the release's
  `SHA256SUMS.txt` names, and the site deployed after it.
- The pre-release run, for the record: every gate in this page, from a
  release worktree with its own venv. Neither the benches nor the soaks
  were due: both stood at 1.14.0, one minor behind. The quiet stage ran
  before the sabotages, once another agent's `node` jobs had stopped:
  `probe-pool-fairness` (32 s), `probe-pool` (896 s; pooled p99 0.2, 0.3
  and 0.2 ms at slow 0, 1 and 2), `stress-asgi` 30 of 30 in both modes
  (191 s), and `bench-linux-conclusions` (637 s), whose conclusions all
  held. `stress-pool` held 20 of 20 rounds and 40 of 40 holds in all three
  wake modes, and `sabotage-host` caught 69 of 69. The pool A/Bs were not
  owed: neither the pool's records nor its park changed since 1.14.0.

## m0 0.11.0 and m0serve 1.14.0 — 2026-10-10

`m0 0.11.0`: tag `m0-v0.11.0` at `e4d2115`, 2026-10-10, cut beside m0serve
1.14.0. A minor release for the code-quality review of `m0-http` (#605,
#606, #607): the keep-alive cap carried to a stream's end, a reload that no
longer orphans a worker, a static mount's weak `If-None-Match`, a `Range`
bound read as digits alone, and package re-exports and two fork names an
application could import, removed or renamed.

- Step 1: `sabotage-m0-wheel` 26 of 26 (657 s). `sabotage-scaffold` 81 of
  81: the 69 rules outside `image:` in one run (1480 s), then each of the
  twelve `image:` rules with `--only` (69–302 s each), each label read by
  its line number, with a `docker builder prune` and an `fstrim` between
  them. The run began at 12.7 GiB free, and the disk stayed above that.
- Step 3: the local wheel, built on the merge commit, was
  `m0-0.11.0-py3-none-any.whl`, 715,558 bytes, its `_build_info.json`
  naming framework 1.14.0, `e4d2115` and a clean tree; a scaffold from it
  pinned `m0==0.11.0`.
- Step 4: the release pull request (#608) was merged by the `automerge`
  label as its `Tests` run passed, so no run started on the merge commit,
  and `build` read the pull request head's (`702a27a`). `build` was green
  at the first attempt, and `publish-pypi` green after approval. The build
  job's log was read through the jobs API while the run waited (`gh api
  repos/OWNER/REPO/actions/jobs/ID/logs`), and its wheel artifact had the
  local wheel's SHA-256 (`86434272…`), as does the file on the index.
- **The tags went out in a different order.** The owner was away overnight,
  so `v1.14.0` was pushed a minute after `m0-v0.11.0`, at the same commit,
  rather than once the index had the `m0` wheel. Both runs then waited at
  their environments, and the owner approved `pypi-m0` before `pypi`. The
  site deploys when the Release run completes, which is after the `pypi`
  approval, so it never described an `m0` the index lacked. What moved is
  steps 5 and 6, which ran after both uploads instead of between them.
- Step 5 on macOS arm64: `uvx --refresh-package m0 m0 new probe` pinned
  `m0==0.11.0`, and `uv.lock` named it from pypi.org. The first build took
  11 s and printed no warning, `smoke.sh` and `m0 test` passed, and every
  `m0 doctor` check passed, `scaffold` naming no file. `m0 image` built in
  31 s: 103.6 MB, 2.92 MB of it the app, `libsqlite3-0` installed and no
  interpreter, the builder installing `m0==0.11.0` and mojo 1.1.0 from the
  index.
- Step 6: 8 blocks passed against the published package. `uvx m0
  --version` read `m0 0.11.0`, and `uvx --from m0serve==1.14.0 m0serve
  --version` read `m0serve 1.14.0`.
- m0serve 1.14.0: `v1.14.0` at `e4d2115`. The Release run built the three
  wheels (`macosx_13_0_arm64`, `manylinux_2_35_aarch64`,
  `manylinux_2_35_x86_64`), inspected them, consumed each on a machine
  that did not build it, published the GitHub release, and uploaded after
  approval. Each file on the index has the SHA-256 the release's
  `SHA256SUMS.txt` names, and the site, the demo and the blobs demo
  deployed after it.
- The pre-release run, for the record: every gate in this page, from a
  release worktree with its own venv. Another agent's `node` jobs held one
  to nine cores in bursts through the evening, so the quiet stage ran
  last, once they had stopped. It ran `probe-pool-fairness` (32 s),
  `probe-pool` (894 s; pooled p99 0.1, 0.2 and 0.2 ms at slow 0, 1 and 2),
  the six macOS bench kinds, two minors behind and re-recorded with every
  figure within noise, `stress-asgi` 30 of 30 in both modes (192 s), and
  `bench-linux-conclusions` (637 s). The conclusions held. ASGI against
  uvicorn+uvloop per core read 0.99 on macOS against 0.91 on Linux, both
  now below parity. `stress-pool` held 20 of 20 rounds and 40 of 40 holds
  in all three wake modes. `sabotage-host` caught 69 of 69, one rule fewer
  than in 1.13.0, since #605 merged the host's two serve paths. Both soaks
  stood at 1.11.0, three minors behind, and were re-run on the release
  branch (REAL_APP_VALIDATION.md): the server's on checkouts made fresh
  after a reboot, 206,933 responses verified, and the application layer's
  on unotes, built unchanged by this wheel's local twin. The pool A/Bs were
  not owed: #605 restructured the pool's spin loop, but neither the
  records' strides nor the park's look.

## m0 0.10.0 and m0serve 1.13.0 — 2026-10-09

`m0 0.10.0`: tag `m0-v0.10.0` at `1258b28`, 2026-10-09, cut beside m0serve
1.13.0 and pushed first; `v1.13.0` was pushed once the index had it and
the scaffold and quickstart had run against it. A minor release for the
rest of the 2026-10 review of the lightbug fork: a pipelined burst that
held the event loop (A41), a `100 Continue` cut short on Linux (A42), a
lost `408` (A5), and the fork's unused code removed, which takes names a
Mojo application could import.

- Step 1: `sabotage-m0-wheel` 26 of 26 (613 s). `sabotage-scaffold` 81 of
  81: the 69 rules outside `image:` in one run (1385 s), then each of the
  twelve `image:` rules with `--only` (70–130 s each), a `docker builder
  prune` and an `fstrim` between them. The first pass over the image rules
  ran one rule and stopped: the label list fed a `while read` loop, and
  the trim's `colima ssh` read the rest of it from standard input. Read
  each label by its line number, or give every command in such a loop
  `< /dev/null`, `colima` and `docker` as well as `uv`.
- Step 3: the local wheel, built on the merge commit, was
  `m0-0.10.0-py3-none-any.whl`, 710,717 bytes, its `_build_info.json`
  naming framework 1.13.0, `1258b28` and a clean tree; a scaffold from it
  pinned `m0==0.10.0`.
- Step 4: the release pull request (#603) was merged by the `automerge`
  label, applied after its `Tests` run had completed, so one job of that
  run was re-run to fire the merge; no `Tests` run started on the merge
  commit. `build` was green at the first attempt, and `publish-pypi`
  green after approval. Its wheel artifact had the local wheel's SHA-256
  (`47152663…`), and so does the file on the index.
- Step 5 on macOS arm64: `uvx --refresh-package m0 m0 new probe` pinned
  `m0==0.10.0` at the first try, and `uv.lock` named it from pypi.org.
  The first build took 12 s and printed no warning, `smoke.sh` and `m0
  test` passed, and every `m0 doctor` check passed. `m0 image` built in
  30 s with the base layers present: 103.6 MB, 2.92 MB of it the app,
  `libsqlite3-0` installed and no interpreter.
- Step 6: 8 blocks passed against the published package.
- m0serve 1.13.0: `v1.13.0` at `1258b28`. The Release run built the three
  wheels (`macosx_13_0_arm64`, `manylinux_2_35_aarch64`,
  `manylinux_2_35_x86_64`), inspected them, consumed each on a machine
  that did not build it, published the GitHub release, and uploaded after
  approval; `uvx --from m0serve==1.13.0 m0serve --version` answers
  `m0serve 1.13.0`.
- The pre-release run, for the record: every gate in this page, from a
  release worktree with its own venv, the quiet stage first with
  `mediaanalysisd` stopped: `probe-pool-fairness` (32 s), `probe-pool`
  (884 s; pooled p99 0.1, 0.2 and 0.2 ms at slow 0, 1 and 2),
  `stress-asgi` 30 of 30 in both modes (190 s), `bench-linux-conclusions`
  (654 s; the four conclusions held, and ASGI against uvicorn+uvloop per
  core read INVERTS again, macOS 1.01 against Linux 0.92). The two pool
  A/Bs the fork review owed (LF24, LF22) ran in the same stage and found
  no difference; their first pass, straight after `stress-asgi`, was
  discarded for the load its hogs left. `stress-pool` held 20 of 20
  rounds and 40 of 40 holds in all three wake modes, and `sabotage-host`
  70 of 70, the two gates the review's lanes could not run.
  `check-docs` asked for no bench re-record.

## m0 0.9.1 and m0serve 1.12.1 — 2026-10-08

`m0 0.9.1`: tag `m0-v0.9.1` at `9d06423`, 2026-10-08, cut beside m0serve
1.12.1 and pushed first; `v1.12.1` was pushed once the index had it and
the scaffold and quickstart had run against it. A patch release for the
fixes of the 2026-10-07 review of the lightbug fork (#577): an overlong
UTF-8 header value that split a response head (G19), a request head the
parser and the loop ended in different places (B12), and the macOS shared
page's mode (G20), among others. The `m0` wheel ships the framework's
source, so this is how an `m0` application gets them.

- Step 1: `sabotage-m0-wheel` 26 of 26 (631 s). `sabotage-scaffold` 81 of
  81: the 69 rules outside `image:` in one run (1415 s), then each of the
  twelve `image:` rules with `--only` (73–131 s each), a `docker builder
  prune` and an `fstrim` between them. The run began at 4.3 GiB free and
  went no lower than 3.4 GiB; nothing was removed to make room, and the
  2 GiB guard never tripped.
- Step 3: the local wheel, built on the merge commit, was
  `m0-0.9.1-py3-none-any.whl`, 699,366 bytes, its `_build_info.json`
  naming framework 1.12.1, `9d06423` and a clean tree; a scaffold from it
  pinned `m0==0.9.1`.
- Step 4: the release pull request (#578) was merged by the `automerge`
  label, so no `Tests` run started on the merge commit. `build` was green
  at the first attempt, and `publish-pypi` green after approval. The
  job's log could not be read while the run waited, so its wheel artifact
  was downloaded instead: the local wheel's SHA-256. The file on the index
  has the same size and SHA-256.
- Step 5 on macOS arm64: `uvx --refresh-package m0 m0 new probe` pinned
  `m0==0.9.1` at the first try. The first build took 12 s, `smoke.sh`
  passed, and every `m0 doctor` check passed, `scaffold` naming no file.
  `m0 image` built in 34 s with the base layers present: 103.6 MB, 2.93 MB
  of it the app, `libsqlite3-0` installed and no interpreter.
- Step 6: 8 blocks passed against the published package.
- m0serve 1.12.1: `v1.12.1` at `9d06423`. The Release run built the three
  wheels (`macosx_13_0_arm64`, `manylinux_2_35_aarch64`,
  `manylinux_2_35_x86_64`), inspected them, consumed each on a machine
  that did not build it, published the GitHub release, and uploaded after
  approval; `uvx --from m0serve==1.12.1 m0serve --version` answers
  `m0serve 1.12.1`.
- The pre-release run, for the record: every gate in this page, from a
  release worktree with its own venv, the quiet stage FIRST on a cold
  machine with `mediaanalysisd` stopped for that stage alone:
  `probe-pool-fairness` (32 s), `probe-pool` (899 s; pooled p99 0.16,
  0.21 and 0.18 ms at slow 0, 1 and 2), `stress-asgi` 30 of 30 in both
  modes (191 s), `bench-linux-conclusions` (661 s). The four conclusions
  held; ASGI against uvicorn+uvloop per core read INVERTS again, macOS
  1.01 against Linux 0.91, with spreads up to 7.9 % on the executor arm.
  `autobahn`'s totals matched 2026-08-31's, so the parser fix (I34)
  moved no case. `check-docs` asked for no bench re-record.

## m0 0.9.0 — 2026-10-07

`m0 0.9.0`: tag `m0-v0.9.0` at `c977202`, 2026-10-07, the first `m0`
published on its own rather than beside an m0serve release. It carries
#569: the `board` template, `m0 new .`, and `live`'s stream behind a
handler pool. The framework's source is unchanged since 0.8.0.

- Step 1: `sabotage-m0-wheel` 25 of 25 (692 s). `sabotage-scaffold` 80 of
  80: the 68 rules outside `image:` in one run (1525 s), then each of the
  twelve `image:` rules with `--only` (68–159 s each), a `docker builder
  prune` and an `fstrim` between them. The run began at 6.4 GiB free,
  after removing three images earlier gate runs had left. A `while read`
  loop over the labels ran only the first: `uv run` read the rest of the
  list from standard input, so give each command `< /dev/null`.
- Step 3: the local wheel, built on the merge commit, was
  `m0-0.9.0-py3-none-any.whl`, 694,090 bytes, and a scaffold from it
  pinned `m0==0.9.0`.
- Step 4: the merge was made by hand, which started a `Tests` run on the
  merge commit itself; the build job reads that run before the pull
  request head, so the tag waited until it passed. `build` was green at
  the first attempt, and `publish-pypi` green after approval. The job's
  log could not be read while the run waited, so its wheel artifact was
  downloaded instead: the local wheel's SHA-256, `_build_info.json`
  naming `c977202` and a clean tree. The file on the index has the same
  size and SHA-256.
- Step 5 on macOS arm64: `uvx --refresh m0 new probe` pinned `m0==0.9.0`,
  and `uv.lock` named it from pypi.org. The first build took 12 s and
  printed no warning, `smoke.sh` passed, `m0 test` passed, and every `m0
  doctor` check passed, `scaffold` naming no file. `m0 image` built in
  27 s with the base layers present: 103.6 MB, 2.93 MB of it the app,
  `libsqlite3-0` installed and no interpreter. A `board` project written
  with `m0 new .` built with no warning, and its `smoke.sh` passed.
- Step 6: 8 blocks passed against the published package.

## m0 0.8.0 and m0serve 1.12.0 — 2026-10-07

`m0 0.8.0`: tag `m0-v0.8.0` at `7ceec8c`, 2026-10-07, cut beside m0serve
1.12.0 and pushed first; `v1.12.0` was pushed once the index had it and
the scaffold and quickstart had run against it.

- Step 1: `sabotage-m0-wheel` 25 of 25 (616 s). `sabotage-scaffold` 66 of
  66: the 62 rules that build no image in one run (1438 s), then each of
  the four image rules with `--only` (94–425 s each, the first cold), a
  `docker builder prune` and an `fstrim` of `/var/lib/docker` between
  them. The run began at 4.2 GiB free; a builder prune, an `fstrim` and
  removing images no gate needs made it 8 GiB, and it stayed between 7
  and 12 GiB with trims between the container gates.
- Step 3: the local wheel, built on the branch head, was
  `m0-0.8.0-py3-none-any.whl`, 684,540 bytes, and a scaffold from it
  pinned `m0==0.8.0`.
- Step 4: `build` green at the first attempt ("Tests passed on" named the
  pull request head, `fc57207`, that the labelled merge carries), and
  `publish-pypi` green after approval. The file on the index is 684,541
  bytes: one byte more than the local wheel, which was cut from the branch
  head rather than the merge commit (the 0.6.0 difference; build the local
  wheel on the merge commit if the sizes are to agree).
- Step 5 on macOS arm64: `uvx --refresh-package m0 m0 new`, minutes after
  the upload, wrote a scaffold pinning `m0==0.8.0` at the first try. The
  first build took 30 s, `smoke.sh` passed, `m0 test` passed, and `m0
  image` built in 29 s with the base layers present: 103.6 MB, 2.93 MB of
  it the app, `libsqlite3-0` installed and no interpreter.
- Step 6: 8 blocks passed against the published package.
- The pre-release run, for the record: every gate in this page, run on
  the release branch from the main checkout with the peer session paused
  for the quiet stage. Both soaks stood at 1.11.0, one minor behind, so
  neither was re-run. All six macOS bench kinds were two minors behind
  and were re-recorded at 1.12.0; every figure moved within noise.
  `bench-linux-conclusions` read ASGI against uvicorn+uvloop per core as
  INVERTS again, macOS 1.01 against Linux 0.92, as the benchmark page now
  says.

## m0 0.7.0 and m0serve 1.11.0 — 2026-10-06

`m0 0.7.0`: tag `m0-v0.7.0` at `1222e33`, 2026-10-06, cut beside m0serve
1.11.0 and pushed first; `v1.11.0` was pushed once the index had it.
- Step 1: `sabotage-m0-wheel` 25 of 25 (724 s). `sabotage-scaffold` 66 of
  66: the 62 rules that build no image in one run (1426 s), then each of
  the four image rules with `--only` (97–112 s each), a `docker builder
  prune` and an `fstrim` of `/var/lib/docker` between them. The run began
  at 6.5 GiB free; a builder prune and an `fstrim` of both colima disks
  made it 16 GiB, and it stayed above 15 GiB from then on.
- Step 3: the local wheel, built on the merge commit, was
  `m0-0.7.0-py3-none-any.whl`, 681,880 bytes, and a scaffold from it
  pinned `m0==0.7.0`.
- Step 4: `build` green at the first attempt ("m0 0.7.0, cut from
  1222e33…"), and `publish-pypi` green after approval; "Tests passed on"
  named the pull request head (`a3b8cd0`) that the labelled merge carries.
  The file on the index is 681,880 bytes with the local wheel's SHA-256:
  both were cut from the merge commit, so 0.6.0's one-byte difference did
  not recur.
- Step 5 on macOS arm64: the first `uvx --refresh-package m0 m0 new`, a
  minute after the upload, wrote a scaffold pinning `m0==0.6.0`. The index
  page is cached for 600 s, and the fresh one listed 0.7.0; `uvx --refresh`
  then pinned `m0==0.7.0`, and `uv.lock` named it from pypi.org. The first
  build took 13 s, `smoke.sh` passed, `m0 test` passed, and every `m0
  doctor` check passed, `scaffold` naming no file. `m0 image` built in
  30 s with the base layers present: 103.6 MB, 2.93 MB of it the app,
  `libsqlite3-0` installed and no interpreter.
- Step 6: 8 blocks passed against the published package; a plain
  `uvx m0 --version` read `m0 0.7.0` beside it.
- The pre-release run, for the record: both soaks ran on the release
  branch, the application layer's against unotes built by this wheel's
  local twin (REAL_APP_VALIDATION.md), so both read 1.11.0 at the release.
  `bench-linux-conclusions` read ASGI against uvicorn+uvloop per core as
  INVERTS, at macOS 1.01 against Linux 0.92, where the 1.10.0 run read
  0.99 against 0.94. Both sides are near parity, and the macOS ratio
  crossed 1.0 with its 1.10.0 re-record.

## m0 0.6.0 and m0serve 1.10.0 — 2026-10-03

`m0 0.6.0`: tag `m0-v0.6.0` at `51d6fac`, 2026-10-03, cut beside m0serve
1.10.0 and pushed first; `v1.10.0` was pushed once the index had it.
- Step 1: `sabotage-m0-wheel` 25 of 25 (652 s). `sabotage-scaffold` 66 of
  66 in one pass: the 62 rules that build no image in one run (1416 s),
  then each of the four image rules with `--only` (105–114 s each), a
  `docker builder prune` and an `fstrim` of `/var/lib/docker` between
  them, starting from 10 GiB free. No disk trouble that way.
- Step 3: the local wheel was `m0-0.6.0-py3-none-any.whl`, 675,312 bytes,
  and a scaffold from it pinned `m0==0.6.0`.
- Step 4: `build` green at the first attempt ("m0 0.6.0, cut from
  51d6fac…"), and `publish-pypi` green after approval; "Tests passed on"
  named the pull request head (`fc2359b`) that the labelled merge carries.
  The file on the index is 675,311 bytes, ONE byte under the local wheel:
  the wheel records the commit it was cut from in `_build_info.json`, the
  local one was built on the branch head and the published one on the
  merge commit, and the two hashes compress differently. Nothing else in
  the two archives differs. Build the local wheel on the merge commit if
  the counts are to be compared.
- Step 5 on macOS arm64: the scaffold pinned `m0==0.6.0`, and `uv.lock`
  named it from pypi.org. The first build took 13 s, `smoke.sh` passed,
  `m0 test` passed, and every `m0 doctor` check passed, `scaffold` naming
  no file. `m0 image` built in 31 s with the base layers present: 103.5 MB,
  2.93 MB of it the app, `libsqlite3-0` installed and no interpreter.
- Step 6: 8 blocks passed against the published package.
- The pre-release run, for the record: the first mixed-workload recording
  had its three `--workers 4` rows 28% down with every comparator row
  unmoved, which `render-bench-docs --check` refused; an interleaved A/B of
  accept sharing showed no difference, and a second recording put the rows
  at +2%, 0% and -1% against 1.8.0. Those rows run first, minutes after
  the free-threaded swap writes a fresh venv. A `docker system prune -f`
  run to free disk removed the `m0lin` container `stress-pool` runs in;
  `docker builder prune` is the prune that frees what the image rules
  leave and nothing else.

## m0 0.5.0 and m0serve 1.9.0 — 2026-10-02

`m0 0.5.0`: tag `m0-v0.5.0` at `e2a88d7`, 2026-10-02, cut beside m0serve
1.9.0 and pushed first; `v1.9.0` was pushed only once the index had it.
- Step 1: `sabotage-m0-wheel` 25 of 25. `sabotage-scaffold` 66 of 66, in
  two runs: the host's disk filled during the image rules (about 10 GiB
  free at the start), two rules read MISSED because the build failed and
  not the rule, the next crashed, and the harness could not write its
  restore, leaving `_common/deploy/Dockerfile` sabotaged and docker's
  volume answering `input/output error`. Put back with `git checkout`,
  `colima restart`, a prune, and the last four image rules one at a time
  with `--only`, a prune and an `fstrim` of `/var/lib/docker` between
  them: all four caught. `fstrim -av` reported 0 bytes there; the volume
  is a disk of its own and is trimmed by its mount point.
- Step 3: the local wheel was `m0-0.5.0-py3-none-any.whl`, 665,220 bytes,
  and a scaffold from it pinned `m0==0.5.0`.
- Step 4: `build` green at the first attempt, and `publish-pypi` green
  after approval; the file on the index is 665,220 bytes, equal to the
  local wheel. "Tests passed on" named the pull request head (`df8f90c`)
  that the labelled merge carries. The two lines to read before approving
  could not be fetched with `gh` while the run waited: read them in the
  browser.
- Step 5 on macOS arm64: the scaffold pinned `m0==0.5.0`, and `uv.lock`
  named it from pypi.org. The first build took 12 s, `smoke.sh` passed,
  `m0 test` passed, and every `m0 doctor` check passed, `scaffold` naming
  no file.
- `m0 image` built in 30 s with the base layers present. The image is
  103.5 MB, 2.93 MB of it the app, with `libsqlite3-0` installed and no
  interpreter.
- Step 6: 8 blocks passed against the published package.

## m0 0.4.0 and m0serve 1.8.0 — 2026-09-29

`m0 0.4.0`: tag `m0-v0.4.0` at `b1dca5b`, 2026-09-29, cut beside m0serve
1.8.0 and pushed first, as 0.3.0 was.
- Step 1: `sabotage-m0-wheel` 25 of 25, `sabotage-scaffold` 66 of 66 (93
  minutes).
- Step 3: the local wheel was `m0-0.4.0-py3-none-any.whl`, 641,393 bytes,
  and a scaffold from it pinned `m0==0.4.0`.
- Step 4: `build` green at the first attempt ("m0 0.4.0, cut from
  b1dca5b…"), and `publish-pypi` green after approval; the file on the
  index is 641,393 bytes, equal to the local wheel. The `automerge` label
  made the merge, so "Tests passed on" named the pull request head it
  merges (`5d159e9`), which is the path step 1 describes.
- Step 5 on macOS arm64: the scaffold pinned `m0==0.4.0`, and `uv.lock`
  named it from pypi.org. The first build took 23.3 s and printed no
  warning, `smoke.sh` passed, `m0 test` ran six tests green, and every
  `m0 doctor` check passed, `scaffold` naming no file.
- `m0 image` built in 586 s from a cold cache. The builder's `uv sync
  --frozen` installed `m0==0.4.0` and mojo 1.1.0 from the index. The image
  is 103.5 MB, 2.92 MB of it the app, with `libsqlite3-0` installed and no
  interpreter.
- Step 6: 8 blocks passed against the published package.

## m0 0.3.0 and m0serve 1.7.0 — 2026-09-27

`m0 0.3.0`: tag `m0-v0.3.0` at `1946db3`, 2026-09-27, cut beside m0serve
1.7.0 and pushed first, as 0.2.0 was.
- Step 1: `sabotage-m0-wheel` 25 of 25, `sabotage-scaffold` 64 of 64. The
  scaffold run took 96 minutes, most of it image rules downloading the
  toolchain cold.
- Step 3: the local wheel was `m0-0.3.0-py3-none-any.whl`, 619,679 bytes,
  from a clean tree. A `views` scaffold and an `auth` scaffold from it both
  pinned `m0==0.3.0`.
- Step 4: `build` green at the first attempt ("m0 0.3.0, cut from
  1946db3…", 619,679 bytes, equal to the local wheel), and `publish-pypi`
  green after approval. The merge was made by hand, so "Tests passed on"
  named the merge commit's own run rather than the pull request head's.
- Step 5 on macOS arm64: the scaffold pinned `m0==0.3.0`, and `uv.lock`
  named it from pypi.org. The first build took 13.5 s and printed no
  warning, `smoke.sh` passed, and every `m0 doctor` check passed —
  `max-gated` with no MAX installed, and `scaffold` naming no file.
- `m0 image` built in 550 s from a cold cache. The builder's `uv sync
  --frozen` installed `m0==0.3.0` and mojo 1.1.0 from the index. The image
  is 103.6 MB, 2.97 MB of it the app, with `libsqlite3-0` installed and no
  interpreter.
- Step 6: 8 blocks passed against the published package.

## m0 0.2.0 and m0serve 1.6.0 — 2026-09-25

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

## m0 0.1.0 — 2026-09-21

`m0 0.1.0` — tag `m0-v0.1.0` at `e6823b6`, 2026-09-21, the
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
