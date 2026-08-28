#!/bin/bash
# The epoll half of the loop inversion, verified in a Linux container.
#
# The development box is a Mac, so every local run of `M0_INVERTED=1` is the
# kqueue half; this runs the epoll half under colima before CI does, the way
# the release path is rehearsed (docs/RELEASING.md, memory: "prefer local
# container verification"). First run 2026-08-28: linux/aarch64, CPython
# 3.13.11 -- smoke-asgi OK with 0 KB RSS over 10k requests, the recycled-slot
# probe OK, stress-asgi 30/30 under 8 hogs.
#
#   colima start --cpu 4 --memory 8
#   docker run --rm -v "$PWD":/src:ro ghcr.io/astral-sh/uv:python3.13-bookworm \
#     bash /src/scripts/epoll_inverted_check.sh
#
# Two colima mechanics: only paths under $HOME mount (a /tmp bind mounts
# EMPTY, silently), and the tree is copied out of the read-only mount before
# `uv sync` so the Linux .venv and .mojoc artifacts never touch the Mac's.
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq curl gcc libsqlite3-dev patchelf >/dev/null
mkdir -p /work
cd /src
tar --exclude=.venv --exclude=.git --exclude='packages/*/*.mojoc' --exclude='bin/m0serve' -cf - . | (cd /work && tar -xf -)
cd /work
echo "=== uv sync ==="
uv sync 2>&1 | tail -2
echo "=== builds ==="
uv run poe build-core
uv run poe build-http
uv run poe build-wsgi
uv run poe build-serve
echo "=== m0serve --doctor (interpreter, loop) ==="
uv run bin/m0serve --doctor bareapp.asgi:application --app-dir apps/asgi_bare 2>&1 | head -12
echo "=== inverted smoke-asgi on epoll ==="
M0_INVERTED=1 uv run poe smoke-asgi 2>&1 | tail -12
echo "=== inverted probe on epoll ==="
M0_INVERTED=1 uv run bin/m0serve bareapp.asgi:application --app-dir apps/asgi_bare --port 8299 > /tmp/inv_epoll.log 2>&1 &
pid=$!
curl -s --retry 30 --retry-delay 1 --retry-all-errors -m 5 -o /dev/null -w 'ready: %{http_code}\n' http://127.0.0.1:8299/
head -3 /tmp/inv_epoll.log
M0_PORT=8299 uv run python3 scripts/chunked_keepalive.py 2>&1 | tail -1
kill -TERM $pid; wait $pid || true
echo "=== inverted stress-asgi on epoll ==="
M0_INVERTED=1 uv run poe stress-asgi 2>&1 | tail -2
echo "=== epoll check done ==="
