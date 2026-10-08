# Changelog

Notable changes to `mojo-http`. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[SemVer](https://semver.org/). From 1.0.0 the served contract does not break
in a minor release: `m0serve`'s flags and environment variables, the
`M0-Hold`/`M0-Channel` response headers, and `m0pub.publish()`.

## [Unreleased]

### Fixed

- **A client that half-closes is answered with `Connection: close`, and
  its connection ends behind the answer** (SPEC A27). A client that shuts
  down its write side after its request has sent its last one, but when
  the request did not itself ask for a close the answer said `keep-alive`,
  and on Linux the connection was then held until the idle timeout (for
  good with `--idle-timeout 0`) waiting for a request that could not come.
  Requests pipelined ahead of the last one are still answered first.

- **A half-closed request with a long head is answered** (SPEC A29). A
  client that sent a request whose headers were longer than 4 KB (a large
  cookie, a long token) and then shut down its write side could have its
  connection closed with no answer, the rest of its headers still unread.
  It is now read to its end and answered.

- **A client that pipelines and half-closes gets every answer when the
  first comes from a pool thread or the ASGI executor** (SPEC A30). With
  `--blocking-threads` or an ASGI application, when that answer went out
  only in part and the client's half-close was seen in the same moment,
  the connection closed as soon as the answer finished, and the requests
  pipelined behind it were never answered. They are now, and the
  connection closes after the last. Answers the event loop runs itself
  were not affected.

- **A streamed response honours `Connection: close`** (SPEC A28). An ASGI
  application's streamed body, or a WSGI application's streamed iterable
  on a pool thread, goes out chunked over HTTP/1.1, and when the request
  asked for `Connection: close` the response still said `keep-alive` and
  the connection stayed open after the body ended. It now says `close`
  and closes once the body is complete, as an unstreamed response does.

- **A stream open when the server is told to stop ends cleanly** (SPEC
  D12, D13). The drain says goodbye to every open stream before closing
  it, and wrote that goodbye where nothing may be written: into a streamed
  ASGI or WSGI body, where a client's chunked parser failed on it; into a
  WebSocket that had already sent its Close, as a second one; and into the
  middle of a frame still going out. Those streams now close as they
  stand, and the client reads the end of the connection; an SSE stream or
  WebSocket the server writes itself still gets its goodbye.

- **The access log times a keep-alive request when the header timeout is
  off** (SPEC F22). A server whose `ServerConfig` set
  `header_read_timeout = 0` logged the `dur_us` of every request after a
  connection's first as the time since the machine booted, and recorded
  no latency for them on `/__metrics`. They now run from the request's
  first bytes, as they always did with the timeout on; a connection's
  first request is timed from its accept, as before. m0serve and the Mojo
  host keep the default of 10 s, and were not affected.

- **A WebSocket the application has stopped reading stays stopped while
  its close completes** (SPEC I41). When an application falls behind the
  messages a client sends, the server stops reading that socket until the
  application catches up. Once the server's Close went out it started
  reading again, so the messages queued for a slow application kept
  growing for as long as the client went on sending. The socket now waits
  for the client's Close without reading until the application resumes
  it, or until the two-second close linger ends it.

- **A `CONNECT` request is answered 501 and its connection closed** (SPEC
  B18). It reached the application, and one that answers every method
  answered it 200, which a proxy forwarding `CONNECT` reads as an open
  tunnel: whatever the client sent next would pass through it unparsed.
  This server implements no tunnel, so no application, on m0serve or the
  Mojo host, receives `CONNECT` any more.

- **A chunked request body in another transfer coding as well is answered
  501 and its connection closed** (SPEC B21). `Transfer-Encoding: gzip,
  chunked` was de-chunked and the body handed to the application still
  gzipped. The server decodes `chunked` only, and now says so with 501, as
  RFC 9112 §6.1 asks. A `Transfer-Encoding` whose last coding is not
  `chunked` (a lone `gzip`, `chunked, gzip`) is still 400, as RFC 9112
  §6.3 requires.

- **A request target that is not a URI the server serves is answered 400**
  (SPEC B19). `GET p` and `GET host:80` reached the application as a path
  with no leading slash, and a target holding a raw byte above ASCII
  (`/caf\xe9`) as a path that is not UTF-8. A target now opens with `/`,
  is an `http` or `https` URI, or is `*` on an `OPTIONS` request; a
  non-ASCII character must be percent-encoded, as every browser does, and
  the escape still reaches the application undecoded.

- **A server-wide `OPTIONS *` reaches the application as `*`** (SPEC
  B19). It arrived as `OPTIONS /`, so an application could not tell a
  question about the whole server from one about its root page. A Mojo
  application reads `*` as `req.uri.path`; a WSGI application reads it as
  `PATH_INFO` and an ASGI one as `path` and `raw_path`, as gunicorn and
  uvicorn hand it on. Under m0serve the root mount answers it; with no
  root mount it is answered 404, as any path no mount claims. The view
  table (`Views`) reads `*` as a path of one segment: a table with a
  one-segment parameter route such as `/:slug` answers `OPTIONS *` as that
  route's preflight, 204 with its `Allow`, and a route registered for
  `OPTIONS` there runs with `*` as its parameter; a table with no such
  route answers 404.

- **`URI.parse` reads a query that follows the host directly** (SPEC A35).
  Exposed: an m0 application whose tests build a request with
  `URI.parse("http://127.0.0.1?x=1")`. The host was `127.0.0.1?x=1` and
  the request carried no query; with a port, `http://127.0.0.1:80?x=1`,
  the query was dropped. The path is `/` and the query `x=1`, as for
  `http://127.0.0.1/?x=1`. A `#` right after the host ends it too:
  `http://127.0.0.1#top` is host `127.0.0.1` and path `/`, where the host
  was `127.0.0.1#top`. A request from the wire was never affected.

- **`URI.parse` refuses a port that is not one** (SPEC A36). Exposed: an
  m0 application that parses a URL with `URI.parse`, its tests' request
  builders among them. `:99999` was read as port 34463, `:65536` as port
  0 and `:8x` as port 8; each now raises. An empty port
  (`http://127.0.0.1:/x`), which raised, is read as no port, the scheme's
  default, as RFC 3986 §3.2.3 allows.

- **A cookie a Mojo view builds can no longer add attributes of its own**
  (SPEC G2). Exposed: an m0 application that builds a `Cookie` from
  request data and sets it with `ResponseCookieJar.set_cookie`. Each field
  was written as given, so `Cookie("theme", "dark; Domain=evil.test")`
  went out as `theme=dark; Domain=evil.test`, a cookie for another site.
  A built cookie whose name is not a token (`a b`, `c=d`, an empty name),
  or whose value, `Domain` or `Path` holds a `;` or a control byte, is now
  dropped from the response, silently, as a header holding a line break
  is: nothing is logged. Every other value is written as before, a space,
  a comma, quotes, a backslash or a byte above 0x7F included, so a base64
  or JSON value goes out unchanged. A `Set-Cookie` line an application
  hands `add_raw`, which is how every WSGI and ASGI application's cookies
  arrive, is still sent as given.

- **A built cookie with no `Path` and one with `Path=/` are two cookies.**
  Exposed: an m0 application that sets the same cookie name twice in one
  response through `ResponseCookieJar.set_cookie`, once without a `Path`
  and once with `Path=/`. The jar treated a missing `Path` as `/` and kept
  only the second. A browser gives a cookie with no `Path` the request's
  directory (RFC 6265 §5.1.4), so it stores both. Both are now sent. An
  empty `Path`, or one not starting with `/`, means the same as none.

- **`NotFound(path)` no longer writes the path into its body.** Exposed:
  an m0 application that answers with `lightbug_http`'s `NotFound`, as the
  WebSocket examples do. The body was `path <path> not found`, the
  request's own bytes, markup included, in the server's answer; it is now
  `Not Found`. The argument is still accepted, and may be left out.

- **An empty `Host` is accepted when the target names no host** (SPEC
  B20). RFC 9110 §7.2 asks a client to send `Host` with an empty value
  when the URI it requests has no authority, and every empty `Host` was
  answered 400. It is accepted on an origin-form (`/path`) or `*` target,
  and the application reads an empty `HTTP_HOST`; beside an absolute-form
  target (`http://host/path`) it is still refused, as is a missing `Host`.

- **`Connection: close` closes the connection whichever `Connection` line
  carries it** (SPEC B22). A request with two `Connection` lines was read
  by its last alone, so `close` on the first was lost and the connection
  kept open. The lines are now one list, in order, as RFC 9110 §5.3 reads
  them, and the application sees them combined.

- **A request head with a bare LF is answered 400 as soon as it arrives**
  (SPEC B23). A head of bare-LF lines (`GET / HTTP/1.1\nHost: x\n\n`) was
  never served, but got no answer until the client closed or the header
  timeout sent 408, holding a connection slot meanwhile.

- **A chunked body whose trailer value holds a control byte is refused
  with 400** (SPEC B24), as a request header's value is. Trailers are
  discarded, so no application ever read one; the two rules now agree.
- **An inbound WebSocket message no longer waits on a quiet pool lane for
  the next request** (SPEC I39). Exposed: m0serve under `--realtime` with
  a handler pool, its default, where a Python view holds a WebSocket with
  `M0-Hold: websocket`. Each message is handed to the pool with a wake for
  a thread that is parked, and one that arrived while none was (every
  thread busy, spinning, or a moment from parking) woke nobody: the thread
  that parked next did not look for it, and the view was handed it only
  when a later request woke the pool, on a quiet server never. A thread now
  looks for a message once more after it announces its park. Found by the
  fork review; with a sleep holding that moment open, 24 messages of 24
  waited.

- **A cross-worker bus frame is delivered whole or not at all** (SPEC
  I40). Exposed: a publish whose channel name and frame together passed
  about 69.6 KB, through `m0pub.publish()`, `scope["state"]["m0"]`,
  `BroadcastBus.publish` or `DatastarStream` with the bus: a 5,000-byte
  channel with a 64 KB frame reached the other workers' subscribers 904
  bytes short, the end of the frame silently missing, though every
  publisher had accepted it. Each loop now reads every datagram a
  publisher can send whole, up to a 65,535-byte channel with a 65,536-byte
  frame, into one buffer it keeps instead of allocating and zeroing 70 KB
  on every drain. A datagram longer than that, or malformed, is refused
  and counted: `http_bus_frames_refused_total` on `/__metrics`, which
  counts the stream chunk channel's datagrams too (an ASGI executor and a
  streaming `--blocking-threads` pool write that channel in the same
  codec, and the same reader drains it).

- **A `DatastarStream` reads a `Last-Event-ID` the way the server's held
  streams do.** Exposed: an m0 application that calls `DatastarStream.open`
  with a request it built itself, whose `Last-Event-ID` carries whitespace
  around the id. `open` read `" 12 "` as 0 and replayed the whole journal
  where the client had seen up to 12; it now resumes after 12. The stream
  and the server's held streams share one parser
  (`lightbug_http.hold.request_last_event_id`), so the two cannot read an
  id differently again. A request from the wire was never affected: the
  server trims the whitespace before either parser sees the value.
- **WebSocket frames and upgrades the RFC calls malformed are refused with
  1002 or 400** (SPEC I35-I38). A client frame whose 64-bit length has its
  high bit set, or whose length is not in the shortest encoding that holds
  it, now closes the connection with 1002 (it was 1009, or accepted). A
  control frame (ping, pong, close) declaring more than 125 bytes is
  refused when its header arrives, not after its payload. The upgrade
  request must list `upgrade` as a whole token of `Connection`
  (`Connection: notupgrade` was accepted) and must be HTTP/1.1; an
  HTTP/1.0 request is answered 400.
- **On Linux, a connection on a descriptor numbered 65536 or above no
  longer disturbs another's timer, or the application's tick** (fork
  review LF18, SPEC C11). Exposed: Linux servers whose descriptor limit
  (`ulimit -n`) lets a connection reach descriptor 65536, m0serve and Mojo
  applications alike. The epoll backend kept each timer in one of five
  regions of 65536 slots, so a higher descriptor's timer took another's
  slot: an SSE stream on descriptor 65536 re-armed the `M0_APP_TICK_MS`
  tick and, when it ended, stopped the tick for good; a request body read
  on descriptor 131072 + k re-armed descriptor k's heartbeat; and a stream
  at or above 131072 got no heartbeat, a body at or above 262144 no read
  timeout. Every timer now has a slot of its own at any descriptor below
  2^20, which a process reaches only with a descriptor limit
  (`RLIMIT_NOFILE`) above a million.

- **A server that returns gives back its kqueue or epoll descriptor**
  (fork review LF21, SPEC C13). Exposed: a Mojo application that serves,
  returns and serves again in one process (`Server.serve_nonblocking`,
  `listen_and_serve`), and the Mojo host's `M0_THREADS` loops as they
  end; m0serve and a host process exit when their loops do, so they
  never reached it. Each return left its multiplexer open, and on Linux
  every timerfd the loop still held. The backend now closes them when the
  loop is done with it. On Linux, an epoll registration the kernel
  refuses is now reported with its own error: a refused ADD was retried as
  a MOD, whose ENOENT was reported in its place.

- **On Linux, a burst of new connections queues instead of being
  dropped** (fork review LF19, SPEC C12). Exposed: Linux servers, m0serve
  and Mojo applications alike. The listener asked the kernel for an accept
  queue of 128, so while the loop was busy -- a slow pass, a batch of
  accepts -- connections past the 128th were dropped at the handshake, and
  each client waited a second or more to retry. The queue is now up to
  `SOMAXCONN` (4096 on Linux, 128 on macOS), or the system's setting if
  that is lower. macOS's limit was and stays 128.

- **Two request cookie jars of two or more cookies compare equal** (fork
  review LF30, SPEC G22). Exposed: an m0 application that compares
  `RequestCookieJar`s with `==`. A jar of two or more cookies was unequal
  even to a jar parsed from the same `Cookie` field, since every cookie of
  one was compared with every cookie of the other. Jars are now equal when
  they hold the same names with the same values, in any order. The server
  itself never compares jars.

- **A bracketed listen address with a colon in its port is refused**
  (fork review LF33, SPEC A31). Exposed: a Mojo application that passes
  `Server.listen_and_serve` an IPv6 address such as `[::1]:8:0`. The port
  was read after the last colon, so that address listened on a port the
  kernel chose, and `[::1]:8:80` on port 80. It is now refused at startup
  as too many colons, as Go's `net.SplitHostPort` refuses it.

- **A listen address of `localhost` with no port is refused** (fork review
  LF45, SPEC A33). Exposed: a Mojo application that passes
  `Server.listen_and_serve` (or `ListenConfig.listen`) the bare word
  `localhost`. It was read as the loopback at port 0, so the server
  listened on a port the kernel chose and named it to no one. It is now
  refused at startup as missing its port, as `127.0.0.1` alone always
  was; `localhost:8080` is unchanged. m0serve and the Mojo host always
  pass a port.

- **A listen address's port must be digits** (fork review LF46, SPEC
  A34). Exposed: a Mojo application that passes `Server.listen_and_serve`
  (or `ListenConfig.listen`) an address whose port text is not plain
  digits. The port was read the way `Int()` reads a number, taking a sign,
  whitespace and underscores, so `127.0.0.1:-0` listened on a port the
  kernel chose and `127.0.0.1:+80`, `127.0.0.1: 80` or `127.0.0.1:8_0` on
  port 80. Such a port is now refused at startup. m0serve and the Mojo
  host check `--port` themselves and pass it on as digits.

- **The "listening on" line names the port the server is bound to**
  (fork review LF47, SPEC F25). Exposed: a Mojo application that passes
  `Server.listen_and_serve` (or `ListenConfig.listen`) a port of 0, such as
  an application not on the Mojo host, which takes a port the kernel
  chooses. The line read `Lightbug is listening on http://127.0.0.1:0`, a
  port nothing can connect to; it now names the port the kernel chose.
  m0serve and the Mojo host refuse a port of 0 (LF56, below) and never
  reach it.

- **A listen address with an IPv6 zone is refused on every platform, and
  a refused listen address says why** (fork review LF48, SPEC E31, M5).
  Exposed: m0serve or a Mojo host given `--host fe80::1%en0`, and a Mojo
  application passing such an address to `Server.listen_and_serve`. On
  macOS, whose libc reads the zone into the address, it listened on that
  interface's link-local address and was reported without its zone; on
  Linux it was refused as not an address. A listen host may not contain
  `%` now, on either. m0serve and the host refuse such an address at
  startup with exit 78, before anything is bound, as the new `address`
  check that `--doctor` reports too: the server used to fail at the bind
  with exit 1 while the doctor said 0. Every refused listen address now
  names the rule it broke: the error read "Failed to parse listen address"
  and stopped there, and now goes on with the reason ("a listen host may
  not contain '%'", "missing port separator", "too many colons").
  `AddressParseError` carries that reason (`AddressParseError(reason)`)
  and is no longer a `CustomError` or `ImplicitlyCopyable`.

- **An `M0_*` number too large to hold is ignored, not wrapped** (fork
  review LF49, SPEC F19). Exposed: m0serve and Mojo host applications
  started with a numeric `M0_*` variable whose digits pass 2^63, such as
  `M0_PORT=18446744073709551696`. The digits were added up with no
  overflow check, so that value served on port 80, and
  `M0_WORKERS=18446744073709551618` forked two workers. Such a value is
  now read as unreadable, as `M0_PORT=80eighty` always was: the default
  is used, and m0serve's startup says so, naming the largest number it
  reads.

- **`Socket.receive` and `TCPConnection.read` into a full buffer read what
  is waiting** (fork review LF34, SPEC A32). Exposed: an m0 application
  that reads a socket through either, into a `Bytes` with no room past its
  length (one already full, or a `Bytes()` never given a capacity). The
  read asked for zero bytes and reported the peer's EOF with its bytes
  still waiting. The buffer now grows by 4 KB before the read. The server
  itself reads through its event loop and never called these.

- **`/__metrics` counts a 101 in a `1xx` status class** (fork review LF32,
  SPEC F23). Exposed: m0serve and Mojo applications run with `--metrics`
  that hold WebSockets. Each upgrade's 101 Switching Protocols was in
  `http_requests_total` and in none of `http_responses_total`'s classes,
  so the classes summed to less than the total. It is now in
  `http_responses_total{status="1xx"}`, and `http_requests_total`'s help
  text says what it has always counted: requests answered, as each
  response's head lands, not requests received.

### Changed

- **A port outside 1-65535 is refused with exit 78, from a flag or the
  environment alike** (fork review LF56, SPEC E30, E31, M2). Affects
  m0serve and Mojo host applications given `--port 0`, `M0_PORT=0`, or a
  port past 65535. `M0_PORT=0` served on a port the kernel chose, which
  m0serve's startup line named as `:0`, while `--port 0` was a usage error
  (exit 2). Both are now read and then refused at startup with exit 78,
  before anything is bound, as a count the server will not serve already
  was: `M0_PORT must be between 1 and 65535, got 0` from m0serve and
  `M0_PORT must be 1-65535, got 0` from the host, the fix naming `--port`
  and `M0_PORT`. `--doctor` reports it as the `port` check, now the first
  of each list. A script that read exit 2 for `--port 0` reads 78 now.

- **The fork's descriptor helpers live in the module that owns them**
  (fork review LF28). Nothing served changes. An application built with
  the `m0` wheel that imported one of these from the old place imports it
  from the new: `set_nonblocking`, `is_nonblocking`, `F_GETFL` and
  `F_SETFL` from `lightbug_http.c.fcntl`, no longer `lightbug_http.c.kqueue`
  (they serve Linux too); `O_NONBLOCK` and `O_CLOEXEC` from
  `lightbug_http.c.fcntl`, no longer `lightbug_http.c.socket`; and
  `set_tcp_nodelay` from `lightbug_http.c.socket`.

- **`recv` and `send` take their length from the span they are given**
  (fork review LF20, SPEC G21). Nothing served changes. The two calls in
  `lightbug_http.c.socket` took a length beside the span, which the span
  did not have to back: a count above the span's length was written past
  its end. They now read or write `len(span)` bytes and no more, so an
  application built with the `m0` wheel that called one drops the length
  argument, slicing the span to the count it meant. To receive into a
  list's spare capacity, pass `spare_capacity(list)` and grow the list by
  what `recv` returns.

### Removed

- **The fork's client connect path, and the last of its dead C bindings**
  (fork review LF26). Nothing served changes: m0serve and the Mojo host
  never open a connection, and reached none of it. The `m0` wheel ships
  the fork's source, so an application built with `m0` that named one of
  these needs its own copy: `Socket.connect` and
  `lightbug_http.connection.create_connection`, with the `connect(2)`
  binding in `lightbug_http.c.socket`; the `getaddrinfo` machinery under
  them in `lightbug_http.address` (`getaddrinfo`, `get_ip_address`,
  `CAddrInfo`, `AnAddrInfo`, `addrinfo_macos`, `addrinfo_unix`,
  `freeaddrinfo`, `gai_strerror` and their three error types), whose
  iterator never ended on Linux; `TCPConnection.set_recv_timeout`,
  `Socket.set_timeout` and `SocketOption.SO_RCVTIMEO`; `NetworkType`'s
  `SUPPORTED_TYPES`, `TCP_TYPES`, `UDP_TYPES` and `IP_TYPES`;
  `lightbug_http.c.address.AddressInformation`, whose `AI_*` values were
  Linux's on macOS too; `lightbug_http.c.network`'s `addrinfo`, laid out
  as Linux's on every platform, `in6_addr` and `sockaddr_in6`;
  `try_writev`; and `kevent_register`, `EV_ENABLE` and `EV_DISABLE`.

- **`lightbug_http.c.epoll`'s `EPOLL_CLOEXEC`, `TFD_CLOEXEC` and
  `TFD_NONBLOCK`** (fork review LF28), copies of the open flags under
  Linux's other names. Nothing served changes; an application built with
  the `m0` wheel that named one passes `O_CLOEXEC` or `O_NONBLOCK` from
  `lightbug_http.c.fcntl`, the same values.

- **The fork's response parser, its `Set-Cookie` parser and unused
  helpers** (fork review LF26). Nothing served changes: the server parses
  requests, never responses, and writes an application's `Set-Cookie` as
  given. The `m0` wheel ships the fork's source, so an application built
  with `m0` that named one of these needs its own copy:
  `HTTPResponse.from_bytes`, the `HTTPResponse` constructor from a
  `ByteReader`, `read_body` and `read_chunks`;
  `lightbug_http.header.parse_response_headers` and
  `ParsedResponseHeaders`, `lightbug_http.http.parsing`'s
  `http_parse_response_headers`, `get_token_to_eol` and `try_peek_at`;
  the response parse errors, `lightbug_http.header`'s
  `ResponseParseError`, `InvalidHTTPResponseError` and
  `IncompleteHTTPResponseError`, and `lightbug_http.http.response`'s
  `ResponseParseError`, `ResponseHeaderParseError` and
  `ResponseBodyReadError`; `ResponseCookieJar.from_headers`;
  `Cookie.from_set_header`, which dropped `expires`, a capitalised
  `SameSite` and any attribute it did not know; `Cookie.clear_cookie`;
  with `lightbug_http.cookie`'s `CookieParseError` (the request side's,
  `lightbug_http.http.request.CookieParseError`, stays),
  `InvalidCookieError`, `Expiration.invalidate` and the `from_string` of
  `Expiration`, `Duration` and `SameSite`;
  `ParsedRequestHeaders.expects_body`, which missed a chunked
  body on any method but POST, PUT and PATCH; `write_header_latin1`,
  which wrote a header holding CR or LF where `Headers.write_latin1_to`
  drops it; `HTTPChunkedDecoder.is_in_chunk_data`;
  `lightbug_http.strings`' `find_all`, `is_printable_ascii`,
  `IS_PRINTABLE_ASCII_MASK`, `BytesConstant.CRLF` and
  `BytesConstant.DOUBLE_CRLF`; and
  `lightbug_http.io.bytes`' `is_newline`, `is_space` and `bufis`, and
  `ByteReader`'s `read_line`, `read_word`, `skip_whitespace`,
  `skip_carriage_return` and `consume`. `parse_headers` and `scan_to_eol`
  lose their `strict` parameter and always read a request head's rules;
  the lenient reading was the response parser's.
- **`LoopState.fd_map_size`, and the event loop's handling of an idle
  timer** (fork review LF26): the field was set and never read, and
  nothing arms an idle timer (idle deadlines are swept), so its branch
  could not run. Nothing served changes. A connection that closes with
  part of a response still unsent now gives that buffer back at once,
  rather than when its slot next answers someone.

- **The fork's network and address code that nothing calls** (fork review
  LF44, LF45, LF48). Nothing served changes. The `m0` wheel ships the
  fork's source, so an application built with `m0` that named one of these
  needs its own copy: `NetworkType`'s `udp`, `ip`, `ip4`, `ip6`, `unix`
  and `empty`, `is_ip_protocol` and `is_ipv4`, and
  `ParseIPProtocolPortError`, which only an `ip` network raised;
  `lightbug_http.address.DEFAULT_IP_PORT`; `validate_no_brackets`'
  `end_idx` parameter, never passed; `TCPAddr`'s zone (the field and its
  constructor), `address_family`, `is_v4`, `is_v6`, `is_unix`, `==`,
  `__str__`, `__repr__` and `write_to`, with the `Addr` requirements
  behind them; `binary_port_to_int` and `ntohs`; `Socket`'s
  `remote_address`, with the `remote_address` parameter of both
  constructors that remain, its constructor without a family,
  `get_peer_name`, `__enter__`, `__str__`, `__repr__` and `write_to`, and
  the `getpeername` binding; `NoTLSListener`'s constructor that made its
  own socket, `shutdown`, `teardown` and `addr`; `TCPConnection`'s
  `shutdown`, `teardown`, `local_addr` and `remote_addr`;
  `ConnectionState.closed` and `ConnectionState.CLOSED`;
  `AddressParseError`'s `CustomError` and `ImplicitlyCopyable` conformances
  and its empty constructor (it now takes the refusal's text,
  `AddressParseError(reason)`, and moves);
  `ListenerError`'s `Error` arm and `SocketNameError`'s `InetNtopError`
  arm, neither ever raised; the `__getitem__` and `__str__` of the
  address, listener, socket and `inet_*` error variants, and the `isa` of
  `ParseError`, `ListenerError`, `SocketNameError`, `InetNtopError` and
  `InetPtonError`;
  `SocketAddress.as_sockaddr_in` and `sockaddr`'s constructor;
  `AddressFamily.is_inet`, `AddressLength.INET_ADDRSTRLEN` and
  `ShutdownOption.SHUT_RD`; and the `write_to` and `__str__` of
  `AddressFamily`, `AddressLength`, `ShutdownOption`, `SocketOption` and
  `SocketType`, with the `==` of the last four.
- **The fork's unused URI, cookie, response and byte helpers** (fork
  review LF52). Nothing served changes, and no application in the tree,
  the `m0` templates or the one outside it named any of these; an
  application built with `m0` that did needs its own copy. From
  `lightbug_http.uri`: `URI`'s `username`, `password`, `full_uri`,
  `_original_path` and `_hash` fields (always empty, or the path again),
  its `__str__`, `__repr__`, `is_http` and `is_https`, the unused
  `QueryDelimiters` and `URIDelimiters` constants, and
  `URIParseError.__str__` (`String(error)` still writes it). From
  `lightbug_http.cookie`: `Expiration`, a stub that could only say
  "session", with `Cookie`'s `expires` field and argument (a `Cookie` sets
  its lifetime with `max_age`); `Cookie.to_header` and `Cookie.__str__`;
  `SameSite.__eq__`; `RequestCookieJar`'s constructor from cookies,
  `parse_cookies`, `empty`, `encode_to` and its `in` for a `Cookie`; and
  `ResponseCookieJar`'s constructors from cookies, its `[]`, `get` and
  `in`. From `lightbug_http.http`: the two `OK` overloads taking `Bytes`,
  `SeeOther` (also exported from `lightbug_http`; `m0_http.reply.redirect`
  builds every redirect) and `BadRequest(message)`. From
  `lightbug_http.io.bytes`: `OutOfBoundsError`, `EndOfReaderError.__str__`,
  `ByteReader`'s `read_bytes(n)`, `as_bytes` and `in`, and `ByteView`'s
  comparisons, `in`, truth test, `as_bytes` and `__str__`. From
  `lightbug_http.strings`: `https`, `colonChar` and the seventeen
  `BytesConstant` bytes nothing reads.

## [1.12.1] — 2026-10-07

A patch release for the security fixes of a review of the server's HTTP
core, the `lightbug_http` fork. A header value could split a response built
in Mojo, and a request head ending a line with a bare LF put the parser and
the event loop's framing out of step in every server, m0serve included; on
macOS the page workers share could be created readable by other users. The
review's other fixes are here too: request heads, trailers and targets the
RFCs call malformed are refused or read as they say. The served contract is
unchanged. The `m0` wheel ships the framework's source, so an application
built with `m0` takes every fix by rebuilding against `m0 0.9.1`. This
section also records what `m0 0.9.0` published on its own: the `board`
template and `m0 new .`.

### Security

- **A header value can no longer split a response with an overlong UTF-8
  sequence** (SPEC G19). Exposed: responses built in Mojo only; the
  gateway's Python applications are not. The latin-1 transcoder that
  writes every response head decoded three- and four-byte sequences as
  well as two-byte ones, AFTER the check that drops a header carrying CR,
  LF or NUL, so the overlong forms `E0 80 8D` and `E0 80 8A` went out as a
  real CRLF. A Mojo view that redirected to a request's `next` with
  `reply.redirect` could be
  made to send a `Set-Cookie`, or a body, of the request's choosing:
  `?next=/%E0%80%8D%E0%80%8ASet-Cookie:%20sid%3Dx` did it, and a header or
  `Set-Cookie` value a view built from request data was open the same way.
  Every response built in Mojo was exposed: a `Views` application's, the
  Mojo host's, and a Mojo mount's in m0serve. Python applications on
  m0serve were not: a `str` header reaches the server as CPython's UTF-8,
  which is never overlong, and a `bytes` value is re-encoded byte by byte.
  The transcoder now decodes only U+0080 to U+00FF and writes every other
  byte as it was given, and the writers check the transcoded bytes again
  before they send them. Upgrade m0serve if it serves a Mojo mount, and
  rebuild every Mojo application against this release (an `m0`
  application against `m0 0.9.1`).

- **A request head with a bare LF is refused with 400** (SPEC B12).
  Exposed: every server, m0serve included, whatever it serves; the
  parser and the event loop are the same under all of them. Upgrade
  m0serve, and rebuild every Mojo application. The parser ended a head
  at a bare-LF empty line (`\r\n\n`), while the event loop frames a head
  by the first CRLFCRLF, and the bytes between the two were lost: a
  request pipelined behind such a head got no
  answer, and a `Content-Length` after the bare LF was never read, so the
  body it described was answered as a request of its own. Every line of
  a request head must now end in CRLF, and the loop also refuses any head
  the parser ends at a different byte than its own frame, then closes the
  connection. A client that ends request lines with a lone LF is refused;
  none is known. `smoke-pipelining` sends both shapes.

- **The page workers share is created private on macOS** (SPEC G20).
  Exposed: macOS only; the mode was measured world-readable once. The
  server asked `shm_open` for mode `0o600` in a register, where Apple
  silicon passes that argument on the stack, so the page took whatever
  mode the stack held: measured as `0o000`, `0o001` and `0o744`, the last
  readable by any user who opened it by name before the server unlinked
  it a moment later. It is now created `0o600`. A page that cannot be
  sized no longer leaks its descriptor. Linux was not affected.

### Added

- **`m0 0.9.1`, this release's framework, for applications built with
  `m0`.** The wheel ships the framework's source, the server's HTTP core
  included, so an application takes every fix under Security and Fixed by
  rebuilding against it: raise its pin to `m0==0.9.1`, then `uv sync` and
  `uv run m0 build`. Nothing in an application's own source has to
  change. What changed since `m0 0.9.0` for someone writing an
  application:
  - Fixed, the response splitting under Security. Every response an `m0`
    application builds is built in Mojo, so every application built with
    an earlier `m0` is exposed until it is rebuilt.
  - Fixed, the bare-LF framing desync under Security, and the request,
    WebSocket and static-file fixes under Fixed.
  - Changed, `m0 --help` names the templates, and an `m0 new` given no
    template says it took the default (under Changed).

- **`m0 0.9.0`, published on its own**, for applications built with `m0`.
  What changed since `m0 0.8.0` for someone writing an application:
  - New, `m0 new --template board`: a list every tab shares, whose sender
    is a view publishing through the state's `DatastarStream`.
  - New, `m0 new .`: writes the empty current directory, named for it.
  - The next step `m0 new` prints serves on `127.0.0.1`.
  - Fixed, `live` behind a handler pool: a project `m0 0.8.0` or earlier
    wrote takes the two lines under Fixed below.
  - The scaffold's `AGENTS.md` changed, so `m0 doctor` names it in a
    project an earlier `m0` wrote. The framework's own source is
    unchanged since `m0 0.8.0`.

- **`m0 new --template board`, and `m0 new .`** (SPEC N27, N52, D66;
  docs/notes/what-the-agent-runs-asked-for.md). The follow-ups from the
  agent usability runs, where every Mojo run wrote `./NAME` and moved it
  up a level, then deleted half of `live` to get a list a request pushes.
  - `board` is a list every tab shares whose sender is a view: a POST
    appends and publishes the whole board through the state's
    `DatastarStream`, with no producer and no database. Its views run on
    the loop, and the gate serves it behind a handler pool.
  - `m0 new .` writes the empty current directory and takes its name.
  - The printed next step serves on `127.0.0.1`.

- **Skills for m0serve and m0** in `skills/`, written from where the
  agent runs looked.

### Fixed

- **A response whose application sets `Server` no longer carries two
  `Server` lines** (SPEC A26). The server wrote its default `server: lightbug_http`
  whatever the headers held, so an application that named itself, built
  in Mojo or a Python application on m0serve, sent two. The default is now
  written only when the application set none.

- **A folded field line is refused with 400** (SPEC B13). A request
  field line opening with a space or a tab (obs-fold, RFC 9112 §5.2) was
  accepted as a field with an empty name: a WSGI application saw an
  environ key `HTTP_`, and the folded text never joined the field it
  continued. Such a request is now refused.

- **A chunked request body's trailer is held to field lines ending in
  CRLF** (SPEC B14). After the last chunk the trailer section skipped any
  run of CR, took a bare LF as a line end, and took any line as a field,
  so `0\r\n\n` ended a body that a stricter proxy in front still reads
  as open, and a trailer line with no colon was served where Node's
  llhttp and h11 refuse it. Each now makes the body invalid, answered
  400, as a bare LF in a chunk extension already was. Trailers are still
  discarded, never handed to the application.

- **An HTTP/1.0 request with a chunked body closes its connection behind
  the answer** (SPEC B15). RFC 9112 §6.1 calls `Transfer-Encoding` on an
  HTTP/1.0 message faulty framing, and asks for the connection to close
  after it. Such a request was de-chunked and, with `Connection:
  keep-alive`, kept alive, so a request pipelined behind it was answered
  too. It is now answered and the connection closed. And `HTTP/1.2`
  through `HTTP/1.9`, which are served as HTTP/1.1, now need a `Host`
  field as HTTP/1.1 does; one without was served.

- **`Connection: close` closes wherever it stands in the list** (SPEC
  B17). `Connection` is a list of options (RFC 9110 §7.6.1), and the
  server compared the whole value with `close`: `Connection: close, TE`
  kept the connection alive and answered the request pipelined behind
  it. Each option is now read on its own, case-insensitively, and an
  HTTP/1.0 client's `keep-alive` is read the same way. Under `--metrics`
  the `/__metrics` answer kept its connection alive whatever the request
  asked; it now closes as every other answer does, for this and for an
  HTTP/1.0 chunked request alike.

- **A request whose target is a whole URL takes its host from the URL**
  (SPEC B16). RFC 9112 §3.2.2 says a server receiving `GET
  http://example.com/p HTTP/1.1` uses the target's host and ignores the
  `Host` field. The server threw the target's host away and kept `Host`,
  so an application routing on `Host` (Django's `HTTP_HOST`) read a site
  the target never named. The target's `host[:port]` now replaces `Host`.
  The scheme is matched in any case (`HTTP://h/p` reached the application
  as the path `HTTP://h/p`), a query straight after the host is kept
  (`http://h?q=1` lost it), and a target with no host (`http:///p`) or
  with a userinfo (`http://user@h/`) is refused with 400.

- **A WebSocket message is no longer lost when a frame the server refuses
  follows it in the same read** (SPEC I34). A frame the protocol forbids
  (a reserved opcode, an unmasked frame, a text frame that is not UTF-8)
  ends the connection with a Close, and that refusal discarded everything
  parsed from the same read before it: a complete message never reached
  the application, and a ping went unanswered. Whether a message arrived
  depended on how TCP split the bytes. Both are now kept, the Close sent
  after the pong.

- **A static file that shrinks while it is served no longer spins its
  connection** (SPEC J15). When a file ended before the `Content-Length`
  its response had already sent, the server read the end of the file as
  a socket that could take nothing yet and waited for room it already
  had: the connection spun on the event loop until the idle timeout
  closed it, and for good with idle timeouts off. It now closes at once,
  and the client sees a response shorter than its length, an error it
  can detect.

- **The `live` scaffold's stream behind a handler pool.** Its `/events`
  view was not `on_loop`, and its handler answered only stateless loop
  routes, so under `--blocking-threads` (`M0_BLOCKING_THREADS`) every
  stream was refused 409. A project an earlier `m0` wrote takes the same
  two lines: `on_loop=True` on the `/events` registration in
  `src/views.mojo`, and `self.views.answer_on_loop(req, self.state)` in
  `LiveHandler.before_request`. `smoke-scaffold` now serves `live` behind
  a pool.

### Changed

- **`m0 --help` names the templates** (SPEC N27;
  docs/notes/what-the-agent-runs-asked-for.md). Every Mojo run without the
  skill ran `m0 --help`, then a bare `m0 new .` before it knew a
  template's name, took `views`, and wrote its application a second time.
  The top-level help now lists the four, a line each, and an `m0 new`
  given no template says it took the default and lists the others. It
  ships in `m0 0.9.1`.

- **The pages say what the agent runs had to find out.** Both quickstarts
  serve on `127.0.0.1`. The Python quickstart says where libpython comes
  from, what `publish()` does with a line break, and that a form post
  meets Django's CSRF check. The home page and the Mojo overview point an
  agent at `llms.txt` and each page's Markdown. The overview maps the API
  to its pages; the views page gives `reply`, `reply.problem`'s four
  arguments, and Datastar 1.0's rule that an action's answer applies only
  on a 200. The scaffold's `AGENTS.md` names the reference pages before
  the installed source, so `m0 doctor` reports it as changed in a project
  an earlier `m0` wrote.

## [1.12.0] — 2026-10-06

A held stream that reconnects is caught up on what it missed. Two of the
known issues were taken up: the first, a WSGI hold that replayed nothing,
is retired by a per-loop journal; the second, the RHEL 9 glibc floor, was
measured and found to be the Mojo runtime's, so its record is corrected
rather than closed. A `Last-Event-ID` from a previous incarnation is
clamped instead of starving the stream. The served contract is unchanged,
with one addition, the `m0-gap` event; the `m0` wheel ships as `m0 0.8.0`.

### Added

- **`m0 0.8.0`: this release's framework, for applications built with
  `m0`.** What changed since `m0 0.7.0` for someone writing an
  application: new, `m0_http.ReplayJournal` (`m0_http.sse.replay`), the
  bounded journal m0serve's holds are caught up from, usable beside an
  application's own `SSERegistry`. Nothing an application has to change.

- **A held stream that reconnects is caught up.** Each loop journals the
  last `--replay-frames` published frames (`M0_REPLAY_FRAMES`, default 64;
  0 keeps none), and a `M0-Hold: stream` that reconnects with
  `Last-Event-ID` is sent every frame of its channel it missed, in order,
  before the live feed — whether the hold was taken inline, on a pool
  thread, by a Mojo mount or by a hold mount. When the journal cannot
  supply all of them, the client is sent none and one unnumbered
  `event: m0-gap` frame whose data names the id it presented and the
  newest id allocated, so it can fetch instead of polling beside the
  stream (SPEC I33; [the record](docs/notes/a-hold-that-replays.md)).
  `--doctor` reports `replay_frames`.

### Changed

- **A `Last-Event-ID` ahead of the counter no longer starves the stream.**
  A client holding an id from a server that has since restarted presented
  one this incarnation never allocated, and the registry took it
  literally, suppressing every frame until the counter passed it. It is
  now clamped to the newest id and reported as an `m0-gap`.
- **The platform note on RHEL 9 is corrected.** The README and the known
  issue said the Linux floor was the build host's and that a
  `manylinux_2_34` container build would reach glibc 2.34. Measured on the
  1.11.0 wheels, the floor is the Mojo runtime's own (`GLIBC_2.35` in
  `libAsyncRTRuntimeGlobals.so`, GCC 12's libstdc++ in
  `libKGENCompilerRTShared.so`), so no build of ours lowers it; the wheel
  tag script now names the file that set the floor on every build
  ([the measurement](docs/notes/the-floor-is-the-runtime.md)).

- **The benchmark page's ASGI per-core verdict is corrected.** It said
  uvloop leads the executor per core on macOS and that Linux answers at or
  above parity. The macOS figure had crossed 1.0 at the 1.10.0 re-record,
  and both a container and a rented x86-64 box put the default executor a
  little behind uvloop per core (0.91x, 0.94x). The one-thread loop
  (`M0_INVERTED=1`) leads uvloop per core everywhere measured, 1.27–1.42x,
  and at 16 connections it also serves more than the default on Linux
  ([the record](docs/notes/asgi-per-core.md)).

### Fixed

- **A `--blocking-threads` stream's abort can no longer be lost beside its
  head.** The loop read the completion ring and then the completion
  channel. A pool thread completes a stream's head onto the ring and, when
  the chunk channel refuses the body, sends that stream's abort on the
  channel. If the push and the send both landed between the loop's two
  reads, the loop met the abort with no head, dropped it as an abort for a
  slot that is not streaming, and then opened the stream, which stayed
  open, kept alive by its heartbeat. The loop now reads the channel first,
  so an abort it takes always has its head on the ring
  ([the record](docs/notes/asgi-per-core.md)). The window is too narrow to
  reproduce on demand; `test_offload.mojo` pins the new order.

## [1.11.0] — 2026-10-06

What an application moved from uvicorn met, fixed. franchise-assessment's
move onto m0serve found a lifespan startup that failed without a word, an
access log whose numbers were strings and whose byte count was the
response head, static files served without the security headers its
middleware set (and, for some types, as downloads where Starlette
displayed them), and two limits only a flag could reach. Each is fixed
here, and `docs/RUNNING.md` says in a few lines what a uvicorn command
line does not show. The access log's line changes shape (Changed, below);
the served contract is unchanged; the `m0` wheel ships as `m0 0.7.0`.

### Added

- **`m0 0.7.0`: this release's framework, for applications built with
  `m0`.** What changed since `m0 0.6.0` for someone writing an
  application:
  - New: `StaticFiles(..., headers=...)` (J11), and `static_headers`,
    `svg_policy_for` and `SVG_SANDBOX_POLICY` in `m0_http`. Every
    `StaticFiles` answer carries `X-Content-Type-Options: nosniff` (J12),
    an SVG carries a sandboxing `Content-Security-Policy` (J14), and the
    type table follows Python's `mimetypes` (J13).
  - What an application may have to change: whatever reads its access
    log (`M0_ACCESS_LOG`), whose numbers are now JSON numbers and whose
    `ts` is now `time` (F20, F21); and an SVG served by `StaticFiles` that
    scripts itself, which stops scripting.
  - Nothing an application built by `m0 0.6.0` must act on otherwise: the
    templates are unchanged, and `m0 doctor` names no scaffold file.

- **Static files carry their types** (SPEC J13). The table behind
  `--static` and `StaticFiles` knew 19 extensions and sent everything
  else as `application/octet-stream`. An app moved from Starlette or
  Django, both of which use Python's `mimetypes`, lost about 45 types,
  and an image or audio file of one of those types downloaded when
  opened directly, in Chromium, Firefox and WebKit, where it had been
  displayed or played. The table adds fonts (`woff`, `ttf`, `otf`),
  `avif` and `bmp`, audio and video (`mp3`, `m4a`, `ogg`, `wav`, `flac`,
  `aac`, `mp4`, `webm`, `ogv`, `mov`), captions (`vtt`), the web app
  manifest, source maps, feeds, calendars, CSV and TSV, JSON-LD,
  GeoJSON, YAML (RFC 9512), Parquet, `zip` and `gz`. A proxy compresses
  by type, and this server leaves compression to it, so text labelled
  `octet-stream` used to go out uncompressed. Build inputs (`.jsx`,
  `.tsx`, `.ts`), model weights and JSON Lines stay
  `application/octet-stream` on purpose.

- **`--static-header 'Name: value'`** (SPEC J11): repeatable, adding a
  header to every response a `--static` mount answers, errors included.
  These are the security headers an application's middleware sets, which
  static responses never pass through. franchise-assessment's
  `X-Frame-Options`, `Strict-Transport-Security`, `Referrer-Policy` and
  the rest were missing from its CSS, JS and icons. The flag is refused
  with exit 2 for a name that is not a token, a control character, a name
  given twice, a name the static server sets itself (`Content-Type`,
  `ETag`, `Content-Range`, `Allow` and the framing headers), and
  `Cache-Control`, which `--static-cache-control` sends on successes only.
  In Mojo, `StaticFiles(..., headers=...)` is the same; there, a name the
  response already carries is left as the response set it.
- **`M0_MAX_BODY` and `M0_BODY_TIMEOUT`, the environment forms of
  `--max-body` and `--body-timeout`** (SPEC C1, A23), read with the flags'
  own parsers (`8m`, `30`) and beaten by the flags. A container raises
  either without a start script.
- **The first refusal of each kind names its knob.** The first time a
  server answers 413 for a body over the cap, it prints one line naming
  `--max-body`, the cap in effect and `M0_MAX_BODY`. The first time it
  ends a body that stopped arriving, it prints the same for
  `--body-timeout`. Each line is printed once per event loop. The 413
  says only "Payload Too Large", and the application never sees the
  request, so until now nothing in any log said which setting refused an
  upload.
- **`docs/RUNNING.md`'s "Coming from uvicorn"**: the behaviour a uvicorn
  command line does not show, one line each, linking to where each is
  described: buffered and capped bodies, the body timer, the longer
  keep-alive, the access log off and in JSON, forwarded headers not
  applied, exit 1 for a failed lifespan startup, and ASGI refused on a
  free-threaded CPython. That refusal now says how to pin a GIL build
  with uv (`3.13` in `.python-version`); uv had picked 3.14t for
  franchise-assessment.

### Changed

- **`wyhash64` multiplies once** (the ETag hash in `m0-core`). Its mixer
  assembled the 128-bit product from four 32x32 partial products behind a
  note that Mojo exposed no `UInt128`; it does at the 1.1.0 pin, and the
  stdlib's own AHash folds a `UInt128` product the same way. The one
  widening multiply gives the same value for every input — the pinned
  vectors, every length to 300 and 20 million random pairs agree, so no
  served ETag moves — at about twice the throughput at every size, measured
  on an M-series Mac: 4.5 to 7.3 GB/s on 16 bytes, 11.6 to 22 GB/s on a
  megabyte. A 20-byte vector joins the pinned set, covering the word path
  between the short tail and the 32-byte block. `std.hashlib`'s AHash was
  measured beside it and is the slower of the two above 64 bytes; the
  ETag hash stays in `m0-core`, where its outputs are this repository's.
- **Short JSON strings are escaped a word at a time** (`m0-core`'s
  `escape_json_string_into`). After its last full 64-byte block a string
  was scanned byte by byte, so every string under 64 bytes took the scalar
  loop, and those are most of what it escapes: access-log fields, Datastar
  signal values, JSON reply fields. The tail is now scanned eight bytes per
  step as one 64-bit word, and skipped when the 64-byte blocks covered it.
  The output is byte-identical over 26,055 cases, every length to 300 in
  five shapes among them; measured on an M-series Mac, 8-byte strings run
  1.53x faster, 24-byte ones 1.56 to 1.85x, 64-byte strings with specials
  1.37x, and clean 64-byte strings 0.96x.

- **An SVG from a static mount is sandboxed** (SPEC J14). Its 200, 206
  and 304 carry `Content-Security-Policy: default-src 'none';
  style-src 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:;
  sandbox`. An SVG's `<script>` never runs in an `<img>`, but opened
  directly or framed it ran as the serving site, with its cookies and
  storage, in Chromium, Firefox and WebKit: a stored XSS wherever a mount
  serves an SVG the application did not write. Starlette and Django serve
  it the same way. With the policy the script cannot act as the site, and
  `<img>`, CSS backgrounds and `<use>` sprites draw as before (measured by
  pixels in all three; `poe browser-svg-sandbox`, pre-release). This
  applies to `StaticFiles` in a Mojo application too. An SVG meant as an
  interactive document with its own script stops scripting; a deployment
  that names its own `Content-Security-Policy` with `--static-header` has
  it on every static response in place of this one. `--doctor` reports
  the effective one as `static_svg_policy`.
- **`.md` is served as `text/markdown; charset=utf-8`**, not `text/plain`
  (RFC 7763). Agents such as Claude Code and Cursor ask for Markdown by
  that name (`Accept: text/markdown`), and the llms.txt convention names
  it for the pages it links. The docs site already advertised its
  Markdown twins as `text/markdown` and then served them as `text/plain`.
  `llms.txt` itself stays `text/plain`, which the convention also allows.

- **Every static response carries `X-Content-Type-Options: nosniff`**
  (SPEC J12), from m0serve's `--static` mounts and from `StaticFiles` in a
  Mojo application alike. The type always comes from the extension table,
  never from the bytes, so a browser has nothing to sniff. Fetch's check
  refuses only a script or a style whose type is not JavaScript or CSS,
  and the table types `.js`, `.mjs` and `.css` correctly. A
  `--static-header` naming the header replaces the value.
- **An `M0_*` value the environment cannot use is reported, not silently
  replaced.** The environment stays lenient: `M0_PORT=80eighty` still
  serves on the default port. But m0serve now prints one line at startup
  for each such value, naming the variable, its value and what was used
  instead. The lines are printed by the process that read the
  environment, so a spawned worker does not repeat them. This covers
  every variable m0serve reads as a number or a switch; a switch set to
  anything but `true`, `1`, `false` or `0` is reported as read off.
- **`--doctor` reports the limits the server would use**: `max_body`,
  `body_timeout`, `idle_timeout` and `max_keepalive_requests` under
  `server` are the effective values, defaults included, where an unset
  flag printed -1.

- **The access log's numbers are JSON numbers, and its time is the wall
  clock** (SPEC F20, F21). `status`, `dur_us` and `bytes` were strings, so
  `jq 'select(.status >= 500)'` matched every line: jq sorts strings after
  numbers. `ts`, a monotonic millisecond count from an arbitrary origin
  that ordered one process's lines and said nothing else, is replaced by
  `time`: RFC 3339 in UTC with milliseconds,
  `"time":"2026-10-04T17:02:51.789Z"`, which matches a line against an
  application's own log. A record now reads
  `{"time":…,"level":"INFO","msg":"access","method":"GET","path":"/","status":200,"dur_us":1234,"bytes":64,"remote_addr":"127.0.0.1"}`,
  and `docs/RUNNING.md` lists the fields. A consumer that parsed the
  quoted numbers, or read `ts`, needs a change. Nothing in this
  repository's own consumers or in the applications known to run on
  m0serve parsed either. The line also got cheaper. It is written on the
  event loop for every response, now straight into one buffer with the
  second's prefix cached per loop. That is about 170 ns a line, the
  wall-clock read included, against about 680 ns before, measured with
  the line built and not printed.

### Fixed

- **`--doctor` reports the static mounts as valid JSON**, escaped where
  they were concatenated raw, so a directory with a quote in its name
  broke the report. It now also reports `static_cache_control` and
  `static_headers`, the headers every static response carries.
- **An ASGI application whose lifespan startup fails no longer leaves a
  server that answers nothing** (SPEC L33). Under the asyncio executor,
  the ASGI default, the application is built and its lifespan started on
  the executor's own thread, and nothing waited for it: a
  `lifespan.startup.failed` was logged as `asgi-executor raised`, the ready
  banner had already printed, the loop went on accepting, requests hung
  with no bytes, `--health-path` answered 200, and SIGTERM exited 0. The
  server now waits for every executor's startup before it prints the
  banner, and a startup that fails exits 1 naming the application's
  message, as it already did under `--blocking-threads` (uvicorn exits 3).
  So the banner follows the lifespan startup in every mode; the
  `armed for a graceful stop` line still precedes it, and a SIGTERM or
  SIGINT while the startup runs ends the worker with exit 0. `--mount`'s
  ASGI applications, one executor each, are waited for alike, and
  `M0_INVERTED`'s banner and exit follow the same rule (a stop there
  still waits for the startup, which runs on the loop's own thread).
- **The access log's `bytes` is the response body as sent** (SPEC F2). It
  was the length of the encoded buffer: the head plus an in-memory body,
  and none of a body sent with `sendfile`. So a 64-byte body logged 366,
  and a `--static` file logged about the size of its own head. It now
  counts the body, a file body included, and nothing for a HEAD or a 304.
  That is what `log_access` named the value all along (`body_size`), and
  what gunicorn's and Apache's `%b` report. With
  `--metrics`, `http_bytes_sent_total` still counts head and body, and now
  includes file bodies, which it also left out.

## [1.10.0] — 2026-10-03

The database remembers what changed. `m0_sqlite`'s stamps put four
triggers on a table, after which every row written there, by any program,
carries the number of its last change, and "what changed since N" is one
statement; a process that derives data from the table keeps its place in
the same database, with its outputs. `m0_http.Feed` is a stream whose
event ids are those numbers: a reconnect is the application's query, not
a replay, fan-out is per subscriber from where it stands, and a delta
goes whole or waits. `apps/table_notes`' list is live on it, from either
loop, with one line of script on the page. The served contract is
unchanged; the `m0` wheel ships as `m0 0.6.0`.

### Added

- **`m0 0.6.0`: this release's framework, for applications built with
  `m0`.** What changed since `m0 0.5.0` for someone writing an
  application:
  - New: `install_stamps`, `watch`, `watched`, `stamp_head`, `stamp_of`,
    `stamp_floor`, `prune_stamps` (O26, O27), `cursor`, `advance` and
    `slowest_cursor` (O28) in `m0_sqlite`; `Feed` and `since_of` in
    `m0_http` (N51); `ViewState`'s three stream hooks and `tick`, each
    with a default, so a state that holds a stream forwards them (N51).
    `apps/table_notes` in the repository is stamps, a delta over a GET
    (N49) and the live list (N50) together.
  - What an application may have to change: nothing. A `ViewState` that
    already declared a method named `tick`, `sse_drain_slot`,
    `sse_is_streaming` or `sse_slot_disconnected` now has it called by
    `ViewsApp`.
  - Nothing an application built by `m0 0.5.0` must act on otherwise: the
    templates are unchanged, and `m0 doctor` names no scaffold file.

- **`m0-sqlite` stamps: the database remembers which rows changed**
  (SPEC O26, O27, N49, DECISIONS D63, D64;
  docs/notes/a-database-that-remembers-what-changed.md).
  `install_stamps(db)` and `watch(db, table)` put four triggers on a
  table, after which every row written there, by any program, has one
  entry in `m0_changes` holding the stamp of its last change, the stamp
  it was born at and whether it is gone. "What changed since N" is then
  one statement, and whoever asks keeps one number. `watched`,
  `stamp_head`, `stamp_of` (one table's clock), `stamp_floor` and
  `prune_stamps` are the rest. A watched single-row commit measured
  30 µs against 8.6 µs unwatched. What a stamp cannot see is pinned
  by tests: a REPLACE through a UNIQUE column needs
  `PRAGMA recursive_triggers = ON` on the writer, and a table rebuilt by
  a migration loses its triggers. `watch` refuses a table whose key is
  not its rowid.
- **A stage's place: `m0_cursors`, `cursor`, `advance`, `slowest_cursor`**
  (SPEC O28). A process or thread that derives data from a watched table
  records the last stamp it acted on in the transaction that writes its
  outputs, so a restart repeats nothing and skips nothing; lag and the
  safe prune point are queries.
- **`m0_http.Feed`: a stream whose event ids are the application's**
  (SPEC N51). Subscribers each stand at a number the application owns;
  a reconnect is the application's query, not a replay; fan-out is per
  subscriber from where it stands; a delta goes whole or waits, so a
  slow client gets merged events and never a gap. `ViewState` gains the
  three stream hooks and the tick, with defaults, forwarded by
  `ViewsApp`.
- **`apps/table_notes`' list is live** (SPEC N50): `GET /notes/events`
  from either loop, an eight-line script on the page (an `EventSource`
  and htmx 4's `htmx.swap`), the rows as out-of-band `<li>`s.
- **`apps/table_notes` answers `GET /notes/changes?since=N`**: the rows
  stamped above N as JSON, from either loop, with nothing kept for the
  client. `smoke-table-notes` holds it at one loop and at two.

## [1.9.0] — 2026-10-02

An application in Mojo can serve a table: `Views.resource` registers a
collection's routes, `m0_sqlite`'s `Connection.data_version()` says when
the data may have changed, and `Cached` with `conditional` keep a rendering
until it does and answer a client that holds it 304. A Mojo function can
run inside a SQLite query. `m0serve` and the Mojo host listen on IPv6. A
stream's socket carries TCP keepalive, so a client that vanished is reaped
where nothing is in flight. Under `--workers N`, five ways a connection or
a worker could be lost at a restart or a failure are closed, and m0-sqlite
and m0-postgres each keep to one image of their library. The application
layer's milestone is met: its first application outside the tree is
recorded. The served contract is unchanged. Names nothing in the tree used
left the packages the `m0` wheel ships, the Mojo HTTP client among them,
which matters only to an application that imported one; the `m0` wheel
ships as `m0 0.5.0`.

### Added

- **`m0 0.5.0`: this release's framework, for applications built with
  `m0`.** What changed since `m0 0.4.0` for someone writing an
  application:
  - New: `Views.resource` and the `RESOURCE_*` suffixes (N46), `Cached`
    and `conditional` (N47), `Connection.data_version()` (O25) and
    `Connection.create_function` (O19–O22), each below; `apps/table_notes`
    in the repository is the first three together. `--host ::` and
    `M0_HOST` take an IPv6 address (M29).
  - What an application may have to change: the names under Removed are
    gone from the packages the wheel ships — `m0_http.Client`,
    `RequestContext`, `check_api_key` and `AppConfig.api_key`,
    `ResponseCache`, `PatchJournal`, `negotiate_encoding`,
    `negotiate_language`, the free `wants_html` and `wants_event_stream`,
    m0-core's FNV-1a and xxHash32, m0-sqlite's `stats_ints` family, and a
    handful of upstream `lightbug_http` names. An application that
    imported one needs its own copy; none of the three templates did.
  - Nothing an application built by `m0 0.4.0` must act on otherwise: the
    templates are unchanged, and `m0 doctor` names no scaffold file.

- **A resource over a table** (SPEC N46–N48 and O25, DECISIONS D60–D62;
  docs/notes/a-resource-over-a-table.md), in three pieces an application
  joins:
  - `Views.resource(NOTES, list=, new=, create=, show=, edit=, update=,
    delete=)` registers a collection and its rows under one pattern, each
    view in the slot that says what it does. Every slot is optional.
    `update` answers `PUT /notes/:id` and `POST /notes/:id/edit`, because a
    plain form cannot PUT and posts to the URL it was served from.
    `RESOURCE_NEW`, `RESOURCE_ITEM` and `RESOURCE_EDIT` are the suffixes,
    for the constants given to `url_for`.
  - `m0_sqlite`'s `Connection.data_version()` is a change clock: a number
    that differs once another connection has committed a change to the
    file. Asked on a connection opened read-only beside the writer, it
    moves for this process's own commits too, so a cache keyed by it needs
    no commit hook and nothing a caller could forget to say. Ask it on the
    connection that renders, before rendering.
  - `Cached` keeps one rendering and the clock value it was made at, and
    `conditional(req, resp)` puts an `ETag` over the response's body and
    answers 304 to a GET or HEAD that names it. The tag is a hash of the
    bytes sent: a page and its fragment have two, and a commit to another
    table leaves both alone.

  `apps/table_notes` is the three together over a SQLite file: two loops
  under `M0_THREADS=2` each serve what the other wrote, with no lock held
  across a render and nothing shared but the file. `apps/fragment_notes`
  registers its notes through `resource`, its wire output unchanged.

- **Scalar SQL functions written in Mojo** (SPEC O19–O22, DECISIONS
  D58–D59). `Connection.create_function("dot", Dot())` registers a type
  conforming to `ScalarFunction` — `comptime arity` and `deterministic`,
  and a `call(mut self, args, answer)` — on that connection, and SQLite
  calls it from inside the query plan. The instance is the function's
  state: `call` may write its own fields, and what it writes is there for
  the next call. `Args.blob` is SQLite's own bytes, never a
  copy, so a kernel over a large column costs the kernel: a dot product
  over 100,000 384-float embeddings scanned them in 8.6 ms, one to three
  percent over the same function written by hand against the C API and
  twice as fast as sqlite-vec's `vec_distance_l2`, which copies both
  vectors on every call. A span from `Args.blob` stays good for the whole
  call: `Args.text` refuses a BLOB, since reading one as text can free or
  move its bytes. A raise fails the statement with its text, while the
  connection is open: on a statement stepped after its `Connection`'s last
  mention, where Mojo has already closed it, the error keeps its code and
  carries the code's own text ("SQL logic error"), as every error of such
  a statement does. Keep the connection mentioned past the step to get the
  function's text. The schema
  never computes with a registered function: SQLite refuses it in a CHECK
  constraint, a generated column or an index when they are created, in a
  stored view when it is used, in a trigger when it fires and in a column
  DEFAULT when an INSERT takes it. Creating a view, a trigger or a DEFAULT
  that names one is NOT refused, and such a trigger then fails every write
  to its table, from every program, until it is dropped; do not name a
  registered function in any of them. A library where that refusal is
  incomplete is refused: one older than 3.31.0 for every function, and one
  older than 3.50.0 for a function that says it is not deterministic,
  which until then a CHECK constraint could name and run. SQLite owns the instance
  from registration and destroys it when the function is replaced or the
  connection is destroyed — at `close()`, or, when a statement outlives the
  close, at that statement's finalize, the function answering until then.
  A call that arrives while one on the same instance is in progress — a
  function that steps a statement of its own connection which calls it —
  fails its statement with "a scalar function was called again while a
  call on it was in progress" and does not run: `call` takes `mut self`,
  and the inner call's writes were otherwise lost to the outer one,
  silently. The check costs about 0.6 ns a call.
  m0-sqlite registers no functions of its own.

- **IPv6** (SPEC M29). `m0serve --host ::` listens on IPv6 and IPv4 at
  once, and `--host ::1` on the IPv6 loopback alone; the same goes for the
  Mojo host's `M0_HOST` and `--host`, and for `Server.listen_and_serve` on
  `"[::]:8080"`. A host may be written in brackets, `[::1]`, as in a URL;
  `0.0.0.0`, `127.0.0.1` and `localhost` listen as before. A client is
  reported in its own family, in `REMOTE_ADDR`, ASGI's `scope["client"]`
  and the access log's new `remote_addr` field, and an IPv4 client of `::`
  is reported as IPv4 (`127.0.0.1`), not as `::ffff:127.0.0.1` as gunicorn
  and uvicorn report it, so moving a server from `0.0.0.0` to `::` changes
  no address your application sees. Until now no IPv6 address could be
  listened on at all. For a Fly.io application, `--host ::` is what makes
  it reachable on the private network's `.internal` addresses.
  `ListenConfig.listen` and `NoTLSListener` default to
  `NetworkType.tcp`, the family the address names; `Server.serve` takes a
  listener of any network.

- **Three rules of the event loop and of `--spawn-workers` that no gate
  held now each have one** (SPEC A23, L16, E35). None changes what the
  server does.
  - A body timer that expires on a connection no longer reading its body
    is deleted, not only skipped. On Linux an expiry left registered is
    reported by every wait after it, and the loop spins.
  - A WebSocket this side has closed keeps its two-second wait for the
    peer's Close while its last frames go out slowly. Each send that moves
    bytes would otherwise restart that wait as `--idle-timeout`.
  - CI serves `--workers 2 --spawn-workers` from a copy of m0serve under a
    directory named `josé`, the one shape that reaches the fix that lets a
    binary under a non-ASCII path re-exec itself.

### Changed

- **The application layer's milestone is met.** `unotes`, the layer's
  first application outside `apps/`, is recorded in
  `docs/REAL_APP_VALIDATION.md` against 1.8.0: 1,748,962 responses at two
  workers and 864,732 at two loops on threads, each compared byte for byte
  with the same binary's answer alone, 0 failures, through six restarts
  and 9,722 abandoned responses, with RSS flat. It is a dogfood
  application and the record says so.

- **The other six sabotage harnesses run on `scripts/sabotage_lib.py`**
  (`sabotage-blobs`, `-host`, `-notes-login`, `-m0-wheel`, `-scaffold` and
  `-mojo-image`): a SIGINT or SIGTERM mid-rule now puts every file back,
  ends the gate's process group, removes the scratch directory and dies by
  the signal, where it used to leave the sabotaged source in the tree.
  Every anchor must match exactly once, a sabotage that only breaks a build
  is a miss, and each gate must pass on the unsabotaged tree first.
  `sabotage-outbox-cap`'s give-up rule now breaks the claim alone.
- **`poe build-serve` skips the link when `bin/m0serve` is already
  current.** Every smoke that serves through m0serve builds it first, so a
  run of several smokes relinked an unchanged binary each time, 4 s on an
  Apple-silicon Mac and about 8.5 on a CI runner. The build now writes
  `bin/m0serve.stamp`, a digest of everything it read (its arguments, every
  source under its include roots, the `.mojoc` artifacts, the toolchain and
  what is installed beside it, the task itself and the scripts it runs) and
  of the binary and runtime it left, and a later call whose digests all
  match says `bin/m0serve is up to date` and stops, in under half a second.
  Any change, a missing binary or stamp, or a build that failed rebuilds;
  delete the stamp to force one. `poe check-serve-stamp` proves each input
  rebuilds.
- **`poe smoke-doctor` takes half as long.** To tell a configuration the
  server accepts from one it refuses, it waited a fixed 8 s for each of the
  seven that serve. It now polls until the server answers and allows it 2 s
  more, so a server that answers and then dies is still read as its exit
  code, and a new control row, an application that answers once and then
  exits 3, fails the smoke if the watchdog ever reads it as served. The
  task went from 70 s to 33 on an Apple-silicon Mac.
- **No gate binds a fixed port.** `sabotage-scaffold`,
  `sabotage-outbox-cap`, `autobahn`, the three browser checks and the
  executed quickstarts take a free port each run, so two runs on one
  machine no longer collide, and `poe check-task-shells` refuses a fixed
  port in any task but a `serve-*` one. `poe smoke-wheel` proves the
  installed m0serve runs on the runtime its wheel ships by asking the
  loader which file it loaded: it used to remove that runtime and let the
  loader abort the process, which on macOS wrote a crash report every run.
- **`poe autobahn` resumes a section, up to three times, when the container
  could not connect** (SPEC I13). The suite's client stops at the first case
  it cannot connect for and still reports success. Under colima that happens
  to about 1 connect in 300, whatever server answers, so one section-6 run
  in three was cut short and the run failed with no cause given.
  - When the client printed `Connection to ... failed` and the server still
    answers, the runner now runs the cases that section did not reach, on
    the same server, and says so. Each resume makes fewer connects than the
    attempt before it.
  - Across the attempts each of the section's cases must be scored exactly
    once. A thin section with any other cause fails the run, and so does
    one still thin after three resumes.
  - Every verdict any attempt scored is judged.
  - The client's output and the server's log are printed and kept under
    `bin/logs/autobahn/`.
- **Each m0serve worker says when a SIGTERM will drain it**:
  `[worker N] pid=P armed for a graceful stop`, the line the Mojo host's
  workers print, in every process shape, and before the `🔥 m0serve:`
  banner, which used to come first. A worker catches SIGTERM only once it
  has imported the application, so one worker answering says nothing of
  the others: a script that stops the server soon after starting it
  should wait for this line from every worker, or a worker still importing
  dies of the signal instead of draining.
- **`poe test-http` compiles m0-http's tests once, not once per file**,
  and `test-core`, `test-datastar` and `test-wsgi` do the same. Each task
  ran `mojo run` on every test file, and each run compiled the package from
  source again: `test-http` took 459 to 579 s of CI's cold `unit-tests` job
  on ubuntu, 7 s of it running tests. `scripts/mojo_suite.py` builds a
  package's test files as one program and runs it once per file, so each
  file still runs in a process of its own. Beside the build it checks each
  file on its own with `mojo doc`, so an error in code no test calls still
  fails the task. It prints each file's count of tests run beside the
  tests the file defines, and fails on any difference, a failing test, a
  death by signal, or a file that does not compile. Cold on a busy
  Apple-silicon Mac, `test-http` went from 390 s to 66-107 s.
  `poe sabotage-mojo-suite` breaks a small package ten ways and requires
  each to fail. To run one file, `mojo run` it as before.
- **CI installs the second libsqlite3 its one-image gates need on macOS,
  and those gates fail without it** (SPEC O22, O23). The tests that refuse
  a second image, and the sabotage that drops the pin's kept handle, need
  on macOS a libsqlite3 outside the dyld shared cache: Homebrew's. The
  runner image happened to carry one, which its software list does not
  promise. The macOS `unit-gates` leg and the nightly canary's now run
  `brew install sqlite`, and under `CI` `test_one_image.mojo` fails where
  it used to print that an arm was not exercised. On a developer's Mac
  without Homebrew's SQLite it still prints and passes.
- **`poe smoke-ramp` gates on the second-worst of its 24 samples, and
  says where the worst one spent its time** (SPEC N20). Each placement arm
  required the WORST of 24 `/x/now` samples under 100 ms, and a macOS
  runner stalls a single sample for 80 to 120 ms, twice in about 2,000.
  Over 40 green `Tests` runs the host's full-lane arm measured 2 ms at the
  median and 8 ms at most on macOS (1 ms at most on Ubuntu), the host's
  one-loader arm reached 79 ms once and m0serve's 42 ms, and then run
  36898942895 failed at 120 ms on a change that did not touch it, beside
  arms that measured 2 and 4 ms. A red `Smoke test one views module on
  two hosts` on macOS with one slow sample was that, and a rerun passed.
  - The three bounded arms now read `second_now_ms`, and the negative arm
    (the host with no lane) must still reach the bound by the same number.
    What the gate is for still fails it: with `/x/now` taken off the loop
    the second-worst sample was 132 to 194 ms in 13 runs of 13, since a
    request that waits for a pool thread is slow on many samples, not one.
  - Each result line carries `worst_now_ms` as before, `second_now_ms`,
    and `worst_connect_ms` and `worst_request_ms` for the worst sample,
    so the next stall says whether it was in the connect or in the
    request. A failure prints the whole line.
  - CI records the gated numbers against the limit
    (`ramp.second_now_ms.m0serve`, `ramp.second_now_ms.host`,
    `ramp.full_lane_second_now_ms.host`), keeps the worst samples under
    their names with no limit, and adds the worst sample's two parts for
    the host's full-lane arm. `ramp_probe.py selftest` runs first: one
    stall in 24 must pass, two must not.

- **`poe smoke-host` and `poe smoke-host-threads` gate their placement
  arms the same way** (SPEC E26, E27). `host_probe.py placement` printed
  the worst of 24 `/health` samples and nothing else, and
  `smoke-host-threads` failed on it twice on macOS on 2026-10-01, at 120
  to 190 ms, on changes that did not touch it. The probe now prints
  `worst_health_ms`, `second_health_ms`, `worst_connect_ms` and
  `worst_request_ms` through the function `ramp_probe.py` uses (now
  `probelib.placement_summary`), the pool arms require the second-worst
  under 100 ms and the bare-loop arm requires it to reach 100, and a
  failure prints the whole line. With the gate app's health path moved to
  a pool thread the second-worst was 141 ms, so the rule the arm guards
  is still caught. CI records `host.pool_second_health_ms` against the
  limit and keeps `host.pool_health_ms` without one.

- **A stream's socket has TCP keepalive on** (SPEC I32), so a client that
  vanishes from a quiet stream no longer holds its connection for as long
  as the server runs. A closed laptop or a dropped network sends no FIN,
  and a stream has no deadline; the server noticed such a client only when
  something sent to it went unanswered. That left out every stream with
  nothing in flight: an SSE stream an ASGI application writes itself (a
  Starlette `StreamingResponse`, FastHTML's `EventStream`) while it has
  nothing to send, a WSGI body streamed from a handler thread, and any
  stream once `M0_SSE_HEARTBEAT_MS` is `0`. Now the kernel probes a stream's
  client after 15 s of silence, every 15 s, and closes the connection at
  the third probe left unanswered, and the application is told its client
  has gone. Measured on Linux with a client whose packets were dropped: a
  quiet ASGI stream was still held 30 s later without it, and is closed
  61.5 s later with it (4.1 s with the setting at 1). The probes carry no
  data, so no stream's bytes change, and a client that is idle or reading
  slowly answers them and keeps its stream. `M0_STREAM_KEEPALIVE_S` sets
  the seconds, for the idle time and the interval alike; `0` turns it off.
  A stream the server heartbeats is reaped as before, when the heartbeat
  goes unanswered for as long as the kernel retries (about 16 minutes on
  Linux at its defaults): keepalive does not shorten that.

### Removed

- **The last upstream `lightbug_http` names nothing used**:
  `NetworkType.udp4` and `udp6`, the free functions `is_ip_protocol`,
  `is_ipv4` and `is_ipv6` (the `NetworkType` methods of those names stay),
  the `TCP4Socket` and `TCP6Socket` aliases, `O_ACCMODE`, and the argument
  `ConnectionState.reading_body` ignored. Nothing served changes; an
  application built with the `m0` wheel that named one needs its own copy.

- **Framework names nothing in the tree used**, from the packages the `m0`
  wheel ships (DECISIONS D54). Nothing served changes: `m0serve` and the
  Mojo host reached none of them, and `M0_API_KEY` was read into
  `AppConfig` and never checked, so no request was ever refused by it. An
  application built with the `m0` wheel (a `0.x` preview) that imported one
  of these needs its own copy: `m0_http.RequestContext`;
  `m0_http.check_api_key`, `AppConfig.api_key` and `M0_API_KEY`, whose
  capability, SPEC G9, is now `out of scope`; `m0_http.ResponseCache`;
  `m0_http.PatchJournal` and `JournalResult` (`DatastarStream`'s own replay
  journal stays); `negotiate_encoding`, `negotiate_language`, and the free
  functions `wants_html` and `wants_event_stream`, where
  `parse_accept(...).wants_html` is the same answer; and m0-core's
  FNV-1a and xxHash32 (`fnv1a`, `fnv1a_step`, `fnv1a_batch`, `xxhash32`,
  `xxhash32_batch`) with `format_hash32`. `libm0core` exports
  `m0_shared_fetch_add` alone, the call `m0pub` makes: `m0_fnv1a`,
  `m0_xxhash32` and `m0_format_hash` are gone.
  `m0_sqlite.stats_ints`, `sum_ints`, `min_ints`, `max_ints` and
  `ColumnStats` left the package, `stats_ints` living on in
  `bench_sqlite.mojo`, its one user; and `poe bench-core` went with the
  m0-core benchmark it ran, which no longer compiled.

- **The Mojo HTTP client, `m0_http.Client`**, with `poe smoke-client`
  (DECISIONS D55). No application called it, it spoke no TLS, and a call
  from a view on the loop blocked every connection the loop held. Nothing
  served changes. An application built with the `m0` wheel that used it
  needs its own; a client comes back as a design of its own that answers
  TLS and where the call runs. SPEC M14 is now `out of scope`.

- **The `libm0core` release assets.** Releases no longer attach
  `libm0core-linux-x86_64.so`, `libm0core-macos-arm64.dylib` or their
  `.tar.gz` bundles, and `poe bundle-ffi` went with them (DECISIONS D56).
  The library ships inside the m0serve wheel, where `m0pub` uses it to
  number the events it publishes, so nothing changes for an m0serve user.
  Releases up to and including 1.8.0 keep their assets.

### Fixed

- **m0-sqlite opens one copy of SQLite per process** (SPEC O23). On macOS
  with `M0_LIBSQLITE3` naming Homebrew's build, or any library file of its
  own, a process that closed all its connections and then opened another
  loaded a fresh copy of SQLite: the library was pinned with
  `RTLD_NODELETE`, which on macOS keeps an image mapped but forgets it once
  its last handle closes. Two copies on one database file is the corruption
  SQLite's documentation warns about — each keeps its own list of open
  files, so a close through one drops the locks the other holds — and here
  it took a statement outliving every connection while a new one opened the
  same file. The pin now keeps one handle open for the life of the process;
  Apple's library, in the dyld shared cache, and Linux were never affected
  by that. Two things change with it for every platform. **The first
  libsqlite3 a process opens is the only one m0-sqlite will open**: a
  library that is another image — `M0_LIBSQLITE3` changed mid-process, or
  a second path — is refused where it is opened, naming both files. And
  the library is opened `RTLD_LOCAL`, no longer in the loader's global
  scope, where on Ubuntu's build it captured the internal calls of any
  other libsqlite3 loaded later, which then could not open a database
  ("no such vfs"). **What this cannot cover is a copy m0-sqlite did not
  open.** CPython's `sqlite3` module carries its own SQLite in the
  interpreters uv installs, so inside `m0serve` a Mojo mount using
  m0-sqlite beside a Python application on the stdlib `sqlite3` backend is
  two copies of SQLite in one process: give each side its own database
  file.
- **m0-postgres maps each libpq it opens once, and keeps it out of the
  loader's global scope** (SPEC O24). On macOS,
  a process whose last connection closed and which then opened another
  loaded a fresh copy of libpq, and of the libraries it links, each time.
  The library was pinned with `RTLD_NODELETE`, which on macOS keeps an
  image mapped but forgets it once its last handle closes, so the next
  open could not find it: m0-sqlite's defect above, in the code it was
  copied from. Nothing faulted, and a result read after its connection
  still answered. The process grew by one mapping of libpq per reopen,
  which for a connection per request on one thread is one per request.
  The pin now keeps one handle open for the life of the process, and a
  later open of the same library is a comparison where it was a second
  `dlopen`. Linux was never affected by that. **On Linux the change is
  the scope**: libpq was opened in the loader's global scope, where it
  captured the internal calls of any other libpq build loaded later. With
  Ubuntu's libpq 16.15 loaded first and psycopg-binary's bundled 18.6
  second, 69 of the second's symbols bound into the first, and a
  connection attempt through the second's own handle crashed the process.
  A Python application on psycopg-binary beside a libpq loaded that way,
  which is the arrangement under `m0serve --pg-listen`, was captured too:
  it reported libpq 16.15, not its bundled 18.6 (measured under `m0serve`
  itself, where every query still answered and nothing crashed). Every handle is
  `RTLD_LOCAL` now, and the two libraries keep to themselves: psycopg
  reports its own 18.6. Unlike m0-sqlite, a second libpq file is not
  refused: each one a process opens is pinned once. A library that opens
  and is not libpq is no longer left mapped after it is refused.
- **A closed `Socket` refuses every call, not only `close()`** (SPEC D1).
  After `close()` a socket went on passing its old number to the kernel,
  so a late `send` wrote into whatever the process had opened on that
  number since, a `receive` took its bytes, a `shutdown` ended its
  connection, `bind`, `listen`, `connect` or a socket option acted on it,
  and `into_fd` gave it to an owner that would close it. `close()` now
  leaves the socket holding -1: those calls fail with EBADF, as they would
  on a number nobody holds, `shutdown` does nothing, and `into_fd` returns
  -1. Nothing in m0serve or the Mojo host uses a socket after closing it; a
  Mojo application that does no longer reaches another descriptor.
  `test_socket_close.mojo` gates each call. Found in review.
- **A thread busy with a WebSocket's messages at shutdown still stops.**
  When every thread of a lane was inside a view at SIGTERM while inbound
  WebSocket messages filled that lane, the stop signal for a thread that
  reads the lane directly could be refused for want of room and was
  dropped. That covers the asyncio executor, and pool threads under
  `M0_POOL_ELASTIC=0` or `M0_POOL_RING=0`. The thread finished its view,
  took the messages and waited for work for good: m0serve gave up on it
  after the 5 s join and exited naming a thread "still inside the
  application". The stop now waits for the lane to have room, inside that
  same 5 s.
- **A fast request that meets a busy handler thread no longer waits a
  millisecond for the loop to notice** (SPEC E37). With `--blocking-threads`,
  a Mojo mount or the Mojo host's `M0_BLOCKING_THREADS`, a request that
  arrives while one pool thread is inside a slow view wakes no second thread
  at once, because the busy one usually comes back first; the loop wakes a
  sibling once the request has waited long enough. At low traffic the loop
  checked that only once a millisecond, so such a request took about
  1.5 ms where 0.1 ms was the answer with no slow view in flight. The loop
  now waits exactly until the request's wait runs out (10 µs on a Mojo
  lane, 200 µs on a WSGI lane) and wakes the sibling then: measured on an
  Apple M4 at 0.10–0.14 ms on a Mojo pool and 0.43–0.56 ms on a WSGI pool,
  against 1.45–1.55 ms before. Throughput under load is unchanged. On Linux
  the shorter waits need `epoll_pwait2` (kernel 5.11 or later); an older
  kernel keeps the millisecond.
- **Under `--workers N` or `M0_WORKERS`, a worker that fails while the
  server stops makes the supervisor exit 1, whichever worker it reaps
  first** (SPEC D10). A worker catches SIGTERM only once it has started
  up — for m0serve, once the application is imported — and a stop that
  reaches one before then ends it at once. When that was the first worker
  the supervisor reaped, it passed the signal on and then waited for the
  rest without looking at how they exited: a sibling that crashed in its
  drain went unreported and the supervisor exited 0, and even a sibling's
  clean exit went unlogged. Each worker is now reported and judged as it
  exits, the same way under `--reload`. A worker the stop reached before
  it had started up is logged as stopped, not as a failure: it had not yet
  taken any request. Found when CI's shutdown smoke signalled a supervisor
  whose second worker was still starting.
- **Under `--workers N` or `M0_WORKERS`, no connection is handed to a
  worker that is still starting up** (SPEC E16). The worker that accepts a
  connection passes it to the least-loaded sibling, and a sibling still
  starting — for m0serve, still importing the application — looked idle,
  so it was handed connections it could not answer until its startup
  ended: with a worker held 3 s, 16 of a burst of 32 each waited the 3 s.
  A stop that reached that worker before it had started up ended it with
  those connections, closed unanswered while the server exited 0. A
  worker is now handed connections only once it serves; a respawned one
  is handed nothing until it has started again. Found in review.
- **Under `--workers N` or `M0_WORKERS`, no connection is handed to a
  worker that has died and was not replaced** (SPEC E16). The supervisor
  does not replace a worker once it is stopping, once it has used up its
  respawns (five crashes in a row, each within a second of its start, or
  ten times the worker count within an hour), or when the worker exited 0
  or 78.
  The worker's
  siblings went on reading the load it last published, which for one
  killed while idle read as idle with no connections, so the least-loaded
  choice handed it about half of every burst: accepted, and never
  answered until the whole server stopped. With `--workers 2` and worker 1
  killed until the supervisor stopped respawning it, 16 of a burst of 32
  went unanswered, under `--spawn-workers`, `--reload` and the Mojo host
  alike. The supervisor now marks every worker it reaps as gone, so no
  sibling picks it; a replacement is picked again once it has started.
  Found in review.
- **Under `--workers N` or `M0_WORKERS`, a long-running server goes on
  replacing workers that crash now and then** (SPEC E36). The supervisor
  stopped replacing crashed workers after ten times the worker count of
  crashes over its whole life, however far apart they were: at one crash a
  day on four workers, after about forty days. From then on each crash left
  the server one worker short, with no error, until none was left and it
  exited 1. The limit is now ten times the worker count within any hour,
  so a worker that keeps crashing is still given up on as soon as before,
  and the rule for a worker that cannot start (five crashes in a row, each
  within a second of its start) is unchanged. m0serve and the Mojo host
  share the supervisor; a `--reload` restart counts as no crash, as before.
  Found in review.
- **Under `--workers N` or `M0_WORKERS`, a connection handed to a worker
  just before it died is closed when the worker is not replaced** (SPEC
  E16). The worker that accepts a connection may pass it to a sibling, and
  one passed in the moment before that sibling died waited, accepted and
  unanswered, until the whole server stopped once the supervisor had used
  up its respawns. The supervisor now closes each such connection, so the
  client sees it close at once and can retry; none had been read. Found in
  review.
- **A `Socket` whose `close()` fails is closed all the same** (SPEC D1).
  A close that failed with anything but EBADF, such as EINTR from a signal
  or EIO, raised with the socket still holding its number, although the
  kernel had already released it; a second `close()`, or the socket's
  destructor, then closed whatever the process had opened on that number
  since, possibly another thread's connection. The failure is still
  raised, and the number is never closed twice. Nothing in m0serve or the
  Mojo host closes a socket twice; a Mojo application's own sockets are
  covered. Found in review.

## [1.8.0] — 2026-09-29

Most of this release is what a review of the whole tree found on
2026-09-28. A Mojo server no longer dies when a client leaves while it
writes: on macOS one visitor closing a tab ended any Mojo host application.
Every response head the server writes refuses CR, LF and NUL, not only the
gateway's. A POST's body timer no longer closes an idle connection 30 s
later, or hands a handler thread's answer to the next client;
`--body-timeout` sets it. Under `--workers N` a connection passed between
workers is no longer lost to a worker that is leaving, to one out of
descriptors, or on macOS to the kernel's collector of descriptors in
transit. On Linux a client's reset gives its slot back at once, a
keep-alive request costs no `epoll_ctl`, and a request in flight at SIGTERM
is answered. An ASGI application that installs asyncio's eager task factory
is answered, and an `M0_INVERTED` server exits on SIGTERM. Every listen
wrote its address into a stack buffer of zero bytes, and no longer does;
and a realtime hold never lets `M0-Channel` reach a client, and refuses a
channel in the server's reserved namespace, which a client could otherwise
use to aim a server write at another socket. The served contract is
unchanged; m0serve gains one flag. The fork loses about 4,400 lines that
nothing used or that the event loop replaced, its typed socket errors among
them, which matters only to an application that imports them. The `m0`
wheel ships as `m0 0.4.0`, whose `Login.from_env` refuses an unset
`PREFIX_SECURE`.

### Added

- **`m0 0.4.0`: this release's framework, for applications built with
  `m0`.** What changed since `m0 0.3.0` for someone writing an
  application:
  - What an application must act on: `Login.from_env` refuses an unset
    `PREFIX_SECURE` with exit 78 (N43, under Changed). An `auth` project
    from an earlier `m0` adds `APP_SECURE = "1"` to `deploy/fly.toml`'s
    `[env]` and `APP_SECURE=0` where it runs locally; `m0 new` now writes
    both (N45, under Fixed), and `m0 doctor` names the scaffold files an
    earlier `m0` wrote differently.
  - What an application that reaches into the fork or the storage libraries
    may have to change: `Server.serve` and `serve_nonblocking` take their
    listener with `^`, since the loop now closes it; a socket error is one
    `SysError`, and the per-errno types are gone; fork code nothing used is
    gone, the UDP path, the demo services and the blocking accept loop among
    it (under Removed); and `SqliteLib` and `PgLib` keep their entry points
    in `fns`, so `lib.errstr(rc)` becomes `lib.fns.errstr(rc)`.
  - A client that leaves no longer ends a Mojo server (A25): not the loop,
    not a supervisor under `M0_WORKERS`, and not the `make`, producer and
    pool threads that run before the loop. Every Mojo host application was
    exposed, `m0 new`'s among them.
  - A response head is safe from request data a view puts in it: a header
    carrying CR, LF or NUL is dropped for a Mojo view as it was for the
    gateway (G1, G2), `reply.redirect` percent-encodes a control byte, and a
    Datastar `redirect` refuses a `javascript:` or off-site location (I29).
    `redirect` and `page_or_fragment` send the standard reason phrase of
    every status that has one (under Changed).
  - `listen_and_serve` and `Server.serve` run the event loop, so SSE and
    WebSockets work through them. A POST's body timer no longer closes an
    idle keep-alive connection 30 s later (A23). A request with two `Host`
    lines is answered 400 (B10). A listen failure is reported in its own
    words, and a listen no longer writes its address into a stack buffer
    of zero bytes.
  - Under `M0_WORKERS`, a supervisor signalled while it forks passes the
    stop on (D2), and a connection passed between workers is no longer lost
    (E16). Under `M0_THREADS` on Linux, the Date header no longer mixes two
    seconds' fields.
  - Storage: `m0_sqlite`'s `INSERT ... SELECT` from `m0_array` inserted
    nothing since 0.3.0, and inserts again (O4). `m0_postgres` refuses a NUL
    in a `text()` parameter (O10), keeps a `Result` alive while `raw` reads
    it (O16), and connects with a URL that ends in `?` or `&` (O7); its
    binary mode reads like text mode for fewer types than O11 said.
  - `m0_core.json_parse` reads a number by JSON's grammar: `1.9` is not an
    integer, and `01` is not a number.

- **CI refuses the asyncio executor's state passed by value** (SPEC L31).
  Mojo 1.1.0 copies a `mut` argument of 256 bytes or less into the call and
  stores the copy back when it returns, which erased the two writes behind
  the `M0_INVERTED` server that never exited on SIGTERM and the eager task
  whose first-step answer was never sent (both under Fixed). `poe
  check-copyback`, part of `test-all`, reads m0serve's LLVM IR and fails if
  any function takes `ExecutorState` by value, or holds it inside an
  argument that is, and on every run first shows it can fail on a control
  written the way that code was. A sweep of every other struct the tree
  reaches through an address found none that anything writes while a call
  holds a copy (docs/notes/mut-arguments-and-raw-addresses.md).

### Changed

- **`m0`: `Login.from_env` refuses an unset `PREFIX_SECURE`** (SPEC N43),
  a change to the framework an application built with `m0` must act on.
  Whether the session cookie carries `Secure` is a fact about the
  deployment that the server cannot see behind a proxy, and read as off
  when unset it sent the cookie in clear on a visitor's first `http://`
  request, before any redirect to HTTPS. It is now stated, and a server
  without it exits 78 naming it: `1` wherever the application is served
  over HTTPS, `0` over plain http such as `http://localhost`. What an
  application does about it:
  - One made with `m0 new --template auth`: add `APP_SECURE = "1"` to
    `deploy/fly.toml`'s `[env]`, and `APP_SECURE=0` where it runs locally:
    the shell's `export`, `smoke.sh`, and the tests' `setenv`. A project
    `m0 new` writes now has all three (under Fixed), and `m0 doctor` names
    the scaffold files an earlier `m0` wrote differently.
  - Any other login: state `PREFIX_SECURE` in each environment that starts
    it, the deploy's included. `apps/fragment_notes` reads
    `M0_NOTES_SECURE`, and `serve-fragment-notes` defaults it to `0`.

- **`listen_and_serve` and `Server.serve` run the event loop, so SSE and
  WebSockets work through them.** They were a blocking accept loop of
  their own, the one README's WSGI example calls. It served one connection
  at a time: a second client waited behind a first that held its
  keep-alive connection idle, up to the 60-second idle timeout. It
  answered every SSE or WebSocket response with `409`. And it had missed
  fixes the event loop carries: an upload over the body limit had its
  connection reset under it after a few hundred KB, where the loop reads
  and discards the rest and the client reads its `413`. Both now delegate
  to `listen_and_serve_nonblocking` and `serve_nonblocking` with their
  defaults, and a `shutdown_read_fd` given to `Server` ends either
  gracefully. `m0serve` and the Mojo host never used them.
  `test_sigpipe.mojo` runs each until its closed shutdown pipe ends the
  loop, under a watchdog that fails the file rather than hang it. Found in
  review.

- **`m0_http.reply.reason_phrase` is the whole standard table: CPython
  3.13's `http.client.responses`, 62 codes.** `reply.mojo` kept two partial
  tables, 16 codes for `page_or_fragment` and the login and five for
  `redirect`, while m0-wsgi held the whole table for the ASGI path.
  `redirect`, `page_or_fragment`, the login's refusals and m0serve's answer
  to an ASGI application's integer status now read the one table, and the
  codes the small tables listed keep their phrases. A `page_or_fragment`
  status the old table did not list now carries its standard phrase
  instead of none, and `redirect` with a status other than 301, 302, 303,
  307 or 308 says what that status is (`201 Created`) rather than
  `Redirect`. An ASGI application's status goes out as before.
  `test_reply.mojo` holds the table.

- **`SqliteLib` and `PgLib` keep their C entry points in one table,
  `fns`**, which each `Statement` and `Result` copies whole (SPEC O16,
  O18). Code that called an entry point on the library itself now calls
  it on the table: `lib.errstr(rc)` becomes `lib.fns.errstr(rc)`. `path`,
  `open_library`, `PgLib.open`, `PgLib.libversion` and
  `PgLib.version_text` are unchanged, and code that goes through
  `Connection`, `Statement` and `Result` changes nothing.

- **A sabotage that does not compile is a miss, never a catch** (SPEC
  F17). `sabotage-pool`, `sabotage-trailers` and `sabotage-keepalive`
  counted any failure of their gate as the rule being guarded, so a
  sabotage that only broke the build passed as proof; `sabotage-fuzz` and
  `sabotage-outbox-cap` skipped one and still reported every rule guarded.
  All five now run on `scripts/sabotage_lib.py`. A catch needs the gate to
  have run: the `mojo` driver's last line names the phase that failed, and
  a timeout or a crash that prints nothing is settled by building the
  sabotaged source alone. An anchor must match exactly once
  (`sabotage-outbox-cap`'s give-up anchor matched twice and is
  re-pointed). A rule this platform cannot observe is reported `SKIPPED`
  and never counted as guarded. Ctrl-C or SIGTERM mid-run puts every file
  back, then ends the harness by that signal. Each task takes `--only` and
  `--skip`, and `sabotage-keepalive` now checks its unsabotaged probe
  first.

- **CI's jobs share one setup step and one measurement step.** Every job
  in `test.yml` set up uv, installed its Debian packages, and rendered and
  uploaded its measurements with its own copy of the same steps. Each now
  calls `.github/actions/setup` and `.github/actions/record-measurements`.
  `check-docs` reads an action as part of each job that calls it, so a job
  that stops calling the record action is still named. So is a
  `wheel-consume` job that reaches uv through the setup action, which by
  this repository's reference needs no checkout. Dependabot now reads the
  actions' own pins, which `directory: "/"` never did, and `check-docs`
  holds it to that. The check also compares the file a job's `M0_RESULTS`
  names with the file it uploads by whole name: `results.jsonl` used to
  pass as `ci-results.jsonl`.

- **CI's smokes are three jobs.** The `smoke` job had grown to a median of
  21.4 min on the ubuntu leg, against a 30-minute cap that a runner 1.45
  times slower, the slowest seen, would pass. It keeps the server's smokes
  and takes m0serve's command-line and `--doctor` smokes from
  `smoke-gateway`. A new job, `smoke-app-layer`, takes the Mojo host and
  its applications, the m0 wheel and its scaffold, and MAX's runtime under
  both hosts. By the step times of the 15 green runs of 2026-09-29, the
  three come to 12 to 13.5 min on ubuntu, and each is capped at 25.

- **`poe test-shim` proves each of the executor shim's rules with the test
  written for it** (SPEC L7). Its sabotage reverted each of 55 rules and
  ran all 59 tests against it, 3,304 runs, and took a rule as proven when
  any test failed, even one written for another rule. Each rule now names
  its test, only that runs, and a rule whose own test passes is unproven
  whatever else fails, with the tests that did fail listed so the fix is
  plain. The task took about 490 s on CI's ubuntu runner and 820 s on
  macOS, and takes 26 s and 33 s; the `unit-gates` job went from 20.1 and
  19.8 min to 12.7 and 9.4. Two rules whose tests no sabotage reverted
  gain one: a finished request releases its slot's state, and a socket's
  accept belongs to the socket, not its slot. `--sabotage-all` is the whole
  run, kept for re-deriving the tests when rules change, and `--selftest`,
  which the task runs first, shows on a real rule that a test that does
  not catch it, a test the suite does not list and a patch that does not
  apply each fail the run.

- **`poe test-shim` guards five more of the executor shim's rules, each a
  line whose removal failed no test** (SPEC L7). None changes what the
  server does: each rule now has a test written for it, and the sabotage
  reverts it.
  - `spawn` drops the slot's disconnect future before a request's task
    exists. Without that, a request parked in `receive()` on a slot
    recycled from a stream heard the stream's disconnect at once, and
    under Starlette's `StreamingResponse` the next client's stream ended
    as it began.
  - It drops it before `create_task`, not after. Under an eager task
    factory, a request parked in `receive()` in its first step otherwise
    lost its own disconnect future, and never heard its client leave.
  - A WebSocket's inbox belongs to its own task. Kept by slot, a socket
    whose client left while it was not in `receive()` passed that
    disconnect, close code and all, to the next socket on the slot.
  - A stream's send asks whether its client has gone before it reads the
    slot's credit state. Without that, a push to a stream whose client had
    gone, while the stream's task was still in a `finally`, raised
    `KeyError` once the slot's next request had finished and cleaned the
    slot, where it must be a quiet no-op.
  - A stream whose client leaves, and a socket, clean their slot's state
    when they finish. Without that, their credit windows, stream task and
    inbox stayed on the slot until its next connection.

- **CI's unit tests are two jobs.** `poe test-all` had grown to 34-35 min of
  its job's 40-minute cap on the ubuntu leg. It is now `build-all` and two
  halves, `poe test-packages` and `poe test-gates`, and CI runs each in a
  job of its own, `unit-tests` and `unit-gates`: about 20 min each on ubuntu
  at first, capped at 40. With `test-shim` down to seconds (above),
  `unit-tests` was then every run's longest job, 20.6 to 23.8 min cold on
  the ubuntu leg, against `unit-gates`' 12.6, so five tasks moved from `poe
  test-packages` to `poe test-gates`: the Datastar SDK's conformance and its
  sabotage, the probes' phase-stamp check, and m0-sqlite's tests and layout
  guard. Measured cold on the eight runs that followed, `unit-tests` ran
  10.4 to 17.5 min on ubuntu and `unit-gates` 13.3 to 17.6, the two about
  even on runners of the same CPU, and each is capped at 35. `poe
  test-all` still runs the whole locally, the same tasks as before, and
  `check-docs` refuses a task that
  `test-all` reaches and no CI step does. Both jobs keep Mojo's compile
  cache between a pull request's runs, which took a warm re-run of
  `unit-tests` from 20.7 min to 9.2.

- **Fifty-three probes share one library, `scripts/probelib.py`, every probe
  but one.** It holds the phase stamp, `fail()`, a server watched until it
  answers, a free port, an SSE reader and a WebSocket client, each proven by
  `python3 scripts/probelib.py --selftest` in CI, and `stamp()` takes two
  options for the probes that needed them: `fail_stream=`, for a failure
  line that goes to stderr while the crash line goes to stdout, and `echo=`,
  for a probe that announces each phase as it begins. Among the probes
  moved: the WebSocket and SSE clients of `smoke-chat`, `smoke-fastapi`, the
  Django and Flask realtime smokes, `smoke-idle-timeout`, `smoke-host`,
  `smoke-sim-loop` and `smoke-todo`; the raw-socket probes of
  `smoke-shutdown`, `smoke-pipelining`, `smoke-early-413`,
  `smoke-body-timeout` and the other HTTP/1.1 smokes; the response-head and
  chunked keep-alive probes of the WSGI and ASGI smokes; `smoke-ramp`'s and
  `probe-pool-fairness`'s; and two docker probes, and the `pid1` job's two.
  Each prints what it printed, on the stream it printed it on. Only
  `apps/ws_echo/ws_probe.py` stays inline, as `poe check-phase-stamps`'
  example of that form.
  - A server that exits before it answers is reported at once, with its log:
    `smoke-exec-inherit` and `smoke-child-publish` used to wait 120 s for
    one, `smoke-ws-inbound` and `smoke-slot-lifecycle` 30 s, and
    `stress-pool`'s two probes and the held server in `smoke-host-doctor`
    each polled for up to a minute.
  - `outbox_cap_probe.py` gives the connection one 20 s deadline, and the
    chat and realtime probes read a WebSocket against one deadline, where a
    per-read timeout was reset by every heartbeat. So
    `sabotage-outbox-cap`'s two rules that leave the connection open are
    caught by the probe's own verdict rather than by the harness killing it
    at 180 s.
  - `pool_fairness_probe.py` waits for its server through the library's
    `wait_healthy`: its own poller, answered with an empty body, asked again
    at once, about 10,700 times a second against a server that answers 101,
    where the library's asks 19.
  - `demo_probe.py` names a refused WebSocket upgrade; it used to die of
    `ValueError('too many values to unpack')`.
  - `poe check-phase-stamps` accepts a probe that takes its stamp from the
    library and holds the library to the crash handler's rules. It now
    judges the unsabotaged tree before any sabotage, and requires every rule
    to have a sabotage that the rule itself catches.

### Removed

- **Upstream `lightbug_http` code that nothing used**, about 870 lines of
  the fork, found by the 2026-09-28 review. None of it was reachable from
  `m0serve` or the application layer, but the `m0` wheel ships the fork's
  source, so an application importing one of these names directly needs
  its own copy: the UDP read path (`UDPConnection`, `Socket.receive_from`,
  `UDPSocket`, `UDP4Socket`, `UDPAddr`); `Socket.get_socket_option` and
  `get_timeout`; `htonl` and `ntohl`; twenty-two `SocketOption` members
  nothing set, several with OpenBSD's numbers and so wrong on macOS and
  Linux, and every `SocketType` but `SOCK_STREAM`; the
  `HTTPResponse.from_bytes(bytes, connection)` overload;
  `http_parse_headers`; `uri.Scheme`; the five demo services in
  `lightbug_http.service` (`Printer`, `Welcome`, `ExampleRouter`,
  `TechEmpowerRouter`, `Counter`), `Welcome` and `Counter` also exported
  from `lightbug_http` itself; `span_is_ascii`; `RequestBodyState`; and
  `ListenConfig`'s `keep_alive` argument, which was stored and never read.
  NOTICE lists each.

- **The fork's typed socket errors, replaced by one `SysError`**, about
  2,960 lines. Each function in `lightbug_http.c.socket` raised one of 109
  types, one per errno (`SendEAGAINError`, `BindEADDRINUSEError`, ...),
  through 14 variants (`SendError`, `AcceptError`, ...), and returned
  normally for an errno none of them named: `socket()` could hand back -1
  as a descriptor, and `listen()` on a connected socket reported success.
  Each now raises `lightbug_http.c.socket_error.SysError` whenever its
  call fails, naming the call and carrying its errno, with
  `would_block()`, `interrupted()`, `connection_aborted()` and
  `address_in_use()` for what the server asks of one. `m0serve` and the
  Mojo host serve as before, and a listener they cannot make is reported
  with the call and its errno, such as `bind: Can't assign requested
  address (errno 49)` on macOS. The `m0` wheel ships the fork's source, so
  an application that catches one of these types, or names one, needs to
  change: every per-errno type and variant; `FatalCloseError`,
  `SocketAcceptError`, `SocketConnectError`, `SocketRecvfromError`,
  `InvalidCloseErrorConversionError`, `CreateConnectionError`,
  `BindFailedError`, `SocketCreationError`, `ListenFailedError` and
  `ChunkedEncodingError`; `SocketGetsocknameError`, now `SocketNameError`;
  and `Socket.accept`, `NoTLSListener.accept` and the `accept` function,
  which nothing called (the event loop uses `accept_with_peer`). NOTICE
  lists each. Found in review.

- **The blocking accept loop's own code**, about 560 lines of the fork:
  `handle_connection`, `gate_streaming_response`, and
  `StreamingUnsupported`, the `409` it answered a stream with. The `m0`
  wheel ships the fork's source, so an application calling one of them
  directly needs its own copy; `listen_and_serve` and `Server.serve` stay,
  and run the event loop (under Changed). NOTICE lists each.

### Fixed

- **Listening no longer writes past the end of a stack buffer.** Every
  listen -- m0serve's, the Mojo host's, `Server.listen_and_serve` -- binds
  its socket through `inet_pton`, which converted the address into a
  buffer of zero bytes: it was counted in `c_void`s, and `c_void` is
  `NoneType`, whose size is 0. The four bytes of the address (sixteen for
  IPv6) landed on whatever the stack held beside it. What that damaged
  depends on how the compiler laid out the caller's frame: no crash is
  known in a released server, and a test build in review crashed in
  `ListenConfig.listen` with SIGSEGV. The buffer is now counted in bytes,
  and `poe check-zero-alloca` (in `test-all`) refuses a zero-size stack
  buffer that anything could write through, anywhere in m0serve. Found in
  review.

- **A client that leaves no longer kills a Mojo server** (SPEC A25). A
  built Mojo binary kept SIGPIPE's default action, which ends the
  process, and the kernel raises SIGPIPE when the server writes to a
  connection its client has reset: a visitor who closes the tab before
  the page comes back, a download abandoned halfway, an SSE subscriber
  going away. On macOS one such client ended a fresh server every time,
  with status 141. Every Mojo host application was exposed (`apps/blobs`,
  `fragment_notes`, anything `m0 new` scaffolds), as was a server built
  on `Server` directly. Under `M0_THREADS` the whole process went; under
  `M0_WORKERS` the supervisor respawned the worker, which read as churn.
  The event loop, which `Server.serve` now runs too (under Changed),
  ignores SIGPIPE before its first send, so the write fails and only that
  connection closes. m0serve's serving processes were not affected: the
  CPython they embed already ignores the signal. `smoke-host` sends a built
  server `kill -PIPE`, then a client that resets before its answer, on
  both CI legs.
- **Under asyncio's eager task factory, an ASGI stream is stopped when its
  client leaves** (SPEC L30). An application that installs
  `asyncio.eager_task_factory` runs each request's first step before the
  server has recorded which task serves the request, and a response that
  began streaming in that step was marked on the wrong task.
  - If an earlier request's task was still running on the same connection
    slot, the stream was marked on that task. That covers a keep-alive
    connection's previous request finishing its background work, and a
    connection that had just closed. The new client leaving then cancelled
    the other task, cutting the earlier request's background work short,
    and the stream ran on until the server shut down.
  - If the body came from a child task, as Starlette's `StreamingResponse`
    sends it, the stream was marked on the child. When the client left,
    the request was reported as failed after its response had begun.

- **A supervisor, and what an application runs before its loop, survive
  SIGPIPE too** (SPEC A25). The ignore above arrived with the event loop,
  which a supervisor never enters: m0serve's under `--workers` or
  `--reload`, and the Mojo host's under `M0_WORKERS`. `kill -PIPE` ended
  either with status 141 and left its workers serving, orphaned (measured
  on macOS). m0serve's supervisor forks before any Python call, so
  CPython's own ignore never reached it. A Mojo host application's `make`,
  producer and pool threads also run before the loop, so a write there to
  a peer that had gone ended the server before it served (one worker, or
  `M0_THREADS`), or killed worker 0 on every respawn (`M0_WORKERS`). The
  listener now ignores SIGPIPE first: both hosts bind before they fork or
  start a thread, so every process and thread they run inherits it.
  `smoke-host` sends the supervisor `kill -PIPE` and has a producer's
  `make` write to a closed pipe; `smoke-spawn-workers` sends m0serve's
  supervisor `kill -PIPE`.

- **A response header, reason phrase or `Set-Cookie` line carrying CR, LF
  or NUL is refused on every path, not only the gateway's** (SPEC G1, G2).
  The check lived in m0-wsgi, so a head built in Mojo -- a view's, the
  Mojo host's, a `--mount X=mojo` pool thread's -- was written
  uninspected, and a view that put request data in a header could end its
  own head and add headers, or a body, of its choosing:
  `reply.redirect(303, next)` with `next` from the query, which `unquote`
  has already decoded from `%0D%0A` to CRLF. The server's head writer now
  drops such a header or cookie line and sends such a reason phrase
  empty, for every response, as m0-wsgi did for an application's head. On
  an eight-header head the writer measured within about 10 ns of the old
  one.

- **`M0-Channel` no longer reaches a client, and a hold on a reserved
  channel is refused** (SPEC G18). Under `--realtime` the server consumes
  the `M0-Hold`/`M0-Channel` instruction headers before it holds a
  connection, but it returned early when `M0-Hold` was absent — so a
  response carrying only `M0-Channel` (a leftover header, or an `M0-Hold`
  the server dropped for carrying a control byte) sent that internal
  instruction header on to the client. `M0-Channel` is now stripped from
  every response, whether or not a hold is taken. And a hold whose
  `M0-Channel` names the reserved `\x01` control namespace is now served as
  an ordinary response rather than held, the same as a hold with no channel.
  That namespace is how the server addresses one connection's slot on its
  event loop, and every publish path already refuses it: an application that
  builds its channel from request data, such as a room name from a form
  field, in which `%01` decodes to that byte, could have let a client aim a
  server write at another client's socket. Applies to a WSGI view's hold, a
  Mojo mount's hold and `--mount PREFIX=hold`.

- **`reply.redirect` percent-encodes a control byte in its target** (SPEC
  G2). A target built from request data, such as
  `?next=%0D%0A...`, which `unquote` decodes to a real line break, carried
  the break into the response head, where it could end the header and
  start one of the request's choosing. Every C0 control byte and DEL in
  the target is now percent-encoded, as `url_for` encodes one, so the
  redirect still goes where the view meant; every other byte is written as
  given, so an ordinary target is unchanged. `test_reply.mojo` holds both,
  on the header and on the head's bytes.

- **A Datastar redirect no longer sends a location that runs script or
  leaves the site** (SPEC I29). `redirect` and `DatastarStream.redirect_to`
  assign the location to `window.location`, which runs a `javascript:` URL
  in the page's origin and follows `//evil.example` off the site; a
  `next=` parameter after a login is how either arrives. Both now raise
  unless the location is an `http`/`https` URL or a reference relative to
  the page (`/path`, `path`, `?query`, `#fragment`) that stays on its
  site. The location is read as the browser reads it, so the spellings a
  browser also takes for those are refused too: a leading space, a tab
  inside the scheme, the scheme in capitals, `/\evil.example`. A redirect
  off the site still goes out when it names its scheme. Found in review.

- **A `Set-Cookie` value's bytes above 0x7F reach the wire as the
  application gave them** (SPEC G17). Every other header goes out in
  ISO-8859-1, as PEP 3333 and RFC 9110 §5.5 have it, but cookie lines were
  written as UTF-8: a WSGI application's `caf\xe9` went out as
  `caf\xc3\xa9`, and an ASGI application's own bytes `caf\xc3\xa9` as the
  double-encoded `caf\xc3\x83\xc2\xa9`. Cookie lines now take the same
  latin-1 writer as every other header. A cookie that is all ASCII, as
  Django's and the session cookie `m0_http.session` builds are, is
  unchanged.

- **A request carrying two `Host` lines, or two `Transfer-Encoding`
  lines, is answered 400** (SPEC B10, B11). The parser kept the last line
  of a repeated field and served the request, so a proxy that routes on
  the first `Host` and an application that reads the last (Django's
  `HTTP_HOST`) disagreed about which site the request was for; RFC 9112
  §3.2 requires a 400 for more than one `Host` line in any request. Two
  `Transfer-Encoding: chunked` lines mean `chunked, chunked`, which was
  refused on one line and accepted on two. A second line of either is now
  refused whatever it says, as a second `Content-Length` line already was.

- **A POST no longer leaves a timer that closes its connection 30 seconds
  later, or sends a pool thread's answer to another connection** (SPEC
  A23). The body timer was armed for every request with a body and left
  running when the body arrived with the headers, as a small POST's does.
  When it fired it closed the connection whatever it was doing: an idle
  keep-alive connection was dropped, and one whose next request was on a
  `--blocking-threads` thread (a WSGI app gets them by default) had its
  slot released under that thread, so the next client to connect read the
  answer meant for the first. The timer is now armed only for a body still
  arriving, and acts only on one. `--body-timeout SECONDS` (default 30,
  0 = never) sets the deadline, and `--doctor` reports it. Two deadlines
  around it changed too (A4, A24): a request that starts late in the
  keep-alive window is no longer cut at the previous response's deadline,
  as an upload begun 7 s into a 10 s `--idle-timeout` was at 10.2 s; and a
  response the client stops reading is closed once `--idle-timeout` passes
  with no send making progress, where it used to hold its connection for
  good. A response read slowly but steadily is not affected.

- **A client that resets its connection no longer holds its slot on
  Linux** (SPEC C9). epoll reported a socket error as a failed
  registration, which the event loop skips, so a client's RST was never
  seen: a response stalled on a full socket, or a keep-alive connection
  sitting idle, kept its slot and descriptors for the life of the process
  unless `--idle-timeout` reaped it, and every graceful shutdown then
  waited out its full 5 s drain. The reset now closes the slot at once, as
  it always did on macOS. Two sends that stop part-way are finished too. A
  `--static` file whose response head the socket could not take at once is
  now sent after it (J10): the file was skipped, so a client pipelining
  requests read the next response's head where the body belonged. And a
  WebSocket ping or Close answered while the send buffer toward the client
  is full goes out whole once the socket drains (I31), where the reply was
  cut, misframing every frame after it, or dropped when refused whole.

- **A client that stops reading no longer keeps the event loop at a full
  core on macOS** (SPEC C10). A connection waiting for its client to take
  a response, or whose request was out on a handler thread or the ASGI
  executor, stayed registered for reads, and macOS reports an unread
  event on every wait: a client that half-closed, or sent its next
  request, and then stopped reading held the loop at 100% CPU for as long
  as the response waited or the view ran. Such a connection is not
  watched for reads until it can read again, on both platforms, and what
  the client sent is still answered then. With `--access-log`, a stream
  or WebSocket whose frames did not go out in a single send logged a
  record for each such frame, and a chunked stream one more at its end;
  `--metrics` counted each as a response. A stream is one record now,
  written when its head lands (F18). On Linux, a WebSocket whose incoming
  messages had been paused for the application could stop sending for
  good if the pause lifted while a frame was still going out. And a
  WebSocket the server closed itself, answering a message too large for
  the handler pool with 1009, could be held until the process exited when
  its client never answered the Close; it is closed after the 2 s linger.

- **A keep-alive request, and each read of an upload, no longer cost two
  `epoll_ctl` calls on Linux** (SPEC A13). Since 0.13.0 the event loop
  re-registered a connection's read interest after every read, of the
  headers and of a request body alike, which the kernel refused as already
  registered before accepting the modification behind it: two wasted system
  calls per request, the pair 0.4.0 had measured out of the hot path, and
  two per read of an upload arriving in pieces. Only a read that fills the
  buffer, or the client's EOF, now re-registers; the rest of a large request
  is still read at once, a 1 MB body sent at once is still read without a
  stall, and one the client cuts short with a half-close is still closed at
  once rather than at the body timeout. `smoke-large-request` counts the
  calls under `strace` on Linux: 4 over 2000 keep-alive requests, where the
  old loop made 4004, and 3 over 101 reads of a body sent in 100 pieces,
  where it made 201. macOS paid one `kevent` a request, and one a read, for
  the same reason, and no longer does.

- **On Linux, a connection that fails as it is accepted no longer holds
  up the ones queued behind it.** Linux's `accept` can return a network
  error already pending on the connection it takes off the queue, such as
  `EPROTO` or `EHOSTUNREACH`, and says to retry. The event loop stopped
  taking connections for that pass on `EPROTO` and `EOPNOTSUPP`, and the
  listener announces only new arrivals, so clients already queued waited
  for another connection to arrive; the six others reached it as a
  descriptor of -1, which it failed to admit and skipped, until the
  socket errors became one error (under Removed) and they stopped the pass
  too. All eight now cost only their own connection, as a client that
  gave up while queued always has. `test_socket_errors.mojo` holds the
  list. Found in review.

- **A request in flight when SIGTERM arrives is answered on Linux, not left
  to the drain's deadline** (SPEC D1). The event loop reads the stop as
  one of the events that are ready together, and it stopped handling that
  batch at the stop. On Linux each of the others is reported only once --
  a request's bytes, the answer a handler thread or the ASGI executor has
  just finished, a response's next write -- so one that came in beside
  the stop went unanswered, and the drain waited out its 5 s before the
  process exited. A request whose handler raised SIGTERM on the ASGI
  executor met it in 20 of 32 tries with the server on one CPU. On macOS
  the same could strand a response waiting to send the rest of itself,
  and the application's tick. The loop now handles the whole batch, and
  admits no new connection in it. `test_shutdown_pass.mojo` puts each
  kind of event behind the stop, on both platforms, and `smoke-asgi`
  repeats the request on Linux with the server pinned to one CPU. Found
  in review.

- **A server's listener is closed once, by its drain** (SPEC D1). The
  event loop closes its listener as the drain begins, and every owner of a
  listener closed it again once the loop returned: `Server.listen_and_serve`
  and `Server.serve`, the Mojo host, and m0serve with and without a
  handler pool, under `--spawn-workers` shutting the adopted listener down
  first. By then the number had been free for as long as the drain ran, and
  a new descriptor takes the lowest free number, so it had usually been
  given to something else -- in a Linux container, a `print` duplicating
  stdout on the loop thread, and the `.pyc` files pool threads were
  importing. The second close then failed, or closed a file or socket that
  was not the owner's; the Mojo host made it before joining its pool and
  producer, whose threads may still be working. The loop now owns the
  listener it is given and closes it once, an error on the way out
  included, and no owner keeps a copy. **A Mojo application that calls
  `Server.serve` or `serve_nonblocking` with its own listener passes it
  with `^`** (`server.serve(listener^, handler)`), since the loop closes
  it. `test_listener_owner.mojo` holds each owner's number past its return
  on both platforms, and `smoke-shutdown` traces m0serve's under strace on
  Linux. Found in review.

- **A closed `Socket` leaves its descriptor number alone** (SPEC D1). A
  socket made from a descriptor it was given (`Socket(fd=...)`) is born
  connected, and `close()` did not mark it otherwise, so destroying it
  after `close()` shut down whatever the process had opened on that number
  since -- a new descriptor takes the lowest free number -- and a second
  `close()` closed that descriptor outright. Nothing in m0serve or the Mojo
  host closes such a socket and keeps it since the listener fix above; a
  Mojo application that adopts a descriptor into a `Socket` could. `close()`
  now marks the socket unconnected, and does nothing on a socket already
  closed. `test_socket_close.mojo` gates both. Found in review.

- **The Date header is right with loops on threads on Linux.** Every event
  loop formats its own Date header, once a second, and did it through
  libc's `gmtime`, which on glibc returns one buffer for the whole
  process. A Mojo host application under `M0_THREADS`, or m0serve under
  `--threads`, runs its loops as threads of one process, so a loop could
  read fields another loop had just written, and at a day's or a year's
  boundary send a Date mixing two seconds' fields. The formatter now fills a
  buffer of its own (`gmtime_r`). macOS was not affected: its `gmtime`
  keeps a buffer per thread. Found in review.

- **A supervisor signalled while it is still starting its workers passes
  the signal on instead of dying and leaving them running** (SPEC D2).
  Under `--workers N`, and in a Mojo host application with `M0_WORKERS`
  above 1, the supervisor installed the handler that passes SIGTERM and
  SIGINT on to its workers only after it had forked the last one. A
  worker answers as soon as its loop starts, which can be before the next
  worker is forked, so a stop sent to the supervisor's PID alone in that
  moment (by a process manager or a deploy script, say, as soon as the
  server answered) took the default action: the supervisor died, no
  worker was signalled, and every worker already forked went on serving
  and holding the port. The supervisor now installs the handler before
  its first fork and signals each worker as soon as it has its PID; told
  to stop while forking, it forks no more workers and waits for the ones
  it has; and a worker the stop reaches before it has set up its own
  signals leaves at once rather than serving on. `smoke-shutdown` gates
  it by holding the supervisor between its first two forks and signalling
  it there, and the phase that caught it in CI, once in about a hundred
  runs, now also checks the supervisor's exit status and every process in
  the server's group rather than only the worker PIDs in the log. Found
  by CI.

- **A worker draining under `--workers N` on Linux no longer takes a
  connection for the listener** (SPEC D1). A worker's drain closes its
  reference to the shared listener, but on Linux epoll goes on watching a
  descriptor that another process still holds open, and the supervisor and
  every sibling hold the listener. So the draining worker kept waking for
  connections waiting for its siblings to accept them, and the next
  descriptor it opened took the listener's freed number. When that was a
  connection a sibling handed over during the drain, the rest of its
  request was read as
  activity on the listener and never answered: the client was reset when
  the drain's 5 s ran out (measured in a Linux container, with the
  hand-off delayed into the drain). The drain now stops watching the
  listener before it closes it, and forgets the number.
  `test_drain_listener.mojo` gates both steps, and on Linux the kernel's
  side. Found in review.

- **A connection accept sharing passes to a worker that is shutting down
  is answered** (SPEC E16, D1). Under `--workers N` the worker that
  accepts a connection may pass it to a lighter sibling. When that sibling
  was stopping on its own, as when one worker is sent SIGTERM, the
  connection could be lost two ways. A worker with nothing in flight exits
  within about 50 ms, and a connection passed to it just after it had
  checked for them waited in a channel nobody would read again: its client
  got no answer, and was reset only when the whole server stopped. A
  connection that reached a stopping worker before its client had sent a
  byte was closed within 2 ms as idle, and its client read EOF. Now the
  worker passing a connection checks again, after counting it, whether
  its sibling has begun to stop, and keeps the connection if it has; a
  stopping worker waits, within its 5 s drain, for any connection counted
  to it; and a stopping worker passes what it receives on to a sibling
  that is still serving, keeping it only when every sibling is stopping.
  A worker restarted after a crash no longer inherits the count of
  connections that died with its predecessor. That count made its
  siblings pass it fewer connections for the rest of the server's life,
  and with the wait above it would have held each of its shutdowns, and
  each `--reload`, to the full 5 s. Both losses were reproduced on Linux
  and macOS with the hand-off delayed on purpose.
  `test_handoff_leaving.mojo` forces each order of events. Found in
  review.

- **Under `--workers N` on macOS, a connection passed between workers is
  no longer lost when another process closes a local socket** (SPEC E16).
  Accept sharing passes a new connection to a less busy worker over a
  Unix-domain socket. macOS's kernel runs a collector of descriptors in
  transit whenever any process on the Mac closes a Unix-domain socket, and
  it flushed every passed connection it found in transit: the request the
  client had sent was thrown away, and the worker that received the
  connection read nothing and closed it, so the client got an empty reply
  or a reset. With one other process opening and closing Unix-domain
  sockets, 179 of 1,600 requests made in bursts of 32 against
  `--workers 2` failed this way, about half of the 361 passed between
  workers; none fail now. The server now holds each worker's channel in a
  way the collector follows. Linux was never affected. Found in review,
  when the macOS CI runner failed two accept-sharing tests.

- **`--workers N` no longer lets a worker's load read one connection
  high for good** (SPEC E16). Since 0.18.0 the worker that passes a
  connection to a sibling counted it in flight only after sending it, so
  a sibling that admitted it and finished its pass first found nothing to
  retire, and the late count then stayed: that worker looked one
  connection busier than it was to every accept after. The count now goes
  up before the send, and back down if the send fails.

- **Under `--workers N`, a worker at its open-file limit no longer
  strands the connections passed to it** (SPEC E16). A connection one
  worker accepts and passes to a sibling travels as a descriptor, and a
  sibling with no descriptor free cannot take it: the kernel closes that
  connection and delivers the message without it, on Linux at once and on
  macOS after one failed receive. The sibling read that as an empty
  channel and stopped admitting, and the channel only announces new
  arrivals, so the connections queued behind it waited, their clients
  connected and unanswered, until another connection was passed to that
  worker; and the lost one stayed counted as in flight to it, so every
  accept after read that worker as a connection busier than it was. It now
  skips the lost one, admits the rest and retires its count.
  `test_accept_share.mojo` gates it. Found in review.

- **A malformed accept-sharing hand-off no longer leaks its connection**
  (SPEC E16). `recv_fd` refuses a message whose control data was cut
  short, and its check never saw one. Linux's `MSG_CTRUNC` is 0x08, and
  the 0x20 it tested there is `MSG_TRUNC`, set when the payload is cut
  short. macOS's `struct msghdr` is 48 bytes, not the 56 assumed, so its
  flags were read from a word the kernel never writes. A refused message
  also closed nothing, though the kernel installs each passed descriptor
  as the message arrives. So on Linux a hand-off whose payload was cut
  short lost its connection, left open for the life of the worker with
  its client waiting, and on both platforms a message carrying extra
  descriptors was taken in part, the rest left open. Neither shape comes
  from the server's own `send_fd`, which passes one descriptor and a
  payload that fits. The flags are now read where each kernel writes
  them, a truncated control message is refused with every descriptor it
  delivered closed, and a payload cut short keeps its descriptor.
  `test_accept_share.mojo` sends both shapes and checks that nothing is
  left open.

- **`--spawn-workers` works for a binary installed under a path that is
  not ASCII** (SPEC E35). The running binary's path was rebuilt a byte at
  a time as characters, so each byte above 0x7F became two: under
  `/Users/josé/` every worker's exec failed with "No such file or
  directory" and m0serve refused to serve (exit 78). The path is now the
  bytes the operating system returned.

- **An `M0_INVERTED=1` server exits on SIGTERM wherever the signal lands**
  (SPEC L8). Under the loop inversion a SIGTERM is read by whichever pass
  of the event loop reaches the shutdown pipe first. When that was the pass
  a completion flush runs, the drain began -- the listener closed, streams
  told goodbye -- and was then lost: the flush had taken the executor's
  state as a copy before its pass and stored the copy back after it, so
  the record that the drain had begun was erased, no later pass saw the
  stop, and the process served nothing and never exited; `docker stop`
  ended it with SIGKILL. CI's macOS runners met it in about 2 of 100 runs
  of `smoke-asgi`'s live-stream shutdown. The state is now read by address
  after the pass, and a flush that began the drain says so and the drain
  starts at once, not at the next event or the 1 Hz tick. `smoke-asgi`
  gates it with a request that raises SIGTERM in its first step, which
  puts the signal in the flush's pass every time; `poe test-shim` holds the
  shim's half.

- **An ASGI application that installs asyncio's eager task factory is
  answered** (SPEC L30). With `asyncio.eager_task_factory` a task's first
  step runs inside `create_task`, and a response the application sent
  there, before its first await, was never answered: the executor parked
  its completion while still inside the job that spawned the task, and
  that job held the executor's state as a copy and stored it back as it
  returned, erasing the completion. Every request answered that way hung
  until the client gave up, on the default executor and under
  `M0_INVERTED` alike, in any application whose lifespan startup calls
  `set_task_factory(asyncio.eager_task_factory)`. The same cause as the
  entry above, found while fixing it; `smoke-asgi` now runs the bare app
  with the eager factory installed.

- **Under asyncio's eager task factory, an ASGI stream is stopped when its
  client leaves** (SPEC L30). An application that installs
  `asyncio.eager_task_factory` runs each request's first step before the
  server has recorded which task serves the request, and a response that
  began streaming in that step was marked on the wrong task.
  - If an earlier request's task was still running on the same connection
    slot, the stream was marked on that task. That covers a keep-alive
    connection's previous request finishing its background work, and a
    connection that had just closed. The new client leaving then cancelled
    the other task, cutting the earlier request's background work short,
    and the stream ran on until the server shut down.
  - If the body came from a child task, as Starlette's `StreamingResponse`
    sends it, the stream was marked on the child. When the client left,
    the request was reported as failed after its response had begun.

  A stream is now marked on its own request's task. `poe test-shim` holds
  both shapes.

- **Under `M0_INVERTED=1`, a connection that arrives beside a streamed
  response is answered** (SPEC L32). With the loop inversion and an eager
  task factory, a task's first step runs inside the event-loop pass that
  read its request, and a stream that sends many small pieces there fills
  the executor's chunk channel. The executor made room by running a pass
  of its own, inside the first one, and its wait overwrote the events the
  first pass had read and not yet reached. A new connection read in the
  same batch was not accepted until another one arrived. On Linux, a
  request on a keep-alive connection in that batch was never read, and its
  client waited for its own timeout. A full channel is now handed to the
  loop in order, as the pass would have handed it, and a pass never runs
  inside another. `smoke-asgi` builds that batch on every run under the
  inversion.

- **m0serve reads a command-line argument that is not UTF-8 instead of
  crashing on it.** It cut `--name=value`, the positional `MODULE:ATTR`,
  and the `PREFIX=` of `--static` and `--mount` with a slice that asserts
  a UTF-8 character boundary, so an argument whose byte after the `=` or
  `:` continued a multi-byte character -- a directory name in a legacy
  encoding, say -- stopped the process on an assertion instead of serving
  it or printing a usage error. m0serve now reads its command line by
  bytes, with the same reader a Mojo host application uses, which already
  did; the two refuse the same malformed lines in the same words.
  `test_cli.mojo` gates each of the four. Found in review.

- **m0serve refuses more than 126 mounts before it binds, and `--doctor`
  says so too.** Each mount is a lane of the loop's handler pool, which has
  room for 126. With a 127th, m0serve bound the port, imported every
  application and then exited 1 on a bare `Unhandled exception` line,
  while `--doctor` reported the same configuration as fine. Both now exit
  78 at once, naming the limit. The limit applies whatever
  `--blocking-threads` is set to, because a single ASGI mount among them
  puts the whole set on the pool. `--doctor` now reads the same ordered
  list of checks the server refuses by, so the two cannot disagree about
  which refusal comes first, and it lists every check it made, passing
  ones included. `smoke-doctor` gates both, and a handler pool
  also refuses a 127th mount's lane rather than writing past the end of
  its wake block. Found in review.

- **An inbound WebSocket message reaches the mount that approved the
  socket when mounts are served inline** (SPEC I12). Under `--realtime`
  with several WSGI mounts and no handler pool — `--workers N` without
  `--blocking-threads`, or `--blocking-threads 0` — one handler serves
  every mount, and it delivered each inbound message, the synthetic
  `/ws/message` POST, to the FIRST mount's application at the first
  mount's prefix, whichever mount's view had approved the upgrade. The
  handler now records, per held socket, the application that approved it,
  and delivers the message there at that mount's prefix, as a handler pool
  already did per lane. `smoke-django-realtime-ws` gates it with two WSGI
  mounts served inline: each socket's message must reach its own mount's
  view with that mount's `SCRIPT_NAME`, and a POST to either mount's
  `/ws/message` from the network must be a 404. Found in review.

- **`--mount PREFIX=MODULE` reports an application that raises on import,
  as the positional spec does, and never serves the next convention in its
  place.** Discovery tries `MODULE`, `MODULE.asgi`, `MODULE.wsgi`, and
  more; a candidate that exists and raises on import is the answer, and the
  positional spec exits 1 with its traceback. A mount went through a copy
  of that resolver without the rule: with `proj.asgi` raising, `--mount
  /=proj` reported the first candidate's one-line miss, or, if `proj.wsgi`
  imported, silently served it — and `--doctor` called that healthy. Both
  now resolve through one function. `smoke-serve` gates it with a package
  whose `asgi.py` raises beside a `wsgi.py` that imports: the positional
  spec, the mount and the doctor must each exit 1 with the traceback.
  Found in review.

- **A WSGI body a handler thread would have streamed is closed when its
  response head cannot be built.** A generator or other lazily produced
  body with no `Content-Length` streams from a `--blocking-threads`
  thread, and a malformed header on it — a value or a name that is not a
  `str` — made the request a 500 without calling the body's `close()`,
  which PEP 3333 requires however a response ends. Django hangs its
  `request_finished` cleanup on that call. Both now close the body once
  before the 500. `smoke-wsgi-stream` gates both, counting `close()`
  calls. Found in review.

- **m0serve reports a listen failure in its own words, and waits out only
  an address in use.** Every failure to bind was retried for five seconds
  and then reported as `address already in use`: a `--host` that is not an
  address of this machine said the port was taken. Now only an address in
  use is retried — a restart racing the previous server's drain still
  succeeds — and anything else exits 1 at once, naming the address and the
  system's reason (`cannot listen on 192.0.2.1:8080: ... Can't assign
  requested address`). The Mojo host and every other `ListenConfig` caller
  get the same rule. `smoke-serve` gates it with an address that is not on
  the machine. Found in review.

- **An `INSERT ... SELECT` from `m0_array` no longer inserts nothing**
  (SPEC O4). Since 1.7.0 (and `m0 0.3.0`) the pointer-type tag bound with
  an array was a buffer freed as the bind returned. SQLite keeps that
  pointer and compares against it when the statement steps, so once the
  freed block was reused the scan found no array: the statement inserted
  0 rows and raised nothing. The public helpers step straight after
  binding, and the scan's own copy of the tag usually took the freed block
  back and wrote the same bytes into it, which hid it from every test; any
  allocation in between that took the block emptied the scan. The tag is
  the literal's static storage again, at the bind and at the lookup.
  `test_vtab.mojo` now fills the heap between the bind and the step: 0 of
  100 rows arrived in 30 runs of 30 on the 1.7.0 code.

- **A NUL inside a `text()` parameter is refused instead of matching the
  value cut short at it** (SPEC O10). libpq reads a text-format parameter
  with `strlen`, whatever length it is handed, so `admin`, a NUL and `x`
  was bound as `admin` and matched the `admin` row. `Params.text` now sends
  binary, framed by its length, and Postgres refuses the NUL with SQLSTATE
  22021 (`CHARACTER_NOT_IN_REPERTOIRE`, now exported). What libpq takes
  only as a C string is refused before the call, under the same state:
  SQL text, a statement name, a name `quote_identifier` quotes, a
  connection string, and `Params.literal`, which stays text so the server
  can type it and so now raises. Where a statement was prepared with
  `OID_UNKNOWN` and the server typed that position as something other
  than text, give it `literal()`, not `text()`: a binary value is read in
  that type's binary form.

- **`Result.raw` keeps its result alive while its bytes are read** (SPEC
  O16). The span it returned had an untracked origin, so a result whose
  last mention was the `raw` call was cleared on that line, and the span
  read freed memory: measured as the next query's value. The span now
  borrows the result, and the compiler keeps the result until the span's
  last use. No caller changes.

- **A connection URL ending in `?` or `&` connects** (SPEC O7). `open`
  and `open_readonly` add their defaults as query parameters, and they
  added a second separator to a URL that already ended in one: `...?`
  became `...??connect_timeout=5`, which libpq reads as a keyword named
  `?connect_timeout`, and `...&` became `...&&`, an empty keyword. libpq
  refused both before connecting, with a message about percent-encoding a
  password.

- **The capability sheet said m0-postgres's binary results read like its
  text results for every type** (SPEC O11). They do not for `timestamp`,
  `timestamptz`, `bytea` and `float4`, nor for a `float8`'s text. In
  binary mode a timestamp's `text()` is microseconds from 2000-01-01
  rather than a date, a `bytea`'s is its raw bytes rather than the `\x`
  escape, and a `float4` reads `0.10000000149011612` where text mode reads
  `0.1`. O11 now names the types that agree, and a Known issue records
  what each mode returns and what a fix needs. `Result.text()`'s own
  documentation made the same claim, and now names the same types. Read
  those types in text mode, which is the default.

- **The `auth` scaffold's session cookie is `Secure` once deployed** (SPEC
  N45). Its `deploy/fly.toml` forces HTTPS but never told the login so,
  and the login read the silence as off: a visit to the `http://` URL sent
  the session cookie in clear before Fly's redirect, and a stateless
  cookie copied there works until it expires. Every template's `fly.toml`
  now states `APP_SECURE = "1"`. The image states nothing, so a platform
  that says nothing is refused rather than served in clear. `m0 new`
  prints `APP_SECURE=0` in its `export` for `http://localhost`, where a
  browser need not keep a `Secure` cookie, and the template's `smoke.sh`
  and tests set `0`. `deploy/README.md` names the two secrets a login
  needs on Fly and what a local `docker run` passes. `smoke-scaffold`
  signs in to the binary under the written `fly.toml`'s `[env]` alone and
  requires a `Secure` cookie, and `sabotage-scaffold` removes the line
  and sets it to `0`.

- **`m0_core.json_parse` reads a number by JSON's grammar.**
  `parse_json_int` returned a number's leading digits, so `1.9` and `1e3`
  read as 1, against its own contract of `None` for a value that is not
  an integer. It and `parse_json_number` also read `01` as 1, and
  `parse_json_number` read `12abc` as 12, `1.5.3` as 1.5 and took `.5`
  and `1.`. Both now return `None` for a value JSON does not parse as a
  number: a zero before other digits, a `.` or an exponent with no digit
  after it, and anything after the number but whitespace, `,`, `}`, `]`
  or the end of the body. `parse_json_int` still refuses a fraction or an
  exponent, which `parse_json_number` reads. A body that relied on the
  lenient reading now gets `None`. Found in review.

- **The docs gate is one list, and CI's coverage checks no longer take a
  comment for a gate.** The required `Docs` check and `poe check-docs` now
  run one script, `scripts/docs_gate.sh` (about 5 s): each used to skip
  checks the other ran, and neither ran the milestone rot gates, which a
  pull request touching only `docs/` could break unseen. The checks that
  every smoke and test task runs in CI, and that each SPEC row's gate
  declares its coverage, counted a task, a `--covers` declaration or a dev
  dependency named only in a comment in `test.yml` or `pyproject.toml`; they
  now read both files as they run. Each CI job must also render and upload
  its own measurements: the postgres job's summary had been empty since the
  job was added, rendered with a flag `emit.py` does not have, while the
  check counted the other jobs' renders as its.

- **Every CI job keeps the coverage its gates declare, and the release
  workflow's cleanliness check reads steps, not comments.** The unit-tests
  and aarch64 wheel jobs ran their `emit.py --covers` declarations with
  nowhere to record them, because the check that each job collects counted
  measurements only; both now record, render and upload like the rest, and
  `emit.py --selftest` no longer writes into, or fails under, the results
  file of the job running it. Each `wheel-consume` job must assert its own
  cleanliness in a step that runs, where the phrase in a comment used to
  pass. `sabotage-spec` no longer reports a working rule MISSED when the
  first test file carries extra coverage, and `test.yml` no longer runs the
  milestone rot gates a second time beside the docs gate.

- **Sixty-nine smokes no longer bind a fixed port or write into the
  checkout, and no task re-syncs the venv it runs in.** They source
  `scripts/smoke/lib.sh`, among them the WSGI and ASGI gateway's, the CLI's
  and the execution modes', the Mojo host's and the Mojo layer's, the Mojo
  mounts', and the wheels' and the scaffold's. Each server takes a free
  port, where fourteen of them shared 8080 and 8099 was four tasks', so they
  run beside each other and beside anything else on the machine, and none
  now fails, or is answered by another server, because something else holds
  its port (`smoke-wheel` refused to run at all while anything listened on
  8129). `free_port N` finds N ports in a row, for the probes that serve one
  shape per port. A smoke's logs go to a temporary directory that is kept,
  and uploaded by CI, only when the smoke fails, and `.gitignore` drops the
  seventeen scratch files the smokes no longer write into the checkout. A
  server that dies while starting is reported at once with its log, where
  the smoke retried for a minute first. Cleanup stops the server's whole
  process group and waits for it, where it signalled one pid and could leave
  a supervisor's workers running; a probe that starts servers of its own
  runs in one process group with them, so a server it leaves behind is
  stopped with it; and an interrupted smoke no longer waits on a server that
  ignores TERM: the interrupt reaches the `ps` the cleanup asks whether the
  server is alive, and the empty answer was read as "exited", so the cleanup
  waited on the server for as long as it lived. Ten tasks could run a nested
  `uv run poe` (three on every run, seven to build something missing), which
  re-syncs the environment the task runs in, swapping packages under
  anything else using it and undoing `nightly-try` or `py314t-try`; they
  pass `--no-sync`, or take the build as a poe dependency. A new step on the
  Linux leg, `poe check-task-shells`, parses every task under dash and
  refuses such a call.

## [1.7.0] — 2026-09-27

MAX's parallel runtime does not survive a fork, so the Mojo host and
m0serve now refuse a forked worker in a binary that links it and name the
mode that serves it, and loops on threads are the documented way to more
than one core. m0serve's refusal reaches only a Mojo mount built against
MAX; the published wheel is built without it, so the served contract is
unchanged. `m0-sqlite` opens libsqlite3 at run time, and no binary in the
tree links it. Two defects the last pre-release run found are fixed: a
burst of new connections held the loop away from the connections it was
serving, and a pool thread starved for the GIL under a CPU-bound view. The
`m0` wheel ships as `m0 0.3.0`, with a login in the layer, an `auth`
scaffold template written on it, the storage packages, and a doctor that
names what an upgrade changed.

### Added

- **`m0 0.3.0`: this release's framework, for applications built with
  `m0`.** What changed since `m0 0.2.0` for someone writing an
  application:
  - New: `m0 new NAME --template auth`, a `views` list behind a login, and
    `m0_http.login`, the module it is written on (N43–N45, below). A swap
    sends a request header with `header=RequestHeader(...)`, written as
    `hx-headers` by `Htmx` and refused by `Datastar`. That is how a DELETE
    carries its CSRF token under htmx 4, and `csrf_header` builds that
    header.
  - `m0_sqlite` and `m0_postgres` ship in the wheel and link nothing
    (N39). The `live` template keeps its kick count in SQLite, and its
    image installs `libsqlite3-0` (N40). `max-core` is a pinned companion,
    and `m0 doctor`'s new `max-gated` check refuses any other version
    (N41).
  - The upgrade path: nothing rewrites a project's files, so `m0 doctor`
    now names each scaffold file that differs from what the running `m0`
    writes, reported and never failed (N42). Between 0.2.0 and 0.3.0 six
    of the ten files every template writes changed, the Dockerfile among
    them, whose 0.2.0 form installs no `libsqlite3`. With `max-core`
    installed, `mojo-gated`'s fix is one `uv add` that moves both pins.
  - `M0_WORKERS` above 1 in a binary that links MAX's parallel runtime
    exits 78; `M0_THREADS` serves it (E32, D48). On macOS a build beside
    an installed `max-core` links the runtime whether or not the source
    imports it (ROADMAP Known issues).
  - A route that takes GET answers HEAD, and `Allow` names HEAD beside
    GET (N38). `url_for` refuses a `.` or `..` parameter (N5).
    `issue_session` refuses an expiry `verify_session` cannot read, such
    as one in milliseconds. `Login.from_env` refuses a key under 32 bytes
    and a `PREFIX_SECURE` other than `1` or `0`.
  - The command line: `m0 new` refuses a name that ends in `-`; `m0
    doctor` bounds its run of the binary at 30 s and skips an editor's
    hidden lock files; two builds of one project wait for each other
    rather than race; and a second Ctrl-C in `m0 dev` ends the draining
    server by name and exits 0 (under Fixed).

- **m0serve refuses a forked worker when MAX's parallel runtime is
  linked** (SPEC E33, DECISIONS D51). A Mojo mount that imports
  `max.algorithm.parallelize` puts `libAsyncRTMojoBindings` in the image;
  `--workers N` above 1 and `--reload` (which supervises even one worker,
  forked) then exit 2 before the bind, naming `--spawn-workers`, whose
  worker execs the binary and starts the runtime fresh, and `--doctor`
  reports the check (`workers-vs-parallel-runtime`) and
  `topology.parallel_runtime`. The fact moved to
  `m0_http.parallel_runtime`, the one function the Mojo host and m0serve
  both read, so the shipped `bin/m0serve`, which links no MAX, passes the
  check at two workers. Measured with the refusal removed: a forked worker
  answered `/par/ser` in 23 ms and `/par/par` never, and the pool thread
  it took was abandoned at the drain's 5 s bound.
  `smoke-serve-parallel-runtime` gates it on every pull request under the
  same `max` group, with two exec'd workers each answering a
  `parallelize` (`apps/serve_parallel`, over the job `apps/host_parallel`
  now keeps in `compute.mojo`). CI's macOS leg found the toolchain's part:
  a build made beside an installed `max-core` links
  `libAsyncRTMojoBindings` whether or not the source imports MAX (the
  demo-mount `bin/m0serve` bundled three runtime files without MAX and
  four with it; Linux, three either way), so on such a machine every
  binary reads as linked and E32's and E33's refusals fire for a MAX-free
  one — a Known issue now, `M0_THREADS` and `--spawn-workers` serving it;
  the gate's control reads the binary's own load commands and holds the
  doctor to them rather than assuming.
- **The Mojo host refuses forked workers when MAX's parallel runtime is
  linked** (SPEC E32, DECISIONS D48). `M0_WORKERS` above 1 in a binary that
  carries `libAsyncRTMojoBindings` — what `max.algorithm.parallelize`
  needs — exits 78 before the bind, naming `--threads (M0_THREADS)`, and
  `--doctor` reports the check (`workers-vs-parallel-runtime`). Measured
  before: a `parallelize` in a forked worker never returned, and the
  request that hung took its worker's loop and the shutdown with it, because
  `fork()` copies the calling thread alone and the runtime's workers are
  started before `main`. `smoke-parallel-runtime` gates it on every pull
  request, both platforms, against `max-core` synced by the new `max`
  dependency group in that step alone; `sabotage-host --only parallel`
  removes the check and must be caught on the served prefork. The host's
  unit tests supply the fact wherever a verdict is about something else,
  so `test_host.mojo` holds with the `max` group synced, where `mojo run`
  maps the runtime into the compiler's process.
- **`m0-sqlite` opens libsqlite3 at run time** (SPEC O17, O18; D49). The
  package reached SQLite through `external_call`, which put the library on
  the link line of every binary that used it: `-Xlinker -lsqlite3` and
  `libsqlite3-dev` on Linux, and `mojo run` of any test that touched a
  database failing there with `Symbols not found`. `Connection` now opens
  the library through `SqliteLib` (`src/lib.mojo`, `m0-postgres`'s shape
  and its three rules: handle and pointers in one struct, every entry point
  behind a method, the image pinned `RTLD_NODELETE`), from `M0_LIBSQLITE3`
  or a search path, refusing one below 3.20.0, built without threads, or
  missing a symbol, each an error naming what it found. `Statement` holds a
  copy of the entry points it calls and outlives every handle of the
  library; the virtual-table callbacks reach it through the module buffer
  SQLite already owns. Nothing in the tree links libsqlite3 any more —
  `build-apps` fails if `datastar_todo`'s binary names it — and six of the
  package's seven test files run under `mojo run`. `test_lib.mojo` is the
  gate; docs/notes/sqlite-at-run-time.md records the round.
- **The storage packages ride in the `m0` wheel, the `live` scaffold keeps
  its kick count in SQLite, and MAX is a pinned companion** (SPEC
  N39–N41; D50; docs/notes/storage-and-max-in-the-wheel.md). `m0_sqlite`
  and `m0_postgres` are two more source trees under `m0/_mojo/`, usable
  with no link flag because both open their library at run time; the
  wheel smoke opens SQLite through the installed tree under `m0 test`.
  `live`'s handler opens a `store.mojo` in `make` (once per worker, loop
  or pool thread, after the fork) and the kick view counts in it inside
  its own request, so `smoke.sh` restarts the server and finds the kick.
  `/stats` reads the database and the board's word drives only the wave,
  so `smoke-scaffold` keeps its stream open across the kick and requires a
  later frame whose lowest bar stands above the highest the wave drew
  before it; `sabotage-scaffold`'s "a kick never reaches the wave" is
  caught there. The scaffold's image installs
  `libsqlite3-0` (`RUNTIME_LIBS`, `libpq5` by one build argument), records
  it in `about.json`, and points `M0_DB` under `/app/data` for a volume.
  `gated_max` is read from the root's `max` group beside `gated_mojo`, and
  `max-gated` joins the ONE list of checks: absent passes naming the `uv
  add`, another version is refused with its sentence, the gated one
  passes; the scaffold's `pyproject.toml` carries that line substituted
  and its `AGENTS.md` the rules. `smoke-parallel-runtime` now also runs
  the release recipe on the MAX-linked probe and serves from the bundle,
  `libAsyncRTMojoBindings` beside it.

- **An `m0` upgrade says what the scaffold it came from lacks, and moves the
  toolchain in one command** (SPEC N42, D52;
  docs/notes/the-scaffold-upgrade-path.md). Nothing rewrites a project's
  files, so a newer `m0` left everything `m0 new` wrote as the older one
  wrote it: between 0.2.0 and 0.3.0 six of the ten files every template
  writes changed, the Dockerfile among them, whose 0.2.0 form installs no
  `libsqlite3` for `m0_sqlite` to open. `m0 doctor` now compares the
  scaffold's own files (all but the README and `pyproject.toml`) with what
  the running `m0` writes for the project's name, and names those that
  differ: reported, never failed, since a difference is as often the
  application's own edit. With `max-core` installed, `mojo-gated`'s fix is
  one `uv add` of both pins: `max-core` and `mojo` each pin
  `mojo-compiler` exactly, so moving `mojo` alone could not resolve. The
  scaffold's `AGENTS.md` and the wheel's README say how to upgrade.
  `smoke-scaffold` holds it per template (a fresh scaffold names nothing;
  an edited Dockerfile is named), and `sabotage-scaffold` removes the
  naming.

- **A login in the layer, and a scaffold template written on it** (SPEC
  N43–N45, D53; D38 and D44 retired; docs/notes/a-login-in-the-layer.md).
  `m0_http.login` is the glue `apps/fragment_notes` wrote by hand and the
  soak application copied with its names changed:
  - `Login.from_env(PREFIX, cookie)` refuses an incomplete configuration by
    name. `PREFIX_SECURE` is `1` or `0`, and any other value is refused
    rather than read as off, so `M0_NOTES_SECURE=true` now stops
    `fragment_notes` at startup where it used to drop `Secure`
    silently.
  - `sign_in(user, password)` is the credential check and the session in
    one call.
  - `session_of` and `sign_out` read and end a session.
  - `refuse_signed_out` answers a navigation with a 303 and a swap with a
    401 carrying the form.
  - `csrf_refusal` reads the header before the field, never the query
    string, and refuses everything when there is no session.
  - `csrf_input`, `csrf_header` and `no_store`.

  A swap now sends a request header with `header=RequestHeader(...)`:
  `hx-headers` for `Htmx`, refused by `Datastar` and by the trait's default.
  That is how a DELETE carries its CSRF token under htmx 4, which sends a
  DELETE's fields in the query string.

  `m0 new NAME --template auth` writes the `views` list behind the login:
  - Every write carries the token.
  - The login and the logout are plain forms.
  - `main` refuses a missing `APP_KEY` or `APP_PASSWORD` with exit 78
    before `serve`, so the doctor refuses it too.
  - `m0 new` prints the `export` that sets both variables.

  `smoke-scaffold` holds the template on the wire, and `sabotage-scaffold`
  reverts each of its rules. `test_login.mojo` and `test_html.mojo` hold the
  module and the header, each rule shown failing with its behaviour
  reverted. The scaffold's `AGENTS.md` now names the module where it named
  the notes app's source, so `m0 doctor` reports that file as changed in a
  project written by an earlier `m0`.

  `apps/fragment_notes` runs on the module, and `smoke-fragment-notes`
  passes unchanged. Its key must now be at least 32 bytes, and
  `serve-fragment-notes`' development default is lengthened to match.
  `sabotage-notes-login`'s CSRF arms now revert `login.mojo` itself, and a
  new arm removes the layer's `request_header` call.

### Changed

- **Loops on threads are the documented way to more than one core for an
  m0 application** (D48, superseding D35's "prefork first"): `M0_THREADS`
  across cores, a handler pool for the views that compute, one loop on one
  vCPU, and prefork kept for an application that links no MAX and wants a
  supervisor. The host page, the deploy page and the scaffold's `AGENTS.md`
  say so. Nothing changes for an application that sets neither.
- **The handler pool's fairness probe runs on every pull request on Linux,
  and judges job order rather than latency** (SPEC E11, E34;
  docs/notes/fairness-judged-by-order.md). `probe-pool-fairness` was
  pre-release; it now runs in test.yml's `pool-fairness` job, with the
  reference Mac keeping the macOS run. Its latency bounds were too close
  to the machine for that: on a 4-vCPU KVM guest a fair run's max reached
  247 ms against 250, and the old shapes broke the bounds by as little as
  4 %. The verdict is now the number of requests passed over by more than
  100 later ones, at most 5 a run and none by more than 1000. A pause of
  the whole process passes nobody over, so two 300 ms stops of the server,
  which failed the latency verdict five times in five, pass it. The keep
  rule's arm (E34) runs too, at a load chosen for it: five threads, twenty
  connections, a 0.65 ms view. With the rule off, who starves depends on
  how many jobs a 1 ms slice holds against how many threads wait. The first
  load's 0.3 ms view sat on the boundary between three jobs and four, and
  starved every AMD EPYC 7763 runner and no Intel Xeon or AMD EPYC 9V45
  one. The new view is two jobs a slice on every machine measured. On
  twenty runners of five CPU types, fair runs show no long waits, the
  barrier off 7–116 a run and the keep rule off 29–93. The reference
  Mac's first run, on an M4, agrees: none, 15 and 34.
  `M0_FAIRNESS_EXPECT_STARVATION=0` skips the keep arm. Each arm's figures
  are recorded with the job's measurements, with a request's share of the
  GIL against the 1 ms edge the keep arm needs.

- **`release-m0.yml` refuses a release `Tests` has not passed, and a wheel
  that does not record one `max-core` pin** (SPEC N32). The build job
  asks the runs API for the latest `Tests` run on the tagged commit, or,
  for a merge commit, on the pull request head it merges: a merge the
  `automerge` label makes is pushed with the workflow token, which starts
  no workflow, so such a commit has no run of its own (`m0-v0.1.0`'s did
  not). A run still going, failed or cancelled, or none at all (a change
  to docs alone gets none) refuses the tag by name. The wheel's
  `_build_info.json` must hold one `gated_max` pin, as it holds one
  `gated_mojo`, and the scaffold the job writes must name that MAX. Checked
  against both published tags, which pass, and a docs-only merge, a
  cancelled run and a running one, which do not. `m0_release_problems`
  holds both rules; its selftest reverts thirteen.

### Fixed

- **A burst of new connections no longer holds the event loop away from
  the connections it already serves** (SPEC C8). A pass admits at most 16
  new connections (`ACCEPT_BATCH`), off the listener or off a sibling's
  accept-share channel, AFTER it has served the events of the connections
  it holds; what a batch leaves is taken by the next pass, whose wait does
  not block. The loop used to drain the listener to EAGAIN — on Linux,
  where epoll reports no backlog depth, through connections that arrived
  during the drain, up to `max_connections` — and admitting a connection
  runs its eager read, which on a loop that serves `func` itself is the
  whole request: a keep-alive `/fast` waited 625 ms behind 120 queued 5 ms
  requests, and waits 79 ms now, the rest of one batch. `M0_ACCEPT_BATCH`
  overrides the batch, 0 taking the whole backlog as before (an A/B
  knob). `smoke-accept-batch` gates it on both legs, its knob-off arm on
  Linux required to show the old starvation. Found by the 2026-09-26
  pre-release run.

- **A `--blocking-threads` thread no longer starves waiting for the GIL
  under a CPU-bound view** (SPEC E34). Inside its hand-off slice a pool
  thread took the GIL back after every job, dropping it only to pop the
  next; each drop woke a parked thread that found the GIL taken again and
  waited once more behind the others, so the slice's hand-off went back
  to the thread that had just held it. Two threads alternated while two
  starved: on 4-vCPU Linux the fairness probe's max was 335–1637 ms in 14
  runs of 14, and with `wrk` the p99 itself 394–515 ms. A thread inside
  its slice now takes a job already queued without dropping the GIL
  (`OffloadPool.try_next_job`, which never waits): the max is 12.9–20.6
  ms, the `wrk` p99 9.3–12.7 ms at the same throughput, and the trivial
  route serves up to 28 % more at 256 connections. `M0_POOL_TURN_KEEP=0`
  restores the old shape (an A/B knob), and `probe-pool-fairness` runs it
  on Linux as a third arm that must starve a waiter. Found by the
  2026-09-26 pre-release run, which recorded it as a VM's outlier; a
  recorder beside the probe showed the machine never stalled.

- **A WebSocket lingering for the peer's Close reply is no longer pinged.**
  After the application's Close the loop waits for the peer's (RFC 6455
  §5.5.1) — and the stream heartbeat kept treating the slot as a live
  socket, so a ping went out during that wait. A peer that had read our
  Close, answered it and was waiting for the FIN read `0x89 0x02 "hb"`
  instead. Nothing follows a Close (§1.4), so the heartbeat now skips a
  slot whose `closing` is set; the linger's own bound still finds a peer
  that never replies. Found by `stress-asgi` in 3 rounds of 30 under CPU
  hogs, which widen the window between the Close going out and the reply
  being read — CI's `smoke-asgi` runs the same probe without hogs and never
  saw it. `ws_probe.py` now gates it deterministically (SPEC L29): its
  quiet-linger phase holds the Close reply for three heartbeat periods and
  requires silence, then a FIN; and its close-order phase names a frame it
  reads after the handshake by opcode, where it used to report the RST
  that had not happened.

- **A route that takes GET answers HEAD** (SPEC N38). The view table
  matched methods exactly, so every `Views` route answered HEAD 405 with
  `Allow: GET, OPTIONS`, `/health` included, where RFC 9110 has a server
  that supports GET support HEAD; an uptime check that sends one reads the
  application as down. `unotes`, the application-layer soak, found it on
  its own deploy. `Router.match` now answers a HEAD that no route registers
  for its path with the route a GET would reach, in both tables and on the
  loop, and the server needed nothing: it already dropped a HEAD's body and
  kept the GET's `Content-Length`. A route registered for HEAD itself still
  wins over its table's GET, and a path with no GET is still a 405 for HEAD. `Allow` names HEAD
  beside GET, so a 405's and a preflight's header changes: `GET, POST,
  OPTIONS` is now `GET, HEAD, POST, OPTIONS`. `test_views.mojo` and
  `test_router.mojo` hold the rule, and `smoke-blobs` sends HEAD to a read
  view, a loop route and the stream on the wire (`head_probe.py --twin`,
  new beside `--hold`).

- **`url_for` refuses a dot segment** (SPEC N5). A parameter of `.` or
  `..` reversed to `/notes/.` or `/notes/../delete`, which a browser
  resolves to another route before it sends the request: the empty
  value's failure, which `url_for` already refused, one step removed, and
  one no encoding avoids, `.` being unreserved and `%2e` read as a dot by
  the URL standard. `url_for` and `Mount.url_for` raise for it as they do
  for an empty value. Every application in `apps/` reverses numeric ids.

- **`issue_session` refuses an expiry `verify_session` cannot read.** The
  verifier reads at most twelve digits of expiry (`SESSION_EXP_DIGITS`),
  and the issuer signed any non-negative one, so an expiry given in
  milliseconds issued a cookie that read back as `malformed` on every
  request: a login that could never succeed, reported as a forgery. It
  raises now, as its docstring said it did.

- **Five `m0` command-line defects**, reaching users with `m0 0.3.0`:
  - `m0 new foo-` was accepted, and `uv sync` then failed on the project
    name. A name ends with a letter or digit (SPEC N27); exit 2 as before.
  - `m0 doctor` ran `bin/server --doctor` with no bound, so a binary whose
    `main` never reaches `serve` served instead of answering and the doctor
    waited for ever, and one that could not be run ended in a traceback.
    The run is bounded at 30 s, in a session of its own so everything it
    started is ended, and either failure is one line and exit 1.
  - `m0 doctor`'s staleness check stat-ed every `src/**/*.mojo`, and an
    editor's lock file (`.#views.mojo`, a symlink to nothing) raised.
    Hidden files are skipped, as `m0 dev`'s poll skips them.
  - Two builds of one project at once (`m0 dev` rebuilding while
    `./smoke.sh` runs `m0 build`) staged at the same path and could rename
    each other's half-written binary into place. A build holds
    `bin/.build.lock` for its length, and a second waits, saying so.
  - A second Ctrl-C while `m0 dev`'s server drained escaped as a
    traceback, and the server was SIGKILLed unannounced. It is ended at
    once and named, and `m0 dev` exits 0.

  `test_m0.py` holds each, and each was reverted to show its test fails.

## [1.6.0] — 2026-09-24

The request an application sees is now the one its client sent, and the
ASGI executor behaves as Starlette, FastAPI and FastHTML expect: FastHTML's
and FastAPI's own examples, run beside uvicorn, found the ASGI and request
fixes below. Descriptors no longer leak into a process the application
starts, `m0-datastar` passes the Datastar SDK's own conformance cases, and
the `m0` wheel ships as `m0 0.2.0`, carrying `Query` and `push=True`.

### Added

- **`m0 0.2.0`: this release's framework, for applications built with
  `m0`.** What changed since `m0 0.1.0` for someone writing an
  application:
  - New: `Query` (N36) and `push=True` (N37), both below.
  - `m0-datastar`'s frame builders now `raise` on a line break in a
    one-line field, so a call site must be in a `raises` function or catch
    it. `patch_signals` splits multi-line JSON, remove mode writes no
    `elements` line, `execute_script` takes `attributes`, `redirect`
    escapes its location, and `read_signals` reads a DELETE's query.
    `DatastarStream.caught_up` and `send_to` answer a reconnect the
    journal cannot catch up (I27–I30).
  - A request reaches a view as its client sent it: no invented
    `Content-Length`, `Connection` or `Host` (L25), and a raw `@` in its
    path or query no longer sends it to `/` (A22). A native 1xx, 204 or
    304 carries no invented entity headers (A21).
  - The scaffold's `AGENTS.md` covers a plain-form login, a cookie in a
    test, and where `read_signals` looks.

- **The Datastar SDK's own conformance cases gate `m0-datastar`** (SPEC
  I27). The SDK's specification (`sdk/ADR.md`), its 20 cases and the
  `compare-sse.sh` that judges them are vendored from the pinned tag into
  `packages/m0-datastar/test/sdk/`, each file hashed. `poe
  check-datastar-sdk`, inside `test-all`, runs every case and refuses
  fixtures from any tag but the pinned one; `poe sabotage-datastar-sdk`
  reverts each rule and insists it is caught. The package passed 14 of the
  19 get-cases before; the misses are under Fixed. `execute_script` takes
  the SDK's `attributes` option (`name="value"` strings, written
  verbatim), and `DatastarStream.execute_script` passes it and
  `auto_remove` through. `packages/m0-datastar/AGENTS.md` records where
  Datastar facts come from and how to move the pin.

- **`push=True`: a swap that moves the address bar** (SPEC N37, D46).
  `Fragment.swap`, `Fragment.el` and `Html.swap[V]` take it, and
  `Fragment[Htmx]` writes `hx-push-url="true"` beside the swap, so a view
  reached by a swap — a filtered list, a detail — can be reloaded, linked to
  and gone back to. `unotes` typed that attribute by hand on every link,
  against the scaffold's own rule. Only a `get` is pushed (the layer
  refuses the rest); `Vocabulary.push_url` is new with a default that
  REFUSES, so an application's own conformance still compiles, and
  `Fragment[Datastar]` raises — Datastar's free bundle has no history
  handling.
  `apps/fragment_notes` pushes its two links and its smoke holds them.
- **`Query`, a query-string builder beside `url_for`** (SPEC N36).
  `url_for` fills and encodes a path and nothing past it, and the encoder
  it uses was private, so an application with a GET filter form wrote a
  percent-encoder of its own — `unotes`, the layer's soak application, did.
  `Query().add(name, value)` then `q.on(path)`: pairs in order, names and
  values encoded byte by byte (`%20`, never `+`), an empty value skipped so
  a filter's URL is only what is set, `add_empty` for the pair whose
  presence is the meaning. Exported from `m0_http`.
- **The `m0` wheel and its CLI; published as `m0 0.1.0` on 2026-09-21** (SPEC
  N23–N26, D39–D43). `packaging/m0/` builds a pure-Python wheel that
  carries the framework's SOURCE — the five trees an application compiles
  against, mapped file by file from `git ls-files` into
  `m0/_mojo/<import name>/` — and a stdlib CLI that builds against it from
  outside this repository: `m0 build` (renamed onto `bin/server`, never
  written over a running binary; `--release` compiles for the platform's
  baseline CPU and bundles the Mojo runtime into `dist/`), `m0 test`
  (`mojo run` per test file, no C compiler needed), `m0 doctor [--json]`
  (the toolchain checks, then the binary's own `--doctor` with whatever
  follows `--`), and `m0 include`. The wheel is gated on ONE exact mojo,
  read from the root pin, and m0 refuses any other with the pin to add; it
  runs the `mojo` in its own environment, never `PATH`'s. Exit codes are a
  closed set (0, 1, 2, 78). Versioned apart from the repository, `0.1.0`
  and `0.x` until the application-layer soak. `m0 new`, the templates,
  `dev` and `image` came in the pull requests below.
  `smoke-m0-wheel` runs on every pull request, both legs.
- **`m0 new` and the two templates it writes** (SPEC N27–N29, D44;
  docs/notes/the-scaffold.md). `m0 new NAME [--template views|live]` needs
  no toolchain and no network — it runs through `uvx` before anything is
  installed — and writes an application a person can read in one sitting:
  `src/` and `test/`, a `pyproject.toml` pinning BOTH `mojo` and `m0`
  exactly, `AGENTS.md` (the rules that are not obvious from the code,
  written for a coding agent), an executable `smoke.sh`, a workflow, and
  `deploy/`. `views` is a server-rendered list swapped in place by htmx 4;
  `live` is a producer pushing full-state Datastar frames to every tab.
  Both are sessionless. The templates are real source files that compile
  unsubstituted — `poe check-templates`, inside `test-all` — so
  substitution is plain string replacement and there is no template
  engine. `smoke-scaffold` runs on every pull request, both legs.
- **`m0 dev`, `m0 image`, and the workflow that publishes `m0`** (SPEC
  N30–N32; docs/notes/dev-image-and-a-release.md). `m0 dev [-- HOST_ARGS]`
  is build-then-swap: the old server keeps answering while a build runs
  and after one fails, and only a build that succeeded ends it — SIGTERM
  by pid, a six-second wait for the pid to exit, then the new binary, so
  there is never a second process on the port. The watcher is a stdlib
  mtime poll of `src/` and `pyproject.toml`. `m0 image [--tag T]
  [--target-cpu CPU] [-- DOCKER_ARGS]` builds the scaffold's
  `deploy/Dockerfile` and prints the image's own `about.json`; it needs
  docker and no toolchain, and does not deploy. The scaffold's Dockerfile
  takes `TARGET_CPU` as a build argument and its `about.json` records
  `cpu`, what the builder's release build said it compiled for.
  `smoke-scaffold-dev` (both legs) and `smoke-scaffold-image` (Linux, the
  first x86-64 build of the scaffold's image, its Dockerfile built as
  written) run on every pull request, which retires the `deploy/` gap
  the scaffold shipped with. `release-m0.yml` publishes from `m0-v*`
  tags through a trusted publisher and an environment of its own; it is
  held to its rules by `check-docs`. Its first run was the `m0-v0.1.0`
  tag on 2026-09-21: green in both jobs at the first attempt, and the
  published wheel then passed docs/RELEASING.md's two after-upload runs
  (a scaffold synced from the index, and the quickstart page verbatim).
- **The scaffold's `AGENTS.md` says three things the first scaffolded app
  had to find out** (`unotes`, the application-layer soak's subject; its
  `SOAK_LOG.md` findings 4–6). Login and logout are plain forms answered
  with a 303, never swaps — a swap leaves the address bar behind, so
  signing in left the application under `/login`. A hand-built
  `HTTPRequest` parses no `Cookie` header, so a test of a view behind a
  session fills a `RequestCookieJar` itself; without the two lines every
  such test is answered as signed out, and finding them meant reading
  framework source. And the worked login, `apps/fragment_notes`, is not in
  the wheel: the page now gives its URL and says to read its renderer as
  well as its views. Reaches a scaffold with the next `m0` release.
- **Documentation for the Mojo stack, and a quickstart CI executes** (SPEC
  N33–N35, D45). Six pages under `/mojo/` on the site, their URLs
  permanent: the section index (where "preview" is said, once), a
  quickstart, the host, views and fragments, deploy, and the way from an
  m0serve mount to a binary of its own. `packaging/m0/QUICKSTART.md` is
  run on every pull request, both platforms, by `smoke-quickstart-mojo`:
  `uvx m0 new` to a served page, `m0 test`, `m0 doctor`, and `m0 dev`
  swapping in an edit, against the tree's wheel, in a scratch directory on
  a stripped `PATH`. It lives under `packaging/` so that a pull request
  editing only the page still runs it. `check-docs` holds the pages'
  tables to `host_checks`, the host's help text, `m0`'s parser and its
  checks list, holds the six URLs, and puts all six pages under the
  bare-figure rule. `llms.txt` gains the stack's operating contract; the
  pages ride in the existing `llms-full.txt`. The site deploys on a
  release, so merging this publishes nothing.
  A scaffold's first build prints no compiler warning (N34):
  `smoke-scaffold` refuses one that does.

- **A command line and a doctor for Mojo host applications** (SPEC
  E30–E31). `serve[H, P](AppConfig())` now reads the binary's flags —
  `--host`, `--port`, `--workers`, `--threads`, `--blocking-threads`,
  `--access-log`, `--sse-heartbeat-ms`, `--app-tick-ms`,
  `--max-keepalive-requests`, `--qos` — with m0serve's precedence, flag
  over `M0_` variable over default, and m0serve's strictness: an unknown
  flag, an unreadable value or a positional is the usage and exit 2.
  `--doctor` prints the configuration the binary would serve as one JSON
  object (the last line of stdout, in m0serve's report shape, each failed
  check carrying its `fix`) and exits with the code serving would exit
  with, having bound nothing; `smoke-host-doctor` runs twenty
  configurations both ways and requires the codes to agree. An
  application that prints its own address takes `host_config()` so the
  banner names the port a flag moved. Nothing changes for an application
  that is passed no arguments.

### Changed

- **`m0-datastar`'s frame builders raise on a line break in a one-line
  field** (SPEC I29). `patch_elements`, `patch_signals`, `execute_script`,
  `redirect` and the `DatastarStream` broadcasts refuse a selector, mode,
  namespace, view-transition selector or event id carrying CR or LF: two
  breaks ended the event, and a selector built from request data could
  open an event of its own. Each is now `raises`, so a caller that cannot
  raise catches -- `apps/datastar_counter`'s `tick` does.

- **A child process reaches the bus only when it is handed it** (SPEC
  G16). The bus is close-on-exec now, like every descriptor the server
  creates. A child started with `os.system`, with `pty.fork` and exec, or
  with `subprocess` and `close_fds=False` used to inherit it by accident,
  and `m0pub.publish()` there reached the real bus. Now it publishes
  nothing, and `publish` returns 0. Hand the child the bus instead, the
  way m0pub has always documented:
  `subprocess.Popen([...], pass_fds=m0pub.child_fds())`. That carries the
  event-id page as well, so the child's frames are numbered.
- **A native 1xx, 204 or 304 no longer carries `Content-Type:
  application/octet-stream` or `Content-Length: 0`** (SPEC A21).
  `HTTPResponse`'s constructors add neither default for a status that has
  no content, and the event loop drops a length and a body that a handler
  set on a 1xx or 204 itself. `reply.empty(304)`, `reply.no_content()`, the
  Views table's OPTIONS answer and the static mount's revalidation all
  change on the wire. A response with a body keeps both defaults.
  `HTTPResponse(..., invent_entity_headers=False)` adds neither for any
  status: it is how the gateway relays an application's head.
- **A parsed request carries only the headers its client sent** (SPEC
  L25). `HTTPRequest.from_parsed` no longer fills in a `Content-Length`, a
  `Connection` or a `Host`, so a native handler reading `req.headers`, a
  WSGI environ and an ASGI scope all see a GET without the
  `content-length: 0` and `connection: keep-alive` they used to carry, and
  a WSGI application gets no `CONTENT_LENGTH` for a request that sent
  none, which PEP 3333 allows. `HTTPRequest(..., invent_headers=False)` is
  new; the default still fills all three for a client.
  `connection_close()` now answers HTTP/1.0's default from the protocol,
  which moves two edges: an HTTP/1.0 request whose `Connection` is a list
  (`Keep-Alive, foo`) now closes, the value being compared whole as `close`
  always was; and HTTP/1.2 to 1.9, which the parser accepts, now persists
  as 1.1 does (RFC 9110 §2.5) where an invented `close` used to end it.
  And `Transfer-Encoding: chunked, chunked` is refused with a 400 beside
  every other request whose `chunked` is not its final coding: RFC 9112
  §6.1 forbids applying it twice, and the loop decodes one layer.
- **Datastar is pinned at v1.0.4** (was v1.0.3; DECISIONS D20).
  `m0-datastar`'s `VERSION`, the three demo pages' CDN pins, the `live`
  scaffold template's, and the SDK conformance-case URL. **Not a protocol
  change**: the v1.0.3...v1.0.4 compare is 74 files with **none under
  `sdk/`**, and every string this tree's behaviour rests on is in both
  bundles in the same count — `Datastar-Request`, the three accepted
  content types, the key parser `split(/:(.+)/)`, `datastar-patch-elements`
  and `-signals`, `retry`, `contentType`, `FetchFormNotFound`. The two
  source files that touch this contract were read: `patchElements.ts`
  removes committed merge-conflict markers and adds two casts, and
  `fetch.ts` registers `@query()` (as the `QUERY` method, not yet in
  `Datastar.verbs()`) and stops a `requestCancellation: 'cleanup'` fetch
  dispatching events for an element that has since been removed. Rocket,
  the new `datastar-rocket.js` web-component bundle, is **not** adopted:
  it is client-side only, in beta, and orthogonal to `Vocabulary`.
- **D46's retiring condition now names a price, not a release.** Datastar's
  free bundle still names neither `pushState`, `replaceState` nor
  `popstate` at 1.0.4, and the two attributes that would spell a push,
  `data-replace-url` and `data-query-string`, are **Pro**. So
  `Fragment[Datastar]` refusing `push=True` is not waiting on a version.
- **`apps/blobs` keeps sending a picture, and now says why** (DECISIONS
  D47; docs/notes/the-picture-on-the-wire.md). An investigation into
  Datastar 1.0.4's Rocket component bundle asked whether the demo could
  send blob state and let the client draw it. Measured over 40 consecutive
  frames instead of argued: 2,544 B of signals per frame at the median —
  not the 11 KB the 16-blob worst case implies — 5 of 16 slots filled, 4
  of those 5 changing every frame, 92.7 % of the bytes vertex text. So
  delta frames would save a fifth, and the only real cut is to stop
  sending vertices, which moves the kernel with it: `match` is what makes
  CSS interpolation coherent, so a client drawing state must reproduce the
  whole contouring pipeline. No code changed; the note and the row record
  the measurement and what would retire the decision.

- **The built-in htmx vocabulary is htmx 4** (SPEC N22, DECISIONS D6
  retired; docs/notes/the-layer-moves-to-htmx-4.md). `Fragment[Htmx]`,
  `page_or_fragment` and `apps/fragment_notes` were gated against 2.0.4 and
  are now gated against 4.0.0:
  - `page_or_fragment` takes `HX-Request-Type` at its word — `partial` is
    the fragment, `full` the document — and reads a request without it by
    the htmx 2 rule, unchanged, so an application still on htmx 2 is
    answered as before. **Every answer's `Vary` gains `HX-Request-Type`**,
    fifth and last; that is the one change on the wire for an application
    that did nothing.
  - `Htmx` takes htmx 4's sixth verb, `query`. A swap is spelled in the
    same three attributes, byte for byte.
  - The notes app sends a DELETE's CSRF token as an `X-CSRF-Token` header
    (`hx-headers` on the form), because htmx 4 puts a DELETE's fields in
    the query string and has no setting to change it; its server reads the
    token from that header or the body and never from the URL.
  - For applications moving: htmx 4 swaps every 4xx, so answer an error a
    person may see as a fragment.

- A Mojo host's refusals (exit 78) now end with the fix in parentheses,
  naming both spellings: `M0_THREADS must be at least 1, not 0 (set
  --threads (M0_THREADS) to 1 or more, ...)`. The opening words are
  unchanged.
- `Report`, the pure half of `m0serve --doctor`, lives in
  `m0_http.doctor` so both doctors render one shape; `m0_wsgi.doctor`
  re-exports it and m0serve's output is byte-identical.
- **blobs.m0serve.dev no longer slows to 2 Hz when idle.** The app drops to
  its idle rate a minute after the last click, and on 1.5.0's live stream
  that was nearly every visit, where each shape moved in 500 ms straight
  lines. The deploy sets `M0_BLOBS_IDLE_HZ=10`. The app's own default is
  unchanged.

### Fixed

- **A raw `@` in a request's query or path sent it to `/`, and a client
  URL to another host** (SPEC A22). `URI.parse` read the first `@`
  anywhere after the scheme as the end of a userinfo and discarded
  everything before it, so `GET /contacts?q=a@b` reached the application
  as `PATH_INFO='/'` with an empty `QUERY_STRING` on every server shape.
  A POST to `/save?x=a@b` ran the root's POST handler, and so did
  `/users/@alice?page=2`. The outbound client dials the parsed host, so
  `http://api.test/lookup?email=x@evil.test` connected to `evil.test`.
  Only an `@` inside the authority (before the first `/`, `?` or `#`,
  RFC 3986 §3.2) now ends a userinfo; `userinfo_separator` is the rule, beside
  `scheme_separator`, which fixed the same search for `://`. Browsers and
  htmx encode `@`, so it took a typed or hand-built URL; a Flask app
  compared against Werkzeug found it. `test_uri_userinfo.mojo` holds it,
  and `smoke-wsgi` sends a GET and a POST with the raw byte.

- **A Datastar replay too big for the connection is no longer served in
  part** (SPEC I30). `DatastarStream.open` replayed a reconnect's missed
  frames oldest first into a 64 KB outbox. When they did not fit, the
  newest were the ones refused, and the client sat on a state from
  several changes ago with nothing in the log: thirty 3 KB frames arrived
  as 1-21. A reconnect behind an evicted frame got the frames after it
  with a hole in the middle. Both are now gaps. Nothing is replayed,
  `caught_up(slot)` answers False (as it does for an id older than the
  process's own history, or ahead of it), and the new `send_to(slot,
  frame)` queues the view's resync for that connection alone.
  `apps/datastar_todo` sends its current list that way, and
  `smoke-todo` reconnects thirteen 2 KB adds behind to hold it.
  `refused()` counts the live frames a full outbox refused.

- **Security: `m0-datastar`'s `redirect` pasted its location between
  single quotes** (SPEC I29), so a `'` ended the JavaScript string and the
  rest ran as script, and `</script>` ended the element whatever the
  quoting. The location is now a string literal with `"`, `\`, `<`, every
  control byte and U+2028/U+2029 escaped.
- **`m0-datastar` against the SDK's own cases** (SPEC I27, I28):
  `read_signals` read a DELETE's signals from its body, where Datastar
  sends none -- the bundle and the SDK's `ReadSignals` table put them in
  `?datastar=`, as for GET -- and so returned `{}`; `patch_signals` wrote
  multi-line JSON as one dataline, so the client received `{` and read
  the other lines as fields of their own; and `remove` mode carried an
  empty `elements` line.

- **Security: an ASGI application's message for a client that had left
  could reach a different client** (SPEC L20). The executor decided whether
  a connection was gone by asking about the task *making* a send, not the
  connection the send addressed, and the loop reuses a slot the moment a
  connection closes. So a `send` an application kept for a client that had
  gone, called from any live task — a broadcast, another request, a
  background task — was written into whichever client now held that slot.
  FastAPI's documented multi-client chat room did it with no change: the
  next client to connect received every message addressed to the one that
  left, including its personal ones. A raw ASGI push hub's stale stream
  `send` wrote into another client's response the same way. The same rule
  also refused a disconnect hook's sends to the sockets still connected
  ("someone left" reached none of them). A send is now judged by the task
  that owns the connection it addresses: a send to a socket that has gone
  raises `ClientDisconnected` (an `OSError`, uvicorn's name for it), and one
  to a stream that has gone is a no-op, as ASGI 2.3 specifies. Two paths
  never told the executor a socket had gone at all, and are closed too: a
  socket its application closed (each socket now keeps its own record of
  its accept and its close, where the slot's record was the next client's —
  a late `finally` closed that client, a second close rejected its
  handshake), and a socket the server ended itself after a message over
  its outbox cap (the loop now tags every connection an executor produced,
  routed to that executor). And a task an application left behind, sending
  after the application returned, could answer the slot's next request
  with its response; a send once the response is over now answers nothing.
  Found by serving FastHTML's and FastAPI's own examples beside uvicorn.
- **A process the application started inherited the server's connections
  and channels** (SPEC G16). Nothing the server created was close-on-exec,
  so a child that execs — `os.system`, `pty.fork`, `subprocess` with
  `close_fds=False` — held every client connection open at that moment, the
  listener, the channels between the loop and its pools, the bus and the
  shutdown pipe: 8 to 46 descriptors, depending on the mode. A connection
  the server closed stayed open in the child. FastHTML's terminal example
  took 10 s to close a WebSocket, and a child that runs another user's
  commands, like that terminal's shell, held every other client's
  connection. Every descriptor is now close-on-exec, atomically on Linux.
  `--spawn-workers` keeps exactly what its new image adopts across its own
  exec, where the supervisor used to clear the flag for every exec in every
  mode. And `m0pub` writes only to its own bus, which it recognises by
  device and inode (`M0_BUS_WRITE_IDS`, exported beside the numbers). A
  child handed no bus used to write its datagram into whatever file or
  socket had the bus's old descriptor number.
- **An ASGI WebSocket's disconnect cancelled the application's task**
  (SPEC L21). uvicorn delivers `websocket.disconnect` through `receive()`,
  and FastAPI's documentation is written against that: its cleanup is an
  `except WebSocketDisconnect:` after the receive loop, which a cancellation
  skips, so the departed client stayed in the application's list for ever.
  The disconnect now arrives through `receive()` (and again on every later
  call), and the task is not cancelled for it. A handler blocked outside
  `receive()` learns at its next send, or at shutdown, where the drain gives
  in-flight tasks a second and then cancels the sockets still running.
- **An ASGI response waited for its background tasks** (SPEC L22).
  Starlette runs a response's `BackgroundTask` after its final body, inside
  the same call, and the executor answered only when the application
  returned, so a response with background work was held for as long as the
  work took, buffered or streamed. It is answered at its final body now,
  and a client leaving afterwards does not cancel the work. Under the
  escape hatch (`--blocking-threads N` with an ASGI application) each
  request runs in its own event loop run, which cannot return early; the
  response still waits there.
- **An ASGI application's error replaced its own error page and lost the
  traceback; a raising WebSocket closed with 1000** (SPEC L23, L24).
  Starlette's `ServerErrorMiddleware` sends a finished 500 — with
  FastHTML's `debug=True`, the traceback page — and then re-raises; the
  executor answered its own `Failed to process request` instead and logged
  one line with no file or line. The application's response now stands,
  and every application error the executor logs carries its traceback. A
  WebSocket whose application raises is closed with 1011 ("an unexpected
  condition", RFC 6455 §7.4.1), not the 1000 that told the client all went
  well. A `ClientDisconnected` escaping an application is not logged; a
  Starlette `WebSocketDisconnect` that an application lets escape is, as
  uvicorn logs it. And `receive()` after a response is answered says
  `http.disconnect` at once, where it used to wait for the life of the
  process.
- **An ASGI application's WebSocket close could be answered with a second
  Close frame** (SPEC L15). The executor sent the close as two datagrams,
  the Close frame and then the socket's end marker. The loop wrote the
  Close at the first but began waiting for the client's reply only at the
  second, so an executor descheduled between them had the client's reply
  read in between and echoed back: a Close after the closing handshake,
  which a strict client reports as a protocol error. CI saw it twice, once
  on each OS. The Close now rides inside the end marker, one datagram, so
  the loop never writes it without knowing the socket is ending.
- **A response's head reached the client rewritten** (SPEC A21, K12). A
  response the application sent without a `Content-Type` went out as
  `application/octet-stream`: a redirect, a 204, FastHTML's default 404
  page, which a browser may then download rather than show. A HEAD the
  application answered with its body's `Content-Length` and no body went
  out with `Content-Length: 0` (Starlette's `FileResponse`, WhiteNoise).
  And every 204 and 304 carried `Content-Length: 0`, from the gateway and
  from a native Mojo handler alike, which RFC 9110 §8.6 forbids on a 204. A
  204 that brought its own length and a body (Django's `CommonMiddleware`
  sets a length on every non-streaming response) sent both, and the body
  began the connection's next response. The head now reaches the wire as
  the application sent it, plus only the framing that is the server's: a
  buffered body's measured length, and on a HEAD the application's own
  length. No 1xx or 204 carries a length or a body, whoever set them, and a
  304 keeps only a length its application gave.
- **A HEAD to a streaming ASGI route received the whole body** (SPEC L27).
  The executor switched a response to streaming at its first chunk
  whatever the request, so a HEAD to a Starlette `StreamingResponse`, which
  answers HEAD as it answers GET, was streamed, and the loop, which never
  frames a HEAD, wrote the body raw after the head: all 10,000 bytes of a
  10,000-byte route, and an endless stream for ever. A keep-alive client
  then read those bytes as the start of its next response. A HEAD is now
  answered at its first streamed body with its head alone, and the
  application's later sends are dropped. A `receive()` it parked before the
  first body, as Starlette and Django do, is woken with `http.disconnect`,
  which stops a `StreamingResponse` and still runs its background tasks;
  an application that never listens is cancelled if it is still running a
  second later. A 1xx, 204 or 304 streamed the same way is answered the
  same way. And a HEAD to a hold, an `M0-Hold` view under `--realtime` or
  a native SSE route, was held as the stream a GET opens, writing every
  event and heartbeat after the head: it is answered with its head, and the
  subscription it made is dropped.
- **A chunked request reached an application with `transfer-encoding:
  chunked` and a `content-length` at once** (SPEC L25). The loop decodes a
  chunked body before any application sees it, and the length it then
  added sat beside the client's coding: a contradictory pair an
  application proxying the request would forward. The body is now
  described by its length and the `chunked` coding is gone, in the ASGI
  scope on both bridges and in the WSGI environ. Any other coding, such as
  the `gzip` of `gzip, chunked`, is kept.
- **Every chunked upload reached a Flask application empty** (SPEC L25).
  Werkzeug reads `HTTP_TRANSFER_ENCODING: chunked` as a streaming request
  of unknown length and, without `wsgi.input_terminated`, hands the
  application an empty input stream, so `request.data` was `b''` however
  much was sent. The environ now describes the decoded body by its
  `CONTENT_LENGTH` and carries no `HTTP_TRANSFER_ENCODING`.
- **A module that calls `asyncio.create_task` at import failed to load
  with a bare `RuntimeError: no running event loop`** (SPEC L26).
  FastHTML's first official example does this. m0serve imports an
  application before any event loop runs, as uvicorn does without
  `--reload`, and now says what the module did and the fix: start that
  work from a lifespan startup handler. The server, `--doctor` and
  discovery all name it, with the traceback, and exit 1. Any other
  import error keeps its own words.
- **An ASGI application's lifespan shutdown was skipped when background
  work outlived the drain.** After the drain, the executor gave WebSocket
  tasks a second and then waited on every HTTP task without bound, so work
  that never ends -- a response's background task, a poller -- held it until
  the 5 s thread join gave up and the process left without shutting the
  application down. Every task now gets 3 s in all, is then cancelled and
  counted in the log, and a task that swallows its cancellation is named and
  left behind, never to reach the server again; lifespan shutdown runs
  after. Work that finishes inside the 3 s finishes (SPEC D11).
- **A HEAD to a WSGI view that streams for ever never answered** (SPEC
  K13). A HEAD took the buffered path, which joins the whole body, so a HEAD
  to a WSGI SSE view hung and held its pool thread until shutdown; eight
  of them were the whole zero-config pool. It is answered at the body's
  first item, with no length, and the body is closed.
- **Two ASGI executor edge cases.** A body an ASGI
  application sent before its `http.response.start`, then caught the error
  for and answered properly, reached the client at the front of the real
  body; and a stream still winding down on a recycled slot was cancelled a
  second time by the next connection's disconnect.
- **An ASGI application heard 1006 for every WebSocket disconnect** (SPEC
  L28). The code a client closed with now reaches it, as uvicorn passes it:
  1000, 1001 for a closed tab, any other code the client sent, 1005 for a
  Close with no code; 1006 means no Close arrived. And a Close, or a last
  message, sent in the same instant as the hang-up now reaches the
  application: the loop closed a socket at EOF before reading what its
  client had left buffered.
- **An inbound WebSocket message over 64 KB went silent** (SPEC I26). A
  message larger than the channel's datagram could never reach the
  application or a pool thread, and was parked and retried for ever: no
  reply, no close, no log. It is refused with a Close carrying 1009, the
  connection ends on the client's reply, nothing the client sent after it
  is processed, the application hears 1009, and the log names the size
  and the limit. On a `--realtime` hold this needed the loop to end a
  socket the handler closed itself: `HTTPService.take_ws_closes()`.
- **A `413` for an oversized upload reached curl and browsers, but not
  `http.client`** (SPEC A20). The server refuses a body over `--max-body`
  as soon as it knows the size, while the client is still uploading, and
  it closed the socket straight after. Closing with the rest of the body
  unread makes the kernel send RST instead of FIN, so a client that writes
  its whole body before reading — `http.client`, and therefore `urllib`
  and `requests` — got `BrokenPipeError` instead of the status. Found by
  a Flask application compared against Werkzeug. The refusal now shuts its
  write side, reads and discards what is still coming for up to five
  seconds (RFC 9112 §9.6's lingering close), then closes cleanly. And
  every error the server answers on its own — 400, 408, 413, 414, 431 --
  said `Connection: keep-alive` on a connection it was about to close; it
  says `close`. `--max-body`'s help and `docs/RUNNING.md` now say that
  the server answers over the cap before the application runs.

- **The nightly canary could not alert, and one break hid the rest.**
  The 2026-09-02 fix created the missing `nightly-breakage` label, which was
  one of two causes: the job declares no `permissions`, so the repository's
  read-only token failed again on `GraphQL: Resource not accessible by
  integration (createIssue)` — every run from 2026-08-18 to 2026-09-15 failed
  and none of them said so, while the free-threaded canary next door had been
  given `issues: write` on 2026-09-02 and its sibling was missed. It has them
  now. The build step was also a `build-all` sequence, so the first broken
  package ended the run: the 2026-09-15 canary reported `Atomic[DType...]`
  and `_CTimeSpec.tv_subsec` and stopped, leaving m0-wsgi, the apps and the
  whole suite unprobed. It now builds each package itself, carries on past a
  failure, marks as skipped anything whose dependency broke, and renders a
  per-package table into the run summary. An open `nightly-breakage` issue
  gets a comment rather than a fresh issue every Tuesday.

- **`page_or_fragment(..., status=422)` answered `422 OK`.** `text`
  defaulted to the literal `"OK"`, so a styled error carried the wrong
  reason phrase unless the caller passed one. `text` left alone is now the
  status's own RFC 9110 phrase (`reply.reason_phrase`); an explicit `text`
  still wins (SPEC N29).

- **`mojo build` needing a C compiler on Linux, and saying so only after
  the whole compile**, is retired as a known issue for an application built
  with `m0`: the check runs first and names the fix. Measured on the way:
  mojo 1.1.0 looks for the literal name `cc` and nothing else, so `gcc`
  without `cc` is refused by name, and a `cc` that cannot link is caught by
  linking one line of C.

- **The blobs demo's shapes twisted and popped** (`apps/blobs`, SPEC N16).
  Measured on 1.5.0's live stream over 45 s: 64 of 1,758 slot steps
  twisted, and 69 of 331 frames made a slot appear or vanish whole. The
  cause was the kernel, not delivery (frames arrived 96–104 ms apart at
  p5–p95), the server (0.5–1 ms a step) or the browser (60 fps, the main
  thread about 4 % busy). CSS moves vertex `i` to vertex `i`, and vertex 0
  was each step's topmost point, so when a blob's highest point moved to
  another lobe every vertex was dragged around the outline. A continuing
  slot is now turned to the rotation of its outline nearest its previous
  polygon. `data-show` does not transition a slot it reveals or hides, so
  now nothing appears or vanishes in one frame:
  - a split starts as a copy of its parent's outline;
  - a drop starts as a seed at 8 % of its size;
  - an absorbed blob becomes the merged outline, then shrinks where it was;
  - any other shape that ends shrinks to its centre before its slot hides.

  The alignment adds about 25 µs to a 312 µs step on an M4 (the same
  600-step world, best of five). Measured locally over 60 s after the fix:
  no twist in 2,588 slot steps. All 40 splits began as their parent's copy,
  and all 40 disappearances shrank first. The unit tests check every trace
  against the one before. `smoke-blobs` checks
  consecutive frames on the wire for a twist and a pop.
  `sabotage-blobs` grows from 23 rules to 31, eight of them new: five
  against the unit tests, three against the smoke.

## [1.5.0] — 2026-09-19

A host for Mojo applications — workers, loops on threads, a handler pool
and a producer from one `serve` call — and the first application written
for it, streaming from an image with no Python in it at
[blobs.m0serve.dev](https://blobs.m0serve.dev). The pin moves to Mojo
1.1.0, which lets an application conform to the layer's traits, and an
unmounted `--realtime` gets the handler pool every other WSGI app gets.

### Added

- **The Mojo host** (SPEC E21–E25). `m0_host.serve[H, P]` is
  everything in a Mojo application's `main` that is not the application:
  the listener, the pre-fork shared pages and bus, `M0_WORKERS` processes
  sharing their accepts, signals armed after the fork, a handler built in
  each worker by `AppHandler.make`, and one `Producer` on worker 0 whose
  frames go to every worker's channel, stopped and joined within the
  drain's 5 s. An application writes two conformances and
  `serve[MyHandler, MyProducer](AppConfig())`. A producer numbers its
  frames from the pre-fork shared word (`Publisher.next_id`), so a
  respawned worker 0 continues above what every held stream has seen
  rather than restarting at 1 and leaving them silent for the pre-crash
  uptime. A `make` that raises, the handler's or the producer's, is a
  refusal with 78 before the server listens, never a crash loop, and one
  worker's refusal ends its siblings (DECISIONS D30). `M0_SPAWN_WORKERS` is
  m0serve's and is refused with 78. Gated by `smoke-host` on
  `apps/host_check` and by `test_host.mojo`; `sabotage-host` (46 rules
  across the host and the pieces it shares) before a release. DECISIONS D26
  is retired: the `Producer` trait is the helper it deferred, and D27
  records its choices. The write-up is
  [the-mojo-host](docs/notes/the-mojo-host.md).

- **A handler pool and route placement in the host** (SPEC E26, N19;
  DECISIONS D31, D32). `M0_BLOCKING_THREADS=N` is served as N `MojoPool`
  threads behind each worker's loop, on one lane the host marks GIL-free.
  `PoolLane[H]` builds the application's handler again on each thread with
  `AppHandler.make`, `HostContext.thread` naming the instance, so an
  application conforms once; the host waits for every thread's handler
  before it serves, and a raising pool `make` is the same 78. A stream
  begun in `func` on a pool thread is refused 409, as on a Mojo mount; one
  opened on the loop works under the pool. `Views.add_read` and `add_write`
  take `on_loop=True`, which keeps a route in the table (one `Allow`, one
  `url_for`, one 404) and answers it on the loop with the loop instance's
  state before it becomes a pool job; `m0serve`'s loop holds no Mojo table
  and answers such a route one round trip later (D32). The shutdown bounds
  overlap: the loop stamps the producer's stop word as its drain begins and
  the pool and producer joins count from that stamp, so a request in flight
  at SIGTERM beside a long step leaves inside one 5 s bound, not two.

- **The Mojo host serves `M0_THREADS=N`: N event loops on N threads of one
  process** (DECISIONS D35; SPEC E27–E29). The listener, the shared page,
  the bus and the accept-share channels are made once and sized by the loop
  count; each thread builds its own handler with
  `AppHandler.make`, its own pool under `M0_BLOCKING_THREADS`, and runs its
  own loop; fan-out across loops rides the bus and accepts are shared
  across the threads (without it, 30 of 32 connections sat on one loop of
  four). `HostContext.worker`/`workers` count loops and the new
  `HostContext.threaded` names the kind, so an application is served by
  either mode unchanged. New on `AppHandler` and `ViewState`:
  `max_threads()`, **defaulting to `max_workers()`** — an application whose
  state lives in one handler refuses loops exactly as it refuses workers,
  without being asked. `M0_WORKERS>1` with `M0_THREADS>1` is refused. No
  loop takes a connection until every loop's `make` has returned, so a
  raising `make` is still a 78 before anything is served. There is no
  supervisor in this mode: a loop that dies takes the process. Measured
  against prefork on `apps/ramp` (`poe bench-host-modes`): the same
  throughput and tail on macOS and Linux, and 20–35 % less RSS — so prefork
  stays what the documentation reaches for first
  ([loops-on-threads](docs/notes/loops-on-threads.md)). On a Linux x86-64
  GitHub runner, threads over workers measured the same throughput and
  tail and 0.56–0.59x the RSS; at 256 connections on the loop route
  threads used more CPU per request, 0.86–0.94x workers' per core in
  every round, which is prefork's side of the decision.

- **One views module on two hosts** (SPEC N20). `apps/ramp/views.mojo` is
  one `Views[Ramp]` table built from its mount prefix alone; two adapters a
  page long build it into `m0serve` under `--mount /x=mojo` and into a host
  binary. `smoke-ramp` diffs nine requests across the two (only `Date`
  differs), follows a rendered link on each, and measures where a request
  waits behind a slow view: with the lane full the host's loop route still
  answers, while `m0serve`'s waits for a thread, which is D32's divergence
  recorded on every run. New on `build-serve`: `M0SERVE_INCLUDE` puts an
  application's own module root on the include path beside
  `M0SERVE_MOUNT_DIR`. The write-up is
  [the-ramp-test](docs/notes/the-ramp-test.md).

- **Every Mojo app that forked or streamed now runs on the host.**
  `sim_loop` (`main` 105 → 19 lines), `datastar_counter` (56 → 7),
  `datastar_todo` (18 → 7) and `fragment_notes` (15 → 10). The counter
  now shares its accepts across workers. The todo list now serves
  `M0_WORKERS=2` over one SQLite file (SPEC N17), holding the write lock
  from a change until its frame is published, so a tab's newest frame
  never misses an older one's change. `ViewsApp[S]` serves a `Views` table
  with no handler struct (SPEC N18), and an application whose state is
  per process declares `max_workers`: `fragment_notes`, which used to
  ignore `M0_WORKERS=2`, now refuses it with 78.

- **`apps/blobs`: a live world the page cannot hold** (SPEC N16). The first
  application written for the Mojo-native stack. A producer thread steps up
  to sixteen metaballs at 10 Hz — samples their field on a 192 × 192 grid,
  traces the outlines where blobs merge, and resamples each to 48 vertices
  in the slot it held last step — and publishes each step as one
  full-state Datastar frame of `polygon()` clip-paths; a click drops a
  blob for every open tab. A step costs ~0.2–0.4 ms on an M4. It is the
  first app that is both a `Views` table and a streaming handler, and the
  first on the Mojo host: its `main` is fifteen lines, and `M0_WORKERS=2`
  serves from two processes, a click on either reaching the one producer.
  Sixteen separate blobs make a 9.6 KB frame, ~96 KB/s per viewer; merged
  ones make less. `uv run poe serve-blobs`; gated by `smoke-blobs` and the
  kernel's unit tests, with `browser-blobs` and `sabotage-blobs` (23 rules)
  before a release.

- **A Mojo application ships as an image with nothing under it, gated on
  every pull request** (SPEC M26, M27;
  [the-demo-in-its-own-image](docs/notes/the-demo-in-its-own-image.md)).
  `deploy/mojo/Dockerfile` is one Dockerfile for every Mojo app, `APP`
  naming the directory: the pinned toolchain compiles it in a builder
  stage, and the runtime stage carries the binary, at `/app/server` and
  PID 1, and the three Mojo runtime libraries beside it, with no
  interpreter and no toolchain. Its last layer measures the image into
  `/app/about.json`: the unpacked bytes, and no interpreter anywhere,
  failing the build if one is found. `apps/blobs` reads the file through
  `M0_IMAGE_FACTS` for a footer and a new `/about`, and refuses a malformed
  one with 78. `poe smoke-blobs-image` builds it from the tree in CI's
  `pid1` job, the first x86-64 Mojo build CI makes, and probes it from
  outside with `scripts/mojo_image_probe.py`: PID 1, no interpreter, the
  page's claims, the whole of `smoke-blobs`' main run through the published
  port, and a held stream ended by `docker stop` with exit 0. On arm64 the
  blobs image is 102.1 MB unpacked (29.3 MB compressed), 3.0 MB of it the
  app, against 184.6 MB (60.3 MB) for the Django demo's image; on x86-64 it
  is 80.1 MB unpacked and holds 20.1 MiB of RSS idle and 24.2 MiB with 100
  streams held. `deploy/mojo/README.md` names each figure's unit and
  architecture. Before a release, `poe probe-mojo-image` records the floor
  under every Mojo image (`apps/hello` from the same Dockerfile) and `poe
  sabotage-mojo-image` breaks ten of the image's rules.

- **D36: the blobs deploy serves one loop.** On one core, one loop, two
  workers and two threads measure the same CPU, delivery and fan-out, on
  arm64 and on x86-64 (`scripts/bench_blobs_modes.py`). Only memory
  differs: 1.11–1.25x one loop's for threads, 1.79–2.29x for workers.

- **The Mojo demo's deploy: `blobs.m0serve.dev`**, made by each release
  from this one. `deploy/blobs/` (the Fly app `m0serve-blobs`: one machine,
  one loop per D36, connection-counted concurrency at soft 200 and hard
  400) and a `deploy-blobs` job in `deploy-site.yml`. The job builds the
  release's commit, or a dispatched version's tag, since the image compiles
  its checkout. It verifies the deploy with `mojo_image_probe.py --url` and
  skips a tag older than the deploy with a notice. `poe deploy-blobs`
  deploys by hand. The site links it beside the Django demo.

- **An application defines its own frontend vocabulary** (DECISIONS D7,
  retired 2026-09-18; D34; SPEC N21). `Vocabulary` was exported but not
  implementable from outside: `Datastar` read a private field of `Html`
  and both built-in conformances called a module-private verb check. New,
  all exported from `m0_http`: `Html.open_kind()` answering an
  `ElementKind` (`is_form`, `is_field`, `is_link`), a static
  `Vocabulary.verbs()` with a default (`STANDARD_VERBS`, the five), and
  the verb check moved into the layer — `Html.swap` and
  `Fragment.swap`/`.el` refuse a verb outside `V.verbs()` before `V.swap`
  runs, naming that vocabulary's list. A conformance that checks nothing
  still refuses a typo, and one for htmx 4 allows `query` in one line.
  `Vocabulary.swap`'s signature did not change and both built-in
  vocabularies emit what they emitted, checked byte for byte across
  `fragment_notes`' four swapping call sites and `datastar_todo`'s three.
  `poe check-app-vocabulary` (inside `test-all`) builds an htmx 4
  vocabulary from a directory outside the repository and reads its output
  with `hxlint`, vendored from hx-flask (MIT; NOTICE, and a recorded-hash
  guard in `check-docs`). The write-up is
  [a-vocabulary-an-application-defines](docs/notes/a-vocabulary-an-application-defines.md).

- **`DatastarStream(send_latest=True)`: a stream of states** (SPEC I24).
  Every subscriber, new or reconnecting, is sent the newest frame for its
  url at open and then the live feed, never a replay. Without it a page
  fed by a paused or slow producer stays blank until the next frame.

- **A bus publish reports what it delivered** (SPEC I25).
  `publish_to_channels` and `BroadcastBus.publish` return how many channels
  took the frame, 0 for a frame over `BUS_MAX_FRAME`, a reserved channel or
  an over-long name. Each of those was dropped without a word.

- **`poe test-apps`** runs an application's own tests from
  `apps/<app>/test/`, inside `test-all`; `apps/blobs` is the first.

### Changed

- **The page shell is a trait** (DECISIONS D12, retired 2026-09-18).
  `page_or_fragment` takes an application struct conforming to
  `m0_http.PageShell` — one method, `wrap(fragment)`, called only when a
  document is wanted — in place of the `thin` function and the separate
  context argument it took through v1.4.0. The context and the function
  travel as one value, and a shell that carries no context is a struct
  with no fields, which is why no second form was kept. The migration is
  mechanical: the context struct conforms, the shell function becomes its
  `wrap` method, and the argument goes. `PageShell` is now exported from
  the package. It was a `thin` function because on Mojo 1.0 an app's
  conformance to a trait behind a `.mojoc` got no witness table; that was
  a package-name-against-directory bug, fixed in Mojo 1.1.0 and pinned on
  2026-09-18. `check-mojoc-trait`'s `mismatch` arm now passes an app's
  shell through the real API, and `wrap_with`, the helper that existed
  only for it, is gone. `apps/fragment_notes` is on the trait with its
  wire byte-identical across all nine of its call sites; the write-up is
  [the-page-shell-becomes-a-trait](docs/notes/the-page-shell-becomes-a-trait.md).

- **`PoolContext`, `PoolHandler`, `MojoPool` and `JOIN_TIMEOUT_NS` import
  from `m0_http`, not `lightbug_http`** — a source break for a Mojo mount
  module built through `M0SERVE_MOUNT_DIR` (SPEC N14), whose first line
  becomes `from m0_http import PoolContext, PoolHandler`. The old import
  is a compile error naming the missing name, at the build that adopts
  this tree; nothing served changes, and a Mojo import path is outside the
  served contract stated above. `mojo_pool.mojo` and the Mojo host were
  placed in the `lightbug_http` fork because Mojo 1.0 emitted no witness
  table for an application's conformance to a trait behind a `.mojoc`;
  Mojo 1.1.0 fixed that, and both have left. The pool is
  `m0_http.mojo_pool`. The host is a package of its own, `m0_host`
  (`from m0_host import serve, AppHandler, ...`; it was
  `lightbug_http.host`, which no release carried), resolved from source
  beside the fork — it cannot be inside `m0_http`, because it calls the
  event loop, `event_loop.mojo` imports `m0_http.log`, and that resolves
  through the `.mojoc` the build would be writing (DECISIONS D33). `poe
  check-host-package` compiles it whole inside `test-all`. The fork's
  imports of `m0_http` fall from eight to one. DECISIONS D28 is retired.
  The write-up is
  [docs/notes/the-host-leaves-the-fork.md](docs/notes/the-host-leaves-the-fork.md).

- **The pinned toolchain is Mojo 1.1.0** (was 1.0.0). It carries the
  upstream fix for the `PythonObject` reference leak
  (modular/modular#6833) and for the witness-table bug that cost a trait
  its conformance when a package's name differed from the directory it was
  compiled from. Both were measured in this tree against 1.0.0 as the null
  case: 1000 operations leak 1001 references there and 0 here, and all four
  arms of `check-mojoc-trait` compile where two were refused. That check
  was written as a countdown and is now a regression guard whose failure
  says what the constraint's return would cost. Nothing served changes.
  What the move cost in source: `Atomic[Int64]` for
  `Atomic[DType.int64]` (20 sites), `_CTimeSpec.tv_nsec` for `tv_subsec`
  (2), `Array` for `InlineArray` (2), a `Span[UInt8]` for `Hasher.update`
  (2), and `ptr`/`as_c_string_span` for the deprecated
  `unsafe_ptr`/`as_c_string_slice` (7 lines) — the warning ratchet's floor
  stays 0. The ROADMAP known issue for the leak is retired, and DECISIONS D7,
  D12 and D28, each decided on the witness-table bug, are retired in this
  release (the entries above). That bug had been recorded here as a
  language limitation for three weeks (`PoolHandler` 2026-08-28,
  `PageShell` 2026-09-10); the error named the cause all along
  (`trait 'src::fragment::PageShell'`), and
  [a-trait-and-a-directory-name](docs/notes/a-trait-and-a-directory-name.md)
  records how it was found. Free-threaded `PyObject` layout
  (modular/modular#5726) is NOT known to be fixed — it needs a 3.14t
  interpreter, so `py-canary` answers it. The write-up is
  [docs/notes/the-pin-moves-to-1-1-0.md](docs/notes/the-pin-moves-to-1-1-0.md).

- **One pre-fork preparation for both hosts** (SPEC E24). `m0_http.prefork`
  makes the shared page, the bus and the accept-share channels, exports
  each by descriptor, and adopts all three in a spawned worker; `m0serve`
  and the Mojo host both call it, where `m0serve` used to keep its own
  copy and the host a second one. Nothing served changes: the flags, the
  `M0_*` names `m0pub` reads and an exec'd worker's environment are as
  they were. The Mojo host's page is now file-backed and exported, as
  `m0serve`'s already was, and a spawned worker handed no page descriptor
  is refused rather than served from an address that is not its own
  (the old `m0serve` path skipped the adoption silently and would have
  bound accept sharing to its parent's address). Six of
  `sabotage-host`'s rules run against `test_prefork.mojo`.

- **An unmounted `--realtime` gets the zero-config handler pool.** It
  used to turn the pool off, so `m0serve app:application --realtime` — the
  Quickstart's own command — ran every view on the event loop, and one slow
  view stalled every held stream (measured on textshelf at 0.12.0: a
  1 543 ms fast-path p50 against 0.3 ms with a pool). `--doctor` reported
  `blocking_threads: 0` with `blocking_threads_source: default` and nothing
  else said so. The reason was the demo's smokes, which were written
  against the single loop; holds have been taken on pool threads since
  0.12.0 for SSE and since 2026-08-26 for WebSockets, and the mounted
  `--realtime` already took the pool. Now the flag composes with the same
  `min(cores, 8)` default every WSGI app gets, the smokes that ran the
  single loop run pooled, and `--blocking-threads 0` (or
  `M0_BLOCKING_THREADS=0`) is that shape by name — which is how SPEC E20's
  gate serves it. Found running desk on m0serve 1.4.0.

- **The live demo shows the bus crossing it exists to demonstrate.** Each
  line names the worker that published it and the worker that delivered it
  to this tab, marks the ones that crossed between them, and the page counts
  them; before, a visitor had to compare two numbers in different places,
  and a tab whose connections and publishes all landed on one worker looked
  the same as one they had crossed. The page links to a second tab of
  itself, the visitor cookie is `HttpOnly` and `Secure` over HTTPS, and the
  CSP allows the inline script and stylesheet by sha256 instead of
  `'unsafe-inline'`. `scripts/demo_probe.py` asserts each, sabotaged eight
  ways against a local server on the 1.4.0 wheel.

### Fixed

- **A JSON number read from a request body could kill the server** (SPEC
  G14). `m0_core.json_parse.parse_json_number` cut the number out with a
  `String` slice, which asserts a codepoint boundary, so a body such as
  `{"x":1<0x80>}` trapped the thread that read it. Nothing in the tree
  called it until `apps/blobs`' drop view; the cut is now a byte-span slice.

- **Two processes opening one fresh SQLite file could not both get WAL**
  (m0-sqlite, SPEC O1). `open` switches a new file out of the rollback
  journal with `PRAGMA journal_mode=WAL`, and SQLite answers the loser of
  that race with `SQLITE_BUSY` at once, without consulting the busy handler
  set the line before, so `open` raised `database is locked`. It now
  retries the switch within `DEFAULT_BUSY_TIMEOUT_MS`. About one pair in
  two lost the race on an M4 (`test_two_processes_open_one_fresh_database`
  forks twelve), and `apps/datastar_todo` refused 29 of 30 two-worker
  starts once the host stopped hiding the raise behind a respawn; the todo
  list also creates its schema inside `BEGIN IMMEDIATE`.

- **A supervisor told to stop no longer respawns a worker that fails its
  drain** (SPEC D10). After a SIGTERM to the supervisor alone — what
  `docker stop` sends — a worker that exited non-zero, or died of any
  signal but the one forwarded, was replaced. Nothing ever signalled the
  replacement, so the supervisor served it until SIGKILL. The supervisor now
  lets it go and exits 1 once the rest are gone. `m0serve --workers N` and
  every Mojo app that forks share the supervisor. Found while gating the
  Mojo host.

- **Ten unchecked bodies in the lightbug fork, one of them a stack write
  past the end.** Mojo type-checks method bodies lazily and `build-http`
  precompiles `src` only, so the fork's 56 files were checked only where an
  app instantiated them — and nothing compiled them whole. `poe
  check-fork-package` now does, inside `test-all`: `Int` where `Int32` was
  wanted at `_getsockopt`, `_recvfrom` and `_writev`, a `socklen_t` from
  `size_of`, an origin mismatch in the dead `ProvisionPool.get_ptr` (removed),
  four hand-written copy/move dunders in the cookie types (removed, the
  compiler derives them), and `getsockopt` landing the kernel's reply in a
  one-byte allocation it had described as `size_of[Int]()` bytes. All ten
  sat in paths nothing instantiates, so no shipped behaviour changes; the
  gate is what stops the next one.

- **`poe deploy-site` and `poe deploy-demo` failed without a version
  argument.** Their default, the tree's own version, was a Python one-liner
  whose `\"` escapes TOML consumed, leaving a syntax error; a version given
  on the command line never evaluated it, which is how it went unnoticed.
  Both now read the version with the `grep`/`sed` pair another task already
  uses, as does the new `poe deploy-blobs`.

- **The live demo's deploy built from main, not from the release it
  pinned.** `deploy-site.yml`'s `deploy-demo` job checked out the default
  branch and pinned the release's wheel, so `deploy/demo/Dockerfile`, the
  demo application and the probe that verifies the deploy came from
  whatever had merged since the release -- or, for the `release/v*` branch
  form, from a main that might not hold the release's commit. It now checks
  out the release's own commit (`head_sha`) after a release and the
  version's tag on a dispatch, and refuses to deploy when the tree's
  version is not the pinned one. The docs site's job builds from the
  release's commit after a release too; a dispatch still renders the ref it
  ran on, which is how prose merged after a release is published.

- **The docs promised `Last-Event-ID` replay on a WSGI hold, which keeps no
  journal.** RUNNING.md and the `m0pub` docstring said a numbered frame was
  "covered by replay"; the plain `SSERegistry` a hold subscribes to only
  suppresses an event a reconnecting client already has, and events
  published while it was gone are not delivered — an application that
  trusted the sentence and dropped its own catch-up lost messages every
  time a phone slept. Both now say suppression only, README's "journal-deep"
  limit names the hold, the Quickstart says to keep a catch-up path, and a
  Known issue records what a journal would take. Two more from the same
  notes: RUNNING.md read as if SSE heartbeats were off until
  `M0_SSE_HEARTBEAT_MS` was set (they default to 15 s, so its 25000 example
  made them rarer), and `m0pub.publish` did not say that `data` is a payload
  rather than a frame, so pre-framed text was framed again and reached the
  client as `data: data: ...` with nothing logged; its docstring now says
  so and points at `publish_frame`. Not detected at run time, because a
  payload may legitimately begin with `data:`. Found running desk on
  m0serve 1.4.0.

- **The live demo's WebSocket status line described another tab's socket**
  (`apps/demo`, SPEC M17). It updated on any message that arrived over a
  WebSocket, and every tab's socket messages reach every tab on the
  visitor's channel, so after tab A sent one, both tabs said "slot 1 on
  worker 647 answered a message" -- tab A's socket, measured in Chromium and
  WebKit against demo.m0serve.dev on 1.4.0. Each tab now sends
  `{"text", "tab"}` with a random tab id, the view echoes the id, and a tab
  learns its socket's worker only from its own echo. A client that sends
  plain text, or JSON that is not the envelope, still has it broadcast
  verbatim.

- **`apps/sim_loop` delivered its steps to worker 0's streams only under
  `M0_WORKERS>1`** (SPEC N15). The simulation thread published to
  `bus.write_fds[0]` alone, while the app's own comments said every
  worker's loop received the frames; its gate ran one worker, where the
  first channel is every channel. The thread now holds every write fd. The
  app also shares accepts (SPEC E16) — without it one worker takes nearly
  every connection — and `/events` names its worker in `x-worker`.
  `smoke-sim-loop` gains a two-worker phase: four held streams must span
  both workers and each carry the steps, so a run that lands them all on
  one worker fails as vacuous rather than passing. The reference for
  periodic work off the loop is what a Mojo application copies, which is
  why this is a fix and not a footnote.

## [1.4.0] — 2026-09-15

Mounts that start are mounts that can be served, a Mojo mount that uses
every thread it is given, a pool-less loop that lets an application's own
threads run, and a child process that can publish without crashing.

### Added

- **A reference for periodic work that does not run on the event loop**
  (SPEC N15, `apps/sim_loop`). `HTTPService.tick` fires on the loop thread,
  so what it costs is its duty cycle — work over period — and that transfers
  into p99 about one for one; the docstring now says so, and this is the
  other half: where the work goes instead, as an application and a gate
  rather than a paragraph. A 4 Hz simulation runs on a thread of its own and
  publishes each step through the `BroadcastBus` with `skip_worker = -1`,
  which the loop drains into `sse_peer_frame`. Three things in it are easy to
  get wrong elsewhere: the bus is created unconditionally, at ONE worker too,
  because here it is the thread-to-loop channel rather than only
  worker-to-worker (`apps/datastar_counter` joins it only above one worker
  and reads as though that were the rule); `skip_worker` is `-1`, since
  nothing has queued the step locally and passing the worker index publishes
  to nobody without saying so; and the thread is joined within a bound,
  `pthread_join` having no timeout, so an unbounded join is a SIGTERM that
  does nothing until SIGKILL. `M0_SIM_ON_LOOP=1` moves the identical step
  onto `tick` — same work, same cadence, same publish, only the thread
  differs — and is both the A/B knob and the gate's negative arm: a trivial
  request measured 0–1 ms off the loop against up to 200 ms on it. Only a
  request that lands in a step's first half waits the gate's 100 ms, so the
  on-loop arm's margin is the probe's sample count: it took three samples
  and failed 19 of 60 local runs once their phases were random, as a slow
  runner makes them (it failed a CI run at 98 ms); it takes 24 at random
  gaps. `poe smoke-sim-loop` also
  asserts the step ids arrive contiguous (the bus is best-effort; at this
  cadence it must not drop) and that SIGTERM with a step in flight still
  exits 0. Building it found two defects of the class it exists to prevent:
  the on-loop arm silently did nothing, `tick` never firing unless
  `M0_APP_TICK_MS` is set — zero steps and a fast `/now`, reading as "the
  loop coped fine" — and the first probe never joined its thread at all.
  D26 records the framework helper deliberately NOT built: one application
  is not evidence of which cadence, shutdown and publish choices are right.

- **A `SessionStart` hook, so a fresh container can build and test the
  tree** (`.claude/hooks/session-start.sh`). Three things are missing from a
  bare Linux container and each fails in a way that reads as a code problem
  rather than a setup problem. Without patchelf, `poe build-serve` aborts the
  whole sequence as the LAST step of `test-all`, after every test has passed,
  and nothing earlier in the run hints that the tree is fine. Without
  `uv sync` there is no `mojo` at all, since the toolchain comes from the
  venv. And the `.mojoc` artifacts are gitignored, so a fresh clone has none
  and every cross-package import fails to resolve until `build-all` runs —
  which CLAUDE.md notes appears as unresolved imports in the editor, i.e.
  indistinguishable from a broken checkout. The hook is best effort
  throughout and always exits 0: a session that refuses to start because apt
  could not reach the network is worse than one that starts with a loud note
  saying what is missing, and the failure this exists to prevent is a silent
  one. Remote-only (`CLAUDE_CODE_REMOTE`), so a developer's own machine, and
  macOS, which needs none of it, are untouched.

### Fixed

- **A child process can publish from a view without crashing** (#322, SPEC
  I23). The bus descriptors survive `exec` but the event-id page did not:
  `M0_SHARED_ID_ADDR` is an address in the parent's memory, and a child
  that inherited the environment took an id there on its first publish. On
  Linux that was SIGSEGV. On macOS the address was often mapped in the
  child, which incremented eight bytes of its own memory and published the
  result as an event id; a subscriber that had seen a higher id then
  silently dropped the frame. The page is now file-backed in every mode and
  exported as `M0_SHARED_ID_FD` too, and carries a magic word. `m0pub`
  numbers only from a page it has verified: mapped from the descriptor, or
  at an address the kernel reports readable. Anything else publishes
  unnumbered, with one line on stderr saying why. The new
  `m0pub.child_fds()` is what to pass as `pass_fds`, and a child given it
  publishes numbered frames from the same counter, so `Last-Event-ID`
  replay covers them. A server that cannot file-back the page (no
  `/dev/shm`) starts anyway and says so, except under `--spawn-workers`,
  where that was already fatal.

- **`bench-mojo-mount` runs on a fresh clone, and its artifact says what it
  measured.** Four defects, each confirmed on `main` before being fixed.
  `build-serve` linked four packages through `.mojoc` files a fresh clone
  does not have, so that bench — and every smoke that depends on
  `build-serve` — failed with `unable to locate module 'm0_http'` until
  `build-all` ran by hand; CI never saw it because every job runs `build-all`
  first. A MISSING artifact is now built in dependency order, the
  `[ -f ] || uv run poe build-ffi` idiom the tree already uses, while a stale
  one is not, so a smoke does not pay for the chain on every call. The bench
  left `mojo_mount_bench.log` at the root unignored, so every run stamped
  `git_dirty: true` — the 2026-09-10 artifact among them — and about thirty
  other root logs written by tasks were missing from the per-name list too;
  one `/*.log` replaces it. The recorder stamped no machine conditions: macOS
  artifacts now carry power source, Low Power Mode, pmset's thermal report,
  the performance / efficiency core split, memory and the OS build, every
  artifact numpy's version, and Linux ones memory. And "per core" had two
  definitions — the headline (1.65x / 1.41x) was the median of each round's
  ratio while the artifact's medians block divides median rps by median cores
  (1.61x / 1.39x), and one table mixed them — so artifacts now carry
  `definitions`, `medians.*.rps_per_core_rounds` beside the existing figure,
  and this bench a `comparisons` block with both ratios per selectivity.

- **A benchmark artifact without its comparator rows is refused, and the
  Mojo mount's table is rendered.** The mixed workload recorded for this
  release under the free-threaded swap had no Granian row: the swap's venv is
  built from the default dependency groups, Granian is the `bench` group, and
  `bench_mixed_workload.sh` skipped the row without a word. The drift check
  then found no comparator in common with the previous artifact and passed,
  a leniency meant for older artifacts, so a table would have lost its
  reference row with its contamination check vacuous. `render_bench_docs.py`
  now refuses a rendered kind's newest artifact that holds none of its
  comparator rows, and the bench refuses to start without Granian
  (`BENCH_NO_GRANIAN=1` to mean it). docs/SERVER_PERFORMANCE.md renders the
  Mojo-mount table from `bench-mojo-mount`'s artifact, printing both
  definitions of per core and naming them, and every rendered table's
  environment line now carries the machine conditions the recorder stamps.

- **Stopping the WSGI handler pool right after starting it no longer
  hangs.** Each `BlockingPool` thread registered on its lane as the first
  act of its own body. `stop` pills registered threads on their own wake
  channels and sends the remainder to the lane socket, so a thread that
  registered after a racing `stop` parked on its own channel while its
  pill sat on the lane socket. Its join then waited out the 5 s bound and
  the process left naming a thread it had abandoned. The Mojo pool had
  the same body and the same fix earlier in this release. Threads are now
  registered in `start`, on the spawning thread, before any exists. The
  window in a server is small, since `stop` follows a loop that has
  served and returned; SIGTERM during startup on a loaded host was the
  way in. The new `test_blocking_pool.mojo` counts the threads the moment
  `start` returns and stops at once: 0 counted and a 5,072 ms join
  before, 4 and about 70 ms after, 10 runs of 10.

- **`M0_POOL_SPIN_US` does what its documentation says.** It was
  documented from 0.19.0 (2026-09-07) as overriding the handler pool's
  10 µs idle spin (`POOL_SPIN_NS`), in CLAUDE.md, NOTICE, this changelog
  and `docs/notes/pool-tail.md`, whose measurements used it. But the patch
  that read it was never committed, so setting it changed nothing. It is
  now read once when the pool is built, like `M0_POOL_WAKE_AGE_US`. A
  value that does not parse, or a negative one, keeps the default. With
  one handler thread at four connections, lane wakes went from 39k by
  default to 93k at `0` and 4 at `1000`.

- **Mounts under `--threads` are tested where they can run** (SPEC M23).
  `smoke-hybrid`'s `--threads` phase served ASGI mounts, which a
  free-threaded build refuses with exit 78 (modular/modular#5726). So it
  could not pass on the only interpreter where it ran, and no scheduled
  job ran it. It is now `poe smoke-mounts-threads`, phase G of the weekly
  free-threaded canary. There, Django and Flask mounts serve with their
  prefixes under `--threads 2`, a slow Django mount does not stall the
  Flask one (`hybrid_isolation.py` takes `ISOLATION_FAST_PATH` to measure
  a WSGI mount), SIGTERM ends both loops, and the ASGI refusal is pinned.
  On a GIL-enabled interpreter the task checks only that a mounted
  `--threads` server is refused.

- **A Mojo mount no longer slows down as its handler pool grows** (SPEC
  M22). `MojoPool` threads never registered on their lane, so the pool's
  elastic wake rules read the lane as "every thread parked" whenever its
  one awake thread was busy, and `submit` woke a sibling on nearly every
  request. The reservation of per-thread wake channels was also sized for
  the WSGI pool alone. On `/native/probe` at 16 connections beside a WSGI
  mount, the zero-config eight threads served 104k rps on 2.04 cores
  (202k lane wakes); with one thread, 132k on 1.42. Mojo pool threads now
  register, park on their own channels and unregister on exit, and
  `_serve_offloaded` reserves records for every pool before starting any.
  Eight threads now serve 133k rps on 1.35 cores with 61k wakes, which
  beats the WSGI route beside it per core.

- **A Mojo mount's compute route runs on all its threads again** (SPEC
  M25). Registering the Mojo pool's threads (M22, above) put its lane under
  the elastic rule's stall check, which leaves a ring alone while its pop
  count moves: a sibling woken beside a draining lane only queues for the
  GIL. A Mojo mount's threads never take the GIL, and the check held its
  lane to one of four threads — `bench-mojo-mount`'s search served 15k rps
  on 1.2 cores where the unregistered pool served 42k on 4.2. Waking eagerly
  on every push restores that and costs the trivial `/native/probe` 21 %, so
  only the stall check changes: on a lane whose threads never attach, a job
  that has waited past the idle spin (10 µs) since its push gets a parked
  sibling, moving ring or not. The search serves 43k rps again, and 76k at
  a quarter selectivity where it had fallen to 37k. The lightest routes pay
  for it: the probe gives up about 2 % (195k against 199k) and the lightest
  search about 4 %, each on more CPU. `M0_POOL_PARALLEL=0` restores the GIL
  rule on every lane.

- **A path no mount claims gets the server's own 404, whatever the first
  mount is** (SPEC M21). The loop sends a path that matches no mount to
  the first mount's lane, and only a WSGI pool thread checked the path
  again. So on a server with no root mount whose first mount was ASGI,
  `GET /zzz` got that application's answer (a 200 from the fixture app,
  and a 403 for a WebSocket upgrade), a lone ASGI mount did the same, and
  a Mojo mount listed first answered with its own router's 404 rather
  than the server's. The miss
  is now decided on the loop, before a mount's lane is chosen, against
  every mount's prefix including `mojo` and `hold` mounts. The check
  covered WSGI-first servers all along, which is the only shape
  `smoke-hybrid` tested; its new phase 2b tests the other three.

- **A mount set that some mount cannot be served in is refused instead of
  started half-served, and one that needs handler threads gets them**
  (SPEC M20). Four configurations used to start and then answer wrongly or
  not at all:
  - a `--mount PREFIX=mojo` with no handler pool (`--workers N`,
    `--blocking-threads 0`) served inline, where the loop knows only the
    Python mounts, so its requests were answered by the root application;
  - an ASGI mount beside a Mojo mount on zero config gave the Mojo mount
    no threads, and its requests hung;
  - more WSGI mounts than handler threads (`--blocking-threads 1` with two,
    or zero config on a one-core host) left a mount with no thread, and
    its requests hung;
  - an ASGI mount beside a WSGI mount under `--workers N` gave the WSGI
    mount no thread, with the same result.

  Every mount now gets at least one thread from the default pool. Unless
  `--blocking-threads` is given, that default also applies under
  `--workers N` or `--threads N` to a mount set that cannot run inline: a
  compiled mount, or an ASGI mount beside a WSGI one. So
  `--workers 4 --mount /=django --mount /native=mojo` now serves both.
  `--workers N` with only WSGI mounts keeps its meaning of no pool.

  An explicit `--blocking-threads` is used as given. If it's below the
  compiled mounts of a kind, the server exits 2; if it leaves a WSGI mount
  without a thread, it exits 78 once detection has run. A compiled mount
  under `--threads`, which was never served, also exits 2.

  The three existing mount refusals (only compiled mounts, a hold mount
  without `--realtime` or `M0_GRANT_KEY`) moved before the fork. Under
  `--workers N` they ran in every worker and ended in "5 rapid crashes"
  and exit 1, and `--doctor` answered 0 for the first of them. `main` and
  `--doctor` now refuse through one function. `smoke-doctor` holds nine
  mount rows to both agreement and a named exit code.

- **A thread a WSGI application starts runs while the server is idle, with
  or without a handler pool** (#310, SPEC E20). With no pool — an unmounted
  `--realtime`, `--blocking-threads 0`, or `--workers N` given explicitly —
  the event loop calls the application itself, and it waited for I/O still
  holding the GIL its thread has held since `Py_Initialize`. A
  `threading.Thread` the app started, or an `asyncio.run` inside one, then
  ran only when a request happened to run some Python: measured at 1 tick
  in 1.5 s idle where 150 were due, and an agent turn publishing progress
  with `m0pub.publish` never got past its first line. The loop now releases
  the GIL around each wait and takes it back before touching the
  application, the shape `--threads` already had. Throughput is unchanged
  (hello-world at 16 and 256 connections, A/B within run-to-run noise).
  On 1.3.0, `--blocking-threads N` with any N above 0 avoids it.
  `poe smoke-app-threads` serves an app with a ticking thread in all three
  shapes on both CI legs and counts its ticks over an idle window.

- **The weekly free-threaded canary hung on Linux in every run that reached
  its last phase since 2026-08-23, and the hang was the gate's own shell.** Phase 2 of
  `smoke-blocking-threads` (a handler pool behind each `--threads` loop,
  run only on 3.14t) waited for its two slow requests with
  `wait $(jobs -p | grep -v "^$pid$")`. poe runs shell tasks with `sh`,
  which is dash on Linux, and dash gives a command substitution's subshell
  no job table — so the list was empty, the `wait` was bare, and it waited
  on the server until the phase watchdog fired. macOS's `sh` is bash, which
  answers the list, so the macOS leg passed and the server was never at
  fault: reproduced locally by running the task under `/bin/dash` against
  3.14t (hung at the same line, SIGALRM at the deadline) and green in 20 s
  with the pids recorded, as phase 1 already did. The phases proving SPEC
  E5 and L18 passed, but the run both rows cite as their weekly evidence
  was red for three weeks, which `poe milestones` cannot see. `check-docs`
  now refuses `jobs` inside `$(...)` in any
  task, with selftest cases that put the defect back into the committed
  file, because `dash -n` parses the line without complaint.

## [1.3.0] — 2026-09-13

A PostgreSQL binding, a second door onto the bus, and a mount an
application brings itself.

### Added

- **A gate on the `_ = x` keep-alives at the FFI sites.** Roughly thirty
  of them end a sequence that hands a buffer's address to C, and nothing
  proved they still worked. `poe check-keepalive-barrier` (inside
  `test-all`) compiles `scripts/keepalive_probe.mojo` to LLVM IR and reads
  four exported bodies: with the line, the allocator free lands after the
  call; without it, before — which is the measured hazard, and the half
  that keeps the gate evidence rather than ceremony. The probe also
  records what is NOT at risk, since only an owning value is: a stack
  local whose address escapes is kept alive by LLVM without help.
  `poe sabotage-keepalive` reverts each of the probe's own rules and
  insists the check reports every one.

- **An application's own Mojo mount, without copying `m0serve.mojo`** (SPEC
  N14). The demo mount moved out of the entry file into a module,
  `m0serve_mount` (`packages/m0-wsgi/mount/`), and `poe build-serve` takes
  `M0SERVE_MOUNT_DIR` to build the same entry file against an application's
  own directory instead, plus `M0SERVE_OUT` to name the binary. The directory
  replaces the default rather than joining it: with both on the include path
  the first root wins silently, measured as a clean build serving the demo.

- **A Postgres `NOTIFY` reaches a held stream** (SPEC I22). `--pg-listen URL`
  (`M0_PG_LISTEN`) holds one `LISTEN` on worker 0 and publishes what arrives
  onto the broadcast bus, so a writer that cannot reach the datagram bus at
  all — a trigger, a cron job, a management command, `psql` — reaches every
  subscriber with an id, an event type and its data. The payload is three
  JSON string fields, and one present as anything else — the object
  `'data', row_to_json(NEW)` makes — is refused and counted rather than
  delivered as an empty event (m0-core gains `parse_json_string` and
  `has_json_field`, which can tell a real `""` from a wrong type);
  `m0pub.notify_sql` builds the statement for a caller
  that already has a database cursor, with no driver imported into a
  stdlib-only module. Refused without `--realtime`, which is what creates
  the bus, and `--doctor` reports both that refusal and which libpq it
  found. Nothing is resolved from libpq when the flag is absent — the
  server binary's dynamic dependencies are unchanged, which is what keeps
  the wheel installable on a machine with no PostgreSQL client. Started in
  both execution modes: worker 0 under `--workers`, and once per process
  under `--threads`, where the bus is one channel per thread. Refused on
  macOS wherever a worker is forked — `--workers N`, and `--reload`, which
  supervises even one — because libpq's connect reaches Kerberos through
  GSSAPI and Objective-C aborts a forked child; `--spawn-workers` is the
  escape, as it is for Core ML, and composes with `--reload`. The SSE line
  splitter and frame decoder a payload passes through slice by bytes now
  (SPEC G14): a `data` from a `SQL_ASCII` database with a continuation byte
  after a newline trapped the listener's thread on worker 0. The listener
  drains once after connecting and after every reset, so a notification
  libpq read during the `LISTEN` round trip is not left waiting for the
  next one to wake `poll`. A host with no libpq exits 78
  naming every path tried, rather than serving with no listener — held on
  the wheel's own binary, since its users have neither a toolchain nor a
  PostgreSQL client.

- **`m0-postgres`, a PostgreSQL binding over libpq** (SPEC O6–O16). A
  sibling of `m0-core`, `m0-http` and `m0-sqlite` that imports nothing else
  here and links nothing: libpq is opened with `dlopen` at run time, so no
  binary in this repo — `bin/m0serve` and the wheel included — carries a
  libpq dependency, and an absent library is one error naming every path
  tried. `Connection` owns its handle, `Result` owns a complete `PGresult`
  and so can outlive its query, `Params` binds positionally with an explicit
  OID per value, and every error carries a SQLSTATE that `sqlstate()`
  recovers. `open()` applies a connect timeout, a statement timeout,
  `client_encoding=UTF8`, an application name, and TCP keepalives of 30 s
  idle, 10 s interval and 3 probes with a 60 s `tcp_user_timeout` — libpq's
  own keepalives use the OS's timings, measured at 7200 s idle, so a
  listener behind a NAT that dropped its idle connection went deaf for two
  hours — merging rather than appending so each stays overridable; `open_readonly()` adds a read-only
  transaction default; every URL is redacted before it reaches an error, a
  log or the doctor, including the ones `redact` cannot parse — an
  unencoded `/`, `?` or `@` in a password, a key/value string with quoted
  or spaced values, a keyword libpq does not know — which come back masked
  whole, with libpq's own message beside them withheld, because libpq
  quotes what it cannot parse. `sslpassword` and `oauth_client_secret` are
  masked as `password` is. `LISTEN`/`NOTIFY` is supported, including restoring
  subscriptions across a reset. No pool, no retry, no `COPY`, and `numeric`,
  dates, intervals and arrays read as text — each a deliberate absence, with
  the reason in the README.

  Three Mojo 1.0 findings are recorded in `lib.mojo` and pinned by
  `test_lib.mojo`, all found by crashing: a `dlopen` handle held apart from
  the pointers loaded from it is closed at its last mention, a `thin`
  pointer field cannot be called as `table.field()` from outside the struct
  that holds it even though its address is unchanged, and a `Result` that
  reached libpq through its connection's address faulted once that
  connection was gone. libpq is now pinned with `RTLD_NODELETE` once opened
  and a `Result` holds the entry points it calls by value, so
  `var rows = db.query(...)` with no later use of `db` reads correctly
  (SPEC O16) — before the fix it was a segmentation fault on the first
  read.

- **`m0-sqlite` gets its rows** (SPEC section O, O1–O5). The storage
  packages had no capability rows at all, so nothing in the sheet noticed
  the three invariants CLAUDE.md calls "look like bugs and are not": that
  `open` raises rather than delivering less than the WAL concurrency it
  promises, that a `Statement` outlives the `Connection` that prepared it
  because every close path uses `sqlite3_close_v2`, and that error text is
  trusted only when `sqlite3_errcode` corroborates the code being
  described. Each is now a row against the test that already proved it,
  beside `m0_array`'s borrow safety and the todo demo's persistence across
  a kill and a restart. No behaviour changed; five gates that were running
  are now recorded, and the sheet's own sabotage suite covers them.

- **A Datastar form, end to end** (SPEC N12). The todo demo renames a todo
  in place: `Fragment[Datastar]` on the `<form>` emits
  `data-on:submit__prevent="@post('/edit/7', {contentType: 'form'})"`, the
  new `/edit/:id` route reads the field with `form(req)` and refuses any
  other body with a 400, and the broadcast morphs the renamed todo into
  every tab. `smoke-todo` posts the form and greps the frame and the page's
  wire spelling on every pull request; `poe browser-datastar-form`, a
  pre-release step, drives the same form in Chromium and records what the
  pinned bundle sends — the form's fields urlencoded, and for a bound
  field's own action the signal store as JSON, which confirms D21. The last
  `planned` row on the layer is now N13.
- **Sessions and CSRF behind a login** (SPEC N13). `m0_http.session` signs,
  verifies and expires a stateless session cookie —
  `v1.<kid>.<exp>.<subject>.<tag>`, HMAC-SHA256 over the rest, the tag
  compared in constant time, the expiry against the host clock, a key ring
  so a rotation ends every session under the key it retires — and derives
  the CSRF token a form carries from that session's own tag, so neither
  needs a store. `session_cookie_line` builds the `Set-Cookie` for
  `ResponseCookieJar.add_raw` with `HttpOnly; SameSite=Lax; Path=/`, and
  `vary_on_fragment_headers` is now exported so an application's own
  redirects name the headers that chose them. `apps/fragment_notes` is the
  worked application: one user from `M0_NOTES_USER`/`M0_NOTES_PASSWORD`,
  signing with `M0_NOTES_KEY`, refusing to start (78) without a key or a
  password, private notes, a guard that is an early return, and a login
  that answers 303 to a navigation and 401 carrying the login fragment to
  a swap. `smoke-fragment-notes` asserts every arm on the wire with the
  forgeries signed by `scripts/notes_session.py`; `test_session.mojo` holds
  that issuer's vectors; `poe sabotage-notes-login` (pre-release) reverts
  five rules and insists the gate goes red for each. Retires D15; D24 and
  D25 record what it deliberately is not. `poe browser-notes-login`, a
  pre-release step, drives the same flow in Chromium: htmx 2.0.4 would put
  a `DELETE`'s fields in the query string, so the shell narrows
  `methodsThatUseUrlParams` to `get` and the run records that the token
  travels in the body. Section N has no `planned` rows left.

### Changed

- **m0-postgres checks each libpq symbol where it loads it**, so the two
  cannot drift. `PgLib` walked a hand-written `required_symbols()` list
  before loading anything, because `ExternalFunction.load` aborts the
  process on a missing symbol — but that list was a third source of truth
  beside the declarations and the fields, and nothing compared them.
  `test_every_symbol_the_table_loads_is_checked_first` asserted the list
  was plausible, never that it matched what is loaded, so a 33rd entry
  point added without its list entry passed every gate and would have
  aborted on the first host whose libpq lacked it — the one failure the
  list existed to prevent. A `_checked[name, T]` helper now takes the
  symbol from the declaration it loads, and the list is gone along with
  its export from `m0_postgres`. The replacement test drives both arms of
  the refusal, which `PgLib.open()` succeeding cannot show; reverting the
  check makes it abort rather than fail, the same evidentiary shape as the
  two crash regressions beside it.

### Fixed

- **The Linux container could not build `m0-wsgi`**, so `stress-pool` and
  `bench-linux-conclusions` — two pre-release gates — failed before their
  first round. The container's build list never gained `postgres` after
  `m0-wsgi` began importing `m0_postgres` for `--pg-listen`, and CI cannot
  see it because there is no such container there. Found by the 1.3.0
  release run; fixed in the four places that name the list, including the
  setup script that creates the container, without which a fresh one could
  not be built at all.

- **A todo whose text is not UTF-8 no longer kills the server** (SPEC G14).
  `m0-datastar`'s `split_data_lines` is a deliberate copy of `m0-http`'s SSE
  line splitter — the wire format stays dependency-free — and kept the
  `[byte=a:b]` slice after the original was fixed. What reaches it is a
  rendered fragment, which is where an application puts request data, so a
  todo reading `a\n<0x80>b` (HTML escaping touches neither the newline nor
  the high byte) cut on a non-codepoint boundary and trapped the loop
  thread: one unauthenticated POST took down the whole process and every
  connected tab. Both cuts are byte-span slices now, pinned by a unit test
  and by `smoke-todo` posting exactly those bytes over a socket.

- `poe check-milestones` read the server soak's version as the first
  `m0serve X.Y.Z` anywhere in its half of the record. A later section's
  heading started carrying a version too, so the sabotage that blanks the
  headline began finding that one instead and stopped being caught — and
  the report would have gone on printing a version the record no longer
  named. It reads the record's own `Last run ... against` headline now,
  which is what the layer's half already did. Nothing on the wire changes;
  the guard does.

## [1.2.0] — 2026-09-12

A stream the server holds against a grant, and a process for the
application layer.

A Django or Flask view that has decided who may read a channel can now
hand the browser a signed URL into `--mount PREFIX=hold`, and a Mojo pool
thread holds the stream without touching the interpreter, verifying the
grant alone. That rests on the tree's first cryptographic primitive,
HMAC-SHA256 in `m0-core` gated by published vectors, and on the piece
under it: a view on a Mojo mount taking the same `M0-Hold` a Django view
takes. Beside them, the application layer is tracked the way the server
is — a milestone `poe milestones` computes, a ledger of standing
decisions, and planned rows naming the application that pulls each.

The served contract grows and does not break: one new mount kind
(`--mount PREFIX=hold`) and three environment variables (`M0_GRANT_KEY`,
`M0_GRANT_KEY_PREV`, `M0_GRANT_COOKIE`), all additive. No existing flag,
header or default changed, so every current deployment upgrades by
version alone.

### Added

- **A grant-verified hold mount** (SPEC I21): `--mount PREFIX=hold`. The
  application keeps every authorization decision in its own views and
  hands the browser a signed stream URL into the mount —
  `m0serve.grant.stream_url(prefix, channel, session=request.COOKIES.get("sessionid"))`
  — and the mount holds the stream on a Mojo pool thread that never
  touches the interpreter, verifying the grant alone: HMAC-SHA256 in
  constant time, expiry against the host clock, the session cookie the
  browser sends against the binding the issuer put in. `M0_GRANT_KEY` is
  the one secret, read by both sides; `M0_GRANT_KEY_PREV` rotates it;
  `M0_GRANT_COOKIE` names the cookie (`sessionid`). A refusal is a 401
  saying `expired` (fetch a fresh URL) or `invalid` (stop), with its
  reason. The mount refuses to start without `--realtime` or the key, and
  `--doctor` agrees. `smoke-hold-mount` is the gate; `test_grant.mojo`
  verifies grants the same issuer signed. The issuer is stdlib-only Python
  in the wheel and, byte-identical, in `apps/django_realtime`.
- **SHA-256 and HMAC-SHA256 in `m0-core`** (SPEC G15), with a
  constant-time tag compare. The first cryptographic primitive in the
  tree: `Sha256` streams and `digest` leaves the state intact, so
  `HmacSha256` absorbs its padded key once per thread and finishes each
  message from a copy — the shape a grant verifier on a pool thread wants,
  with no allocation in the state. Gated by FIPS 180-4's examples, every
  split of one message across the padding boundary, and RFC 4231's seven
  cases; every expected value was produced by CPython's `hashlib` and
  `hmac` rather than transcribed. `wyhash64` was never a MAC (D15); this
  is what a signed grant for a Mojo-held stream, and later a signed session
  cookie, are built on.
- **An SSE hold from a Mojo mount** (SPEC N11). A view on a Mojo mount
  returns the two instruction headers a Django view returns, `M0-Hold:
  stream` and `M0-Channel`, and its pool thread does what a WSGI pool
  thread does with them: rewrites the response into the stream's head,
  sends the loop the same `h` frame before completing, and completes with
  the head. The loop subscribes the slot in the registries it drains, so a
  publish from Python — `m0pub.publish()` from a Django view — reaches the
  Mojo-held stream with its id, the client's `Last-Event-ID` is honoured,
  heartbeats keep coming, and the slot is released when the client leaves.
  Only under `--realtime`; without it the head is served as an ordinary
  response, as a Django hold view's is. A streaming response that is not a
  hold is still refused from a pool thread. `smoke-mojo-mount-hold` is the
  gate, `test_mojo_pool` the unit form, and `poe sabotage-pool` reverts
  both the send and the refusal. The hold module moved into the fork
  (`lightbug_http/hold.mojo`, from `m0-wsgi/src/hold.mojo`) so the WSGI
  handler and the Mojo pool share one copy; `m0_wsgi` still exports every
  name it did.
- **The application layer has a milestone, a ledger and planned rows.**
  `poe milestones` prints a third milestone beside beta and 1.0, computed
  from SPEC section N the way those are from the sheet: no row
  `implemented`, every `planned` row resolved, and a soak on the layer — an
  application outside `apps/` running on `Views`/`Fragment`, recorded in
  `docs/REAL_APP_VALIDATION.md`'s new application-layer section. It reads
  NOT MET, which is the honest state of a layer proven by demos. 1.0 now
  counts `planned` rows outside section N only, since it shipped before
  the section existed. Three rows were `planned` (N11 streaming from a Mojo
  mount, N12 a Datastar form end to end, N13 a login), each with a ROADMAP
  heading naming the application that pulls it and the gate that will
  verify it; N11 was built in this same release, above. `docs/DECISIONS.md` is the ledger of standing decisions,
  D1–D21 at first, D22 and D23 joining with the two hold pieces above, each
  naming the note that argues it and what would retire it;
  `check-docs` fails when a row's note does not exist, its condition is
  empty, its id is repeated or out of order, or its `superseded by` names
  no row, and `--selftest` reverts each rule against the page.

### Fixed

- **Dependabot PRs auto-merge again.** `dependabot-automerge.yml` compared
  the author `gh pr list --json author` reports against `dependabot[bot]`,
  and gh 2.98 on the runner renders a bot as `app/dependabot`, so from
  2026-08-17 every Dependabot PR was refused by a green run. The gate now
  reads the author from the REST API (`user.login` and `user.type`, the
  API's contract rather than the CLI's rendering), and a refusal that is
  never routine on a `dependabot/` branch — not Dependabot's, or from a
  fork — exits 1. `check_dependabot_gate` in `scripts/check_docs.py` pins
  both, sabotaged four ways.

- **The container gates carry a moved file.** `stress-pool` and
  `bench-linux-conclusions` tar the tree into the `m0lin` container, and a
  tar carries no deletion, so the hold module's move into the fork left a
  copy behind that failed the source stamp on every container gate of this
  release. The two `/src` copies now clear their source directories first
  and `linux_sync.sh` mirrors removals into `/work`; and `core` is in the
  sync's build list, because m0-core changed for the first time and the
  stamp, which hashes sources, matched over an artifact built weeks
  earlier.

## [1.1.0] — 2026-09-11

A remote crash fix, and an application layer for programs written in Mojo.

The crash is why this release is not held for the rest of section N: a
request carrying a byte that is not UTF-8 killed the server process, from
any client, with no handler involved. Five slices on the serving path had
it; the query parser and the cookie jar have had it since they were
written, so every release including 1.0.0 shipped it.

The layer is ten capabilities ([SPEC](docs/SPEC.md) section N), each gated
on the wire, each built app-first — an application written deliberately
ugly, a smoke that asserts its bytes, then every piece lifted out from
under that green gate. An application written in Mojo now has a URL table
whose views the compiler holds to reading or writing their state, a
fragment renderer that emits htmx or Datastar attributes from one source,
a page-or-fragment decision the framework makes from the request's own
headers, reverse routing that fails to compile on a misspelled route, and
a form parser. What it does not have is a real application on it; that is
the next round.

Nothing in the served contract changed — no flag, no environment
variable, no header — so this is an upgrade by version alone.

### Added

- **One renderer, two transports** (SPEC N7–N9). `Fragment` takes its
  frontend vocabulary as a type parameter: `Fragment[Htmx]` emits
  `hx-post`/`hx-target`/`hx-swap`, `Fragment[Datastar]` emits
  `data-on:EVENT="@post('…')"` with the event chosen by the element (a
  form submits with `{contentType: 'form'}`, a field changes, a button or
  anchor clicks with `__prevent`) and no target, because Datastar morphs a
  `text/html` answer into the element whose id it carries — the id the
  fragment owns. An app names its vocabulary once (`comptime Frag =
  Fragment[Htmx]`) and never writes an attribute of either. A Datastar
  URL sits inside a JavaScript string literal that HTML escaping cannot
  protect, so a URL carrying `'`, `\`, CR or LF is refused (`url_for`
  encodes them), and both vocabularies refuse a verb outside the five.
  `apps/datastar_todo`'s list is now that renderer, one line, verbatim
  as the `elements` of every broadcast frame (`test_fragment_frame.mojo`)
  and byte-identical on a fresh page load (`smoke-todo`); its routes are
  values reversed with `url_for`. `page_or_fragment` reads four headers:
  `Datastar-Request: true` gets the bare fragment, and
  `HX-History-Restore-Request: true` or `HX-Boosted: true` beside
  `HX-Request: true` gets the whole document, since htmx swaps a history
  restore's body into the page it is rebuilding and a boosted navigation
  takes a document's body; `Vary` names all four on every answer. A table knows
  where it is mounted: `Views[S](Mount("/native"))` registers under the
  prefix, `Mount.url_for` reverses to it, and `PoolContext.prefix` carries
  the lane's own prefix to a `PoolHandler`, so `m0serve`'s `MojoMount` —
  now a `Views` table — renders links that are followed under
  `--mount /native=mojo` by `smoke-mojo-mount`, the way `smoke-hybrid`
  follows Django's `reverse()`. An expression tier over the builder —
  `el`, `void`, `attr`, `flag`, `text`, and `Fragment.el` for a swapping
  element — makes an element a string so a renderer nests like its
  markup with each escaping context named; `fragment_notes`'s list is
  written in it, its detail view in the builder, both pinned
  byte-identical (SPEC N10); a child left in the attrs slot is refused
  rather than rendered into the tag name. The research behind the Datastar arm is
  [one-renderer-two-transports](docs/notes/one-renderer-two-transports.md).

- **A framework layer for applications written in Mojo** (SPEC section
  N), built app-first. `apps/fragment_notes` serves the notes resource as
  an htmx app; it was written deliberately ugly, gated on wire output
  alone (`smoke-fragment-notes`, sabotaged six ways), and then refactored
  onto each piece under that green gate, in this order: `Views[S]` — a
  view is a function the URL table names, `add_read` hands the state
  borrowed and `add_write` `mut` (compile-checked by `sabotage-views`),
  405 with `Allow`, no fallthrough; `Fragment` and `Html` in m0-core — a
  fragment writes its root id once and `swap` generates the attribute
  targeting it from that id, `attr` owns the delimiters and escapes;
  `page_or_fragment` — the framework decides from `HX-Request` whether to
  wrap, `Vary` on both, the shell a `thin` function over a context because
  a trait cannot cross the `.mojoc` boundary; `url_for` — the route
  pattern is a `comptime` constant given to the table and reversed with
  arity checked and values encoded; `form(req)` — an ordered multimap,
  empty unless the content type is the form's. `apps/notes_api` runs on
  `Views` too, wire-identical under `smoke-notes`; `apps/views_pattern`
  from draft PR #273 was not landed. The design and the refusals are
  [docs/notes/a-fragment-that-names-itself.md](docs/notes/a-fragment-that-names-itself.md).

### Changed

- **Datastar pinned at v1.0.3** (was v1.0.2): `m0-datastar`'s `VERSION`,
  both demos' CDN bundles and the conformance cases' source. A patch
  release with nothing in `sdk/` changed and every attribute rule the
  tree records unchanged; the todo demo was driven in Chromium against
  the new bundle for the three recorded traps (`data-init` opens the
  stream, colon-keyed attributes, `retry: 'always'` reconnects across a
  restart) before and after the renderer moved onto `Fragment`.

- **The fragment layer hardened after review** (SPEC N2–N6 unchanged, the
  gates widened). `Views` keeps its routers private (a route registered
  past the tables was a call through whatever the out-of-bounds index
  held) and exposes `allow_header`, which merges both tables; a loop route
  in the wrong method is 405 with that `Allow` rather than 404, `OPTIONS`
  on any registered path is 204 with it (a preflight used to get a 405
  whose `Allow` named OPTIONS), and a loop route that reaches `dispatch`
  is answered there. `url_for` refuses an empty value, which reversed
  `/notes/:id` to the collection. `reply.vary` keeps `*` alone and treats
  an empty field as absent. `Html` and `Fragment` move from m0-core to
  m0-http beside their consumer — the four-function sentence was an
  inventory, not the constraint, and a frontend library's attribute names
  do not belong in the package `build-ffi` compiles into `libm0core`;
  `finish` consumes the builder and the constructor refuses an id `#id`
  cannot select. `page_or_fragment` takes a status, so a styled 404 is a
  404. `form(req)` is `Optional`, None unless the media type, compared
  whole, is the form's. `poe check-mojoc-trait` is the probe behind the
  thin-function shell, with a control. The fragment smoke follows a
  rendered link rather than typing the path, and sends a form body
  carrying a byte that is not UTF-8.

- **The real-application soak was re-run against 1.0.0**
  ([docs/REAL_APP_VALIDATION.md](docs/REAL_APP_VALIDATION.md)). All four
  applications, six rows, 215,214 requests compared byte for byte against
  gunicorn, uvicorn and daphne captures, zero failures, every slot
  returned, and six SIGTERM drains all inside 0.26 s. The release bumped
  the version and left the record naming 0.19.0, so `poe milestones` had
  been printing the soak STALE since the merge; it reads MET again. One
  commit had touched the request path in between — the drain split that
  lets the loop inversion step it — and the churn rows are what put load
  through it.
- **The soak's binary fixtures are generated from a seed**
  (`scripts/soak_fixtures.py`). color-separation's two noise PNGs were
  regenerated unseeded every pass, so the manifest's `bytes` pins had to be
  re-measured by hand each time; the same seed now reproduces both files
  byte for byte.
- **The bare-figure rule reads a list of pages, and the roadmap is on it**
  (`FIGURE_PAGES` in `scripts/check_docs.py`). The roadmap's figures
  drifted precisely because the rule was pointed at one page, so the fix
  for the drift and the fix for its cause are the same edit. The selftest
  proves coverage rather than adjacency: it drives the real pages through
  the real wiring with one doctored, pins the list's membership so a page
  cannot be dropped quietly, and reverts the rule the way the other doc
  rules are sabotaged — with a page removed, the same drift goes
  unnoticed. README.md, `docs/SPEC.md` and `docs/RUNNING.md` are still
  outside it; the selftest prints their bare-figure counts so the backlog
  cannot rot into a claim.

### Fixed

- **A request carrying a byte that is not UTF-8 crashed the process.**
  Five sites on the serving path sliced a request-derived `String` with
  `[byte=a:b]`, which asserts a codepoint boundary and traps: `unquote`
  (so one `GET /?x=<0x80>%41` killed the loop thread before any handler
  ran, every app and the production WSGI deployment alike), the cookie
  jar (built for every request, so `Cookie: a=<0x80>` did the same), the
  static mount's path handling, the `Accept` negotiator and the ETag
  matcher. Bytes above 0x7F pass the header parser as obs-text, so all of
  them were one request away. Every slice is now a byte-span slice, which
  has none; `unquote` is a single byte walk and requires exactly two hex
  digits for an escape (SPEC G14, one test per site, plus both smokes on
  the wire). Found by a review probe of the form parser on a pending
  branch; the query path and the cookie jar had it on every release.
- **`reply.vary_accept` overwrote `Vary`.** A response that varied on two
  request headers kept whichever was set last, unnoticed while nothing set
  `Vary` twice. `reply.vary` appends without repeating a name;
  `vary_accept` is built on it.
- **`apps/notes_api` deleted on route drift.** Its handler-id chain ended
  in a bare `return self._delete(...)`, so a route registered without its
  own arm did not 404, it deleted. The chain is gone with the move to
  `Views`, whose `dispatch` has no fallthrough to reach; `test_views.mojo`
  is the gate. (A wire assertion was first described as guarding this; it
  cannot, since the old chain answered 405 before the chain for any
  unregistered method, and the claim is withdrawn.)

- **The Mojo pool's distribution test asserted the pool's PRE-elastic wake
  contract**, and failed pull requests that could not reach `MojoPool` at
  all — most recently on a macOS runner with `distinct=1` at 783 ms. The
  test submits eight 60 ms jobs to three threads and requires more than one
  to answer, which is what a served burst does; but it drives a bare pool
  with no event loop, and since the elastic rules landed the wake that
  spreads such a burst is the LOOP's, not `submit`'s. `submit` wakes nobody
  while a thread of the lane is busy or spinning, precisely so a burst of
  trivial jobs does not put N threads on the GIL; a thread that is not
  coming back soon is `wake_aged`'s case, once per pass. With no loop there
  was no wake at all, so a spinner descheduled across the burst took all
  eight jobs at 60 ms apiece. The test now makes the loop's own
  bottom-of-pass call, which pairs it with the production shape rather than
  with `M0_POOL_ELASTIC=0`, the arm nobody runs. Reproduced deterministically
  by stalling the spinner across the burst: 10 of 10 rounds failed before,
  0 of 20 after, and under CPU load the fixed test's median run fell from
  295 ms to 228 ms because the siblings no longer sit parked.

- **A milestone sabotage stopped applying at 1.0.0.** The test that deletes
  the soak record's version and insists the checker notices searched for
  the literal `m0serve 0.`, which the 1.0.0 headline removed from the file,
  leaving the mutation a no-op. `sabotage()` reports a no-op as NOT
  APPLICABLE and fails, so it failed safe; it now matches the shape of a
  version rather than its digits.
- **Three pages still told readers the API would break at 1.0.** The
  release replaced the docs site's caveat and missed the README's two and
  `docs/RELEASING.md`'s, which cited the README for a statement no longer
  there. All four now say what is actually stable: `m0serve`'s flags and
  environment variables, the `M0-Hold`/`M0-Channel` headers, and
  `m0pub.publish()`. The roadmap and the docs index no longer describe 1.0
  as ahead of the tree.
- **The roadmap argued from figures that had drifted by roughly half.**
  Its "Not planned, and why" section frames every refusal with the rps
  numbers, and they read 116k on the hello row against a measured 192.3k,
  and 61k on the executor against 80.8k. The arguments they support are
  unchanged; the numbers are spans now, rendered from the same artifacts
  the benchmark page uses. It also cited `lightbug_http/parsing.mojo`,
  which lives in `http/`.

## [1.0.0] — 2026-09-09

Every capability in [docs/SPEC.md](docs/SPEC.md) names a gate, every
`planned` row is built or refused with a reason, the real-application soak
is current against this version, and each known issue declares what would
retire it. `uv run poe milestones` computes those four from the sheet and
the roadmap rather than from anyone's memory, and CI prints it on every
pull request.

The number changes what a minor release may break, and nothing else. The
five [known issues](docs/ROADMAP.md#known-issues) are unchanged by it and
are all upstream or packaging matters — Mojo 1.0.0 is still the only stable
toolchain release, so the `PythonObject` reference leak and the
free-threaded executor refusal both wait on it.

### Added

- **A view parallelises across `--blocking-threads` only if it releases the
  GIL, and a gate says so** (SPEC E19). `--blocking-threads N` gives a view
  N handler threads; whether N of them run at once is decided inside the
  view. C5 covered the isolation half of that pool and nothing covered the
  concurrency half, which is how an embedding server came to serve the same
  rate on one handler thread and on two, and a third less on eight: Core
  ML's `predict` holds the lock for its duration. `bareapp`'s `/work` is one
  hashlib call over two buffer sizes either side of `HASHLIB_GIL_MINSIZE`,
  so the lock is the only variable between its modes, and
  `smoke-pool-parallelism` compares the two concurrency ratios on one server
  in one run. The measurement, including what MAX does differently and why
  it is not a reason to switch backends on a Mac, is
  [docs/notes/gil-and-the-handler-pool.md](docs/notes/gil-and-the-handler-pool.md).
- **`--doctor` reports the CPU budget the process can actually use.**
  `usable_cpus` reads the affinity mask and the cgroup quota rather than the
  machine's core count, so a container with a fraction of a host's CPUs
  sizes its zero-config pool from what it was given.
- **`--doctor` reports which loop an ASGI deployment resolved to**, as
  `topology.loop`: `pump` (the default, two threads), `inverted`, or `n/a`
  where no executor serves the application. It reported `mode: single` for
  both shapes before, so the startup banner was the only way to tell them
  apart.
- **FastAPI is gated through the ASGI bridge** (SPEC L19): routing, a
  `StreamingResponse` and a WebSocket the application closes itself, with
  the log assertion as the load-bearing half.
- **A page that restates a capability row's status is checked against the
  sheet.** `check-docs` fails when prose gives a row a status
  docs/SPEC.md disagrees with, or names a row that does not exist. The
  validation record had called a row planned for three days after it was
  built and gated, which is the most misleading kind of drift because that
  page reads as a live status board. Narrow on purpose: it fires only where
  a status is presented as a token beside a row id, never on a status word
  that merely shares a sentence.
- **`poe bench-linux-conclusions`, and `--remote`.** The benchmark page's
  conclusions re-run on Linux, in the local container or over ssh on a
  rented box, with an empty comparison failing rather than passing.

### Changed

- **The inverted loop's drain is stepped.** Under `M0_INVERTED=1` a request
  sitting in an `await` when SIGTERM lands is answered when it finishes,
  rather than being cut off by a drain that could not step the asyncio loop.
- **The loop inversion is documented, and deliberately not a default.** Its
  earlier "nothing at saturation" verdict had expired: re-measured, it is
  ahead per core at high concurrency and well ahead of uvicorn with uvloop
  on a single CPU, and behind the default from two cores up. `--doctor` and
  the banner both name which loop is running
  ([the record](docs/notes/inversion-on-a-constrained-box.md)).
- **Two of the benchmark page's four conclusions invert on Linux**, and the
  artifact system could not have told you, because every rendered artifact
  had been recorded on macOS. `poe bench-linux-conclusions` is the check,
  and the page says which conclusions are platform-specific.
- **The WSGI and ASGI modes page, and Running, say when handler threads
  help.** The modes page called `--workers` "the answer that works under the
  GIL", which reads as though threads never give parallelism; it now states
  the rule E19 gates, and the `--blocking-threads` row in Running says what
  decides the number.
- **BENCHMARKS.md's intro and caveats are shorter**, and Reproducing names
  the script behind every table.
- **BENCHMARKS.md's prose may not carry a bare figure.** Every number in
  the page's sentences is either a span the renderer recomputes from the
  newest artifact or sits in a paragraph whose `<!-- observed: WHERE -->`
  marker says where it was observed, and `check-docs` refuses one that is
  neither (`check_bench_prose_figures`, sabotaged in its selftest). Four
  hand-typed figures had outlived their artifacts: the inline row's ratio
  contradicted the span beside it, the executor's p50 pair quoted the
  previous run, the isolation effect understated its own table by half,
  and the per-thread loop costs predated the ring handoff. The isolation
  claim's figures (the unpooled climb, the hold, the pooled p99 and the
  factor between them) and the one-thread rows' gap are spans now,
  computed from the same grouping the table renders; the histories are
  marked with the note or artifact that records them.

### Fixed

- **A `poe` shell task's `"$@"` is empty**, so `bench-linux-conclusions
  --remote` silently dropped its flag and reported success from the local
  machine rather than the rented one.
- **The Linux container's sync could rebuild nothing, or rebuild the wrong
  tree, and report success either way.**

## [0.19.0] — 2026-09-07

### Added

- **`--max-keepalive-requests N` / `M0_MAX_KEEPALIVE_REQUESTS`.** The
  keep-alive request cap is configurable (0 = never close for count) and
  reported by `--doctor`; SPEC A3 names it, and the cap smoke pins 100
  explicitly so the gate is independent of the default.
- **Pool instruments for the tail question.** Under `M0_POOL_DEBUG=1`
  each pool thread prints histograms of its ring wait, GIL wait and
  service at shutdown, and the loop prints how many of its waits
  returned late past their cap and how many passes ran over 1/2/4/8 ms;
  `M0_POOL_SPIN_US` sets the idle spin for measurement. Together with
  the access log they split a request's time into what the server does
  and what happens between the server and the client, which is how the
  cap was found (docs/notes/pool-tail.md).
- **The pool's Linux reproducers are in the tree, and pre-release.**
  `scripts/probes/` holds the instruments the engineering record quotes
  (`herd.c`, `handoff_pingpong.c`, `bench_threads.py`, `bench_arms.py`,
  `bench_slow.py`, `xctrace_report.py`) and the two Linux reproducers
  (`phase5_probe.py`, `hold_race_probe.py`), which lived untracked under
  a session directory until now. `poe stress-pool` (SPEC E18) runs the
  reproducers in the `m0lin` container — twenty rounds of
  `smoke-django-realtime` phase 5 with a fresh server each, then forty
  holds under a busy loop — once per shipped wake mode, and is a
  pre-release step beside `stress-asgi` (docs/RELEASING.md); the
  phase-5 probe now exits non-zero on a failed round. `poe probe-herd`
  runs the wake-herd ping-pong. The container recipe (`linux_setup.sh`,
  `linux_sync.sh`) moved there too.
- **Prose may not cite an untracked path.** `check-docs` fails when a
  page under `docs/`, the README, CLAUDE.md or this changelog cites a
  `.claude/` path git does not track — the record cannot cite a file
  nobody else can open. Its selftest proves the rule fires. The 2026-09-04
  soak driver outputs the real-app record cited there are now
  `bench/soak/2026-09-04/`.
- **A rendered benchmark table may not be stale.** Bench artifacts record
  the version they measured (`environment.version`), and
  `render_bench_docs.py --check`, inside `check-docs`, refuses the newest
  artifact of any rendered kind that lacks the stamp, was recorded on a
  dirty tree, or is more than one minor version behind `pyproject.toml`;
  its selftest proves each rule can fail. Found by asking whether the
  published numbers were current: the slow-view isolation table was from
  2026-08-26, before the detached loop and the pool hand-off changed its
  rows, and two headline artifacts were stamped "dirty tree".
- **The benches refuse to lie about their own variance.** Both shell
  benches refuse to start, and to begin a round, while any process outside
  their own tree is above half a core across three samples
  (`scripts/bench_guard.py`, whose selftest runs inside `check-docs`);
  the mixed-workload artifact records the round and the p99's min and
  max, its table renders the spread beside each median and
  `render_bench_docs --check` refuses one with fewer than three rounds;
  and the check refuses any rendered artifact whose rows moved more than
  5 % against the comparator rows' own move since the previous one — the
  contamination signature — unless `--accept-drift` stamped it with the
  comparison it accepts. Three recordings on 2026-09-06 were wrong in
  ways the scripts could not see (docs/notes/elastic-pool.md).

### Changed

- **The keep-alive request cap defaults to 1000 (nginx's), from 100.**
  Every close is a reconnect for the client, and one reconnect per
  hundred requests IS the client's 99th percentile: the whole of the
  fast-route tail BENCHMARKS.md conceded to Granian. Measured at equal
  shape on 3.14t (one worker, four threads, `wrk -c16`, Django, slow
  views beside): cap 100 p99 0.6–3.8 ms; cap 0 or 1000 0.45–0.64 ms;
  Granian, which has no cap, 0.51–0.55. Four workers: 1.5–4.0 ms to a
  flat 1.3, the maxima 25 ms to 5. The server's own header-to-send p99
  was 0.45–1.35 ms throughout; the loop was never late; GC, the GIL
  hand-off barrier, QoS placement and the idle spin moved nothing
  (docs/notes/pool-tail.md).
- **The zero-config pool serves a trivial view at the one-thread rate.**
  `m0serve app.wsgi` runs `--blocking-threads min(cores, 8)`, and those
  eight threads served a bare WSGI view at 0.67x the one-thread shape on
  1.6x the cores: a burst of jobs was taken by every thread awake, they
  serialized on the GIL with an OS wake per hand-off, and each wake
  woke every parked thread on macOS (one datagram into eight blocked
  receivers costs 59 µs of CPU against 3) or the coldest one on Linux.
  The pool now behaves as one thread until a job has waited: one idle
  spinner per lane, no wake while a thread is busy or spinning, a wake
  by name on each thread's own channel to the thread that parked last,
  and the loop waking a parked sibling for a ring that holds a job and
  has not been drained for 200 µs — which is what keeps a fast request
  from waiting out a slow view, and replaces the chained wake; a ring
  whose pop count moves is a queue one thread is draining, and is left
  alone however deep on a GIL build, while without a GIL the pool wakes a
  parked thread whenever there is one and counts the wait from the push,
  a parked thread beside a queued job being an idle core there. Same session,
  arms alternated, 16 connections: 172.5k / 179.2k rps on the
  zero-config shape against 176.9k / 179.4k on one thread, from
  118.4k / 122.6k before, on the one-thread shape's cores
  (docs/notes/elastic-pool.md). `M0_POOL_ELASTIC=0` is the A/B knob.
- **The event-loop thread's header path costs what tokio's does.** A
  known-name index and a presence word on `Headers` make every lookup
  the loop performs per request O(1) and the parser's duplicate check
  one AND per field; inserts copy by `memcpy` and lowercase eight bytes
  at a time; the token scanner verifies sixteen bytes per vector; the
  header read lands in the connection's buffer with no staging copy;
  the encoder writes a header line as one reservation; the completion
  drain no longer allocates. Same session, arms alternated, bare WSGI
  at one worker and one handler thread: 186k rps against 170k at 16
  connections and 205k against 186k at 256, the loop thread's cost per
  request from 5.8 µs to 5.1 and 5.3 to 4.7 — the tokio thread's
  figures — and the row 0.98x Granian at 16 connections, 0.99x at 256.
  The isolated parse went from 0.89 µs to 0.62 and the whole user-space
  request from 1.98 to 1.33 (docs/notes/loop-user-space.md, which also
  records two levers measured and not kept: a spin before the loop
  parks, and servicing completions between reads).
- **The `--blocking-threads` handoff rides in-memory rings**, and the two
  socketpairs carry only wakes and payloads. A bounded MPMC ring per pool
  lane for jobs and one for completions replace the four datagram
  syscalls a request used to cost; a pool thread spins before it parks,
  and a wake is sent only to a side that has announced it is parked
  (`lightbug_http/ring.mojo`; the protocol in `offload.mojo`'s docstring).
  Same binary, same session, bare WSGI at one worker and one handler
  thread: 155k rps against 131k at 16 connections and 184k against 154k
  at 256, the loop thread's per-request cost from 7.5 µs to 6.3 and 5.3.
  Found by measuring per thread rather than per core
  (docs/notes/loop-thread-bound.md): the loop was the saturated stage and
  1.2 µs of its 7.2 was the handoff. `M0_POOL_RING=0` restores the
  datagram handoff for an A/B.
- **The layer split measures one worker in three shapes**, and the
  head-to-head with Granian is same-shape. An explicit `--workers 1`
  switches the zero-config pool off, so the old one-worker row was the
  loop alone against Granian's one blocking thread: it understated
  m0serve's throughput by a third and flattered its per-core figure. The
  table now has the inline row (the bridge measurement), the one-handler-
  thread row (Granian's shape) and zero-config (what `m0serve app.wsgi`
  runs); the four-worker rows are one handler thread per worker on both
  servers. All four tables re-recorded on 0.18.0; the landing page, README
  and llms.txt state throughput as the comparison it is rather than as a
  limit, with the numbers as spans the renderer keeps current.

## [0.18.0] — 2026-09-05

### Added

- **Under `--workers N`, the worker that wins an accept gives the
  connection to the least-loaded sibling** (SPEC E16; `smoke-accept-spread`
  on both CI legs; `lightbug_http/accept_share.mojo` over `c/fdpass.mojo`;
  docs/notes/accept-sharing.md). Every worker waits on the one listener
  and the first to wake drained the whole backlog, the same one nearly
  every time: 32 of 32 connections on macOS, 23 to 31 of 32 on Linux, so a
  keep-alive load ran at one worker's throughput. `SO_REUSEPORT` is not
  portable (Linux hashes, macOS sends everything to the last-bound
  socket) and `EPOLLEXCLUSIVE` made it worse, so the acceptor reads each
  sibling's `active + pending` off the pre-fork shared page and passes the
  socket over an `AF_UNIX` channel with `SCM_RIGHTS`; the receiver admits
  it by the accept path's own tail. A hand-off that fails for any reason
  keeps the connection where it is. After: 16/16 on every platform and
  mode for bursts and ramps alike, one worker pays nothing, two workers
  tie on keep-alive throughput, and the Core ML embedding app on two
  spawned workers goes from 1779 to 3090 req/s (uvicorn's two workers:
  2510) with a p99 of 2.8 ms against 5.1. `M0_ACCEPT_SHARE=0` is the A/B
  knob.
- **The executor shim is a Python file.** `packages/m0-wsgi/shim/m0_shim.py`
  is the source of truth for the ~1,500-line program `PyBridge` execs —
  WSGI's `start_response`, protocol detection, the asyncio executor, the
  streaming seam's credit and ownership rules, the pub/sub object — and
  `scripts/render_shim.py` (`poe render-shim`) renders it into the Mojo
  constant `bridge.mojo` embeds (`src/shim_source.mojo`, generated and
  committed, so the binary is still self-contained). `check-docs` fails
  when the rendering is stale and proves the literal decodes back to the
  file byte for byte, which is what lets `poe test-shim` read the file
  and still be testing the binary's program; the renderer's `--selftest`
  proves the check can fail, and a pyflakes step joins the `Docs`
  workflow (`poe lint-shim` locally) — its first run found the one unused
  import the audit had found by hand. The question of whether Python is
  the right home for the shim was answered first, with measurements:
  docs/notes/shim-language.md. The program the binary execs is unchanged
  except for that import and black's formatting.
- **`--spawn-workers` / `M0_SPAWN_WORKERS`** (SPEC E15; `smoke-spawn-workers`).
  Each worker is forked and at once execs the binary afresh, inheriting the
  listener, the bus channels and a file-backed shared page by descriptor,
  so an application may use what a forked child cannot: Core ML,
  Objective-C, CoreFoundation, libdispatch — `urllib.request.getproxies()`
  on macOS kills a forked worker 3 of 3 and answers under spawn. The
  supervisor, respawn (through a fresh exec) and signal propagation are
  unchanged; an image that cannot exec exits 78 and ends supervision
  rather than spending the respawn budget. `--doctor` reports
  `topology.worker_mode`. The default stays fork: start-to-ready with two
  workers is 82 ms forked and 92 ms spawned, and throughput ties once
  started (195k against 199k req/s on hello, alternated). On its own it did not
  buy the second worker's throughput on macOS, because the same worker won
  nearly every accept and the Core ML app served 1675 req/s on two spawned
  workers as on one; accept sharing (E16, above) is what did.

### Changed

- **The documentation site is shorter.** The sidebar lists eight pages
  and a link to the map, with nouns for labels; the top bar is Docs,
  GitHub and PyPI. The quickstart ends at the two-tab demo, and its
  two-worker, Flask and gunicorn steps are `docs/QUICKSTART_NEXT.md`, run
  by the same smoke in the same scratch directory (`run_quickstart.py`
  takes several `--doc` pages). `SPEC.md` and `ROADMAP.md` open with the
  reference rather than a preamble: the row audit moved to the
  traceability note, and the PythonObject-leak and accept-placement
  investigations became design notes of their own. `llms-full.txt` drops
  from eight pages to six; the roadmap and the conformance page are under
  `More` in `llms.txt`.
- **`OwningList` retired.** The fork's private copy of `List`
  (`lightbug_http/utils/owning_list.mojo`) existed for elements that are
  Movable but not Copyable — per-slot response buffers, WebSocket parsers,
  connection provisions, parked requests and responses, the mounted
  `WSGIApp`s, the client's idle connection. Mojo 1.0's `List` takes those
  as it is, so every site is a plain `List` and the file is gone.
  Measured at parity: the hello row 171.6k/172.7k/174.8k req/s at
  c16/c64/c256 before and 172.8k/173.7k/176.4k after, the user-space
  request in `bench_http_parts` 2.11 → 2.05 µs. Probed on the way: the
  reason `ExecutorState` stays behind an address rather than inside the
  Python-bound `ExecutorPort` is not the container but the element —
  `PythonModuleBuilder`'s derived `Writable` recurses into
  `HTTPResponse`, whose cookie jar holds a `Dict` that is not `Writable`;
  the docstring now says so.
- **The event loop holds no thread state while it serves** (`_serve_offloaded`,
  `DetachingBackend.set_loop_detached`, SPEC E11; docs/notes/detached-loop.md).
  Under `--blocking-threads` and under the ASGI executor the loop used to
  re-acquire the GIL after every wait and parse, encode and send while
  holding it — measured blocked in that acquire 36–45 % of wall time under
  load, so its work never overlapped the Python threads'. Detached, one
  binary and one env var, arms alternated: the ASGI executor 67.5k → 101–109k
  rps at 16 connections and 84k → 158k at 256 (1.8 cores where it had one);
  bare WSGI with one pool thread 71k → 140k. The one place the loop runs
  Python, the inline fallback, attaches for itself (`WSGIHandler.func`).
  `M0_LOOP_ATTACHED=1` restores the old shape for an A/B.

- **Pool threads hand the GIL to the thread that waited for it**
  (`_yield_turn` in `blocking_pool.mojo`; `poe probe-pool-fairness`,
  pre-release; SPEC E11). The attached loop had been an accidental
  fairness pump: as a GIL waiter on every pass it forced CPython's 5 ms
  switch between pool threads, and without it a thread that finishes a
  job re-takes the GIL before the thread it signalled runs — a fast-route
  max of seconds under a CPU-bound view with four threads (the same tail
  Granian's WSGI pool shows on a GIL build). Two atomic counters: a thread
  that has held its run for a millisecond and drops the GIL while another
  is parked on it yields until that one has attached. Nothing is held
  across a job, so slow-view isolation is untouched, and no waiter's extra
  wait exceeds the millisecond. `apps/wsgi_bare` gains `/busy`, the CPU-bound view the probe
  drives.

- **Repo hygiene from the 2026-09-05 audit.** `.gitignore` covers
  `.claude/worktrees/` (a 652 MB checkout of this repo was sitting
  untracked) and `.claude/handoffs/`; the deploy workflow pins
  `setup-flyctl` to the 1.5 release commit instead of `@master`; nine
  pyflakes items (unused imports, a placeholder-free f-string) cleared.

### Removed

- **`StringSlice` → `StringSpan`**, 98 sites across `packages/`, `apps/`
  and `scripts/`: the 1.0 name, from the prelude, ahead of the alias
  starting to warn on a later pin. A pure identifier substitution; the
  ratchet stays at 0.
- **Two uninstantiated bodies in the fork**, and the UDP send path one
  anchored: `memmove` in `io/bytes.mojo`, and `Socket.send_to` with
  `UDPConnection.write_to`, the `sendto` binding and its twenty-one error
  structs plus the `SendtoError` variant (NOTICE has the list). Each held
  a deprecated spelling the compiler never flagged because nothing
  elaborated the body; a bare `undefined_name` in each survived
  build-all, test-all, build-apps and build-serve, which is the proof.
  743 lines gone.

### Fixed

- **A header line cut between its CR and its LF was answered 400.**
  `scan_to_eol` treated a carriage return as the buffer's last byte as a
  malformed line rather than a line whose LF had not arrived, so a
  request whose TCP segment boundary fell between the two bytes of a
  header's CRLF was rejected instead of waited for; the request line and
  the terminating empty line already answered incomplete there. Found by
  the release fuzz sweep (`fuzz-request-long`, seed 5, iteration 147067)
  under its invalid-is-sticky rule, reproduced on v0.17.1, so latent in
  every release before this one. `test_parsing.mojo` pins the shape.
- **Five `String` builders read a local buffer after Mojo had freed it.**
  `Span(unsafe_ptr=out.unsafe_ptr(), length=...)` carries no origin, so
  under the manual's after-every-sub-expression destruction the `List`
  behind it is gone before `String(unsafe_from_utf8=...)` copies — a probe
  on the pinned compiler printed the buffer's free before the copy. The
  output was right only because the freed block still held its bytes.
  `Span(out)` at `_format_hex`, `escape_json_string`, `parse_json_field`,
  the access-log line and the Datastar SSE builder; `compute_etag` takes
  the same spelling.
- **The warning ratchet's baseline is 0, from 68.** All three "unfixable on
  Mojo 1.0.0" claims failed to reproduce when probed against the pinned
  compiler: `abi("C")` is a function effect placed before the return arrow
  (the four `@export`s in `ffi_exports.mojo`), `unsafe_alloc` is importable
  from `std.memory.alloc` (the twelve fork allocation sites), and a
  doc-string summary may open with a backticked identifier (the 52 test and
  `multiworker.mojo` summaries). CLAUDE.md's Mojo 1.0 patterns 8 and 9 are
  corrected in the same pass: `List` and `Optional` take Movable-only
  elements on this toolchain, so `OwningList` is a retirement candidate.

## [0.17.1] — 2026-09-03

### Added

- **Citation tracking** (`scripts/check_citations.py`, `poe
  check-citations`, `.github/workflows/citations.yml`, SPEC F15 and
  F16). Every `RFC nnnn` in a tracked text file is looked up in
  `scripts/rfc_status.json`, a committed snapshot of the RFC Editor's
  per-document JSON: a citation of an obsoleted RFC fails every pull
  request unless its paragraph cites a successor, and a monthly job
  re-fetches the snapshot and files an issue when a document moves.
  First run it found the parser, the chunked decoder, the date
  formatter, content negotiation and their tests citing RFC 7230 and
  RFC 7231 (replaced by RFC 9110 and RFC 9112 in 2022) and RFC 5987
  (replaced by RFC 8187); each is re-pointed to the successor's
  section. The rules are pure functions of text, selftested and
  sabotaged the way the spec sheet's are.

- **The live two-tab demo beside the docs** (`apps/demo`, `deploy/demo`,
  `poe smoke-demo`, SPEC M17; https://demo.m0serve.dev once the Fly app
  exists). One file of sync Django in the quickstart's shape, served by
  `m0serve --realtime --workers 2` from its own Fly app on a subdomain --
  never a mount inside the docs app, so untrusted realtime traffic shares
  no process with the site -- and on ONE machine, because the publish bus is
  per process. The page holds an SSE stream and a WebSocket side by side,
  says which m0serve version serves it and which worker published each
  line, and carries what a public page needs that the tutorial does not:
  channels namespaced per visitor by a random cookie token (a stranger's
  tab hears nothing), 280 bytes a message (413), 30 a minute per visitor
  per worker (429 with `Retry-After`), a foreign `Origin` refused on the
  upgrade, binary frames dropped, nothing stored. `scripts/demo_probe.py`
  proves every one of those from outside -- against the image built from
  the tree's wheel in the `pid1` job, with m0serve as PID 1 and `docker
  stop` draining with a stream held, and against the live URL in the deploy
  workflow's new `deploy-demo` job (secret `FLY_DEPLOY_DEMO`). Both
  verify steps wait for the health path to answer steadily before asserting
  anything, and the demo's retries the probe up to three times 20 s apart:
  `flyctl deploy` returns before the edge is stable, and the first deploy's
  verify hit a TLS EOF from the proxy while Fly was creating the second
  machine and bouncing the first. Four
  sabotages of the application -- shared channel, no rate limit, no Origin
  check, no size cap -- each failed the probe in the phase that names the
  guard.
- **The headline claim, gated clause by clause** (SPEC I20, K11, M16;
  `QUICKSTART.md` §7–8, `poe smoke-flask-realtime`). The sentence names
  Flask, and nothing held a stream or a socket from a Flask view: K10 proves
  plain WSGI. The quickstart now carries the same four views in Flask,
  served with `--workers 2` and checked with curl, and `smoke-flask-realtime`
  extracts that file from the page itself and drives it with the Django
  rows' RFC 6455 probe, one stream and one socket pinned per worker. Gating
  it found the Flask-specific line the claim was missing: Werkzeug's router
  answers 400 to an upgrade request on an ordinary rule before any view
  runs, so the socket route is declared `websocket=True`. "No second
  process" and "no dependencies" are asserted rather than stated (exactly a
  supervisor and two m0serve workers by `pgrep -x`, an empty `Requires:`
  from `pip show`), and the README's "degrades under gunicorn" sentence is
  executed: the Django file served by gunicorn answers the hold views as
  short plain responses inside curl's deadline, the upgrade as 200, and
  `publish()` reports 0 workers without raising. The published wheel was
  run through the whole page from a scratch directory on macOS and in a
  `python:3.12-slim` container, which is the fresh-project check the
  sentence was owed.

### Changed

- **`docs/WSGI_VS_ASGI.md` is the concise answer to why there are two
  execution modes**, in a page: what each mode is, why one would not do,
  what WSGI gets from the handler pool and held connections, what ASGI
  gets from the executor, what free-threading changes, the cliffs, and how
  to choose. The dated essay it replaced, whose opening still made "the
  case for not building an ASGI host", is kept as written at
  `docs/notes/wsgi-vs-asgi-history.md` with its section numbers, and every
  citation of §5, §8 and §9 (CLAUDE.md, the README, the conformance and
  performance pages, the notes) now points there.
- **The documentation, restructured for a first-time reader and for an
  agent** (`scripts/docsite.py`, `docs/ROADMAP.md`, `docs/notes/`,
  `docs/RUNNING.md`, `docs/README.md`, `llms.txt`, `apps/site/home.md`).
  The site now opens on a short home page rather than the repository's
  README, and its pages are grouped by intent: start here (quickstart, the
  new **Running m0serve** guide covering flags, the execution modes and
  when each applies, proxies, shutdown and exit codes, the capability
  matrix, the map), understanding the design, measurements, the project
  record, and the Mojo framework underneath. **ROADMAP.md is a state page
  now**: milestones, known issues, planned, not planned and why, recently
  resolved, at 380 lines where it was 2,726; its twenty-one long-form
  narratives (the Django server aims, each shipped subsystem, the gates,
  the open questions, the post-mortems) are **design notes** under
  `docs/notes/`, kept as written, rendered under `/notes/` with their own
  index and picked up by the site without a page-table entry. Every page
  opens with a one-sentence lede, the description a search result shows;
  pages with six or more headings get an "On this page" list. For agents,
  `llms.txt` is curated (the operating contract, then the essential pages)
  with the rest under the spec's `## Optional` tier, and `llms-full.txt`
  carries only the essentials, at a fraction of its former size, naming
  what it omits and where to find it. `poe milestones`, the spec checker
  and the link checker read the new shape unchanged.

### Fixed

- **The ASGI smoke's two shutdown phases bound their wait for the server
  to exit**, and the `Tests` job caps are raised to what green runs now
  take. Both phases ended in a bare `wait $pid` after SIGTERM, so a
  server that never exited was a smoke that never finished: on 2026-09-02
  the inverted-mode run on macOS sat 7 minutes inside that wait until the
  job's 20-minute cap cancelled it, with a stray `m0serve` for the runner
  to reap and no log to read -- the step's last line was the WebSocket
  probe passing. A `wait_exit` helper polls for 30 s (the drain is 5 s
  and the thread join another 5), then kills the server and fails naming
  the phase, with `asgi.log` printed. The hang itself has not reproduced:
  the sequence ran 20 of 20 clean under twenty CPU hogs on this tree, in
  both shutdown phases, and every macOS run since has passed; the two
  slot-recycle fixes above landed after the commit that hung, and the
  next occurrence will at least say where it stood. Separately, the
  smoke job's green runs take 16-19 minutes across some fifty steps
  against a 20-minute cap set when they took 3-5 -- a 19.5-minute green
  run is on record -- so the smoke cap is 35 and unit-tests (11-15
  minutes) 30.

- **A Starlette streaming response no longer leaves a traceback per
  response in the log** (`bridge.mojo`, the executor shim). Starlette
  -- so FastAPI and FastHTML -- produces a `StreamingResponse` body inside
  an anyio task group, and the shim stamped its streaming mark on
  `asyncio.current_task()`, the CHILD. The request task's done-callback
  then took the stream for a buffered result and raised `TypeError`
  unpacking `None` (the body had already been delivered, so nothing
  failed but the log), and a client disconnect cancelled the child rather
  than the request. The mark and the cancellable task are now the slot's
  OWNER. Found by running FastAPI against the published wheel;
  `test-shim` gains the child-task shape plus its sabotage, and
  `smoke-fasthtml` refuses the traceback in its log.
- **A recycled slot no longer inherits the previous WebSocket's accept.**
  The executor shim's `spawn_ws` cleared a recycled slot's stale disconnect
  mark but not its `_exec_ws_accepted` membership, and the previous task's
  done-callback — correctly, no longer the owner — does not clean the slot
  up either. A new handshake landing on a slot whose previous connection
  was an accepted socket therefore looked pre-accepted: an application
  that returned without answering it sent `ws_close` instead of
  `ws_reject`, so the held 101 was never released and the client hung
  against a clean server log; a pre-accept `websocket.send` was silently
  tolerated instead of raising. Found by auditing the bridge's slot-recycle
  hygiene; `shim_ownership.py` gained the WS→WS recycle test
  (`test_a_websocket_recycle_forgets_the_predecessors_accept`) and its
  sabotage, which fails exactly that test on the pre-fix shim.

## [0.17.0] — 2026-09-02

### Added

- **ASGI on a free-threaded CPython build is refused, not crashed**
  (SPEC L18, E10; ROADMAP Known issues). The weekly py-canary found the
  asyncio executor segfaulting on 3.14t while building its `ExecutorPort`
  Python type: Mojo 1.0's stdlib lays `PyObject` out for the GIL build, so
  `PyModule_Create` misreads the module definition (modular/modular#5726).
  `m0serve` now probes the build wherever the executor would engage --
  prefork's worker, the threaded path, `--doctor` -- and exits 78 with a
  sentence naming the issue and the fix (a GIL-enabled interpreter with
  `--workers`); an ASGI app under `--threads` is therefore refused on this
  toolchain. `WorkerSupervisor` treats a worker's exit 78 as the refusal it
  is: no respawn, and the supervisor exits 78 itself, where before ten
  respawns and an exit 1 reported a crash. `smoke-django-realtime` phase 6
  asserts the refusal on a free-threaded build (alone, via `--doctor`, and
  under `--workers 2`) and the full mixed server on a GIL build.
  `py-canary.yml` no longer fail-fasts (Linux was cancelled before reaching
  the failure, twice) and can file its issue (the default token was
  read-only, so it never had).
- **The documentation site's deployment** (`deploy/site/`, `poe
  deploy-site`, `poe smoke-site-image`; SPEC F14). A `python:3.12-slim`
  image with the m0serve wheel, the site rendered for `https://m0serve.dev`
  and the fallback application, on one always-on 256 MB Fly.io machine
  (`deploy/site/fly.toml`); `.github/workflows/deploy-site.yml` deploys
  after every successful `Release`, pinning that release's wheel, or on
  demand with a version. `scripts/site_image_probe.py` builds the same
  Dockerfile from the tree's own wheel in CI and asserts the served shape
  through a published port, that m0serve is PID 1, and that `docker stop`
  is the drain. The PyPI project now links `Documentation` to the site.
  The first public deploy follows the next release: the XML sitemap and
  the fallback application's redirect and 404 need the `xml` content type
  and the static mount's fall-through above, which 0.16.0 does not have;
  the probe passes everything else on that wheel and fails at exactly that
  phase.
- **The documentation site** (`scripts/docsite.py`, `apps/site`, `poe
  build-site` / `serve-site` / `smoke-site`; SPEC F13). README, QUICKSTART,
  CHANGELOG, PROVENANCE and every page under `docs/` render to HTML and are
  served by m0serve itself through `--static`, with `llms.txt` at the root
  (the repository's own, its links made absolute, plus an index of every
  page) and `llms-full.txt` beside it for agents, a Markdown twin beside
  every page advertised by `<link rel="alternate" type="text/markdown">`,
  `sitemap.xml`, `robots.txt` and `spec.json` at stable URLs, and canonical
  links, Open Graph and JSON-LD on every page. Titles and descriptions live
  in one table and are written for the question a reader searched, not the
  file's name. Every relative link is resolved at build time and a link to
  nothing fails the build; every `docs/*.md` must be listed, so a page
  cannot ship without a title. The link check is standard-library and runs
  inside `check-docs`, so doc-only pull requests get it, and `--selftest`
  proves it can fail. The rewriter is a fence-aware regex; the build then
  walks the parsed token stream and refuses any relative link it missed,
  which found one on the first run (a link whose text wraps a line). `xml`
  joined the static mount's content types as `application/xml`, because the
  sitemap was going out as octet-stream. Deployment is the open half: the
  build takes `--base-url`, and nothing serves it publicly yet.
- **The scheduling-stickiness sighting reproduced, and its fix direction
  corrected** (`docs/ROADMAP.md` Known issues, `scripts/accept_placement.py`).
  The one CI failure of `smoke-reload`'s two-worker phase — eighty
  sequential connections all answered by one of two live workers — is CPU
  placement, not load: with the client on one worker's CPU the other worker
  wins every accept (80 of 80, measured on the 0.16.0 wheel in a Linux
  container), because the accept-queue wakeup runs on the client's CPU and
  the co-located worker is last to run. `EPOLLEXCLUSIVE`, which the entry
  named as a fix direction, sends 80 of 80 to one worker in every placement;
  per-worker `SO_REUSEPORT` listeners are the only shape that balances. The
  entry now records the numbers and why the server keeps its shared
  listener. **`smoke-reload`'s two-worker phase no longer asserts scheduler
  fairness**: instead of waiting for both pids to happen to answer, it
  stops the worker that did (SIGSTOP; the supervisor reaps with `WNOHANG`,
  so that is neither a crash nor a respawn) and requires the other to serve
  the new module 8 of 8, both pids tied to the supervisor's re-fork log.
  Sabotaged in both layers; passes 4 of 4 on Linux against the 0.16.0
  wheel, including with the whole smoke pinned to one CPU.

- **The 0.16.0 real-application soak** (`docs/REAL_APP_VALIDATION.md`,
  rewritten; the milestone's soak reads current). Four applications —
  `transcripts`, `color-separation`, `textshelf` and Wagtail's
  `bakerydemo` — driven by `scripts/soak.py` against captures from
  gunicorn, uvicorn and daphne: 373,000 responses byte-identical across
  the clean rows, with logins, 9.7 MB multipart uploads, abandoned holds,
  four-worker prefork, and SIGTERM churn. **One server defect found and
  left open as SPEC D9**: a request body still arriving at SIGTERM holds
  the drain to its 5 s deadline, because the drain loop reads nothing new;
  `scripts/drain_upload_probe.py` reproduces it bare and is the gate the
  fix will land with. Everything else that differed was traced, by
  measurement, to the application: Wagtail rendering from sets under
  different hash seeds, typst's per-process font tags and PDF dates,
  textshelf's SSE views stalling any WSGI pool and its unpooled Postgres
  connections at four workers. Manifests for both apps, multipart uploads,
  status-only routes and supervisor-aware sampling in the driver.

- **The soak driver** — `scripts/soak.py`, manifests under
  `scripts/soak_manifests/`, `poe soak-apps` (pre-release, three legs) and
  `poe soak-selftest`. `docs/REAL_APP_VALIDATION.md`'s phase 5 was a
  request loop that sampled RSS; three of the six real-application defects
  were silent (a clean status over a short or empty body) and a request
  loop passes every one. This asserts bytes instead: every response is
  compared — status, normalised headers, body digest — against a capture
  recorded from a reference server (`--baseline`, gunicorn or uvicorn),
  under five concurrent populations (keep-alive bursts that cross the cap
  on every connection, streams, uploads and logins, WebSocket echoes, and
  abandoners that vanish mid-body and reuse the freed slot at once), with
  the server SIGTERM'd or `--reload`ed underneath (`--churn-every`), and
  the server's own `/__metrics` sampled beside RSS, fds and threads. A
  manifest's `login` block is a CSRF form round trip with a cookie jar per
  session, so the authenticated surface of a real application is
  reachable and the login response itself is verified — `Set-Cookie`
  normalised to its attributes, defect 1's exact shape. The comparator is
  a pure function with a `--selftest` that found the driver's own first
  hole: a substitution greedy enough to absorb a truncation blinds the
  instrument, so a capture now refuses any route its patterns blind, and
  carries a fingerprint of the rules it was recorded under. Shaken down on
  `apps/hybrid_mix` and `apps/asgi_bare` (3.5 M responses against a
  uvicorn capture, zero differences), then on Wagtail's bakerydemo and
  textshelf, each byte-identical to gunicorn/daphne with logins and churn
  — every body difference traced, by measurement, to the application
  rendering from Python sets under different hash seeds.

- **SIGTERM as PID 1 in a container is gated, every pull request** (SPEC
  M11, the last beta row). `docker stop` is SIGTERM to PID 1 and nothing
  else, and PID 1 gets no default signal dispositions from the kernel — a
  SIGTERM arriving with no handler installed is *discarded*, not fatal.
  This server installs its handlers post-fork by design, so every
  in-process SIGTERM gate proved the handler works once installed while
  proving nothing about the one environment where the default disposition
  cannot paper over a missing install. `poe smoke-pid1`
  (`scripts/pid1_probe.py`) runs the shipped wheel exec'd as PID 1 in
  `python:3.12-slim` — checked via `/proc/1/cmdline`'s argv[0], not
  trusted — and stops it in both process shapes: one process alone, and
  the supervisor reaping two workers whose exits must be clean rather
  than by the propagated signal. The sabotaged shapes were each measured
  in a container before the gate counted: the worker install skipped is
  SIGKILL at the deadline (exit 137 at 10.1s of a 10s grace) alone and
  workers dying *by* signal 15 under a supervisor; the supervisor's arm
  skipped silently is the deadline again with the single shape green; the
  announced degradation is caught by its own log line. The probe's PID 1
  premise check failed its first sabotage — `sh -c`'s cmdline *contains*
  "m0serve", so a substring check over the whole cmdline blessed the
  shell — and checks argv[0] alone for that reason.

- **`/__metrics` renders a request-latency histogram** (SPEC F5). Six
  log-spaced `le` bounds — 100µs, 1ms, 10ms, 100ms, 1s, +Inf — as a
  standard Prometheus histogram (`_bucket`/`_sum`/`_count`), integer-only
  and O(1) on the event loop thread: one band counter incremented per
  response, accumulated cumulatively at render time. Sampled in
  `_after_send` from the same clock the access log reads, and only when a
  header stamp exists, so a pushed frame on a streaming slot cannot sample
  the epoch as a latency. Per-loop like every other metric; the scraper
  aggregates. The serve smoke's metrics phase now checks coherence through
  `scripts/histogram_check.py` — the documented bounds in order, cumulative
  counts non-decreasing, `le="+Inf"` equal to `_count`, and a `_count`
  covering the phase's own requests, that last being the assertion that
  fails when recording is never called. The checker's selftest runs in the
  same phase (six doctored expositions, each flagged by the rule that names
  it), and three sabotages were caught by name before the gate counted:
  recording never called (`_count is 0 after at least 5 requests`), the
  cumulative render broken (`counts decrease: [5, 1, 1, 0, 0, 0]` and
  `+Inf is 0 but _count is 7`), and an `le` boundary off by one (two
  `test_metrics.mojo` tests). 6 unit tests pin the boundary math.

- **Autobahn|Testsuite is wired to the pre-release cadence** (SPEC I13).
  `poe autobahn` drives the suite's sections separately (a single pass
  wedges on the slot a cap-killed connection just released), skips 9/12/13,
  and compares both directions against the pinned baseline — 240 of 247,
  every failure being I17's ≥64 KB outbox cap: a failure outside those
  seven cases is new and fails the run, and one of the seven *passing*
  fails it too, the cap having moved out from under the sheet. The image is
  version-pinned (digest-identical to the 2026-08-30 baseline's), which is
  what lets the per-section case counts be asserted exactly; the server is
  the runner's own pure-echo ASGI app, because `asgi_bare`'s `/ws`
  prefix-echoes text and Autobahn's byte-identity cases would score that
  as failures. The comparator's `--selftest` (five doctored result sets,
  each flagged by the rule that names it) runs before anything is
  believed. The wired run reproduced the baseline exactly, and the live
  sabotage — I16's close-code validation reverted — was caught as nine
  named new failures (7.9.1–7.9.9) on the first section-7 run.
  `docs/RELEASING.md` now lists it beside `stress-asgi`, along with
  `fuzz-request-long` and `sabotage-outbox-cap`, which were pre-release
  tasks the checklist never named.

- **Coverage is declared by the gate, not merely cited by the spec sheet**
  (SPEC F12; ROADMAP "Traceability", phase 2). Every one of the 119
  `verified (every PR)` rows now declares its coverage in its own gate: a
  `covers: A7` line in the cited test's docstring for the 39 unit-cited
  rows, and a `scripts/emit.py --covers A7` call in what the cited step
  runs for the 80 step-cited ones — the latter also recorded by the real
  run through `$M0_RESULTS`, rendered in the CI summary as a tally. Two
  new checker rules run beside the citation rules: every declared id must
  name a row that exists, and every gated row's declaration must AGREE
  with its citation — a row declared only somewhere its evidence does not
  cite is the exact mis-citation class the 2026-08-30 audit found six of,
  now a red build instead of an audit finding. Weekly and pre-release
  rows keep declared-static citations (their runs are absent from PR CI);
  the citation-shape rules stay, guarding what declarations cannot (real
  cadences, unconditional steps, the two closed sets). Four new sabotages
  revert the rules, each caught by the failure that names it — and the
  migration itself surfaced a masking hazard: appending a
  recorder call after a smoke body's last command replaces the exit
  status poe reads, so `smoke-pool` and `smoke-ws-inbound`, whose final
  probe's status was the task's status, now carry an explicit
  `|| exit 1` there.

- **The request decoder is fuzzed, every pull request** (SPEC G13).
  `scripts/fuzz_request.mojo` mutates a seed corpus of real and hostile
  requests through `parse_request_headers` and `HTTPChunkedDecoder.decode` —
  no socket, no server, because the decoder is a pure function over bytes.
  Deterministic from its seed, so a CI failure names the seed and iteration
  and the same run reproduces it.

  Beyond "does not crash" it asserts four properties: parsing is
  deterministic; an **INVALID** request cannot become valid by appending bytes
  (the smuggling-relevant one — "invalid, not incomplete" is what stops an
  attacker's payload being read as the next request); a request that parses is
  unchanged by bytes after it, consuming the same count; and the chunked
  decoder's `ret`, decoded length and `pending_bytes` all index the buffer they
  were given, since those feed copy sizes in the loop.

  **480,000 mutations across eight seeds found nothing**, which is a believable
  result for a decoder with this unit suite and worth nothing on its own — so
  two things guard the negative. The run refuses to pass on thin coverage (it
  counts parsed, rejected, incomplete and both chunked outcomes, and fails if
  any bucket is empty), and `poe sabotage-fuzz` breaks each invariant in the
  decoder and requires the fuzzer to report that invariant by name. Without
  them "no findings" and "checks nothing" are the same output.

  `poe fuzz-request-long` is the release sweep (8 seeds x 250k).

- **The chunked decoder's trailer states are gated** (SPEC A10). The servers
  build their decoder with `consume_trailer = True` — which is what makes a
  body end where RFC 9112 says it ends — but the round-trip tests set that
  flag over a wire carrying no trailer section, so every state below
  `IN_TRAILERS_LINE_HEAD` was reached by no test at all.

  Eight tests in `test_parsing.mojo` now cover the section: consumed whole
  (including its terminating CRLF, whose absence is what makes a close send
  an RST), several fields, no trailer byte reaching the decoded body, the
  framing fields RFC 9110 §6.5 says a trailer must not honour
  (`Content-Length`, `Transfer-Encoding`, `Host`), the pipelined tail
  surviving byte for byte, and the section bounded by the existing abuse
  ratio — trailer bytes advance `src` and never `dst`, so they are charged as
  pure overhead and no second limit is needed. The default-setting half is
  asserted too, so a decoder that swallowed to the end of the buffer cannot
  pass.

  `poe sabotage-trailers` reverts each of the six rules and requires a
  failure for every one; it runs in `test-all` and in CI. Nothing was found
  wrong with the implementation — the gap was in the evidence.

### Changed

- **Three renames the next Mojo release forces, applied now because their
  replacements already compile on 1.0.0**: `InlineArray` → `Array`
  (`header.mojo`, `test_sendfile.mojo`), `std.ffi._CPointer` →
  `OptionalPointer` (`bridge.mojo`'s two `PyBytes_*` signatures) and
  `memcpy` → `unsafe_memcpy` (four fork files). Verified by building the
  tree on `1.1.0.dev2026090205` in an isolated copy: with these plus the
  two renames that cannot be applied ahead of time (`Atomic[DType.X]` →
  `Atomic[X]`, `_CTimeSpec.tv_subsec` → `tv_nsec`), `build-all`, all 1011
  Mojo tests, `build-apps`, `build-serve` and `smoke-django` are green
  there. The `PythonObject` leak entry in `docs/ROADMAP.md` (Known
  issues) now records the upstream issue and fix commit (#6833,
  `c9d5048575`, authored nine hours after the 1.0.0 wheel was uploaded),
  the leak measured per operation on both toolchains, and the verified
  break list in place of the one read from the release notes, which was
  three items short and one item stale.

- **A static mount's miss falls through to the application.**
  `StaticFiles.serve` (and so `--static`) used to answer every path under
  its prefix definitively — a missing file was the mount's own JSON 404 and
  a POST anywhere under it a 405 — which made `--static /=dir` swallow the
  application entirely. It now answers `None` for a path that names no
  regular file under the root, so a root mount can front an application's
  routes (the `try_files` / whitenoise shape); a missing asset under
  `/static/` now gets the application's 404 page rather than the mount's
  JSON. What still never reaches the application: a traversal, an encoded
  slash that would open a segment, a malformed segment — those stay the
  mount's 404 (G5, G6). The 405 for a method other than GET/HEAD is now
  about a file the mount holds, checked after existence. Found by the
  documentation site, which needs the redirect for `/docs/spec` and its own
  404 page from the application behind the mount.
- **`poe autobahn` provisions its own docker on a Mac.** With no daemon
  answering it starts a 4 GiB colima VM (enough for the wstest container;
  the echo server runs on the host) and stops that VM when the run ends,
  pass or fail. A daemon that was already up — colima started for other
  work, or native Linux docker — is used as found and never stopped: only
  what the run started is the run's to reap. Both branches measured: a
  stopped VM is started at 4 GiB (`colima start --memory 4` resizes the
  existing profile down from 8) and reaped after the suite; a running one
  is left running. The sizing matters on a 16 GB machine, where the
  forgotten 8 GiB reservation was half the RAM.

- **Bench prose numbers are now generated in place, not pattern-matched
  after the fact.** `check_bench_prose` held 24 hand-written regexes
  against 12 quantities across three documents — every legitimate
  rewording broke a pattern, only a phrase's first occurrence was
  checked, and nothing proved the checker could still fail. It is
  replaced by inline `num:` spans: `render_bench_docs.py` computes each
  quantity from the newest artifacts and writes the number between
  markers naming the quantity and its decimals
  (`~<!-- num:granian-per-m0@1 -->1.2<!-- /num -->x`), so the sentence
  around it stays free to be reworded and `--check` — already run by
  `poe check-docs` — refuses any stale span. A span naming an unknown
  quantity, a quantity whose artifact row vanished, or an opener whose
  closer was deleted is an error, not a skip, and the renderer's new
  selftest (run at the top of `check-docs`, so doc-only pull requests
  prove it too) insists each of those failures fires. All 25 span sites
  were migrated value-neutrally — every number the prose showed is
  byte-identical to what the newest artifact computes — and the
  migration corrected one overstated claim found along the way:
  WSGI_PERFORMANCE.md said the old checker held the mixed-workload
  prose to its artifact, but that artifact records throughput medians
  only and no checker ever recomputed the p99 narrative; the page now
  says which numbers are held to the file and which are quoted
  measurements.

- **`SO_REUSEPORT` (SPEC D6) now records the property that is actually gated**,
  and M13's reason is corrected. D6 claimed the option itself and sat
  `implemented` for want of a smoke covering "the zero-downtime handover it
  would enable" — but no shipped path can enable it: `reuse_port` is opt-in on
  `ListenConfig`, defaults off, and has no caller, no flag and no environment
  variable, because workers and threads all accept from ONE listener bound
  before the fork. The property that matters and IS gated is the default:
  `smoke-serve` proves a second server on a busy port fails to bind loudly
  rather than silently taking a share of the connections, which is what it did
  until 0.14.0.

  M13 (systemd socket activation) was `out of scope` **because** "`SO_REUSEPORT`
  covers the restart case it is usually wanted for". That was not true for
  anyone running `m0serve`. The row keeps its status on the honest reason —
  nobody has asked for it — and now says what a restart does get, which is the
  supervisor's graceful drain. This is the class of error the checker cannot
  catch: it validates that a citation resolves, never that a reason is true.

- **The blocking `listen_and_serve` loop no longer sends a `Keep-Alive`
  header.** It was the only site that did — the event loop, which every
  shipped binary runs, has never sent one — so the two paths disagreed on the
  wire for a header that is not in RFC 9110 or 9112 (RFC 2068 §19.7.1
  described it; RFC 2616 dropped it) and that browsers ignore.

  It was also unreachable and wrong. Nothing in this tree calls
  `listen_and_serve`, no test asserted the header, and the `max` value was off
  by one: `max` counts ADDITIONAL requests, and `keepalive_count` is not
  incremented until after the response is built, so request 99 of 100
  advertised `max=2` and served one more.

  Aligning the other way would have put a header nobody reads on every
  keep-alive response of the hot path, plus a spec row and a permanent gate.
  If a client pool ever needs `timeout=` to avoid racing the idle close, the
  event loop is where to add it, with a row and a gate. `listen_and_serve` is
  public API (README), so this is a visible change for a library caller that
  was reading the header; `Connection: keep-alive` is unaffected.

### Fixed

- **The nightly canary could not alert, and would have misreported its
  first success.** `nightly-canary.yml` failed on all three scheduled runs
  (2026-08-18, 08-25, 09-01) and filed no issue: `gh issue create --label
  nightly-breakage` failed because the label did not exist. It does now.
  And `trailer_sabotage.py`, `fuzz_sabotage.py` and `pool_sabotage.py`
  ran the compiler as `uv run mojo`, which re-syncs the venv to `uv.lock`
  even under a parent `uv run --no-sync` (measured: the child printed Mojo
  1.0.0 and the venv stayed there) — so the `sabotage-trailers` step of
  `test-all` would have swapped a canary back to stable mid-run and the
  next step's "precompiled file is newer than the compiler" would have
  read as a nightly break. They run the venv's own `mojo` now; on the
  nightly copy the step passes and the toolchain stays put.

- **A request whose body was still arriving at SIGTERM held the drain to
  its 5 s deadline** (SPEC D9). The drain loop dispatched writes only and
  read nothing new, so a half-received upload was neither completed nor
  closed: the client was reset at 5.03 s and the process left at 5.09 s —
  half of `docker stop`'s patience for a request that completes in
  milliseconds. The same loop cut any response too large for one `send`
  at its first write readiness. The drain now runs ordinary event-loop
  passes for its budget, with `_close_between_requests` after each so only
  bytes already sent are served; gated by `smoke-drain-upload` in both
  execution shapes, two-sided (answered whole, exited inside 3 s), and
  sabotaged by restoring the old loop. Found by the soak driver's uploads
  population on color-separation.

- **A chunked body that arrived with its headers was bounded by nothing.**
  Both request-body limits — the decoded cap and the raw ceiling at twice it —
  lived in the `READING_BODY` branch, but a chunked body whose bytes arrive in
  the same read as its headers is decoded and dispatched inline at the header
  site, which never runs that branch. Sending head and body in one write was
  enough to escape both: 512 one-byte chunks are 3,077 raw bytes against a
  2,048 ceiling and answered `200`, where the same body paced across several
  writes answered `413`.

  So whether a request was bounded came down to how the client's writes
  happened to be coalesced by the kernel — which is also why this survived:
  `chunked_overhead_probe.py` sends 512 separate 6-byte writes, and they
  coalesce differently on a loaded CI runner than on a laptop. It surfaced as
  an unrelated pull request going red on macOS.

  The probe now sends the over-ceiling body **three ways** — paced, head and
  body in one write, and split across two writes at the ceiling — so the shape
  that reaches each decode site is chosen rather than left to the kernel.
  Reverting the fix fails the one-write phase and no other, which is how the
  fix was scoped: a second check added in the `READING_BODY` branch turned out
  to change no observable behaviour, because the existing pre-decode
  buffer-size test already refuses those shapes, and it was removed rather
  than shipped unpinned.

- **The keep-alive request cap destroyed the response it fired on**, for a
  streamed body and for a WebSocket upgrade alike. On the hundredth request
  of a keep-alive connection (`max_keepalive_requests`, 100) a streamed ASGI
  response went out as a `200` carrying its `Content-Length` and **zero body
  bytes**, and a WebSocket upgrade completed its handshake with `101` and then
  never sent a frame. Both were silent — correct status line, nothing logged.

  `_finish_response` clears `should_close` for a stream and for a 101, because
  neither is keep-alive reuse: each owns the connection until it ends. The cap
  check below those two branches was guarded by `not should_close`, which is
  exactly the state they had just established, so the two shapes that had
  opted out were the two it caught; `_after_send` then closed the slot as soon
  as the head drained, before any body frame arrived over the executor's chunk
  channel. The blocking loop cannot reach this — `gate_streaming_response`
  turns both shapes into a 409 before the cap is consulted — and it is left
  unchanged rather than given a condition that can never be false.

  Found by re-soaking a real Django application against 0.16.0
  (`docs/REAL_APP_VALIDATION.md`): 9 truncated responses in 6,000 requests,
  all on one 124 KB static file, at intervals of exactly 700 — every hundredth
  time that route was hit. Gated by `poe smoke-keepalive-cap` (SPEC A3), whose
  third phase asserts the cap still fires for an ordinary response, so the
  gate cannot pass on a build whose cap never fires.

## [0.16.0] — 2026-08-31

Four WebSocket correctness fixes, two of them silent — a slot leak and a
message loss that no client could detect. Three were found by gating a
mechanism nothing gated, which is the theme of the release rather than a
coincidence.

### Fixed

- **A WebSocket peer that never answers Close no longer holds its slot for
  ever.** v0.15.1 made the server wait for the peer's Close reply (RFC 6455
  §5.5.1) and bounded that wait with the idle sweep. The bound did not work:
  none of the linger's four sites is a transition, so the drain re-stamped
  the deadline on EVERY pass while a slot lingered — about once a second,
  two seconds into the future — and the sweep could never overtake it.
  Measured: a peer that received Close and never replied still held its slot
  at 40 s. Armed once now, only when the deadline is still zero. `A4` is
  gated (`--idle-timeout`, `scripts/idle_timeout_probe.py`,
  `poe smoke-idle-timeout`) and `L16` is a new row for the BOUND, separate
  from L15 for the ORDER, because L15's 64-way concurrent-close phase passes
  on both broken servers.
- **Close frames are validated, not echoed.** RFC 6455 §7.4.1 divides close
  codes into ones a peer may put on the wire and ones it may not; the parser
  copied the first two payload bytes into its echo unexamined. The
  contradiction is sharpest at 1006, "abnormal closure", which names the
  ABSENCE of a close frame — so a close frame carrying it cannot be honest,
  and the server answered it with its own 1006. Now 1000-1003, 1007-1014
  (1012-1014 were registered with IANA after the RFC, hence the range ending
  at 1014 and excluding 1015) and 3000-4999 are echoed; everything else
  fails the connection with 1002. A one-byte body is a protocol error
  (§5.5.1), and a reason that is not valid UTF-8 is 1007 (§8.1). Autobahn
  section 7 goes 24 OK / 3 informational / 10 FAILED to **34 / 3 / 0**.
- **Inbound WebSocket messages are no longer dropped when a client stalls.**
  The outbound direction was credit-gated and the inbound direction had no
  backpressure of any kind, so once the executor's submit channel filled,
  each further message was discarded with a log line the client can never
  see: **2932 of 3000 lost** at 4 KB. The two directions were coupled, which
  is why the threshold was so low — an app that awaits `send` inside its
  `receive` loop stops receiving when its client stops reading, which stops
  the drain that inbound messages depend on. Inbound now has a window
  (`WS_IN_WINDOW`, acked cumulatively as the application consumes), the loop
  suspends the socket's READ when it cannot forward, and what it has already
  taken off the wire is parked and delivered late. A parked message is owed,
  never dropped.
- **A WebSocket client sending more than one socket read's worth no longer
  stalls on Linux.** The WebSocket read path took one `recv` per readiness
  event and never re-armed — `A13`'s defect in the one path nothing had ever
  sent a large inbound burst to. kqueue's level trigger hides it entirely;
  on epoll the edge is spent, and the stall needs the client to STOP
  SENDING, which is exactly what the inbound window above makes it do. So
  the fix above exposed a bug that had been waiting for it. Re-armed only on
  a full staging buffer, so an ordinary small-message socket pays no extra
  syscall.

### Added

- `--idle-timeout`, exposing the connection idle deadline that was
  previously a `ServerConfig` field with no flag or environment variable.
- `poe smoke-idle-timeout`, `poe smoke-realtime-holds`, `poe smoke-ws-inbound`
  and `poe check-phase-stamps` — four new gates, each sabotage-proven.
- Every probe now stamps the PHASE it was proving, so a traceback naming a
  shared socket helper says which phase failed rather than only which call.
  `scripts/phase_stamp_check.py` holds it across all 16 probes and reverts
  each rule to prove the checker bites.

### Changed

- **A client that sends without ever reading, against an app that echoes,
  now BLOCKS rather than losing data.** That is the correct end of a
  deadlock every echo server has, uvicorn included; the old behaviour only
  avoided it by discarding the client's messages.
- `docs/SPEC.md` grew to 149 rows. Autobahn|Testsuite was run once by hand
  to decide whether to wire it (`I13`): it scores the build with a known
  RFC 6455 §5.5.1 violation and the fixed build IDENTICALLY, because its
  fuzzing client always initiates the close and the bug was on the
  app-initiated path. The ROADMAP's claim that "the bar is unambiguous and
  the result is comparable" is withdrawn. It still found the close-code
  defect above, and outside its performance section now scores 240 of 247 —
  every remaining failure being the deliberate `MAX_PENDING_BYTES` cap
  (`I17`).
- `B8` split into `B8` (h2spec) and `B9` (the PortSwigger desync scanner),
  both `out of scope`: h2spec needs HTTP/2, which `A18` refuses, and a
  pair-scanner has nothing to compare against a server with no proxy in
  front of it.

## [0.15.1] — 2026-08-30

### Fixed

- **A WebSocket the server closes now ends in a FIN, not an RST.** When an
  application sent `websocket.close(1000)`, the loop wrote its Close frame
  and closed the TCP connection in the same pass — before the peer could
  reply. The reply then reached a socket that was already gone, TCP answered
  with an RST, and that reset flushed the peer's receive queue, taking the
  FIN with it and, for a client far enough behind, the Close frame itself:
  against the `websockets` library at 200 concurrent closes, 33 of 200 saw
  `ConnectionClosedError: no close frame received or sent` instead of the
  application's own code 1000. The loop now follows RFC 6455 §5.5.1's order
  — having sent Close, it waits to receive one, bounded by a 2 s deadline so
  a peer that never replies cannot hold the slot. Measured after: 0 resets
  at 20, 50, 100 and 200 concurrent closes, and 200 of 200 clean `code=1000`
  from the real client. `ws_probe.py` gained a close-order phase (64
  concurrent closes, all required to end in a clean FIN) which reports 2 of
  64 against the unfixed server.

### Changed

- **`poe stress-asgi` covers the WebSocket path, in both loop modes.** The
  pre-release timing gate drove `chunked_keepalive.py` only, so the seam a
  2026-08-30 CI flake landed in — the WS path, the loop inversion and CPU
  contention together — was gated by nothing. Each round now runs
  `chunked_keepalive.py` and then `apps/asgi_bare/ws_probe.py`, so the
  handshake lands on the slot the streamed connection just released, and the
  whole loop runs on the pump and again under `M0_INVERTED=1` (asserted from
  the banner, not assumed from the variable), at `smoke-asgi`'s 300 ms
  heartbeat so a timer is queueing frames into the outbox the application is
  filling. A failure names its mode, round and probe, and
  `M0_STRESS_MODES=inverted` reruns just the half that failed. Reverting the
  `websocket.send` credit gate fails the new gate on round 1 — 15 of 400
  frames — and passed the old one 30 of 30. It did not reproduce locally
  (150 rounds per mode across three runs, up to 40 CPU hogs on 10 cores, all
  green) but **did reproduce on CI**, where the probe's new phase stamp named
  it at once: see "A WebSocket close races the peer's close reply" under
  ROADMAP's Recently resolved — it was diagnosed and fixed in this release.
- **`ws_probe.py` reports the phase it failed in.** The CI failure was an
  unhandled `ConnectionResetError` whose traceback named `recv_exact`, a
  helper four phases share. A reset is now a finding carrying its phase —
  and, being an `OSError` rather than an `EOFError`, it no longer bypasses
  the flood phase's frame-count diagnosis in silence. It earned its keep
  immediately: the next occurrence named **the app-initiated close
  handshake**, which is a different phase from the one two investigations
  had assumed, and is what identified the underlying bug.

## [0.15.0] — 2026-08-29

The Mojo-native release: the tier for handlers written in Mojo grows the
ergonomics it lacked, and the HTTP layer under everything gets measurably
faster. Nothing on the wire changed — every existing response is
byte-identical, which the parse-sensitive smokes assert — and nothing an
application already does breaks: `HTTPService` implementers that spell
out all nine methods keep compiling.

What is visible to an application:

- **A handler is `func` and nothing else.** `HTTPService`'s other eight
  methods carry defaults, so `apps/hello` is 30 lines instead of 57 and
  268 lines of empty stubs left the tree. Adding a defaulted hook no
  longer breaks every implementer — which is how `direct_job` arrived.
- **`m0_http.reply`** (`json`, `html`, `problem`, `redirect`, `empty`,
  `no_content`, `body_string`, `param_int`, …) and
  **`Router.allow_header`** — the helpers three apps had each rewritten.
- **`MojoPool`**: the handler pool for Mojo handlers, so one blocking
  Mojo handler no longer stalls the loop (fast-route p50 405 ms → 0.3 ms
  with two 400 ms blockers in flight).
- **`M0_INVERTED=1`**, experimental: the Mojo loop inside the executor's
  asyncio loop on one thread. Correct under every gate, −14% CPU at low
  concurrency, not the default — the CHANGELOG entry below says exactly
  why, with the numbers, and the one limitation to know before trying it
  (a request mid-await at SIGTERM is answered at the 5 s drain deadline).
- **`docker stop` under traffic costs about the slowest in-flight
  request, not 5 s**: a keep-alive connection answered during the drain
  no longer holds the drain to its deadline.

And under it all: the request parser went from 1.96 to 0.86 µs and the
per-pass outbox sweep is skipped while nothing streams, which together
take `apps/hello` from ~122k to ~157k rps at c16 on the reference
machine (+29%), the ASGI executor from 55.7k to 60.1k on the benchmark
page's row (1.03x `uvicorn --loop asyncio`, above it for the first
time), and `M0_INVERTED=1` to 62.0k. One wrong answer was fixed on the
way: a bare-LF line ending followed by a CR within 64 bytes used to
swallow the next header.

The one API that moved is inside the fork: `lightbug_http`'s
`HTTPHeader` is four offsets into the parse buffer rather than two
`String`s. Nothing outside `packages/m0-http` imported it.

### Changed

- **The per-pass outbox sweep is skipped while nothing streams — except
  under the pump.** Every pass swept all 1,024 slots for a streaming
  connection to drain, and the miss path alone cost 1.2 µs per pass.
  `OffloadLoopState.streaming_hint` — an upper bound raised by the two
  sites that set a stream flag and recounted by the sweep itself — now
  gates it: `apps/hello` **+3.3% at c16** (152.3k → 157.4k rps, +5.5%
  per core), `M0_INVERTED=1` **+4.6%** (59.3k → 62.0k). The pump's loop
  keeps sweeping every pass (`OffloadPool.sweep_every_pass`, set by its
  wiring alone), because measured without it the pump lost 2.9% rps at
  +6% CPU at c16: the microsecond was accidental pacing — a loop thread
  that parks sooner batches fewer submits and wakes the executor more —
  and ±0 at c256. Guarded by the streaming smokes, sabotaged three ways
  (never sweep; either flag site not raising the hint), each failing
  exactly the smoke it should. Artifacts under
  `bench/results/outbox-sweep/`. The follow-up the finding named — an
  explicit pause in place of the accidental one — was measured the same
  day and recorded, not built (ROADMAP "Pacing the pump's loop thread"):
  a 1.2–2 µs spin on every pass reproduces the sweep exactly, a spin
  only before a partial flush does nothing, and re-polling to merge
  batches is worse; the pump keeps the pacing it already has.

- **The request parser is under a microsecond.** `parse_request_headers`
  on the twelve-header browser GET: **1.96 → 0.86 µs**, the whole
  user-space request **3.33 → 1.97 µs (−40%)**, `find_header_end` 45 →
  16 ns, and `OK()` construction 0.66 → 0.52 µs as a side effect
  (`scripts/bench_http_parts.mojo`, medians of three; the instrument
  gained a warm-up pass, because once the parse got cheap its row — the
  first heavy loop — was reading the allocator's cold start). Four
  changes, each measured on its own first: the SIMD scanners name the
  first matching lane with a `select` of `iota` and one `reduce_min`
  instead of a scalar walk over up to 64 lanes (9.4 → 0.8 ns per chunk),
  and run 64 lanes wide, then 16, then scalar, so the last headers of a
  request no longer fall to a `try_peek` per byte; the 100-entry offsets
  array is uninitialized rather than filled (3.2 KB of stores per
  request — 0.3 µs in context, though 66 ns measured alone); the
  `Headers` blob and index are sized once from the bytes consumed and the
  field count, and a value goes in as one `extend` rather than a byte at
  a time; and the wrapper's three post-loop RFC scans (Host, the
  Transfer-Encoding/Content-Length pair, the last-coding rule) are flags
  set in the loop that already dispatches on the name — the Host one had
  been building a `String` to measure it.

  On the wire, byte-identical responses: `apps/hello` under wrk with
  browser headers, old and new builds side by side, **122.1k → 150.2k rps
  at c16 (+23%)** and 123.1k → 152.1k at c64, p50 113 → 90 µs
  (`bench/results/parse-lever-ab/hello-wrk-parse-ab-*.json`); through the
  ASGI executor on stdlib asyncio, 55.7k → 60.1k (+8%) — see the
  `M0_INVERTED` entry below for what that did to the inversion's gate.

  One answer changed, and it was wrong before: the wide scan looked for
  the first **CR** and only then for any other control byte, so a field
  value ended by a bare LF ran on to the next line's CR whenever one lay
  in the same 64-byte chunk — the next header vanished into the value.
  The mask is now the scalar tail's own predicate, so both widths agree
  (`test_a_bare_lf_ends_the_line_even_with_a_cr_further_on` fails on the
  old scanner). Ten more tests sweep a line ending across every offset
  from 1 to 140 bytes for values, names and request targets — every
  hand-off between the three widths, both sides — and pin the
  invalid-versus-incomplete verdicts of the token scanner, which are the
  byte-at-a-time loop's exactly (a header line with no colon is invalid,
  not "still arriving").

- **`run_event_loop` is now three functions and a struct**, with no change
  in behaviour: `prepare_loop` (the registrations and slot tables, returning
  a `LoopState`), `_run_pass` (everything between one `backend.wait` and the
  next; returns whether the shutdown pipe fired) and `_run_shutdown` (the
  drain). The pass and the drain are the former inline `while` body, moved
  verbatim behind `ref` bindings into the state, so the nine helpers' 20-
  argument signatures are untouched. This is the step the loop inversion
  needs — a pass that something other than that `while` can call, one per
  asyncio readiness callback on the executor's own thread — and it is
  landed on its own so the zero-diff claim is checkable in isolation: the
  full suite, the warning ratchet (68, baseline) and the nine seam smokes
  (shutdown, ASGI streaming with its RSS guard, the blocking pool, the
  counter under prefork, pipelining, the Mojo pool, hybrid mounts, the
  Django WebSocket hold) pass unchanged, and `stress-asgi` N of N.

- **Header parsing no longer builds a `String` per name and per value.**
  `HTTPHeader` holds four offsets into the parse buffer instead of two
  `String`s that existed only to be read back as bytes and copied into the
  `Headers` blob — two copies of every header per request, the first made
  to be the source of the second. Measured with the new
  `scripts/bench_http_parts.mojo` on the twelve-header browser GET:
  `parse_request_headers` 2.52 → 2.05 µs, the whole user-space request
  3.74 → 3.31 µs (−12%). The instrument is the point as much as the number:
  SERVER_PERFORMANCE.md's "allocations are invisible" verdict came from
  loopback sampling at 50k rps, and at 116k rps the parse turns out to be
  two thirds of the user-space request. Nothing on the wire changed; the
  eight parse-sensitive smokes and all m0-http tests pass unchanged.
  `parse_http_version` also stopped allocating a list of the literal it
  compares against (39 ns, fixed because it was silly, not because it
  showed).

- **`HTTPService` now requires only `func`.** The trait's other eight methods
  carry default bodies, so a handler writes the hooks it uses and nothing
  else. `apps/hello` went from 57 lines to 30 — 4 lines of handler had been
  carrying 25 lines of empty stubs — and 268 lines of the same boilerplate
  came out of the five demo services in `service.mojo`, all six Mojo apps and
  the README example. Nothing on the wire changed: every stub deleted was
  byte-identical to the default replacing it, and `smoke-hello`,
  `smoke-notes`, `smoke-counter`, `smoke-todo`, `smoke-ws`, `smoke-chat` and
  `smoke-client` pass unchanged.

  Overriding a default is ordinary — define the method and yours wins. The
  practical effect is on the trait itself: adding a hook **with** a default no
  longer breaks every implementer in the repo at once, which is what the old
  contract's warning was about. Adding one **without** a default still does.

- **`Router.allow_header(path)`** builds a 405's `Allow:` from the routing
  table. `apps/notes_api` had been probing the router once per method over a
  hardcoded `["GET","POST","PUT","DELETE"]` list — five `match` calls to
  answer a question the table already knew, and a route registered in any
  other method (`PATCH`, `HEAD`) was silently missing from the header it
  produced. `match` and `allow_header` now share one `_path_matches`, so the
  two cannot disagree about which routes a path reaches; `Router.method_of`
  reads a registration back. The header `smoke-notes` asserts byte for byte
  (`GET, PUT, DELETE, OPTIONS`) is unchanged.

### Added

- **`M0_INVERTED=1` — the loop inversion, experimental and behind the
  variable.** For an unmounted, pool-free ASGI application, the Mojo event
  loop runs INSIDE the executor's asyncio loop on one thread: the backend's
  kqueue/epoll fd is registered with `add_reader`, one readiness callback
  runs one non-blocking pass, a request reaches the app through
  `WSGIHandler.direct_job` with no datagram, and its response reaches the
  wire through `service_direct_completions` with no wake. Every other
  topology stays on the pump, unchanged.

  Correct, proven: `smoke-asgi` (0 KB RSS over 10k requests), `-fanout`,
  `smoke-django-asgi`, `smoke-fasthtml` and `stress-asgi` (30/30 under 20
  hogs) all pass under the variable, on kqueue and — verified in a Linux
  container before CI, `scripts/epoll_inverted_check.sh` — on epoll; CI
  runs the ASGI smoke under it on both platforms. Two single-thread rules were found on the way and are
  documented on `ExecutorPort._place_frame` and `PyBridge.notify_disconnect`:
  a producer that waits for the loop to drain waits for itself, so a full
  chunk channel is drained by running a pass; and a direct job would
  overtake a disconnect still on the FIFO submit channel, so the disconnect
  goes direct too.

  Not yet a throughput win, and the numbers say why. Same session, uvloop
  executor, c16, two samples of three rounds: inverted 59.1–59.6k rps at
  0.87–0.88 cores (p50 263 µs), pump 62.6–63.1k at 0.98 (p50 237 µs). The
  two cross-thread wakes per request are gone — that is the −11% of CPU —
  but the pump's two threads were also overlapping Mojo parse/write with
  Python app work, and at c16 wrk is a closed loop, so +27 µs of serialized
  latency is −6% rps. Per core it is +5%; on stdlib asyncio (the gate's
  row) it is +1% rps at −10% CPU, +12% per core, with both arms at 0.93x
  uvicorn asyncio. The default therefore stays the pump; the flag is the
  A/B, `bench_asgi_wrk.sh` now records `inverted=` in its artifact, and the
  session's eight A/B artifacts are under `bench/results/inverted-ab/`
  rather than the canonical glob the benchmark page renders from.

  Re-measured after the parser change above, on the gate's own row
  (stdlib asyncio, c16, medians of three, uvicorn asyncio beside each arm;
  `bench/results/parse-lever-ab/`): pump 55.7k → **60.1k rps, 1.03x
  uvicorn asyncio**; inverted 54.5k → **59.7k, 1.01x**, at 0.88 cores
  (67.9k/core against uvicorn's 59.6k). On uvloop: pump 63.2k → **69.1k**
  (0.83x uvicorn uvloop), inverted 60.2k → **66.4k at 0.86 cores**,
  77.2k/core (0.79x on rps, 0.92x per core). Both arms now clear the
  gate; the inversion's edge over the pump is still per-core (+9% and
  +12%), not throughput (within noise, and −4% on uvloop), and the
  default is unchanged.

  Evaluated for the default and declined, on two more measurements: at
  c256 the per-core edge is gone (pump 88.1k @1.02, inverted 85.5k @0.99
  — +0.6%/core, −2.5% rps, on an idle machine with the comparators
  within 0.5%), so it does not buy capacity; and under the flag a request
  mid-await at SIGTERM is answered at the 5 s drain deadline (5.30 s for
  a 1.5 s request, where the pump answers at 1.50 s), because the drain
  is still the blocking first cut. That limitation is recorded beside the
  flag in `m0serve.mojo` and as ROADMAP design item 6, deferred to the
  inversion's promotion bar rather than built for a mode nothing runs;
  an inverted server wants a stop grace of 10 s or more.

- **A handler pool for Mojo handlers** (`lightbug_http/mojo_pool.mojo`):
  `MojoPool` puts N handler threads behind one event loop for an
  `HTTPService` written in Mojo, the way `--blocking-threads` does for a
  WSGI app — no interpreter, no GIL, no `DetachingBackend`. A handler
  conforms to `PoolHandler` (two methods: `make`, `shutdown`; the rest is
  `HTTPService` and its defaults) and the loop becomes an acceptor:
  `Server.listen_and_serve_nonblocking` now carries the `offload_addr`
  parameter `run_event_loop` always took and `Server` dropped.

  Measured (`apps/pool_spike`, three runs, M4): p99 of `/fast` on a
  keep-alive connection beside N handlers blocking 400 ms in a syscall —

  | configuration | slow=0 | slow=1 | slow=2 | slow=6 |
  |---|---:|---:|---:|---:|
  | loop only | 0.1 ms | 406.0 ms | 405.9 ms | 2026.5 ms |
  | pool of 4 | 0.2 ms | 0.2 ms | 0.3 ms | 404.0 ms |

  At `slow=2` the loop-only **p50** is 405 ms — every request, not a tail.
  The last column is the deliberate saturation boundary (6 blockers against
  4 threads): the pool degrades to about ONE blocking duration (p50
  31.8 ms) where the bare loop degrades to the queue's sum
  (`bench/results/pool-probe-20260828T175956Z.json`).
  Deliberately only for handlers that *block*: CPU-bound work already
  parallelises inside one handler with `std.runtime.asyncrt`'s `TaskGroup`
  (measured 3.6x on four tasks), so the pool exists for threads parked in a
  syscall. A streaming response from a pool thread is refused with 409 (the
  loop drains its own handler's registries, not a pool thread's), and
  `before_request` runs on both the loop's handler and the pool thread's —
  the loop's is where an always-responsive `/health` belongs.

  Guards: `test_mojo_pool.mojo` (in `test-http`), `poe smoke-pool` (in CI:
  which thread served, saturation behaviour, clean SIGTERM), `poe
  sabotage-pool` (in CI on Linux, where all four rules are observable —
  closing the submit channel wakes a blocked `recv` on macOS and not on
  Linux), and `poe probe-pool`, the pre-release p99 table with a deliberate
  saturation column.

- **`m0_http.reply`** — the response constructors every Mojo app was writing
  for itself. `apps/notes_api`, `apps/datastar_todo` and
  `apps/datastar_counter` each carried their own `_json`, `_html`,
  `_no_content` and `_parse_id`, the last two byte-identical copies. The
  module holds `json`, `html`, `empty`, `no_content`, `redirect`, `problem`
  (RFC 9457), `vary_accept`, `accept_header`, `body_string` and `param_int`,
  lifted from those bodies rather than invented, and all three apps now use
  it — `apps/notes_api` went from 388 lines to 308. `redirect` is new
  surface: `common_response.mojo` shipped only `SeeOther`, so 301/302/307/308
  had no constructor at all.

  One behaviour change came with it. `param_int` refuses a parameter longer
  than 18 digits; the hand-written copies multiplied without bound, so
  `/notes/99999999999999999999` wrapped to some other note's id. Every caller
  already treats `-1` as a 404.

- `packages/m0-http/test/test_service.mojo` — the guard for the above, and the
  first unit coverage the handler contract has had. `MinimalService`
  implements `func` and nothing else, so the file failing to compile *is* the
  failure; the value assertions pin that the defaults return what the event
  loop expects (no short-circuit, an empty drain, a non-streaming slot), since
  a wrong default would be a silent behaviour change across every app rather
  than a compile error. Proven by reverting each of the eight defaults to
  `...` in turn and confirming the suite fails for every one.

### Fixed

- **A keep-alive connection answered during the drain no longer holds
  the drain to its 5 s deadline.** The graceful shutdown closed the
  connections that were already idle when SIGTERM landed, but a request
  still running at that moment — on a pool thread or the executor —
  completed during the drain, went out in one `send`, registered no write
  interest for the drain's `EVFILT_WRITE`-only dispatch to see, and
  re-armed its slot for a next request the drain never reads;
  `active_count` then held at one until the budget ran out. Measured with
  a 1.5 s request in flight at SIGTERM: the response at 1.5 s either way,
  but the process exited at **5.35 s with keep-alive against 1.55 s with
  `Connection: close`**, in every execution mode. The between-requests
  sweep now runs after every completion pass of the drain as well as
  before it (`_close_between_requests`); the process exits 0.04 s after
  answering. `smoke-shutdown` gained a fourth phase on the Mojo pool
  (`scripts/drain_inflight_probe.py`), which fails at 5.33 s with the
  in-drain sweep removed. `docker stop` during traffic now costs about the
  slowest in-flight request rather than 5 s.

## [0.14.1] — 2026-08-28

A hardening release for the ASGI streaming seam. No wire format, default
or API changed, and one thing is visible to an application:
**`websocket.send` now applies backpressure.** An app that sends faster
than its client reads waits, where before it silently lost messages:
430,693 of 1,638,400 bytes arrived under a *clean close frame*, a message
stream with holes the peer had no protocol-level way to detect. The same
flood now arrives whole, byte for byte.

The rest turns failures that were invisible into failures that are named
and terminal, and adds the two guards the 0.14.0 slot-ownership fix
shipped without. If you run ASGI streams or WebSockets under `m0serve`,
this is worth taking; if you run WSGI only, nothing here reaches you.

### Added

- **The slot-ownership race has guards.** 0.14.0 fixed a silent hang in
  the ASGI executor — a stream on a recycled connection slot could leave
  the loop holding a subscription with no producer, which a client saw as
  a 30 s stall against a clean server log — but the fix was verified only
  by an ad-hoc reproducer, so nothing would have caught a
  re-introduction. Two guards now do:
  - `poe test-shim` (in CI, inside `test-all`) exercises the shim's
    ownership rules with no server, no Mojo and no threads:
    `scripts/shim_ownership.py` extracts `SHIM_SOURCE` from
    `bridge.mojo`, `exec`s it, and drives it through real socketpairs
    exactly as the event loop does. Seven tests, one per rule; four of
    them fail on the shim reverted to its pre-fix ownership shape.
    `--sabotage` reverts each of the eight rules in turn and insists the
    suite fails for every one, so the repo's sabotage rule is enforced
    rather than remembered.
  - `poe stress-asgi` (a pre-release check, deliberately not in CI) runs
    `chunked_keepalive.py` N times under CPU hogs — the shape that
    recycles a slot mid-stream. Reverted build: failed on round 5 of 15.
    Current: 45 of 45 across three runs.
- `check-docs` fails when a `test-*` poe task is not reachable from
  `test-all`, which is the single step CI runs. Its `smoke-*` twin exists
  because a smoke once shipped that CI never ran; a test task can drop out
  the same way, with no ghost step to notice.

### Fixed

- **Six silent failures in the streaming seam are now terminal and
  named.** A frame the seam could not place was discarded at five of six
  sites, and a drain ack could credit the wrong stream. Each was measured
  by forcing the failure:
  - a dropped stream **begin** frame served a clean, EMPTY 200 (the log
    naming only a downstream `KeyError`) and left the application's task
    awaiting credit for the life of the process; it now answers 500,
    closes, and cancels that task through the same disconnect tag the
    loop would have sent.
  - a dropped stream **end** frame hung the client until its own timeout
    (12 s, curl exit 28) against a silent log; it now aborts — the body's
    bytes, then a close with no terminator — in 13 ms, and says so.
  - a **response chunk** the loop's outbox refuses aborted nothing and
    hung the connection for 12 s; it now aborts, so the truncation is
    visible to the client.
  - a **WebSocket frame** the outbox refuses delivered 430,693 of
    1,638,400 bytes under a *clean close frame* — a message stream with
    holes the peer had no way to detect. It now flushes what is queued and
    closes abruptly (1006).
  - the **WebSocket begin** frame and the close/end pair get the same
    treatment — and a socket can now be aborted at all: the loop's abort
    path gated on `slot_sse`, which a held 101 never sets, so aborting a
    socket was a silent no-op. It reads `slot_sse or slot_ws` now, and a
    101 records its generation after the non-stream branch that was
    clearing it.
  - a **stale drain ack** — acks name a slot and carry no generation, and
    the loop recycles a slot the instant it closes a connection — could
    credit a recycled slot's new stream past its window, over-committing
    the one chunk channel every stream on an executor shares. Credit is
    now clamped to the window.

  A tear-down is claimed once per stream (`stream_lost`): the producer
  does not learn its connection is gone until the loop closes it, so one
  flooding WebSocket announced itself 336 times before.

- **`websocket.send` applies backpressure.** It was the one path above
  reachable by an ordinary application, and until now it was not
  credit-gated at all: an ASGI app that sent faster than its client read
  filled the loop's 64 KB per-slot outbox and every frame past it was
  dropped — 430,693 of 1,638,400 bytes under a clean close. It now waits
  for drain credit exactly as a streaming HTTP response does, so the same
  flood arrives complete and in order (measured byte for byte: 400 x 4 KB
  plus framing, 1,640,193 bytes on the wire). Almost all of the machinery
  was already running — the loop acks a socket's drained bytes, because a
  WS slot on an executor lane answers `slot_channel_stream` — and what was
  missing was the window to credit them to, seeded at `websocket.accept`.
  Credit is charged in ENCODED frame bytes, which is what the loop acks;
  charging the payload instead drifts by the header on every message,
  threefold on one-byte sends. `apps/asgi_bare` grew a `/ws/flood` route
  and `ws_probe.py` a phase that asserts the exact count, so `smoke-asgi`
  fails if the gating is removed (measured: 15 of 400 frames arrive).

  Two limits this does not lift, both now loud rather than silent: a
  single WebSocket message larger than `MAX_PENDING_BYTES` (64 KB) is
  still refused by the outbox, since the cap applies to one frame as well
  as to the queue; and a `--realtime` hold on a WSGI lane has no window,
  because the loop does not ack those sockets.

## [0.14.0] — 2026-08-27

A streaming and throughput release. Three changes are visible on the wire
or in your terminal, so read them before upgrading: unsized WSGI bodies (a
generator, Django's `StreamingHttpResponse`) now **stream** chunked where
0.13.0 buffered them into one sized response; a second `m0serve` on a busy
port now **fails to bind** instead of silently sharing it, `SO_REUSEPORT`
having become opt-in; and `m0serve`'s **startup output** is one line of its
own, printed after the application loads, so "ready" means ready.

The ASGI executor went from 0.72x to **1.06x** `uvicorn --loop asyncio` on
the benchmark page's 16-connection row — 1.22x at 256 — by inverting the
pump: Python calls into Mojo through a type built in-process, and the
executor thread never leaves its event loop. And one silent hang is fixed:
a stream on a recycled connection slot could leave the loop holding a
subscription with no producer, which a client saw as a stall on a clean
server log.

### Added

- `check-docs` counts the tests in the tree (`def test_` per
  `packages/*/test/*.mojo`) and fails when README's "What's in the box"
  table or its `test-all` comment says otherwise; the table sat at 618
  while the tree held 928.

- **Unsized WSGI bodies stream.** A generator or iterator the application
  did not size — Django's `StreamingHttpResponse`, a Flask
  `Response(generator)` — is produced chunk by chunk from a
  `--blocking-threads` pool thread (the WSGI zero-config default) through
  the same chunk channel the ASGI executor streams through: chunked on
  HTTP/1.1 with the connection reusable after, close-delimited on
  HTTP/1.0, `close()` called, and the thread back in the pool when the
  client leaves. Every release before this joined such a body whole, so a
  never-ending SSE generator never answered and pinned its thread until
  shutdown. Sized bodies (`Content-Length` — every Flask page, every Django
  page behind `CommonMiddleware`, `FileResponse`), list bodies, Django's
  `HttpResponse`, HEAD, bodiless statuses and `M0-Hold` responses buffer
  exactly as before, so no framework page changes on the wire; a server
  with no pool keeps joining. `poe smoke-wsgi-stream` pins the contract.
- `apps/wsgi_bare` gains `/stream`, `/stream-forever`, `/stream-raises`,
  `/stream-empty`, `/stream-write-inside`, `/stream-cl` and `/stream-hold`;
  `apps/django_wsgi` gains `/events`, a `StreamingHttpResponse`.
- `poe bench-asgi-wrk` / `scripts/bench_asgi_wrk.sh`: the wrk run behind
  the `asgi-wrk-hello` artifact, which had no producing script. It puts
  the venv first on `PATH` (so a bare invocation embeds the same
  interpreter `uv run poe` does), stamps `executor_python` and
  `executor_loop` in the artifact, takes `M0SERVE_BIN` for an A/B of
  two builds and `BENCH_CONNS` for the concurrency; the generated block
  on the benchmark page prints the executor's loop. `check-docs` now
  ratchets the uvloop ratio and per-core gap too. `BENCH_NAME`,
  `BENCH_APP_DIR`, `BENCH_M0_SPEC`, `BENCH_UV_SPEC` and `BENCH_PATH` run a
  framework app through the same script: the `asgi-wrk-fasthtml-*` and
  `asgi-wrk-django-*` artifacts behind WSGI_PERFORMANCE.md's framework
  table (FastHTML 0.85x / Django ASGI 1.18x `uvicorn --loop asyncio`).
- `bench/results/asgi-wrk-conns-*.json`: the 2026-08-27 concurrency
  matrix — the executor with and without pump batching, and on uvloop,
  at 16/64/256 connections.

### Changed

- `m0serve`'s ready line carries the Mojo flame: `🔥 m0serve: app:application
  on http://…`, and both READMEs now document it as the contract it is —
  printed once per worker, after the application is imported, so "it
  printed" means "it is serving". There is no cross-server standard to
  match here (uvicorn says `Uvicorn running on …`, gunicorn `Listening
  at: …`); for an orchestrator use `--health-path /health` or a TCP check
  rather than the log line. One emoji, once per worker, on the line that already means
  "ready" — the fork's `🔥🐝 Lightbug is listening` banner it replaced was
  Lightbug's branding (attribution lives in NOTICE) and printed *before*
  the application loaded. Error and shutdown lines stay plain: a flame on
  a failure reads as celebration. The Mojo example apps keep the fork's
  banner unchanged.
- **The loop↔executor pump is batched in both directions.** The loop
  sends a pass's submits to an executor lane as one datagram at the
  bottom of the pass, and the executor answers a pump pass's completions
  with one datagram; every existing ordering (begin frame before head,
  park before poke, pill FIFO behind every job) is preserved by
  construction, and a batch the channel will not take runs inline, which
  is what a refused submit always meant. Measured under wrk with the
  uvicorn rows re-measured beside it: +5% at 16 connections
  (a pass batches three submits on average there), +7% at 64 and +19% at
  256, where the executor passes `uvicorn --loop asyncio` (1.10x; 0.85x
  against uvicorn with uvloop). Table and artifacts in
  docs/WSGI_PERFORMANCE.md; `bench-asgi`'s stdlib throughput gate is
  retired — its harness read 1.4x the same day wrk read 0.75x, so it
  measures its own client; the ratio is printed as information and the
  mixed-tail gate stays.
- **The executor pump parks in `run_forever`, one `stop()` per pass**,
  instead of a `run_until_complete(batch())` per pass (38 µs on stdlib
  asyncio against 17): every shim event is appended to a list, the first
  append while the pump is parked schedules the stop for the end of the
  next iteration, and `wait_events` returns the list. Measured on top of
  batching: +16% at 16 connections (50,747 rps, 0.90x `uvicorn --loop
  asyncio`), +18% at 64 (67,258, 1.17x), +2% at 256. A stop is armed
  only while the pump itself is parked — never inside
  `finish_executor`'s post-pill gather or `lifespan_shutdown`, which it
  would end early with "Event loop stopped before Future completed",
  skipping the application's shutdown; `smoke-asgi`'s new
  outlive-the-drain phase pins it, and `apps/asgi_bare` writes
  `M0_SHUTDOWN_MARKER` from its lifespan shutdown so the phase can tell.
- **Python calls into Mojo for every executor event; the executor thread
  never leaves `run_forever`.** `ExecutorPort` is a Python type built
  with `PythonModuleBuilder` inside the embedded interpreter (no shared
  library, no `PyInit_`, no ctypes; ~70 ns a call) and set into the shim
  as `_port`; every event that used to be queued for a Mojo pass is
  `_port.dispatch(ev)`, handled at once inside the loop iteration that
  produced it, and completions are poked to the loop once per iteration
  by a `call_soon`-scheduled `_port.flush`. The per-pass
  `run_until_complete` (38 µs on asyncio, 64 on uvloop) is gone.
  Measured beside the `run_forever`+`stop()` pump: on stdlib asyncio
  within noise at 16 connections (49,713 rps, 0.93x
  `uvicorn --loop asyncio`) and 1.07x / 1.13x at 64 / 256; on
  uvloop, which this shape finally lets pay, 60,419 rps at 16
  connections — +24% over the pump on the same loop, 1.05x the
  asyncio comparator, 0.74x uvicorn with uvloop — and 0.94x uvicorn
  with uvloop at 256. `bench_asgi_wrk.sh`
  gains `BENCH_EXECUTOR_PYTHON=system` for an A/B of the executor's loop.
- The benchmark page's ASGI row is re-measured (0.72x → 0.75x
  against `uvicorn --loop asyncio` at 16 connections, executor on
  uvloop) and now also states the uvloop number a default `pip install
  uvicorn[standard]` produces (0.53x). Which loop the
  executor ran on was never recorded before: `bin/m0serve` outside the
  venv embeds the system Python and runs on stdlib asyncio — measured to
  be a wash either way (−3% at 16 connections, +4% at 256).

### Fixed

- **A stream on a recycled slot could stall silently.** The executor's
  per-slot state (credit window, event, disconnect mark) was keyed by
  slot alone; the loop recycles a slot the instant it closes a
  connection, and the previous task lives on for an iteration or two.
  When the HTTP/1.0 client of `chunked_keepalive.py` closed after the
  head and the keep-alive stream that followed landed on the same slot,
  the new task saw the OLD connection's disconnect mark, cancelled its
  own stream, and — the mark being the slot's — skipped its end signal,
  leaving the loop a subscribed stream with no producer: the client
  waited 30 s on a clean server log (CI macOS, 1 in 2; 8 of 11 runs
  under twelve CPU hogs locally). A stale task's late cleanup could
  also wipe the live task's window. Now a slot's state belongs to the
  slot's current task (`_exec_slot_task`): cleanup only by the owner, a
  disconnect stamped on the task it hit (with the dead connection's
  in-flight bytes refunded there), a stale mark cleared when a new task
  takes the slot, and every "am I gone" check asking both. 0 of 6 under six CPU hogs (the plain build: 4 of 5)
  after, same load.
- **A second `m0serve` on a busy port fails, loudly, instead of binding
  beside the first.** `SO_REUSEPORT` was set unconditionally on every
  listener, so a second server on an occupied port bound successfully,
  printed "Ready", and on Linux took a share of the connections (17 of 40,
  measured from the wheel in `python:3.12-slim`; macOS: served nothing).
  The option is now opt-in on `ListenConfig` (`reuse_port=False`; workers
  and threads share one pre-fork listener and never needed it), and
  `m0serve` binds with five attempts a second apart — a restart racing the
  previous process's 5 s drain still succeeds — then exits 1 with
  `address already in use: HOST:PORT -- is another server running?`.
  `smoke-serve` pins it.
- **"Ready" means ready.** The listener's banner printed before the
  application was imported, so a failed import logged "Ready to accept
  connections" and then exit 1. `m0serve` now binds quietly
  (`ListenConfig(quiet=True)`); its own startup line, printed after the
  load, is the ready signal.
- **A load failure shows its traceback.** An application whose import
  raises (a settings module without its environment variable, a missing
  dependency) printed only the exception's one-line text. The shim now
  attaches the Python traceback for every failure that is not the spec's
  own module or attribute being absent — those stay one line, because a
  bare `MODULE` tries four discovery candidates and the misses must stay
  quiet — and discovery stops at a candidate that exists and raises
  instead of trying the next convention. `apps/wsgi_bare/deep_fail` is
  the case; `smoke-serve` pins it and the quiet misses.

- **A stream that raises after its head is truncated honestly.** The
  connection closes without the chunked terminator — for a WSGI generator
  and for an ASGI application alike; the executor used to end such a body
  cleanly, which made a short body indistinguishable from a complete one.
- **A chunk that outlived its connection can no longer land in a
  recycled slot's new stream.** Every stream frame carries its stream's
  generation and the loop handler drops one that is not the
  subscription's. One producer's frames are FIFO behind its own begin;
  with two producers on one loop (an executor and a pool thread, two
  executors, or a hold arriving on the other bus fd) there was no order
  between them at all.
- **A stream whose head completes during the shutdown drain is now told
  goodbye.** The drain loop dispatches write-readiness only, so such a
  connection was never closed and its producer waited out the bounded
  join as a straggler; a second farewell pass after the drain closes it.

## [0.13.0] — 2026-08-27

A security-audit release plus two wire-protocol conformance fixes. Several
requests that previous versions accepted are now refused, and one class of
client that previous versions hung is now served — read **Changed** before
upgrading anything that speaks non-standard HTTP at this server.

### Security

- **A cross-connection injection hole is closed.** Channel names opening
  with the reserved `\x01` byte address connection SLOTS on the loop, and
  an application channel is frequently user input (`%01` in a form body
  decodes to the control byte): an unauthenticated POST could reach
  another client's SSE stream through `publish()`. Every publish boundary
  now refuses reserved and over-long names — `publish_to_channels`, the
  shim's `_M0Broadcast`, and both copies of `m0pub.publish_frame`.
- **`/ws/message` is the server's path, not an application's.** Under
  `--realtime` it carries synthetic POSTs with trusted `M0-*` headers and
  a CSRF exemption; a request for it arriving over the wire is now 404,
  so only the in-process synthetic one reaches the app.
- **Response headers carrying CR, LF or NUL are dropped, not transmitted**
  (and an injected status reason phrase is emptied) — a header an
  application built from user input can no longer end the header block
  and add headers or a body of its own.
- **`Proxy` request headers never reach WSGI/ASGI environs** (httpoxy):
  CGI's mechanical mapping would turn them into `HTTP_PROXY`, the
  variable outbound HTTP clients read to choose a proxy. Nothing else is
  dropped — `X-Forwarded-*` is load-bearing behind a real proxy.
- **Static mounts serve only regular files**, auth token comparison runs
  in constant rounds, WebSocket datagrams are bounded, and the WS outbox
  drops whole frames past a 64 KB cap instead of growing unboundedly.

### Fixed

- **Pipelined requests are all answered, in order** (RFC 9112 §9.3).
  Every release through v0.12.0 answered only the first request of a
  pipelined burst and left the client hanging on the rest: the keep-alive
  reset cleared the receive buffer, and bytes consumed together with a
  previous request get no readiness event of their own. The request's end
  is now stamped at dispatch, the keep-alive reset preserves the tail
  (and ONLY the keep-alive reset — a tail can never leak across
  connections), and a drain loop answers buffered requests after every
  completed response, on both backends and on the blocking path.
  `poe smoke-pipelining` pins it.
- **A client that half-closes (`shutdown(SHUT_WR)`) after sending gets
  its response.** kqueue reports a half-close as `EV_EOF`, and closing
  there discarded the response already written: macOS lost 24–30 of every
  30 requests on GET, Content-Length and chunked alike; Linux lost none.
  The loop now finishes the buffered request and only turns off
  keep-alive. `poe smoke-half-close` pins it.
- **The epoll backend registers `EPOLLRDHUP`, ending the half-close
  divergence.** A half-closed INCOMPLETE request now releases its slot
  promptly on Linux too, where it used to be indistinguishable from a
  silent client and waited out the full 10 s header timeout for a 408.
  The guard is layered — a recv returning 0 marks the peer gone even
  where the flag is absent — and a half-close while a request is out on a
  `--blocking-threads` pool thread no longer detaches the fd (which
  dropped the response the pool thread was about to complete): the
  completion answers through the still-open fd.
- **A request bigger than one read is answered on epoll too.** The header
  path performed one recv per readiness edge and never re-armed, so a
  request over 8192 bytes — a large cookie jar or a JWT, not an attack —
  stalled on Linux until the header timeout answered 408. Headers now
  re-arm exactly as the body path always did; requests are served up to
  the 32 KB header cap and answered 431 beyond it.
  `poe smoke-large-request` pins the boundary.
- **A chunked request body is decoded incrementally by one persistent
  decoder per connection.** Rebuilding the decoder per read event made a
  dribbled chunked body O(N²) on the loop thread — 3 MB took 1.37 s,
  0.006 s after — and reset the decoder's own abuse-ratio guard so it
  could never trip.
- **The chunked terminator is consumed** (`consume_trailer`), so closing
  a `Connection: close` socket no longer leaves the final CRLF unread —
  which made the kernel send RST instead of FIN and discarded the
  response, measured at up to 53% of chunked requests and 100% when the
  client paced its writes.
- **HTML escaping passes UTF-8 through intact** (`escape_html` in
  m0-core): `café` no longer renders as `cafÃ©`.
- **An application's `Set-Cookie` goes to the wire verbatim** (subject
  only to the CR/LF refusal). Round-tripping it through the server's own
  cookie model silently dropped `expires`, `SameSite`, everything after
  the first `=` in a value, and any unmodelled attribute — on every
  Django session and CSRF cookie of every app.

### Changed

Requests that v0.12.0 accepted and this release refuses, or handles
differently — each is a smuggling or correctness surface:

- **HTTP/1.1 without a `Host` header → 400.** Hand-rolled clients and
  crude health checkers sometimes omit it.
- **Malformed `Content-Length` → 400** (`5, 5`, `0x10`, `+5`, `-1`,
  `5abc`, longer than 18 digits). Previously read as 0 and served as
  bodyless — which a proxy in front could read differently.
- **`Transfer-Encoding` whose final coding is not `chunked` → 400.**
  `gzip` alone was previously served as bodyless.
- **An encoded slash stays encoded**: `unquote` re-emits disallowed bytes
  as `%XX` instead of deleting them, so `/adm%2Fin` no longer collapses
  to `/admin`.
- **A chunked body is bounded by raw bytes consumed as well as decoded
  size** — a body whose framing outweighs its payload roughly twice over
  now answers 413 (1 MB in 3-byte chunks is 3.6 MB on the wire).
- **A chunked request that omits the final CRLF now waits for it**, as it
  would for any truncated body, instead of being answered early.

### Added

- `poe smoke-pipelining`, `poe smoke-half-close`, and
  `poe smoke-large-request` — socket-level regression probes for the
  fixes above, run on both CI runners because each bug was invisible on
  one platform.
- The PyPI publish path is hardened: the `pypi` environment is the
  authorization boundary (deployment branch policy + required reviewer),
  the publishing action is pinned, and the wheel set is validated against
  the tag before upload.

## [0.12.0] — 2026-08-26

### Added

- **WebSocket holds work with `--blocking-threads` and with `--mount`.**
  The last thing `--realtime` refused. A pool thread performs the 101 — the
  client's key is in the request it holds — and sends the loop an `H` frame
  carrying its own lane; the loop records which mount holds the socket, and
  an inbound frame rides the submit channel back as a `TAG_WS_MESSAGE`
  datagram (the executor's shape plus the channel, since a pool thread's
  registries are empty). `next_job` decodes both shapes off one channel,
  told apart by length, into a buffer owned by the thread so a WebSocket's
  size is not charged to every request. Two orderings are load-bearing and
  both are pinned by `smoke-django-realtime-ws` phases 3 and 4: the pool
  must be asked about a socket before the executor (on a mixed mounted
  server the executor's fd is set, and asking it first hands every message
  to an executor that never accepted the connection), and the
  "not pool-held" sentinel cannot be -1, which is a real lane. The whole
  socket probe — handshake, fan-out, relay through Django, channel
  isolation — now runs against a pool and against mounts, and behind two
  1.5 s views it costs +13 ms against its own baseline.

- **`--realtime` composes with `--mount`.** One process can now hold the
  SSE streams a synchronous application publishes to *and* run an ASGI
  mount for the streams whose view is the producer — the shape a mixed
  application needs, and the one that kept `textshelf` in two processes
  (docs/REAL_APP_VALIDATION.md). The loop tells a held stream from an
  executor's **per slot** rather than per server
  (`OffloadPool.slot_is_executor`, read from the lane `submit` already
  stamps): asking globally was the same question only while the two could
  not share a loop, and a held stream drained as an executor's would be
  chunk-framed, acked to an executor that never issued the credit, and
  denied the comment heartbeat that keeps it alive through an idle proxy —
  none of which stops delivery, so none of which looks wrong.
  `smoke-django-realtime` phase 6 holds one stream of each kind on one loop
  and asserts both. Still refused: a `websocket` hold under `--mount`
  (409 — an inbound frame is a synthesised POST into one urlconf), and
  `--realtime` on a server with no WSGI mount at all.

- **`--realtime` composes with `--blocking-threads`.** A hold taken on a
  pool thread is forwarded to the event loop's registries as a reserved
  frame on that loop's own bus channel, before the response completes —
  the executor's begin-before-head seam, applied to a second producer —
  so a held-stream server no longer has to run its views on the loop. On
  textshelf with eight slow views in flight that is the difference between
  a 1 543 ms fast-path p50 and 0.3 ms, and between M0-Hold being
  demonstrable and deployable. SSE holds only: a WebSocket hold under the
  pool answers a 409 that says why (inbound messages still reach the view
  on the loop thread), and `--mount` with `--realtime` stays refused. The
  loop needs no ordering guarantee for the forwarded frame because,
  without an executor, it has no end-of-stream signal to misread a
  not-yet-subscribed slot as. `smoke-django-realtime` phase 5 pins the
  composition; `smoke-blocking-threads` and `smoke-doctor` now assert the
  pair is accepted where they asserted the refusal.

- **The isolation benchmark has an artifact, and the ratchet caught sixteen
  stale sentences.** Gate 3's last item. `bench/results/` now carries a
  `mixed-workload-*.json` — the pool's ~100x p99 claim, the largest effect
  in this repository and previously the only one with no machine-readable
  source — plus a post-pin re-run of the WSGI layer split.

  Re-rendering moved every derived figure, and `check_bench_prose` failed
  the build naming **all sixteen** prose sentences that had gone stale
  across README.md, docs/BENCHMARKS.md and docs/WSGI_PERFORMANCE.md, each
  with the value it claimed and the value the artifact computes. That is
  the whole reason it exists: the tables re-render themselves, and before
  this the sentences around them would have quietly kept the old numbers.
  Per-core ratio 0.83x → **0.85x**, bridge tax 1.44x → **1.36x**.

  Two findings the run itself produced. **Granian's `--blocking-threads`
  row is better than ours** — ~0.6 ms flat against our best ~2 ms — which
  is now on the page, because the honest claim is that the pool removes a
  hundredfold *stall*, not that it wins the tail that remains. And the
  earlier note that granian "is not in this repo's lock file" was wrong: it
  is, in the `bench` group at the pinned 2.8.1, one `uv sync --group bench`
  away. That is why its row had been missing from the isolation table.

  Recorded because it changes how these are read: **one anomalous round per
  run is normal on this box.** Three recorded layer-split runs each had
  exactly one round land well off the other two, in a different position
  each time, while their medians agreed to within 0.03 on the per-core
  ratio. Median-of-three is doing real work here, not ceremony.

- **The first screen leads with what the server is for.** Gate 5. All three
  surfaces that have a first screen now open on the same claim — *realtime
  from a synchronous Python app, with no added infrastructure* — with the
  hero shown as six lines of ordinary sync Django rather than described:
  README.md, `packaging/m0serve/README.md` (which is what PyPI renders, and
  is the one nothing was checking until this release), and `llms.txt`.

  The gaps are on the first screen rather than in an issue: no TLS or
  HTTP/2 (terminate at a proxy), the platform floors, pre-1.0, and — stated
  with numbers and a link — that this is **not** the fastest server on raw
  throughput. A page that hid that would be contradicted by the benchmark
  page two clicks away.

  The snippet was run before it was published: a Django app containing
  exactly those six lines, served by `bin/m0serve --realtime`, delivers
  `id: 2 / data: deploy finished` to a live `curl -N` subscriber. The
  fuller path stays covered in CI by `smoke-quickstart`.

- **[docs/BENCHMARKS.md](docs/BENCHMARKS.md): the public benchmark page,
  and it leads with the losses.** Gate 3 of the launch checklist. Four
  generated regions across two documents, all driven by
  `render_bench_docs.py` and all CI-checked — hand-edit a table, or land a
  new artifact without re-rendering, and `check-docs` fails naming the file.

  Two things it does on purpose. It states plainly that m0serve is **~0.83x
  Granian per measured core on bare WSGI and 0.72x uvicorn on ASGI
  throughput**, because the win it does claim — fast-request p99 under
  mixed load — is only credible next to them. And it renders a *stated
  absence* for the mixed-workload bench rather than omitting it: the
  handler pool's ~100x p99 improvement is the strongest claim in this
  repository and currently the only one with no machine-readable source.

  `render_bench_docs.py` grew from one region in one document to a table of
  targets, with a renderer per bench kind. The isolation bench gets its own:
  its finding is a comparison *across* slow levels within one configuration,
  so the rows are pivoted — a flat row isolated the slow work, a climbing
  one did not — and the percentiles are re-medianed from `rows`, since
  `bench_record.medians()` folds only rps and cores. It also stops naming a
  comparator the artifact's environment stamp recorded but the bench never
  ran: on a public page, "granian 2.8.1" beside a table with no granian row
  reads as if it had been measured and lost.

- **`m0serve --doctor`: the configuration as JSON, starting nothing.** The
  launch checklist's machine-readable startup diagnostic, and the reason is
  narrower than "nice to have": every refusal this server makes already
  names its fix, but seeing one meant *attempting the run* — which binds a
  port, forks, and imports the application. `--doctor` reports platform and
  wheel architecture, the interpreter it resolved and the virtualenv it came
  from, the spec discovery chose and the protocol it classified as, the
  resolved topology (including whether the handler pool is a default or
  configured), and a `checks` array whose failures each carry `detail`,
  `fix` and `exit`.

  **The contract is the exit code: `--doctor` exits with the code `m0serve`
  itself would exit with for the same arguments** — 0 serve, 2 usage,
  1 startup, 78 `EX_CONFIG`. A diagnostic that reports "fine" where the
  server refuses is worse than no diagnostic, and the doctor mirrors the
  startup path's check order rather than sharing its control flow, so
  nothing but a test keeps them in step: `poe smoke-doctor` runs *both*
  binaries over every refusal and compares.

  That test earned its place before it was committed. The first
  implementation recorded the free-threading check before the usage
  conflicts, so `--workers 2 --threads 2` reported 78 where the server exits
  2 — the interpreter is never reached, because `main` decides topology
  conflicts before any Python runs. `Report.exit_code` returns the *first*
  failure rather than the largest for the same reason, and
  `test_doctor.mojo` pins it.

  A bare `m0serve --doctor` with no application is the "is this environment
  sane" call and exits 0 — reporting the interpreter facts is precisely what
  a failed install needs, and previously libpython not resolving was visible
  only as a traceback at serve time.

### Changed

- **The loop's `before_request` runs before a request is offloaded**, not
  only on the queue-full fallback — where, under a pool, it never ran on
  the loop at all. `WSGIHandler` answers its static mounts and the health
  path there, so under `--blocking-threads` those are served on the loop
  in Mojo rather than by a pool thread: a stylesheet stays readable
  whatever the pool is busy with, and `/health` reports the registries the
  loop actually drains. Before this, under the newly-composed `--realtime
  --blocking-threads`, it reported zero subscribers while events were
  being delivered — a pool thread's own registries are always empty.

- **The mounted-isolation guard had 138x headroom and now has 12x.**
  `hybrid_isolation.py`'s `ISOLATION_BUDGET_MS` was 400 ms against an
  observed p99 of 1.4–4.1 ms, so it discriminated "isolated" from "sharing
  an execution mode" (~2000 ms, the sync view's hold) and nothing in
  between: a regression that parked the async mount for 300 ms — a
  hundredfold degradation, plainly visible to a user — passed. It is now
  50 ms, chosen from 17 recorded CI runs across both runners rather than
  from the gap to the failure signal, and the docstring carries that
  evidence and its one limit (every run is the prefork phase; the
  `--threads` phase is skipped wherever there is no free-threaded
  interpreter with fasthtml).

  Every run now prints its headroom, pass or fail, because a number
  drifting from 12x to 2x is the warning that comes before the failure.

- **A total loss of isolation reported a stack trace.** With the pool off
  (`--blocking-threads 0`) the sync mount's warm-up never returns at all,
  and the script exited on a urllib `TimeoutError` — the smoke failed, but
  whoever read the log had to work out why from a traceback. A request that
  never returns is now reported as what it is, with the two things to check
  named. The ordinary failure still reports a number: sample timeouts are
  bounded well above the 2000 ms hold, so a request genuinely queued behind
  the sync work is measured rather than erroring.

- **`check_wheel_platform_claims` now checks what its docstring always
  said.** It asserted that a wheel gets built at all and that neither README
  points at 3.13t; it never compared a platform table to anything. It now
  reads the `plat:` entries out of `release.yml`'s `build-wheels` matrix —
  the only place a wheel that reaches PyPI is declared — and holds **both**
  READMEs to them in both directions: a built platform must be marked
  supported, and a platform marked supported must be built. Either failure
  is a claim with no artifact behind it, which is the whole premise of this
  file.

  Recorded while wiring it, because it is the opposite of the guess:
  `test.yml`'s `paths-ignore` lists `*.md`, and a GitHub path glob's `*`
  does not cross `/`. A PR touching only the root `README.md` therefore
  skips CI entirely, while one touching only `packaging/m0serve/README.md`
  runs the full suite. The published README is the guarded one.

- **The quickstart's version echo is machine-checked.** QUICKSTART.md showed
  `m0serve 0.10.0` against a 0.11.0 tree. The doc promises every command in
  it is executed by CI, and that promise is kept for ```bash blocks —
  but the echo lives in a ```text block, which `run_quickstart.py`
  displays rather than asserts. That is the right design (the other text
  block interleaves output from three commands and is not byte-stable), so
  the check belongs in `check_docs.py`, where prose facts with a machine
  source live. [docs/RELEASING.md](docs/RELEASING.md) names the fourth bump
  site; `poe check-docs` fails on all four.

### Fixed

- **`--app-dir` is prepended to `sys.path`, not appended.** It appended
  where gunicorn, uvicorn and `runserver` all `sys.path.insert(0, ...)`, so
  an application module could be shadowed by an installed package of the
  same name — and the shadowed application simply is not the one served,
  with nothing to see. The help text, `cli.mojo` and `app.mojo` had all
  said "prepended" since the flag existed; now it is true.
  `prepend_to_path` also declines to move an entry already at the front,
  and leaves duplicates further down alone — a path the user put there is
  not the server's to edit. Found by dogfooding the wheel, reconfirmed by
  the three-project pass, and guarded by a `smoke-serve` phase that puts a
  module named `django` under `--app-dir` in a venv where the real Django
  is installed.

- **Every `Set-Cookie` an application set lost its `expires` and `SameSite`
  attributes.** The WSGI/ASGI bridge parsed each `Set-Cookie` line into a
  `Cookie` and re-serialised it, and that round trip was lossy four ways:
  `Expiration` is a stub whose `from_string` parses nothing, `SameSite`
  matched only lowercase values, a value was cut at its first `=` (base64
  pads with one), and any attribute the struct does not model was dropped.
  Django's session and CSRF cookies therefore reached every browser without
  `expires` or `SameSite` — a persistent cookie silently demoted to a
  session cookie, and a CSRF cookie without its defence. Application lines
  are now transmitted **verbatim** (`ResponseCookieJar.add_raw`), which is
  also the cheaper path on the measured response half of the bridge. Found
  by serving three real Django projects; `smoke-django` now reads the cookie
  off the wire and requires all four attributes, because curl's jar stores
  name and value only and could never have seen it.

- **Uploads between ~1.5 MB and `--max-body` were refused with `400`.** The
  per-connection receive buffer had its own 2 MB ceiling that `--max-body`
  never raised, so a body the server advertised as acceptable was rejected
  by the wrong check with the wrong status — under the default 4 MB cap too.
  The limit is now derived (`ServerConfig.recv_buffer_limit()` = headers plus
  body allowance, floored by `recv_buffer_max`), so raising the body cap
  raises the buffer with it. A 7.1 MB image upload to a real Django app
  found it.

- **Concurrent ASGI streams truncated each other, and enough of them wedged
  the executor.** The chunk credit window is per stream (64 KB) while the
  chunk channel is one shared `SOCK_DGRAM` pair, so N streams over-commit it;
  `send_stream_chunk` then dropped the datagram it could not place — a short
  body under a clean terminator, or, with the end frame dropped, a response
  that never completed at all. Twelve concurrent WhiteNoise `FileResponse`s
  under Django were enough. Now bounded globally (`_ASGI_TOTAL_WINDOW` in the
  shim, where waiting is an `await` rather than a Mojo spin that would hold
  the GIL against the very loop that has to drain the channel), with the loop
  keeping owed credit and retrying it when the ack channel is momentarily
  full. `smoke-asgi` runs 32 concurrent `FileResponse`-shaped streams and
  checks every byte.

- **`SIGTERM` never returned while a handler thread sat in a response that
  never ends.** A `StreamingHttpResponse` served under WSGI is buffered, so
  an SSE generator never returns and its pool thread never comes back;
  `stop_and_join` waited for it forever, turning `docker stop` into a
  `SIGKILL` after the grace period. The join now has the same 5 s budget as
  the drain (`ThreadSet.join_within`), after which the process exits naming
  how many threads it left inside the application. Nothing in the process can
  unwind Python on another thread, so leaving is the only correct answer;
  waiting was not.

- **`smoke-wheel` leaked a server on every run, and could pass against the
  wrong binary.** Nine orphaned `m0serve` processes accumulated over one
  day of development, all still `LISTEN`ing on port 8129, one of them still
  answering `200 OK` a day after the run that made it.

  Two independent defects. The launch was
  `(cd "$work/app" && env ... m0serve ...) &` — a *list*, which bash cannot
  exec-optimize, so `$!` was the **subshell** rather than the server.
  `kill $pid` killed the wrapper and left `m0serve` orphaned to init. Adding
  `exec` makes the subshell become the server, which is how
  `bench_mixed_workload.sh` had been doing it all along. And the `EXIT` trap
  only removed the temp directory, so every `fail` after the launch leaked
  one too; the server pid is in the trap now.

  The consequence was worse than untidiness. The server sets `SO_REUSEPORT`
  because prefork needs it, so the kernel adds a new listener **alongside**
  a stale one and load-balances between them: a leaked server from an
  earlier run can answer this smoke's request, and the assertions then pass
  against a binary that is not the one under test. `smoke-wheel` now refuses
  to start when 8129 already has a listener, naming the pids and the command
  to clear them.

  Verified by running the pre-fix task once (leaks exactly one process,
  `ppid 1`) against the fixed one (leaks none, on both the success and the
  failure path), and by putting a decoy listener on 8129 to trip the new
  refusal.

- **The README quoted a decomposition its own measurements had retired.**
  It said the one-worker gap to Granian "splits evenly, 1.58x HTTP layer and
  1.58x bridge" — numbers from before the CPU-normalized re-run, which
  WSGI_PERFORMANCE.md had already replaced with ~1.0x × 1.35x and explicitly
  marked as "records of what was measured, not descriptions of the
  present". The README kept quoting them, in raw rps, against a comparator
  since found to be running 1.75 cores. Rewritten from the artifact.

- **"There is no chunked encoding" was no longer true.** The server has
  chunked transfer-encoding and ASGI responses stream through the executor
  chunk-framed on HTTP/1.1. WSGI responses are still fully buffered, but
  the reason is PEP 3333 — a WSGI response carries a `Content-Length`,
  which means knowing the length — not a missing feature.

- **The PyPI project page told aarch64 users their wheel did not exist.**
  0.11.0 shipped a `manylinux_2_35_aarch64` wheel and its release notes
  claimed "the platform matrix on the README is the platform matrix on the
  index" — which was true of the repository's README and false of
  `packaging/m0serve/README.md`, the `readme` named by the wheel's
  pyproject.toml and therefore the page PyPI renders. That one still read
  `Linux aarch64 | buildable, not yet shipped` for the whole of the
  release. Two READMEs, one of them published, and the ratchet was pointed
  at the other.

- **A README number quoted twice, guarded once.** The mounted-isolation
  p99 (2.8 ms) now appears on the first screen as well as in the mounts
  section. It is not artifact-backed — `hybrid_isolation.py` asserts a
  deliberately generous ceiling rather than recording the figure — so
  `check_hybrid_p99_consistent` checks the two copies against *each other*
  instead. A number edited in one place and not the other is the ordinary
  way a README starts contradicting itself.

- **The bench prose was answerable to nothing, and it was wrong.**
  `render_bench_docs` kept the generated *tables* honest; the sentences
  around them — where the headline claims actually live — were checked by
  no one. docs/WSGI_PERFORMANCE.md stated the WSGI result as a
  decomposition, "roughly 1.0x HTTP layer × ~1.35x bridge", and it does not
  reconcile with the artifact directly beneath it: the measured per-core gap
  is **1.21x**, and a 1.35x bridge term requires an HTTP layer term of
  0.89x — this server's HTTP layer *slower* than the comparator's, which
  the same sentence denies.

- **The boolean-flag dispatch had a fallthrough.** `parse_args` ended its
  chain with `else: opts.metrics = True`, so a new flag added to `_is_bool`
  and forgotten in the dispatch silently enabled Prometheus metrics instead
  of doing its job. `--doctor` would have been the first victim. The `else`
  now raises, and `test_cli.mojo` asserts each boolean sets only itself.

### Documentation

- **`textshelf` re-measured after stage 1**
  ([REAL_APP_VALIDATION.md](docs/REAL_APP_VALIDATION.md), *Revisited*).
  With `--realtime` and the pool composing, the recommendation the record
  pointed at changed, so it was re-measured rather than re-reasoned. Two
  findings. m0serve's ASGI executor matches uvicorn and daphne to the
  millisecond on both a sync and an async generator — whatever streams
  under them streams under it. And the application's own AI streaming
  endpoints do not stream anywhere, including its production daphne: the
  producer is a *sync* generator, which Django's ASGI handler consumes
  before serving. That makes those endpoints free to move, which leaves
  the `--mount`-with-`--realtime` refusal as the only thing standing
  between a mixed application and one process — recorded in the ROADMAP
  as a re-ordering of stage 2, ahead of the WebSocket half. The real-application
  pass produced one finding about the shape of the server rather than a
  defect in it: `--realtime` refuses `--blocking-threads`, so the cheapest
  way to hold a stream (M0-Hold: +2 MB per 200 held, no Python state, no
  database connection) costs the pool that cures the hostage pathology —
  measured on textshelf as a 1 543 ms fast-path p50 under `--realtime`
  against 0.3 ms with the pool, with eight slow views in flight. The entry
  records the numbers, the mechanism the executor already uses to solve the
  identical problem (a reserved begin frame the loop's handler turns into a
  subscription), a staged design for SSE holds then sockets, the narrower
  `--mount` refusal that follows from it, and what must be shown before it
  is built. Verdict recorded with it: the larger of the two is the
  difference between the realtime claim being demonstrable and deployable.

- **Three real Django projects, served — the record**
  ([REAL_APP_VALIDATION.md](docs/REAL_APP_VALIDATION.md)). The plan that
  file used to hold has been executed: `transcripts` (plain WSGI, `src/`
  layout), `color-separation` (numpy/Pillow pipelines, uploads, downloads)
  and `textshelf` (four SSE endpoints, three pubsub modules, WhiteNoise,
  djstripe) served from clean clones against scratch databases, through
  `--doctor`, byte-parity against `runserver`, the feature matrix, the
  topology matrix, a realtime retrofit and a soak. Four defects, all fixed
  below, three of which no application in `apps/` could have shown. After
  the cookie fix, every remaining parity difference on every route of all
  three apps is `connection: keep-alive`, `x-thread`, or Django's debug page
  echoing its own port.

- **The desktop-Mac hypothesis, and the packaging tension under it**
  (ROADMAP, Open questions). Recorded because the relevant decision is
  already shipped and otherwise invisible: `poe build-serve` pins
  `--target-cpu` to `apple-m1`, the *oldest* Apple Silicon, so the PyPI
  wheel deliberately forfeits M-series-specific capability — including the
  +sme/+sme2 matrix extension the build comment notes this M4 would
  otherwise target. The pin exists because the first release crashed with
  SIGILL in a clean container, so it is not a mistake to undo; it is a
  tradeoff that points the other way from "exploit the Mac's silicon", and
  the two should be reconciled deliberately. Also recorded: what has to be
  established first, including that this toolchain has no `gpu` module at
  all, and that the neural engine is a CoreML surface rather than something
  a language targets directly.

## [0.11.0] — 2026-08-26

The release that makes three published claims true at once: the quickstart
works against the PyPI package, `pip install m0serve` includes the publish
helper the realtime story depends on, and the platform matrix on the
README is the platform matrix on the index.

### Added

- **`m0serve.m0pub` ships in the wheel.** The publish half of the realtime
  feature — `m0pub.publish(channel, data)` from any sync view, one
  `os.write` per worker plus an atomic fetch-add for the globally unique
  event id. It was previously only in the repository's demo app, so a pip
  user had a server that could hold connections and no way to publish to
  them. Pure stdlib; degrades to 0 workers under any other WSGI server and
  to unnumbered frames without the shared counter, exactly as documented.

- **[QUICKSTART.md](QUICKSTART.md), and it is executable.** Ten minutes from
  `pip install m0serve` to live multi-tab sync from one synchronous Django
  file — SSE verified by curl with expected output stated, WebSockets in
  the browser, cross-worker fan-out with `--workers 2`. CI extracts the
  fenced blocks and runs them against the tree's own wheel on every pull
  request (`poe smoke-quickstart`), so the doc a stranger follows is pinned,
  not aspirational. It caught its own author before anyone else: a first
  draft asserted event ids survive a server restart, and the runner failed
  the doc — ids are unique across one server's workers, by design.

- **`llms.txt`** — the operating contract for agents: strict flags, exit 78
  refusals that explain themselves, the `M0-Hold` protocol, where to start.

- **Linux aarch64 wheels** (Graviton, Ampere, arm64 Docker). The platform
  was already proven — built by hand in an arm64 container, passing the full
  wheel smoke including the removal sabotage — so the only thing between it
  and users was a CI runner. `build-wheels` and `wheel-consume-linux` are
  now matrices over both Linux architectures, and the aarch64 wheel is
  consumed on real arm64 hardware rather than under emulation, which would
  defeat the purpose of a job that exists to run an artifact on a machine
  that did not build it.

  Also added to `test.yml`, not just the release path: `release.yml` runs on
  a tag, so aarch64-only would have meant discovering a break *during* a
  release, after the GitHub release exists and with the upload gated behind
  it. That is the failure shape the consume jobs were built to prevent.

  The README claimed Linux arm64 support before the wheel existed, so a
  Graviton user would have got `No matching distribution found` — the
  literal "didn't install" comment the release checklist names as its
  first risk.

- **`scope["client"]` and `REMOTE_ADDR`: the peer reaches Python.** The
  fork's `accept()` passed a 4-byte `addrlen`, so the kernel truncated
  the peer address before the IP bytes — it was unreadable even in
  principle. `accept_with_peer` keeps the full sockaddr, the event loop
  stamps each request (`HTTPRequest.remote_addr`/`remote_port`, captured
  once per connection on the provision), and the peer crosses to Python
  on both protocols: WSGI gets `REMOTE_ADDR`/`REMOTE_PORT` in the environ
  (per request, C-API only, same no-leak discipline), ASGI gets
  `scope["client"] = (host, port)` on http and websocket scopes. Django
  populates `request.META` from these only when present — `client: None`
  doesn't error, it silently logs every visitor as address-less, which
  disables rate limits, IP allow-lists and audit logs.

- **`apps/django_asgi` + `poe smoke-django-asgi`: Django's own ASGI
  handler, proven.** A bare `djasgi` discovers `djasgi.asgi:application`,
  detection classifies it ASGI, and the executor serves it zero-config.
  The smoke pins: discovery + the `asgi-loop` banner; `/meta` showing the
  real peer (verified load-bearing against a server sending `None` — it
  answers empty); four overlapping 400 ms async views completing in ~1x;
  `StreamingHttpResponse` streaming live rather than buffered; a
  signed-cookie session counter surviving three round trips; SIGTERM.
  `smoke-wsgi` gains the environ-side `REMOTE_ADDR` assertion.

- **Cross-worker fan-out for ASGI applications: `state["m0"]`.** Every
  ASGI app now finds a pub/sub object in its lifespan state — the
  Channels channel-layer shape with no Redis, riding the `BroadcastBus`
  that already existed for GRIP. `m0.publish(channel, payload)` writes
  one datagram per worker channel (m0pub's exact protocol, shared-atomic
  event ids included, best-effort on a full or dead channel);
  `m0.subscribe(channel)` is an async iterator fed by frames the loop's
  handler forwards to each executor as tagged submit datagrams. The bus
  fd conflict that blocked this — the executor consumes `bus_read_fd`
  for its ASGI chunk channel — is answered by a second registered fd on
  the loop (`peer_bus_fd`), same codec, same drain, same handler entry.
  The bus (plus `SharedAtomics` ids and env exports) is now created
  unconditionally pre-fork: an ASGI app cannot be detected until after
  the fork, and a single worker publishing to its own subscribers rides
  its own channel — there is no separate local-delivery path to keep in
  sync. `poe smoke-asgi-fanout` pins the spread (6 streams over 2
  workers), delivery of one publish to every stream on both workers,
  distinct cross-worker ids, supervisor SIGTERM with a live subscriber,
  and the single-worker case.

- **An ASGI server validator — the `wsgiref.validate` that never got
  written.** WSGI has a stdlib conformance checker and this repo runs it;
  ASGI has nothing standard (the `asgiref` testing helper plays the
  server rather than checking one, and uvicorn/hypercorn/daphne verify
  themselves bespoke). `apps/asgi_bare/bareapp/validate.py` is the
  analog, written from the ASGI 3 spec: every required scope key with its
  exact type (bytes-vs-str is THE classic server bug), the receive
  stream's protocol, `server`/`client` tuple shapes. `M0_ASGI_VALIDATE=1`
  wraps the app; violations raise and answer 500. `smoke-asgi` gains the
  validated pass, with `/validate/canary` proving the wrapper is engaged
  — a bogus message type the unvalidated server ignores (200) and the
  validator refuses (500), the `/pep3333/canary` pattern exactly.

- **`--mount PREFIX=SPEC`: several applications in one process.** A
  `m0serve` process can now host more than one application, routed by
  longest prefix before either sees the request — `--mount /=djangoproj
  --mount /portal=portal.wsgi:app` serves a Django project and a Flask app
  from one listener, one set of workers and one graceful shutdown. Each
  mount detects its own protocol (discovery included) and gets its own
  bridge and shim namespace; a path no mount claims is a 404 answered in
  Mojo, never entering Python; prefixes match on segment boundaries, so
  `/app` never swallows `/application`.

  The prefix reaches both protocols through one seam, because they
  disagree about what it means: WSGI gets `SCRIPT_NAME` with `PATH_INFO`
  trimmed to the remainder, ASGI gets `root_path` with `path` left whole
  (Django's `ASGIHandler` strips it itself). Getting that backwards leaves
  every direct request working while every generated URL breaks, so
  `smoke-hybrid` compares Django's `reverse()`, Flask's `url_for()` and
  both frameworks' `request.path` byte for byte. New row:
  `apps/hybrid_mix`, deliberately two frameworks rather than two Django
  projects — those would share `django.conf.settings` and the first import
  would win, which would make the isolation claim a lie.

  Refused rather than guessed, each with a message saying why: mixed
  WSGI/ASGI mounts (routing them is done; giving each its native execution
  mode is the next stage), `--mount` with `--realtime` (an inbound
  WebSocket message has no defensible destination among several urlconfs),
  and a mounted server taking the asyncio executor (one submit channel
  cannot say which mount a job is for). See docs/WSGI_VS_ASGI.md §9.

- **Mixed mounts, each in its native execution mode.** A sync Django app
  and an async FastHTML app now run in ONE process, sharing one listener
  and one graceful shutdown, with Django's requests on handler-pool
  threads and FastHTML's on the asyncio executor. The mechanism is a
  submit **lane** per mount — the single submit channel became one
  `SOCK_DGRAM` pair each — so the loop hands a job to the worker that can
  run it; one `ProvisionPool` per loop stays, since a slot indexes that
  loop's provisions. `match_path_prefix` is now the single implementation
  of the matching rule, so the lane a job takes and the application the
  handler picks cannot disagree, and each worker builds only its own
  mount's application rather than every mount's.

  Measured and smoke-pinned: with four blocking 2-second Django views
  holding every pool thread, the FastHTML mount answers at p50 1.3 ms /
  p99 2.8 ms. `apps/hybrid_mix` is now Django + Flask + FastHTML in one
  process.

- **Several ASGI mounts, one executor each.** The one-ASGI-mount limit is
  lifted: every ASGI mount gets its own executor thread, its own bridge
  and lifespan, and its own drain-ack pair (`OffloadPool.enable_stream_ack`),
  with the loop routing each ack by the lane recorded at submit
  (`slot_lane`) — credit belongs to the executor that owns the slot, and
  an ack routed anywhere else is a stream stalled forever rather than an
  error, which is why the smoke streams 256 KB (four credit windows) from
  two executors concurrently and byte-counts both. Executors share the
  one chunk channel: its datagrams were always slot-addressed, and a
  single `SOCK_DGRAM` queue is globally FIFO across writers, so the
  recycled-slot safety argument survives. The reserved channel names now
  carry the executor's lane (`\x01<kind>/<slot>/<lane>`; the unmounted
  wire format is unchanged), which is how disconnect tags and inbound
  WebSocket messages route back to the owning executor — parsed from the
  slot's own subscription record, no side table to drift. Shutdown sends
  one pill per executor on its own lane. `apps/hybrid_mix` gains
  `feed.asgi`, a second async mount beside FastHTML's.

## [0.10.0] — 2026-08-25

Promotes 0.10.0rc1 unchanged. The rc's whole purpose was to run the upload
path once on a filename that could be spent: it published, installed from
the real index on machines that never built it, and served. Nothing needed
fixing afterwards, so this is the same artifact under a stable number.

What the release candidate cost, kept here because the reasoning outlives
the incident: three attempts and four defects, every one of them invisible
from the machine that built the artifact.

- The binaries were compiled for the build host's CPU (`mojo build` defaults
  `--target-cpu` to it), so `m0serve --version` died with SIGILL in a clean
  container after passing on the runner that produced it. Not detectable by
  static inspection at all — only by running the artifact on different
  silicon.
- `wheel-inspect` runs on Linux and checks both wheels, but read Mach-O
  through `otool`, which macOS has and Linux does not.
- The glibc negative control ran `pip` with no shell in the container, so
  its glob stayed literal and pip refused the wheel for the wrong reason.
  The guard caught precisely that and declined to score it as a pass.
- The release published as "Latest", above the current stable, because
  `gh release create` does not infer pre-release status from a tag.

### Changed

- Version only. No source changes from 0.10.0rc1.

## [0.10.0rc1] — 2026-08-25

First release published to PyPI, as a release candidate: it claims the name
and exercises the production upload path — trusted publishing, the
two-platform wheel set, the tag/version cross-check — before a stable number
is spent on an untried path.

One correction, because this entry originally claimed otherwise: **`pip
install m0serve` does install it.** pip excludes pre-releases only when a
stable version also exists, and there is none here, so the rc is the only
candidate and pip takes it. The rc therefore buys rehearsal, not
invisibility; quietness rests on nothing being announced. The upside is that
the index-install path — pip choosing the right file from several platform
wheels, from a real index, on a machine that never built them — is proven
rather than deferred.

### Added

- **`pip install m0serve` — the server as an installable binary.** A
  WSGI/ASGI server for Python applications, with no Mojo toolchain on the
  target machine and nothing fetched at install time (the wheel declares no
  dependencies). `m0serve myproject.wsgi:application` serves either protocol,
  detected from the object.

  **One wheel per platform covers every supported CPython** — 3.10 through
  3.14 including free-threaded builds — because `m0serve` does not link
  libpython; Mojo `dlopen`s the interpreter at run time, so there is no
  CPython ABI in the archive to be compatible with and no CPython in it to
  redistribute. Verified across all five, and by serving Django 5.2.17 on
  CPython 3.11 from a wheel built on 3.13 with Django 6.1.

  Built from `packaging/m0serve/`, a separate project holding the only
  `[build-system]` in the repository: one in the root would make uv treat
  the repo as installable, and that build needs `bin/m0serve`, which needs
  the `.venv` uv is creating.

- **The platform tag is measured, not declared** (`scripts/wheel_tag.py`).
  It reads `LC_BUILD_VERSION` and versioned glibc symbols out of the staged
  binaries and takes the strictest floor. Copying the toolchain's own
  `macosx_13_0` tag would have shipped a wheel requiring macOS 26.

- **`poe bundle-serve` and `poe check-serve-portable`**, mirroring the
  `libm0core` pair, plus `stage-wheel`/`build-wheel`/`smoke-wheel`.

- **Clean-consumer release jobs.** The wheel is installed and made to serve
  in containers and on a runner that never built it — four CPython minors,
  `--network none`, and a permanent negative control asserting an older
  glibc is *refused* by pip rather than crashed at startup. Each job asserts
  its own cleanliness first, and `check-docs` fails the build if one ever
  acquires a checkout.

### Fixed

- **Binaries were compiled for the machine that built them.** `mojo build`
  defaults `--target-cpu` to the host CPU, so every artifact this project has
  produced was effectively `-march=native`. The first release run proved the
  consequence: `m0serve --version` died with `Illegal instruction (core
  dumped)` in a clean container after passing on the runner that built it,
  and on a developer machine the effective target was `apple-m4` with
  `+sme`/`+sme2` — Scalable Matrix Extension, which no M1, M2 or M3 has.
  `build-ffi` and `build-serve` now pin the oldest CPU each platform must
  support (`apple-m1`, `x86-64-v2`, `generic`), and `check-docs` asserts they
  do. Unlike the rpath defect this resembles, it is invisible to static
  inspection — only running the artifact on different silicon can find it,
  which is exactly what the clean-consumer jobs do.

- **The portability checker could not see an executable, and the bundler was
  blind the same way.** `otool -L` prints a *dylib's* own `LC_ID_DYLIB`
  before its dependencies; an `MH_EXECUTE` has none, so dropping the first
  entry discarded `bin/m0serve`'s only real dependency. The checker reported
  `SELF-CONTAINED` for a binary that resolved the Mojo runtime through a
  developer's `.venv`, and `bundle_ffi.py` would have copied zero runtime
  libraries and called the bundle complete. The parse now lives once in
  `scripts/binfmt.py`, keyed on the load command's presence, self-tested in
  CI against both cases.

- **`build-serve` had no post-link surgery at all**, so every `bin/m0serve`
  ever built recorded a search path into the venv that produced it. It now
  shares `build-ffi`'s, via `scripts/relocate.py`, and completes its bundle
  in place — so `bin/` is the shipped shape rather than a development
  arrangement that worked for a different reason.

- **The macOS deployment target is pinned to 13.0.** `mojo build` honours
  `MACOSX_DEPLOYMENT_TARGET`; without it the binary inherited the build
  host's SDK, making the wheel's reach a property of whichever image GitHub
  calls `macos-latest`.

- **"The Linux artifact is statically linked" was true of one file only.**
  Measured on `libm0core.so` and carried as a platform fact; the `m0serve`
  executable links the three Mojo runtime `.so` files on Linux exactly as on
  macOS. Nothing in the tooling decides by platform now, only by what the
  file records. `patchelf` is a Linux build requirement in consequence, and
  `nightly-canary.yml` — which builds `m0serve` — had no dependency step at
  all.

### Changed

- **NOTICE describes artifacts, not just the source tree.** The wheel is the
  first artifact to redistribute the lightbug_http fork in object form, and
  MIT requires its notice to travel with copies — so
  `licenses/LICENSE.lightbug_http.txt` and `licenses/NOTICE.m0serve.txt`
  ship inside the wheel and the `m0serve` bundle. NOTICE gains a table of
  which notice covers which artifact, and no longer implies the Linux builds
  contain no Modular code.

- **The README's platform claim is architecture-qualified**, because once
  wheels exist `pip` enforces it: macOS Intel is not untested but
  *impossible* (no toolchain wheel), Linux aarch64 is buildable and
  unshipped, and the glibc floor excludes musl. The free-threading claim
  moved from "3.13t+" to 3.14t, which is what is actually tested — 3.13t
  systematically immortalizes objects, as `pyproject.toml` and
  `docs/WSGI_VS_ASGI.md` already recorded.

## [0.9.0] — 2026-08-24

### Added

- **ASGI WebSockets (Phase 3b): `app.ws` works.** A WebSocket handshake
  on an ASGI app gets a `websocket` scope on the executor's loop. The
  ready 101 (built by the loop's own validator from the original
  request's key) is held until the application's `websocket.accept` —
  the same approve/perform split as M0-Hold — and released through the
  completion channel behind a FIFO-anchoring begin frame; outbound
  frames are RFC 6455-encoded executor-side and ride the 3a chunk
  channel into the `sockets` registry; `websocket.close` queues the
  close frame plus the end marker and the loop closes after both land;
  inbound messages travel as tagged submit-channel datagrams into
  per-slot queues behind `receive()`; a disconnect cancels the task and
  a never-answered handshake resolves as 403 so no slot leaks.
  `smoke-asgi` drives a raw RFC 6455 probe (verified accept, text and
  binary echo, close(1000) to the FIN, abrupt-vanish cleanup);
  `smoke-fasthtml` proves FastHTML's `app.ws` end to end — its full
  surface (pages, SSE `EventStream`, WebSockets) now runs on `m0serve`
  with zero configuration.

- **ASGI streaming responses (Phase 3a): SSE actually streams.**
  FastHTML's `EventStream`, Starlette's `StreamingResponse`, and Datastar
  patch streams now stream live through the asyncio executor instead of
  meeting the buffered watchdog's 500. Response chunks travel from the
  executor thread to the event loop as datagrams on a private per-loop
  channel and ride the existing `SSERegistry` per-slot outboxes under
  reserved channel names (a leading control byte no HTTP header value can
  carry, so GRIP channels cannot collide). Correctness is ordering and
  credit, both smoke-pinned: a stream's begin frame precedes its head on
  one FIFO channel (so a recycled slot can never receive another
  stream's chunks), a 64 KB credit window with 32 KB chunk split means
  the loop's drain acks pace the producer (a 100 MB stream behind a slow
  reader grows server RSS ~2 MB), bodies are close-delimited and the
  loop closes on end-of-stream via the previously-uncalled
  `sse_is_streaming` hook, client disconnects cancel the app task
  (uvicorn's contract), and comment heartbeats are suppressed on ASGI
  streams so an SSE event split across chunks can never be corrupted —
  asserted byte-exact under a 300 ms cadence, alongside an md5-checked
  1 MB streamed body. `smoke-fasthtml` now asserts live `/sse` ticks;
  the buffered escape hatch (`--blocking-threads` + ASGI) keeps its
  watchdog refusal. WebSocket scopes are Phase 3b.

- **The asyncio executor: real await-concurrency for ASGI (Phase 2).**
  Zero-config ASGI now serves through one executor thread per event loop
  (`m0_wsgi.asgi_executor`) running the bridge's persistent asyncio loop:
  the loop parks each request and submits its slot through the unchanged
  `OffloadPool` datagram channel, `loop.add_reader` turns slots into
  tasks, and completions answer through `put_response`/`complete`.
  Requests overlap wherever the application awaits — eight concurrent
  1.5 s awaits complete in 1.51 s on one loop with zero threads — and the
  banner says `asgi-loop`. The executor path crosses method, path, query,
  headers (ready lowercase byte-pairs), and body straight through the C
  API as stolen tuple slots — no environ, no CGI names, no Python-side
  re-transform — and the RSS guard stays flat (20 KB–1.7 MB across runs,
  allocator noise against the 12 MB limit). Exactly
  one lifespan runs per loop (fallback handlers are built with
  `lifespan=False`); the executor picks uvloop for its own loop where
  installed. An explicit `--blocking-threads N` keeps the Phase-1
  buffered pool as the escape hatch; `--threads N` composes (one executor
  per loop, free-threaded CPython only, as before). `poe bench-asgi` is
  the standing gate against uvicorn: the mixed slow/fast fast-request p99
  passes (2.87 ms vs 3.27 ms); hello-world throughput stands at
  0.88–0.94x with the remainder located and its fix paths recorded in
  docs/WSGI_PERFORMANCE.md §"The ASGI executor vs uvicorn".

- **`m0serve` is now a hybrid WSGI/ASGI gateway with zero-config
  detection.** The protocol is detected from the application object at load
  (coroutine-function duck typing — the rule uvicorn and asgiref share;
  `--protocol auto|wsgi|asgi` overrides it), so FastHTML, Starlette,
  FastAPI, and Django's `asgi.py` serve from the same binary that serves
  Django/Flask WSGI. ASGI requests run on a persistent per-bridge asyncio
  loop, buffered: the scope is derived in the shim from the same C-API
  environ, `send()` events collect into the same `(status, headers, body)`
  tuple, and no new per-request Mojo↔Python object traffic exists —
  `smoke-asgi`'s RSS guard (same 12 MB/10k-request limit as the Django
  row) measured 356 KB on day one. Lifespan startup/shutdown run with
  uvicorn's "auto" semantics, and lifespan `state` reaches request scopes.
  Streaming responses are the recorded limit: a response still unfinished
  10 s after its first `more_body=True` is answered with an explanatory
  500 pointing at docs/WSGI_VS_ASGI.md §8 (the buffered bridge cannot
  carry an infinite SSE/EventStream; that surface is the design's Phase 3).
- **Spec discovery**: a bare `m0serve MODULE` now tries
  `MODULE:application`, `MODULE.asgi:application`, `MODULE.wsgi:application`,
  `MODULE:app`, `MODULE.main:app` in order — a Django project or a
  FastHTML/FastAPI `main.py` serves without learning either convention. An
  explicit `:ATTR` never falls back. A total miss lists every spec tried,
  and a non-callable names both expected signatures.
- **Zero-config concurrency**: with no `--workers`/`--threads`/
  `--blocking-threads` flag and no `M0_*` topology variable, `m0serve` now
  starts a handler pool of `min(cores, 8)` blocking threads, so one slow
  view no longer stalls every connection out of the box. Any explicit
  topology value wins — `M0_WORKERS=1` or `M0_BLOCKING_THREADS=0` restore
  the old single-loop shape — and `--realtime` keeps the single loop
  (its streaming hooks run on the loop's handler). The banner reports
  `protocol=` and marks the pool `(auto)`.
- New rows and gates: `apps/asgi_bare` (the ASGI sibling of `wsgi_bare` —
  every route pins one clause of the contract) with `poe smoke-asgi`, and
  `apps/fasthtml_demo` with `poe smoke-fasthtml` (skips where
  python-fasthtml is absent). `python-fasthtml` joined the dev dependency
  group.

### Changed

- `wsgi.multithread` is `True` under the zero-config pool (it is a real
  thread pool), and ASGI apps refuse `--realtime` with an explanatory
  message — the M0-Hold contract is a WSGI response-header protocol.
- docs/WSGI_VS_ASGI.md gained §8: the deliberate revisit of its §6
  verdict, with the three-phase gateway design (buffered bridge →
  per-loop asyncio executor over the offload channel → ASGI realtime over
  the existing bus/registry transport).

## [0.8.0] — 2026-08-24

### Added

- **`poe bundle-ffi` — a self-contained, redistributable `libm0core`.** The
  macOS artifact resolves the Mojo runtime at load time and is useless
  without it, so releases now ship `<asset>.tar.gz` containing the library,
  the runtime it loads, and both licences — 1.65 MB, verified to `dlopen`
  from an unrelated directory with `DYLD_LIBRARY_PATH` and
  `DYLD_FALLBACK_LIBRARY_PATH` unset. The bare library remains a separate
  asset so existing download URLs keep working; the Linux `.so` is
  statically linked and self-contained already.

  The dependency closure is **discovered, not listed** — a hand-written
  first attempt shipped only the library named in the error message and
  then failed on *its* dependency, so `bundle_ffi.py` walks the graph and a
  toolchain bump that adds a fourth library is picked up rather than
  silently producing a broken bundle. The task refuses to finish unless the
  result is self-contained, so assembly and assertion cannot drift apart,
  and CI runs it on every commit: **a release can no longer publish an asset
  that only loads on the build machine.**

  The Mojo runtime is Apache 2.0 with LLVM Exceptions. Rather than rely on
  the exception excusing attribution for separately shipped files, the
  bundle **complies with section 4 in full** — licence text, attribution,
  and an explicit 4(b) notice that install name, rpath and code signature
  were changed while the executable code is byte-for-byte as built. See
  `NOTICE` and [docs/FFI_DISTRIBUTION.md](docs/FFI_DISTRIBUTION.md), which
  also record the one piece of contrary evidence: the `mojo_compiler` wheel
  still declares the proprietary MAX licence, though it contains only the
  compiler and runtime — no MAX components — and ships no licence file of
  its own.

### Changed

- **The WSGI response path was never measured, and was 10x the request
  path. `build_response` now costs 3.30 µs instead of 22.97** for a
  six-header Django-shaped response; `serve()` 25.51 → 5.65 µs. End to end
  on `apps/wsgi_bare` — one response header, the *least* favourable shape —
  **49,517 → 56,896 rps (+14.5%)**, p50 291 → 252 µs.

  The cause was not the Python boundary. Splitting it put the
  `PythonObject` header read at 1.27 µs (5%) and `name.lower()` at
  **19.36 µs (84%)** — a Unicode-lowercased copy of every header name,
  allocated solely to compare against one constant. `name_is` was already in
  the repo doing this correctly for the identical Set-Cookie dispatch on the
  request side, and its docstring already named the mistake. The fix is that
  one call.

  `scripts/bench_bridge_parts.mojo` now covers both directions, at one, six,
  and six-plus-two-cookie response headers, so this cannot go unpriced
  again. `name_is` and `ascii_lower_byte` gained unit tests
  (`test_headers.mojo`) — they had none despite being the whole of header
  case folding, now in both directions; the boundary test was verified to
  fail when the `A`–`Z` range is widened by one byte.

- **The Granian layer split is re-measured on 3.14.7t, and the gap it was
  written to explain is spent.** After five bridge changes, the row that has
  driven every roadmap priority since it was taken: **at four workers
  m0serve is now ahead of Granian, 101,892 rps against 98,489**; at one
  worker the gap is **2.50x**, down from 4.31x.

  The re-measurement carries its own validity check. Nothing here touched
  the HTTP layer or Granian, and all three rows that should not have moved
  reproduced within 2% — `apps/hello` 0.99x, Granian 0.98x at one worker and
  0.99x at four — across five weeks and a Granian bump to 2.8.2. The two
  rows that moved are the two the bridge work touched: **3.94x at one worker,
  2.91x at four.**

  What is left at one worker is **1.58x HTTP layer × 1.58x bridge** — dead
  even, and their product is the whole 2.50x. The original conclusion, *"the
  headroom is in the bridge, not the HTTP layer"*, was right when measured
  (6.30x against 1.59x) and no longer is. Part of the four-worker result is
  Granian's own 19% loss from one worker to four on a four-performance-core
  box; m0serve scales 2.08x over the same step. Both stated.

- **m0-sqlite: the text-scan cost is measured, and the zero-allocation read
  is documented.** `bench_sqlite.mojo` gained TEXT rows — the one column
  type it never priced — showing `column_text` pays **2.1x** for its
  per-row `String` at 64 B and at 4 KB alike. The fast path already
  existed: `column_blob_into` works on TEXT columns (SQLite's UTF-8
  TEXT→blob conversion is a pointer handoff), and the two docstrings now
  point at each other. No new API, per the package's own rule. Also
  recorded in SQLITE_PERFORMANCE.md: the WSGI-bridge techniques checked
  item-by-item against this package — most already applied or without an
  analog, and the one fresh suspect (a hidden `StringLiteral` → `String`
  conversion on every binder's happy path) measured at 0.0 ns and was
  left alone.

- **Each request's environ starts as `PyDict_Copy` of a finished base
  template — `build_environ` 1.78 → 1.56 µs, the bridge 2.35 µs.** One C
  call replaces ten per-request hash-and-stores (58 ns vs 214 measured),
  and `Python().cpython()` is acquired once per request instead of sixteen
  times. The template is copy-isolated: an app may overwrite or delete
  anything in its environ without touching the next request's, probed with
  ten vandal/inspect cycles and a second `set_base`. The decision that
  *didn't* ship matters as much: an intern cache for recurring header
  names/values measured as a net loss — its hit-path byte-compares cost
  more than the 15 ns decodes they would skip — so it was never built, and
  the bridge is now near the structural floor WSGI's environ shape sets.

- **The response body is read through `PyBytes_AsString` instead of
  `ctypes` — the bridge costs 2.50 µs per request instead of 3.52.**
  `body_bytes` was 31% of what the bridge had left, and the split named one
  cause: the shim's `body_addr()`, which built two `ctypes` objects per
  request. It now runs **no Python at all** — `PyObject_Length` for the
  length, `PyBytes_AsString` for the address, one `memcpy` for the copy.
  **1.07 µs → 0.13 µs**, and end to end on one worker serving
  `apps/wsgi_bare`: **45,891 → 48,852 rps, +6.7%**, p50 315 → 295 µs. That
  is **1.69x cumulative** against the 28,853 rps measured before any of the
  bridge work.

  **The general finding matters more than the optimisation.**
  `Python().cpython()` binds no `PyBytes_*` and no `PyUnicode_DecodeLatin1`,
  and `external_call` cannot reach them either, because libpython is not on
  the link line — Mojo `dlopen`s it, which is why `CPython` is a struct of
  loaded function pointers. But that struct exposes its handle, and the
  stdlib's own `ExternalFunction[name, type].load(cpy.lib.borrow())` opens
  the functions it omitted. **The whole CPython C API is reachable**, which
  retires "there is no binding for it" as a constraint on this boundary.

  `PyBytes_AsString` is stable-ABI and checked — NULL plus `TypeError` on a
  non-`bytes`, where the `PyBytes_AS_STRING` macro would read wrong offsets
  and is not a symbol anyway. The pointer is resolved once at construction;
  the call it returns is 1.0 ns. `smoke-django`'s RSS guard still reports
  **0 KB over 10k requests** — reading through a raw pointer takes no
  reference.

  The **request** body followed in the next entry — see below.

- **The request body crosses as a real `bytes` via
  `PyBytes_FromStringAndSize` — the blob design is fully retired.** Mojo
  builds the `bytes` straight from the request's own buffer (one copy,
  inside the call) and hands it to the shim as a stolen tuple slot;
  `io.BytesIO(bytes)` shares the buffer copy-on-write, so `wsgi.input`
  costs no second copy where the old bytearray protocol always paid one.
  Staging a 1 KB body: **1.6 µs → 0.07 µs (~23x)**; end to end, a 1 KB POST
  to `apps/wsgi_bare`'s `/input/read`: **42.1k → 47.3k rps (+12%)**, GETs
  unchanged. Deleted outright: the shim's 64 KB transfer bytearray,
  `buf_addr()`, the grow protocol, and the shim's `ctypes` and `sys`
  imports — it now imports nothing but `io`. Every request costs exactly
  one call into Python, the `PyObject_CallObject` that runs
  `run(environ, body)`.

### Fixed

- **The C-ABI artifact no longer records the machine that built it.**
  `build-ffi` rewrites both paths after the link — install name
  `packages/m0-core/libm0core.dylib` → `@rpath/libm0core.dylib`, search path
  `/Users/runner/work/.../modular/lib` → `@loader_path` — taking the macOS
  artifact from **BROKEN to SATISFIABLE**: it now looks beside itself, so a
  consumer can supply the runtime. Neither path can be suppressed with a
  linker flag, because `mojo build` adds them itself; macOS also needs an
  ad-hoc `codesign`, since arm64 invalidates the signature on any Mach-O
  edit and an unsigned dylib will not load at all.

  **`smoke-ffi` was silently undoing this**: it ran its own `mojo build` into
  the same output path, so it overwrote `build-ffi`'s output and tested an
  unfixed artifact. It now depends on `build-ffi` and tests what that task
  emits, supplying the runtime through `DYLD_LIBRARY_PATH` — the documented
  consumer requirement, exercised rather than accidentally bypassed.

  **Linux was never broken the way macOS is.** The published `.so` has no
  `DT_NEEDED` entries at all and is statically linked; its `DT_RUNPATH` was
  inert debris. The missing-runtime problem is macOS-only, and
  `check-ffi-portable` now reports three states — `BROKEN`, `SATISFIABLE`,
  `SELF-CONTAINED` — because pass/fail could not express that. It also reads
  ELF itself rather than shelling out: the previous version used
  `llvm-objdump`, which exists on macOS, formats ELF differently, matched
  nothing, and reported a Linux artifact as portable. A guard that answers
  "fine" when it cannot read the file is worse than no guard.

  Still not self-contained: shipping the runtime turns on a licensing
  question, and the **2026-08-23 nightly still declares the proprietary MAX
  Platform license** — five days after the Apache-2.0 relicensing, so the
  discrepancy is not a same-day packaging slip. Building the runtime from
  the Apache-licensed sources was assessed and rejected as disproportionate
  (an MLIR/Bazel compiler stack for a 1.57 MB macOS-only bundle). See
  [docs/FFI_DISTRIBUTION.md](docs/FFI_DISTRIBUTION.md).

- **The published `libm0core` artifacts do not load off the machine that
  built them, and now there is a check that says so.** Every release from
  v0.1.0 has shipped a C-ABI library whose recorded search path is the CI
  runner's own directory, so `dlopen` — the entire point of the artifact —
  fails for anyone who downloads it. `smoke-ffi` could never catch this: it
  loads the library **in the build tree**, where the venv it was linked
  against still exists, so it passes on exactly the machine where the defect
  cannot appear.

  `poe check-ffi-portable` checks what a load attempt cannot — that every
  recorded search path is self-relative and every dependency is a system
  library or shipped alongside — and fails on the current artifact and on
  every published one, which is how it was verified. The README no longer
  claims the prebuilt artifacts are usable as-is.

  The fix is demonstrated in [docs/FFI_DISTRIBUTION.md](docs/FFI_DISTRIBUTION.md)
  (the bundled artifact loads from an unrelated directory with a clean
  environment) but not yet applied: two of the three defects are ours and
  need no permission, while shipping the Mojo runtime's 1.57 MB
  three-file closure turns on a licensing question that is genuinely
  unresolved — Mojo's sources went Apache-2.0 with LLVM Exceptions on
  2026-08-18, but the wheel shipping those prebuilt binaries still declares
  the proprietary MAX Platform license. Recorded in NOTICE.

- **`body_bytes` no longer swallows a pending exception.** `PyObject_Length`
  answers -1 with the exception *set*; folding that into the empty-body case
  returned an empty list and left the error pending, poisoning whatever
  C-API call ran next. Unreachable through the shim contract today (`_body`
  is always `bytes`), found by review, fixed before it could become
  reachable.

## [0.7.0] — 2026-08-23

### Added

- **`m0serve --blocking-threads N` / `M0_BLOCKING_THREADS` — Stage B, the
  acceptor and its handler pool.** The event loop stops calling
  `HTTPService.func`. It parses the request, hands it to one of N handler
  threads, and returns to `wait()`; the thread calls the handler and pokes
  the loop back, which encodes and writes the response through the same
  `RESPONDING` path every other response takes. **One slow view no longer
  stalls the connections pinned behind it**: on `apps/wsgi_bare`, a fast
  request answered in **1 ms** with two 1.5 s views in flight, against
  **2.7 s** for the identical server without the flag — the same code, the
  same load, the flag as the only variable.

  This is the failure the mixed-workload benchmark measured and Stage A did
  not touch (fast-request p99 1.6 ms → ~194 ms, ~120x, under `--workers`
  *and* `--threads` alike), because a keep-alive connection belongs to the
  loop that accepted it in both modes and adding loops does not change that.
  Granian's `--blocking-threads` is the same architecture and the reason the
  design had a working reference.

  Composes with both execution modes — `--workers W` gives W processes of N
  handler threads, `--threads T` gives T loops of N each, one pool per loop
  because a job names a slot and a slot means nothing outside the loop whose
  provision pool it indexes. Off by default: it costs N threads and N
  handlers' worth of per-thread state per loop, and a server whose views are
  all fast gains nothing.

  Unlike `--threads`, it is **not** refused on a GIL-enabled interpreter. A
  pool under the GIL is what gunicorn's `--threads` is: CPU-bound views
  serialize, but a view waiting on a database, a socket or a sleep releases
  the GIL and the isolation is real — which is the workload the mode exists
  for. It **is** refused together with `--realtime`, because the streaming
  hooks (`sse_drain_slot`, `sse_slot_disconnected`, `ws_message`) are called
  on the loop's handler while `func` would run against a pool thread's own
  registries; half-wiring that would fail quietly.

- **`lightbug_http.offload`** — the queue itself, and it knows nothing about
  Python. Two `SOCK_DGRAM` socketpairs (submit, and a completion channel the
  loop registers exactly as it registers a `BroadcastBus` channel) plus
  per-slot request/response storage. Datagrams because they preserve message
  boundaries: N threads receiving on one channel each dequeue one whole job,
  so the kernel is the queue and there is no mutex to write. Each handoff is
  published by the socketpair syscall that names it, which is the whole
  memory-ordering argument. `m0_wsgi.blocking_pool` is the thread side —
  the only half that attaches to an interpreter, which is what keeps
  libpython off everything else's link line.

  **Retiring the pool is one method, `BlockingPool.stop_and_join`, and that
  is a safety property rather than tidiness.** `next_job` blocks with no
  timeout, so the poison-pill count must equal the thread count exactly: a
  thread that receives no pill blocks forever, which is a hung
  `pthread_join`. Closing the queue does not rescue it — on Linux, closing
  the write end of a connected `AF_UNIX` `SOCK_DGRAM` pair does **not** wake
  a peer already blocked in `recv`, while macOS returns 0 and looks fine.
  That asymmetry cost a 20-minute CI timeout: `test_offload.mojo` read one
  pill more than `stop` had sent, to "prove" the close was a backstop, and
  passed locally while hanging ubuntu. The claim is gone from the code and
  the count is now a property of the type instead of an agreement between
  call sites.

  Three things a slot in flight is *not*: touched by the loop, swept by the
  idle or header timeout, or recycled. A client that disconnects mid-job
  detaches the fd but leaves the provision borrowed until the completion
  arrives, so a late completion has nowhere wrong to land — a generation
  counter would detect that race, holding the slot removes it. Past 256
  jobs in flight the loop runs requests inline rather than queueing them,
  which is a bound on what the channels must hold and degrades to exactly
  the behaviour of a server without the flag.

- **`c/socketpair.mojo`**, extracted from `broadcast.mojo` — one binding, two
  callers, and one deprecated-`alloc` warning site instead of two. See
  [NOTICE](NOTICE).

- **`poe smoke-blocking-threads`.** Phase 1 runs everywhere: the `--realtime`
  refusal, the isolation measurement, four clients abandoned mid-job leaving
  every slot recovered, HEAD through the pool (the loop has to remember it —
  by completion time the request belongs to another thread), a raising
  handler, and SIGTERM answering an in-flight request rather than dropping
  it. Phase 2 needs the GIL off and is `py-canary`'s new phase F: two loops
  of four handler threads each, proving Stage B composes with Stage A — and
  deliberately loading only half a pool, because past saturation a request
  queues for a thread, which is what a thread pool is and not what the row
  asserts. Measured at **1 ms against a 400 ms gate**, so the row fails on a
  broken pool rather than on a busy machine.

### Changed

- **The WSGI environ is built in Mojo through the CPython C API — the bridge
  costs 3.5 µs/request instead of 14.9.** `PyDict_New` and `PyDict_SetItem`
  build the dict, `PyUnicode_DecodeUTF8` builds every key and value, and
  `PyTuple_New`/`PyTuple_SetItem`/`PyObject_CallObject` hand the finished
  dict to the shim. End to end on one worker serving `apps/wsgi_bare` with a
  browser-shaped keep-alive request: **28,853 → 45,715 rps, 1.57x**, p50
  508 → 315 µs, p99 1.06 ms → 681 µs.

  This retires the last large measured item in the Granian gap. The shim
  used to rebuild the environ in **pure Python on every request**, parsing a
  binary blob Mojo had just written — 28 `_read_str` calls for a
  twelve-header request, 12.09 µs of the bridge's 14.23, 85% of it.

  The blob existed because Mojo 1.0's `PythonObject` leaks a reference per
  call argument, so the environ could not be passed as one. The raw C API
  refcounts explicitly and is not that path, which is what made this
  possible at all. `smoke-django`'s RSS guard — the instrument for any
  change to this boundary — still reports **0 KB over 10k requests**.

  The **request body still crosses as bytes** through the persistent
  bytearray, because Mojo 1.0 has no `PyBytes_*` binding of any kind and a
  `bytes` object therefore cannot be built from Mojo. A request with no body
  now skips that path entirely — `buf_addr()` is not called and nothing is
  copied. There is no `PyUnicode_DecodeLatin1` either, so PEP 3333's
  latin-1 tunneling is spelled as a UTF-8 encode in `environ.mojo` and
  decoded by `PyUnicode_DecodeUTF8` into exactly the same `str`; ASCII, the
  overwhelming case, is its own UTF-8 and costs no copy.

### Removed

- **`serialize_request` and the request blob format.** Nothing crosses the
  boundary positionally any more except the request body, which needs no
  framing because its length is passed as an argument. `environ.mojo` keeps
  the pure half — `cgi_header_name` and the CGI/latin-1 byte transforms —
  so the mapping stays testable without an interpreter, and
  `test_environ.mojo` still asserts the two statements of the CGI rule
  agree on every shape it distinguishes.

### Fixed

- **Graceful shutdown no longer waits the full 5 s drain for connections
  that are already finished.** `active_count` counts a connection that is
  merely *open* the same as one with a request in flight, so a server
  holding idle keep-alive connections waited out the whole
  `DRAIN_TIMEOUT_NS` budget at SIGTERM — **5.02 s to exit against 0.02 s
  idle, in every execution mode**, which is most of what `docker stop`
  allows before it escalates to SIGKILL.

  The shutdown path now closes slots in `READING_HEADERS` whose receive
  buffer is empty — "between requests" — before it starts the drain clock.
  Those connections could never have been served by the drain loop anyway:
  it dispatches `EVFILT_WRITE` only, so a request arriving mid-drain is not
  read there. **5.02 s → 0.03 s** under `--workers 4`, under
  `--blocking-threads 4`, and on a single loop.

  A slot mid-request, mid-response, or with a job in a pool thread is left
  alone, and the SSE/WebSocket farewell still runs first, so streaming
  clients get their close comment or 1001 frame. Both halves of the
  contract are pinned: `smoke-blocking-threads` already asserted that a
  request in flight at SIGTERM is answered rather than dropped, and
  `smoke-shutdown` gained a phase (`scripts/drain_idle_probe.py`) asserting
  idle keep-alive connections do not hold the drain open — checked against
  the unfixed loop, where it fails at 5.01 s.

  This also retires the standing suspicion that `--threads` shuts down
  slowly. It does not, and neither does the pool: every mode exited at
  5.02 s, and a 5 s wait loses that race.

## [0.6.0] — 2026-08-23

The release that finished moving the WSGI examples off their own
`server.mojo`, and made the bridge 2.35x faster. `--realtime` and
`--health-path` carry the hold machinery `apps/django_realtime` used to own,
`--reload` re-forks workers onto changed Python in ~300 ms, and
`serialize_request` — 77% of the bridge's per-request cost — went from 48 µs
to 0.44 µs, taking `apps/wsgi_bare` from 12,289 to 28,911 rps. The
benchmarking also settled what comes next: one slow view raises fast-request
p99 by ~120x in *both* execution modes, which is the failure Stage B was
built to remove.

### Added

- **`m0serve --realtime` — the hold machinery behind a flag.**
  `apps/django_realtime` was the last example carrying its own
  `server.mojo`; everything in it now lives in `WSGIHandler`. The flag turns
  on two `SSERegistry`s (streams and sockets, holding disjoint slots),
  `take_hold` on every application response, the WebSocket handshake a
  buffered WSGI response cannot produce, `ws_message_request` for inbound
  frames, and — created before the fork and before the first Python call —
  the `BroadcastBus` and the `SharedAtomics` id slot with their
  `M0_BUS_WRITE_FDS` / `M0_SHARED_ID_ADDR` exports. `M0_CORE_LIB` is
  *discovered* rather than demanded: beside the binary first, then
  `poe build-ffi`'s output, and left alone if already set. Off by default,
  because it costs two slot arrays and because it makes `M0-Hold` a header
  the server consumes rather than one an application may emit for its own
  reasons.
- **`--realtime` works under `--threads N`.** The bus is built on the main
  thread before spawning and loop `i` drains `read_fd(i)`, exactly as worker
  `i` does. A `SOCK_DGRAM` socketpair does not care whether the peer is a
  process or a thread, so `m0pub.py` and `sse_peer_frame` are unchanged —
  the publisher reaches N threads with the N `os.write`s it used to reach N
  processes and never learns which it is talking to. `smoke-django-realtime`
  phase 4 pins it where the GIL is off (`py-canary` C3): six streams spread
  over four loops, one publish from one thread's Django reaching all six
  with numbered ids, then a clean four-loop drain on SIGTERM.
- **`m0serve --reload [--reload-dir DIR]` — hot reload.** A changed `.py`
  under a watched directory stops the workers and forks replacements onto
  the new module, in ~300 ms plus a drain. The flag forces a supervisor even
  at one worker and even under `--threads N`, and that composes with both
  execution modes for one reason: the supervisor never touches Python. It
  watches with `listdir` and `stat` — libc, and therefore safe in a process
  forked without `exec` — and the fork still precedes the first Python call
  because the supervisor never makes one. A reload is a graceful shutdown
  followed by a fork: workers leave through the existing `SIGTERM` →
  drain → `exit_worker()` path, unchanged, and the exits are accounted as a
  reload rather than a retirement, so the crash-respawn budget is untouched.
  Stragglers past a 5 s drain deadline get `SIGKILL`. What reloads is the
  worker; the Mojo binary is never re-exec'd, so a changed `.mojo` still
  needs a rebuild.
- **`--reload` sets `PYTHONDONTWRITEBYTECODE=1`,** which is not a tidiness
  choice. CPython validates a cached `.pyc` against its source's mtime in
  whole **seconds** and its size, so a rewrite landing in the same second at
  the same length looks unchanged to the import system. The reloader sees it
  — it compares nanoseconds — re-forks, and the fresh worker imports the old
  bytecode: a reload that visibly happened and changed nothing. Writing no
  bytecode means there is never a cache to go stale. `smoke-reload` pins it
  by editing same-length versions in the same second, and asserts no
  `__pycache__` appears.
- **The `wrk` keep-alive tail row, and the Stage B go/no-go**
  (`docs/WSGI_PERFORMANCE.md`, `scripts/bench_wsgi_tail.sh` +
  `scripts/bench_wsgi_tail_ka.sh`). Three rounds on 3.14.7t:
  keep-alive p99 is 1.6–2.9 ms across `--workers` and `--threads` at both
  2 and 4, so the 84 ms tail does not reproduce as a property of the
  design; the single excursion in seventeen valid rows was in *prefork*.
  **Stage B is a no-go on this evidence**, and the gate is restated as a
  mixed-workload run, because a hello-route benchmark cannot exercise the
  slow-view isolation Stage B is half about. Granian 2.8.1 measured at
  1.4–2.0x either mode on the same interpreter with a byte-identical
  response — recorded as the better-evidenced target. Also recorded: the
  ephemeral-port exhaustion that made the first `wrk` table report a
  spurious 8–10x threads-vs-prefork tail gap and five empty rows, and why
  gunicorn cannot appear in a keep-alive table at all.
- **`scheme_separator`** (`lightbug_http/uri.mojo`, so also in
  [NOTICE](NOTICE)). See Fixed.
- **`MtimeScanner`** (`m0-http`): the change detector, suffix-filtered with
  the suffix supplied by the caller so `m0-http` keeps no notion of what a
  source file is. One number per pass — newest mtime *and* file count,
  because deleting the newest file leaves the maximum in the past — compared
  against the previous pass rather than a high-water mark. `__pycache__`,
  `.git`, `node_modules` and dotfiles are skipped; the first pass records
  and never reports. `waitpid_nonblocking` (`WNOHANG`) is what lets the
  supervisor poll instead of parking in `wait`.
- **`--health-path PATH`** answers `PATH` in Mojo with a liveness JSON —
  under `--realtime`, with the live `subscribers` and `sockets` counts, which
  is how the smokes assert that a vanished client was actually unsubscribed.
  Opt-in, and separate from `--realtime`, for the mirror-image reason: an
  application may already route `/health`, and a server that took the path
  silently would shadow it.

### Changed

- **The WSGI bridge is 2.35x faster: 12,289 → 28,911 rps** on
  `apps/wsgi_bare` at one worker, p50 1.21 ms → 508 µs, p99 2.47 ms →
  1.07 ms (same interpreter, two rounds). `serialize_request` cost **48 µs
  per request — 77% of the bridge's whole per-request cost**, and six times
  what the Python shim it feeds costs. Enumerating headers with `keys()` +
  `get()` allocated a String per name and per value and linear-scanned for
  each, and `cgi_header_name` allocated three more per header: ~70 String
  allocations to move twelve headers. The projection now walks `count()`
  with the header map's own spans and writes the CGI name's bytes directly,
  uppercasing and mapping `-` to `_` in place — **48.10 µs → 0.44 µs**. PEP
  3333 conformance green; `smoke-django`'s RSS guard still 0 KB over 10k
  requests.

  Recorded because the suspicion was wrong: the Python shim's environ parse
  looked like the culprit and is only 11.5 µs. `scripts/bench_bridge_parts.mojo`
  is the split that found it, and `handle()` is now five-sixths of what
  remains.
- `Headers.name_span`/`value_span` are public (were `_name_span`/
  `_value_span`), so headers can be projected into another representation
  without allocating. `keys()` is unchanged and still right for callers that
  want owned Strings. A fork change; see [NOTICE](NOTICE).

- **Stage B is justified — reversing the no-go recorded earlier in this
  release cycle.** That verdict came from a keep-alive benchmark on a hello
  route, which cannot produce the failure Stage B is half designed for, and
  it named a mixed-workload run as the gate. That run
  (`scripts/bench_mixed_workload.sh`, 3.14.7t, two rounds) is decisive: one
  slow view alongside fast traffic takes fast-request p99 from **1.6 ms to
  ~194 ms (~120x)** while p50 does not move — a subset of connections
  stopped dead, not general slowdown. `--threads` is affected identically,
  because a keep-alive connection belongs to the loop that accepted it in
  both modes. Granian's `--blocking-threads`, which *is* the Stage B
  architecture, is flat under the same load (0.96 → 1.22 ms).
- **The Granian throughput gap is the WSGI bridge, not the HTTP layer or
  the concurrency model** (`scripts/bench_layer_split.sh`). Three rows
  differing by one layer, byte-identical 13-byte response: `apps/hello`
  (zero Python) 78.3k rps at 178 µs, the same HTTP layer through the bridge
  12.4k at 1.18 ms, Granian through its own bridge 124.6k at 109 µs. The
  bridge costs ~1 ms per request because the shim rebuilds the WSGI environ
  in pure Python every time (~28 string decodes for a twelve-header
  request) — itself downstream of the `PythonObject` reference leak that
  forced the blob design. Building the environ through the raw CPython C
  API sidesteps the leak; `PyDict_New`/`PyDict_SetItem` were compile-checked
  as reachable via `Python().cpython()`.
- `apps/django_wsgi`'s `/slow` accepts `?ms=`, defaulting to the 1500 ms
  `smoke-django` expects. The mixed-workload benchmark needs a much shorter
  hold — 1.5 s swamps the signal instead of measuring it.

### Fixed

- **A bare `://` anywhere in a request target was read as a scheme**, so a
  query parameter carrying an unencoded URL (`/go?url=http://x`) was parsed
  as a URI whose scheme was `/go?url=http` and answered `400` before
  reaching the application. `URI.parse` searched the whole target for `://`;
  `scheme_separator` now accepts one only when everything before it is a
  scheme as RFC 3986 §3.1 defines it — ALPHA, then ALPHA / DIGIT / `+` /
  `-` / `.` — a character set that by construction cannot contain `/`, `?`
  or `#`. It is computed before the `ByteReader` borrows the string: a
  second interior reference taken while the reader holds one invalidates
  it. Clients that percent-encode — every browser form, every `urlencode` —
  never hit this, which is what kept it a Known issue rather than a bug
  report. `test_uri_scheme.mojo` covers both directions and `smoke-wsgi` now
  sends its `/reentrant?url=` unencoded as well as encoded, so a real server
  proves it.

### Removed

- `apps/django_realtime/server.mojo`, and with it `M0_DJANGO_PROJECT`. The
  row keeps `m0pub.py`, `djangoproj/`, `realtime_probe.py` and `static/`, and
  is served by `bin/m0serve djangoproj.wsgi:application --app-dir
  apps/django_realtime --realtime --health-path /health`. No WSGI row has a
  `server.mojo` any more.

## [0.5.0] — 2026-08-22

The release the server grew a command line and a second way to be
concurrent. `m0serve` is one built binary that serves any WSGI application,
so three example apps stopped carrying a `server.mojo` each; `--threads N`
runs N event loops on N pthreads in one process on free-threaded CPython,
at throughput parity with prefork for ~60% of its RSS.

### Added

- **`--threads N` / `M0_THREADS` — the threaded execution mode** (free-threaded
  CPython only). N event loops on N pthreads in one process, one interpreter:
  each thread runs its own `run_event_loop` with its own `WSGIHandler`, and
  so its own `WSGIApp`, bridge and shim namespace — the bridge's per-process
  singletons become per-thread without a line of the bridge changing, and
  the event loop is untouched. What it buys: one RSS instead of N, the app
  imported once, and the whole fork-after-init hazard class gone. What it
  does not: a keep-alive connection stays pinned to its loop, exactly as
  under prefork, so the keep-alive p99 shape is unchanged (the thread-pool
  stage is recorded in ROADMAP.md). `m0_wsgi.threaded` is the choreography —
  main initializes and imports before spawning and then detaches; every
  thread attaches once, serves, and releases; `DetachingBackend` wraps the
  loop's one blocking wait so a parked thread never stalls the others'
  stop-the-world; the process-wide signal pipe wakes a coordinator that
  pokes one shutdown pipe per thread. A GIL-enabled interpreter **refuses to
  start** with exit 78 and a sentence naming the requirement — never
  warns-and-runs. `--threads` and `--workers` are mutually exclusive.
  `wsgi.multithread` is finally True somewhere; every response carries
  `x-thread`. `smoke-threads` pins the guard on every runner and the mode
  itself on the free-threaded canary (phase D of `py-canary`) — green on
  **both** backends as of 2026-08-23: kqueue on macOS and epoll on Linux,
  with all four loops accepting in each, so a listener dup'd into N epoll
  instances under `EPOLLET` wakes every one of them and no `EPOLLEXCLUSIVE`
  follow-up is owed.
- **The threads-vs-prefork benchmark row** (`docs/WSGI_PERFORMANCE.md`,
  `scripts/bench_wsgi_modes.sh`): on 3.14.7t, `--threads N` is at throughput
  parity with `--workers N` (0.92–1.05x) at ~60% of its RSS, ~3.5x gunicorn
  on the same free-threaded interpreter.
- **`ThreadHandler`** (`m0-wsgi`): an `HTTPService` that constructs itself on
  a serving thread via a static `make(ctx)`. A trait rather than a function
  parameter because Mojo 1.0 cannot materialize a function-parameterized
  `def` as the runtime value a pthread needs; `WSGIHandler` implements it
  from the `ServeOptions` at `ctx.user`.
- **`m0_http.threads`** — raw pthreads from Mojo, packaged: `ThreadSet`
  (malloc'd Int64 argument blocks, `pthread_create`/`pthread_join` through
  `external_call`, a `def`'s address as the start routine), `ThreadBlock`,
  `ShutdownFanout` (one shutdown pipe per thread, poked together — the
  event loop never drains its pipe, so N loops cannot share one), `dup_fd`
  and `read_one_byte_blocking`. The idiom `scripts/py_thread_probe.mojo`
  proved, now importable under `mojo run` and tested without an interpreter
  (`test_threads.mojo`). Knows nothing about Python; that discipline belongs
  to `m0-wsgi`. The substrate for the threaded execution mode — nothing
  consumes it yet.
- **`M0_THREADS`** is read by `AppConfig` (default 1) and
  `threads_conflict(workers, threads)` answers the one message for asking
  for both execution modes at once. Mutually exclusive with `M0_WORKERS>1`.
  Read and validated ahead of the mode that will consume it, so the
  environment and `m0serve --threads` will say the same sentence.
- **`m0serve` — the uvicorn-shaped serve CLI.** One built binary
  (`poe build-serve` → `bin/m0serve`) serves any WSGI application:
  `m0serve MODULE[:ATTR] --host --port --workers --app-dir --static
  PREFIX=DIR --static-cache-control --access-log --max-body --metrics`.
  `ATTR` defaults to `application`; `--app-dir` (default `.`) is prepended to
  `sys.path`. Every `M0_*` variable keeps its meaning with the matching flag
  winning over it, and flags are strict where the environment loader is
  lenient — `--port 80eighty` is a usage error (exit 2), not a silent
  default. Startup failures exit 1 and name the thing (a missing app dir is
  caught before any interpreter starts; a module or attribute that will not
  import is reported in Python's own words). `--max-body` and `--metrics`
  are the first two server-only `ServerConfig` tunings a command line can
  reach. The entry file lives at the package root
  (`packages/m0-wsgi/m0serve.mojo`), outside `src/`, for the reasons
  `m0-core/ffi_exports.mojo` documents; the parser (`src/cli.mojo`) is pure
  and interpreter-free, tested in `test-wsgi`.
- **`WSGIHandler`** (`m0-wsgi`): the one copy of the handler three example
  apps used to carry identically, with static mounts (`List[StaticFiles]`)
  answered in Mojo ahead of the bridge.
- **`M0_HOST`**: the listen address, read by `AppConfig` and honoured by
  `address()`. An IPv4 literal, or `localhost` for `127.0.0.1`; the listener
  is IPv4-only and resolves nothing.
- `poe smoke-serve`: `--help`/`--version`, the usage and startup exit codes
  (including a supervisor that gives up under `--workers`), flag-over-env
  precedence, a static mount with its `Cache-Control`, `--max-body` → 413,
  `--metrics`, and a graceful SIGTERM.

### Changed

- The Django, Flask and bare-WSGI rows are Python-only projects served by
  `m0serve`; `serve-django`, `serve-flask`, `serve-wsgi-bare` and the three
  smokes build the CLI once and reuse it. What the rows assert is unchanged.
- `WorkerSupervisor` exits **1**, not 0, when its respawn budget runs out
  with a worker still dead — a worker that crashes on every attempt usually
  could not start at all (a bad module path), and exiting 0 reported success
  to whatever launched the server. `test_respawn.mojo` pins it.

### Removed

- `apps/django_wsgi/server.mojo`, `apps/flask_wsgi/server.mojo` and
  `apps/wsgi_bare/server.mojo`, and with them the `M0_FLASK_PROJECT` and
  `M0_WSGI_PROJECT` variables — replaced by `m0serve … --app-dir`.
  `apps/django_realtime/server.mojo` keeps its own `main()` and
  `M0_DJANGO_PROJECT` until the hold/publish machinery moves behind
  `m0serve` flags.

## [0.4.0] — 2026-08-22

The release the WSGI host grew up in. `m0-wsgi` went from a spike to a
framework-agnostic PEP 3333 server with a conformance suite, a second
framework row, and a realtime story that gives synchronous Django the SSE
and WebSocket surface people adopt ASGI for. Separately, the HTTP hot path
got substantially faster — headers alone are worth +72% throughput.

### Added

- **In-process GRIP: sync Django holds SSE streams and WebSockets.** A view
  answers an ordinary buffered response carrying `M0-Hold: stream` or
  `M0-Hold: websocket` plus `M0-Channel`, and the server takes the
  connection from there. `take_hold` (`m0-wsgi`) consumes the instruction
  headers; an SSE hold keeps the view's body as the head of the stream, and
  a WebSocket hold cannot — a handshake answers `101` with a
  `Sec-WebSocket-Accept` derived from the client's key, which a buffered,
  re-encoded WSGI response has no way to produce. So Django *approves* and
  the Mojo layer *performs* the upgrade. Inbound frames make the return trip
  as ordinary requests: `ws_message_request` gives a message the shape of a
  `POST` (payload as body, channel/slot/opcode as `M0-` headers) and a plain
  synchronous view handles it.

  Under a server that has never heard of these headers the same views
  degrade to short buffered responses — the GRIP property. The header names
  are M0-prefixed because this is GRIP-shaped, not GRIP-compatible.

- **Publishing that never enters Mojo.** The server exports its
  `BroadcastBus` write fds once, pre-fork, as `M0_BUS_WRITE_FDS`; `m0pub.py`
  (stdlib only) frames an event and `os.write`s one datagram per worker,
  including its own. No `PythonObject` crosses the bridge, so the reference
  leak rule and `smoke-django`'s RSS guard are untouched. One line in a sync
  view reaches SSE *and* WebSocket subscribers on every worker: the bus
  carries one SSE frame and delivery re-encodes per slot, so an
  `EventSource` client and a WebSocket client on the same channel see
  byte-identical messages.

- **Numbered event ids, so `Last-Event-ID` means something.** Each publish
  fetch-adds one `Int64` on the `MAP_SHARED` page the server allocates
  pre-fork, and the number goes into the bus datagram's id field and onto
  the wire as an `id:` line — which engages `SSERegistry`'s redelivery
  filter. An SSE hold seeds that filter from the request's `Last-Event-ID`.
  Python has no atomic read-modify-write over a raw address, so
  `m0_shared_fetch_add` joins m0-core's C ABI and `m0pub` calls it through
  `ctypes`. Absent `M0_CORE_LIB`/`M0_SHARED_ID_ADDR` it degrades to
  unnumbered frames — the only behaviour available under a plain WSGI host.
  Suppression, not replay: catching a client up on missed events needs a
  journal, which `DatastarStream` has and the raw registry does not.

  `apps/django_realtime` is the working demo; `poe smoke-django-realtime`
  and `poe smoke-django-realtime-ws` pin it, the latter with four held
  connections across two workers — one SSE stream and one socket each — all
  reached by ONE synchronous Django publish.

- **PEP 3333 conformance testing, framework-free.** `apps/wsgi_bare` is a
  plain WSGI callable with no third-party imports, and `poe smoke-wsgi` is
  the conformance suite over it: the `write()` callable, a second
  `start_response`, multi-chunk iterables, `close()`, arbitrary status
  passthrough, and `wsgi.input` read patterns. `smoke-django` gains a pass
  under `M0_WSGI_VALIDATE=1`, wrapping the app in `wsgiref.validate`, with a
  `/pep3333/canary` route that must fail under the wrapper so a misspelled
  variable cannot silently downgrade it to a second unvalidated run.
  Reasoning, including why repointing Django's own `tests/servers/` here was
  rejected, is in [docs/WSGI_CONFORMANCE.md](docs/WSGI_CONFORMANCE.md).

- **Flask as a second framework row.** `apps/flask_wsgi` and `poe
  smoke-flask`, with the assertions both rows share extracted into
  `scripts/wsgi_framework_contract.sh` — routing, both directions of the
  cookie path, body round trips past the shim's 64KB transfer buffer, binary
  safety, query parsing, the framework's own 404, and a raising view
  becoming a 500. A row needing assertions of its own would be evidence the
  host is not framework-agnostic after all. Adding Flask needed no change to
  `m0-wsgi`.

- **Graceful shutdown on SIGTERM/SIGINT.** The loop always knew how to drain
  — close the listener, `: close` to SSE clients, a 1001 frame to WebSocket
  clients, in-flight requests for up to 5s — and nothing could ask it to.
  `install_shutdown_signals()` returns the fd to pass as `shutdown_read_fd`.
  Mojo has no global `var` and a POSIX handler gets no user-data pointer, so
  `src/global_slot.mojo` reaches `pop.global_alloc` for what C spells
  `static`; if that ever stops working nothing is installed and the default
  disposition stands, which `shutdown_signals_active()` reports.
  `WorkerSupervisor` propagates a signal aimed at the supervisor alone to
  its children — what `docker stop` does, and what used to leave workers
  orphaned on the port. `poe smoke-shutdown` covers both paths.

- **Static files ahead of the bridge.** `StaticFiles` grew a `Cache-Control`
  policy, emitted on 200/206/304 (a validator response carries freshness
  too, per RFC 9110), and the Django rows mount it: asset requests are
  answered in Mojo with type, ETag revalidation and traversal 404s, and
  never enter Python. WhiteNoise has nothing left to do. Zero-copy
  `sendfile` remains recorded, not built — it needs event-loop support for
  fd-backed response bodies.

- **`m0-sqlite`:** the result codes callers actually branch on are exported
  (`SQLITE_CONSTRAINT`, `SQLITE_RANGE`, `SQLITE_NOMEM`, plus
  `SQLITE_OPEN_NOMUTEX`/`FULLMUTEX` so a caller assembling flags can
  reproduce the package's threading model). `sum_ints`, `min_ints`,
  `max_ints` and `stats_ints` are the SIMD pass `fetch_ints`' column-major
  layout was written for: over 200k rows, `fetch_ints + stats_ints` beats
  `SELECT sum(v), min(v), max(v)` 8.63 ms to 11.84 ms — mostly because the
  read-out runs one column fetch per row where SQLite runs three aggregate
  steps through its bytecode VM, not because of the vectorization, which is
  0.5% of that pipeline.

- **`sse_data_payload`** (`m0-http`) — the inverse of `format_sse_event`,
  returning what a browser's `EventSource` hands to `onmessage`; and
  `SSERegistry.filter_url`, the inverse of `subscribe`.

- **CI that cannot quietly rot.** A warning ratchet
  (`scripts/warning_ratchet.py`, `poe check-warnings`) holds the unique
  warning count at a committed baseline, because `mojo` has no per-warning
  suppression and warning number 69 would otherwise land among 68 residual
  ones unnoticed. `poe canary` runs the whole Mojo-nightly probe in one
  command, with the toolchain restore in an `EXIT` trap so it happens even
  when the canary fails. `poe py-canary` runs the WSGI suite against
  free-threaded CPython 3.14t and now runs weekly; `poe py-thread-probe`
  measures Mojo-spawned pthreads calling Python — 3.96x at 4 threads on
  thread-local state, and 0.71x on a shared dict, a confirmed per-object
  `PyMutex` mechanism recorded in
  [docs/WSGI_VS_ASGI.md](docs/WSGI_VS_ASGI.md).

### Performance

Each figure is against its own baseline in its own session;
[docs/SERVER_PERFORMANCE.md](docs/SERVER_PERFORMANCE.md) records a 1.7x
session-to-session swing on identical binaries, so they do not chain.

- **Headers stored as spans into a flat buffer, not a `Dict`: +72%
  throughput** — 29,000 → 50,000 req/s on `apps/hello`, p50 535 → 320 µs,
  five alternating A/B rounds. A `Dict[String, String]` cost two allocations
  per header to fill, a third to lowercase each name, and a fourth per
  lookup, because `key.lower()` builds a probe copy before it can hash. One
  blob indexed by parallel (offset, length) arrays makes a lookup a linear
  scan that compares lengths first and allocates nothing — and preserves
  insertion order, which the `Dict` never guaranteed.
- **The hot path cut to two syscalls per request: +24%** — 15.2k → 18.9k
  req/s, p50 1.03 → 0.83 ms. Persistent read-filter registration
  (`slot_read_armed`) removes an `epoll_ctl` ADD that failed `EEXIST` every
  time and the MOD it fell back to; idle timeouts move to a once-a-second
  deadline sweep instead of a per-request `timerfd_settime`; `TCP_NODELAY`
  on accepted sockets.
- **`Router.match` on spans: 2.8x on `/health`** (158 → 57 ns). Patterns
  live in one flat blob and matching walks the path by moving span
  endpoints; nothing allocates until a parameter is captured on a route that
  matched, and a 404 allocates nothing at all.
- **WebSocket unmasking and UTF-8 validation vectorized** — the 4-byte mask
  splats across 64 lanes (64 is a multiple of 4, so the pattern stays
  phase-aligned and the scalar tail needs no special case), and text
  validation skips pure-ASCII runs 64 bytes at a time while every non-ASCII
  byte still goes through the same strict decoder.
- **Startup RSS down 47–64%** — connection buffers are sized on first use
  rather than at pool construction, so a server no longer allocates for its
  configured ceiling before accepting anything. `apps/hello`: 26.5 → 14.1 MB
  at one worker, 77.7 → 28.0 MB at four.
- Log lines assemble in one buffer instead of a dozen `String`s.
- The per-slot response buffer is reused via `encode_into`, which had sat
  unused behind a comment claiming Mojo could not move out of a list-element
  field. It can, by `swap`. The honest result is 1.04x, and
  `SERVER_PERFORMANCE.md` was corrected to say so rather than leaving the
  item ranked first.

### Changed

- The Django example enables `django.contrib.sessions` on the signed-cookie
  backend, so it still needs no database. `poe smoke-django` asserts request
  cookies reach a view intact (including a value containing `=`), that split
  `Cookie` fields rejoin, that a cookieless request stays cookieless, and
  that a session counter advances across three requests.
- `AppConfig` maps to `ServerConfig` in one place instead of once per app.
- Mojo 1.0 deprecations cleared across the repo where a replacement ships:
  the memory and origin APIs, positional pointer indexing, `memcpy` →
  `unsafe_memcpy`, `deinit take:` → `deinit move:`, and
  `http/common_response.mojo` importing the names it uses instead of
  resolving them through a star-import — that pattern alone accounted for 57
  of the repository's then-143 unique warnings.
- The cross-worker smokes place one stream per worker deterministically
  (SIGSTOP the worker that won the first open, then open the second) rather
  than racing accept. Which worker wins is the kernel's choice and it is not
  a fair one: a macOS runner handed a single worker all 24 opens across six
  rounds, and opening in bursts made it worse, because the accept path
  drains the backlog until `EAGAIN` and the first worker to wake takes the
  whole burst.

### Fixed

- **Request cookies never reached a WSGI application.** The request parser
  diverted `Cookie` out of the header map into `RequestCookieJar`, and the
  WSGI environ is built by walking the header map — so `HTTP_COOKIE` was
  absent and `request.COOKIES` was always empty. Every Django session,
  login, CSRF check and message silently behaved as though the visitor had
  arrived with no cookies at all. `Cookie` now stays in `headers` as well as
  feeding the jar, and several `Cookie` fields are rejoined into one
  `"; "`-separated list (RFC 6265 §5.4) rather than collapsing to the last
  one. `Set-Cookie` on a *request* is no longer folded into the request's
  own cookies — it is a response field, and treating it as one invented a
  cookie the client never sent.

  Because a parsed request now carries its cookies in both places, `encode`
  and `write_to` write the jar only when `headers` does not already carry
  the field, so re-encoding a parsed request still emits one `Cookie`.

- **`RequestCookieJar` mis-parsed values, and its lookups did not match its
  storage.** Pairs were split on every `=` rather than the first, so any
  value containing one was truncated at the first segment — base64 pads with
  `=`, so a Django `sessionid` routinely lost its tail. Splitting also ran
  over the whole field instead of per cookie, so `a=1; b=2` parsed as one
  cookie `a` holding `1; b`. A pair with no `=` was stored under the empty
  name instead of being ignored (RFC 6265 §5.2). And `__getitem__`
  lowercased the key while stores, `__contains__` and `to_header` did not,
  so a jar holding `sessionId` answered nothing to any spelling; cookie
  names are case-sensitive (RFC 6265 §4.1.1) and are now treated that way
  throughout. The jar's own `parse_cookies` was dead code — `HTTPRequest`
  hand-rolled a separate, buggier copy — and both now share one path.

- **A request body that could not be read in one `recv` never completed.**
  The event loop registered read interest only while a connection was in
  `READING_HEADERS`; once headers parsed and the state moved to
  `READING_BODY`, nothing armed `EVFILT_READ` again. Since epoll is
  edge-triggered, body bytes already waiting in the socket buffer raised no
  further edge either, so the connection stalled until `body_read_timeout`
  answered `408`. Both the transition into `READING_BODY` and each
  incomplete body read now re-register read interest.

  This hit every request whose body did not arrive inside the first 4KB
  staging read — any POST or PUT over ~4KB, and any request at all whose
  client flushed headers before the body, regardless of size. It affected
  every app in the repo, not just the WSGI host: Django form posts, file
  uploads and JSON APIs all timed out. `poe smoke-django` now posts a 256KB
  binary body and a header-flushed-first body to `/echo` and compares the
  echo byte for byte.

- **`write()` discarded every byte.** The WSGI shim returned `lambda data:
  None`, so an application using the legacy write callable got a 200 with an
  empty body and no error anywhere. Django never calls `write()`, so nothing
  Django-shaped could have caught it — including the `wsgiref.validate`
  pass, which type-checks the call and not its effect. The iterable is now
  drained *before* the writes are joined, because an application may call
  `write()` from inside the generator it returned. Found by `apps/wsgi_bare`
  within minutes of its existing.

- **A second `start_response` without `exc_info` was silently accepted**,
  last call winning. PEP 3333 makes it an application error; it now raises.
  With `exc_info`, replacing the stored status and headers is always correct
  for a fully-buffering server, since nothing has ever been sent.

- **Keep-alive connections answered `408` to prompt requests.**
  `slot_header_start` was re-stamped in `_after_send`, so the header read
  deadline measured from the end of the *previous* response rather than the
  start of the current request: any connection idle longer than
  `header_read_timeout` got a `408` for a request the client had just sent
  promptly and completely. Measured at the boundary — a 9s gap answered 200,
  an 11s gap answered 408.

- **`m0-sqlite` answered questions it should have refused.**
  `sqlite3_column_name` returns NULL past `column_count()` and `cstr_len`
  dereferenced it, segfaulting on an out-of-range index; NULL is now guarded
  in `cstr_len`, one place for every caller. Out-of-range reads were
  indistinguishable from NULL — `column_int` answered 0, `column_text` `""`,
  and `is_null` answered True for a column that does not exist, so the one
  accessor whose job is removing that ambiguity was adding one. Every reader
  now bounds-checks, re-reading the count per call because `prepare_v2`
  silently re-prepares after a schema change and a `SELECT *` can change its
  column count mid-life.

- **`verify_layout.c` guarded shipped code and nothing ran it.** It
  re-derives with `_Static_assert` every SQLite struct offset `vtab.mojo`
  hardcodes as a flat word buffer, but sat in `experiments/`, which nothing
  builds — so the claim that "every offset used here is asserted against the
  real headers" was aspirational, guarding a failure mode (a wrong offset
  silently corrupting every row after the first) this repo has shipped once
  before. It moved into `packages/m0-sqlite/test/` and `poe test-sqlite`
  runs it first.

- **Three latent faults in the lightbug fork**, each reachable only when the
  import graph is entered from a particular direction and so invisible until
  one was: `cookie/request_cookie_jar.mojo` used `Headers` without importing
  it (it resolved through the `header` ↔ `http.parsing` cycle on the usual
  path), and `uri.mojo`'s `__str__` and `is_http` still called
  `len(String)`, which Mojo 1.0 rejects. Bodies elaborate on demand, so all
  three compiled cleanly until a consumer reached them.

### Known limits

Newly documented rather than newly true, and worth knowing before turning on
more workers:

- `urlopen` from inside a view SIGKILLs the worker on macOS under
  `M0_WORKERS>1`: `_scproxy` calls into CoreFoundation, and Objective-C
  aborts rather than run in a process forked without exec. Use
  `http.client.HTTPConnection`, which does no proxy lookup;
  `apps/wsgi_bare`'s `/reentrant` route is the worked example and `poe
  smoke-wsgi` pins it. The general rule — after `fork()` without `exec`,
  platform runtimes are off limits, from application code too — is what the
  free-threading path is expected to retire.

## [0.3.0] — 2026-08-18

- WebSocket text messages are now validated as UTF-8 (RFC 6455 §8.1) on
  the assembled message — a multi-byte character split across fragments is
  fine; an invalid sequence closes with 1007. Binary frames still carry
  any bytes.
- `StaticFiles` honours single byte ranges (RFC 9110 §14): `bytes=a-b`,
  `bytes=a-`, and `bytes=-suffix` answer `206` + `Content-Range`;
  parseable-but-past-the-end answers `416` with `bytes */total`; multiple
  ranges and other units are ignored (full `200`, as the RFC permits).
  `Accept-Ranges: bytes` is advertised; `If-Range` deliberately never
  matches (weak ETags, strong comparison required) and falls back to the
  full representation.
- `apps/hello` (and the README example) now use the non-blocking event
  loop — the blocking accept loop remains in the fork but has no in-repo
  app consumers left.
- `Client` keep-alive: response boundaries are now computed
  (`classify_response` — Content-Length, chunked terminal chunk + trailers,
  bodiless statuses, HEAD) instead of inferred from EOF, and the connection
  is kept warm and reused across requests to the same host and port. Reuse
  rules are conservative (a `Connection: close` response, an HTTP/1.0 peer,
  a close-delimited body, or stray bytes past the boundary all retire the
  connection); a reused connection that dies before yielding a single
  response byte is retried once on a fresh dial. `keep_alive=False`
  restores one-connection-per-request. `connections_opened` reports dials;
  the smoke asserts a six-request conversation (HEAD included) rides one
  connection. Breaking: `request`/`get`/`post` now take `mut self`.
- `m0_http.WSHub` — the handler-side WebSocket registry: connected slots,
  per-slot outboxes, room broadcast, and cross-worker fan-out over the
  same `BroadcastBus` SSE uses (the bus is transport-agnostic;
  `sse_peer_frame` delivers encoded WebSocket frames as readily as SSE
  events). New `apps/ws_chat` demo — one room, every message reaching
  every socket across `M0_WORKERS` — and `poe smoke-chat`, which proves a
  message sent on one worker's socket arrives on the other worker's.

## [0.2.0] — 2026-08-17

- WebSockets (RFC 6455), server side: `websocket_upgrade` answers the
  opening handshake from an ordinary handler, the event loop parses frames
  (client masking enforced, fragments assembled, ping/pong and the close
  handshake answered in the loop), and complete messages arrive at the new
  `HTTPService.ws_message` hook — the ninth trait method, empty in handlers
  that never upgrade. Outbox, heartbeat (a protocol ping on the
  `M0_SSE_HEARTBEAT_MS` cadence), and disconnect plumbing are shared with
  SSE. Protocol violations answer with the RFC's close codes (1002/1009).
  New `apps/ws_echo` demo; `poe smoke-ws` proves the wire format against a
  from-scratch stdlib client. Also fixed in passing: a stale keep-alive
  idle timer could fire mid-stream and kill an SSE connection opened on a
  reused keep-alive connection.
- `m0_http.StaticFiles` — static file serving: a directory mounted under a
  URL prefix, with lexical path-traversal defense (decoded `..`/`.`/empty
  segments answer 404), extension-based content types, and ETag/`304`
  revalidation. The notes example serves `/static/` with it.
- `HTTPService.tick(now_ms)` — the application timer hook, fired every
  `M0_APP_TICK_MS` milliseconds (0 = off, the default) on the event loop's
  timer. Server-initiated pushes no longer need an inbound request; the
  counter demo gained a live uptime clock driven by it, ticking on one
  designated worker and reaching every worker's tabs over the broadcast
  bus. Breaking for handler authors: the trait gains an eighth method
  (empty `tick` in non-scheduling handlers).

## [0.1.0] — 2026-08-17

First release. Everything below is new.

### The server (`lightbug_http`, a maintained hard fork)

- HTTP/1.1 server, Linux (`epoll`) and macOS (`kqueue`), forked from
  lightbug_http v26.1.2 after upstream was archived — see [NOTICE](NOTICE)
  and [PROVENANCE.md](PROVENANCE.md).
- Non-blocking event loop: multiplexed keep-alive connections,
  header/body/idle timeouts, graceful shutdown that drains in-flight
  requests, opt-in Prometheus-format `/__metrics`.
- Request-parsing hardening: request smuggling (CL+TE, duplicate
  `Content-Length`, `chunked` not last), header-count and size caps,
  request-target normalization, chunked-size integer overflow — each guard
  pinned by a test verified to fail without it.
- SSE as a first-class server concern: per-slot outboxes with backpressure,
  `Last-Event-ID` redelivery suppression, heartbeats on idle streams
  (`M0_SSE_HEARTBEAT_MS`) that double as dead-subscriber detection.
- Cross-worker SSE fan-out: a pre-fork `BroadcastBus` (one datagram channel
  per worker) plus `SharedAtomics` event ids make `M0_WORKERS>1` and SSE
  compose; a broadcast on any worker reaches every worker's subscribers.
- `fcntl(F_SETFL)` fixed on ARM64 macOS (Darwin passes variadic arguments
  on the stack): `set_nonblocking` now actually works there, which is what
  lets two workers race on one shared listener without the loser blocking
  inside `accept()`.
- Outbound `Client`: GET/POST/any method with full response parsing —
  Content-Length with loud truncation detection, chunked, and
  close-delimited bodies.

### The framework (`m0-http`)

- Router with `:param` captures and real `405` + `Allow`.
- Content negotiation: `Accept` (quality factors, wildcards, `*/*` resolves
  to JSON), `Accept-Encoding` (codec-agnostic, RFC 9110 `identity`/`*`/q=0
  rules), `Accept-Language` (RFC 4647 matching, serve-something-over-406).
- Weak ETags (wyhash) with `304 Not Modified`, URL-keyed response cache.
- API-key auth with constant-time comparison, CORS hooks, health/readiness
  registry, JSON-lines access logging, `M0_`-prefixed env configuration.
- Multi-worker fork supervisor with crash respawn: workers accept from one
  shared pre-fork listener; a respawned worker takes over its predecessor's
  identity (index, bus channel).

### Datastar (`m0-datastar`)

- Datastar v1.0.2 wire format with zero dependencies (`consts`, `sse`), so
  frames are usable without the framework.
- `DatastarStream`: subscriptions, five broadcast shapes, `read_signals`,
  and `Last-Event-ID` replay from a bounded frame journal — including
  across restarts when the app persists the journal (the todo example
  does, in ~15 lines of SQLite).

### WSGI (`m0-wsgi`)

- Runs Django (or any WSGI app) on this server by embedding CPython. Bodies
  cross the boundary as raw addresses (Mojo 1.0 binds no `bytes` API), and
  per-request data avoids the toolchain's `PythonObject` reference leak by
  design — an RSS guard in CI keeps it that way. Prefork via `M0_WORKERS`,
  benchmarked at ~1.6–2.2x gunicorn's throughput on the same Django app.

### SQLite (`m0-sqlite`)

- Connections, statements, typed columns, transactions, bulk read-out —
  WAL by default, busy timeouts, honest error text. A sibling package that
  imports nothing else here. Measured guidance in
  [docs/SQLITE_PERFORMANCE.md](docs/SQLITE_PERFORMANCE.md).

### C ABI (`libm0core`)

- `poe build-ffi` emits `libm0core.so`/`.dylib` (FNV-1a, xxHash32,
  wyhash64, JSON escape) for Bun `dlopen`, N-API, or `ctypes`; release
  artifacts for Linux and macOS are attached to GitHub releases.

### Examples (`apps/`)

- `hello` — the whole server in one file.
- `notes_api` — the framework showcase: negotiation, ETags, problem+json,
  CORS, validation.
- `datastar_counter` — multi-tab live sync; the reference wiring for
  cross-worker fan-out and shared-memory state.
- `datastar_todo` — the flagship: HTML-over-SSE broadcasts, SQLite
  persistence, and SSE replay across restarts.
- `django_wsgi` — a real Django project served by the WSGI host.

[1.12.1]: https://github.com/codetalcott/mojo-http/releases/tag/v1.12.1
[1.12.0]: https://github.com/codetalcott/mojo-http/releases/tag/v1.12.0
[1.11.0]: https://github.com/codetalcott/mojo-http/releases/tag/v1.11.0
[1.10.0]: https://github.com/codetalcott/mojo-http/releases/tag/v1.10.0
[1.9.0]: https://github.com/codetalcott/mojo-http/releases/tag/v1.9.0
[1.8.0]: https://github.com/codetalcott/mojo-http/releases/tag/v1.8.0
[1.7.0]: https://github.com/codetalcott/mojo-http/releases/tag/v1.7.0
[1.6.0]: https://github.com/codetalcott/mojo-http/releases/tag/v1.6.0
[1.5.0]: https://github.com/codetalcott/mojo-http/releases/tag/v1.5.0
[1.4.0]: https://github.com/codetalcott/mojo-http/releases/tag/v1.4.0
[1.3.0]: https://github.com/codetalcott/mojo-http/releases/tag/v1.3.0
[1.2.0]: https://github.com/codetalcott/mojo-http/releases/tag/v1.2.0
[1.1.0]: https://github.com/codetalcott/mojo-http/releases/tag/v1.1.0
[1.0.0]: https://github.com/codetalcott/mojo-http/releases/tag/v1.0.0
[0.19.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.19.0
[0.18.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.18.0
[0.17.1]: https://github.com/codetalcott/mojo-http/releases/tag/v0.17.1
[0.17.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.17.0
[0.16.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.16.0
[0.15.1]: https://github.com/codetalcott/mojo-http/releases/tag/v0.15.1
[0.15.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.15.0
[0.14.1]: https://github.com/codetalcott/mojo-http/releases/tag/v0.14.1
[0.14.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.14.0
[0.13.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.13.0
[0.12.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.12.0
[0.11.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.11.0
[0.10.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.10.0
[0.9.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.9.0
[0.8.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.8.0
[0.7.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.7.0
[0.6.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.6.0
[0.5.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.5.0
[0.4.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.4.0
[0.3.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.3.0
[0.2.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.2.0
[0.1.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.1.0
