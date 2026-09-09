#!/bin/bash
# One-time setup of the persistent Linux build container (`m0lin`): copy the
# tree out of the read-only /src mount into /work, sync the toolchain, build
# every package and the m0serve binary. Re-run `scripts/probes/linux_sync.sh` after
# editing sources on the Mac to copy them over and rebuild.
#
# Create the container with NO bind mount and tar the tree in, which is
# what `stress-pool` does and the shape to prefer:
#
#   docker run -d --name m0lin --platform linux/arm64 \
#     ghcr.io/astral-sh/uv:python3.13-bookworm sleep infinity
#   tar --exclude=.venv --exclude=.git --exclude='packages/*/*.mojoc' \
#       --exclude='bin/*' --exclude=.claude -cf - . \
#     | docker exec -i m0lin bash -c 'mkdir -p /src && cd /src && tar -xf -'
#   docker exec m0lin bash /src/scripts/probes/linux_setup.sh
#
# **A bind-mounted `-v "$PWD":/src:ro` works and then silently stops.**
# Measured 2026-09-08 after a `colima stop` / `colima start --cpu 8`: the
# container came back Up and `/src` served a FROZEN tree -- README.md two
# days old, a file created seconds earlier not visible at all. Every build
# from it succeeded, against the wrong sources, and nothing said so. The
# mount also materialises macOS extended attributes as AppleDouble files
# (below). `linux_sync.sh` takes a `M0_SYNC_STAMP` from the caller to catch
# both; if it trips, recreate the container rather than trying to refresh
# the mount.
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq curl gcc libsqlite3-dev patchelf procps >/dev/null
mkdir -p /work
cd /src
tar --exclude=.venv --exclude=.git --exclude='packages/*/*.mojoc' --exclude='bin/m0serve*' --exclude='bin/*.dylib' --exclude='.claude' -cf - . | (cd /work && tar -xf -)
# AppleDouble files reach `/src` two ways and `mojo` parses `._foo.mojo` as
# source and dies on "unexpected character". Measured 2026-09-08, with the
# Mac tree holding ZERO of them on disk: a virtiofs bind mount materialises
# macOS extended attributes as `._*` in the guest (213 under packages/),
# and a whole-tree `tar -cf - .` from the Mac carries 816. The subset tar
# `stress-pool` uses (packages, scripts, apps, pyproject, uv.lock, bench)
# carries none, which is why that gate never hit this.
_ad=$(find /work -name '._*' 2> /dev/null | wc -l | tr -d " ")
find /work -name '._*' -delete 2> /dev/null || true
[ "$_ad" = 0 ] || echo "=== removed $_ad AppleDouble file(s) the copy carried in ==="
cd /work
echo "=== uv sync ==="
uv sync 2>&1 | tail -2
echo "=== builds ==="
uv run poe build-core
uv run poe build-http
uv run poe build-wsgi
uv run poe build-serve
echo "=== doctor ==="
uv run bin/m0serve --doctor bareapp.wsgi --app-dir apps/wsgi_bare 2>&1 | head -8
echo "=== linux setup done ==="
