# Deploying the Mojo demo

`https://blobs.m0serve.dev` is [apps/blobs](../../apps/blobs/server.mojo):
one shared world, stepped in Mojo on the server and pushed to every open
tab. It runs from one small Fly.io machine, in an image with no Python in
it ([deploy/mojo](../mojo/README.md)). Everything here is the deployment.

| file | what it is |
|---|---|
| `fly.toml` | App `m0serve-blobs`, region `iad`, one shared CPU, 256 MB, always on, connection-counting concurrency, health check on the server's own `/health`. Builds `../mojo/Dockerfile` with `APP=blobs` and `TARGET_CPU=x86-64-v2`. |
| `../mojo/Dockerfile` | The pure-Mojo image: the pinned toolchain compiles the checkout in a builder stage, and the runtime stage is the binary and the Mojo runtime libraries on `debian:12-slim`. `poe smoke-blobs-image` proves it on every pull request (SPEC M26, M27). |
| `../../.github/workflows/deploy-site.yml` | The `deploy-blobs` job deploys after every successful `Release`, from that release's commit, or on demand with a version, from its tag -- the same trigger as the docs site and the Django demo, a different app and a different token. |

## Why its own app, one machine, one loop

**The checkout is the version.** The Django demo pins a wheel from PyPI;
this image compiles the tree it is built from. So the deploy builds from the
release's tag, and the footer's version -- read from the image's own
`/app/about.json` -- is that release's. A hand deploy from a branch would
put a version on the page that its code is not.

**One machine, by design.** The world is held by one producer thread and
carried to every stream by one process's bus. A second machine would be a
second world, and two tabs could be looking at different ones. So
`auto_stop_machines = false`, `min_machines_running = 1`, and after the
first deploy (which creates two):

```bash
fly scale count 1 -a m0serve-blobs
```

**One loop** (DECISIONS D36): no `M0_WORKERS`, no `M0_THREADS`. On one shared
vCPU, measured on one pinned core, extra loops buy no CPU, delivery or
fan-out and cost memory. A crash takes the process, and Fly restarting the
machine plays the supervisor's part; the page's `retry: 'always'` brings
every tab back.

**The proxy counts connections, at soft 200 and hard 400.** Every viewer
holds a stream. 400 viewers at 10 Hz cost about 6 % of an x86 core, a
shared-cpu-1x's baseline share, and each receives 30-50 KB/s (a whole state
per frame) until a minute passes without a drop and the producer slows to
2 Hz. The limits are where that stops being a demo's cost
(docs/notes/the-demo-in-its-own-image.md).

**Heartbeats every 25 s** (`M0_SSE_HEARTBEAT_MS`): frames already flow while
anyone watches, so this matters only through a quiet proxy. Keep the DNS
records unproxied, as the demo's.

## One-time setup (done 2026-09-18)

Created empty, deployed by the repository's workflow -- never `fly launch`
in the checkout, never Fly's GitHub integration:

```bash
fly apps create m0serve-blobs --org textshelf
fly ips allocate-v4 --shared -a m0serve-blobs     # 66.241.125.48
fly ips allocate-v6 -a m0serve-blobs              # 2a09:8280:1::193:6228:0
fly certs add blobs.m0serve.dev -a m0serve-blobs
fly tokens create deploy -a m0serve-blobs --name "github-actions deploy-blobs" \
  | gh secret set FLY_DEPLOY_BLOBS --env fly
```

Publish `A blobs -> 66.241.125.48` and `AAAA blobs -> 2a09:8280:1::193:6228:0`
at the registrar, then `fly certs check blobs.m0serve.dev -a m0serve-blobs`
until it reports issued. The certificate issues before anything is
deployed; the first request simply finds no machine until the workflow has
run. The records were published and the certificate issued on 2026-09-19.

Fly's remote builder builds this image: a `flyctl deploy --build-only
--remote-only` on 2026-09-19 compiled it there for x86_64 at `x86-64-v2`
in 32 s, and its facts file read 80.1 MB unpacked, 3.4 MB of it the app, no
Python. Nothing was deployed; the app has no machine until the workflow's
first run.

## Deploying

The first deploy is the `Release` workflow's, from the next release's tag.
After that, a dispatch of `Deploy site` with a version redeploys it from that
version's tag, beside the site and the Django demo. By hand, from a checkout
of the tag:

```bash
git worktree add /tmp/blobs-vX.Y.Z vX.Y.Z && cd /tmp/blobs-vX.Y.Z
uv run poe deploy-blobs
fly scale count 1 -a m0serve-blobs            # the first deploy only
```

`--remote-only`, always: Fly's machines here are x86-64, and a local build on
an Apple Silicon Mac would emulate it (see [deploy/site](../site/README.md)).

## Verifying

```bash
python3 scripts/mojo_image_probe.py --app blobs --url https://blobs.m0serve.dev --version X.Y.Z
curl -s https://blobs.m0serve.dev/about          # the image's own facts
fly ssh console -a m0serve-blobs -C "sh -c 'for f in /proc/[0-9]*/comm; do [ \"\$(cat \$f)\" = server ] && cat \${f%comm}limits; done; true'"
```

On Fly the server is not PID 1: Fly's `/fly/init` is, and `/app/server` is
its child, so `/proc/1/limits` describes init. Read on the first deploy,
1.5.0 (2026-09-19): the server's open-files limit is 10240, soft and hard,
above the 400 connections the hard concurrency limit admits. It held
13.9 MiB of RSS in three threads on one vCPU, idle.

The probe asserts `/health`, `/about` naming blobs, no Python and the
version, the footer saying what `/about` says, a stream receiving three
whole-state frames with increasing ids, and `/stats` counting steps. It is
what the workflow runs after a deploy, up to three times 20 s apart.
