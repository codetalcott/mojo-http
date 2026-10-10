# The README points to the page that owns a fact — 2026-10-10

A record from the engineering notes. It holds the incident behind the
README's rule, the rule, and the two halves of the rule no gate enforces
yet.

## The incident

1.12.0 (2026-10-06) gave a WSGI hold a replay journal (SPEC I33). The
release updated the pages that own the realtime contract — RUNNING.md, the
`m0pub` docstring, the changelog — and the README's "SSE replay is
journal-deep" limit went on saying a hold "has no journal at all ... and
replay nothing", telling applications to keep a catch-up path they no
longer needed. It stayed through 1.12.1, 1.13.0 and 1.14.0.

One read of the whole README against the tree on 2026-10-10 found seven
more claims the tree had moved past: the Mojo pin (1.0, where `uv.lock`
pins 1.1.0); `DatastarStream` resuming a client live where SPEC I30 sends
it nothing and answers `caught_up(slot)` false; a handler's optional hooks
"shown here" beside an example that shows none; `m0-http` using "three
functions" of `m0-core`, which it imports from ten files; exit codes
without 78; uploads raised through a `ServerConfig` field an m0serve user
cannot reach; a "recorded follow-up" recorded nowhere. RUNNING.md, read
for the move below, offered `--threads` from 3.13t.

The README had 231 commits in the month before, behind only the changelog
and the capability matrix, the two pages meant to change every round
(RUNNING.md, the page that owns most of what the README restated, had 28).
Of its 974 lines the docs gate read six facts: the test counts, the
platform table against `release.yml`, the two copies of the mounted p99
against each other, the free-threading floor, conflict markers, and the
benchmark spans. 23 measured figures sat outside the figure rule
(`FIGURE_PAGES` in `scripts/check_docs.py` listed README as backlog).

## Why the README drifted

- **It restated facts other pages own.** Flags, discovery, the ready
  line, modes, mounts, `--doctor`, limits and exit codes are RUNNING.md's;
  the Mojo layer is MOJO_HOST.md's and MOJO_VIEWS.md's; every capability
  is a SPEC row; the measurements are BENCHMARKS.md's and
  SQLITE_PERFORMANCE.md's. A change lands on the owner page, where its
  gate and its reviewer are, and the copy is not on anyone's list.
- **It repeated itself.** The served contract twice, the platforms three
  times, "no TLS" three times, the quickstart's CI claim twice, the mounted
  p99 twice (with a check whose only job was keeping the copies equal),
  "no statement cache" twice, the Python range twice.
- **It narrated history in the present tense.** "Is gone", "used to",
  "now raises", "no longer", "Through Mojo 1.0": each is a changelog entry
  that has to stay true where it stands.
- **It kept lists the tree produces.** A command block copying `uv run
  poe`, with ports; counted headings ("Two more things", over three
  bullets); inventories ("three functions").

## The rule

The README states what no other page owns: what the project is, how to
install it, the packages, the example applications, and the SQLite and
PostgreSQL APIs, which have no page of their own. Everything else is a
link to its owner. A figure in it is a `num:` span or sits in an
`observed: WHERE` block. History goes to the changelog or a note.
Headings and inventories are written so they cannot be miscounted.

Four facts had no owner but the README, and moved to RUNNING.md: which
`libpython` m0serve loads (`python3` on `PATH`, or `MOJO_PYTHON_LIBRARY`);
how a mount's prefix reaches its application (`SCRIPT_NAME`, `root_path`);
which WSGI bodies stream (SPEC K9); and what `--doctor`'s JSON carries.
The README went from 974 lines to 583 and from 23 bare figures to none.
The mounted p99 kept one copy, marked as observed in
[wsgi-vs-asgi-history.md](wsgi-vs-asgi-history.md) §9.

## What no gate holds yet

Both halves wait on a change to `scripts/`, which runs `Tests` (hours of
runner time) where a page-only change runs `Docs` alone, so they ride with
the next pull request that runs `Tests` anyway:

- **README.md into `FIGURE_PAGES`.** With no bare figure left, adding it
  is one line, and a bare figure then fails `check-docs` naming its line.
  The comment above `FIGURE_PAGES` still counts README's backlog at 29.
- **`check_hybrid_p99_consistent` retired.** It compares two copies of
  the mounted p99, and one is left; once the README is a figure page, the
  `observed` marker is the rule that holds the figure.

The SQLite and PostgreSQL sections could move to pages of their own the
same way: a new `docs/*.md` page needs a row in `scripts/docsite.py`'s
page table.

The test total stays quoted twice, in the package table and in the
commands block, because `check_test_counts` reads both; a gate holds both
copies, so neither can drift.

**Later the same day**, both halves rode with the pull request that fixed
#611 and #612, which ran `Tests` anyway: README.md is in `FIGURE_PAGES`,
where a bare figure fails `check-docs` naming its line, and
`check_hybrid_p99_consistent` is gone, the `observed` marker holding the
one copy of the mounted p99 that is left. The comment above
`FIGURE_PAGES` no longer writes a count down.
