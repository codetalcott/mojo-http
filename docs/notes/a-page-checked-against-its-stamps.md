# A page checked against its stamps — 2026-11-26

> A design note from the engineering record.

`apps/table_notes` keeps a client live from stamps (D63, D64). A client
loads the first page and stands at the stamp it was rendered at. The feed,
or `GET /notes/changes`, then sends it the rows stamped above that.

A stamp says what a trigger saw, and a write can get past a trigger:
- a connection with triggers turned off;
- blob I/O;
- a table rebuilt by a migration;
- a REPLACE without the writer's pragma;
- a backup restore that brings the counter back.

The witness (O32, D71) keeps the server's cached page right through all of
them. A **client** holding a row that such a write changed is a different
matter: it keeps the old title for good, because nothing stamps that row
again.

This round makes the server notice, and start every client over. It lands as
SPEC N57 (the check), O33 (`m0_sqlite.raise_floor`), and DECISIONS D72.

## The check

**The table's own triggers keep a copy of what the list renders.**
`notes_seen(id, title)` is written in the transaction that writes each row:
an insert, an update (a key that moves included), a delete. A write that
gets past the triggers, a connection with triggers turned off or blob I/O,
gets past this copy too. So it leaves `notes` and `notes_seen` different in
the file itself, where any thread, or any other program, that compares them
finds it.

**Each trigger writes only the copy its own write accounts for.** That keeps
a difference already there from being healed by the next stamped write:
- an insert never overwrites a copy, so a row a bypass deleted and an insert
  then put back under its id still differs;
- an update of the same key never creates a copy, so a row a bypass
  inserted and a stamped edit then touched is still missing its copy.

Every answer that serves the first page or what changed, and the feed's
fan-out on each tick, opens the same way:
1. Read the clock. If it moved, ask the witness (over `notes` and
   `notes_seen`) to look, before the read transaction (O32's order).
2. Begin the read transaction, and read the head in it.
3. If the witness said UNCHANGED and the head is the kept page's, the kept
   page stands.
4. Otherwise, compare the first `CHECK_WINDOW` rows (100: the page and as
   many again) with their copies. The rows and the copies are read as two
   scans in id order, on statements kept between answers, and merged as
   they are read:
   - a pair whose titles differ is a difference;
   - a row with no copy at its id is one;
   - a copy below the next row, whose row is gone, is one.

   No row is probed for its copy, nor a copy for its row. The merge stops
   at the window's last row and its copy, so a copy above that row is never
   read; in a table shorter than the window, every copy is. Then render the
   page from the same rows.
5. Answer in the same transaction, and settle the witness after the commit.

**A difference raises the floor:**
- `/notes/changes` answers every client below it `reset`;
- the feed sends every subscriber `resync`, with the page whole.

Every client is reset, not only those holding the row. The difference proves
that writes get past the triggers, and the check sees only its window.

**The raise and the copies are one transaction** (`raise_floor_within`). In
it, each differing copy is set to what the check saw, where it is still what
the check read:
- **compared as bytes,** since a title another program stored as a BLOB
  never equals the TEXT the check binds;
- **a stamped write since,** whose trigger already made the copy agree, is
  left alone;
- **a second write no trigger saw is not taken in,** because the copy gets
  the title the check saw, not the table's title now.

With the raise and the copies in one transaction, no thread can check
between them. And a failure leaves the difference in the file, for the next
check to raise again.

## How it got here

The first design kept no copy. Each thread remembered the window as it last
read it, applied the stamps above that point, and compared the result with
the window now. It failed three ways, each found by a run or a review rather
than by reasoning:

- **Row 51.** The rule as first modelled compared the page exactly, on
  tables that never grew past one page. In `table_notes`, a delete on the
  page brings row 51 up, and a birth goes beyond the page. Neither is a
  difference, and both raised the floor: **214–237 false raises per 400
  steps** under pressure, with no bypass at all.
- **Below a raised floor.** After every raise, each thread's kept window is
  older than the floor. The lifted code took that as a reason to re-read
  without comparing:
  1. a pool thread served a client a page at the new floor;
  2. a bypass followed;
  3. that thread served nothing more, and every other thread's re-read took
     the bypass in silently.

  The pressure run on the lifted code found it: one row stale for good, on
  one seed of twenty.
- **A stamp hides a bypass from every thread that ticks.** An independent
  review found this:
  1. a stamped write W to row r;
  2. a pool thread serves a page holding W;
  3. a bypass X rewrites r, all within one 50 ms tick.

  Every thread that ticks kept its window from before W. It applied W's
  stamp with r's current title, which is X's, and found nothing.

All three come from one thing: **the evidence was in a thread's memory, and
the client could have been served by another thread.** The copy puts the
evidence in the file.

A second independent review of the copy found five more problems, each now a
test:
- **The triggers healed two kinds of bypass.** They are now
  insert-never-overwrites and edit-never-creates.
- **A gap between the raise and the copies,** in which another thread could
  serve a client a value that a later bypass changed back (A→B→A).
- **A copy compared as TEXT** against a BLOB title, which would have raised
  the floor at every tick.
- **A live restore missed** when stamped writes carried the head back past
  where it was. That is the schema version, below.
- **A claim that the copy catches a REPLACE's displaced row.** It doesn't:
  the incoming row's trigger writes the copy. The claim is gone.

## A restore

A backup restore puts the rows, their copies and the counter back together,
so nothing differs. Three things answer it:
- **A head below the highest this thread has read.** This misses a restore
  if stamped writes carry the head back past that before any thread checks.
- **A moved schema version.** The backup API moves it, and stamped writes
  never move it back. Measured with CPython's SQLite 3.50.4: a live restore
  took it from 1 to 2, and twenty writes after left it at 2.
  - A migration moves it too, and so also starts every client over. A
    migration that rebuilds a table is a write no stamp saw anyway.
  - A restore can't be told from other DDL by the schema alone.
- **The startup raise.** Each thread's state raises the floor once as it
  starts, for a restore made while no server ran.

**Where the raise lands.** One past the restored counter could be exactly
the stamp a client held from after the backup. That client would be neither
below the floor nor above the head, so it would never start over.
- So the head lands on the current time in microseconds (SQLite's clock, at
  millisecond resolution), or on one past the head if that is later.
- That is past every stamp given since the last raise, unless more stamps
  were given than microseconds passed, or the clock was set back.
- It stays below 2^53, so a JavaScript client reads it exactly, until the
  year 2255.

## The floor means more than pruning now

Before this round, a floor meant "tombstones at or below it were pruned".
Now it means **below here, no delta is vouched for**:
- **a prune** puts it there (O26);
- **`raise_floor`** puts it there for a program that saw a write no stamp
  recorded (O33).

Either reaches every program that compares a stamp with `stamp_floor`.
- **After a write no stamp saw,** a stage starting over is right, since it
  missed the write as well.
- **After an application's startup raise,** a stage starts over for
  nothing. That is a cost of sharing the file with such an application.

**A raise takes the write lock.** It waits for another writer up to the busy
timeout (5 s), on whichever thread found the difference. With no pool
threads, that is the loop, and the loop waits with it. The startup raise does
the same, so a state can't be made while another program holds the lock
that long.

## What it measured

Everything here is in `experiments/checked-page/`, run 2026-11-26 on the
final code.
- **Machine:** Apple M4, macOS 27.2.1, Mojo 1.2.0. The clients and writers
  ran in CPython 3.13.7 with SQLite 3.50.4.
- **Server:** `M0_THREADS=2` with two pool threads, so six thread states,
  over one WAL database of 120 rows (2.4 pages).
- **Clients:** SSE clients and pollers, applying what they are sent as htmx
  and a client would.
- **Writers:** a thread of stamped writes through the routes and through
  CPython's sqlite3, with a rare bulk delete of 60 window rows. And writes
  no stamp saw: triggers turned off (an update, a delete or an insert) and
  blob I/O, aimed at the page, the window's second half and rows beyond it.
- **Checks:** every 50 steps the writers pause and every client is compared
  with the table. A row is "covered" when its id is at or below the last id
  of the true first page.

| workload | result |
|---|---|
| stamped writes only, 10 seeds × 400 steps (2,651 writes, 9 of them bulk deletes) | **0 errors**, and no raise but the six at startup |
| with writes no stamp saw, 60 seeds (2,260 of them) | **0 covered errors**; 16 beyond the window; 1,981 raises |
| a write no stamp saw while the server was down, 5 restarts | **0 errors** after each: the copy kept the difference |
| a backup restored while the server was down, 5 times | **0 errors** after each |
| a backup restored onto the running file, then stamped writes past the clients' stamps, 5 times | **0 errors** after each; every raise was the schema version's |

**Raises:** fewer than one for each write no stamp saw. A raise answers
every difference found together, and the copies set in its transaction
spare the other threads a second raise.

**The sabotages,** each run on the same harness:
- **the comparison always matches:** 1,689 covered errors over 5 seeds;
- **a stamped update leaves the copy alone:** 94–108 false raises per seed;
- **no raise at startup:** 100–330 covered stale rows after each restore
  made while down;
- **a restore found by the head alone:** 100–310 covered stale rows after
  each live restore.

**The startup raise needed its own workload.** Without the startup raise,
the registered restart workload still converged. The copy had kept the
down-time write's difference in the file. So the raise is needed only for a
restore, and the restore workloads were added after the registered runs to
show that. The live one followed the second review.

**Earlier runs are kept beside these:**
- `results-window-*`: the first design's runs. They include the lifted run
  that found the raised-floor hole, and a cost of 21 µs on a write's page.
- `results-shadow-first-*`: the copy before the second review's fixes. It
  passed every registered workload, and the review still found five
  problems.

**Beyond the window** (a run chosen after the registered ones): with every
write no stamp saw aimed beyond the window, 5 seeds gave 64 errors, all
beyond it, and 90 raises. A row beyond the window is found once it comes
into the window, because its copy still differs. The first design left
1,775 errors on the same run.

**Cost.** One loop, 10,000 rows, and the same 1,000 stamped title updates to
the page. Medians, `-O3`. The three requests are client round trips over
loopback; the write is the update and its commit, by the writer:

| | before (`main`) | checked |
|---|---|---|
| `GET /notes` after a write | 75.5–75.9 µs | 106.2–106.5 µs |
| `GET /notes`, the clock unmoved | 49.8–50.0 µs | 50.0–50.1 µs |
| `GET /notes/changes?since=head-1` | 50.8–51.0 µs | 53.6–53.8 µs |
| the write | 40.5–43.3 µs | 45.5–46.2 µs |

- **About 30 µs more on a write's page,** which is 1.40× the round trip.
  That design joined 100 rows with their copies, scanned for gone copies
  and read the schema version, each on a statement prepared for the
  answer; then the render read 51 rows again.
- **2–6 µs more on each write** (5–14%, round by round), for the copy's
  row.
- `/notes/changes` costs 3 µs more, and the idle page nothing.

**The merged scans (2026-11-27).** The comparison is now two scans merged,
kept between answers, and the page is rendered from the rows the first scan
read. The design was worked out in a lab copy of this app, where a
breakdown put most of the 30 µs in the gone-copy side's probe per copy.
The same run, on this tree:

| | `main` (the join) | the merged scans |
|---|---|---|
| `GET /notes` after a write | 106.3–107.8 µs | 79.9–80.1 µs |
| `GET /notes`, the clock unmoved | 49.8–50.4 µs | 48.7–48.8 µs |
| `GET /notes/changes?since=head-1` | 55.9–56.6 µs | 54.2–54.5 µs |
| the write | 46.7–51.5 µs | 47.4 µs |

That is 1.33–1.35× faster on a write's page, or 26–28 µs less. In #714's
run above, the check had added 30 µs. That is another run, so the two are
not one subtraction. `results-merge-cost-2026-11-27.txt` has the run.

## What it is not

- **Not coverage of the table.** The check compares its window. A client
  also holds every row born since it rendered, and in a table larger than
  two pages those are all beyond the window. A bypass to one of them reaches
  the client at the next reset, for whatever reason, or once the row comes
  into the window, since its copy still differs.
- **Not a repair.** A difference found could be sent as a row with a late
  stamp. An insert can't be: a client that already rendered it would append
  it again. One reset for a rare event is the simpler answer, until a
  consumer pays for resets.
- **Not free.** The copy doubles the titles on disk, and every row write
  writes one more indexed row.
- **Not tested under forked workers.** The unit tests and the sabotage run
  on both platforms in CI. The pressure harness ran on macOS for every
  design, and once on Linux for the merged scans
  (`results-merge-linux-2026-11-27.txt`).
- **Not tested by injection:** a thread checking between the raise and the
  copies. They are one transaction, so the window does not exist; nothing
  can inject into it either.

The harness, the sabotages and every output, the first design's included,
are in [`experiments/checked-page/`](../../experiments/checked-page/README.md).
