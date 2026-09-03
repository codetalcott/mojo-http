# Specification coverage

[![Tests](https://github.com/codetalcott/mojo-http/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/codetalcott/mojo-http/actions/workflows/test.yml)
[![Docs](https://github.com/codetalcott/mojo-http/actions/workflows/docs.yml/badge.svg?branch=main)](https://github.com/codetalcott/mojo-http/actions/workflows/docs.yml)

What this server implements, and what proves it. One row per capability, and
every row carries its evidence — a named CI gate, a source file, a roadmap
heading, or a reason for the refusal.

The badges are half of what makes a `verified` row mean anything. The claim is
a composition: **CI is green for this commit** AND **every `verified` row names
a gate CI actually runs**. `poe check-docs` enforces the second half and fails
the build if a row names a gate that does not exist or does not run; the badges
are the only visible evidence of the first. Read them together, and read them
knowing a badge reports the newest run on `main` rather than the commit you are
looking at.

<!-- generated: spec-rollup -- edit the tables below, not this block -->
**157 capabilities: 133 verified, 0 implemented, 0 planned, 24 out of scope.** Of the 133 verified, 129 are gated on every pull request, 2 weekly, and 2 before a release. Every pull-request-gated row's coverage is declared IN its gate (`covers:` in the cited test, or a recorder coverage call in what the cited step runs), and the checker requires the declaration and the citation to agree; the weekly and pre-release rows keep declared-static citations, their runs being absent from PR CI.
<!-- /generated: spec-rollup -->

## How to read this page

Each row carries a permanent **id** (`A7`, `K3`). Ids are assigned once, never
renumbered, and never reused — a deleted row's id is retired rather than
recycled, so an id in an old commit, an issue or a conversation still means
what it meant. Refer to a row by its id, not its wording: the wording is meant
to be edited as understanding improves, and it has been.

| status | means |
|---|---|
| `verified` | a named CI gate exercises this, on the cadence the evidence states |
| `implemented` | it is in the tree, and no gate is dedicated to it — this is the work queue, not a claim of correctness |
| `planned` | intended and not built; the evidence names the roadmap heading |
| `out of scope` | a deliberate refusal; the evidence is the reason |

**`verified` means a gate runs, not that the capability is correct.** No
checker can read a test's meaning. `smoke-sendfile`'s RSS ceiling is 16 MB for
three 64 MB passes — generous on purpose so CI is not flaky — and a regression
that buffered 8 MB would pass it. The word is a statement about evidence, not
a warranty.

**Cadence matters and is stated per row.** `(every PR)` is a step in
`.github/workflows/test.yml`. `(weekly)` is `py-canary.yml` or
`nightly-canary.yml` on a cron — the free-threading rows live here, because
CI pins GIL-enabled 3.13 and every `--threads` phase skips on it.
`(pre-release)` is a gate `docs/RELEASING.md` requires and CI deliberately
does not run, because shared runners cannot reproduce the timing.

**One conformance suite runs on a cadence**: Autobahn\|Testsuite, at
pre-release (`poe autobahn`, I13), compared both directions against a
pinned baseline. No h2spec and no PortSwigger desync harness is wired to
any gate (B8 and B9 refuse them, each with its reason). The WebSocket and
smuggling rows below are otherwise pinned by hand-written probes and unit
tests against the RFC text — real evidence that is not a conformance run,
and the rows say which they are. What Autobahn measured when first run by
hand (2026-08-30) is in ROADMAP's conformance-suite tier, including the two
live defects it found and the reason it could not have caught the bug that
motivated running it: its client always closes first, so the app-initiated
close path (L15) is a region no external suite can reach.

This page is checked by `poe check-docs`: a `verified` row whose gate does not
exist or does not run fails the build, as does a CI gate no row accounts for.
See `scripts/spec_sheet.py`.

**How the rows were checked, and what that leaves.** The machine proves a gate
exists and runs; only reading proves it tests the row's claim. Every row has
been read against its gate once, 2026-08-30, and roughly a fifth were wrong —
claims whose cited test asserted something narrower (a predicate rather than
the behaviour it guards), claims covering two things while citing one test,
and four rows citing a gate that did not touch the capability at all. Those are
now split, re-pointed, or demoted to `implemented`.

The two halves of that pass were not equally thorough, and the weaker one is
worth knowing about: every unit-test citation was checked by reading the test
body, while single-claim smoke steps were checked by a relevance probe with
the flagged ones read in full. A smoke step whose name matches its row but
whose body drifted away from it is the case most likely to have survived.

## A. HTTP/1.1 framing and connection lifecycle

| id | capability | status | evidence |
|---|---|---|---|
| A1 | Persistent connections (keep-alive) | verified | `Smoke test pipelined requests` (every PR) |
| A2 | The example Mojo server starts and answers `/health` | verified | `Smoke test the hello server` (every PR) |
| A3 | Keep-alive request cap | verified | `Smoke test the keep-alive request cap` (every PR) — closes on the cap request, and a stream or WebSocket upgrade landing there survives it; the probe's third phase refuses to pass on a build whose cap never fires. No flag or env var exposes the limit |
| A4 | Idle connection timeout, `--idle-timeout` | verified | `Smoke test the idle connection timeout` (every PR) — an answered keep-alive connection left quiet is closed at the deadline and no earlier, and one kept busy across it is not |
| A5 | Header read timeout (slowloris defence) | verified | `Smoke test the header read timeout` (every PR) |
| A6 | Request pipelining, answered in order (RFC 9112 §9.3) | verified | `Smoke test pipelined requests` (every PR) |
| A7 | Chunked request bodies, decoded incrementally across reads | verified | `test_parsing.mojo:test_incremental_decode_matches_a_single_pass` (every PR) |
| A8 | Chunked decode consumes the terminator, leaving nothing buffered | verified | `test_chunked_encode.mojo:test_round_trip_single_chunk` (every PR) |
| A9 | Chunked response bodies | verified | `Smoke test streamed WSGI bodies` (every PR) |
| A10 | Trailer fields consumed and discarded, not surfaced to the application | verified | `test_parsing.mojo:test_a_trailer_section_is_consumed_whole` (every PR) — with seven more beside it: the framing fields a trailer must not honour, the pipelined tail surviving it, the section bounded by the abuse ratio, and `test_without_consume_trailer_the_body_ends_at_the_zero_chunk` as the other half. `poe sabotage-trailers` reverts each of the six rules and requires a failure for every one |
| A11 | `Expect: 100-continue`, honoured case-insensitively and withheld from HTTP/1.0 | verified | `Expect 100-continue, honoured and withheld` (every PR) — both directions: a server answering it unconditionally would pass the invitation half while discarding the refusal-before-upload the mechanism exists for |
| A12 | Half-close answered rather than dropped | verified | `Smoke test a half-closed client` (every PR) |
| A13 | Request headers larger than one socket read | verified | `Smoke test a request larger than one read` (every PR) |
| A14 | `Host` required on HTTP/1.1 | verified | `test_parsing.mojo:test_http11_requires_a_non_empty_host` (every PR) |
| A15 | absolute-form request target reduced to its path | verified | `test_parsing.mojo:test_absolute_form_target_is_reduced_to_its_path` (every PR) |
| A16 | Malformed field lines rejected, not treated as incomplete | verified | `test_parsing.mojo:test_a_field_line_without_a_colon_is_invalid_not_incomplete` (every PR) |
| A17 | Control bytes in the request target rejected | verified | `test_parsing.mojo:test_a_control_byte_in_the_request_target_is_invalid` (every PR) |
| A18 | HTTP/2 | out of scope | terminate at a proxy — gunicorn's answer, and the same one applies here |
| A19 | HTTP/3 and QUIC | out of scope | follows HTTP/2; there is no TLS layer to build it on |

## B. Request smuggling (CWE-444)

| id | capability | status | evidence |
|---|---|---|---|
| B1 | `Content-Length` with `Transfer-Encoding` rejected | verified | `test_parsing.mojo:test_content_length_with_transfer_encoding_is_rejected` (every PR) |
| B2 | Duplicate `Content-Length` rejected, including across letter case | verified | `test_parsing.mojo:test_duplicate_content_length_is_rejected_across_letter_case` (every PR) |
| B3 | `Transfer-Encoding` whose last coding is not `chunked` rejected | verified | `test_parsing.mojo:test_transfer_encoding_whose_last_coding_is_not_chunked_is_rejected` (every PR) |
| B4 | Header padding does not bypass the smuggling check | verified | `test_parsing.mojo:test_padded_headers_do_not_bypass_the_smuggling_check` (every PR) |
| B5 | Bare LF in a chunk extension rejected | verified | `test_parsing.mojo:test_bare_lf_in_a_chunk_extension_is_rejected` (every PR) |
| B6 | `Content-Length` integer overflow rejected | verified | `test_parsing.mojo:test_overflowing_content_length_is_rejected` (every PR) |
| B7 | Chunk size with the sign bit set rejected | verified | `test_parsing.mojo:test_chunk_size_with_the_sign_bit_set_is_rejected` (every PR) |
| B8 | h2spec conformance run | out of scope | follows from having no HTTP/2 (A18), the same reason C7 gives |
| B9 | PortSwigger-style desync scanning | out of scope | the scanner probes a proxy/server PAIR for disagreement about framing; this server has no proxy in front of it in any gate, so there is no second parser to disagree with. The shapes it looks for are unit-tested directly above (B1-B7), and fuzzing the decoder itself is G13 |

## C. Connection management and denial of service

| id | capability | status | evidence |
|---|---|---|---|
| C1 | Max request body size, configurable | verified | `Smoke test the serve CLI` (every PR) — `--max-body` |
| C2 | Chunk size limited to 16 significant digits | verified | `test_parsing.mojo:test_chunk_size_is_limited_to_sixteen_significant_digits` (every PR) |
| C3 | Raw chunked bytes bounded independently of decoded size | verified | `Smoke test the serve CLI` (every PR) — a decoded-legal body costing 2x the cap in framing answers 413 |
| C4 | Max header count | verified | `test_parsing.mojo:test_header_count_is_capped` (every PR) |
| C5 | A slow handler does not stall connections behind it | verified | `Smoke test the blocking-threads pool` (every PR) |
| C6 | Connection/request rate limiting | out of scope | a proxy's job; this server has no notion of a client identity to limit on |
| C7 | HTTP/2 reset-flood limits | out of scope | follows from having no HTTP/2 |

## D. Graceful shutdown and restart

| id | capability | status | evidence |
|---|---|---|---|
| D1 | SIGTERM drains in-flight requests | verified | `Smoke test graceful shutdown` (every PR) |
| D2 | SIGTERM to the supervisor alone reaps workers | verified | `Smoke test graceful shutdown` (every PR) |
| D3 | Bounded drain, naming what it abandoned | verified | `Smoke test streamed WSGI bodies` (every PR) |
| D4 | SIGTERM reaches a shutdown pipe rather than killing the process | verified | `test_lifecycle.mojo:test_sigterm_reaches_the_shutdown_pipe` (every PR) |
| D5 | Development hot reload on file change | verified | `Smoke test hot reload` (every PR) — `--reload`, `--reload-dir` |
| D9 | A request whose body is still arriving at SIGTERM is read on and answered, not left to the deadline | verified | `Smoke test the drain with an upload in flight` (every PR) — `scripts/drain_upload_probe.py`, two-sided: answered whole AND exited inside 3 s, on the ASGI executor and on a WSGI pool thread |
| D6 | `SO_REUSEPORT` off by default: a second bind fails loudly instead of silently sharing the port | verified | `Smoke test the serve CLI` (every PR) — five attempts a second apart, so a restart racing the previous process's drain still succeeds; the second server must exit 1 naming the address, print no ready banner, and leave the first answering. The opt-in `ListenConfig.reuse_port` remains for a deliberate handoff between two processes that both mean to listen; no shipped path enables it, because workers and threads all accept from ONE listener bound before the fork |
| D7 | Binary/hot upgrade (USR2-style overlap) | out of scope | needs socket handoff this server does not have; run two behind a proxy |
| D8 | SIGHUP reload | out of scope | `--reload` covers development; production reload is a new process behind a proxy |

## E. Process and worker model

| id | capability | status | evidence |
|---|---|---|---|
| E1 | Multi-process prefork with a supervising parent | verified | `Smoke test the Django WSGI example` (every PR) |
| E2 | Crashed workers respawned | verified | `test_respawn.mojo:test_respawned_worker_returns_to_the_callers_startup_path` (every PR) |
| E3 | A spent respawn budget exits nonzero rather than looping | verified | `test_respawn.mojo:test_supervisor_exits_nonzero_when_respawn_budget_is_spent` (every PR) |
| E4 | Handler thread pool behind each event loop | verified | `Smoke test the Mojo handler pool` (every PR) |
| E5 | Free-threaded CPython, N loops on N threads | verified | `py-canary` (weekly) |
| E6 | A GIL-enabled interpreter is refused, never warned-and-run | verified | `Smoke test the threaded mode's guard` (every PR) |
| E7 | Zero-config topology defaults | verified | `Smoke test --doctor against the server's own exit codes` (every PR) |
| E8 | Max-requests worker recycling with jitter | out of scope | the leak it mitigates is measured instead — `smoke-django` fails on RSS growth over 10k requests |
| E10 | A worker's configuration refusal (exit 78) ends supervision with 78, never a respawn loop | verified | `test_respawn.mojo:test_a_worker_refusing_its_configuration_is_not_respawned` (every PR) |
| E9 | Worker lifetime / max-RSS recycling | out of scope | same reason as above |

## F. Observability

| id | capability | status | evidence |
|---|---|---|---|
| F1 | Access log records cannot be forged by a value (newline, quote, backslash escaped) | verified | `test_log.mojo:test_a_newline_cannot_forge_a_second_log_line` (every PR) |
| F2 | `--access-log` emits one JSON record per response, and nothing without it | verified | `Smoke test the serve CLI` (every PR) — `--access-log` |
| F3 | `--metrics` turns `/__metrics` from the application's 404 into a 200 | verified | `Smoke test the serve CLI` (every PR) — `--metrics` |
| F4 | Prometheus exposition 0.0.4: 8 counter and gauge families, each with HELP, TYPE and a sample | verified | `Smoke test the serve CLI` (every PR) — `--metrics` |
| F5 | Latency histograms on `/__metrics` | verified | `Smoke test the serve CLI` (every PR) — six log-spaced `le` bounds (100µs–1s, +Inf), integer-only and O(1) on the loop thread; `scripts/histogram_check.py` (selftested in the same phase) asserts the documented bounds, non-decreasing cumulative counts, `le="+Inf"` equal to `_count`, and a `_count` covering the phase's own requests; boundary math pinned by `test_metrics.mojo` |
| F12 | Coverage declared by the gate rather than cited by this page | verified | `Check machine-sourced doc facts` (every PR) — every pull-request-gated row declares its coverage in the gate itself (a `covers:` docstring line in the cited test, or a recorder coverage call in what the cited step runs), and the checker requires the declaration to agree with the citation, which is what makes the audit's mis-citation class structurally impossible. Weekly and pre-release rows keep declared-static citations, their runs being absent from PR CI. Four sabotages in `poe sabotage-spec` revert the rules |
| F6 | `--health-path` answers 200 | verified | `Smoke test the Django realtime example` (every PR) — `--health-path` |
| F7 | Health registry with readiness aggregation | verified | `test_health.mojo:test_health_register_unhealthy` (every PR) |
| F8 | Configuration report that exits as the server would | verified | `Smoke test --doctor against the server's own exit codes` (every PR) — `--doctor` |
| F9 | OpenTelemetry tracing | out of scope | no tracing context crosses the Mojo/Python seam today; a wrapper in the application is the supported route |
| F10 | CI measurements recorded, rendered per run and kept as an artifact | verified | `Check machine-sourced doc facts` (every PR) |
| F11 | The measurement recorder itself | verified | `Self-test the measurement recorder` (every PR) |
| F14 | The site's deploy image: the wheel in `python:3.12-slim` with the built site, served from a container as it deploys | verified | `Smoke test the documentation site's deploy image` (every PR) — `deploy/site/Dockerfile` built from the tree's own wheel; through a published port, `llms.txt` and the sitemap answer at the root, a page answers with the Markdown twin it advertises, the slash redirect and the HTML 404 come from the application, m0serve is PID 1 by `/proc/1/cmdline`, and `docker stop` is the drain's exit 0 inside its grace |
| F13 | The documentation site: the tree's own pages rendered and served by the server, `llms.txt` at the root, a Markdown twin beside every page | verified | `Smoke test the documentation site` (every PR) — built by `scripts/docsite.py`, served through `--static` with `apps/site` behind it; every sitemap URL answers as HTML with the twin it advertises, the root text files name the site's pages by absolute URL, the sitemap goes out as XML, and the slash redirect and HTML 404 come from the application |

## G. Security hardening

| id | capability | status | evidence |
|---|---|---|---|
| G1 | An injected status reason phrase is emptied, not transmitted | verified | `test_response.mojo:test_status_reason_with_crlf_is_emptied_not_transmitted` (every PR) |
| G2 | A response header carrying CR, LF or NUL is dropped, and a clean one beside it is not | verified | `Conformance test the WSGI bridge` (every PR) |
| G3 | An application's `Set-Cookie` reaches the wire verbatim | verified | `test_response_cookies.mojo:test_raw_line_reaches_the_wire_verbatim` (every PR) |
| G4 | `Proxy` request header never becomes `HTTP_PROXY` (httpoxy) | verified | `test_environ.mojo:test_proxy_header_is_excluded_from_the_environ` (every PR) |
| G5 | Path traversal rejected (`../`) | verified | `test_static.mojo:test_dotdot_is_rejected` (every PR) |
| G6 | Percent-encoded traversal rejected (`%2e%2e`) | verified | `test_static.mojo:test_encoded_dotdot_is_rejected` (every PR) |
| G7 | Reserved `\x01` channel namespace refused by `publish_to_channels` | verified | `test_broadcast.mojo:test_publish_rejects_reserved_channel` (every PR) |
| G8 | ...and by `BroadcastBus.publish` | verified | `test_broadcast.mojo:test_bus_publish_method_rejects_reserved_channel` (every PR) |
| G9 | API key authentication, length-checked so a repeated key fails | verified | `test_auth.mojo:test_a_rotation_of_the_key_is_rejected` (every PR) |
| G10 | CORS, configurable | verified | `Smoke test the notes API` (every PR) |
| G11 | `X-Forwarded-*` / `Forwarded` parsing with a trusted-proxy allowlist | out of scope | the server never consults them — `REMOTE_ADDR` is the socket peer and `wsgi.url_scheme` is configuration, so there is nothing to spoof |
| G12 | PROXY protocol v1/v2 | out of scope | same reason: the peer address is taken from the socket |
| G13 | Parser fuzzing in CI | verified | `Fuzz the request decoder` (every PR) — 20k mutations of a seed corpus against `parse_request_headers` and the chunked decoder, replayable from the seed it prints; asserts determinism, that an INVALID request cannot become valid by appending, that a parsed one is unchanged by bytes after it, and that the decoder's counts index its buffer. `poe fuzz-request-long` is the release sweep (8 seeds x 250k). The run refuses to pass on thin coverage, and `Sabotage the decoder invariants the fuzzer checks` breaks each invariant so "no findings" cannot mean "checks nothing" |

## H. TLS

| id | capability | status | evidence |
|---|---|---|---|
| H1 | TLS 1.2 / 1.3 termination | out of scope | terminate at a proxy — gunicorn's answer, and the same one applies here |
| H2 | ALPN, SNI, mTLS, OCSP stapling, certificate hot-reload | out of scope | all follow from not terminating TLS |

## I. WebSocket and Server-Sent Events

| id | capability | status | evidence |
|---|---|---|---|
| I1 | WebSocket handshake (RFC 6455), `Sec-WebSocket-Accept` | verified | `Smoke test the WebSocket echo demo` (every PR) |
| I2 | Fragmented messages reassembled | verified | `test_websocket.mojo:test_fragmented_message_assembles` (every PR) |
| I3 | Ping/pong, and a server heartbeat on a cadence | verified | `Smoke test the WebSocket echo demo` (every PR) |
| I4 | Close frame echoed with its code, connection marked for close | verified | `test_websocket.mojo:test_close_is_echoed_with_code_then_closes` (every PR) |
| I5 | Invalid UTF-8 in a text frame closes 1007 | verified | `test_websocket.mojo:test_invalid_utf8_text_closes_1007` (every PR) |
| I6 | A fragmented control frame is a protocol error | verified | `test_websocket.mojo:test_fragmented_control_frame_is_protocol_error` (every PR) |
| I7 | Wrong `Sec-WebSocket-Version` answers 426 advertising 13 | verified | `test_websocket.mojo:test_wrong_version_is_426_advertising_13` (every PR) |
| I8 | Cross-worker WebSocket fan-out over the broadcast bus | verified | `Smoke test the WebSocket chat demo` (every PR) |
| I9 | Server-Sent Events, with heartbeats and disconnect cleanup | verified | `Smoke test the Datastar counter` (every PR) |
| I10 | `Last-Event-ID` replay from a bounded journal | verified | `Smoke test the Datastar todo demo` (every PR) |
| I11 | A synchronous view gating a held SSE connection, with cross-worker publish | verified | `Smoke test the Django realtime example` (every PR) — `--realtime` |
| I12 | A synchronous view gating a held WebSocket it never speaks | verified | `Smoke test the Django realtime example over WebSockets` (every PR) |
| I18 | N holds taken AT ONCE from a pool, and a publish reaching all of them | verified | `Concurrent --realtime holds from a pool` (every PR) — the other realtime rows subscribe sequentially, so this is the only one where more than one hold is in flight; the probe's own self-test gates it, because the result it reports is a negative |
| I19 | Inbound WebSocket data larger than one socket read | verified | `Inbound WebSocket messages survive a stalled client` (every PR) — the WebSocket read path took one `recv` per event with no re-arm, A13's defect in the one path nothing had sent a large inbound burst to; invisible on kqueue's level trigger, and on epoll only once the client STOPS sending |
| I13 | Autobahn\|Testsuite conformance run, wired to a cadence | verified | `autobahn` (pre-release) — sections driven separately against the runner's pure-echo ASGI app, image version-pinned so the per-section case counts are asserted exactly; compared both directions against the pinned baseline (240/247, every failure I17's cap): a new failure is red, and an I17 case unexpectedly passing is red too. The comparator's selftest runs first. What the suite cannot see stays L15's territory — its client always closes first (ROADMAP: A conformance-suite tier) |
| I14 | `permessage-deflate` | out of scope | follows from having no response compression |
| I15 | WebSocket over HTTP/2 (RFC 8441) | out of scope | follows from having no HTTP/2 |
| I16 | A Close frame's code is VALIDATED, not just echoed | verified | `test_websocket.mojo:test_reserved_close_codes_are_refused_1002` (every PR) — with `test_legal_close_codes_are_still_echoed` as the other half, so a refusal that refuses everything cannot pass |
| I17 | A message at or above the outbox cap ends the connection | verified | `Smoke test the outbox cap ending a connection` (every PR) — the marker sent after the oversized message must never arrive, which is what separates ending the connection from dropping a frame the peer cannot know it missed; the under-cap half stops a server that ended every large-message connection from passing. Deliberate, and what Autobahn scores as 7 failures plus all of its performance section. `poe sabotage-outbox-cap` (pre-release) reverts each of the four rules |
| I20 | A synchronous Flask view gating a held SSE stream and a WebSocket, with cross-worker publish | verified | `Smoke test the Flask realtime views` (every PR) — the headline names Flask, and K10 only proves plain WSGI. The file under test is extracted from QUICKSTART.md's own fenced block, so it is the one a reader types; the Django rows' RFC 6455 probe drives it unchanged (its gate phase off: the quickstart's views take no token), one stream and one socket pinned per worker under `--workers 2`, so a message sent on one worker's socket reaches a Flask view and comes back on the other worker's. The quickstart runs the same file from the wheel with curl alone (M10) |

## J. Static file serving

| id | capability | status | evidence |
|---|---|---|---|
| J1 | Zero-copy `sendfile`, body never entering the process | verified | `Smoke test zero-copy static file serving` (every PR) — `--static` |
| J2 | Byte range served as 206 with `Content-Range` | verified | `test_static.mojo:test_range_serves_206_with_content_range` (every PR) |
| J3 | Unsatisfiable range answered 416 carrying the total | verified | `test_static.mojo:test_range_unsatisfiable_is_416_with_total` (every PR) |
| J4 | `If-None-Match` takes precedence over a range | verified | `test_static.mojo:test_if_none_match_beats_range` (every PR) |
| J5 | `If-Range` with a weak ETag serves the full body | verified | `test_static.mojo:test_if_range_with_weak_etags_serves_full` (every PR) |
| J6 | ETag and conditional 304 | verified | `Smoke test the notes API` (every PR) |
| J7 | `Cache-Control`, configurable | verified | `Smoke test the serve CLI` (every PR) — `--static-cache-control` |
| J8 | Response compression (gzip, brotli, zstd) | out of scope | recorded in ROADMAP as deliberate: no dynamic compression; a proxy compresses |
| J9 | Precompressed sidecar files (`.br`, `.gz`) | out of scope | follows from the row above |

## K. WSGI (PEP 3333)

| id | capability | status | evidence |
|---|---|---|---|
| K1 | `application(environ, start_response)` against a bare callable | verified | `Conformance test the WSGI bridge` (every PR) |
| K2 | `wsgiref.validate` pass, with an engagement canary | verified | `Conformance test the WSGI bridge` (every PR) |
| K3 | The `write()` callable reaches the client, in production order | verified | `Conformance test the WSGI bridge` (every PR) |
| K4 | A second `start_response`, with and without `exc_info` | verified | `Conformance test the WSGI bridge` (every PR) |
| K5 | `wsgi.input` read, readline, iteration, and read past EOF | verified | `Conformance test the WSGI bridge` (every PR) |
| K6 | `QUERY_STRING` raw while `PATH_INFO` is decoded | verified | `Conformance test the WSGI bridge` (every PR) |
| K7 | `close()` called on the response iterable | verified | `Conformance test the WSGI bridge` (every PR) |
| K8 | Correct `wsgi.multithread` / `wsgi.multiprocess` for the real topology | verified | `Smoke test the Django WSGI example` (every PR) |
| K9 | Unsized iterables streamed from a pool thread, sized bodies buffered | verified | `Smoke test streamed WSGI bodies` (every PR) |
| K10 | Framework-neutral: one contract, two frameworks | verified | `Run the WSGI framework contract against Flask` (every PR) |
| K11 | The hold headers degrade under another WSGI server: the same view answers a short plain response | verified | `Execute the quickstart` (every PR) — the quickstart's Django file under gunicorn: `/events` answers 200 with the view's body and closes inside curl's deadline (held, it would not), the upgrade request answers 200 rather than 101, and `publish()` reports 0 workers without raising. The README's "degrades, not breaks" sentence, executed |

## L. ASGI 3.0

| id | capability | status | evidence |
|---|---|---|---|
| L1 | Single `app(scope, receive, send)`, protocol detected from the object | verified | `Conformance test the ASGI bridge` (every PR) — `--protocol` |
| L2 | `http` scope shape, validated against the spec | verified | `Conformance test the ASGI bridge` (every PR) |
| L3 | `websocket` scope: connect, accept, receive, send, close | verified | `Conformance test the ASGI bridge` (every PR) |
| L4 | `lifespan` startup and shutdown, degrading if unsupported | verified | `Conformance test the ASGI bridge` (every PR) |
| L5 | `lifespan.state` shallow-copied into each request scope | verified | `Conformance test the ASGI bridge` (every PR) |
| L6 | Streaming responses stream, credit-gated per stream and in total | verified | `Conformance test the ASGI bridge` (every PR) |
| L7 | Slot ownership across recycled connections, sabotage-proven | verified | `Run unit tests` (every PR) — `poe test-shim` drives the extracted shim through real socketpairs and reverts each rule |
| L8 | The event loop running inside asyncio (`M0_INVERTED`) | verified | `Smoke test the ASGI executor under the loop inversion` (every PR) |
| L9 | Slot ownership under CPU contention, on the streamed AND WebSocket paths, in both loop modes | verified | `stress-asgi` (pre-release) — each round runs `chunked_keepalive.py` then `ws_probe.py`, so the handshake lands on the slot the streamed connection just released; run under CPU hogs on the pump and again under `M0_INVERTED=1` |
| L10 | Django's own ASGI handler through the executor | verified | `Serve a Django ASGI project through the executor` (every PR) |
| L11 | Starlette-family app (FastHTML) through the executor | verified | `Serve a FastHTML app through the ASGI bridge` (every PR) |
| L12 | Cross-worker pub/sub as `scope["state"]["m0"]` | verified | `ASGI cross-worker fan-out over the BroadcastBus` (every PR) |
| L13 | `http.response.pathsend` | out of scope | `--static` serves files in Mojo ahead of the application, which is the same saving without the extension |
| L14 | `http.response.zerocopysend`, `early_hint`, `trailers` | out of scope | no application has asked; the extensions are additive and can be taken later |
| L15 | An app-initiated close ends in a FIN, not an RST (RFC 6455 §5.5.1's order) | verified | `Conformance test the ASGI bridge` (every PR) — `ws_probe.py` runs 64 concurrent app-initiated closes and requires every one to end in a clean FIN; concurrency is what widens the window, so one close at a time would pass on the broken server |
| L16 | ...and the wait for the peer's reply is BOUNDED, so a peer that never answers does not hold its slot | verified | `Smoke test the idle connection timeout` (every PR) — the linger used to re-arm on every loop pass, which held the slot for the life of the process; L15 alone passes on that server |
| L18 | ASGI on a free-threaded CPython build is refused with exit 78, naming modular/modular#5726 | verified | `py-canary` (weekly) — `smoke-django-realtime` phase 6 on 3.14t: the executor's Python type cannot be built there (the stdlib lays `PyObject` out for the GIL build), so the mixed server exits 78 alone, through `--doctor`, and under `--workers 2` without a respawn; on the pinned GIL interpreter the same phase runs the full mixed server |
| L17 | Inbound `websocket.receive` is flow-controlled: a stalled client is throttled, never silently dropped | verified | `Inbound WebSocket messages survive a stalled client` (every PR) — the loop suspends the read rather than discarding what the executor cannot take; a concurrently-reading client loses nothing even on the broken build, so the gate stalls first and only then reads |

## M. Deployment and operations

| id | capability | status | evidence |
|---|---|---|---|
| M1 | Several applications in one process, routed by prefix | verified | `Serve two mounted applications from one process` (every PR) — `--mount` |
| M2 | Flags over environment over defaults | verified | `Smoke test the serve CLI` (every PR) — `--host`, `--port`, `--workers`, `--threads`, `--blocking-threads` |
| M3 | Application discovery from a bare module name | verified | `Conformance test the ASGI bridge` (every PR) |
| M4 | `--app-dir` prepended to `sys.path`, shadowing an installed package | verified | `Smoke test the serve CLI` (every PR) — `--app-dir` |
| M5 | Usage errors exit 2, startup errors exit 1, refusals exit 78 | verified | `Smoke test --doctor against the server's own exit codes` (every PR) |
| M6 | `--help` names every documented flag; `--version` matches the release | verified | `Smoke test the serve CLI` (every PR) — `--help`, `--version` |
| M7 | Installable wheel with no toolchain and no dependencies | verified | `Build and smoke test the installable wheel` (every PR) |
| M8 | The aarch64 wheel built and served on arm64 hardware | verified | `Build and smoke test the aarch64 wheel` (every PR) |
| M9 | C-ABI shared library loadable by `dlopen`/`ctypes` | verified | `Smoke test the C-ABI shared library` (every PR) |
| M10 | The documented quickstart is executed, not asserted | verified | `Execute the quickstart` (every PR) |
| M11 | Correct signal handling as PID 1 in a container | verified | `Smoke test SIGTERM delivered to PID 1 in a container` (every PR) — the wheel exec'd as PID 1 in `python:3.12-slim` (checked via `/proc/1/cmdline`, not trusted); `docker stop` must be the drain's exit 0 well inside the grace, never SIGKILL at the deadline, alone and as a supervisor reaping two workers whose exits must be clean rather than by the propagated signal |
| M12 | Configuration from a TOML file | out of scope | flags and `M0_*` environment variables cover it; a third source is a third precedence rule |
| M13 | systemd socket activation (`LISTEN_FDS`) | out of scope | no request for it. The old reason said `SO_REUSEPORT` covered the restart case, which is not true for anyone running `m0serve`: no flag or variable enables it (D6). What a restart here does get is the supervisor's graceful drain, so in-flight work finishes; a listener that outlives the process is a different property and nothing has asked for it |
| M14 | An HTTP client in Mojo, for server-to-server calls | verified | `Smoke test the HTTP client` (every PR) |
| M15 | Windows, musl | out of scope | no Mojo toolchain for either — see the platform table in README.md |
| M16 | No second process: the running server is one process tree of m0serve binaries, and the wheel requires nothing | verified | `Execute the quickstart` (every PR) — under `--workers 2`, `pgrep -x m0serve` counts exactly a supervisor and two workers (the console script `execve`s, so no Python parent survives), and `pip show m0serve` lists an empty `Requires:`. The exact count is the self-test: a check that only looks for a broker it does not expect passes on an empty machine |
