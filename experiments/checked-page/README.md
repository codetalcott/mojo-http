# The checked page: the pressure runs behind it

**These are the runs behind `apps/table_notes`' check and
`m0_sqlite.raise_floor`** (SPEC N57, O33; DECISIONS D72). The argument is in
[docs/notes/a-page-checked-against-its-stamps.md](../../docs/notes/a-page-checked-against-its-stamps.md).

- Nothing here is built by `build-all` or picked up by any `test-*` glob.
- The gate's own evidence is `apps/table_notes/test/test_check.mojo`,
  `poe sabotage-checked-page`, and `smoke-table-notes`.
- **Measured on:** Apple M4, macOS 27.2.1, Mojo 1.2.0, 2026-11-26. The server
  used Apple's libsqlite3; the clients and writers ran in CPython 3.13.7 with
  its SQLite 3.50.4.

## The question, written down before each design's first run

At `M0_THREADS=2` with two pool threads, with writers racing the server's
loops and pool threads, does the check:
- keep every live client's rows right, over the rows it covers;
- never raise the floor without a write no stamp saw;
- converge after a restart?

And what do the check and its limit cost?

**Pass** needed all three:
- 0 raises after startup with stamped writes only;
- 0 covered errors at every quiescent check with writes no stamp saw, on
  every seed;
- 0 errors after every restart.

A row is covered when its id is at or below the last id of the true first
page. Each sabotage had to fail.

## The files

| file | what it is |
|---|---|
| `build.py` | builds the server and four sabotages from a source tree: S1 the comparison always matches; S2 a stamped update leaves the copy alone; S3 no raise at startup; S4 a restore found by the head alone |
| `pressure.py` | runs a built server, clients (SSE and pollers), a thread of stamped writes with a rare bulk delete of 60 window rows, and a main thread of bypasses, checkpoints and client churn. It compares every client with the table every 50 steps. `restore` restores a backup while no server runs; `live-restore` restores one onto the running file |
| `cost.py` | `main` against the check: 10,000 rows and 1,000 stamped writes. It times three requests and the write itself |

## The runs, in order

**The first design: each thread kept its window and replayed the stamps.**

| file | result |
|---|---|
| `results-pressure-registered-2026-11-26.txt` | **passed:** 0 covered errors over 20 seeds, no raise without a bypass, every restart right |
| `results-pressure-found-2026-11-26.txt` | the lifted code, which re-read without comparing below a raised floor. **Failed:** 1 covered stale row, on seed 15. The registered run had the same rule and passed by chance |
| `results-window-pressure-2026-11-26.txt`, `-more-` | comparing below a raised floor too. **Passed** 60 seeds. S2, the page compared exactly: 214–237 false raises per seed |
| `results-window-beyond-2026-11-26.txt`, `results-window-cost-2026-11-26.txt` | 1,775 errors with every bypass beyond the window; 21 µs more on a write's page |

An independent review then found a case none of these runs produced: a stamp
hiding a later bypass from every thread but the one that served the client.
That ended the first design.

**The shadow table, before the second review.**

| file | result |
|---|---|
| `results-shadow-first-pressure-2026-11-26.txt` | **passed** workloads 1–3, and S1 and S2 failed. **S3 did not fail:** a bypass made while the server was down stays in the file as a difference, so the first check finds it without the startup raise |
| `results-shadow-first-restore-2026-11-26.txt` | a restore while no server ran, added for S3: 0 errors with the startup raise, 100–330 covered stale rows without it |
| `results-shadow-first-beyond-…`, `results-shadow-first-cost-…` | 86 errors with every bypass beyond the window; +30 µs on a write's page |

A second independent review then found five problems that no run had
produced. These were triggers that healed a bypass's difference, a gap between
the raise and the copies, a BLOB title compared as TEXT, a live restore the
head climbed back past, and a false claim about REPLACE. Each is now a unit
test and a sabotage rule.

**The shadow table, final code.**

| file | result |
|---|---|
| `results-shadow-pressure-2026-11-26.txt` | **passed** workloads 1–3: 0 errors over 10 seeds of stamped writes (2,651, 9 of them bulk deletes) with no raise after startup; 0 covered errors over 60 seeds (2,260 bypasses, 16 errors beyond the window, 1,981 raises); every restart right. S1: 1,689 covered errors; S2: 94–108 false raises per seed |
| `results-shadow-restore-2026-11-26.txt` | **a restore while no server ran:** 0 errors with the startup raise. Without it (S3), 13 stamped writes carried the head past the clients, and 100–330 covered rows were stale each time. With the raise, the head had already landed past every client's stamp, so no catch-up writes were made. **A restore onto the running file, then 13 stamped writes past the clients' stamps:** 0 errors, every raise the schema version's. With the restore found by the head alone (S4), 100–310 covered rows were stale |
| `results-shadow-beyond-2026-11-26.txt` | chosen after the registered runs, every bypass beyond the window: 64 errors, all beyond, and 90 raises as rows came into the window |
| `results-shadow-cost-2026-11-26.txt` | a write's `GET /notes` 75.5–75.9 µs against 106.2–106.5; the write itself 40.5–43.3 against 45.5–46.2; the idle page unchanged; `/notes/changes` 3 µs more |

**A discarded attempt.** The shadow table's first attempt at workload 2
crashed on a harness race. A bypass picked a row the stamped writer had just
deleted, and `blobopen` raised. That attempt was discarded, and bypasses are
now made under the write lock after checking the row is still there.

## Running them

Each run takes a few minutes, and writes its databases and server logs under
the work directory it is given.

```bash
out=$(mktemp -d)
python3 -I experiments/checked-page/build.py . "$out/bin"
python3 -I experiments/checked-page/pressure.py "$out/bin/table_notes_C" "$out/work" bypass --seeds 20
python3 -I experiments/checked-page/pressure.py "$out/bin/table_notes_S4" "$out/work" live-restore --tag S4
```

`cost.py` wants two `-O3` builds: `main`'s `apps/table_notes/server.mojo`
(`git show origin/main:apps/table_notes/server.mojo`) and this tree's.
`pressure.py` needs CPython 3.12 or later, for `setconfig` and `blobopen`.

`build.py`'s sabotages match the final source. The earlier results were made
with earlier versions of `build.py` and of the server, and are kept as a
record; this tree cannot reproduce them.
