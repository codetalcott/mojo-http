# The table witness: the probes behind it

**These are the probes that led to `packages/m0-sqlite/src/witness.mojo`,
kept for the record. For working code, use `m0_sqlite.TableWitness`** (SPEC
O32). The probes carry their own copies of the witness's logic, as it stood
while it was being tried, and should not be copied.

- Nothing here is built by `build-all` or picked up by any `test-*` glob, and
  `packages/` does not import it.
- The argument and the figures are in
  [docs/notes/a-witness-for-a-table.md](../../docs/notes/a-witness-for-a-table.md);
  the decision is D71.
- The docstrings name plans and phases from the owner's working notes, which
  are not in this repository. The questions and results are restated below.
- **Measured on:** Apple M4, macOS 27.2.1, 2026-11-25; Mojo 1.2.0 `-O3`
  against mojo-http `31fb5841`, with the system SQLite 3.54.0; CPython 3.13.7
  with its SQLite 3.50.4.

| file | question | result (`results-*.txt`) |
|---|---|---|
| `bypass_matrix.py` | Across 15 write paths, which ways of keeping a page are ever stale: the clock, stamps, stamps guarded by `schema_version` and `watched`, the WAL page witness, or rows compared? | **The clock and the witness never were.** Stamps went stale after 5 events (a dropped trigger, a rebuild, triggers turned off, blob I/O, a restore that repeats the head). The guarded stamps went stale after 2 (triggers off, blob I/O). The witness kept the page where stamps over-refresh: another table, the same value stored, a hand-bumped counter. A sabotaged witness goes stale. |
| `bench_notes3.mojo` | What each design costs in `table_notes`' render path: 10,000 notes, a 50-row page, 1,000 writes, then 100 commits to another table. | Medians: the clock 68–78 µs; the witness with rows compared 21–24 µs under writes and 3 µs after a commit elsewhere; stamps 4–5 µs (refused, D63). Every arm's page was byte-identical to the clock's. A bypass check (triggers dropped) left only the stamp arm stale. |
| `pressure.mojo`, `pressure_writer.py` | Does the witness stay correct while another process writes and checkpoints every 1–5 commits? | **No page stale in 1,513 comparisons,** against 31,000–53,000 WAL resets per 20 s. Ignoring the salts goes stale; a quarter of looks were UNKNOWN. The order bug (covering a later position) needs the injected test `test_witness.mojo` has: the next write repairs it before any comparison. Protocol A, as registered, was degenerate (few comparisons kept the page); protocol B fixed that, and is labelled post-hoc. |
| `tailite_check.py` | Does tailite (github.com/zaydmulani09/tailite, `0078c6c`), which decodes row changes from the WAL, see the same 15 events? | **Every changed row, REPLACE's displaced one included,** at about one poll interval (24.8 ms median at 20 ms). It is a better source for a feed's rows. As a cache, it would be up to a poll stale. |

## Running them

`bypass_matrix.py` and `tailite_check.py` need CPython 3.12 or later (for
`setconfig` and `blobopen`) and `/usr/bin/sqlite3` with `dbstat`:

```bash
python3 -I experiments/table-witness/bypass_matrix.py "$(mktemp -d)"
python3 -I experiments/table-witness/tailite_check.py <tailite-binary> "$(mktemp -d)"
```

The Mojo probes build against this repository's packages:

```bash
out=$(mktemp -d)
for f in bench_notes3 pressure; do
  uv run mojo build -O3 -I packages/m0-core/ -I packages/m0-http/ -I packages/m0-sqlite/ \
    experiments/table-witness/$f.mojo -o "$out/$f"
done
"$out/bench_notes3" "$out/bench.db" hot 1
python3 -I experiments/table-witness/pressure_writer.py "$out/p.db" "$out/ctl" 26 1 B &
"$out/pressure" "$out/p.db" "$out/ctl" 20 0 B
```
