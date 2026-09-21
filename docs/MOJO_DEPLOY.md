# Deploy

A Mojo application ships as the binary and the Mojo runtime libraries
beside it. `m0 new` writes `deploy/Dockerfile`, `deploy/fly.toml` and a
`.dockerignore`; `m0 image` builds the image.

## The release build

```bash
uv run m0 build --release
```

This compiles for the platform's baseline CPU rather than the machine doing
the build, rewrites the binary's library search path to its own directory,
and bundles the runtime into `dist/`. `dist/` is relocatable: copy it
anywhere on the same platform and run `dist/server`. `--target-cpu CPU`
compiles for something newer; `native` is refused, because the machine
that builds is rarely the machine that runs.

A build needs a C compiler reachable as `cc`: `mojo build` links through
that name and takes no other. `m0 build` checks for it first, with a link
test, and refuses with exit 78 naming the package to install
(`build-essential`, or Xcode's command line tools). `m0 test` needs none.

## The image

```bash
uv sync               # once; commit uv.lock
uv run m0 image       # docker build -f deploy/Dockerfile -t NAME .
docker run --rm -p 8080:8080 NAME
```

`m0 image` needs docker and a committed `uv.lock`, and no local toolchain:
the builder stage runs `uv sync --frozen` and `uv run m0 build --release`.
The runtime stage copies `dist/` onto `debian:12-slim` and runs the binary
as PID 1, as an unprivileged user. `--tag T` names the image (the default
is the project directory's name), `--target-cpu CPU` reaches the release
build, and everything after a bare `--` goes to `docker build`, for example
`-- --platform linux/amd64`.

### What `about.json` proves

The image's last layer measures the image from inside and writes
`/app/about.json`; `m0 image` prints it as its last line.

```json
{"app":"shop","version":"0.1.0","arch":"x86_64","cpu":"x86-64-v2","base":"debian:12-slim","python":false,"app_bytes":2953336,"image_bytes":102047098}
```

| key | source |
|---|---|
| `python` | always `false`: the layer searches the filesystem for an interpreter and fails the build if it finds one |
| `cpu` | what the builder's release build said it compiled for, not what was asked |
| `app_bytes`, `image_bytes` | `du` over `/app` and over the whole filesystem, unpacked |
| `version` | the project's `pyproject.toml` |

<!-- observed: docs/notes/dev-image-and-a-release.md, the views scaffold on Linux aarch64 in colima on an M4, cold; the JSON above is that measurement with the arch and cpu of an x86-64 build -->
The `views` scaffold's `/app` is about 3 MB and the image about 102 MB
unpacked, nearly all of it the Debian base. A cold build spends about 10 s
on apt, 5 s on the frozen sync and 13 s compiling.

CI builds this image from a freshly scaffolded project on x86-64 Linux on
every pull request, reads `about.json`, checks PID 1, probes the
application through a published port and requires `docker stop` to exit 0
(N31 in [Capabilities](SPEC.md)).

## Fly.io

```bash
fly apps create NAME
fly deploy -c deploy/fly.toml --remote-only
fly scale count 1 -a NAME
```

- **`--remote-only`.** Fly's machines are x86-64. An image built on an Apple
  Silicon laptop is built under emulation, and the Mojo compiler does not
  survive it.
- **`scale count 1`.** The first deploy creates two machines. An application
  whose state lives in the process has one machine's state on each.
- **One loop.** On one shared vCPU a second worker or loop has no core to
  run on, so the scaffold's `fly.toml` leaves `M0_WORKERS` and `M0_THREADS`
  unset.
- The scaffold's `fly.toml` counts connections rather than requests, never
  stops the machine, and sets a 25-second SSE heartbeat: a held stream is
  one connection for its whole life, and a quiet one needs traffic to stay
  open through the proxy.

The health check is `GET /health`, which both scaffolds answer on the event
loop.

## Behind a proxy

The server speaks HTTP/1.1 and no TLS; terminate TLS in front of it.
SIGTERM drains and exits 0 within five seconds, which is inside
`docker stop`'s default grace. [The host](MOJO_HOST.md) has the shutdown
rules and every environment variable the binary reads.

<https://blobs.m0serve.dev> is `apps/blobs` from the repository, deployed
this way; its footer is its own `about.json`.
