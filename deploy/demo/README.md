# Deploying the live demo

`https://demo.m0serve.dev` is [apps/demo](../../apps/demo/README.md) -- the
two-tab realtime demo, one file of sync Django -- served by `m0serve
--realtime` from one small Fly.io machine. Everything here is the
deployment; the application is described there.

| file | what it is |
|---|---|
| `Dockerfile` | `python:3.12-slim` + Django + the m0serve wheel + `demoapp.py`. Context is the repository root; `.dockerignore` lets in only what it copies. |
| `fly.toml` | App `m0serve-demo`, region `iad`, one shared CPU, 256 MB, always on, connection-counting concurrency, health check on the server's own `/health`. |
| `wheelhouse/` | Empty in the repository. `poe smoke-demo` stages the tree's wheel here to prove the Dockerfile against main; a deploy leaves it empty and pins PyPI. |
| `../../.github/workflows/deploy-site.yml` | The `deploy-demo` job deploys after every successful `Release` (pinning that release's wheel), or on demand with a version -- the same trigger as the docs site, a different app and a different token. |

## Why its own app, and why one machine

**A separate app on a subdomain, never a mount inside the docs app.** The
demo takes untrusted realtime traffic -- held connections, publishes from
anyone -- and that must not share a process with the site.

**One machine, by design.** The publish bus is per process: a message
published on the worker that received it reaches the worker holding the
other tab over a socket pair both inherited from the supervisor. Two
machines would split a visitor's tabs across two buses, and the demo would
look broken in exactly the way it exists to disprove. So `auto_stop_machines
= false`, `min_machines_running = 1`, and after the first deploy (which
creates two):

```bash
fly scale count 1 -a m0serve-demo
```

**The proxy counts connections.** `fly.toml` sets the concurrency type to
`connections` with a hard limit under the server's own 1024 per worker;
with the default `requests` type every held stream would count as one
in-flight request against a limit of 250.

**Heartbeats every 25 s** (`M0_SSE_HEARTBEAT_MS`, in both the image and
`fly.toml`): Fly's proxy closes idle long-lived connections, and a comment
on the stream or a ping on the socket is what keeps a quiet tab held. Do not
put Cloudflare's proxy in front for the same reason; keep the DNS record
unproxied.

## One-time setup

Same rules as the docs site: create the app empty and let the repository's
workflow deploy it -- do not connect the repository to Fly's GitHub
integration and do not run `fly launch` in the checkout.

```bash
fly apps create m0serve-demo --org textshelf         # the name in fly.toml; the TextShelf org
fly ips allocate-v4 --shared -a m0serve-demo
fly ips allocate-v6 -a m0serve-demo
fly certs add demo.m0serve.dev -a m0serve-demo       # prints the records to publish
```

Publish an `A` record for `demo` to the shared IPv4 and an `AAAA` to the
IPv6 (`fly ips list -a m0serve-demo`) at the registrar, then `fly certs
check demo.m0serve.dev -a m0serve-demo` until it reports issued.

For the workflow, a deploy token scoped to this one app, stored as the
secret `FLY_DEPLOY_DEMO` (the `fly` environment is where `FLY_DEPLOY_SITE`
lives too). The `FlyV1 ` prefix is part of the value -- paste the whole line,
never as a bare shell argument:

```bash
fly tokens create deploy -a m0serve-demo --name "github-actions deploy-demo"
pbpaste | gh secret set FLY_DEPLOY_DEMO --env fly
```

Then either wait for the next release or dispatch `Deploy site` by hand
with the version to pin; the demo job runs beside the site's.

## Deploying by hand

```bash
uv run poe deploy-demo               # pins the tree's version, which must be on PyPI
uv run poe deploy-demo 0.17.0        # pins a release
```

`flyctl deploy` runs from the repository root with `--config
deploy/demo/fly.toml`, so the Dockerfile sees the same context the workflow
gives it. `--remote-only`, always: a local build on an Apple Silicon Mac
emulates x86_64 and the binary dies with `exit code: 136` (SIGFPE) under
QEMU -- see [deploy/site/README.md](../site/README.md) for the whole trap.

## Verifying

```bash
python3 scripts/demo_probe.py --url https://demo.m0serve.dev   # every promise, from outside
curl -s https://demo.m0serve.dev/about                         # the version line as JSON
pip index versions m0serve | head -1                           # ...should match
fly logs -a m0serve-demo                                       # one access-log line per response
```

The probe is the same one `poe smoke-demo` runs against the image on every
pull request, minus the container phases: the page and the cookie, the 403s
without it, a held stream and a held socket, one publish reaching a second
tab and not a stranger, the 413 and the 429. Then open the page in two tabs
yourself; that is the demo.

## Cost and shape, for the record

Measured in the image with three streams held: 52 MB RSS per Django worker,
9 MB for the supervisor, 74 MiB for the container. Two workers and the
supervisor, always on, on a shared-cpu-1x with 256 MB: $2.02 a month at
Fly's 2026-09 prices, the same machine as the docs site. The image is
proven from the tree's wheel by `poe smoke-demo` (SPEC M17) before any
release can deploy it.
