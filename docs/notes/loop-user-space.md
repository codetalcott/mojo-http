# The loop thread's user space — measured and cut, 2026-09-06

> A design note from the engineering record. It is the step after
> [pool-ring-handoff.md](pool-ring-handoff.md): with the handoff in
> memory, the event-loop thread of a one-worker, one-handler-thread
> `m0serve` still cost about a microsecond more per request than
> Granian's tokio thread, all of it user space. This note re-took the
> profile on the ring build, let its ranking set the order, and reports
> what moved and what did not.

Bare WSGI at one worker and one handler thread, main at `043ac1d` and
this branch, the same session, arms alternated: 186k requests per
second against 170k at 16 connections, 202k against 182k at 64, and
205k against 186k at 256. The loop thread's per-request cost went from
5.8 µs to 5.1 at 16 connections and from 5.3 to 4.7 at 256 — the tokio
thread's figures in the same session are 5.1 and 4.7. The row is
0.98x Granian at 16 connections (from 0.90x that morning, on the same
binaries), 0.97x at 64 and 0.99x at 256.

## Where the ranking pointed

On-CPU samples of the loop thread (Instruments' Time Profiler through
`xctrace`, the instrument [loop-thread-bound.md](loop-thread-bound.md)
describes), ring build, 16 connections, before anything here was
built. The kernel — one `recvfrom`, one `sendto`, a fifth of a `kevent`
per request — was 57 % of the thread and within 0.2 µs of tokio's; user
space was 43 %, about 2.7 µs, against tokio's 1.2. Its largest symbols:

| share of the loop thread | symbol | what it was |
|---:|---|---|
| 5.6 % | `Headers._name_matches` | the case-folding scan behind every header lookup; the loop asks for a dozen names a request, and the parser scanned the growing collection once per field for duplicates |
| 4.2 % | `scan_token` | after the SIMD find of the colon, a byte-at-a-time walk of every name through an eighteen-test range-and-compare chain |
| 3.1 % | `Headers.set_bytes` | an `append` per name byte, each a capacity test and a length store |
| 2.7 % | `List.extend` | the staging-buffer copy after every `recv`, and four extends per header line in the encoder |
| 2.4 % | `_handle_read_headers` | its own bookkeeping, two clock reads among it |
| 1.9 % | `_service_completions` | a fresh `List` per drain, and on every read of the completion channel a 2 KB buffer allocated and zero-filled one `append` at a time |
| 1.1 % | `ByteReader.peek` | a raising call, in a `try`, for a byte the caller had already proven present |

The isolated instrument agreed about the parse: `scripts/bench_http_parts.mojo`
priced `parse_request_headers` at 0.89 µs for a twelve-header browser
GET, and the whole user-space request at 1.98.

## What was built

All in `packages/m0-http/lightbug_http/`, and one line in the WSGI
bridge.

- **A known-name index on `Headers`** (`known_header_id`, `KH_*`,
  `Headers._known`). The ten names the server itself asks about —
  content-length, content-type, connection, transfer-encoding, host,
  date, cookie, upgrade, expect, server — are classified by length and
  first byte before any full compare, and the collection records each
  one's entry index, so a lookup for one of them is O(1) whatever the
  collection holds. The parser dispatches on the same id once per
  field instead of asking three `name_is` questions. `pop` rebuilds the
  index. A **presence word** (`Headers._present`, one bit per name from
  its length and first and last bytes) answers "absent" for every other
  name without touching the index; only a set bit permits the scan. The
  parser's per-field duplicate check, which was the O(n²) part, is one
  AND per field.
- **Inserts by raw copy.** `_set_bytes` reserves room for the value and
  the name together — grown geometrically with a floor, because
  `List.reserve` sizes exactly and reserving per insert made an
  unreserved collection reallocate on every one — then copies the value
  with one `memcpy`, lowercases the name eight bytes at a time into the
  blob, and writes the four index words with one length store. The
  bridge reserves its response headers with room for what the server
  adds after the application (Content-Length, Connection, Date), so
  those inserts no longer reallocate on the loop.
- **The token scanner verifies with a vector.** `is_token_char` is two
  64-bit words indexed by the byte, and `scan_token` checks sixteen
  bytes at a time through `_non_tchar_lanes` — the complement of tchar
  as twelve vector compares — falling back to the table for a tail
  shorter than a vector. `try_peek` reads the byte directly behind the
  availability test.
- **One `recv` into the connection's own buffer.** The header path
  receives past what `recv_buffer` already holds and bumps its length;
  the staging buffer and the copy out of it are gone from that path
  (the body and WebSocket paths keep theirs). Still exactly one read
  of `recv_staging.capacity()` bytes per call, which the 8 KB header
  rule depends on.
- **The encoder writes a header line as one reservation and two
  copies** (`ByteWriter.write_header_line`), tests a value for ASCII
  sixteen lanes at a time (`span_is_ascii`), and the loop stamps Date
  and Connection through the known index rather than a classified
  `__setitem__`. The bridge's `all_ascii` over every environ value
  (4.7 % of the handler thread) is the same vector test.
- **Small things the ranking named**: the completion channel's receive
  buffer lives on the pool; the loop's list of finished slots is reused
  across passes; `_drain_pipelined` is inlined into its six callers; a
  request's first bytes stamp the header clock without also measuring
  it; the chunked-body test asks the known index before building an
  `Optional[String]`.

Measured in isolation (`bench_http_parts.mojo`, twelve-header browser
GET, 20k iterations, Apple M4):

| part | before | after |
|---|---:|---:|
| `parse_request_headers` | 0.889 µs | 0.621 µs |
| `from_parsed` (derived) | 0.186 | 0.097 |
| `Headers` `in` / `value_equals_ic` / `content_length` | 38 / 42 / 51 ns | 6 / 12 / 2.5 ns |
| `OK()` construct | 0.488 | 0.221 |
| `encode_into` (derived) | 0.320 | 0.316 |
| **whole user-space request** | **1.978** | **1.330** |

## Measured in situ

`ps -M` per thread, medians over 8 s of `wrk -t2` with browser
headers, `apps/wsgi_bare`, `--workers 1 --blocking-threads 1`, Apple
M4, CPython 3.13.6, granian 2.8.2, one session, arms alternated. Base is
main at `043ac1d`.

| connections | base | this branch | granian 2.8.2 |
|---|---:|---:|---:|
| 16 | 169.9k / 169.2k rps (loop 98 %, pool 77 %) | 186.0k / 184.8k (loop 94–95 %, pool 75 %) | 189.1k / 189.5k (tokio 96–97 %, blocking 79–81 %) |
| 64 | 182.4k (97 %, 62 %) | 202.1k (99 %, 60 %) | 208.8k (97 %, 80 %) |
| 256 | 185.7k (99 %, 62 %) | 205.1k (97 %, 57 %) | 207.2k (98 %, 77 %) |

Per request on the loop thread: 5.8 → 5.1 µs at 16 connections, 5.3 →
4.9 at 64, 5.3 → 4.7 at 256; tokio's 5.1, 4.6 and 4.7. The pool thread
is cheaper too, from the bridge's reserve and vector test: 4.5 → 4.1 µs
per job at 16 connections (spin included) and 3.3 → 2.8 at 256, against
Granian's blocking thread at 4.2 and 3.7. The layer-split artifact
re-recorded on this tree (`bench/results/layer-split-20260906T151035Z.json`,
three rounds, medians) has the row at 183.1k against 189.1k, 0.97x, and
the Mojo-only `apps/hello` row — the same parse and encode with no
handler thread to hide behind — at 195.8k from 148.7k.

The profile afterwards has user space at 36 % of the loop thread.
`_name_matches` is gone from the list (the scan it did runs only for a
name outside the ten, and only when the presence word permits it);
`scan_token` is 1.1 %; `List.extend` 0.4 %; `ByteReader.peek` gone. What
remains is the parser's own two passes (`parse_headers` 3.0 %,
`parse_request_headers` 2.4 %, `_set_bytes` 3.7 % — most of it the
copies a `Headers` that owns its bytes has to make), and about 0.7 µs of
per-request state work across `_handle_read_headers`, `_process_request`,
`_run_pass`, `_service_completions` and `_finish_response`: moves of
the parsed-headers and request structs (`Optional.take`, the parked
request), per-slot stores, and the twenty-four-argument calls the loop's
functions make to each other. The allocator is about 4 %: the request's
two header buffers allocated here and freed on the pool thread, and the
response's two plus its body freed here.

## What did not move, and is not kept

- **A spin before the park.** With jobs in flight the loop watched the
  completion ring for 2, 5 or 10 µs before raising its parked flag and
  entering `kevent`, on the theory that the pool's wake datagram and
  the kernel wake were the bubble at 16 connections. Throughput was
  unchanged — 172.8k off against 172.8k, 173.6k and 174.1k on — while
  the loop's CPU rose from 89 % to 91–95 %. The wake is not where the
  time goes; the idle time is time with nothing runnable.
- **Completions serviced after every read event**, so one did not wait
  behind the rest of a batch. At 16 connections +1 %, inside the noise;
  at 256 connections 198.0k against 213.4k with the pool thread's cost
  per job up from 2.8 µs to 4.4. A per-read `is_empty` on the completion
  ring reads the cache lines the pool thread writes, and stealing them
  fifty times a pass is what the pool thread then paid for. The two
  drains per pass stay.
- **Lazy cookie jars and query map.** Both jars and `URI.queries` are
  `Dict`s, and a dozen allocations a request looked likely. Measured
  with opaque sinks, an empty `Dict` construct-and-destroy is 0 ns on
  Mojo 1.0: it allocates lazily. No lever there.
- **The clock.** `mach_absolute_time` is 1 % of the thread either way;
  one read per request came out of the header path and the rest stay.

## What is next: measured, and not much

At 256 connections the row is at parity and at 16 it is within 3 %.
The first draft of this section named three structural candidates for
the next microsecond, and a microbench the same day priced them
(`sizeof` and park-and-take round trips through the same `Optional`
lists the loop and pool use, opaque sinks, 200k iterations, Apple M4):

| candidate | per request |
|---|---:|
| `ParsedRequestHeaders` (184 bytes) parked in the provision and taken back | 56 ns |
| `HTTPRequest` (584 bytes) parked in the pool and taken back | 5 ns |
| `HTTPResponse` (288 bytes) parked and taken | 25 ns |
| the twelve-`String` `URI` fast-path construction | under 4 ns |
| a call with twenty-four arguments against one state argument | 1.31 ns against 1.34 |

About 85 ns together, under 2 % of the loop's 5.1 µs, and the
twenty-four-argument calls the read path makes cost nothing measurable:
the `mut` lists travel as pointers, and a wide call is a narrow one.
What remains in the profile is the parser's two passes (about 0.55 µs
for ten headers, most of it copies a `Headers` that owns its bytes has
to make), the allocator (about 0.2 µs: the request's two header buffers
allocated here and freed on the pool thread, the response's two and its
body freed here), and roughly 0.6 µs of per-request state work spread
thinly across the loop's own functions with no single symbol above
4 %. A fused single-pass parser and a single-allocation `Headers` might
be worth 0.2 µs between them, 4 % of the thread, on a row that is
already within 3 % of Granian's; the next real difference would need a
line-level profile of that state work, and beyond it both threads are
at the kernel's price for one `recv` and one `sendto` per request,
which is the price tokio pays. The loop-thread line of work stops here.
