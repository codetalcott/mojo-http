# libpq keeps its handle — 2026-10-01

`m0-sqlite` found on 2026-09-30 that its pin did not do on macOS what its
row said (SPEC O23; [functions-inside-the-query](functions-inside-the-query.md)),
and fixed it there. The pin was `m0-postgres`'s code, copied, so
`m0-postgres` had the same defect and kept it. This is that half. SPEC O24
is the row, and the one decision it took is recorded in D49.

## What it was

`pin_library` re-opened libpq `RTLD_NODELETE` and let the handle go. The
flag keeps the image mapped, which is what lets a `Result` outlive its
`Connection` (O16), and the handle was thought to be spent. On macOS it is
not: an image opened `RTLD_NODELETE` stays mapped after its last handle
closes but leaves dyld's list, so the next `dlopen` of the same path maps a
fresh copy.

Measured with Homebrew's libpq 17.6 on macOS 27.0.1 (arm64), under `mojo
run`: one `PgLib.open()` and its destruction per cycle, `PQlibVersion`'s
address read and `_dyld_image_count()` taken while the library was open
and after it closed.

```
images before any open: 422
cycle 0  PQlibVersion at 0x10b67aee8  images during: 431  after: 422
cycle 1  PQlibVersion at 0x11474eee8  images during: 431  after: 422
cycle 2  PQlibVersion at 0x1147a2ee8  images during: 431  after: 422
cycle 3  PQlibVersion at 0x11520eee8  images during: 431  after: 422
cycle 4  PQlibVersion at 0x115262ee8  images during: 431  after: 422
cycle 5  PQlibVersion at 0x1152b6ee8  images during: 431  after: 422
```

A new image at every reopen, five of five, and nine images out of dyld's
list at each close: libpq and the eight libraries it brings. Nothing
faults. A stale pointer into a dropped image keeps answering, which is how
O16's tests passed throughout. So for libpq it is a leak, where for SQLite
it was corruption: one mapping of the library per close-and-reopen, and a
process reopens whenever its last `PgLib` goes and another opens. A
connection per request on one thread is one per request.

No libpq on macOS escapes it. What hid the SQLite case was Apple's library,
which lives in the dyld shared cache, where no image is dropped; Apple
ships no libpq. glibc keeps a `RTLD_NODELETE` object findable, so Linux
never showed it and cannot: with the kept handle removed, the test below
passes on Ubuntu 24.04.

## What was built

m0-sqlite's shape: one `pop.global_alloc` word behind a `@no_inline`
accessor, a record published by compare-and-swap, the pin's handle moved
into an allocation that is never freed, and a read-back through the
readers' accessor. The same probe on this branch:

```
images before any open: 422
cycle 0  PQlibVersion at 0x10ae82ee8  images during: 431  after: 431
cycle 1  PQlibVersion at 0x10ae82ee8  images during: 431  after: 431
cycle 2  PQlibVersion at 0x10ae82ee8  images during: 431  after: 431
```

and so on: one address, and the nine images stay.

Two things differ from m0-sqlite, both on purpose.

**A second image is pinned, not refused** (D49). m0-sqlite refuses a
library that is not the image the process opened first, because SQLite
does not survive two copies of itself on one database file: each keeps its
own list of open files, and a close through one drops the other's POSIX
locks. libpq has no such rule. Two builds of it in one process each hold
their own connections and share nothing a close could take away, so a
refusal would be a new way to fail that buys nothing. The word therefore
names a LIST of records, one per image, newest first, and each image a
process opens is pinned once. In practice the list has one entry.

**The pin moved after the table.** It needs the image, which is an entry
point's address, so `PgLib.__init__` builds the table and then pins. A
library missing a symbol used to be pinned before it was refused; now its
handle closes on the raise and it unloads, with no table of it kept
(measured on Ubuntu 24.04 with a copy of libz: still mapped after the
refusal before this change, gone after it now). The
version floor and the thread-safety check stay in `open`, after the pin,
as they were: a library refused there stays mapped, as it always did, and
nothing calls into it.

A later open of a pinned image is a walk of that list, one comparison
long. Before, every `PgLib.open()` paid a second `dlopen` for the flag.

## The gate, and its cadence

`test_pin.mojo` holds both halves: a table copied out of a `PgLib`, five
reopens, one image; and a copy of the library's own file opened as a
second image, pinned, reopened to the same image and answered from after
its handles are gone. An image is told by `PQlibVersion`'s address, read
and never called.

Only macOS can fail the first half, and CI's macOS runners carry no libpq:
the `macos-26-arm64` image of 2026-09-07 lists no PostgreSQL among its
software. A row saying `(every PR)` over a test that every runner skips,
or that cannot fail where it runs, is the defect the review of #522 found
twice. That left two honest cadences:

- **every PR**, in a macOS job that installs libpq itself and fails
  without it;
- **pre-release**, on the reference Mac, where `test-postgres-server`
  already runs against Homebrew's libpq.

The row is `(every PR)`. A regression here is silent by construction: the
code keeps working and the process only grows. A gate that runs at release
time would report it weeks after the change that caused it, when that
change is no longer in anyone's diff. The cost is one `brew install libpq`
per pull request, in a job of its own (`postgres-macos`) so that a Homebrew
outage reddens a job named for what it could not install. The Linux
`postgres` job runs the file too, inside
`test-postgres-server`: it states the property there, and its second half
can fail there.

`poe sabotage-postgres-pin` reverts four rules by exact source lines: the
pin itself (the process dies in a call through an unmapped table), the
kept handle (caught on macOS, SKIPPED on Linux, which cannot see it), the
per-image rule and `@no_inline` on the word.

## What it does not cover

A libpq something else brought into the process. Under `m0serve`, a Python
application on `psycopg` loads its own, through its own handle. That is an
image this package never opened and has no say over, and for libpq, unlike
SQLite, two of them in one process is not a fault.
