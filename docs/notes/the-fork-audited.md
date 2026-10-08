# The fork audited — 2026-10-08

The review of the lightbug fork, 2026-10-07 and 2026-10-08: the method,
the numbers before and after, which instrument found which record, and
what is still open. It raised 69 records (LF1–LF69). 65 are fixed, one is
a duplicate, two are open, one was moved out of the fork's scope, and
none was refuted. The share of the fork's code lines unchanged since the
upstream import fell from 34% to 24%.

The plan, the three audit ledgers (one row per function) and the lane
reports are kept outside this repository. The ids are in the commits, the
pull requests, [NOTICE](../../NOTICE) and the CHANGELOG.

## Why

`packages/m0-http/lightbug_http/` is a hard fork of lightbug_http
v26.1.2 (NOTICE). At fbb88b9, blame showed 5,670 of its 16,518 code lines
unchanged since the import, and every parser-level defect the first
day's reading confirmed (LF1–LF4) sat on those lines. Every other defect
confirmed that day was in this repository's own later code: the WebSocket
parser, the pool, the bus, the shared page, `sendfile`. So the review had
two parts. Part 1 fixed what the reading found. Part 2 measured whether
anything else was there, with instruments that see what reading does
not.

## The measure

An inherited line is one `git blame -w -M -C` dates before 2026-03-24:
the import (05da7fe7, 2026-03-18) and the mechanical `fn` to `def` pass of
2026-03-23. A code line is one that is neither blank nor opens with `#`,
so docstrings count. The files are every `.mojo` under
`packages/m0-http/lightbug_http/`. Move detection follows upstream lines
through the 2026-09 split of the event loop into `loop/`. Copy detection
also credits a few new lines to old commits, so a rewritten function can
gain inherited lines: `c/fcntl.mojo` went from 5 to 18 when LF28 moved
`set_nonblocking` into it. For the audits each line went to its innermost
enclosing `def` or `struct` by indentation; a struct's fields and
docstring count to the struct.

## Method

- **Reading.** Five readers took the fork in slices of about 4k lines on
  2026-10-07 and wrote LF1–LF35. Each record says how it was established:
  4 by a probe that day, 7 re-read in the code and its callers, 14 on a
  reader's quoted code, 10 to be proven before any fix.
- **The differential run (D0).** 137 requests probing framing and field
  parsing, each on a connection of its own, written whole and half-closed,
  were sent to this server, to h11 0.16 and to Node 24's `http` (llhttp).
  86 agreed, 38 were RFC latitude (this server matched one reference), 6
  had this server alone differing, and 7 had all three differing. Every
  disagreement became a record, a latitude, an oracle defect, or an
  existing record. The table was then frozen as a gate (S1, SPEC B25):
  `smoke-differential`, every pull request, with `sabotage-differential`
  (B26) before a release. h11 and llhttp are how the table grows, never a
  CI dependency.
- **Fuzzing across reads (S2).** The loop's decision of where a request
  head ends, how its body is framed and where the request ends was
  factored out of `_handle_read_headers` into one pure function,
  `frame_request_head` (B29). The fuzzer runs 20k mutations a pull
  request, each split at random reads and told how far the last call
  scanned, as the loop calls it. Its invariants span the parser and the
  loop: the head ends where the parser stops, or the request is refused;
  a head split across reads is framed as it is whole; the chunked decoder
  fed a read at a time decodes as it does whole and never ends a body on
  a bare LF (B30). `sabotage-fuzz` breaks each invariant every pull
  request.
- **Two guards for classes the reading found.** A seeded property over
  every header writer (S3, G24, 4000 cases a run) holds LF1's class: no
  byte string puts CR, LF or NUL inside a head line. A fork lint (S4,
  G25) holds LF17's: no variadic libc call outside its sanctioned
  wrapper, and no `[byte=` slice outside a reasoned allowlist.
- **The audits (A1–A3).** After Part 1's deletions, every function still
  holding inherited lines in 31 files was deleted with a repo-wide grep,
  pinned by a named test (written where none existed), or recorded as
  needing none, one ledger row each. A1 took network and addresses; A2
  bytes, strings, URI, cookies, dates, the server's own responses,
  configuration and metrics; A3 HTTP messages, the server and the event
  backends.
- **Review.** Every lane's diff was read by an independent session before
  its pull request, with up to three fix rounds, and every ruling was
  written down with its cost if wrong.
- **Sabotage.** Every new gate was proven against its fix: the fix
  reverted, the gate seen to fail for the right reason, the fix restored.
  A compile failure is not a catch.

Seventeen lanes landed as pull requests: three alone (#580, #585, #590)
and fourteen in five merge trains (#577, #584, #589, #594, #597).
LF1–LF9, LF16 and LF17 shipped in m0serve 1.12.1 and m0 0.9.1; the rest
are unreleased on `main`.

## Before and after

Inherited code lines in the fork, by the measure above:

| commit | when | inherited / code lines |
|---|---|---|
| fbb88b9 | before the review | 5,670 / 16,518 (34%) |
| 93101c8 | Part 1 merged (train #589) | 4,639 / 16,157 (28%) |
| d5f0935 | A1, A2 and S2 merged (train #594) | 3,985 / 15,722 (25%) |
| 13e151e7 | A3 and M merged (train #597) | 3,780 / 15,707 (24%) |

By audit scope:

| scope | fbb88b9 | audit base (93101c8) | 13e151e7 |
|---|---|---|---|
| A1, six files | 1,980 | 1,453 | 1,112 |
| A2, fourteen files (thirteen now) | 1,088 | 954 | 666 |
| A3, eleven files | 2,130 | 1,766 | 1,557 |
| outside the three audits, 21 files (22 now) | 472 | 466 | 445 |

The audits wrote 623 ledger rows, one per function (a struct's own lines
and a module's imports count as one each): 159 deleted, 393 pinned by a
named test, 71 recorded as needing none. Every function that holds
inherited lines in their files at 13e151e7 has a row, which covers 3,335
of the 3,780 inherited lines. The other 445 are in files no audit was
scoped to (below).

The suite went from 1,609 unit tests to 1,750. `docs/SPEC.md` gained 59
rows (A26–A38, B12–B30, C11–C13, C16, C17, D12, D13, F22, F23, F25,
G19–G22, G24, G25, G28, I34–I42, J15), and `poe milestones` reports 396
capabilities, 370 verified, 26 out of scope, none `implemented`.

## Which instrument found what

| instrument | records | sec | bug | risk | maint, nit |
|---|---|---|---|---|---|
| reading, 2026-10-07 | LF1–LF35 | 2 | 11 | 10 | 12 |
| the differential run | LF36–LF39, and LF4's trailer line with no colon | 0 | 0 | 1 | 3 |
| a reviewer of a lane's diff | LF40 (P2's review), LF41 (R's), LF65 (A2's), LF69 (A3's) | 0 | 1 | 0 | 3 |
| a lane implementer, beside its own record | LF42, LF43 (L), LF49, LF56 (A1), LF57 (A2), LF63 (A3) | 0 | 3 | 1 | 2 |
| the audits | LF44–LF48 (A1), LF50–LF55 (A2), LF58–LF62 (A3) | 0 | 3 | 2 | 11 |
| freezing the corpus (S1) | LF64 | 0 | 1 | 0 | 0 |
| the fuzzer's split invariant (S2) | LF66, LF67 | 0 | 2 | 0 | 0 |
| a merge train's whole-suite run | LF68 | 0 | 0 | 1 | 0 |

LF59 (A3) is a duplicate of LF66, found independently by reading the
same function.

**Reading** found both security records: an overlong UTF-8 sequence
transcoded to CRLF after the header check (LF1, response splitting), and a
parser that ended a head at a bare LF where the loop framed at CRLFCRLF
(LF2). It found 11 of the 21 bugs and 10 of the 15 risks in one day, the
cheapest records of the review. What it missed falls into four kinds:
behaviour that depends on where a read ends, a rule all three parsers
share, Unicode case folding, and code that reads like configuration.

**The differential run** confirmed five reading records on the wire before
they were fixed (LF2, LF4, LF5, LF6, LF8), extended LF4, and found four at
the RFC's edges: CONNECT reaching the application (LF36), targets outside
the URI grammar (LF37), an empty `Host` refused (LF38), a coding before
`chunked` decoded (LF39). Freezing its table as a gate made someone read
each of the 137 answers against the RFCs, and that found LF64: a
`Host: a b` served where RFC 9112 §3.2 asks for 400. h11 and llhttp serve
it too, so D0 had counted it as agreement. The run cannot see
segmentation, since each case is written whole.

**The fuzzer** found the only records that turn on where a read ends:
LF66, two empty lines and then a request, refused 400 whole and served
200 when a read ended between them; and LF67, a bare CR before the request
line, served whole and refused split. The first day's readers saw
neither, and the differential sends each case in one write. A3's audit
found LF66's root independently the same day, reading `find_header_end`
line by line (LF59). The fuzzer needed the refactor first: one function
deciding the framing is also the structural answer to LF2's class, two
framers that disagree.

**The audits** found three bugs where a listen address is read and
reported: a bare `localhost` listened on a port the kernel chose (LF45),
`+80`, `8_0` and a space then `80` were read as port 80 (LF46), and the
banner named port 0 rather than the port bound (LF47). They found two
risks: a built cookie whose value could add attributes (LF55), and
transfer-coding names folded by Unicode's `lower()`, so `chunked` spelled
with U+212A KELVIN SIGN for its `k` read as `chunked` where every
ASCII-folding hop reads an unknown coding (LF58). The other eleven are
dead code, inherited TODOs and nits. Their larger product is the 393
functions pinned by a named test, and 838 inherited lines gone from their
scope. They took three lanes.

**Reviews** raised four records, and more often found a problem in a fix
or in the claim its SPEC row made: a repeated-`Connection` join that was
quadratic, a lone `gzip` answered 501 where RFC 9112 §6.3 says 400, LF55's
first rule dropping cookies browsers accept, Linux-only gates never run, a
row claiming sabotage catches before the harness had run, and a row
saying memory went back to the system when its gate proves reuse by other
connections.

**Implementers** proving a record found its neighbours: LF42 and LF43 are
half-close cases beside LF11, LF63 is LF58's Unicode fold in three more
places, and LF49 and LF56 are LF46's port reading in the environment.

**The trains** ran the whole suite on each merged train before its push.
Besides LF68, that run caught three breaks between lanes that each lane's
targeted gates could not see: a test's `external_call` signature that
conflicted with the program's, a property test still modelling a cookie
rule another lane had changed, and an application reading a field another
lane had deleted.

S3 and S4 found nothing. They hold the classes of LF1 and LF17.

## Where the effort paid

- **Read first.** Five readers for a day gave half the records, both
  security records among them.
- **Run the references before fixing.** D0 turned five read records into
  wire reproductions and added the RFC-edge ones. Freezing its table gives
  every later parser change a visible diff.
- **Factor the decision, then fuzz it across reads.** Reading and the
  differential both miss segmentation, and LF2's class lives on it.
- **Audit by function, and take the scope from the blame output.** The
  audits found parser-adjacent defects in functions a slice reader passes
  over, and pinned what they kept. The plan scoped them by a list of files
  and left 445 inherited lines in 22 files unaudited.
- **Review every diff, and run the whole suite on the train.** Those two
  caught overclaims and cross-lane breaks that no lane's own gates could.

## Still open

| item | retiring condition |
|---|---|
| LF24: the pool's wake and thread records sit 64 bytes apart where Apple silicon's lines are 128 | the A/B in `scripts/probes/quiet-machine-ab.md` on a quiet machine (`scripts/probes/pool_ab.py LF24`): the strides change if 128 is faster, and the cache-line docstrings are corrected if not |
| LF22's cost: the park's look at its lane socket adds a non-blocking `recv` to every park | the same runbook, `pool_ab.py LF22`; the owner rules on the result |
| LF68: `test_offload.mojo`'s `test_a_websocket_message_wakes_a_thread_parked_on_its_own_channel` hit its 2 s deadline once, in a whole-suite run at load 12, and in none of 18 runs alone or beside ten busy loops | an investigation. The test waits to see the lane's parked count at zero, which lasts only from the wake until the thread parks again, so a test thread descheduled across that window would fail although the message was served. Waiting on the thread's served count instead (the test reads it at the end) would tell a test-side miss from a lost wake |
| LF69: content negotiation finds `q=` by substring, so `Q=` is ignored and `;xq=0` reads as `q=0` | framework code outside the fork; on the owner's to-do list |
| the pre-release gates the lanes could not run | `stress-pool`, after LF22 and LF23 changed the pool and the bus; `sabotage-host`, whose files lanes A1, B, F and L touched (all 73 of its anchors still match exactly once at 13e151e7). Both are on RELEASING's list, so the next release runs them |
| 445 inherited lines outside every audit: `loop/` and `event_loop.mojo` (284), `c/process.mojo` (77), `c/pipe.mojo` (32), `c/fcntl.mojo` (18), and 34 in ten small files | an audit of their 76 functions by the A-lanes' method |

The event loop's inherited lines were read on 2026-10-07 and again by lane
L, which fixed LF11–LF15, LF42 and LF43 there, and S2 rewrote its head
path. No ledger row covers them.
