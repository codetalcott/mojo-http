#!/bin/bash
# Make a fresh Claude Code on the web session able to build and test this repo.
#
# Three things are missing from a bare container, and each fails in a way that
# reads as a code problem rather than a setup problem:
#
#   * The Linux system packages. README's "Building on Linux needs three
#     system packages" names them: a C compiler (`mojo build` shells out for
#     linking), `patchelf` (binaries record a $ORIGIN DT_RUNPATH so they find
#     the Mojo runtime beside themselves) and `libsqlite3-dev` for m0-sqlite.
#     Without patchelf, `poe build-serve` -- the LAST step of `test-all` --
#     aborts the whole sequence after everything else has passed, saying
#     "on Linux it is a build requirement for this artifact, not an optional
#     cleanup". Nothing else in the run hints that the tree is fine.
#   * The toolchain. `mojo` comes from the venv (`mojo==1.0.0` in
#     pyproject.toml), so without `uv sync` there is no compiler at all.
#   * The .mojoc artifacts. They are gitignored, so a fresh clone has none,
#     and every cross-package import fails to resolve until `build-all` runs
#     -- which CLAUDE.md notes also shows up as unresolved imports in the
#     editor, i.e. exactly like a broken checkout.
#
# Idempotent: the apt step is skipped when the packages are already there,
# `uv sync` is a no-op on an up-to-date venv, and the container state is
# cached after this completes, so the build is paid once.
#
# Every step is BEST EFFORT and the hook always exits 0. A session that
# refuses to start because apt could not reach the network is worse than one
# that starts with a loud note saying what is missing -- the failure this
# exists to prevent is a SILENT one, and a warning here is not silent.
set -uo pipefail

# A developer's own machine has its own setup, and macOS needs none of this.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

if [ "$(uname -s)" = "Linux" ]; then
  SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 && SUDO="sudo"
  fi

  missing=""
  command -v cc >/dev/null 2>&1 || missing="$missing build-essential"
  command -v patchelf >/dev/null 2>&1 || missing="$missing patchelf"
  [ -e /usr/include/sqlite3.h ] || missing="$missing libsqlite3-dev"

  if [ -n "$missing" ]; then
    echo "session-start: installing$missing"
    # shellcheck disable=SC2086
    if ! ($SUDO apt-get update -qq \
          && DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq $missing); then
      echo "session-start: WARNING -- could not install$missing." >&2
      echo "session-start: without patchelf, \`poe build-serve\` fails at the END of" >&2
      echo "session-start: test-all; without libsqlite3-dev, test-sqlite fails to link." >&2
    fi
  else
    echo "session-start: build-essential, patchelf and libsqlite3-dev already present"
  fi
fi

echo "session-start: syncing the venv (brings the pinned Mojo toolchain)"
uv sync || echo "session-start: WARNING -- uv sync failed; there is no mojo compiler" >&2

# --no-sync throughout the repo's tasks: a plain `uv run` re-syncs and would
# silently undo a `poe nightly-try` toolchain swap (CLAUDE.md). Harmless here,
# but the habit is worth keeping consistent.
echo "session-start: building .mojoc artifacts"
uv run --no-sync poe build-all \
  || echo "session-start: WARNING -- build-all failed; cross-package imports will not resolve" >&2

echo "session-start: ready -- uv run --no-sync poe test-all"
exit 0
