# libpq keeps its handle — 2026-10-01

`m0-sqlite` found on 2026-09-30 that its pin did not do on macOS what its
row said (SPEC O23; [functions-inside-the-query](functions-inside-the-query.md)),
and fixed it there. The pin was `m0-postgres`'s code, copied, so
`m0-postgres` had the same defect and kept it. This is that half, and a
second defect its review found on the way. SPEC O24 is the row, and the
one decision it took is recorded in D49.

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

**The pin moved after the table.** It needs the image, which is an entry
point's address, so `PgLib.__init__` builds the table and then pins. A
library missing a symbol used to be pinned before it was refused; now its
handle closes on the raise and it unloads, with no table of it kept
(measured on Ubuntu 24.04 with a copy of libz: still mapped after the
refusal before this change, gone after it now). The version floor and the
thread-safety check stay in `open`, after the pin, as they were: a library
refused there stays mapped, as it always did, and nothing calls into it.

A later open of a pinned image is a walk of the pinned list, one
comparison long, and pins nothing. Before, every `PgLib.open()` paid a
second `dlopen` for the flag.

Six threads released together on a process's first open, 150 runs on one
image and 150 with half the threads opening a copy: one record per image
every time.

## A second image: pinned, not refused, and why that needed the scope

m0-sqlite refuses a library that is not the image the process opened
first, because SQLite does not survive two copies of itself on one
database file: each keeps its own list of open files, and a close through
one drops the other's POSIX locks. libpq has no such rule, so the first
version of this change pinned a second image beside the first and said
that nothing in libpq forbids two copies in one process.

Its review, from a session that did not write it, showed that false on
Linux as the package then opened libpq. `OwnedDLHandle`'s default mode is
`RTLD_NOW | RTLD_GLOBAL`, and the pin re-opened global too. With the first
libpq in the loader's global scope, glibc binds the internal calls of any
libpq loaded later into it, unless that build was linked `-Bsymbolic`.
Ubuntu's own build binds one data symbol across, `pgresStatus`, and no
function, which is why a copy of the system library showed nothing. A
different build does:

| Ubuntu 24.04, aarch64 | first image global | first image local |
|---|---|---|
| symbols of psycopg-binary 3.3.6's libpq 18.6 bound into Ubuntu's 16.15 | 69 (70 bindings) | 0 |
| a connection attempt through the second's own handle (`PgLib.open(path)`, then `connect_with`) | the process crashes, 3 runs of 3 | "connection refused", 3 of 3 |
| `psycopg.pq.version()` from psycopg-binary imported after the first image | 160015, the system's | 180006, its own |

A `PGconn` built by one version was being walked by the other. And the
second libpq need not be one this package opened: under `m0serve`, a
Python application on psycopg-binary loads its bundled libpq after
`--pg-listen` has loaded the system's. The binding count above is that
case, the second library loaded through `ctypes`, and the last row is
psycopg itself: captured whole, it ran on the system's libpq, and its
connection attempt failed cleanly. No crash was measured for it, because
its extension's own calls were captured with the rest; what it lost was
the library it shipped. All of this predates the change. It was measured
in a Python process modelling the two loads, and, in review, in a Mojo
program embedding CPython.

Then under a real `bin/m0serve`, built from the commit before the change
and from the one that made it, serving a WSGI application on psycopg-binary
3.3.6 with `--realtime --pg-listen` on Ubuntu 24.04 (aarch64, CPython
3.12, PostgreSQL 17 beside it):

| `psycopg.pq.version()` in a request | before | after |
|---|---|---|
| with `--pg-listen` | 160015, the system's | 180006, its own |
| without it (the control) | 180006 | 180006 |

In all four `psycopg.pq.__impl__` was `binary`, and with the listener on
both files were mapped in the serving process, the system's `libpq.so.5.16`
and the wheel's 18.6. The listener was in that process: the same pid, its
`pg-listen: listening on` line, and a `pg_notify` sent from the handler
arriving on a held stream. Nothing crashed on either side of the change:
before it, 60 queries in sequence and 40 eight at a time through the
captured psycopg all answered, at one worker and at two, with no worker
replaced. At two workers the one that runs no listener reported 160015 as
well, the library having been opened before the fork. What was observed is
the version psycopg reports; that its other calls went to the system's
library too follows from the binding count above and was not traced.

That measurement is now an arm of `smoke-pg-notify`: an application on
psycopg-binary served beside the listener must report the version it was
built against, with two libpq files mapped and the system's a different
version, or the arm says it proves nothing on that runner. Which it did,
on its first run in CI: GitHub's Ubuntu runner carries PostgreSQL's own
libpq 18.6, not Ubuntu's 16.15, and psycopg-binary 3.3.6 bundles 18.6 too.
So the wheel is pinned, in a dependency group of its own, to 3.2.13, which
bundles 17.6; the group also keeps it out of the free-threaded canary's
sync, the wheel having no free-threaded build.
Run by hand on the same Ubuntu with the open's flag put back to global,
alone and with the pin's, the arm failed both times, "psycopg was built
against libpq 180006 and reports 160015", after the three arms before it
had passed; unchanged, it passed with both files mapped.

And again for the pair CI has, PostgreSQL's libpq 18.6 as the system's
with the pinned wheel's 17.6 beside it: unchanged, the smoke passed with
both files mapped; with the open's flag global, the arm failed, "built
against libpq 170006 and reports 180006". A newer libpq captures an older
build's calls as the older captured the newer's: no crash, queries
answer, and the version psycopg reports is the one thing that shows it.

So every handle is `RTLD_LOCAL` now, the open's and the pin's, which is
m0-sqlite's second rule arriving for the same reason. Nothing here needs
the global scope: every entry point is looked up through the handle. With
it, a second image is sound on both platforms measured, and stays pinned,
not refused (D49): the word names a LIST of records, one per image, newest
first. In practice the list has one entry. On macOS, where two-level
namespaces never bound across, Homebrew's 17.6 and the EDB installer's
17.9 each connected to a local server and answered in one process, and
each reopen found its own image.

What was NOT measured: any pair of builds but that one on Linux, x86-64,
and TLS through either library.

## The gate, and its cadence

`test_pin.mojo` has three tests. A table copied out of a `PgLib`, five
reopens, one image and one record. A copy of the library's own file opened
as a second image, pinned once, reopened to the same image and answered
from after its handles are gone. And libpq absent from the loader's global
scope after an open, asked of the loader through the process's own handle.
An image is told by `PQlibVersion`'s address, read and never called.

The third test is the mechanism, not the fault. The fault needs a second
BUILD, and CI has one libpq per runner; a copy cannot show it. So the test
holds the scope, which a flag flipped back fails on both platforms, and
the table above is the measurement of what the scope prevents, taken once
by hand.

Only macOS can fail the kept handle, and CI's macOS runners do not promise
a libpq: the `macos-26-arm64` image of 2026-09-07 lists no PostgreSQL among
its software. This note first took that list to mean the image had none;
it has one. The first run of the job below was told Homebrew's libpq 18.6 was
already installed, some other formula's dependency, as Homebrew's SQLite
was for O23. So the install is what it is there: the thing that keeps a
library the image merely happens to carry from being what the gate rests
on. A row saying `(every PR)` over a test that every runner skips, or that
cannot fail where it runs, is the defect the review of #522 found twice.
That left two honest cadences:

- **every PR**, in a macOS job that installs libpq itself and fails
  without it;
- **pre-release**, on the reference Mac, where `test-postgres-server`
  already runs against Homebrew's libpq.

The row is `(every PR)`. A regression here is silent by construction: the
code keeps working and the process only grows. A gate that runs at release
time would report it weeks after the change that caused it, when that
change is no longer in anyone's diff. The cost is one `brew install libpq`
per pull request, which today finds the library there and installs
nothing, in a job of its own (`postgres-macos`) so that a Homebrew outage
reddens a job named for what it could not install. The Linux
`postgres` job runs the file too, inside `test-postgres-server`: the kept
handle is only stated there, and everything else in the file can fail
there.

`poe sabotage-postgres-pin` reverts seven rules by exact source lines: the
pin itself (the process dies in a call through an unmapped table), the
kept handle (caught on macOS, SKIPPED on Linux, which cannot see it), the
pin taken once, the per-image rule, `@no_inline` on the word, and the
local scope of the open and of the pin.

## What it does not cover

A libpq something else loads into the process BEFORE this package opens
its own, in the global scope: then it is this package's image whose calls
may bind into the other, and nothing here can prevent it. `m0serve` opens
libpq for `--pg-listen` before the application is imported, so the order
there is the safe one.

And a later `dlopen` of the SAME libpq file with `RTLD_GLOBAL`, by
anything else in the process: a re-open promotes an image opened local,
which is why the pin's own re-open is local. `ctypes.CDLL("libpq.so.5",
mode=RTLD_GLOBAL)` in an application would do it. Pure-Python psycopg,
which finds the system library through `ctypes`, does not: in review it
shared the package's image and the scope held.
