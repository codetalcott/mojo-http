# Specification coverage

What this server implements, and what proves it. One row per capability, and
every row carries its evidence — a named CI gate, a source file, a roadmap
heading, or a reason for the refusal.

<!-- generated: spec-rollup -- edit the tables below, not this block -->
**126 capabilities: 96 verified, 3 implemented, 5 planned, 22 out of scope.** Of the 96 verified, 94 are gated on every pull request, 1 weekly, and 1 before a release.
<!-- /generated: spec-rollup -->

## How to read this page

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

**No conformance suite runs anywhere** — no h2spec, no Autobahn, no
PortSwigger desync harness. The WebSocket and smuggling rows below are pinned
by hand-written probes and unit tests against the RFC text. That is real
evidence and it is not a conformance run; the rows say which they are.

This page is checked by `poe check-docs`: a `verified` row whose gate does not
exist or does not run fails the build, as does a CI gate no row accounts for.
See `scripts/spec_sheet.py`.

## A. HTTP/1.1 framing and connection lifecycle

| capability | status | evidence |
|---|---|---|
| Persistent connections (keep-alive) | verified | `Smoke test pipelined requests` (every PR) |
| Keep-alive request cap | implemented | `packages/m0-http/lightbug_http/event_loop.mojo:2707` — no flag or env var exposes it |
| Idle connection timeout | verified | `Smoke test graceful shutdown` (every PR) |
| Header read timeout (slowloris defence) | verified | `Smoke test the header read timeout` (every PR) |
| Request pipelining, answered in order (RFC 9112 §9.3) | verified | `Smoke test pipelined requests` (every PR) |
| Chunked request bodies, decoded incrementally | verified | `test_parsing.mojo:test_chunked_body_decodes` (every PR) |
| Chunked terminator consumed, so no RST on close | verified | `test_chunked_encode.mojo:test_terminator_is_zero_chunk_and_bare_crlf` (every PR) |
| Chunked response bodies | verified | `Smoke test streamed WSGI bodies` (every PR) |
| Trailers consumed per RFC 9112, not surfaced to the application | verified | `test_chunked_encode.mojo:test_round_trip_single_chunk` (every PR) |
| `Expect: 100-continue` | implemented | `packages/m0-http/lightbug_http/server.mojo:650` and `event_loop.mojo:1800` — no test or smoke exercises it |
| Half-close answered rather than dropped | verified | `Smoke test a half-closed client` (every PR) |
| Request headers larger than one socket read | verified | `Smoke test a request larger than one read` (every PR) |
| `Host` required on HTTP/1.1 | verified | `test_parsing.mojo:test_http11_requires_a_non_empty_host` (every PR) |
| absolute-form request target reduced to its path | verified | `test_parsing.mojo:test_absolute_form_target_is_reduced_to_its_path` (every PR) |
| Malformed field lines rejected, not treated as incomplete | verified | `test_parsing.mojo:test_a_field_line_without_a_colon_is_invalid_not_incomplete` (every PR) |
| Control bytes in the request target rejected | verified | `test_parsing.mojo:test_a_control_byte_in_the_request_target_is_invalid` (every PR) |
| HTTP/2 | out of scope | terminate at a proxy — gunicorn's answer, and the same one applies here |
| HTTP/3 and QUIC | out of scope | follows HTTP/2; there is no TLS layer to build it on |

## B. Request smuggling (CWE-444)

| capability | status | evidence |
|---|---|---|
| `Content-Length` with `Transfer-Encoding` rejected | verified | `test_parsing.mojo:test_content_length_with_transfer_encoding_is_rejected` (every PR) |
| Duplicate `Content-Length` rejected, including across letter case | verified | `test_parsing.mojo:test_duplicate_content_length_is_rejected_across_letter_case` (every PR) |
| `Transfer-Encoding` whose last coding is not `chunked` rejected | verified | `test_parsing.mojo:test_transfer_encoding_whose_last_coding_is_not_chunked_is_rejected` (every PR) |
| Header padding does not bypass the smuggling check | verified | `test_parsing.mojo:test_padded_headers_do_not_bypass_the_smuggling_check` (every PR) |
| Bare LF rejected in chunk framing | verified | `test_parsing.mojo:test_bare_lf_in_a_chunk_extension_is_rejected` (every PR) |
| `Content-Length` integer overflow rejected | verified | `test_parsing.mojo:test_overflowing_content_length_is_rejected` (every PR) |
| Chunk size overflow and sign-bit rejected | verified | `test_parsing.mojo:test_chunk_size_with_the_sign_bit_set_is_rejected` (every PR) |
| External desync suite (PortSwigger, h2spec) | planned | ROADMAP: A conformance-suite tier |

## C. Connection management and denial of service

| capability | status | evidence |
|---|---|---|
| Max request body size, configurable | verified | `Smoke test the serve CLI` (every PR) — `--max-body` |
| Raw chunked bytes bounded independently of decoded size | verified | `test_parsing.mojo:test_chunk_size_is_limited_to_sixteen_significant_digits` (every PR) |
| Max header count | verified | `test_parsing.mojo:test_header_count_is_capped` (every PR) |
| A slow handler does not stall connections behind it | verified | `Smoke test the blocking-threads pool` (every PR) |
| Connection/request rate limiting | out of scope | a proxy's job; this server has no notion of a client identity to limit on |
| HTTP/2 reset-flood limits | out of scope | follows from having no HTTP/2 |

## D. Graceful shutdown and restart

| capability | status | evidence |
|---|---|---|
| SIGTERM drains in-flight requests | verified | `Smoke test graceful shutdown` (every PR) |
| SIGTERM to the supervisor alone reaps workers | verified | `Smoke test graceful shutdown` (every PR) |
| Bounded drain, naming what it abandoned | verified | `Smoke test streamed WSGI bodies` (every PR) |
| Signal handlers armed after the fork, not before | verified | `test_lifecycle.mojo:test_sigterm_reaches_the_shutdown_pipe` (every PR) |
| Development hot reload on file change | verified | `Smoke test hot reload` (every PR) — `--reload`, `--reload-dir` |
| `SO_REUSEPORT` on the listener | implemented | `packages/m0-http/lightbug_http/socket.mojo` — opt-in, no smoke covers the zero-downtime handover it would enable |
| Binary/hot upgrade (USR2-style overlap) | out of scope | needs socket handoff this server does not have; run two behind a proxy |
| SIGHUP reload | out of scope | `--reload` covers development; production reload is a new process behind a proxy |

## E. Process and worker model

| capability | status | evidence |
|---|---|---|
| Multi-process prefork with a supervising parent | verified | `Smoke test the Django WSGI example` (every PR) |
| Crashed workers respawned, with a budget | verified | `test_respawn.mojo:test_supervisor_exits_nonzero_when_respawn_budget_is_spent` (every PR) |
| Handler thread pool behind each event loop | verified | `Smoke test the Mojo handler pool` (every PR) |
| Free-threaded CPython, N loops on N threads | verified | `py-canary` (weekly) |
| A GIL-enabled interpreter is refused, never warned-and-run | verified | `Smoke test the threaded mode's guard` (every PR) |
| Zero-config topology defaults | verified | `Smoke test --doctor against the server's own exit codes` (every PR) |
| Max-requests worker recycling with jitter | out of scope | the leak it mitigates is measured instead — `smoke-django` fails on RSS growth over 10k requests |
| Worker lifetime / max-RSS recycling | out of scope | same reason as above |

## F. Observability

| capability | status | evidence |
|---|---|---|
| Access logging, toggleable | verified | `Smoke test the serve CLI` (every PR) — `--access-log` |
| Prometheus `/__metrics`: 8 counter and gauge families, exposition 0.0.4 | verified | `Smoke test the serve CLI` (every PR) — `--metrics` |
| Latency histograms | planned | ROADMAP: A conformance-suite tier |
| Health endpoint answered before Python | verified | `Smoke test the hello server` (every PR) — `--health-path` |
| Configuration report that exits as the server would | verified | `Smoke test --doctor against the server's own exit codes` (every PR) — `--doctor` |
| OpenTelemetry tracing | out of scope | no tracing context crosses the Mojo/Python seam today; a wrapper in the application is the supported route |
| Structured CI-facing result output | planned | ROADMAP: Structured CI results |

## G. Security hardening

| capability | status | evidence |
|---|---|---|
| CR, LF or NUL in an application response header drops the header | verified | `test_response.mojo:test_has_control_bytes_finds_the_framing_bytes` (every PR) |
| An application's `Set-Cookie` reaches the wire verbatim | verified | `test_response_cookies.mojo:test_raw_line_reaches_the_wire_verbatim` (every PR) |
| `Proxy` request header never becomes `HTTP_PROXY` (httpoxy) | verified | `test_environ.mojo:test_proxy_header_is_excluded_from_the_environ` (every PR) |
| Path traversal rejected, encoded and plain | verified | `test_static.mojo:test_encoded_dotdot_is_rejected` (every PR) |
| Reserved `\x01` channel namespace refused at every publish boundary | verified | `test_broadcast.mojo:test_publish_rejects_reserved_channel` (every PR) |
| API key authentication | verified | `test_auth.mojo:test_a_rotation_of_the_key_is_rejected` (every PR) |
| CORS, configurable | verified | `Smoke test the notes API` (every PR) |
| `X-Forwarded-*` / `Forwarded` parsing with a trusted-proxy allowlist | out of scope | the server never consults them — `REMOTE_ADDR` is the socket peer and `wsgi.url_scheme` is configuration, so there is nothing to spoof |
| PROXY protocol v1/v2 | out of scope | same reason: the peer address is taken from the socket |
| Parser fuzzing in CI | planned | ROADMAP: A conformance-suite tier |

## H. TLS

| capability | status | evidence |
|---|---|---|
| TLS 1.2 / 1.3 termination | out of scope | terminate at a proxy — gunicorn's answer, and the same one applies here |
| ALPN, SNI, mTLS, OCSP stapling, certificate hot-reload | out of scope | all follow from not terminating TLS |

## I. WebSocket and Server-Sent Events

| capability | status | evidence |
|---|---|---|
| WebSocket handshake (RFC 6455), `Sec-WebSocket-Accept` | verified | `Smoke test the WebSocket echo demo` (every PR) |
| Fragmented messages reassembled | verified | `test_websocket.mojo:test_fragmented_message_assembles` (every PR) |
| Ping/pong, and a server heartbeat on a cadence | verified | `Smoke test the WebSocket echo demo` (every PR) |
| Close handshake through to TCP FIN | verified | `test_websocket.mojo:test_close_is_echoed_with_code_then_closes` (every PR) |
| Invalid UTF-8 in a text frame closes 1007 | verified | `test_websocket.mojo:test_invalid_utf8_text_closes_1007` (every PR) |
| A fragmented control frame is a protocol error | verified | `test_websocket.mojo:test_fragmented_control_frame_is_protocol_error` (every PR) |
| Wrong `Sec-WebSocket-Version` answers 426 advertising 13 | verified | `test_websocket.mojo:test_wrong_version_is_426_advertising_13` (every PR) |
| Cross-worker WebSocket fan-out over the broadcast bus | verified | `Smoke test the WebSocket chat demo` (every PR) |
| Server-Sent Events, with heartbeats and disconnect cleanup | verified | `Smoke test the Datastar counter` (every PR) |
| `Last-Event-ID` replay from a bounded journal | verified | `Smoke test the Datastar todo demo` (every PR) |
| A synchronous view gating a held SSE connection, with cross-worker publish | verified | `Smoke test the Django realtime example` (every PR) — `--realtime` |
| A synchronous view gating a held WebSocket it never speaks | verified | `Smoke test the Django realtime example over WebSockets` (every PR) |
| Autobahn\|Testsuite conformance run | planned | ROADMAP: A conformance-suite tier |
| `permessage-deflate` | out of scope | follows from having no response compression |
| WebSocket over HTTP/2 (RFC 8441) | out of scope | follows from having no HTTP/2 |

## J. Static file serving

| capability | status | evidence |
|---|---|---|
| Zero-copy `sendfile`, body never entering the process | verified | `Smoke test zero-copy static file serving` (every PR) — `--static` |
| Byte ranges: 206 with `Content-Range`, 416 when unsatisfiable | verified | `test_static.mojo:test_range_unsatisfiable_is_416_with_total` (every PR) |
| `If-Range` and `If-None-Match` precedence over a range | verified | `test_static.mojo:test_if_none_match_beats_range` (every PR) |
| ETag and conditional 304 | verified | `Smoke test the notes API` (every PR) |
| `Cache-Control`, configurable | verified | `Smoke test the serve CLI` (every PR) — `--static-cache-control` |
| Response compression (gzip, brotli, zstd) | out of scope | recorded in ROADMAP as deliberate: no dynamic compression; a proxy compresses |
| Precompressed sidecar files (`.br`, `.gz`) | out of scope | follows from the row above |

## K. WSGI (PEP 3333)

| capability | status | evidence |
|---|---|---|
| `application(environ, start_response)` against a bare callable | verified | `Conformance test the WSGI bridge` (every PR) |
| `wsgiref.validate` pass, with an engagement canary | verified | `Conformance test the WSGI bridge` (every PR) |
| The `write()` callable reaches the client, in production order | verified | `Conformance test the WSGI bridge` (every PR) |
| A second `start_response`, with and without `exc_info` | verified | `Conformance test the WSGI bridge` (every PR) |
| `wsgi.input` read, readline, iteration, and read past EOF | verified | `Conformance test the WSGI bridge` (every PR) |
| `QUERY_STRING` raw while `PATH_INFO` is decoded | verified | `Conformance test the WSGI bridge` (every PR) |
| `close()` called on the response iterable | verified | `Conformance test the WSGI bridge` (every PR) |
| Correct `wsgi.multithread` / `wsgi.multiprocess` for the real topology | verified | `Smoke test the Django WSGI example` (every PR) |
| Unsized iterables streamed from a pool thread, sized bodies buffered | verified | `Smoke test streamed WSGI bodies` (every PR) |
| Framework-neutral: one contract, two frameworks | verified | `Run the WSGI framework contract against Flask` (every PR) |

## L. ASGI 3.0

| capability | status | evidence |
|---|---|---|
| Single `app(scope, receive, send)`, protocol detected from the object | verified | `Conformance test the ASGI bridge` (every PR) — `--protocol` |
| `http` scope shape, validated against the spec | verified | `Conformance test the ASGI bridge` (every PR) |
| `websocket` scope: connect, accept, receive, send, close | verified | `Conformance test the ASGI bridge` (every PR) |
| `lifespan` startup and shutdown, degrading if unsupported | verified | `Conformance test the ASGI bridge` (every PR) |
| `lifespan.state` shallow-copied into each request scope | verified | `Conformance test the ASGI bridge` (every PR) |
| Streaming responses stream, credit-gated per stream and in total | verified | `Conformance test the ASGI bridge` (every PR) |
| Slot ownership across recycled connections | verified | `Smoke test the ASGI executor under the loop inversion` (every PR) |
| Slot ownership under CPU contention | verified | `stress-asgi` (pre-release) |
| Django's own ASGI handler through the executor | verified | `Serve a Django ASGI project through the executor` (every PR) |
| Starlette-family app (FastHTML) through the executor | verified | `Serve a FastHTML app through the ASGI bridge` (every PR) |
| Cross-worker pub/sub as `scope["state"]["m0"]` | verified | `ASGI cross-worker fan-out over the BroadcastBus` (every PR) |
| `http.response.pathsend` | out of scope | `--static` serves files in Mojo ahead of the application, which is the same saving without the extension |
| `http.response.zerocopysend`, `early_hint`, `trailers` | out of scope | no application has asked; the extensions are additive and can be taken later |

## M. Deployment and operations

| capability | status | evidence |
|---|---|---|
| Several applications in one process, routed by prefix | verified | `Serve two mounted applications from one process` (every PR) — `--mount` |
| Flags over environment over defaults | verified | `Smoke test the serve CLI` (every PR) — `--host`, `--port`, `--workers`, `--threads`, `--blocking-threads` |
| Application discovery from a bare module name | verified | `Conformance test the ASGI bridge` (every PR) — `--app-dir` |
| Usage errors exit 2, startup errors exit 1, refusals exit 78 | verified | `Smoke test --doctor against the server's own exit codes` (every PR) |
| `--help` names every documented flag; `--version` matches the release | verified | `Smoke test the serve CLI` (every PR) — `--help`, `--version` |
| Installable wheel with no toolchain and no dependencies | verified | `Build and smoke test the installable wheel` (every PR) |
| The aarch64 wheel built and served on arm64 hardware | verified | `Build and smoke test the aarch64 wheel` (every PR) |
| C-ABI shared library loadable by `dlopen`/`ctypes` | verified | `Smoke test the C-ABI shared library` (every PR) |
| The documented quickstart is executed, not asserted | verified | `Execute the quickstart` (every PR) |
| Correct signal handling as PID 1 in a container | verified | `Smoke test graceful shutdown` (every PR) |
| Configuration from a TOML file | out of scope | flags and `M0_*` environment variables cover it; a third source is a third precedence rule |
| systemd socket activation (`LISTEN_FDS`) | out of scope | no request for it; `SO_REUSEPORT` covers the restart case it is usually wanted for |
| An HTTP client in Mojo, for server-to-server calls | verified | `Smoke test the HTTP client` (every PR) |
| Windows, musl | out of scope | no Mojo toolchain for either — see the platform table in README.md |
