# Server performance: the raw HTTP hot path

Measured 2026-08-18, on the raw `lightbug_http` event loop (`apps/hello`,
single process, epoll backend). Companion to
[WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md), which measures the Django/WSGI
stack; this document is about the server itself, with the handler cost near
zero.

## Setup

- 4-core Linux container, 16 GB RAM, server and load generator on one box.
  **Absolute numbers drift hard between sessions and comparing across them
  will mislead you.** Measured directly: the same Go binary served 36k
  req/s in one session and 60k in another, a 1.7x swing from nothing but
  container load. Every comparison in this document was therefore taken in
  the same session as its counterparts, and any before/after claim comes
  from alternating A/B runs rather than a remembered number.
- `apps/hello/server.mojo` compiled with `mojo build` (Mojo 1.0, the
  `uv.lock` pin). Single process, `listen_and_serve_nonblocking`, default
  `ServerConfig`.
- wrk 4.1.0: 2 threads, 16 connections, 10 s runs after warm-up, keep-alive,
  against `/` (13-byte plain-text body). Three runs per configuration; the
  tables show a representative middle run.
- Competitors, same box, same wrk settings: Go 1.x `net/http`
  (`GOMAXPROCS(1)`, hello-world handler), Node 22 `http` (single process),
  uvicorn (single worker, plain ASGI app, no uvloop). All four servers are
  CPU-saturated on their serving core at these rates (verified via
  `/proc/<pid>/stat` — each burns ~100% of one core).

## Where the time went: a syscall budget

`strace -c` over a 5 s window of the pre-change server, keep-alive load:

| syscall           | calls/request | notes                                       |
|-------------------|--------------:|---------------------------------------------|
| `recvfrom`        | 1.0           | necessary                                   |
| `sendto`          | 1.0           | necessary — whole response in one send      |
| `epoll_ctl`       | 2.0           | **half of them failing with EEXIST**        |
| `timerfd_settime` | 1.0           | idle-timeout re-arm, every request          |

The `epoll_ctl` pair was the keep-alive re-arm: `add_read` tries `EPOLL_CTL_ADD`
(fails `EEXIST` — the fd is still registered), then falls back to `MOD`. The
`timerfd_settime` was the idle timer being re-armed after every response.
Five-plus syscalls per request where two suffice.

Beyond syscalls, gdb stack sampling under load put ~65% of the saturated
core inside `__libc_send` itself — on loopback, `send()` runs the peer's
softirq delivery and wakeup inline, so that share is partly the load
generator's cost billed to the server, and every server measured here pays
it. The user-space remainder concentrated in `String.to_lowercase` (header
`Dict` keys), `HTTPResponse.encode`, and allocation (`tc_new`).

## Changes landed in this pass

Each was measured in isolation against the previous step, same session:

1. **Skip redundant event re-registration** (`event_loop.mojo`,
   `slot_read_armed`). Read filters are persistent on both backends; the only
   operation that disarms one is `add_write_oneshot` (on epoll it replaces
   the fd's mask). Tracking that transition per slot eliminates both
   per-request `epoll_ctl` calls in steady state.
2. **Idle timeout by deadline sweep** (`slot_idle_deadline`). Instead of
   `timerfd_settime` per request, each response stamps a deadline and the
   loop sweeps active slots at most once a second (the loop already wakes at
   least that often — `wait(1000)`). Timeouts are whole seconds; nothing
   observable changes. Removes the last per-request `epoll`/timer syscall.
   Changes 1+2 together: **15.2k → 16.8k req/s (+10%)**.
3. **`TCP_NODELAY` on accepted sockets** (`set_tcp_nodelay`, accept path).
   Responses are single `send()`s — there is nothing for Nagle to coalesce,
   it only delays a response behind the previous one's ACK. Every mainstream
   server disables it. **16.8k → ~19.1k req/s (+5% throughput, p50 0.93 ms →
   0.81 ms)**.
4. **Date header: format once per second, not once per response**
   (`http_date_from_unix` + loop-level cache). Formatting cost ~10 small
   String allocations plus `gmtime` per response — measured **~9%** of hello
   throughput when it ran per-response in the `HTTPResponse` constructor.
   The constructor no longer stamps Date; the event loop injects a cached
   string (falling back to `encode()`'s own stamp for responses sent outside
   the loop).
5. **ASCII fast path for header encoding** (`write_header_latin1`). The
   ISO-8859-1 transcode allocated a scratch buffer per header per response;
   pure-ASCII values (all of them, in practice) are now written directly.
6. **Request construction on the cheap** (`HTTPRequest.from_parsed`): the
   parsed header `Dict` is now moved (swap) instead of deep-copied, and an
   origin-form path with no `%`-escape and no query string skips `URI.parse`
   entirely — every derived URI field is the path itself. Neutral on wrk's
   minimal requests, but removes a full Dict copy + URI parse per request
   for real traffic.

After all six: syscalls per keep-alive request are exactly `recvfrom` +
`sendto` (plus a shared `epoll_wait` amortized over ~16 requests), and the
strace error column is zero.

## Results

Same box, same wrk settings (t2/c16 keep-alive unless noted):

| server                        | req/s  | p50     | p99    |
|-------------------------------|-------:|--------:|-------:|
| mojo-http before this pass    | 15,200 | 1.03 ms | 1.7 ms |
| **mojo-http after**           | **18,900** | **0.83 ms** | **1.45 ms** |
| Go `net/http` (GOMAXPROCS=1)  | 36,000 | 0.44 ms | 1.2 ms |
| Node 22 `http`                | 18,200–26,500 | 0.54 ms | 1.6 ms |
| uvicorn (no uvloop)           | 5,000  | 3.1 ms  | 5.1 ms |

**+24% throughput, −20% p50.** The patched server holds its rate under
concurrency — 18.3k at c64, 17.3k at c256 (p99 21.8 ms, purely queueing) —
and does 11.4k in `Connection: close` mode, where accept-path costs
(2 × `fcntl`, header-timer `timerfd_create`/`epoll_ctl`/`close`) dominate.
Node's range reflects genuine run-to-run drift in this shared container.

Go's remaining ~1.9× is real and is not syscalls — both servers now issue
the same two per request. It is the per-request object machinery, detailed
next.

## Span-based headers

The item ranked first below landed next, and it was the largest single win
in this file's history: **+72% throughput** on top of everything above.

`Headers` stored a `Dict[String, String]`. Filling it cost two String
allocations per header, `.lower()` allocated a third to normalize each name,
and every lookup allocated a *fourth* — `key.lower()` builds a probe copy
before it can hash. At 5-15 headers per request that is dozens of
allocations to answer questions like "is this connection close?".

It now stores one flat byte blob holding every name and value back to back,
indexed by parallel (offset, length) arrays — the SoA pattern used
elsewhere in this repo. Names are lowercased on the way in, so a lookup is
a linear scan comparing lengths first and folding only the probe's bytes:
no allocation at all. Over 5-15 entries that beats hashing outright, and
insertion order is preserved, which the Dict never guaranteed.

Three things fell out of the new representation for free:

- `content_length()` parses digits straight out of the blob instead of
  materializing a String first — it runs for every request with a body.
- `value_equals_ignore_case()` answers the `Connection: close` question
  without building the two Strings the old `get(k).value().lower() == v`
  needed, on every single request.
- The parser dispatches field names with `name_is()` against known-
  lowercase constants, and trims OWS by moving span endpoints, so a header
  only becomes a String if it is a cookie.

Measured by alternating A/B runs in one session (wrk
t2/c16 keep-alive):

| variant | req/s | p50 | p99 |
|---------|------:|----:|----:|
| `Dict[String, String]` | 29,000 | 535 us | 0.90 ms |
| **flat blob + offsets** | **50,000** | **320 us** | **485 us** |

Five alternating rounds; the spread within each variant was under 5% and
the two never overlapped. Go `net/http` measured 60k in that same session,
so this moved mojo-http from 0.48x to 0.83x of Go on the same box.

Note what these absolute numbers are *not* comparable to: the 18.9k in the
table above was a different session on the same container. Against that
session's Go baseline of 36k, 18.9k was 0.53x. The honest way to read the
two tables together is by ratio, not by subtraction.

**How much this depends on header count.** The A/B above used wrk's default
request, which sends a single `Host` header — the *least* favourable shape
for a change whose cost scaled with header count. Measured separately on the
Django path, where the same before/after pair was run at one header and at
twelve: the benefit was 2.4x larger with twelve
(see [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md)). Real traffic sits at the
twelve end, so the number in the table is a floor, not a ceiling.

**The profile then flipped.** Before, stack samples showed
`String.to_lowercase`, `Headers.__init__`, and the allocator. After, 31 of
35 samples sit in `__libc_send` — the write syscall itself — with exactly
one in the allocator and one each in `set_bytes` and `Headers.__init__`.
The server is now syscall-bound on loopback rather than allocation-bound.

That result retires the rest of the header work. The parser still builds a
String per name and per value in `parse_headers` (`create_string_from_reader`),
and the original plan was to make `HTTPHeader` hold offsets too. The profile
says that is no longer worth its complexity: the leaf cost it would remove
does not appear in the samples. Revisit only if a future profile disagrees.

### What this deliberately did not do

The literal design sketched below — spans pointing *into the provision's
receive buffer*, with zero copy at all — would require `Headers` to carry an
origin parameter, which propagates to `ParsedRequestHeaders`, `HTTPRequest`,
and therefore the `HTTPService` trait. That breaks every handler in the
repo at once: all six apps, the five demo services in `service.mojo`, and
the README example. The blob copies the header bytes once per request and
gets the allocation win without touching a single caller — `Headers`'s
public API (`get`, `[]`, `in`, `pop`, `keys`, `content_length`) is
unchanged, which is why this landed as a pure internal substitution.

(`HTTPService`'s methods later gained default bodies, which does not change
this. A default removes the cost of *adding* a hook; it does nothing for
*changing a signature*, and `func` — the one method with no default — is the
one an origin parameter would rewrite.)

## Where the remaining gap lives

The canonical fast HTTP/1.1 servers (fasthttp, may-minihttp/ntex, and
TechEmpower's top plaintext entries generally) share one design decision:
**nothing request-scoped is allocated**. fasthttp documents it directly —
headers stay `[]byte` slices into the read buffer, request/response objects
are pooled per connection, `[]byte`→`string` conversions are avoided in hot
paths. The header half of that checklist is now done (above). What each
request still allocates:

- two Strings per header inside `parse_headers`
  (`create_string_from_reader`) before `Headers` copies the bytes into its
  blob — the one remaining piece of the header story, and the profile says
  it is no longer worth chasing;
- an `HTTPRequest` (cookie jar, URI struct with 12 String fields) and an
  `HTTPResponse` (its own `Headers`, 3–4 inserts);
- ~~a fresh `ByteWriter` per response~~ — **done, and it was worth less than
  this list implied — but the field it uses was already costing memory.** It was never blocked: a buffer moves out of a
  list-element field by `swap`, the same idiom `from_parsed` and `Headers`
  already used, verified on the 1.0 toolchain. Each slot now rotates one
  buffer between `encode_into` and `_after_send`. Measured in isolation at
  **76 ns per response (1.04x on the encode step)**, and *not* separable from
  run-to-run noise end to end — see below;
- a copy of the body bytes out of `recv_buffer`.

Ranked next steps, by expected value:

1. ~~**Response encode into a reusable per-slot buffer**~~ — **done; this
   ranking was wrong.** The change is in, and the honest result is that it
   buys 76 ns per response in isolation and nothing measurable end to end.
   An alternating A/B of the two binaries (`ab -k -c16 -n20000`, five rounds
   each) put both between 75k and 89k req/s with the distributions fully
   overlapping. That is what the post-header profile already predicted —
   one allocator sample out of 35 — and the general lesson is worth keeping:
   after the header work, *no* remaining allocation on this path is large
   enough to see through loopback noise. Rank the next two accordingly.

   It landed anyway, and on a different argument than throughput.
   `ProvisionPool` eagerly constructs every provision at startup —
   `for _ in range(capacity)` over `max_connections`, 1024 by default — and
   each one allocated an `encoding_buffer` of `socket_buffer_size`. That is
   ~4 MB of heap per process that nothing read or wrote. The choice was
   never "76 ns or nothing"; it was "use the buffer, or delete the field".
   Using it also retires the false claim that Mojo cannot move out of a
   list-element field, which is what put this item at the top of this list
   in the first place.
2. **Close-mode accept path**: `accept4(SOCK_NONBLOCK)` (one syscall instead
   of accept + 2 × `fcntl`), and pool header-timeout timerfds instead of
   create/close per connection. Only matters for non-keep-alive clients;
   the close-mode p99 suggests accept-queue latency is the tail.
3. **Body handling**: hand the handler a span into `recv_buffer` instead of
   a copied `Bytes` (needs a lifetime story for the handler contract).

Temper all three against the post-header profile: with 31 of 35 samples in
`__libc_send`, user-space work is no longer what limits this server on
loopback. The next honest win is likely more sockets doing the sending —
`M0_WORKERS` prefork already exists (see WSGI_PERFORMANCE.md) and
everything here compounds per worker — rather than more shaving in the
request path. Measure before building.

## The instrument, and what it overturned (2026-08-28)

Everything above was measured with `wrk` and gdb stack samples, and the
post-header profile's verdict — 31 of 35 samples in `__libc_send`, "no
remaining allocation on this path is large enough to see through loopback
noise" — retired the rest of the header work. That verdict was drawn at
~50k rps, when a request cost ~20 µs. The server now does 116k rps/core, a
request costs ~8.6 µs, and a cost that was 5% of the old request is 12% of
the new one. Loopback sampling cannot see a change of a few hundred
nanoseconds; a per-part instrument can, and `scripts/bench_http_parts.mojo`
is that instrument — the same shape as `bench_bridge_parts.mojo`, one layer
down. Twelve-header browser GET, 20k iterations, Apple M4:

| part | before | after |
|---|---:|---:|
| `find_header_end` | 0.047 µs | 0.046 µs |
| **`parse_request_headers`** | **2.520 µs** | **2.052 µs** |
| `from_parsed` (derived) | 0.261 µs | 0.281 µs |
| `Headers` lookups (`in`, `get`, `value_equals_ic`, `content_length`) | 40–70 ns | 40–75 ns |
| `Router.match` hit / miss | 0.100 / 0.027 µs | 0.099 / 0.029 µs |
| `OK()` construct | 0.672 µs | 0.651 µs |
| `encode_into` (derived) | 0.275 µs | 0.347 µs |
| **whole user-space request** | **3.743 µs** | **3.309 µs** |

Two things the table says that the profile did not. The parse is **two
thirds** of the user-space request, not a leaf; and the two allocation
findings this pass set out to measure are noise — the
`Array[HTTPHeader, 100]` fill was 66 ns and `parse_http_version`'s List
39 ns. What was not noise was the item ranked first in "Where the remaining
gap lives" and then retired: the two `String`s per header that
`parse_headers` built for `parse_request_headers` to read back as bytes and
copy into the blob. `HTTPHeader` now holds four offsets into the buffer the
parser was given, the token scanners expose their spans (`scan_token`,
`scan_to_eol`; the `String` wrappers stay for the request line and the
response status), and the wrappers slice the buffer they already hold. The
Array fill became 3.2 KB of integers as a side effect, and
`parse_http_version` compares seven bytes instead of building a list.

**−0.47 µs on the parse, −12% on the user-space request**, with all 556
m0-http tests and the eight parse-sensitive smokes (pipelining, the 8 KB
request, half-close, the client's response parser, cookies, the WebSocket
handshake, the header timeout) unchanged. Less than the 1.2 µs a scratch
attribution predicted for 24 allocations: short names and values fit
Mojo's inline string storage and never touched the heap, which is the kind
of thing only the measurement settles.

What was left in the 2.05 µs was recorded as the next lever: below 64
bytes remaining the scanners fell back to a `try_peek` per byte,
`set_bytes` appended and lowercased twelve names into the blob, and the
wrapper's three RFC checks were three linear `in` scans.

## The lever, taken (2026-08-29)

The same instrument, plus a scratch spike splitting the parse row in two,
said where the 2 µs actually went — and the split was not what the entry
above assumed. The low-level scanner (`http_parse_request_headers`) was
1.07 µs, of which **0.3 µs was the `Array[HTTPHeader, 100]` fill** — the
66 ns the table above measured for it was the fill in isolation, where the
compiler could elide most of it; in the parse, passed to a function, it is
3.2 KB of stores per request. The wrapper — the blob build and the RFC
checks — was **1.16 µs, more than half**. And inside the scanner, the SIMD
helpers were spending their time not in SIMD: having learned with one
`reduce_min` that a chunk held a match, they walked up to 64 lanes with a
scalar loop to find which — **9.4 ns per chunk for a CR at lane 46**,
against 0.8 ns for a `select` of `iota` and a second `reduce_min` that
names the lane with no branch.

Four changes, in the order they paid: the lane walk replaced by the
`select`/`iota` idiom in every scanner, each now running 64 lanes wide,
then 16, then scalar, so the last headers of a request stop falling to a
`try_peek` per byte; the offsets array uninitialized rather than filled
(the parser writes all four offsets of an entry before counting it);
`Headers.reserve` sizing the blob and index once from the bytes consumed
and the field count, with a value copied in by one `extend` (twelve inserts
had been growing the blob through nine reallocations and the index through
seven); and the three RFC scans folded into the dispatch loop the wrapper
already ran — the Host check had been building a `String` to measure its
length. Same twelve-header browser GET, 20k iterations, medians of three:

| part | before | after |
|---|---:|---:|
| `find_header_end` | 0.045 µs | 0.016 µs |
| **`parse_request_headers`** | **1.96 µs** | **0.86 µs** |
| `from_parsed` (derived) | ~0.2 µs | ~0.2 µs |
| `Headers` lookups | 32–67 ns | 31–69 ns |
| `Router.match` hit / miss | 0.099 / 0.027 µs | 0.093 / 0.026 µs |
| `OK()` construct | 0.66 µs | 0.52 µs |
| `encode_into` (derived) | 0.37 µs | 0.36 µs |
| **whole user-space request** | **3.33 µs** | **1.97 µs** |

**−1.1 µs on the parse (−56%), −40% on the user-space request**, with the
`OK()` row's −0.14 µs a side effect: a response's headers go through the
same `set_bytes`. The instrument gained a warm-up pass on the way — with
the parse under a microsecond, its row (the first heavy loop) read the
allocator's cold start, 0.85 in one run and 1.20 in the next with the
parse-plus-build row below it.

One answer changed, and the old one was wrong: the wide scan looked for the
first CR and only then for any other control byte, so a field value ended
by a bare LF ran on to the next line's CR whenever one lay in the same
64-byte chunk, and that line vanished into the value. The mask is now the
scalar tail's own predicate, so the widths agree; the test that pins it
fails on the old scanner, and length sweeps from 1 to 140 bytes for
values, names and targets cross every hand-off between widths in both
directions (a 16-wide block returning its lane without its base fails the
value sweep and nothing else — that is what the sweeps are for).

**On the wire it is +23% to +24%.** `apps/hello` built from the old and
the new parser, run side by side on distinct ports (SO_REUSEPORT would
otherwise let one take the other's connections), byte parity asserted
first, browser headers, keep-alive, three rounds alternating between the
two so drift lands on both, cores measured off each process
(`bench/results/parse-lever-ab/hello-wrk-parse-ab-20260829T043918Z.json`,
medians):

| | old | new | |
|---|---:|---:|---|
| c16 rps / p50 / cores | 122.1k / 113 µs / 0.98 | 150.2k / 90 µs / 0.97 | **+23%** |
| c64 rps / p50 / cores | 123.1k / 487 µs / 0.98 | 152.1k / 390 µs / 0.96 | **+24%** |

Re-measured later the same day on a machine confirmed idle (another
Claude Code session had run alongside some of the day's later benchmarks,
and this row has no in-run comparator to show it clean):
`hello-wrk-parse-ab-20260829T145148Z.json`, c16 118.9k → 142.3k (+20%),
c64 122.0k → 152.0k (+25%), p50 114 → 91 µs and 491 → 391 µs — the same
gain within run-to-run drift, so the first table stands.

That is ~155–158k rps per core on the hello row where the page above
says 116k, and the arithmetic checks: −1.36 µs of user-space work on a
request that was ~8.6 µs all-in is −16% of the request, and 1/0.84 is
1.19 before the cache effects of touching less memory per request. The
p50s move by 23 µs at c16 and 97 µs at c64 — the same per-request cost
removed, multiplied by the connections queued behind it in a closed-loop
client.

Through the ASGI executor the same change is worth +8–10%, because the
parse is a smaller share of a request that also runs Python: on the
benchmark page's row (stdlib asyncio, c16, uvicorn asyncio re-measured
beside each arm, `bench/results/parse-lever-ab/`) the pump went 55.7k →
60.1k rps and `M0_INVERTED=1` 54.5k → 59.7k — both now above the
comparator's ~58.5k, which neither was before — and on the uvloop
executor 63.2k → 69.1k and 60.2k → 66.4k. ROADMAP.md's inversion entry
carries the reading.

What remains is ~0.86 µs of parse against the 5.3 µs of a request that is
the two syscalls, which no parser touches.

## The outbox sweep (2026-08-29)

The other per-pass cost the inversion entry in ROADMAP.md had named.
Every pass swept all 1,024 slots for a streaming connection whose outbox
needed draining, and the miss path — two flag loads per slot, none set —
measured **1.2–1.3 µs per pass** in isolation (a scratch spike over two
`List[Bool]`s of 1,024). A pass carries one or two requests at c16, so
that is a visible share of a request that costs 8.6 µs on the hello row
and ~15 µs through the inverted executor.

The ceiling first, with the sweep skipped outright on builds whose
benchmark routes never stream (`bench/results/outbox-sweep/`, uvicorn
re-measured beside every executor arm and within the clean band on all
of them):

| | with sweep | without | |
|---|---|---|---|
| hello c16 | 146.5k @0.99 | 151.6k @0.98 | +3.5% |
| hello c64 | 154.7k @0.99 | 157.9k @0.97 | +2.1% |
| executor, `M0_INVERTED=1`, c16 | 59.3k @0.88 | 61.7k @0.89 | +4.1% |
| executor, pump, c16 | 60.0k @0.97 | 58.2k @1.03 | **−2.9%, +6% CPU** |
| executor, pump, c256 | 79.1k @1.02 | 79.0k @1.01 | ±0 |

The pump row is the finding. Its loop thread does not run the
application; it parks requests and flushes them to the executor thread
as one datagram per pass, and a loop that returns to `wait` a
microsecond sooner finds fewer events waiting, batches fewer submits,
and wakes the executor more often per request. The sweep's microsecond
was accidental pacing, and at c256 — where batches are large regardless
— it makes no difference either way.

So the gate is scoped: `OffloadLoopState.streaming_hint`, an upper bound
on the flagged slots that the two flag-setting sites raise and the sweep
itself recounts, skips the sweep while it is zero — except when the pool
says `sweeps_every_pass`, which only the pump's wiring sets. Realized:
hello **152.3k → 157.4k at c16 (+3.3%, +5.5% per core)**, +1.3% at c64;
inverted **59.3k → 62.0k (+4.6%)**; pump 60.0k → 59.7k @0.98, parity
within noise.

The pump row's question — is an explicit pause better than the
accidental one? — was answered the same day with fourteen more arms
(`bench/results/outbox-sweep/pacing/`; the table is in ROADMAP.md,
"Pacing the pump's loop thread"). A spin of 1.2–2 µs on *every* pass
reproduces the sweep to within noise (60.0–60.1k against 59.95k); a
spin only before a partial flush does nothing (58.6–59.0k, the same as
no pause), because the batch is already whatever the previous `wait`
returned — the pause that matters is the one after writing responses,
which lets the clients' next requests arrive before the loop parks; and
re-polling after the pause to fold new events into the same batch is
worse (55.7k at 1.08 cores). The pump keeps its pacing through the
sweep it already runs; there is no knob to add. The per-byte token validation
(`is_token_char` over a name's bytes) was measured against a bit table and
is a wash — 1 ns per byte either way — and is not a lever. Nor is a
state-machine rewrite in the picohttpparser shape: the row it would
attack is now a fifth of the user-space request and a tenth of the whole.

## Non-goals, considered and rejected

- **Pipelined-request support** — no longer a non-goal: implemented
  (RFC 9112 §9.3), because dropping the tail was never just a benchmark
  gap — it was a hang for any client that pipelines. `request_end` marks
  where an answered request ends, the keep-alive reset preserves the bytes
  past it, and `_drain_pipelined` answers them without a fresh read edge;
  `poe smoke-pipelining` pins it. The benchmark note this entry used to
  carry still stands: TechEmpower plaintext runs 16-deep pipelining and
  flatters servers that batch parse/write — mojo-http now answers that
  shape, but attempts no batching: one response per parse, one send each.
- **`writev` for header/body split** — the response is already assembled
  into one buffer and sent with one syscall; vectored IO would only help if
  encode stopped copying the body, i.e. after next-step 4.
- **io_uring** — a different backend entirely; the epoll loop is not the
  bottleneck at current rates.

## Reproducing

wrk is not a dependency of this repo (same policy as gunicorn in the WSGI
doc). The shape of a run:

```bash
uv run poe build-all
uv run mojo build -I packages/m0-core/ -I packages/m0-http/ \
  apps/hello/server.mojo -o /tmp/hello_server
/tmp/hello_server &

wrk -t2 -c16 -d10s --latency http://127.0.0.1:8080/       # keep-alive
wrk -t2 -c16 -d10s -H 'Connection: close' http://127.0.0.1:8080/

# Syscall budget (the strace overhead inflates µs/call ~10×; use the
# calls and errors columns, not the time):
strace -c -p "$(pgrep -x hello_server)" & sleep 5; kill -INT %%
```

`scripts/bench_hello.sh` automates the matrix (baseline + concurrency
sweep) and prints a summary table.
