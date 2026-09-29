# The loop on the wire: what each read and write rule answers — moved out of CLAUDE.md 2026-09-28

> A design note from the engineering record, moved out of CLAUDE.md on
> 2026-09-28 (review record C11) and kept as written, with the day's
> renames applied. CLAUDE.md's "Runtime constraints" keeps each rule in a
> line or two and points here for the incident behind it. The event loop
> became the package `lightbug_http/loop/` that day (C3), so a function
> named below lives in one of its modules rather than in `event_loop.mojo`.

## Two backends, two trigger semantics

The two backends do not have the same trigger semantics, and every read
path must satisfy the stricter one. `add_read` is `EV_ADD` on kqueue — no
`EV_CLEAR`, so connection reads are LEVEL triggered and a partial drain is
simply reported again — while epoll registers `EPOLLIN | EPOLLET`, where
bytes already in the socket buffer when the edge fired produce no further
edge. (`add_read_listen` differs the other way: both edge triggered. A write
registration replaced the read registration on epoll and not on kqueue,
which is what `slot_read_armed` tracks; since review R4, 2026-09-28,
kqueue's one-shot write drops `EVFILT_READ` too, so it replaces it on both.)

So each platform forgives a different mistake, and macOS will pass without
the re-arm that Linux requires. `_handle_read_headers` performs exactly ONE
`recv` of `recv_staging.capacity()` (4096) per call and did not re-arm while
headers were incomplete: a request bigger than the eager read at accept plus
one edge — 8192 bytes exactly, measured — stalled on Linux until the header
timeout answered 408, while macOS served any size. 8 KB of request headers
is a large cookie jar or a JWT, not an attack. The body path had the fix
already, with a comment giving this exact reason; it just had not been
extended to headers. `poe smoke-large-request` pins it.

## A half-close is not a hang-up

`EV_EOF` on a read event means "no more request bytes", not "connection
over". A client may half-close (`shutdown(SHUT_WR)`) to say it has sent the
whole request and still be waiting to read the answer, so the loop finishes
the buffered request and only turns off keep-alive; an SSE stream still
closes, having no request left to answer; a WebSocket first reads what its
peer left buffered — a last message, its Close with the code the application
is told (SPEC L28) — and closes once nothing is left; and a request that is
still INCOMPLETE closes at once (`peer_eof`) rather than waiting out the
header timeout. Closing there discarded a response already written, which
the client sees as an RST and a lost answer.

The two backends used to disagree here, and that is why this was invisible
in CI: kqueue sets `EV_EOF` on the read filter for a half-close (data may
still be pending), while epoll only reports it because `add_read` registers
`EPOLLRDHUP` — which it originally did not, so on Linux a half-close was an
ordinary readable event that the header path happened to handle. Measured
before the fix, 30 requests per shape: macOS lost 24-30 of 30 on GET,
Content-Length and chunked alike; Linux lost none — and conversely a
half-closed INCOMPLETE request released its slot at once on macOS while
Linux held it the full 10 s to the header timeout's 408. Registering
`EPOLLRDHUP` was once recorded in CLAUDE.md as a deliberate non-change
"adding an event source per connection"; that was wrong on its own terms —
it is one more bit in the existing registration, delivering events only when
a peer actually half-closes — and both platforms now behave identically.
`poe smoke-half-close` pins the answered response AND the prompt release.

One consumer of the flag is subtle: `_handle_read_headers` reuses
`bytes_read = 0` as its EAGAIN-with-buffered-data sentinel, so "the peer
really hit EOF" travels as `recv_eof`/`peer_eof`, never as a zero byte count
— collapsing the two closed every request that was partial at an EAGAIN
pass.

## Pipelined requests are answered from the buffer

RFC 9112 §9.3. The bytes of request N+1 arrive in the same read that
completes request N and get no readiness event of their own — the edge that
carried them is spent on epoll, and the socket buffer kqueue's level trigger
watches no longer holds them. Three pieces make the tail answered rather than
silently dropped, which is what every release through v0.12.0 did:
`request_end` stamps where the answered request ends (at parse for
Content-Length, at completion for chunked — whose completion paths now
PRESERVE the bytes past the terminator instead of resizing them away); the
keep-alive reset keeps the tail (`prepare_for_new_request(keep_pipelined=True)`
— passed ONLY by the keep-alive resets, so accept and close still clear
whole and one client's tail can never leak into another connection's first
request); and `_drain_pipelined` re-parses the preserved buffer after every
completed response, one request per iteration. It is iterative on purpose
(recursing through the handler chain nests a call stack per request) and
unbounded on purpose (the send buffer is the real bound: an iteration whose
response cannot go out whole leaves the slot RESPONDING and exits). The
blocking server path had the same fix in its own shape until it was retired
on 2026-09-28 (C5). `poe smoke-pipelining` pins all of it.

## A WebSocket this side closes lingers, once, and says nothing more

RFC 6455 §5.5.1: the endpoint that sends Close first waits to RECEIVE one
before closing the connection. Closing as soon as the Close frame drained —
which is what the loop did — closes the socket before a reply can exist, so
the reply reaches a socket that is gone and TCP answers with an RST; that
reset flushes the peer's receive queue, taking the FIN and, for a client far
enough behind, the Close frame itself (33 of 200 concurrent closes reached
the `websockets` library as `no close frame received or sent` rather than
the app's own 1000). `WSState.closing` marks the wait, and the three
stream-ended close sites plus `_after_send`'s `should_close` branch set a
`WS_CLOSE_LINGER_NS` deadline in `slot_idle_deadline` — a WebSocket's is
otherwise 0, so a non-zero one IS the linger, and the existing idle sweep
reaps a peer that never replies. Two consequences worth keeping straight:
with idle timeouts off there is nothing to bound the wait, so that
configuration deliberately keeps the old close-at-once behaviour rather than
leaking a slot; and the read path drops the parser's close echo while
`closing`, because this side already sent one. `ws_probe.py`'s close-order
phase is the guard and its CONCURRENCY is load-bearing — one close at a time
passes on the broken server, which is how this survived two investigations.
[websocket-close-rst](websocket-close-rst.md) is the first fix's own record.

**The deadline is armed ONCE, and that is the whole of the bound.** None of
the four sites is a transition: the drain reaches its linger branches again
on every pass while a slot lingers (`sse_is_streaming` stays false once the
app's close unsubscribed it), and `_after_send` runs again for every send
that completes while `should_close` and `closing` are both set — a heartbeat
ping's, at the top of the list, until the heartbeat learned to skip a
lingering slot. Re-stamping there pushed the deadline two seconds into the
future about once a second, so the sweep never overtook it and a peer that
received Close and never answered held its slot for the life of the process
— the exact leak the gating on `idle_timeout > 0` says it exists to avoid.

**And nothing follows this side's Close** (RFC 6455 §1.4): the heartbeat
handler skips a slot whose `closing` is set, because a ping sent during the
linger raced the peer's Close reply and a client that had answered our Close
read `0x89 0x02 "hb"` where it expected the FIN — `stress-asgi` found it in 3
rounds of 30 under CPU hogs, which widen the window between the Close going
out and the reply being read; `ws_probe.py`'s quiet-linger phase holds its
reply for three heartbeat periods and requires silence, then a FIN (SPEC
L29). Every site writes the deadline only while `slot_idle_deadline` is 0.
Since review C4 (2026-09-28) that test lives once, in `_arm_ws_linger` in
`loop/state.mojo`, and `_stream_idle` zeroes a WebSocket's deadline when its
101 lands, leaving a `closing` socket's alone. (CLAUDE.md said
`_finish_response`'s 101 branch did the zeroing; C4 found it was
`_after_send`'s.) The guard is `poe smoke-idle-timeout` (SPEC L16), which
asserts BOTH bounds: a
close inside the linger is v0.15.1's bug, and a slot never reclaimed is this
one. L15's 64-way concurrent close phase passes on both broken servers,
which is why the bound needed a gate of its own.

## Chunked request bodies

**A chunked request body ends where RFC 9112 says it ends**, because the
request decoder is built with `consume_trailer = True`. Without it the decode
completed at `0\r\n` and the terminating `\r\n` every conforming client sends
stayed in the receive buffer — and closing a socket with unread data queued
makes the kernel send RST rather than FIN, discarding the response already
written. On `Connection: close` that is a response the client never sees:
measured at up to 53% of chunked requests, and 100% when the client paced its
writes. Keep-alive hid it by never closing. The cost of the rule is that a
client which omits the final CRLF now waits for it, as it would for any
truncated body.

**A chunked body is bounded twice: decoded size AND raw bytes consumed.**
`max_request_body_size` caps what the application receives; twice that caps
what the connection cost, read from the decoder's `_total_read`. Framing is
consumed and dropped as it is decoded, so the first bound alone leaves the
raw stream limited only by the ratio guard — which allows roughly three times
the body limit in chunk-extension bytes before it fires. The cost is that a
body whose framing outweighs its payload several times over (1 MB in 3-byte
chunks is 3.6 MB on the wire) now answers 413, which is what it is.

**A chunked request body is decoded incrementally, by ONE decoder per
connection.** `ConnectionProvision.chunk_decoder` is fed only the bytes that
just arrived and carries its chunk state across reads; the buffer is
`[headers][decoded][raw tail]` and `pending_bytes` says where the next batch
lands. It used to be rebuilt per read event: that re-copied and re-scanned
the whole body every time, making a chunked body O(N^2) on the loop thread
(1 MB 0.15 s, 2 MB 0.61 s, 3 MB 1.37 s, dribbled in 1 KB segments;
0.003/0.004/0.006 s after), and it reset `_total_overhead` so the decoder's
own abuse-ratio guard could never trip.

## A body the server accepts fits its receive buffer

The per-connection cap is `ServerConfig.recv_buffer_limit()` — headers plus
body allowance, floored by `recv_buffer_max` — never the bare field, which
was a second, lower ceiling that `--max-body` did not raise and that refused
oversized bodies as `400` where the body cap sends `413`.

## Request bytes are not UTF-8

A request-derived `String` may hold bytes that are not UTF-8, and is never
sliced with `[byte=a:b]`. The request target, every header value (the parser
passes obs-text, bytes above 0x7F, through) and the body all become `String`s
via `unsafe_from_utf8`, so String's UTF-8 invariant does not hold for them —
and `String[byte=a:b]` asserts a codepoint boundary at both ends, which is a
trap, not an error. Five sites had it: `unquote` (one `GET /?x=<0x80>%41`
killed the loop thread before any handler, every app and the production WSGI
deployment alike), the cookie jar (built for every request:
`Cookie: a=<0x80>`), the static mount's path, the `Accept` negotiator and
the ETag matcher. A sixth and seventh were not request bytes at all:
`split_sse_lines` and `sse_data_payload`, which a `--pg-listen` NOTIFY
payload reaches on worker 0's listener thread, and a `SQL_ASCII` database
converts nothing. An eighth is `m0-datastar`'s `split_data_lines`, the
deliberate COPY of that splitter (the wire format stays dependency-free, so
the fix had to be made twice and the copy kept trapping for a release): what
reaches it is a rendered fragment, and an application renders request data —
a todo whose text is `a\n<0x80>b` put a non-boundary byte after a line
break, because HTML escaping touches neither, and one unauthenticated POST
killed the whole server on the loop thread. Duplicating a function
duplicates its traps. Every such slice is now
`String(unsafe_from_utf8=s.as_bytes()[a:b])`, a byte-span slice with no
boundary check; `unquote` is a single byte walk. SPEC G14 is the row, one
test per site declares it, and both `smoke-hello` and `smoke-notes` send the
bytes over a socket.

## What a response head may carry

**A response header carrying CR, LF or NUL is dropped, not transmitted.** A
value an application built out of user input could otherwise end the header
block and add headers, or a body, of its own. Until 2026-09-28 the refusal
lived in m0-wsgi alone (`has_control_bytes` in its `response.mojo`, which
also emptied an injected status reason phrase, one that frameworks that
validate header pairs still leave alone), so a Mojo application's headers,
`--mount X=mojo` and the Mojo host wrote theirs unchecked; review record B6
moved it into the fork's head writers, where every response passes (SPEC
G1, G2). Dropping rather than raising: the application has already run and
its body is real.

**An application's `Set-Cookie` goes to the wire verbatim.** A `Cookie` is
what the server builds for itself; a line a WSGI/ASGI application returned
IS the header, and `ResponseCookieJar.add_raw` transmits it unparsed —
subject only to the CR/LF refusal above. Round-tripping it through
`Cookie.from_set_header` + `build_header_value` silently dropped `expires`
(the `Expiration` stub parses nothing), `SameSite` (lowercase-only match),
everything after the first `=` in a value, and any unmodelled attribute — on
every Django session and CSRF cookie of every app.
