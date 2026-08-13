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
