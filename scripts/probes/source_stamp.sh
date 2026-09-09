#!/bin/bash
# A content hash of the sources `linux_sync.sh` copies into the Linux
# container, computed IDENTICALLY on the Mac and inside the container.
#
#   bash scripts/probes/source_stamp.sh [ROOT]      # default: .
#
# Why: the sync is only meaningful if the tree that arrived is the tree the
# caller has, and both ways of getting it there can fail silently.
# `stress-pool` tars the tree in from the Mac, and a partial extraction
# leaves a mixture; the `linux_setup.sh` bind-mount recipe reads `/src`,
# and that mount was measured serving a FROZEN snapshot after a `colima
# stop`/`start` -- README.md two days stale, a brand-new file not visible
# at all, while the container reported itself Up. A container that builds
# and passes against the wrong sources is worse than one that fails.
#
# Content only: no mtimes, no inode order, no build artifacts. `sha256sum`
# where it exists (GNU coreutils) and `shasum -a 256` otherwise (macOS);
# both were verified to agree on the same bytes.
set -euo pipefail
cd "${1:-.}"
_hash() { if command -v sha256sum > /dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
# The `._*` exclusion is not cosmetic: virtiofs materialises macOS extended
# attributes as AppleDouble files inside the guest, so the container can see
# a `._which_package.mojo` beside every source that the Mac cannot.
find packages scripts apps -type f \
     \( -name '*.mojo' -o -name '*.py' -o -name '*.sh' \) \
     ! -path '*/.venv/*' ! -name '._*' 2> /dev/null \
  | LC_ALL=C sort \
  | while IFS= read -r f; do cat "$f"; done \
  | _hash | cut -c1-16
