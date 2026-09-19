# The demo in its own image — 2026-09-18

Phase 5 of the Mojo-native host plan: `apps/blobs` shipped as an image with
no interpreter and no toolchain in it, proven on x86-64, gated on every pull
request, and measured beside the Django demo. The same work settled the
execution mode for its deploy (DECISIONS D36). The deploy itself
(`blobs.m0serve.dev`) follows from the next release's tag.

The plan described its builder stage as a spike nobody had run. It had been
run: PR #328, on 2026-09-15, as `deploy/mojo-hello/` (SPEC M26). What Phase 5
owed was that spike's "does NOT prove" list: an app that does more than
answer, x86-64, a gate and a deploy. It also owed a correction. The spike's
headline figure compared two different things, as described below.

## What was built

- **`deploy/mojo/Dockerfile`**, one Dockerfile for every Mojo app, replacing
  `deploy/mojo-hello/`. `APP` names a directory under `apps/`, the binary is
  `/app/server` whatever the app, and `TARGET_CPU` is never `native`.
- **A last layer that measures the image.** It records the unpacked bytes of
  the filesystem and of `/app`, and checks that no interpreter is anywhere in
  it. The build fails if one is. The result goes to `/app/about.json`, with
  the version from `pyproject.toml`, the target CPU, the architecture and the
  base.
- **`apps/blobs` says what the file says.** Its footer and `/about` read
  the file through `M0_IMAGE_FACTS`, once per handler (`about.mojo`). Outside
  an image nothing is claimed. A file that is named but unreadable or
  malformed is refused with 78 rather than skipped.
- **`scripts/mojo_image_probe.py`**, replacing the shell probe. It runs in
  three modes: `--build`, `--image` and `--url`. The last is the deploy's
  verification.
- **`poe smoke-blobs-image`**, on every pull request in the `pid1` job
  (SPEC M26, which moved here from pre-release, and M27, new).
- **`poe sabotage-mojo-image`** (pre-release): ten sabotaged images, each
  required to fail where it should.
- **`scripts/bench_blobs_modes.py`**, the measurement behind D36.

## The precursor: the demo deployed from main

`deploy-site.yml`'s `deploy-demo` job checked out the default branch and
pinned the release's wheel. So `deploy/demo/Dockerfile`, the demo
application and the probe that verifies it came from whatever had merged
since the release. Copying that job for blobs would have been worse, because
the blobs image compiles its checkout: the checkout IS the version. PR #347
fixed it first:

- after a `Release`, both jobs check out the release's `head_sha`;
- on a dispatch, the demo checks out `refs/tags/v<version>`;
- a new step refuses to deploy when the tree's `pyproject.toml` version is
  not the pinned one.

The site's dispatch still renders the ref it ran on, because publishing
prose merged after a release is what a site dispatch is for.

The test was a live dispatch for 1.4.0 after the merge. `deploy-demo`
checked out `refs/tags/v1.4.0` (`f17638b`) and printed "tree f17638b is
m0serve 1.4.0". It then deployed, and the probe verified the live demo.

## Question 3: one Dockerfile, not two

A second near-copy of the hello Dockerfile is how two images drift. What
differs between apps is one directory. The toolchain, the package chain, the
relocation and the runtime stage are the same, so they are written once.

- **The binary has a fixed name.** An exec-form `ENTRYPOINT` cannot expand a
  build argument, and a shell form would put `sh` at PID 1. That is the
  failure the first sabotage builds.
- **`m0-datastar` is precompiled for every app.** It costs about four
  seconds and sits in a layer every app shares.
- **Apps enter the context by name.** The `.dockerignore` is still `*` plus an
  allowlist. `apps/blobs/` joins `apps/hello/`, and a new app's first build
  fails naming its missing `server.mojo` until it is added. `**/*.mojoc`
  stays excluded, because a host artifact would be a silent toolchain
  mismatch.

## Question 4: every pull request

M26 was pre-release "because the builder installs the toolchain wheel and
compiles the packages from source" — minutes and a large download, it said.
That cost had never been measured. Measured, the whole `Smoke test the Mojo
demo's deploy image` step took 66 s on `ubuntu-latest`, build and probe
together. Locally, the build took 13 s with the apt layer cached: the three
package precompiles took 4 s and blobs 11 s. The `pid1` job went from about
2.5 minutes to about 3.5. So both rows are every-PR, and the hello image
keeps `probe-mojo-image` as a pre-release measurement of the floor rather
than as a row's gate.

## Question 2: x86-64

The gate picks the target CPU from the docker DAEMON's architecture, so on
CI's runner it builds `--target-cpu x86-64-v2`. That is the first x86 Mojo
build anything here has made, and it runs on every pull request. The run
that settled it is #348's first `Tests` run
([35401394882](https://github.com/codetalcott/mojo-http/actions/runs/35401394882)).
Its `pid1` job built the image in 58 s from a cold cache, served it, and
passed every phase of the probe, the whole of `smoke-blobs`' main run
through the published port included. There the image is 80.1 MB unpacked,
3.4 MB of it the app, and the server's RSS was 20.1 MiB idle and 24.2 MiB
with 100 streams held. The step at 10 Hz was 0.9 ms, and each viewer
received 49 KB/s. QEMU was never involved: a local amd64 build SIGFPEs under
emulation, which says nothing about the binary.

D35's first retiring condition was a Linux x86 measurement. Phase 4 could
not make one. This round ran `bench-host-modes` on a GitHub runner (AMD
EPYC 9V45, 4 vCPU, N=2) from a throwaway branch
(`bench/results/pure-mojo-image-2026-09/host-modes-linux-x86-*.json`).
Threads over workers:

| case | throughput | per core | p99 | RSS |
|---|---|---|---|---|
| now c16 | 0.98x | 0.98x | 1.06x | 0.57x |
| now c256 | 0.99x | 0.87x | 0.99x | 0.56x |
| search c16 | 0.99x | 0.99x | 1.14x | 0.56x |
| search c256 | 0.98x | 0.98x | 1.03x | 0.59x |

Throughput and the tail are at parity, as on macOS and Linux aarch64. One
difference is consistent, and it is recorded rather than averaged: at 256
connections on the loop route, threads served the same requests on more
CPU. Per core they reached 0.86, 0.86 and 0.94 of workers' in the three
rounds, with workers at 1.74–1.87 cores against threads' 1.87–2.0 for the
same throughput. That is prefork's side of D35, which already puts prefork
first, so the decision stands and its retiring condition now reads
"threads win".

## Question 1: one loop, for this deploy (D36)

D35 left the default at prefork and deferred the question to this phase,
"where RSS is the number that is billed". A Fly shared-cpu-1x machine is ONE
vCPU at 256 MB, billed by the machine. `bench_blobs_modes.py` runs the
demo's own image three ways: one loop, `M0_WORKERS=2` and `M0_THREADS=2`.
Each arm is a fresh container. The client, in a container on the same docker
network, holds V viewers' `/events` streams and times a trivial `/now` every
50 ms.

**The first run measured the wrong machine.** `--cpus 1` is a quota of CPU
time, and two loops spend it on two cores at once whenever the machine has
them. Unpinned, the two N-loop arms halved `/now`'s p99 at 400 viewers by
running beside each other, which a one-vCPU machine cannot do. The bench now
pins the server to one core with `--cpuset-cpus` and keeps the client off it.
The unpinned rows are not cited.

Pinned, 20 s windows after a 3 s warm-up, three rounds, medians:

| arch | viewers | mode | cores | RSS, MiB | delivered | spread p99 | `/now` p99 |
|---|---|---|---|---|---|---|---|
| arm64 | 100 | loop | 0.039 | 16.0 | 100 % | 4.7 ms | 1.6 ms |
| | | workers=2 | 0.039 | 32.5 | 100 % | 5.0 ms | 1.4 ms |
| | | threads=2 | 0.041 | 19.6 | 100 % | 4.4 ms | 1.8 ms |
| arm64 | 400 | loop | 0.101 | 22.1 | 100 % | 16.2 ms | 8.3 ms |
| | | workers=2 | 0.105 | 39.6 | 100 % | 18.2 ms | 6.8 ms |
| | | threads=2 | 0.104 | 26.5 | 100 % | 19.0 ms | 6.4 ms |
| x86-64 | 100 | loop | 0.026 | 24.0 | 100 % | 2.5 ms | 0.5 ms |
| | | workers=2 | 0.025 | 53.6 | 100 % | 2.4 ms | 0.3 ms |
| | | threads=2 | 0.024 | 28.4 | 100 % | 2.1 ms | 0.4 ms |
| x86-64 | 400 | loop | 0.061 | 33.1 | 100 % | 10.9 ms | 0.7 ms |
| | | workers=2 | 0.058 | 63.8 | 100 % | 9.6 ms | 1.1 ms |
| | | threads=2 | 0.066 | 37.0 | 100 % | 10.7 ms | 1.0 ms |

arm64 is colima on an Apple M4 (4-CPU VM); x86-64 is a GitHub runner with an
AMD EPYC 7763. RSS is VmRSS summed over the server's processes, in MiB
(`/proc`'s kB are 1024 bytes). The spread is, per frame, the last viewer's
arrival minus the first's.

Every mode uses the same CPU and delivers every frame with the same spread.
The only difference that repeats is memory: two threads cost 1.11–1.25x one
loop's RSS and two workers 1.79–2.29x. `/now`'s tail moves by at most 2 ms,
and not in one direction. On arm64 at 400 viewers two loops were better,
the kernel interleaving two fan-outs on one core. On x86 one loop was. So
the tail is not a reason either way.

A second run throttles the pinned core to a shared-cpu-1x's baseline share,
6.25 % (`--cpus 0.0625`, at 25 and 100 viewers). Every mode still delivered
every frame on the same CPU. The tail was set by the quota's 100 ms period:
23–50 ms p99 in every mode. That is harsher than Fly, whose shared CPU
bursts to the whole vCPU on a balance where a cgroup quota throttles each
burst. Read it as a bound, not a forecast.

**So the deploy serves one loop** (D36). What one loop gives up is a
supervisor: a crash takes the process, and the machine's restart plays the
supervisor's part. That costs blobs less than it would another app. The
world lives in the producer on worker 0 under prefork too, so a crash there
loses it in every mode. The page's `retry: 'always'` brings every tab back
either way.

What the budget buys, from the same rows: 400 viewers at 10 Hz cost 0.061
of an x86 core, close to the 6.25 % baseline, and the producer slows to 2 Hz
a minute after the last drop. The owner set the deploy's limits from these
figures: soft 200, hard 400 connections. At 400 they stay inside the CPU
baseline at full cadence and under the process's default 1024 open files,
where the Django demo's hard 900 would not. Each viewer receives
30–50 KB/s at 10 Hz (a whole state, 3–5 KB, per frame), which is what the
egress bill counts.

## The images, measured the same way

The spike's headline was "29.2 MB against the Django demo's 74 MiB". The
first figure is the hello image's COMPRESSED size: under colima's containerd
image store, `docker image inspect`'s `Size` counts compressed layers. On
the classic overlay2 store, which GitHub's runners use, the same field
counts unpacked bytes. The second figure is the Django demo CONTAINER's
memory with three streams held (`deploy/demo/README.md`), not an image size
at all. So the two were never comparable, and M26 said they were.

Measured the same way on linux/arm64 (colima, Apple M4), the Django image
from the 1.4.0 wheel. Image sizes are decimal MB, as the footer prints them;
RSS is VmRSS in MiB, summed over the server's processes:

| | blobs | hello | the Django demo |
|---|---|---|---|
| image, compressed | 29.3 MB | 29.2 MB | 60.3 MB |
| image, unpacked | 102.1 MB | 101.6 MB | 184.6 MB |
| the app's own bytes | 3.0 MB | 2.5 MB | — |
| RSS idle, MiB | 13.6, one loop | 11.9 | 112.8: a 9.1 supervisor and two 52 workers |
| RSS with 100 connections held, MiB | 16.4 (streams) | 13.2 (keep-alive) | — |

Debian slim is 99.1 MB unpacked of the blobs image's 102.1 MB. The page's
footer says so in its own words: "102.1 MB unpacked, 3.0 MB of it this app".
A smaller base (distroless, or a static link) is where the next cut would
come from, not the binary.

## What the gate found on its way

- **Two stale sabotage anchors.** `blobs_sabotage.py`'s "the producer never
  publishes" entry had matched nothing since round 4 (4bb5a50) renamed
  `self.step_no` to `id` in the publish call. `sabotage-blobs` would have
  reported it NOT APPLICABLE and counted a miss. The board entry's anchor
  moved with this round's edit. Both are re-pointed.
- **`relocate.py` is not load-bearing here.** The sabotage "relocate.py
  removed" built a working image, because `bundle_artifact.py` rewrites the
  copy it bundles to `$ORIGIN` itself. The Dockerfile's grep was right; the
  sabotage's premise was wrong. It now ships the unrelocated binary, which
  the build refuses by name.
- **One sabotage could not be built.** "The footer claims no Python without
  reading the facts" passes the probe, because no image that builds can say
  `python: true`: the build refuses first. That refusal is what holds the
  claim, and it is sabotaged directly.
- **`bench_record.medians` assumed every bench has a rate.** It crashed after
  the whole run on a bench that holds a fixed load and measures its cost. It
  now records what the rows carry.

## What this does not prove

- **Fly's own CPU.** The throttled run is a cgroup quota, not Fly's burst
  balance, and it runs on a runner's EPYC 7763 and an M4, not Fly's hosts.
- **The deploy.** The Fly app `m0serve-blobs`, its IPs, DNS and the
  certificate for `blobs.m0serve.dev` exist, and so does the deploy token.
  Fly's remote builder has built the image (build-only, 2026-09-19: x86_64,
  80.1 MB unpacked), so the build the release will run is not in doubt. The first
  deploy is the release workflow's, from the v1.5.0 tag. A hand deploy from
  main would have shown a version its code is not.
- **Open files on Fly.** The container's soft limit is 1024 under docker. Fly
  machines have not been checked; the hard limit of 400 is well inside
  either.
- **Egress at scale.** Measured per viewer, not billed.

## Reproduction

```bash
uv run poe smoke-blobs-image                  # build for the daemon's arch, probe from outside
uv run poe sabotage-mojo-image                # ten sabotaged images, each caught where it should be
uv run poe probe-mojo-image                   # the hello floor
python3 scripts/bench_blobs_modes.py --build                                  # one core
python3 scripts/bench_blobs_modes.py --build --cpus 0.0625 --viewers 25,100   # its baseline share
python3 scripts/bench_host_modes.py --n 2 --wrk-threads 2 --name host_modes_linux_x86
```

The artifacts are in `bench/results/pure-mojo-image-2026-09/`, a
subdirectory so that none of them renders into a table: a Linux run is not a
row in the macOS tables, and `host-modes-linux-x86-*` would match the
`host-modes` glob. The local ones were recorded from a clean tree at
`b7d4f63`; the runner ones at `3e0dda9` and `cde7841`, on a throwaway
branch whose only change beyond this round's commits was the workflow that
ran them.
