#!/bin/bash
# Copy the Mac tree's sources over the container's /work and rebuild what
# the arguments name (default: everything after core).
#   docker exec m0lin bash /src/scripts/probes/linux_sync.sh            # http datastar wsgi serve ffi
#   docker exec m0lin bash /src/scripts/probes/linux_sync.sh serve      # fork-only edit
set -e
cd /src
tar --exclude=.venv --exclude=.git --exclude='packages/*/*.mojoc' --exclude='bin/m0serve*' --exclude='bin/*.dylib' --exclude='.claude' -cf - packages scripts apps pyproject.toml bench 2>/dev/null | (cd /work && tar -xf -)
# `build-ffi` is in the default list because the realtime app's m0pub loads
# packages/m0-core/libm0core.so, and the pool reproducers serve that app.
cd /work
steps="${@:-http datastar wsgi serve ffi}"
for s in $steps; do
  echo "=== build-$s ==="
  uv run poe "build-$s" 2>&1 | tail -3
done
echo "=== linux sync done ==="
