# Compressing a stream

A brief for the session implementing it. Written 2026-10-26 in the
datastar-builder repo, from a measurement there
(`datastar-builder/docs/measurements.md`, "compressing a seat's stream",
not yet in that repo's pushed tree). Revised the same day against this
repo at `05d28811`. The revision added three measurements: what the deploy
target's proxy does with a page and a stream, the `apps/blobs` stream's
ratio, and its CPU cost. It also traced every write to a stream and every
per-slot owner, read what other Datastar servers do, and moved the anchors
to where the code now lives: `loop/streams.mojo` (`_drain_outboxes`,
`_heartbeat`), `loop/state.mojo` (`_farewell_streams`, `_close_slot`,
`_chunked_stream_ends`), `loop/response.mojo`'s stream marking,
`src/sse/response.mojo`, `m0-datastar/src/stream.mojo`,
`m0-sqlite/src/lib.mojo` and `deploy/mojo/Dockerfile`. It touches SPEC J8,
J9, I14 and O17, and DECISIONS D33, D49 and D54.

The first version chose gzip through the system zlib. The owner chose zstd
on 2026-10-26, on the evidence in "Why zstd" below. The gzip design is in
this note's history if a second coding is ever wanted.

Where it stands: steps 0 and 2 landed with the binding (#632), and steps
1, 3, 4 and 5 with the stream (rows I45 and I46, D69). Step 6, with the
blobs setting and the image probe it needs, remains.

Read `CLAUDE.md` first and run `uv run poe milestones`. This brief adds
one capability, opt-in, and changes no default.

## The claim

m0 compresses nothing by decision (SPEC J8: a proxy compresses). For a
buffered response that holds, on the deploy target too. For a server-sent
event stream it does not, on three counts:

1. **A proxy must flush at every event boundary** or the page gets events
   late; the ones that do still add their own buffering, and nginx's must
   be told not to (`X-Accel-Buffering: no`, which `sse_response` already
   sends to defeat it).
2. **The deploy target's proxy compresses pages and leaves streams
   alone.** Measured 2026-10-26 on `m0serve-demo` and `m0serve-blobs`
   (`server: Fly/331937a822`), each request sending
   `Accept-Encoding: gzip, br`. A buffered `/` comes back
   `content-encoding: br`, though m0 sent no coding; m0serve.dev, asked
   for `zstd` too, comes back `content-encoding: zstd`. `/events` comes
   back `text/event-stream` with no coding, whatever the client accepts.
   On Fly, a stream is the one body that reaches the client as m0 wrote
   it.
3. **A stream that repeats itself compresses well only through a context
   that lives as long as the stream.** Measured on a Datastar game's seat:
   each event compressed alone gives 3:1; one context per stream, flushed
   per event, gives 23:1 with deflate and 29:1 with brotli. The repeated
   HTML comes round every 0.6 s, so a deflate window beyond 16 KB adds 6 %.

How much it pays depends on the stream. `apps/blobs` streams whole
simulation states, about 22 KB/s in events of about 2.1 KB, with little
markup repeated. It gives 2.6:1 per event alone and 3.4:1 with one zstd
context. The method: a 6 s capture of the deployed stream, compressed
with one context and a flush per event, in Python 3.14's
`compression.zstd`. The seat's ratio comes from markup that recurs inside
the window. Without that, a shared context gains less than half again
over compressing each event alone.

So: streams are the one place m0 compresses, as an option a response asks
for, with one context per connection and a flush per event, in zstd
through the system's libzstd, opened at run time.

## What other Datastar servers do

Each read on 2026-10-26 at its repository's head.

- **hyperlith** (`andersmurphy/hyperlith` at `b0536ef`,
  `src/hyperlith/impl/datastar.clj` and `impl/zstd.clj`):
  - one zstd context per connection, closed with the stream: level -1
    ("twice as fast as 1"), window log 19, checksum off;
  - each frame compressed with `EndDirective/FLUSH`. It moved from
    brotli to zstd on 2026-08-23. Until 2026-10-14 it compressed each
    frame with `EndDirective/CONTINUE`, which flushes nothing, and a
    commit titled "Switch to flush" changed that;
  - `Content-Encoding: zstd` sent without reading `Accept-Encoding`;
  - a fixed 32 KB output buffer that raises on overflow ("Fix zstd silent
    overflow", 2026-09-20).

  Its README reports ratios "of 20000:1 sometimes more" over a series of
  whole-view renders.
- **Datastar's Go SDK** (`starfederation/datastar-go`,
  `datastar/sse-compression.go`). `WithCompression` wraps the writer per
  connection. The default codings are brotli, zstd, gzip and deflate, in
  that order, and the server's order wins. The compressing writer is
  flushed after every event. Its `parseEncodings` drops each coding's
  parameters, so `zstd;q=0` selects zstd. It sets no `Vary`.
- **Datastar's Clojure SDK** (`starfederation/datastar-clojure`). A "write
  profile" wraps the output stream, and the documented example is gzip.
  Its brotli library, taken from hyperlith's earlier code, defaults to
  quality 5 and window 24 (16 MB).
- **Anders Murphy, "Why you should consider using brotli compression with
  SSE" (2025-04-15).** Brotli at quality 5. Widening the window from
  32 KB to about 263 KB took a game's stream "from 30:1 to 150-250:1",
  because its repeats are spaced far apart. zstd was set aside then
  because Safari lacked it.
- **Fly's proxy** (`docs.fly.io/reference/content-encoding`):
  - compresses a response that carries no `Content-Encoding`, preferring
    zstd, then brotli, gzip and deflate;
  - passes one that carries a coding through unmodified;
  - "buffers responses before compressing them", and so recommends
    `Content-Encoding: none` for streaming HTML.

  The page does not say whether the client's `Accept-Encoding` reaches
  the app; step 0 measured that it does.

## Why zstd

- **deflate's window stops at 32 KB**, a limit of the format. A stream
  whose repeats lie further apart than that, like Anders' game, gains
  nothing from any deflate setting, and the seat's own ratio climbs right
  up to that ceiling (21.5:1 at 16 KB, 22.8:1 at 32 KB). The HTTP zstd
  coding allows windows up to 8 MB.
- **zstd costs about a fifteenth of gzip's CPU.** On the blobs capture,
  flushed per event:

  | Coding | Ratio | CPU per MB |
  | --- | --- | --- |
  | gzip, level 6 | 3.6:1 | 53 to 65 ms (two runs) |
  | zstd, level 1 | 3.4:1 | 3.1 ms |
  | zstd, level 3 | 3.5:1 | 3.9 ms |
  | brotli, quality 5 | 3.8:1 | 21 ms |

  A larger window found nothing more on blobs, with any of the three. The
  cost lands on the loop thread once per subscriber, so this is the figure
  that matters most: 100 blobs subscribers take about 1 % of a loop
  thread at zstd level 1, against about 14 % with gzip.
- **Every browser engine decodes it:** Chrome 123, Firefox 126 and
  Safari 26.3, the last on macOS 26.3 and iOS 26.3 only.
- **The deploy image gains no package:** `libzstd1` is in every Debian
  image for the same reason `zlib1g` is, since `dpkg` depends on both.

What it costs, accepted with the choice:

- macOS ships no `libzstd`. Homebrew's is named among the candidates; a
  Mac without it serves streams uncompressed.
- Safari before 26.3, and any other client that does not offer zstd, gets
  the stream uncompressed, as today.
- Memory per stream is about twice deflate's. Live contexts measured
  after 130 KB of input; zstd grows toward its window on a long stream:

  | Context | Memory |
  | --- | --- |
  | deflate, window 14, mem level 6 | 103 KB |
  | zstd level 1, window log 15 | 201 KB |
  | zstd level 1, window log 19 | 317 KB |
  | zstd level 3, window log 19 | 1,023 KB |

## Ground rules

- **No link flag** (D40's closed `m0 build`, with D49 and O17 as the
  precedent). libzstd is opened at run time through `OwnedDLHandle`, with
  m0-sqlite's loader rules adopted from the start:
  - the handle and its entry points in one struct, every entry point
    private behind a method beside it;
  - the handle opened `RTLD_NOW | RTLD_LOCAL`, since `OwnedDLHandle`
    defaults to `RTLD_GLOBAL` and a global image captured a second copy's
    calls on Linux (O24);
  - one handle per process, opened on first use and never closed, its
    record published in a `pop.global_alloc` word of the module's own
    (as `_pinned_image_slot` keeps sqlite's) by compare-and-swap, since
    `M0_THREADS` loops can ask together.

  There is no second-image refusal, as m0-sqlite has: two copies of
  libzstd in a process are harmless, because a context is only ever used
  through the table that made it. `M0_LIBZSTD` names the file outright.
  Otherwise the candidates are `libzstd.so.1` and the distributions'
  directories on Linux, and `libzstd.1.dylib` then Homebrew's and
  MacPorts' directories on macOS. An absent library is one error naming
  every path tried.
- **Opt-in per response, through a field.** Nothing compresses unless the
  handler asked. The ask is a field on `HTTPResponse` beside
  `sse_streaming`, never the `Content-Encoding` header. An application
  that compresses its own stream sets that header (Django's
  `GZipMiddleware` compresses a `StreamingHttpResponse`), and the loop must
  not compress it again. The field is a fork change, so NOTICE records
  it. J8 stays `out of scope` for buffered responses; its text gains
  "except a stream that asks".
- **Every byte after the head goes through the slot's context.** The
  outbox drain is one of three writers to a stream. The heartbeat
  (`_heartbeat`, `: heartbeat` through `_send_frame`) and the drain's
  farewell (`_farewell_streams`, `: close` through a bare `send`) are the
  other two. Raw bytes in the middle of a zstd frame corrupt everything
  after them, so neither may skip the context. Neither may be refused for
  a compressed slot through `_takes_an_out_of_band_frame` either: the
  heartbeat is what keeps a held stream alive through an idle proxy.
- **The loop's miss path stays what it is.** The outbox sweep's miss path
  is one flag pair and a `continue`, measured at 1.2 µs a pass; a
  compressing slot adds its work on the hit path only.
- **Measure before and after**, the repo's habit: the hello row and the
  SSE rows in `docs/BENCHMARKS.md` must not move for a stream that does
  not compress.
- **Gate it** (CLAUDE.md: nothing ships `implemented`). Each new SPEC row
  names the gate that proves it, and the gate declares the row in turn: a
  `covers:` line in the test's docstring, or `scripts/emit.py --covers` in
  what the step runs (F12).

## The steps, in order

### 0. The deploy target forwards `Accept-Encoding`

Answered on 2026-10-26, before the loop was touched, through a throwaway
Fly app in the `textshelf` organisation. It was a Python server with one
route that echoed the request's headers and one that sent a zstd stream,
an event every 0.5 s; it was destroyed after the run.

- **The client's `Accept-Encoding` reaches the app unchanged**, q-values
  included: `gzip, deflate, br, zstd`, `zstd;q=0, gzip` and
  `br;q=1, zstd;q=0.5` each arrived as sent. The proxy's own choice for
  the echo honours them: zstd for the first, gzip for the second, brotli
  for the third.
- **A stream the app compressed passes through with its coding and
  unbuffered**: `content-encoding: zstd` at the client, and each of 20
  events decoded on arrival, 0.43 to 0.58 s apart.

Had the proxy stripped or rewritten the header, the app would never have
learnt what the client takes, and the feature would do nothing on the
deploy target.

### 1. The decision, and the rows

- `docs/DECISIONS.md`: a new row, next id, `standing`, recorded in this
  note: *m0 compresses a streaming response that asks, with one zstd
  context per connection and a flush per event, through the system's
  libzstd opened at run time. Buffered responses stay a proxy's job (J8),
  which Fly's proxy does. zstd for its CPU (a fifteenth of gzip's on the
  blobs stream, paid per subscriber on the loop thread) and its window;
  it pays on a stream that repeats markup inside its window and little on
  one that does not (blobs: 3.4:1 against 2.6:1 per event alone).
  Retired by: a proxy on the deploy target that compresses
  `text/event-stream` with a flush per event and one context per
  connection (on 2026-10-26 Fly's compressed pages and left streams
  alone); a measured stream where a flush per event loses the gain; or
  clients that cannot take zstd asking for compression, which brings
  gzip as a second coding.*
- `docs/SPEC.md`:
  - J8's reason reads "no dynamic compression of buffered responses; a
    proxy compresses; a stream may ask (row below)".
  - A new row in section I: *An SSE stream compressed per connection, one
    zstd context for the stream's life, flushed at every event, its
    heartbeats and farewell included, when the response asks and the
    client accepts zstd*, `planned` until step 5's smoke exists.
  - A second new row, O17's shape: *libzstd is opened at run time, never
    linked; an absent library is one error naming every path tried,
    `M0_LIBZSTD` naming the file outright; a library missing an entry
    point, or older than 1.4.0, is refused by name*, gated by
    `test_zstd.mojo`.
  - I14 (`permessage-deflate`) keeps its line: WebSocket is not this.
- `docs/ROADMAP.md`, "Automatic `Vary` tracking and dynamic compression":
  its last sentence, "The framework ships no compressor", becomes the one
  compressor, for streams, and why.

### 2. zstd, opened at run time

New `packages/m0-http/lightbug_http/c/zstd.mojo`, beside the fork's other
C bindings (`fcntl`, `socket`, `sendfile`). It belongs in the fork because
the loop calls it. In `src/`, the loop would reach it through a second
import from the fork back into `m0_http`, where D33 allows exactly one
(`m0_http.log`). `src/` imports `lightbug_http` freely, so `sse_response`
reaches it from there. NOTICE records the module. m0-core stays zero-deps
and has no business with a C library.

- **Entry points.** `ZSTD_versionNumber`, `ZSTD_isError`,
  `ZSTD_getErrorName`, `ZSTD_createCCtx`, `ZSTD_freeCCtx`,
  `ZSTD_CCtx_setParameter`, `ZSTD_compressStream2` and `ZSTD_sizeof_CCtx`;
  for the tests, `ZSTD_createDCtx`, `ZSTD_freeDCtx`,
  `ZSTD_DCtx_setParameter` and `ZSTD_decompressStream`. Each is checked
  with `check_symbol` before it is loaded, so a library that is not
  libzstd is an error naming the symbol. The floor is 1.4.0, where the
  parameter API and `ZSTD_compressStream2` became stable.
- **Buffers.** `ZSTD_inBuffer` (`src`, `size`, `pos`) and
  `ZSTD_outBuffer` (`dst`, `size`, `pos`) are three machine words each.
  The compressor allocates one block for both and passes their addresses.
  The input and output lists are owning values handed to C as addresses,
  so each is used after the call (CLAUDE.md's keep-alive rule).
- **`ZstdCompressor`**, not `Copyable`, since it owns a `ZSTD_CCtx`:
  `ZstdCompressor(level=1, window_log=15)`; `push(bytes, end=False) ->
  List[UInt8]`, which runs `ZSTD_compressStream2` with `ZSTD_e_flush`, or
  `ZSTD_e_end` to close the frame; and `memory()`, `ZSTD_sizeof_CCtx`.
  `push` calls until the return is 0 and the input is consumed, growing
  the output between calls. zstd.h's rule: a nonzero return is bytes
  still to flush, and only 0 means the flush is complete. hyperlith's
  overflow, from a fixed output buffer, is the warning. A flushed block
  is decodable as it lands, which is what lets the client see each event
  at once.
- **`ZstdDecompressor`**, for the tests: `push(bytes) -> List[UInt8]`,
  decoding everything the bytes complete, and an optional window limit
  (`ZSTD_d_windowLogMax`), so a test can prove the encoder kept to the
  window it was given.
- **Why those defaults.** Level 1 is 3.1 ms per MB on blobs against
  level 3's 3.9 ms, and at the same window a third of its memory (317 KB
  against 1,023 KB at window log 19). Window log 15 (32 KB)
  covers the seat's repeats, which come round within 16 KB, at 201 KB a
  stream; a wider window waits for a measured stream that wants it.
  At 1,024 connections all compressing, that comes to about 200 MB,
  which is why the option is per response and the numbers are in the
  docstring.

### 3. The loop: a compressor per streaming slot

- **Marking.** In `loop/response.mojo`, the branch that sets
  `st.slot_sse[slot] = True` for a `sse_streaming` response also marks the
  slot when the response's field asks. The branch comes after the HEAD
  check, so a HEAD opens no context. The head goes out plain; the body
  (the `: open` comment or the first frame) goes through the context. A
  marked response's `body_raw` is replaced by the context's output before
  `encode_into` writes head and body together. So the context starts at
  the first body byte on the wire, never at the first drain.
- **The drain.** In `_drain_outboxes` (`loop/streams.mojo`), where
  `out = Bytes(Span(pending))` is built, a marked slot builds
  `out = compressors[s].push(pending)` instead. The chunked branch
  (`framed`, an ASGI stream) wraps the compressed bytes. It is not this
  brief's target, but it must not break: compress first, frame second.
- **The heartbeat and the farewell.** `_heartbeat` pushes `: heartbeat`
  through the slot's context before `_send_frame`. `_farewell_streams`
  pushes `: close` with `end=True`, so a graceful close ends a complete
  zstd frame.
- **Order.** Compressed bytes must reach the wire in the order the context
  produced them, and nothing may be compressed twice. The loop already
  guarantees both if a frame is compressed at the moment it is handed to
  the socket:
  - the drain takes a slot only while it is idle (`STREAMING_SSE`);
  - the heartbeat and the farewell take one only through
    `_takes_an_out_of_band_frame`, which refuses a half-sent frame;
  - a partial write waits in `slot_response` for the write-ready path.

  #630's latest-wins catch-up works on the handler's outbox inside
  `sse_drain_slot`, before the drain compresses.
- `offload.ack_payload`, the producer's credit window, keeps counting
  the PAYLOAD bytes (`payload_len`), as the comment there insists;
  compression changes the wire bytes only.
- **Teardown has one owner** (review record C4). The context is freed in
  `_close_slot` and `_chunked_stream_ends` (`loop/state.mojo`), the two
  places that clear `slot_sse`, never beside a call site. A slot reused
  for a new stream gets a fresh context from the marking.
  `test_slot_lifecycle.mojo` gains both transitions.
- **The library opens on the first slot that asks**, under `M0_THREADS`
  shared by the loops. A loop that never compresses never opens it, so a
  box without libzstd runs every non-compressing app as before. Under
  `M0_WORKERS>1` it opens in a forked worker. libzstd has no platform
  runtime beneath it, and the smoke runs at two workers to make that a
  fact.
- **The cost is per subscriber, on the loop thread.** A broadcast is
  compressed once for each subscriber, since every context has its own
  history. At blobs' rate and 3.1 ms per MB that is about 0.07 ms a
  second a subscriber: 100 subscribers take under 1 % of a loop thread.

### 4. The API: a response that asks

- `sse_response(initial, zstd=False)`: with `True`, the response sets
  the field and carries `Content-Encoding: zstd`, with `Accept-Encoding`
  appended to `Vary` through `reply.vary`. It does not negotiate; the
  caller does. A Bool, not a coding's name: with one coding there is no
  name to get wrong, and the function stays one that cannot raise.
- **The negotiation is one question.** `negotiate_encoding` was removed
  on 2026-09-29 with nothing calling it (D54). A stream needs only to know
  whether the request accepts zstd. So `accepts_zstd(req) -> Bool` sits
  beside `sse_response`, with a table test of its own: `zstd;q=0`
  refuses, `*` counts (RFC 9110 §12.5.3), and the coding is matched
  without regard to case (§8.4.1). Datastar's Go SDK drops the q-values and so serves
  zstd to `zstd;q=0`; the table holds this one to the rule. Bringing
  `negotiate_encoding` back instead reopens D54 for a general negotiator
  with one coding to choose.
- `DatastarStream.open(req, url, compress=False)`: `True` asks
  `accepts_zstd(req)` and passes the result through. The `send_latest`
  newest-frame catch-up and the journal replay queue frames into the
  outbox as they do; they reach the wire through the same drain, so they
  are compressed by the same context.
- The scaffold's `live` template keeps its default. `apps/datastar_counter`
  turns compression on, as the demo the gate drives; its frames are small
  signal patches, so it proves correctness and not the ratio.
  `apps/blobs` keeps compression off; the setting that turns it on for a
  measurement is step 6's.

### 5. The gates

- `packages/m0-http/test/test_zstd.mojo`, the loader row's gate:
  - the library opens; when it is absent the test fails, naming the
    paths tried (every Linux runner has libzstd, and the macOS runner
    must have Homebrew's, so a skip would be green having tested
    nothing);
  - a round trip through `ZstdCompressor` and `ZstdDecompressor`;
  - a flush per push leaves each push decodable as it arrives (the
    decoder fed each push yields exactly that push);
  - a push larger than one round of output still decodes (the loop on a
    nonzero return);
  - a stream several windows long decodes under a decoder held to window
    log 15, which proves the encoder kept to its window;
  - a context's memory stays under a bound, read through
    `ZSTD_sizeof_CCtx`;
  - a library that is not libzstd is an error naming the missing symbol,
    and a list of absent paths is an error naming each.
- The stream row's gate is a new `smoke-stream-zstd` task, its step in
  `test.yml`'s `smoke` job beside `Smoke test the Datastar counter`, on
  `scripts/smoke/lib.sh` (a free port, logs in `$SMOKE_DIR`). A
  raw-socket client sends `Accept-Encoding: zstd`, reads the counter's
  `/events`, and feeds each `recv` to a `zstandard` decompressor. It
  asserts:
  - each `POST /increment` has its event decoded before the next POST
    goes, within a bound of seconds. That proves the flush, where a
    millisecond bar on a shared runner would only invite flakes;
  - with `M0_SSE_HEARTBEAT_MS` short, a `: heartbeat` decodes between two
    events and the stream still decodes whole after it;
  - with no `Accept-Encoding`, and with `zstd;q=0`, the stream comes
    uncompressed;
  - a buffered page from the same app carries no `Content-Encoding`, so J8
    holds;
  - all of it holds at one worker and at two.

  The row cites the step `(every PR)`, and the task declares the row with
  `emit.py --covers`. CI's Python 3.13 has no `compression.zstd`, so
  `zstandard` goes in `[dependency-groups] dev`, or the gate is green
  having tested nothing. It must be 0.25.0 or later: py-canary moves the
  venv onto free-threaded 3.14t from the same lock, and 0.23.0 does not
  build there (`ob_refcnt`, measured), where 0.25.0 imports with its C
  backend on both.
- Moved to step 6: `scripts/mojo_image_probe.py`, with M26's
  no-interpreter check, resolving `libzstd.so.1` in the runtime image
  (`debian:12-slim` ships `libzstd1`, which `dpkg` depends on; the probe
  makes that a fact rather than a belief). It matters once an application
  in the image compresses, which blobs's setting is the first to do, and
  `scripts/mojo_image_sabotage.py` anchors the probe's lines: run it
  after the edit.

### 6. Measure

- `docs/BENCHMARKS.md`: the hello row and the SSE rows, before and after,
  with no stream compressing: they must not move.
- `apps/blobs` on one loop, compressed and not, at 1, 10 and 100
  subscribers: bytes to the client over 60 s, the loop's CPU, and a hello
  request's p50 and p99 on the same loop while the streams run. The last
  is the bar, since the compression cost lands on every connection the
  loop holds. The expected shape is about 3.4:1 and 3 ms of CPU per MB.
  The decision row's blobs figures come from this run.
- The datastar-builder seat, re-measured with its own tools
  (`apps/drones/bench/capture.sh`, then `bench/compress.mjs` on the
  uncompressed capture with zstd added through `node:zlib`, against the
  wire bytes). That repo pins `mojo==1.1.0` and `m0==0.12.0`. It moves to
  1.2.0 and the m0 release carrying this first, and its capture's section
  of `measurements.md` is pushed, so the seat's ratio can be checked.
- Through Fly: m0's own compressed stream, from a deployed app, keeps its
  coding and its events' timing past the proxy, as the Python stream in
  step 0 did.

## Not in this plan

- **gzip as a second coding.** For clients that do not offer zstd: Safari
  before 26.3, and anything older. It waits for those clients to ask.
  The design is this note's first version, through the system zlib.
- **brotli.** 29:1 against deflate's 23:1 on the seat's stream, and on
  blobs 3.8:1 against zstd's 3.4:1, at seven times zstd's CPU. It needs a
  package in the image (`libbrotli1`, which `dpkg` does not pull in) and
  a loader of its own.
- **Compressing buffered responses** (J8): Fly's proxy compresses them
  already, with zstd where the client offers it. Precompressed sidecars
  (J9) and `permessage-deflate` (I14) each follow their own row.
- **A Mojo zstd encoder.** `kszucs/marrow` has one, a port of libzstd
  1.5.7's level 1 that writes the same frames byte for byte, but one-shot:
  a stream needs the match history carried from one event to the next
  and a block at every flush, which is what `ZSTD_compressStream2` does.
  It waits for a deploy target without libzstd, or a streaming encoder
  upstream there.
- **`Cache-Control: no-transform` on every stream.** `sse_response` sends
  `no-cache` alone. `no-transform` tells a conforming proxy not to
  compress the stream (RFC 9110 §7.7), and so not to buffer it to
  compress it. It costs one header, helps every uncompressed stream
  whether or not this brief lands, and wants a row of its own. Whether
  Fly's proxy honours it is unmeasured.
- **Compression levels per app.** Level 1, window log 15, fixed. A knob
  waits for a measured stream that wants another setting.

## What to hand back

- The decision row and the SPEC rows, resolvable under `poe check-docs`.
- Step 6's measurements in `docs/BENCHMARKS.md`: the hello row before and
  after, blobs at three subscriber counts with the hello latency beside
  them, and the seat.
- Step 0's pass-through, re-measured with m0's own stream.
- A note on anything libzstd's ABI made awkward.
