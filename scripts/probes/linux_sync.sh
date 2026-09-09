#!/bin/bash
# Copy the Mac tree's sources over the container's /work and rebuild what
# the arguments name (default: everything after core). Runs INSIDE the
# container.
#
#   M0_SYNC_STAMP=$(bash scripts/probes/source_stamp.sh) \
#     docker exec -e M0_SYNC_STAMP m0lin bash /src/scripts/probes/linux_sync.sh
#   docker exec m0lin bash /src/scripts/probes/linux_sync.sh serve   # fork-only edit
#
# Three things here are load-bearing, and each was a silent wrong answer
# before it existed (measured 2026-09-08):
#
#   - `pipefail`, because `poe build-X | tail -3` under a bare `set -e`
#     exits with TAIL's status. Every build in the loop below failed to
#     parse, the script printed the errors, carried on, and returned 0.
#   - no bare `echo` as the last statement, for the same reason: it was
#     the script's exit status, so `docker exec ... || exit 1` in
#     `stress-pool` could never fire. A pre-release gate was rebuilding
#     nothing and reporting success.
#   - the stamp, because `/src` cannot be trusted to be the caller's tree.
#     `stress-pool` tars it in (a partial extraction leaves a mixture),
#     and the `linux_setup.sh` bind-mount recipe reads a virtiofs mount
#     that was measured FROZEN after a `colima stop`/`start`: README.md
#     two days stale, a brand-new file invisible, the container reporting
#     itself Up throughout. Note the script you are reading came through
#     that same mount, which is exactly why it cannot detect this on its
#     own -- the caller passes the stamp in.
# No `2>/dev/null` on the tar below: a missing path makes GNU tar exit 2,
# and suppressing its stderr turned that into a failure with NO message at
# all -- measured against a remote host whose /src lacked `bench`.
set -euo pipefail
cd /src
tar --exclude=.venv --exclude=.git --exclude='packages/*/*.mojoc' --exclude='bin/m0serve*' --exclude='bin/*.dylib' --exclude='.claude' -cf - packages scripts apps pyproject.toml bench | (cd /work && tar -xf -)
# virtiofs materialises macOS extended attributes as AppleDouble files in
# the guest, so `/src` carries a `._which_package.mojo` beside sources the
# Mac shows as clean (213 of them, measured). `mojo` then tries to parse
# one as source and the build dies on "unexpected character".
_ad=$(find /work -name '._*' 2> /dev/null | wc -l | tr -d " ")
find /work -name '._*' -delete 2> /dev/null || true
[ "$_ad" = 0 ] || echo "=== removed $_ad AppleDouble file(s) the copy carried in ==="
# `build-ffi` is in the default list because the realtime app's m0pub loads
# packages/m0-core/libm0core.so, and the pool reproducers serve that app.
cd /work
got=$(bash scripts/probes/source_stamp.sh)
if [ -n "${M0_SYNC_STAMP:-}" ] && [ "$got" != "$M0_SYNC_STAMP" ]; then
  echo "linux_sync: the tree in the container is NOT the tree you sent." >&2
  echo "  expected $M0_SYNC_STAMP (caller)   got $got (/work after the copy)" >&2
  echo "  A bind-mounted /src goes stale across a colima restart; recreate the" >&2
  echo "  container, or tar the tree in from the Mac the way stress-pool does." >&2
  exit 1
fi
echo "=== sources $got ${M0_SYNC_STAMP:+(matches the caller)} ==="
steps="${@:-http datastar wsgi serve ffi}"
for s in $steps; do
  echo "=== build-$s ==="
  uv run poe "build-$s" 2>&1 | tail -3
done
