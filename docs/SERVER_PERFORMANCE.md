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
- a fresh `ByteWriter` per response, moved into the slot afterwards
  (`encode_into` exists for buffer reuse but is blocked on moving a buffer
  out of a list-element field — the `swap` idiom used in `from_parsed` and
  in `Headers` is the likely unblock);
- a copy of the body bytes out of `recv_buffer`.

Ranked next steps, by expected value:

1. **Response encode into a reusable per-slot buffer** via the swap idiom —
   removes the per-response `ByteWriter` growth cycle. Now the largest
   remaining allocation on the response side.
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

## Non-goals, considered and rejected

- **Pipelined-request support** (draining a second buffered request without
  a fresh read edge): today `prepare_for_new_request` clears `recv_buffer`,
  so pipelined bytes are dropped; real browsers and proxies don't pipeline,
  and wrk only does with `--script`. Worth knowing when comparing against
  TechEmpower plaintext numbers, which *are* pipelined (16 deep) — that
  benchmark shape flatters servers that batch parse/write, and mojo-http
  currently can't run it. Revisit only if that comparison ever matters.
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
