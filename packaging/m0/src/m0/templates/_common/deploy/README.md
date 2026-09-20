# Deploying __M0_APP__

The image holds the binary, the Mojo runtime libraries beside it, and no
Python. Everything here runs from the PROJECT ROOT, which is the build
context.

## The image

```sh
uv sync                                         # once; commit uv.lock
docker build -f deploy/Dockerfile -t __M0_APP__ .
docker run --rm -p 8080:8080 __M0_APP__
```

The builder stage runs `uv run m0 build --release`: the platform's baseline
CPU, never the builder's own. `/app/about.json` in the image is what the
image measured about itself (its size, and that no interpreter is in it).

## Fly.io

```sh
fly apps create __M0_APP__
fly deploy -c deploy/fly.toml --remote-only
fly scale count 1 -a __M0_APP__
```

- `--remote-only`: an image built on an Apple Silicon laptop is built under
  emulation for Fly's x86-64 machines, and the Mojo compiler does not
  survive that.
- `scale count 1`: the first deploy creates two machines. State held in
  the process is one machine's; see the comment in `fly.toml`.
- One loop. On one shared vCPU a second worker or thread cannot run beside
  the first, so `M0_WORKERS`/`M0_THREADS` stay unset.
