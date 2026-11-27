#!/usr/bin/env python3
"""Break each rule of the table notes app's check in turn (SPEC N57, O33,
DECISIONS D72), and insist the test that claims it fails.

The check is why a client is never left holding a title that a write no
stamp saw replaced, so each of its failures is the quiet kind. Each entry
reverts one rule by an EXACT source line and runs the test file that
claims it, which must fail in its own words:

- **the comparison:** the window's rows against their copies in
  `notes_seen`, read as two scans in id order and merged as they are read.
  Always answered "the same", a bypass reaches no client; and each of the
  merge's three findings is its own rule: a pair whose titles differ, a row
  with no copy at its id, and a copy below the next row, whose row is gone.
- **a copy whose row is gone is found,** over the window's ids, and every
  one in a table shorter than the window: else a row deleted with the
  triggers out of the way stays on every client.
- **the copy moves with every stamped write:** the update trigger left
  out, every stamped edit reads as a bypass and raises the floor for
  nothing.
- **after a raise the copy is set to what the check saw,** and only where
  it is still what the check read: else the difference raises again, a
  stamped write since is overwritten, or a later bypass is taken in.
- **each trigger writes only the copy its own write accounts for:** an
  insert never overwrites a copy, an edit never makes one, so a bypass's
  difference survives the stamped writes after it.
- **a copy is compared as bytes,** or a title stored as a BLOB never
  matches and raises the floor at every check.
- **a restore is found two ways:** a head below the highest read, and a
  moved schema version, which stamped writes cannot move back as they can
  carry the head past.
- **the feed's tick and `/notes/changes` check before they answer.**
- **a failed answer settles nothing,** so a difference found while the
  write lock was held is found again.
- **the head the answer's snapshot reads re-renders the page** after a
  raise elsewhere, which writes neither table.
- **a raise at startup,** for a restore made while no server ran.
- **and the feed's one rule the check leans on:** a row born above a
  subscriber's stamp comes after a delete of its id (N50), since an id
  that came back may still be on the page.
- **`raise_floor` moves the floor, past every stamp given,** in m0-sqlite:
  past the counter a restore brought back, too.

About two minutes on an Apple M4: twenty `mojo run`s of the app's test
file, three of `test_stamps.mojo`.

    python3 scripts/checked_page_sabotage.py
    python3 scripts/checked_page_sabotage.py --only restore
"""

from __future__ import annotations

import sys
from pathlib import Path

from sabotage_lib import MojoRun, rule, run

SERVER = Path("apps/table_notes/server.mojo")
STAMPS = Path("packages/m0-sqlite/src/stamps.mojo")
APP_TESTS = Path("apps/table_notes/test/test_check.mojo")
STAMP_TESTS = Path("packages/m0-sqlite/test/test_stamps.mojo")

RULES = [
    rule(
        "comparison: the window's rows against their copies (N57)",
        SERVER,
        "        if len(differ) > 0 and why.byte_length() == 0:\n",
        "        differ = List[Seen]()\n        if len(differ) > 0 and why.byte_length() == 0:\n",
        gate="app",
        expect="test_a_write_no_stamp_saw_raises_the_floor_over_every_client",
    ),
    rule(
        "gone: a copy below the next row, whose row is gone, is found (N57)",
        SERVER,
        "            while more_s and s.column_int(0) < id:\n"
        "                gone.append(Seen(s.column_int(0), False, String(), True, s.column_text(1)))\n",
        "            while more_s and s.column_int(0) < id:\n",
        gate="app",
        expect="test_a_bypassed_delete_is_found_by_the_copy_it_leaves",
    ),
    rule(
        "short: in a table shorter than the window every copy is read, the last row's included (N57)",
        SERVER,
        "        if shown < CHECK_WINDOW:\n            while more_s:\n",
        "        if False:\n            while more_s:\n",
        gate="app",
        expect="test_a_bypassed_delete_is_found_by_the_copy_it_leaves",
    ),
    rule(
        "uncopied: a row with no copy at its id is a difference (N57)",
        SERVER,
        "                differ.append(Seen(id, True, title^, False, String()))\n",
        "                pass\n",
        gate="app",
        expect="test_a_bypassed_insert_stays_a_difference_after_a_stamped_edit",
    ),
    rule(
        "titles: a row and its copy are compared, title against title (N57)",
        SERVER,
        "                if copy != title:\n",
        "                if False:\n",
        gate="app",
        expect="test_a_write_no_stamp_saw_raises_the_floor_over_every_client",
    ),
    rule(
        "trigger: a stamped update moves the copy with the row (N57)",
        SERVER,
        "    UPDATE notes_seen SET title = new.title WHERE id = new.id AND old.id IS new.id;\n",
        "",
        gate="app",
        expect="test_stamped_writes_never_raise",
    ),
    rule(
        "insert: an insert never overwrites a copy a bypass left (N57)",
        SERVER,
        "        WHERE NOT EXISTS (SELECT 1 FROM notes_seen WHERE id = new.id);\nEND;\n"
        "CREATE TRIGGER IF NOT EXISTS notes_seen_au",
        "        WHERE NOT EXISTS (SELECT 1 FROM notes_seen WHERE id = new.id);\n"
        "    UPDATE notes_seen SET title = new.title WHERE id = new.id;\nEND;\n"
        "CREATE TRIGGER IF NOT EXISTS notes_seen_au",
        gate="app",
        expect="test_a_bypassed_delete_stays_a_difference_after_its_id_comes_back",
    ),
    rule(
        "edit: an update of the same key never makes a missing copy (N57)",
        SERVER,
        "        WHERE old.id IS NOT new.id\n        AND NOT EXISTS",
        "        WHERE NOT EXISTS",
        gate="app",
        expect="test_a_bypassed_insert_stays_a_difference_after_a_stamped_edit",
    ),
    rule(
        "copies: after a raise, the copies are set to what the check saw (N57)",
        SERVER,
        "                self._set_copies(differ)\n",
        "",
        gate="app",
        expect="test_a_raise_sets_the_copies_to_what_the_check_saw",
    ),
    rule(
        "still: a copy is set only where it is still what the check read (N57)",
        SERVER,
        "                    \" AND CAST(title AS BLOB) = CAST(?3 AS BLOB)\"\n",
        "                    \" AND (CAST(title AS BLOB) = CAST(?3 AS BLOB) OR 1)\"\n",
        gate="app",
        expect="test_a_stamped_write_after_the_check_keeps_its_copy",
    ),
    rule(
        "seen: a copy gets the title the check saw, not the table's now (N57)",
        SERVER,
        "\"UPDATE notes_seen SET title = ?1 WHERE id = ?2\"",
        "\"UPDATE notes_seen SET title = coalesce((SELECT title FROM notes WHERE id = ?2), ?1)"
        " WHERE id = ?2\"",
        gate="app",
        expect="test_a_bypass_after_the_check_is_not_taken_into_the_copy",
    ),
    rule(
        "bytes: a copy is compared as bytes, so a title stored as a BLOB is set (N57)",
        SERVER,
        "                    \" AND CAST(title AS BLOB) = CAST(?3 AS BLOB)\"\n",
        "                    \" AND title = ?3\"\n",
        gate="app",
        expect="test_a_title_stored_as_bytes_is_answered_once",
    ),
    rule(
        "restore: a head below the highest read raises the floor (N57)",
        SERVER,
        "        var restored = head < self.highest or (self.schema >= 0 and schema != self.schema)\n",
        "        var restored = self.schema >= 0 and schema != self.schema\n",
        gate="app",
        expect="test_a_counter_that_went_back_raises_the_floor",
    ),
    rule(
        "schema: a moved schema version raises the floor, past a head that climbed back (N57)",
        SERVER,
        "        var restored = head < self.highest or (self.schema >= 0 and schema != self.schema)\n",
        "        var restored = head < self.highest\n",
        gate="app",
        expect="test_a_live_restore_is_found_after_the_head_climbs_back",
    ),
    rule(
        "feed: the tick checks before it fans out (N57)",
        SERVER,
        "            self.check_in_snapshot()\n            var head = stamp_head(self.reader)\n",
        "            var head = stamp_head(self.reader)\n",
        gate="app",
        expect="test_the_feed_and_the_changes_answer_check_first",
    ),
    rule(
        "changes: /notes/changes checks before it answers (N57)",
        SERVER,
        "            self.check_in_snapshot()\n            body = _changes(self.reader, since)\n",
        "            body = _changes(self.reader, since)\n",
        gate="app",
        expect="test_the_feed_and_the_changes_answer_check_first",
    ),
    rule(
        "abandon: a failed answer settles nothing (N57)",
        SERVER,
        "        same frames again.\"\"\"\n        self._looked = False\n",
        "        same frames again.\"\"\"\n        try:\n            self.witness.settle()\n"
        "        except:\n            pass\n        self._looked = False\n",
        gate="app",
        expect="test_a_raise_that_fails_loses_nothing",
    ),
    rule(
        "head: a head moved elsewhere renders the page again (N57)",
        SERVER,
        "            and head == self.rows_head\n",
        "",
        gate="app",
        expect="test_a_floor_raised_elsewhere_renders_the_page_again",
    ),
    rule(
        "startup: each state raises the floor as it starts (N57)",
        SERVER,
        "        self.raise_floor(String(\"startup\"))\n",
        "",
        gate="app",
        expect="test_every_state_raises_the_floor_once_as_it_starts",
    ),
    rule(
        "reborn: a row born above the stamp deletes its id before the append (N50)",
        SERVER,
        "                rows += el(\"li\", attr(\"id\", \"n\" + String(id)) + attr(\"hx-swap-oob\", \"delete\"))\n"
        "                born += render_item(f, id, q.column_text(4), String(\"\"))\n",
        "                born += render_item(f, id, q.column_text(4), String(\"\"))\n",
        gate="app",
        expect="test_a_row_whose_id_came_back_is_deleted_before_it_is_appended",
    ),
    rule(
        "floor: raise_floor puts the floor at the new head (O33)",
        STAMPS,
        "    db.execute(\"UPDATE m0_stamp SET floor = seq WHERE id = 0\")\n",
        "",
        gate="stamps",
        expect="test_a_raised_floor_puts_every_client_below_it",
    ),
    rule(
        "landing: the head lands past the stamps a restore took back, not one past the counter (O33)",
        STAMPS,
        "        \"UPDATE m0_stamp SET seq = max(seq + 1,\"\n"
        "        + \" CAST((julianday('now') - 2440587.5) * 86400000000.0 AS INTEGER))\"\n",
        "        \"UPDATE m0_stamp SET seq = seq + 1\"\n",
        gate="stamps",
        expect="test_a_raised_floor_lands_past_the_stamps_a_restore_took_back",
    ),
    rule(
        "within: raise_floor_within opens no transaction of its own (O33)",
        STAMPS,
        "    db.execute(\"UPDATE m0_stamp SET floor = seq WHERE id = 0\")\n    return stamp_head(db)\n",
        "    db.execute(\"UPDATE m0_stamp SET floor = seq WHERE id = 0\")\n    db.execute(\"COMMIT; BEGIN\")\n"
        "    return stamp_head(db)\n",
        gate="stamps",
        expect="test_a_raise_within_lands_with_what_the_caller_writes",
    ),
]


def main(argv: list[str]) -> int:
    return run(
        "sabotage-checked-page", RULES,
        {
            "app": MojoRun(APP_TESTS, includes=(
                "packages/m0-core", "packages/m0-http", "packages/m0-sqlite", "apps/")),
            "stamps": MojoRun(STAMP_TESTS, includes=("packages/m0-sqlite",)),
        },
        argv,
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
