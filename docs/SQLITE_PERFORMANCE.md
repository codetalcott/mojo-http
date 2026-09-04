# SQLite performance notes

Measured against `m0-sqlite` on macOS (arm64, Apple system libsqlite3 3.51.0),
August 2026. Every number here came from a benchmark in this repo's style —
build a real database, run the real bindings, time the real calls. Reproduce
with the scripts described at the end.

The short version:

| Change | Effect | Verdict |
| --- | --- | --- |
| Batch writes in one explicit transaction | **46x** on 10k inserts | Do this. Nothing else comes close. |
| `PRAGMA mmap_size` | **40%** on random reads past the cache | Worth adopting, with a caveat |
| `json_each(?)` for variable-length `IN` lists | **6.7x** over a per-id loop at N=1000 | Use above N≈10 |
| `PRAGMA cache_size` | ~5%, inside noise | Skip |
| Statement cache | ~650 ns per prepare | Confirms the existing decision not to build one |
| `carray()` | Unavailable, and unusable from Mojo structs anyway | Superseded by `m0_array` — see below |
| Aggregating in Mojo instead of in SQL | **1.37x** on sum+min+max over 200k rows | Use when the rows are wanted anyway |

> **Written in parallel with `m0_array`.** This study and the `m0_array`
> virtual table landed from two separate sessions that did not see each other's
> work. They agree on the facts and answer the same question differently: this
> document establishes that the *carray extension* cannot be reached from here,
> and `m0_array` supplies the capability anyway by registering a Mojo-side
> virtual table instead of loading a C one. Where they overlap, `m0_array` is
> the answer; the analysis below is why it had to be built rather than borrowed.

## What the library we link actually has

`PRAGMA compile_options` on the macOS system library, filtered to what matters:

```
OMIT_LOAD_EXTENSION        <- no runtime extensions, ever
DEFAULT_MMAP_SIZE=0        <- mmap is off until you ask
MAX_MMAP_SIZE=1073741824   <- and can be raised to 1 GB
DEFAULT_CACHE_SIZE=2000    <- 2000 pages, ~8 MB at the 4 KB page size
THREADSAFE=2               <- multi-thread, NOT serialized
MAX_VARIABLE_NUMBER=500000 <- generous; Linux builds are usually 32766
ENABLE_SETLK_TIMEOUT       <- blocking locks, which busy_timeout uses
ENABLE_FTS5, ENABLE_RTREE, ENABLE_MATH_FUNCTIONS, ENABLE_SESSION
DEFAULT_WAL_AUTOCHECKPOINT=1000
```

Two of these deserve attention. `OMIT_LOAD_EXTENSION` means no loadable
extension can ever be used on macOS with the system library — that single flag
decides the carray question below. And `THREADSAFE=2` means the library defaults
to multi-thread rather than serialized mode; `open_serialized`'s
`SQLITE_OPEN_FULLMUTEX` still selects per-connection serialization, so that
helper works, but the docstring's "serialized by default" describes the upstream
default, not this build.

Probed, not assumed: `json_each` and FTS5 are present; `carray` and
`generate_series` are not. `sqlite3_bind_pointer` links; `sqlite3_enable_load_extension`
does not link at all.

## carray(), and whether Mojo structs can feed it

**Short answer: no, on two independent grounds.**

**It isn't there.** `SELECT ... FROM carray(...)` fails with `no such table:
carray` on the library we link. carray only became part of the amalgamation in
SQLite 3.51.0 and even then it is off unless built with `-DSQLITE_ENABLE_CARRAY`;
before that it was a loadable extension. Loading it at runtime is not an option
on macOS, because the system library is compiled `OMIT_LOAD_EXTENSION` — the
symbol `sqlite3_enable_load_extension` isn't merely disabled, it doesn't exist,
and a binary referencing it fails to link. Linux distributions usually do enable
loading, so a shipped `carray.so` could work there, but a feature that exists on
one of two supported platforms isn't a feature this package can offer.

**Structs wouldn't work if it were.** carray binds *one flat, homogeneous C
array* and reads it with a fixed element type: `int32`, `int64`, `double`,
`char*`, or `struct iovec`. It has no concept of a stride, a field offset, or a
record layout. Handing it a `List[MyStruct]` would make it read the first four
or eight bytes of each struct as a value and then step forward by the *element*
size rather than the struct size — garbage, not an error.

What does map cleanly is a flat numeric list:

| Mojo | carray flag | Works? |
| --- | --- | --- |
| `List[Int]` / `List[Int64]` | `CARRAY_INT64` | Yes — contiguous, 8-byte elements |
| `List[Int32]` | `CARRAY_INT32` | Yes |
| `List[Float64]` | `CARRAY_DOUBLE` | Yes |
| `List[String]` | `CARRAY_TEXT` | No — needs `char*[]`, and Mojo strings are not NUL-terminated (see `c_string`) |
| `List[UInt8]` blobs | `CARRAY_BLOB` | No — needs an array of `struct iovec`, hand-built |
| `List[SomeStruct]` | — | **No.** No layout guarantee, no stride support |

There's a pleasing consequence: the parallel-array (SoA) style this repo already
uses — because `List[Struct]` fights `ImplicitlyCopyable` — is exactly the layout
carray wants. A `List[Int]` field of an SoA struct is already a bindable C array.
So if carray ever becomes available, the data is in the right shape; the blocker
is availability, not representation.

`sqlite3_bind_pointer` does resolve, so the pointer-passing machinery carray
depends on is present. If a future toolchain links a libsqlite3 built with
`SQLITE_ENABLE_CARRAY`, wiring it up would be a small change.

## The portable substitute: json_each

The problem carray solves is passing N values into one prepared statement when N
varies. SQLite has a built-in answer that needs no extension: bind a JSON array
as text and unpack it with `json_each`, which is present here and in every
SQLite built since 3.38.

```sql
SELECT name, payload FROM items
 WHERE id IN (SELECT value FROM json_each(?1))
```

Nanoseconds per call, 50k-row table, warm cache:

| N | loop (one `?` per id) | rebuilt `IN (?,…)` | `json_each` | `json_each`, statement reused |
| --- | --- | --- | --- | --- |
| 1 | **2,485** | 2,635 | 8,490 | 5,245 |
| 10 | 15,870 | 9,420 | 10,055 | **7,060** |
| 50 | 80,280 | 17,650 | 17,680 | **14,920** |
| 200 | 336,705 | 57,360 | 51,895 | **48,830** |
| 1000 | 1,700,200 | 315,280 | 259,600 | **255,560** |

Read this as three regimes. At N=1 the plain loop wins and json_each's parsing
overhead is pure loss. Around N=10 they cross. From N=50 up the loop is losing
badly — 4.5x at 50, 6.7x at 1000 — because it pays a full statement round trip
per id.

Rebuilding `IN (?,?,…)` is competitive but has two problems the table doesn't
show: it needs a *different* prepared statement for every distinct N, which
defeats any statement reuse, and it is bounded by `MAX_VARIABLE_NUMBER` (500k
here, but 32766 on typical Linux builds). `json_each` needs one statement
forever.

Building the JSON array is a string concatenation this repo is already equipped
for — `m0-core`'s `escape_json_string` for text ids, plain `String(i)` for
integers.

## Pragmas

20,000 random point reads over a 45 MB database (deliberately past the ~8 MB
default page cache):

| Setting | Time |
| --- | --- |
| baseline, as `open()` leaves it | 55 ms |
| `PRAGMA mmap_size=536870912` | **33 ms** |
| `PRAGMA cache_size=-131072` (128 MB) | 52 ms |
| both | 33 ms |

`mmap_size` is worth 40% and `cache_size` is worth approximately nothing. That
asymmetry makes sense: raising the cache only helps if the working set fits it
and the reads repeat, while mmap removes a `read()` syscall and a buffer copy
from *every* page fetch. On a database that fits entirely in the default cache
(a 4 MB, 50k-row table) neither pragma moved the needle at all, which is the
other half of the same story.

The caveat on mmap, from SQLite's own documentation: with memory-mapped I/O a
disk error that would have been an `SQLITE_IOERR` becomes a SIGBUS, and a stray
pointer write in the process can corrupt the database file instead of being
caught. That is a real trade, so `open()` does not set it. It belongs to the
application that knows its storage.

`temp_store=MEMORY` showed no measurable effect on these workloads — nothing
here spilled to a temp file. Set it if you sort large result sets without a
supporting index.

## Writes: the number that dwarfs everything else

10,000 single-row inserts:

| Approach | Time |
| --- | --- |
| autocommit — one implicit transaction per insert | 325 ms |
| autocommit with `PRAGMA synchronous=OFF` | 125 ms |
| **one explicit `begin` / `commit` around the batch** | **7 ms** |

Batching is **46x**. Weakening durability to `synchronous=OFF` — which risks
database corruption on an OS crash — buys 2.6x, still eighteen times slower than
just wrapping the loop in a transaction. This is the single most valuable thing
to know about writing to SQLite, and it costs two method calls this package
already exposes.

## Statement caching, revisited

The decision recorded in [ROADMAP.md](ROADMAP.md) not to build a statement cache
still holds, and now has a second measurement behind it. For the same trivial
point query:

- `prepare` + `step` + `finalize`: 1,651 ns
- `reset` + `step` on a cached statement: 999 ns

So a prepare costs about 650 ns, fixed. Against the 17 µs a 50-row fetch takes,
that is under 4% — consistent with the ~10% measured earlier on a smaller query,
and not worth the ownership complexity of a cache that has to outlive the
statements it hands out. Callers who care can hold their own `Statement`, which
is what the benchmark's fastest column does.

## Aggregates: SQL is not automatically the fast side

`Statement.fetch_ints` was written to hand back a column-major `List` because
that "is what a SIMD pass over the results wants". `m0_sqlite.stats_ints` and
friends are that pass, and measuring them turned up something worth writing
down: **pulling a column out and reducing it here beats asking SQLite to
aggregate it.**

200,000 integer rows, in-memory database, `sum` + `min` + `max`, values
checked against SQLite's own answers before timing (`bench_reduce` in
`bench_sqlite.mojo`):

| Path | Time |
| --- | --- |
| `SELECT sum(v), min(v), max(v)` — in-engine | 11.84 ms |
| `fetch_ints` + `stats_ints` | **8.63 ms** |
| of which, the reduction itself | 0.043 ms |

SQLite runs three aggregate steps through its bytecode VM for every row; the
read-out runs one column fetch. That is the whole difference — and it is why
the vectorization is almost beside the point. The reduction is **0.5% of the
pipeline**. It is 4x its own scalar loop, and that 4x buys nothing you would
notice unless the column is already materialised and you intend to pass over
it repeatedly.

**Do not read this as "aggregate in Mojo".** It is one shape: a full scan, in
memory, three aggregates at once, no index, no `WHERE`. Any of those moving
can move the answer past it — a single aggregate halves the VM work, an index
can make SQLite skip rows entirely, and a result set larger than memory makes
the read-out untenable at any speed. What it does establish is narrower and
still useful: when you already need the rows, computing an aggregate from them
is not the expensive choice it looks like, and reaching for SQL to avoid a
Mojo-side pass is not automatically right.

Integers only, deliberately. A vector sum reassociates the additions, and
floating point is not associative — a `Float64` version would disagree with a
scalar loop in the last ulp with no single right answer to test against.
Integer addition reassociates exactly, so these agree bit for bit at every
length, which `test_reduce.mojo` asserts from 0 to 80 elements and against
SQLite over 1,000 rows.

## The WSGI-bridge techniques, checked against this package

The bridge work (docs/WSGI_PERFORMANCE.md) distilled into a short method:
split a cost by part before designing against it; check whether a missing
API is missing or merely unbound; eliminate copies; hoist per-call
overhead; and measure a cache's *hit* path before building it. Checked here
deliberately, item by item:

| technique | status here |
|-----------|-------------|
| reach the unbound C API | **no analog** — libsqlite3 is on the link line, `external_call` already reaches all of it; `carray()` is absent from the *library binary*, which no loader trick fixes |
| replace interpreted work with C calls | **no analog** — there is no interpreter boundary |
| batch N calls into one (`PyDict_Copy`) | **no analog** — SQLite has no bulk row API (`sqlite3_step` is per row; already recorded at the SoA readers) |
| eliminate copies on the hot path | **already applied** — `column_blob` memcpy (13–20x), `column_blob_into` reuse, `m0_array` borrow-by-shape (3.4x) |
| measure a cache's hit path first | **already practiced** — the statement cache was rejected twice by measurement |
| hoist hidden per-call work | **checked, nothing there** — the `StringLiteral` → `String` conversion every binder pays on its happy path (`_check(rc, "bind_int")`) measures at **0.0 ns** in an optimized build; the compiler hoists it |
| read a value where its owner holds it, through a borrowed pointer (`PyBridge.read_head`) | **measured, not shipped** — a borrowed `Span` over SQLite's cell saves 2–3 ns/row at 64 B and 12–24 ns (4–6%) at 4 KB against `column_blob_into`, and the compile-time borrow that would make it safe does not exist on Mojo 1.0; see below |
| sabotage-prove every guard (`shim_ownership.py --sabotage`) | **was missing for `verify_layout.c`**, and the guard turned out to check the header against its own literals rather than against vtab.mojo; it now reads the Mojo constants and `poe sabotage-vtab` moves each of the 28 in turn — see "The layout guard" below |

Two things did come out of the check.

**A text scan pays 2.1x for its per-row `String`, and the zero-allocation
read already existed — undocumented.** The bench had int, float and blob
rows but no TEXT row, so `column_text`'s per-row allocation had never been
priced. Now it is (`bench_sqlite.mojo`, 100k rows, best of 5):

| read | 64 B | 4096 B |
|------|-----:|-------:|
| `column_text` (String per row) | 111.5 ns/row | 971.7 ns/row |
| `fetch_texts` | 134.9 ns/row | 1233.8 ns/row |
| **`column_blob_into` on the TEXT column** | **51.9 ns/row** | **463.7 ns/row** |

`column_blob_into` works on TEXT because SQLite converts TEXT to blob bytes
on request, and for TEXT stored as UTF-8 that conversion is a pointer
handoff. No new API was added — the fix is the two docstrings that now
point at each other, per this package's own rule: add the variant the day
something needs it, not speculatively.

**The verdict on the package**: it already embodies the method. The
remaining per-row cost of a scan is SQLite's own VM (`sqlite3_step`), which
is the same kind of floor the WSGI bridge just reached — the boundary code
is direct calls and single copies, and what is left is the engine itself.

### A borrowed read, measured and not shipped

The one bridge technique the table above had not tried here was
`PyBridge.read_head`'s shape: hand back the bytes where their owner holds
them, and copy nothing. `column_blob_into` is one `memcpy` away from that;
a `Span[Byte, origin_of(stmt)]` over `sqlite3_column_blob`'s pointer would
be zero copies. `bench_sqlite.mojo` carries it as `_column_bytes_span`,
beside the per-byte loop it keeps for the same reason — an A/B, not an
API. 100k rows, best of 5, 2026-09-04, same run for every row:

| read | 64 B | 4096 B |
|------|-----:|-------:|
| `column_blob_into` (reused), BLOB | 32.7 ns/row | 348.4 ns/row |
| borrowed span, BLOB | 29.8 ns/row | 336.0 ns/row |
| `column_blob_into` on TEXT | 33.0 ns/row | 370.9 ns/row |
| borrowed span on TEXT | 30.8 ns/row | 347.0 ns/row |

So the copy is 2–3 ns of a 64-byte row and 12–24 ns (4–6%) of a 4 KB one;
the rest is `sqlite3_step` moving the record out of its page, which no
read-side change touches. (This run's absolute numbers sit below the
table above, which was recorded on a different day; compare within a run.)

What would have justified the API was not the nanoseconds but the borrow.
SQLite says the pointer is valid until the next `sqlite3_step`,
`sqlite3_reset`, `sqlite3_finalize`, or a type-converting `column_*` on
the same cell; the first three take `mut self`, and the premise was that a
span carrying `origin_of(stmt)` would make the compiler refuse
`stmt.step()` while the span is alive — the borrow the Python side could
only document, enforced here for free. **It is not.** On Mojo 1.0.0 a
program that takes the span, steps, and then reads the span builds and
runs (printing the stale length), and so do the `reset` and `finalize`
shapes — and so does the stdlib's own `Span(list)` followed by
`list.append`, and a `ref`-returning method followed by a `mut` one.
Origins do the two jobs the manual gives them, extending the referent's
lifetime and enforcing argument exclusivity within one call; they do not
refuse a sequential mutation. A borrowed span here would therefore be
`column_blob_into` minus 4% plus a use-after-step the compiler cannot see,
which is exactly the class of bug `m0_array`'s borrow is enforced by
*shape* to prevent (`stmt.mojo`, "Array parameters"). Add to that the
package's rule — the variant is added the day something needs it, and
nothing in this repo or in the sibling SQLite projects scans large
TEXT/BLOB columns through m0-sqlite — and the answer is no API. The day
one of the four probes under "Reproducing" stops compiling, the API is
shippable, with that probe as its negative compile gate.

### The layout guard checked C against C

`test/verify_layout.c` asserts every offset `vtab.mojo` hardcodes against
the installed `sqlite3.h` — and until 2026-09 it did so with its own copy
of each number (`offsetof(sqlite3_module, xBestIndex) == 3 * 8`), so a
wrong `M_BESTINDEX` in the Mojo source compiled, passed the gate, and would
have corrupted rows in silence. The question that found it was the one the
handoff asked first: *what does the guard compare?* — not a sabotage, which
would have reported the right answer for the wrong reason. Now
`scripts/vtab_layout.py` extracts every `comptime NAME: Int` from
`vtab.mojo`, compiles the C file with each as `-DM0_NAME=N`, and holds the
two files to one closed set of names in both directions (a constant the C
file asserts must exist in Mojo; a constant Mojo defines must be asserted
or declared Mojo-own). Four offsets that were literals inside
`_x_best_index` (`base + 4`, `base + 5`, `u + 4`, the 32-byte `sqlite3_vtab`
allocation) became constants so the guard could see them, and
`SQLITE_INDEX_CONSTRAINT_EQ`, the one header constant copied by value, is
checked too. `poe sabotage-vtab` moves each of the 28 in turn (the two
allocation sizes to one word, because a larger buffer is legal) and breaks
each closed-set rule, and insists on a failure for every one.

## Recommendations

1. **Document batching prominently.** A `README` example that inserts in a loop
   without a transaction teaches the 46x-slower pattern.
2. **Consider a `mmap_size` argument or an `open_tuned` variant** rather than
   changing `open()`, given the SIGBUS trade. Left undone deliberately: it
   changes failure modes, so it is your call.
3. **Add a `json_each` helper** if fetching by id-set becomes common — the
   ergonomics, not the speed, are the reason: building the JSON array by hand at
   every call site invites an injection-shaped mistake that `?` normally
   prevents.
4. **Do not pursue carray.** Unavailable on macOS, unusable with structs, and
   both `m0_array` and `json_each` already cover what motivates it — `m0_array`
   for binding a Mojo `List` directly (~3x on bulk inserts), `json_each` for an
   id-set that arrives as data rather than as a live buffer.
5. **Revisit if the toolchain ever links its own SQLite.** Building the
   amalgamation with `-DSQLITE_ENABLE_CARRAY -DSQLITE_ENABLE_MATH_FUNCTIONS`
   and a controlled version would make several of these questions moot — at the
   cost of owning the build.

## Reproducing

The benchmarks were written as standalone Mojo programs against `-I
packages/m0-sqlite`, in the same shape as `packages/m0-core/run_benchmarks.mojo`.
They are not checked in; the measurements above are the deliverable. To redo
them, the four workloads are: N-row fetch by the four strategies above; 20k
random point reads under each pragma set; 10k inserts under each transaction
mode; and prepare-versus-reset for one trivial query.

The read-out rows (blob, text, borrowed span, ingest, reduce) are the
exception: `uv run poe bench-sqlite` is checked in and prints them. The
layout guard is `uv run poe verify-vtab-layout`, and `uv run poe
sabotage-vtab` proves it can fail.

The origin finding is four programs of a dozen lines, built with
`mojo build -I packages/m0-sqlite -Xlinker -lsqlite3`. The shape that must
NOT build for a borrowed span to be safe, and does:

```mojo
var q = db.prepare("SELECT v FROM t")
_ = q.step()
var s = _column_bytes_span(q, 0)   # Span[Byte, origin_of(q)]
_ = q.step()                        # mut self, while s is alive
print(len(s))                       # builds; prints the stale length
```

Swap the second `step` for `q.reset()` or `q.finalize()`, or reduce it to
`var s = Span(xs); xs.append(4); print(len(s))` over a plain `List`, and
each builds the same way. When one of them is refused, re-open the API.
