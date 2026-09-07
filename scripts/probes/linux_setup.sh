#!/bin/bash
# One-time setup of the persistent Linux build container (`m0lin`): copy the
# tree out of the read-only /src mount into /work, sync the toolchain, build
# every package and the m0serve binary. Re-run `scripts/probes/linux_sync.sh` after
# editing sources on the Mac to copy them over and rebuild.
#
#   docker run -d --name m0lin --platform linux/arm64 -v "$PWD":/src:ro \
#     ghcr.io/astral-sh/uv:python3.13-bookworm sleep infinity
#   docker exec m0lin bash /src/scripts/probes/linux_setup.sh
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq curl gcc libsqlite3-dev patchelf procps >/dev/null
mkdir -p /work
cd /src
tar --exclude=.venv --exclude=.git --exclude='packages/*/*.mojoc' --exclude='bin/m0serve*' --exclude='bin/*.dylib' --exclude='.claude' -cf - . | (cd /work && tar -xf -)
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
