# A pure-Mojo image

`apps/hello` compiled by the pinned toolchain in a builder stage, and a
runtime stage carrying the binary, the three Mojo runtime libraries it needs,
and nothing else. No interpreter. No toolchain.

```bash
uv run poe smoke-mojo-image            # build, then probe from outside
M0_TARGET_CPU=x86-64-v2 uv run poe smoke-mojo-image
```

This exists because everything in the Mojo-native direction rests on it and
none of it had been tried: the toolchain ships as a wheel, but whether it
installs and compiles inside a Linux image, what the result weighs, and
whether it behaves as PID 1 under `docker stop` were all open.

## Measured, 2026-09-15, `linux/arm64` under colima on an Apple M4

| | this image | the Django demo (`deploy/demo/README.md`) |
|---|---|---|
| image | 29.2 MB | 74 MiB |
| RSS, idle | 12.1 MB | 52 MB per worker, 9 MB supervisor |
| RSS, 100 keep-alive connections held | 13.5 MB | — |
| what runs | one binary | CPython, Django, m0serve |

The app's own payload is four files totalling 2.5 MB — `hello` at 645 KB plus
`libKGENCompilerRTShared`, `libAsyncRTRuntimeGlobals` and
`libMSupportGlobals` — on a 28.1 MB `debian:12-slim` base. So the base is
almost the whole image, and a smaller one (distroless, or a static link) is
where the next cut would come from, not from the binary.

`docker stop` is the drain: exit 0, immediately, with connections open.
`/proc/1/cmdline` reads `/app/hello`, read inside the container rather than
trusted.

## Two things the build needs that are easy to miss

- **A C compiler.** `mojo build` drives one for the link step, so the
  toolchain wheel alone is not enough: without `build-essential` the build
  stops with `unable to find suitable c compiler for linking`. It stays in
  the builder stage.
- **A build context.** The repository's `.dockerignore` excludes everything
  and lets back in only what the two Python images COPY, so this image's
  first build failed with `"/scripts": not found`. Its own allowance is
  deliberately narrow — the toolchain pin, the packages, the one app, and the
  three scripts that make a linked artifact redistributable — and it excludes
  `**/*.mojoc`, because the builder precompiles its own and a stale one from
  the host would be a silent toolchain mismatch.

`relocate.py` rewrites `DT_RUNPATH` (the build venv's path is recorded
otherwise; `patchelf` is what it uses) and `bundle_artifact.py` walks the
dependency graph to copy the runtime libraries in. The binary carries no
builder path afterwards, which is checked by grep rather than assumed.

## What this does NOT prove

- **x86-64.** This was built and measured on `linux/arm64`. The toolchain
  publishes a `manylinux_2_34_x86_64` wheel, so the build is expected to
  work, but it has to run on a real x86 machine — QEMU is not evidence
  (`fly-local-build-emulates-amd64`: a local amd64 build SIGFPEs under it).
  A GitHub `ubuntu-latest` runner or Fly's remote builder is the arm that
  settles it, with `M0_TARGET_CPU=x86-64-v2` as `build-serve` uses.
- **A deploy.** Nothing here is deployed anywhere; that is a separate
  decision, and it needs a name and a subdomain first.
- **An app that does more than answer.** `apps/hello` has no SSE, no
  WebSockets, no pool. The RSS figures are a floor, not a working set.
