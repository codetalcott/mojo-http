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
apt-get install -y -qq curl gcc libsqlite3-dev patchelf procps wrk git > /dev/null
echo "=== uv ==="
if ! command -v uv > /dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh > /dev/null 2>&1
fi
export PATH="$HOME/.local/bin:$PATH"
uv --version
mkdir -p /work
echo "=== remote setup done (the tree and the builds follow, from the caller) ==="
