# Deploying the documentation site

`https://m0serve.dev` is the repository's own pages, rendered by
[scripts/docsite.py](../../scripts/docsite.py) and served by `m0serve` from
one small Fly.io machine. Everything here is the deployment; the site itself
is described in [apps/site](../../apps/site/README.md).

| file | what it is |
|---|---|
| `Dockerfile` | `python:3.12-slim` + the m0serve wheel + the built site + the fallback app. Context is the repository root; `.dockerignore` lets in only those three things. |
| `fly.toml` | App `m0serve-docs`, region `iad`, one shared CPU, 256 MB, always on, health check on the server's own `/health`. |
| `wheelhouse/` | Empty in the repository. `poe smoke-site-image` stages the tree's wheel here to prove the Dockerfile against main; a deploy leaves it empty and pins PyPI. |
| `../../.github/workflows/deploy-site.yml` | Deploys after every successful `Release` (pinning that release's wheel), or on demand with a version. |

## What the image needs from the server

Three things need the server after 0.16.0: the sitemap served as
`application/xml` (the `xml` content type), and the fallback application's
two promises -- `/docs/spec` redirects to `/docs/spec/`, and an unknown URL
gets the site's own 404 page -- which need a static mount that **falls
through on a miss** (it also lets the server's own `/health`, the Fly
health check, answer under a mount at `/`). `poe smoke-site-image` passes
everything else on the 0.16.0 wheel and fails at exactly that phase, saying
so. The first public deploy therefore follows the next release; until then
the workflow's dispatch input would pin a wheel that cannot keep those
promises.

## One-time setup

**Do not connect the repository to Fly's GitHub integration, and do not run
`fly launch` in the checkout.** Both would write a second workflow and a
root `fly.toml` that deploy on every push to main, which is exactly what
`deploy-site.yml` avoids: the pages would describe main while the server
behind them is the released wheel, and neither would render the site or
pass the version pin the Dockerfile needs. Create the app empty and let the
repository's own workflow deploy it:

```bash
fly apps create m0serve-docs --org textshelf        # the name in fly.toml; the TextShelf org, not personal
fly ips allocate-v4 --shared -a m0serve-docs        # a first deploy would do these, but
fly ips allocate-v6 -a m0serve-docs                 # ...DNS and the cert cannot wait for it
fly certs add m0serve.dev -a m0serve-docs           # prints the records to publish
```

Publish an `A` record for `m0serve.dev` to the shared IPv4 and an `AAAA` to
the IPv6 (`fly ips list -a m0serve-docs` shows both), then
`fly certs check m0serve.dev -a m0serve-docs` until it reports issued. The
certificate issues before anything is deployed; the first request simply
finds no machine until the workflow has run. The organization is a property
of the app, not of `fly.toml` (app names are global), so nothing in the
repository names it; `fly apps list -o textshelf` is where to look. Keep DNS **unproxied** if the registrar is Cloudflare: the proxy's
100 s idle timeout and second TLS hop buy nothing for a static site and
complicate the live demo that will sit beside it.

For the workflow, create a deploy token scoped to this one app and store
it as the secret `FLY_DEPLOY_SITE` (the workflow hands it to flyctl as
`FLY_API_TOKEN`). It is a repository secret today; the job also runs in a
GitHub environment named `fly`, and moving the secret there would keep it
off every other job. The token is printed as `FlyV1 fm2_...`, and
the `FlyV1 ` prefix is part of the value — paste the whole line, at the
prompt or from the clipboard, never as a bare shell argument, which the
space would split:

```bash
fly tokens create deploy -a m0serve-docs --name "github-actions deploy-site"
pbpaste | gh secret set FLY_DEPLOY_SITE            # add --env fly to scope it to the environment
```

## Deploying by hand

```bash
uv run poe deploy-site               # renders for https://m0serve.dev, deploys, pins the tree's version
uv run poe deploy-site 0.17.0        # ...pinning a specific PyPI release
```

The task runs `flyctl deploy` from the repository root with
`--config deploy/site/fly.toml`, so the Dockerfile sees the same context the
workflow gives it. `fly releases -a m0serve-docs` lists what is live;
`fly deploy --image <previous>` rolls back.

## Building locally on a Mac

`flyctl deploy --local-only` builds for the app's platform, which is x86_64,
so on an Apple Silicon Mac the image builds under QEMU emulation and the
x86-64-v2 binary dies inside the build with `exit code: 136` (SIGFPE) at
`m0serve --version`. That is the emulator, not the wheel: the same wheel
runs natively on x86_64 in the release's consume job, and `docker run
--platform linux/amd64 … m0serve --version` reproduces the fault on demand.
The same fault appears without flyctl when `docker run python:3.12-slim`
on colima picks up a cached amd64 image (the daemon warns about the
platform mismatch); pass `--platform linux/arm64` and the aarch64 wheel
runs natively. Deploy with `--remote-only` (the default in `poe deploy-site`
and the workflow), where Fly's builder is native. `--build-only --local-only` is
still useful for one thing: it proves `fly.toml`'s Dockerfile path and the
build context resolve, which is where the first deploy failed. flyctl
needs `DOCKER_HOST=unix://$HOME/.colima/default/docker.sock` to see colima.

## Verifying

```bash
curl -sSfI https://m0serve.dev/llms.txt          # 200, text/plain
curl -sSf  https://m0serve.dev/llms.txt | head    # links are absolute
curl -sSfI https://m0serve.dev/sitemap.xml        # application/xml
curl -sSI  https://m0serve.dev/docs/spec | head -3 # 301 -> /docs/spec/
fly logs -a m0serve-docs                          # one access-log line per response
```

Afterwards, once and by hand: point the GitHub repository's homepage field
at the site (`gh repo edit --homepage https://m0serve.dev`) and submit the
sitemap in Google Search Console. The PyPI project's Documentation link is in
`packaging/m0serve/pyproject.toml` and rides the next release.

## Cost and shape, for the record

Measured before choosing the machine: 22 MB RSS per worker, 12 MB for the
supervisor, 2.5 MB of files, a page served in 0.26 ms locally. A
shared-cpu-1x with 256 MB is $2.02 a month at Fly's 2026-09 prices, always
on; a second machine in the region doubles that and is the reliability
knob for the static site. The live demo, when it comes, is a separate app
on a subdomain so untrusted realtime traffic never shares a process with
the docs.
