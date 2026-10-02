# A database that remembers what changed — 2026-10-02

The change clock ([a-resource-over-a-table](a-resource-over-a-table.md))
says that something was committed. This round adds what: `m0-sqlite`
stamps each row a watched table writes, so "what changed since N" is a
query. It lands as SPEC O26, O27 and N49 and DECISIONS D63 and D64, with
`apps/table_notes` answering the query over a GET.

## Three places to keep the past

A feed sends a client what changed since it last looked, so something has
to remember what the client had. There are three places for it.

| who remembers | how a change is found | what the server holds | work per commit |
|---|---|---|---|
| the server | compare a kept copy with a fresh query | a copy of every view | the size of the view |
| the client | send everything; it ignores what it has | a hash, to stay quiet | the size of the view, in bytes too |
| the database | rows carry a stamp; ask for the ones above N | one number | the size of the change |

The first is how Meteor's live queries began, and what it left: every
write re-ran every watched query. It is also state per view, which
becomes state per connection once views are per user. The second is fine
for fifty numbers and cannot say a row is gone. The third is this round.

## What was built

`install_stamps(db)` creates two tables and `watch(db, "notes")` puts four
triggers on one:

    m0_changes(tbl, row, seq, born, gone)   PRIMARY KEY (tbl, row)
    m0_stamp(id = 0, seq, floor)

One entry per row touched, not per change: `seq` is the stamp of its last
write, `born` the stamp of the insert that made it, `gone` whether it is
a tombstone. The counter is a row, incremented in the trigger. A feed is
then one statement, and its memory one number:

```sql
SELECT c.row, c.seq, c.born, c.gone, n.title FROM m0_changes c
LEFT JOIN notes n ON n.id = c.row
WHERE c.tbl = 'notes' AND c.seq > ?1 ORDER BY c.seq
```

Five properties carry it. The first three and the last are tests in
`test_stamps.mojo`; the fourth is the wire gate's, whose other program is
CPython's SQLite:

- **Stamps are in commit order, and a rollback takes its own.** The
  counter is in the database and SQLite has one writer. On PostgreSQL the
  same query misses rows, a sequence value being taken before the commit
  that publishes it.
- **A statement sees whole commits**, so what is above a stamp is a whole
  number of transactions and one stamp per row is enough.
- **`born` tells an insert from an update.** A client at N holds a row
  iff `born <= N`. That is what lets a feed send an element for a new row
  and one key for a changed one while keeping nothing.
- **A trigger fires for every program.** The write path does not publish,
  so it cannot forget to, and a writer in another process and another
  language is stamped like this one.
- **`stamp_of(db, table)`** is the highest stamp among one table's rows:
  a clock for a table, where `data_version` is the database's.

`prune_stamps(db, below)` forgets tombstones and raises a floor; a client
below the floor is told to start over.

### The counter is a row

The first version numbered a change `max(seq) + 1` over the stamp table.
It needed a rule (never prune the row that holds the highest stamp, or
the number is given twice) and an index that made the per-table clock a
scan. Measured on an M4 through CPython's SQLite, WAL, 10,000 rows:

| | single-row update, committed | per row of a 10,000-row update | a table's highest stamp |
|---|---|---|---|
| unwatched | 6.5 µs | 0.13 µs | |
| `max(seq) + 1` | 15.8 µs | 0.89 µs | 221 µs |
| a counter row | 19.7 µs | 0.95 µs | 1.2 µs |

The counter costs 4 µs a commit and removes the rule.

Both of those forms wrote the entry with an upsert. What shipped does
not, for two reasons the review of this round found. A SQLite older than
3.24 cannot parse an upsert, so it could no longer open a watched file.
And the plain alternative, `INSERT OR IGNORE`, is wrong inside a trigger:
SQLite applies the conflict clause of the statement that FIRED the
trigger to the statements in it, so `UPDATE OR REPLACE` replaced the
entry and lost `born`, and `INSERT OR FAIL` would have failed the write.
The entry is written by an insert that cannot conflict
(`INSERT ... SELECT ... WHERE NOT EXISTS`), then an update. As shipped,
on `apps/table_notes`' own table, same machine and client:

| | unwatched | watched |
|---|---|---|
| single-row update, committed | 8.6 µs | 30 µs |
| per row of a 10,000-row update | 0.12 µs | 2.1 µs |
| per row of a 10,000-row insert | 0.49 µs | 3.7 µs |
| a table's highest stamp | | 1.3 µs |
| the five newest changes, joined | | 3.8 µs |

A watched commit is about 21 µs more than an unwatched one. The upsert
form measured 29 µs a commit and 1.2 µs a bulk row on the same table.

## The application

`apps/table_notes` watches its table and answers
`GET /notes/changes?since=N` with the rows stamped above N: the live ones
with their titles and `born`, the dead ones as `gone`, and `head`, the
stamp to ask from next. `smoke-table-notes` holds it at one loop and at
two: a write through the server, one by another program and a delete
arrive as three rows in commit order; a client that has everything is
sent nothing; a commit to another table moves the clock and no stamp; a
client below the floor, or ahead of the head, is answered `reset`; a
title with a byte that is not UTF-8 still decodes; and under
`M0_THREADS=2` the
two loops answer one stamp identically, neither having kept the client's
place.

The list's cache stays on the clock. A stamp can be got past (the two
traps below) and `data_version` cannot, so a rendering keyed on stamps
would be as fragile as the triggers, to spare one rendering when another
table commits.

## What a stamp does not see

Pinned as tests too, so a fix or a change in SQLite shows up as a
failure.

- **A REPLACE through a UNIQUE column (`INSERT OR REPLACE`,
  `UPDATE OR REPLACE`) deletes without a tombstone** unless the writing connection has
  `PRAGMA recursive_triggers = ON`. SQLite fires no delete trigger for
  the displaced row otherwise, and the pragma is per connection, so every
  program that writes with REPLACE has to set it.
- **A table rebuilt by a migration loses its triggers**, silently.
  `watched` reports it; `watch` again restores them, and what was written
  in between was not stamped.
- **An update that changes nothing is stamped.** A program that
  recomputes more than changed compares before it writes.
- **Only a rowid alias names a row durably.** `watch` refuses a table
  with any other key, WITHOUT ROWID among them: its triggers would have
  resolved `new.rowid` only when they fired, and failed every write to
  the table from every program. `INTEGER PRIMARY KEY DESC` is refused
  too, a spelling SQLite keeps as a key that is not the rowid.
- **A row older than the watch is in no delta until it is written**, so
  the changes above 0 are the table only for one watched from its first
  row. Nothing backfills.
- **A window and an aggregate are not rows.** A "top 50" loses a row that
  did not change, and a count has no row. Either stays on the clock and a
  hash, or is written down as a row by a stage that computes it.

## Three applications outside the tree

The design was run as three probes before it was lifted, each with a wire
gate and a browser check (`ideas/changefeed`, private). What they
measured, on an M4, one run each:

- **A page of fifty bars**, values bound to Datastar signals, fed by a
  per-loop poll of the clock and the query above. An outside write
  reached every subscriber on two loops in one tick; one changed row was
  86 bytes against a 6 KB list; 1,000 commits in a burst were 2 events.
- **A graph laid out by the server.** A thread reads `nodes` and `edges`
  when their stamp moves, runs a force-directed step with the repulsion
  across cores, and writes positions to a watched table; pages draw them
  with registered custom properties. 2.5 times faster than one core at
  2,000 nodes inside the server.
- **Notes and their nearest notes**, over this project's dogfood corpus:
  a Python process embeds the notes stamped above its cursor, a Mojo
  thread recomputes neighbours for the vectors stamped above its own, and
  an open page is told when its row of the result is stamped. An edit to
  one note reached another note's open page in 89 ms, with one embedding
  and 14 of 535 lists recomputed.

So a stamp is a cursor, and a feed is one consumer of it. A stage that
derives something expensive does only the work above its cursor, keeps
the cursor in the database where the work is costly to repeat, and
writes its result to a table that is watched in turn.

Two rules came from getting them wrong:

- **A delta is never cut.** Split at a stamp to fit a buffer, a row born
  below the cut and changed above it was never sent as new. `born` is
  true of a client only at the head of a snapshot it has all of.
- **Fan-out is per subscriber, from its own stamp.** A broadcast assumes
  everyone stands together, and one refused frame leaves a gap. Asked
  again from where each stands, a slow client gets fewer and larger
  deltas.

## A stage's place (added the same day)

The embedder kept its cursor in a table of its own making, in the
transaction that wrote its vectors. That is the one part of a stage the
package can hold without holding the stage: `m0_cursors(name, seq)`,
`cursor`, `advance` (inside the caller's transaction, so outputs and
place hold together; never backwards, never past the head, the check in
the statement that writes) and `slowest_cursor`, the stamp pruning may
reach without stranding a registered stage (O28). Registered is the
word: a stage takes its row before its first read and gives it back
when it retires, or pruning waits on it for good, and the lag query
says which one. Two things
become queries: a stage's lag, `head - seq`, and the safe prune point.
It was lifted ahead of a Mojo asker, which D64 records.

## Not built

- **The stream.** The probes wrote their own handler over `SSERegistry`:
  `ViewsApp` forwards no stream hooks, `DatastarStream` numbers its own
  frames and keeps a journal a stamp makes unnecessary, and the
  registry's bound of 64 KB a slot cannot hold one large delta whole.
  What the layer would want is a stream whose event ids are the
  application's and whose replay is a callback.
- **Repairing a rebuilt table.** `watched` reports; the application
  decides.
- **History.** One entry per row is the present and when it last
  changed. "As of stamp 42" is a log, which grows.
- **A PostgreSQL form.** Commit order is not sequence order there.
