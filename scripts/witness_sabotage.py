#!/usr/bin/env python3
"""Break each rule of m0-sqlite's table witness in turn (SPEC O32), and
insist the test that claims it fails.

The witness is a cache's reason to keep a rendering, so every one of its
failures is the quiet kind: a rendering kept that the table no longer
matches. Each entry reverts one rule by an EXACT source line of
`src/witness.mojo` and runs `test_witness.mojo`, which must fail in its own
words:

- **the order:** `settle` takes the position `look` read, never a fresh
  one. That rule is the one a pressure test cannot see: the page it leaves
  stale is repaired by the next write within microseconds. Only an injected
  commit, after the rendering's snapshot and before `settle`, catches it.
- **a reset log** is UNKNOWN. Read as the same generation, the frames of
  the new log are skipped or misread.
- **page 1** is UNKNOWN. That is where pages change hands, and the page map
  is only right while none has.
- **the tables' own pages** are CHANGED.
- **a table is named as SQLite names it,** and a name no table answers to,
  or a table with no pages, is no map. A map of nothing answers UNCHANGED
  for every write: `"Notes"` looked up in `dbstat` as given did exactly that
  (review, 2026-11-25).

About two minutes: seven `mojo run`s of one test file.

    python3 scripts/witness_sabotage.py
    python3 scripts/witness_sabotage.py --only order
"""

from __future__ import annotations

import sys
from pathlib import Path

from sabotage_lib import MojoRun, rule, run

WITNESS = Path("packages/m0-sqlite/src/witness.mojo")
TESTS = Path("packages/m0-sqlite/test/test_witness.mojo")

RULES = [
    rule(
        "order: settle covers what look read, not a fresh position (O32)",
        WITNESS,
        "        self._covered = self._pending\n",
        "        self._covered = self._position()\n",
        expect="test_a_commit_the_rendering_does_not_hold_is_looked_at_next",
    ),
    rule(
        "reset: a log restarted after a checkpoint is UNKNOWN (O32)",
        WITNESS,
        "        if now.salt != self._covered.salt or now.max_frame < self._covered.max_frame:\n",
        "        if False:\n",
        expect="test_what_moves_pages_between_owners_is_unknown",
    ),
    rule(
        "page 1: a frame of page 1 is UNKNOWN (O32)",
        WITNESS,
        "            if page == 1:\n",
        "            if page == -1 and False:\n",
        expect="test_what_moves_pages_between_owners_is_unknown",
    ),
    rule(
        "names: a table is looked up as SQLite names it, not as given (O32)",
        WITNESS,
        "                pages.bind_text(1, stored)\n",
        "                pages.bind_text(1, self._tables[t])\n",
        expect="test_a_table_is_named_as_sqlite_names_it",
    ),
    rule(
        "empty: a table with no pages is no map (O32)",
        WITNESS,
        "                if found == 0:\n",
        "                if found < 0:\n",
        expect="test_a_table_with_no_pages_is_no_map",
    ),
    rule(
        "missing: a name no table answers to is UNKNOWN, naming it (O32)",
        WITNESS,
        "                if not named.step():\n",
        "                if not named.step() and False:\n",
        expect="test_a_table_is_named_as_sqlite_names_it",
    ),
    rule(
        "own pages: a frame of the tables' pages is CHANGED (O32)",
        WITNESS,
        "                hit = True\n",
        "                hit = False\n",
        expect="test_the_tables_own_writes_are_never_unchanged",
    ),
]


def main(argv: list[str]) -> int:
    return run(
        "sabotage-witness", RULES,
        MojoRun(TESTS, includes=("packages/m0-sqlite",)), argv,
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
