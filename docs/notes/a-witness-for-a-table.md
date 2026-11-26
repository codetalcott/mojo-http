# A witness for a table — 2026-11-25

> A design note from the engineering record.

`apps/table_notes` kept its first page on the change clock (D63). Every
commit anywhere in the file moved the clock, and the page was rendered
again, including after a commit to another table. A stamp could have spared
that rendering, and D63 refused it for a stated reason: a stamp can be got
past, and the clock cannot.

This round keeps the reason and drops the cost. The question asked of a
moved clock is no longer "did anything change?" but "did any page of
`notes` change?". It is answered from what SQLite itself wrote, not from
what a trigger saw. It lands as SPEC O32 (`m0_sqlite.TableWitness`), N48's
new wording, and DECISIONS D71.

## How many ways a stamp is got past

D63 named two: a REPLACE without the writer's `recursive_triggers`, and a
table rebuilt by a migration. A probe ran fifteen events against a WAL
database watched with this package's own triggers (copied verbatim), with a
reader holding a first page. It found three more:

| a write | moves the stamp | what a stamp-kept page did |
|---|---|---|
| the triggers dropped, then an update | no | stale |
| a migration rebuild, then an update | no | stale |
| a connection with `SQLITE_DBCONFIG_ENABLE_TRIGGER` off | no | stale |
| a title rewritten by `sqlite3_blob_write` | no | stale |
| a backup-API restore that brings the counter back to a value it had, then other writes | to the same number | stale |
| REPLACE through a UNIQUE column, no pragma | yes (the insert) | current: the page takes its rows from a query, so only a feed misses the tombstone |

Guarding the stamp with `PRAGMA schema_version`, asking `watched` whenever
it moves, closed the schema cases. It didn't close the connection with
triggers off, or blob I/O, which change no schema. The clock was never
stale. Neither was the witness below.

**Where measured:** Apple M4, macOS 27.2.1, CPython 3.13.7 with its SQLite
3.50.4 as the writer. Both runs gave the same table.

Two of those writes now run on every pull request, through the server: the
last phase of `scripts/table_notes_probe.py`. A connection with triggers off
and a blob write each leave the stamp head where it was, and each reaches
the list.

## The witness

In WAL mode every committed page is a frame in `<db>-wal`, and the first
four bytes of a frame's header are its page number. A table's pages are
known (`dbstat`). So "has `notes` changed since I last looked?" is answered
by reading:
- the wal-index header (`<db>-shm`), for how many frames are committed;
- the header of each frame committed since the last look.

That takes no SQL and no transaction. It answers:
- **UNCHANGED** when no such frame wrote a page of the table, page 1 or a
  new log;
- **CHANGED** when one wrote a page of the table;
- **UNKNOWN** otherwise. The view then renders again, as the clock alone
  would.

**Page 1 is where pages change hands.** Allocation, a free, growth and a
schema change all write page 1's header. So while page 1 is unwritten, the
table's page set is the one last mapped. A probe found page 1 in the frames
of every event that could move pages (300 inserts, the rebuild, the restore,
VACUUM). The reasoning is from SQLite's file format. Autovacuum wasn't tried.

**The order is the contract.**
- The wal-index header is read BEFORE the rendering's read transaction, so
  the snapshot holds at least what the witness covers.
- `settle` covers that position, never one read later.

A witness that covered a later position would skip commits the rendering
doesn't hold. A writer racing the witness can't show that bug: the next
write repairs the page within microseconds. So
`test_a_commit_the_rendering_does_not_hold_is_looked_at_next` injects the
commit, and `poe sabotage-witness` reverts the line.

**Reading only the WAL file is ruled out on correctness, not cost.**
- A commit frame can be on disk before SQLite publishes it to new snapshots
  (the wal-index header).
- A cache that rendered at a snapshot without that commit, then covered its
  frame, would keep a stale page until the table changed again.
- Only the published `mxFrame`, read before beginning, ties what is covered
  to the snapshot.

**The wal-index header is documented but not promised.** SQLite's
walformat.html §2.1 gives the layout: two 48-byte copies, native-endian
fields, and salts that are the WAL header's own bytes. It also calls the
format "left to discretion of individual VFS implementations". So the
witness:
- reads the copies until they agree;
- requires `iVersion` 3007000;
- answers UNKNOWN to anything else: slower, never wrong.

Reading the salts in native byte order, as the first probe did, made every
look UNKNOWN. A check that passed because the witness never decided would
have proved nothing, so the probe's verdict also required the witness to
keep pages.

**Its `-shm` descriptor is never closed.** A POSIX `close()` of any of a
file's descriptors drops every lock the process holds on that file, and
SQLite takes its WAL locks on `-shm` (howtocorrupt.html §2.2). The first
version closed its copy when it was destroyed. On Homebrew's SQLite that let
another process's `wal_checkpoint(TRUNCATE)` complete, `(0, 0, 0)`, under a
reader that was still reading, where it must answer busy. Apple's build kept
its locks and hid it. An independent review of the next design found it
(2026-11-25). The handle now lives in an allocation that is never freed.

**Its own connection.** The witness opens a read-only connection of its own:
- **The files stay.** SQLite deletes `-wal` and `-shm` at the last close,
  and that is never the witness's connection, so it never reads files that
  are no longer the database's.
- **The map's snapshot is its own.** It maps pages in its own read
  transaction, begun after the look that asked for the map, so the map holds
  at least what the look read.

## What it costs

`apps/table_notes`' render path, in process: 10,000 notes, a 50-row first
page, and 1,000 writes, each followed by one rendering of the page. Medians
in µs, run 1 / run 2. Apple M4, macOS 27.2.1, Mojo 1.2.0 `-O3`, SQLite
3.54.0, WAL, 4 KB pages.

| first page | under writes to `notes` | after a commit to another table |
|---|---|---|
| on the clock (D63) | 70–77 | 68–78 |
| stamp-validated (refused, D63) | 20–23 | 4–5 |
| rows compared by title, on the clock | 19–22 | 19 |
| **witness, then rows compared by title** | **21–24** | **3** |

- **Under writes the page costs a third of what it did.** Only the rows whose
  title changed are rendered. A row's `<li>` reads its id and its title, so
  those two are its key, and no stamp says whether it is current.
- **A commit elsewhere costs a pread of the header and of each frame's
  header:** less than the stamp check, which is SQL.
- **UNKNOWN was 0.8–2.3% of looks** at SQLite's default autocheckpoint,
  from page-1 writes and log resets.

**Under pressure.** A writer in another process committed 95,000–161,000
times in 20 s, checkpointing every one to five commits (PASSIVE, RESTART and
TRUNCATE). The witness saw 31,000–53,000 log resets per run.
- **No comparison was stale:** 1,513 of them, against a fresh rendering, each
  taken while the writer was paused.
- **A quarter of looks were UNKNOWN,** which costs a rendering each. So under
  that pressure the witness stays correct and loses much of its saving.
- **The comparisons can fail.** Ignoring the salts went stale on 15–28% of
  comparisons.

## What it is not

- **Not a feed.** The witness says a table changed, not which rows. The feed
  stays on stamps (D64), and so does a client's place in it.
- **Not new in kind.** Keeping a cache from the database's log rather than
  from triggers is how log-based caches work elsewhere. ReadySet keeps its
  caches from Postgres' and MySQL's replication streams
  ([its account](https://readyset.io/blog/behind-the-magic-how-readyset-speeds-up-queries-with-streaming-dataflow)).
- **Not what tailite is.** tailite (2026, MIT, Rust) decodes row-level
  changes from a SQLite WAL from outside the process. Run against the same
  fifteen events it reported every changed row, REPLACE's displaced one
  included. It is the better source for a feed's rows. It polls, though (a
  report about one interval, 25 ms at 20 ms), and reads to the end of the
  log file, which can hold a commit not yet published to snapshots. That
  suits a stream, not a cache answering for the snapshot it rendered.
- **Not free of SQLite's layout.** It reads a structure SQLite documents and
  doesn't promise, and needs `dbstat`, a compile-time option.
  - Apple's build has it, and Debian's `debian/rules` enables it.
  - `unit-gates` runs `test_witness.mojo` on `ubuntu-latest` as well as
    macOS, so a Linux library without it fails the gate.
  - CPython's bundled SQLite does not have it.
  - Without it every look is UNKNOWN.
- **Not forgiving of a name.** `dbstat` matches table names exactly, while
  SQLite resolves them without regard to case. A witness over `"Notes"`,
  given to `dbstat` as written, mapped no pages and answered UNCHANGED for
  every write to `notes`: a permanent stale page. Review caught it before it
  merged. Each name now resolves through `sqlite_schema` first, and a map
  with no pages in it is refused.

The probes and their output are in
[`experiments/table-witness/`](../../experiments/table-witness/README.md):
the bypass matrix, the render-path costs, the pressure run, and tailite's
run.
