# Deploy

A Mojo application ships as the binary and the Mojo runtime libraries
beside it. `m0 new` writes `deploy/Dockerfile`, `deploy/fly.toml` and a
`.dockerignore`; `m0 image` builds the image.

## The release build

```bash
uv run m0 build --release
```

This compiles for the platform's baseline CPU, whatever machine does the
build, rewrites the binary's library search path to its own directory,
and bundles the runtime into `dist/`. `dist/` is relocatable: copy it
anywhere on the same platform and run `dist/server`. `--target-cpu CPU`
compiles for something newer; `native` is refused, because the machine
that builds is rarely the machine that runs. The bundle is read from the
binary: the libraries it names and the libraries those name, so an
application that links MAX's parallel runtime (`parallelize`) ships
`libAsyncRTMojoBindings` beside it with the rest (E32 in
[Capabilities](SPEC.md)).

A build needs a C compiler reachable as `cc`: `mojo build` links through
that name and takes no other. `m0 build` checks for it first, with a link
test, and refuses with exit 78 naming the package to install
(`build-essential`, or Xcode's command line tools). `m0 test` needs none.

On Linux, `m0 build --release` also needs `patchelf`, which rewrites the
binary's library search path after the compile. `m0 build --release` checks
for it first and refuses with exit 78 naming the install
(`apt-get install patchelf`); a development build does not need it, and
`m0 doctor` does not ask. The scaffold's `deploy/Dockerfile` installs it in
the builder.

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
is the project's name in `pyproject.toml`, else the directory's), `--target-cpu CPU` reaches the release
build, and everything after a bare `--` goes to `docker build`, for example
`-- --platform linux/amd64`.

The storage packages link nothing and open their C library at run time, so
the runtime stage installs it: `libsqlite3-0` by default, and an
application on Postgres adds libpq with `-- --build-arg
RUNTIME_LIBS="libsqlite3-0 libpq5"`. `about.json`'s `libs` records what
went in. The image sets `M0_DB` to a file under `/app/data`, the one
directory the container may write; a deploy keeps that data only on a
volume mounted there (the Fly.io section below).

### What `about.json` proves

The image's last layer measures the image from inside and writes
`/app/about.json`; `m0 image` prints it as its last line (N31 in
[Capabilities](SPEC.md)).

```json
{"app":"shop","version":"0.1.0","arch":"x86_64","cpu":"x86-64-v2","base":"debian:12-slim","libs":"libsqlite3-0","python":false,"app_bytes":2953336,"image_bytes":102047098}
```

| key | source |
|---|---|
| `python` | always `false`: the layer searches the filesystem for an interpreter and fails the build if it finds one |
| `cpu` | the CPU the builder's release build reported compiling for: the platform's baseline unless `--target-cpu` named one |
| `libs` | the `RUNTIME_LIBS` build argument the runtime stage installed |
| `app_bytes`, `image_bytes` | `du` over `/app` and over the whole filesystem, unpacked |
| `version` | the project's `pyproject.toml` |

<!-- observed: docs/notes/dev-image-and-a-release.md, the views scaffold on Linux aarch64 in colima on an M4, cold; the JSON above is that measurement with the arch and cpu of an x86-64 build -->
The `views` scaffold's `/app` is about 3 MB and the image about 102 MB
unpacked, nearly all of it the Debian base. A cold build spends about 10 s
on apt, 5 s on the frozen sync and 13 s compiling.

## Fly.io

```bash
fly apps create NAME
fly deploy -c deploy/fly.toml --remote-only
fly scale count 1 -a NAME
```

- Build with `--remote-only`: Fly's machines are x86-64, and on an Apple
  Silicon laptop the image is built under emulation, which the Mojo
  compiler does not survive.
- Scale to one machine: the first deploy creates two, and an application
  whose state lives in the process would have one machine's state on each.
- One loop: on one shared vCPU a second worker or loop has no core to
  run on, so the scaffold's `fly.toml` leaves `M0_WORKERS` and `M0_THREADS`
  unset. On a machine with more than one vCPU, set `M0_THREADS` to the
  count ([the host](MOJO_HOST.md)).
- The scaffold's `fly.toml` counts connections rather than requests, never
  stops the machine, and sets a 25-second SSE heartbeat: a held stream is
  one connection for its whole life, and a quiet one needs traffic to stay
  open through the proxy.
- Safari behind Fly's proxy: the proxy speaks HTTP/2 to the browser
  and can forward an event in two pieces, and Safari's `fetch` reader holds
  the second until something follows it. The server sends a comment
  shortly after each event for that (`M0_SSE_FLUSH_MS`, SPEC I47), so a
  quiet stream needs no faster heartbeat.
- Give the database a volume: `fly volumes create data --size 1 -a NAME
  -r iad`, then the `[mounts]` block the scaffold's `fly.toml` carries
  commented out: it names the volume, and a deploy naming one that does
  not exist fails. Without it the `live` scaffold's kick count, and
  anything else under `/app/data`, starts empty on every deploy.

The health check is `GET /health`, which every scaffold answers on the event
loop.

## Behind a proxy

The server speaks HTTP/1.1 and no TLS; terminate TLS in front of it.
SIGTERM drains and exits 0 within five seconds, which is inside
`docker stop`'s default grace. [The host](MOJO_HOST.md) has the shutdown
rules and the configuration the binary reads.

<https://blobs.m0serve.dev> is `apps/blobs` from the repository, deployed
this way; its footer is its own `about.json`.
