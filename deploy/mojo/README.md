# A pure-Mojo image

One Dockerfile for every Mojo app. The pinned toolchain compiles the app in a
builder stage, and the runtime stage carries the binary, the three Mojo
runtime libraries it needs, and nothing else: no interpreter, no toolchain.
`APP` names the directory under `apps/`, and the binary is `/app/server`
whatever the app.

```bash
uv run poe smoke-blobs-image      # apps/blobs: build, then probe from outside (every PR)
uv run poe probe-mojo-image       # apps/hello: the floor under every Mojo image
uv run poe sabotage-mojo-image    # ten sabotaged images, each caught where it should be

docker build -f deploy/mojo/Dockerfile --build-arg APP=blobs --build-arg TARGET_CPU=generic .
```

`TARGET_CPU` is never `native`. The probe picks it from the docker daemon's
architecture: `x86-64-v2` on x86-64, `generic` on arm64. `M0_TARGET_CPU`
overrides it.

## The image says what it is

The runtime stage's last layer measures the image from inside it: the
unpacked bytes of the whole filesystem and of `/app`, and whether an
interpreter is anywhere in it. **The build fails if one is.** It writes the
result, with the version, target CPU, architecture and base, to
`/app/about.json`, and sets `M0_IMAGE_FACTS` to that path. An app that wants
to say what it runs in reads the file: `apps/blobs`'s footer and `/about` do
(`apps/blobs/about.mojo`). So "no Python in this image" and the size are
measurements, not prose, and the probe checks them again from outside.

## Measured, 2026-09-18

On `linux/arm64` under colima on an Apple M4, with the Django demo's image
built from the 1.4.0 wheel on the same machine. Image sizes are decimal MB;
RSS is VmRSS in MiB, summed over the server's processes.

| | blobs | hello | the Django demo |
|---|---|---|---|
| image, compressed | 29.3 MB | 29.2 MB | 60.3 MB |
| image, unpacked | 102.1 MB | 101.6 MB | 184.6 MB |
| the app's own bytes | 3.0 MB | 2.5 MB | — |
| RSS idle | 13.6, one loop | 11.9 | 112.8: a 9.1 supervisor and two 52 workers |
| RSS, 100 connections held | 16.4 (streams) | 13.2 (keep-alive) | — |

On x86-64, the blobs image as CI's `pid1` job builds it on every pull
request, on a GitHub runner whose docker store counts unpacked bytes (run
35401394882): 80.1 MB unpacked, 3.4 MB of it the app, on a Debian base
that is smaller on amd64. RSS was 20.1 MiB idle and 24.2 MiB with 100
streams held, more than on arm64. It built in 58 s from a cold cache, and
the whole step, build and probe, took 66 s.

**Compressed and unpacked are different numbers, and so is memory.** Until
this date the page compared "29.2 MB" with "74 MiB". The first was the hello
image's COMPRESSED size: colima's containerd image store reports compressed
layers from `docker image inspect`. The second was the Django demo
CONTAINER's memory with three streams held, not an image size. The probe now
records which size the daemon reports, and the table above gives both, for
all three images, measured the same way.

The app's own payload is four files: the binary (0.58 MB for hello, 1.07 MB
for blobs) plus `libKGENCompilerRTShared`, `libAsyncRTRuntimeGlobals` and
`libMSupportGlobals`. They sit on a `debian:12-slim` base of 99.1 MB
unpacked. So a smaller base (distroless, or a static link) is where the next
cut would come from, not the binary.

## Three things the build needs that are easy to miss

- **A C compiler.** `mojo build` drives one for the link step, so the
  toolchain wheel alone is not enough. Without `build-essential` the build
  stops with `unable to find suitable c compiler for linking`. It stays in
  the builder stage.
- **A build context.** The repository's `.dockerignore` excludes everything
  and lets back in only what an image copies. Each app is let in BY NAME, so
  a new app's first build fails naming its missing `server.mojo` until it is
  added. `**/*.mojoc` stays excluded: the builder precompiles its own, and a
  stale one from the host would be a silent toolchain mismatch.
- **A binary that names no builder path.** `bundle_artifact.py` copies the
  runtime libraries in and rewrites the bundled copy's `DT_RUNPATH` to
  `$ORIGIN`. It does this whether or not `relocate.py` ran first: removing
  `relocate.py` alone still built a working image, measured. What the build
  checks is the result. A bundled binary that still names the build venv
  fails the build by name.

## What this does NOT prove

- **Fly's own CPU.** The modes were compared pinned to one core and throttled
  to a shared-cpu-1x's baseline share with a cgroup quota
  (docs/notes/the-demo-in-its-own-image.md). That is not Fly's burst
  balance, and it did not run on Fly's hosts.
- **A smaller base.** The image is mostly Debian.
