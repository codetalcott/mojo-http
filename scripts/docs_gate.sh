#!/bin/sh
# The docs gate: everything the one required check on `main` runs, in one
# file. The `check-docs` job in .github/workflows/docs.yml and
# `poe check-docs` both run THIS, so what you run before a push is what the
# required check runs. They used to keep separate lists and each skipped
# checks the other ran (review H4); check_docs.py's check_docs_gate_shared
# now holds both call sites to this file.
#
# Standard-library Python (3.11 or later: check_docs and spec_sheet read
# pyproject.toml with tomllib) plus pyflakes -- no uv, no Mojo toolchain,
# nothing compiled -- which is what lets docs.yml run it on the runner's own
# python3. Under `uv run poe check-docs`, `python3` is the project's venv,
# whose dev group carries pyflakes.
#
# About 3 s on an M-series Mac (2026-09-28), so there is no faster subset
# for local use: the whole gate is the pre-push check.
#
# Every part runs even after one fails, and the summary names each failure,
# so a pull request learns all of its drift in one run rather than one per
# push.

cd "$(dirname "$0")/.." || exit 2

failed=
part() {
  label=$1
  shift
  echo "--- $label"
  if ! "$@"; then
    failed="$failed
  - $label"
  fi
}

# Selftests first. Each checker below is proven able to fail before its pass
# is believed: a doc checker that cannot fail is green having tested nothing.
# check_docs runs `render_bench_docs --check` for the tables and the prose
# spans, the docs site's link check (`docsite --check`), the shim's rendering
# check (`render_shim --check`) and the citation tracker
# (`check_citations.check`); `bench_guard.py wait` is what stands between a
# busy laptop and a committed benchmark artifact.
part "render_bench_docs selftest" python3 scripts/render_bench_docs.py --selftest
part "docsite selftest" python3 scripts/docsite.py --selftest
part "render_shim selftest" python3 scripts/render_shim.py --selftest
part "check_citations selftest" python3 scripts/check_citations.py --selftest
part "bench_guard selftest" python3 scripts/bench_guard.py --selftest
# check_docs' own rules, each reverted against the committed text.
part "check_docs selftest" python3 scripts/check_docs.py --selftest

# The ratchet itself: every machine-sourced doc fact against its source, and
# docs/SPEC.md's rules (scripts/spec_sheet.py) with it.
part "check_docs" python3 scripts/check_docs.py

# The executor shim is a Python file precisely so a linter can read it: a
# NameError inside it surfaces at run time as streams truncated at 64 KB
# with a log line that says only "raised after its head".
part "pyflakes over the executor shim" \
  python3 -m pyflakes packages/m0-wsgi/shim/m0_shim.py scripts/render_shim.py

# Guard the guards. Each rule is reverted -- in memory, the tree is never
# written -- and its checker must catch every one; a sabotage whose patch no
# longer applies is itself a failure, which is what stops a rule being
# renamed out of existence quietly.
part "spec_sheet sabotage" python3 scripts/spec_sheet.py --sabotage
part "check_citations sabotage" python3 scripts/check_citations.py --sabotage

# The milestone rot gates read docs/SPEC.md, ROADMAP's Known issues and the
# soak record -- all under docs/**, which test.yml ignores, so until they ran
# here a doc-only pull request could break them and the next code pull
# request would find out.
part "milestones check" python3 scripts/milestones.py --check
part "milestones sabotage" python3 scripts/milestones.py --sabotage

if [ -n "$failed" ]; then
  printf 'docs gate: FAIL%s\n' "$failed"
  exit 1
fi
echo "docs gate: every part passed"
