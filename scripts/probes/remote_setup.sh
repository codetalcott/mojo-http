#!/bin/bash
# One-time provisioning of a REMOTE Linux host for `bench-linux-conclusions`
# (`--remote user@host`). The container's sibling: `linux_setup.sh` starts
# from an image that already has uv and Python, a bare Debian 12 host has
# neither, and it needs the load generator too.
#
#   scp this to the host and run it as root, or let
#   scripts/bench_linux_conclusions.py --remote do it for you.
#
# Debian 12 (bookworm) on purpose: it is what the m0lin container runs, so
# the toolchain path is one that already works rather than a second one to
# debug. `wrk` comes from Debian's own repo there.
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "=== apt ==="
apt-get update -qq > /dev/null
# gcc: `mojo build` shells out for linking and says only "unable to find
# suitable c compiler" when it is missing (ROADMAP, Known issues).
# libpython3-dev is NOT optional and nothing says so until you see it:
# `m0serve` EMBEDS CPython and resolves `Py_Initialize` at runtime, and
# Debian's `python3` package ships a STATIC interpreter -- the shared library
# lives in this package. Without it every m0serve arm dies with
# "ABORT: symbol not found: Py_Initialize" and the bench reports each one as
# "never healthy", which reads like a server bug and is a missing .so.
# The container never hits it because its image already has one.
apt-get install -y -qq curl gcc libsqlite3-dev patchelf procps wrk git libpython3-dev > /dev/null
echo "=== uv ==="
if ! command -v uv > /dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh > /dev/null 2>&1
fi
export PATH="$HOME/.local/bin:$PATH"
uv --version
# Pin 3.13, the version the macOS artifacts and the container both used. A
# bare Debian 12 host would otherwise give the venv its system 3.11, and a
# ratio measured against uvicorn on 3.11 is not comparable to one measured
# on 3.13 -- an interpreter difference stacked on top of the platform
# difference this whole exercise exists to isolate. uv's own build ships
# libpython3.13.so, so the embed works from it directly.
uv python install 3.13 > /dev/null 2>&1 || true
mkdir -p /work
echo "=== remote setup done (the tree and the builds follow, from the caller) ==="
