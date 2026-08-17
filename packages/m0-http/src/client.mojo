"""A minimal HTTP/1.1 client — the server's building blocks, pointed outward.

Everything hard was already in the fork, built once for the server side:
`create_connection` dials with real `getaddrinfo` DNS, `HTTPRequest.encode()`
serializes, `HTTPResponse.from_bytes()` parses, and `HTTPChunkedDecoder`
decodes chunked bodies. This module assembles them and owns the one
genuinely client-side concern: response framing.

**Framing: the message boundary is computed, not inferred from EOF.**
`classify_response` watches the accumulating bytes and decides where the
response ends — at `Content-Length` bytes past the headers, at the chunked
terminal chunk, immediately for bodiless statuses (1xx/204/304, HEAD), or
"only the close can end this" for the close-delimited shape HTTP/1.1 still
permits. That computed boundary is what makes **keep-alive** possible: a
connection whose response ended cleanly is kept and reused for the next
request to the same host and port.

The pool is deliberately one connection deep: this client makes one request
at a time, so one warm connection is exactly what it can use. Reuse rules
are conservative — a `Connection: close` response, an HTTP/1.0 peer, a
close-delimited body, or stray bytes past the computed boundary all retire
the connection. A reused connection that dies before yielding a single
response byte (the server idled it out between requests) is retried once on
a fresh dial; after any response byte, failures are failures — the request
may have been processed, and replaying it is not this client's call.
`keep_alive=False` restores the old behavior exactly: `Connection: close`
sent, one connection per request.

Deliberate non-goals, matching the server's constraints:

- **No TLS.** `https://` URLs are rejected loudly. Terminate at a proxy,
  exactly as the server side documents.
- **No redirect following.** A 3xx is returned to the caller undisturbed.
- **No pipelining, no concurrent pool.** One request at a time, one warm
  connection kept between them.

Usage::

    from m0_http import Client

    var client = Client()
    var resp = client.get("http://localhost:8080/health")
    # resp.status_code == 200, resp.body_raw holds the bytes
    var again = client.get("http://localhost:8080/health")
    # same TCP connection, if the server kept it open

    var created = client.post(
        "http://localhost:8080/notes",
        String('{"title":"hi"}').as_bytes(),
        content_type="application/json",
    )
    client.close()  # drop the warm connection when done (or let scope end)
"""

from lightbug_http import HTTPRequest, HTTPResponse
from lightbug_http.address import NetworkType
from lightbug_http.connection import TCPConnection, create_connection
from lightbug_http.http.chunked import HTTPChunkedDecoder
from lightbug_http.socket import EOF
from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.io.bytes import Bytes
from lightbug_http.uri import URI
from lightbug_http.utils.owning_list import OwningList


comptime DEFAULT_TIMEOUT_S = 30
comptime DEFAULT_MAX_RESPONSE = 16 * 1024 * 1024

# classify_response outcomes.
comptime FRAME_INCOMPLETE = 0
"""More bytes are needed before the boundary is known."""
comptime FRAME_COMPLETE = 1
"""The message ends at `end` bytes; anything past it is not this response."""
comptime FRAME_UNTIL_CLOSE = 2
"""No length, not chunked, body-bearing status: only the close ends it."""
comptime FRAME_ERROR = 3
"""The bytes cannot be a valid response (malformed chunked framing)."""

comptime _STALE_RETRY_MSG = "http client: reused connection yielded no response"


@fieldwise_init
struct FrameResult(Copyable, Movable):
    """Where a response ends, as far as the bytes so far can say."""

    var kind: Int
    """One of the FRAME_* constants."""
    var end: Int
    """Message length in bytes (headers included); valid when COMPLETE."""


def classify_response(raw: Span[Byte, _], method: String) -> FrameResult:
    """Incremental framing decision over the bytes received so far.

    Pure and re-runnable: call it after every read with everything
    accumulated. `method` matters because a HEAD response ends at its
    headers no matter what lengths those headers advertise.
    """
    var header_end = _find_header_end(raw)
    if header_end < 0:
        return FrameResult(FRAME_INCOMPLETE, -1)

    var status = _status_code(raw)
    if (
        method == "HEAD"
        or status == 204
        or status == 304
        or (status >= 100 and status < 200)
    ):
        return FrameResult(FRAME_COMPLETE, header_end)

    var te = _raw_header_value(raw, header_end, "transfer-encoding:")
    if te and te.value().lower() == "chunked":
        # The decoder mutates its buffer (decodes in place), so probe a copy.
        # ret >= 0 means the last-chunk marker ("0\r\n") arrived, with ret
        # bytes after it: the trailer section, which is usually just the
        # final CRLF — and the message is not over until that CRLF (or the
        # blank line ending real trailers) has arrived too.
        var probe = Bytes(raw[header_end:])
        var decoder = HTTPChunkedDecoder()
        var (ret, _) = decoder.decode(Span(probe))
        if ret == -1:
            return FrameResult(FRAME_ERROR, -1)
        if ret == -2 or ret < 2:
            return FrameResult(FRAME_INCOMPLETE, -1)
        var tail = len(raw) - ret
        if raw[tail] == 0x0D and raw[tail + 1] == 0x0A:
            return FrameResult(FRAME_COMPLETE, tail + 2)
        # Trailer fields: the message ends at their terminating blank line.
        var i = tail
        while i + 3 < len(raw):
            if (
                raw[i] == 0x0D
                and raw[i + 1] == 0x0A
                and raw[i + 2] == 0x0D
                and raw[i + 3] == 0x0A
            ):
                return FrameResult(FRAME_COMPLETE, i + 4)
            i += 1
        return FrameResult(FRAME_INCOMPLETE, -1)

    var advertised = _advertised_content_length(raw, header_end)
    if advertised >= 0:
        var total = header_end + advertised
        if len(raw) < total:
            return FrameResult(FRAME_INCOMPLETE, -1)
        return FrameResult(FRAME_COMPLETE, total)

    return FrameResult(FRAME_UNTIL_CLOSE, -1)


struct Client(Copyable, Movable):
    """One outbound HTTP/1.1 request at a time, with a warm connection kept
    between requests to the same host and port."""

    var timeout_s: Int
    """Socket receive timeout, seconds. A server that stalls longer mid-read
    fails the request; there is no separate connect timeout."""
    var max_response_bytes: Int
    """Cap on the accumulated response (headers + body). A response that
    exceeds it fails the request rather than growing without bound."""
    var keep_alive: Bool
    """Reuse the connection across requests when the response allows it.
    False restores strict one-connection-per-request (`Connection: close`)."""
    var connections_opened: Int
    """How many times this client has dialed. Diagnostic: N requests with
    this still at 1 is what connection reuse looks like from the caller."""

    # The one-deep pool: empty, or exactly one idle connection and the
    # host/port it is warm for. An OwningList because Optional demands
    # ImplicitlyCopyable and a connection owns an fd.
    var _idle: OwningList[TCPConnection[NetworkType.tcp4]]
    var _idle_host: String
    var _idle_port: UInt16

    def __init__(
        out self,
        timeout_s: Int = DEFAULT_TIMEOUT_S,
        max_response_bytes: Int = DEFAULT_MAX_RESPONSE,
        keep_alive: Bool = True,
    ):
        self.timeout_s = timeout_s
        self.max_response_bytes = max_response_bytes
        self.keep_alive = keep_alive
        self.connections_opened = 0
        self._idle = OwningList[TCPConnection[NetworkType.tcp4]](capacity=1)
        self._idle_host = String()
        self._idle_port = 0

    def __init__(out self, *, copy: Self):
        # A copy shares settings, never sockets: it starts cold.
        self.timeout_s = copy.timeout_s
        self.max_response_bytes = copy.max_response_bytes
        self.keep_alive = copy.keep_alive
        self.connections_opened = 0
        self._idle = OwningList[TCPConnection[NetworkType.tcp4]](capacity=1)
        self._idle_host = String()
        self._idle_port = 0

    def __init__(out self, *, deinit move: Self):
        self.timeout_s = move.timeout_s
        self.max_response_bytes = move.max_response_bytes
        self.keep_alive = move.keep_alive
        self.connections_opened = move.connections_opened
        self._idle = move._idle^
        self._idle_host = move._idle_host^
        self._idle_port = move._idle_port

    def close(mut self):
        """Drop the warm connection, if any. Requests still work after —
        the next one simply dials fresh."""
        self._drop_idle()

    def _drop_idle(mut self):
        while len(self._idle) > 0:
            var conn = self._idle.pop()
            try:
                conn.close()
            except:
                pass
        self._idle_host = String()
        self._idle_port = 0

    def get(mut self, url: String, *, accept: String = "") raises -> HTTPResponse:
        return self.request("GET", url, accept=accept)

    def post(
        mut self,
        url: String,
        var body: Bytes,
        *,
        content_type: String = "application/json",
    ) raises -> HTTPResponse:
        return self.request("POST", url, body^, content_type=content_type)

    def request(
        mut self,
        method: String,
        url: String,
        var body: Bytes = Bytes(),
        *,
        content_type: String = "",
        accept: String = "",
    ) raises -> HTTPResponse:
        """Send one request, return the parsed response.

        Raises on connect failure, timeout, an oversized or truncated
        response, and parse errors — a 4xx/5xx status is a *response*, not
        an error, and comes back normally.
        """
        var uri = URI.parse(url)
        if uri.scheme != "http":
            raise Error(
                "http client: only http:// URLs are supported (no TLS —"
                " terminate at a proxy, as the server side does): ",
                url,
            )
        if uri.host.byte_length() == 0:
            raise Error("http client: URL has no host: ", url)
        var port: UInt16 = 80
        if uri.port:
            port = uri.port.value()

        var headers = Headers(Header(HeaderKey.HOST, _host_header(uri)))
        if not self.keep_alive:
            headers[HeaderKey.CONNECTION] = "close"
        if content_type.byte_length() > 0:
            headers[HeaderKey.CONTENT_TYPE] = content_type
        if accept.byte_length() > 0:
            headers[HeaderKey.ACCEPT] = accept
        if len(body) > 0:
            headers[HeaderKey.CONTENT_LENGTH] = String(len(body))

        var req = HTTPRequest(uri^, headers=headers^, method=method, body=body^)
        var payload = req^.encode()
        var host = String(_strip_brackets(uri_host_for_dial(url)))

        # Reuse the warm connection when it is for this same host and port.
        if self.keep_alive and len(self._idle) > 0:
            if self._idle_host == host and self._idle_port == port:
                var warm = self._idle.pop()
                self._idle_host = String()
                self._idle_port = 0
                try:
                    return self._exchange(
                        warm^, Span(payload), method, host, port, reused=True
                    )
                except reuse_err:
                    # A reused connection that produced NOTHING was closed by
                    # the server between requests (idle timeout, keep-alive
                    # cap) — the request was not processed; dial and retry
                    # once. Any other failure is a real failure.
                    if String(reuse_err).find(_STALE_RETRY_MSG) < 0:
                        raise reuse_err^
            else:
                self._drop_idle()

        var conn = create_connection(host, port)
        self.connections_opened += 1
        try:
            conn.set_recv_timeout(self.timeout_s)
        except:
            pass  # a missing timeout must not fail the request
        return self._exchange(conn^, Span(payload), method, host, port, reused=False)

    def _exchange(
        mut self,
        var conn: TCPConnection[NetworkType.tcp4],
        payload: Span[Byte, _],
        method: String,
        host: String,
        port: UInt16,
        reused: Bool,
    ) raises -> HTTPResponse:
        """Send the encoded request, read one framed response, decide reuse."""
        var raw: Bytes
        var boundary_clean: Bool
        try:
            var written = 0
            while written < len(payload):
                var n = Int(conn.write(payload[written:]))
                if n <= 0:
                    raise Error("http client: send made no progress")
                written += n
            var msg = Bytes()
            boundary_clean = self._read_framed(conn, method, reused, msg)
            raw = msg^
        except e:
            try:
                conn.close()
            except:
                pass
            if reused and String(e).find(_STALE_RETRY_MSG) < 0 and String(e).find("send made no progress") >= 0:
                # A dead reused socket can also surface as a failed send —
                # still zero response bytes, still retryable.
                raise Error(_STALE_RETRY_MSG)
            raise e^

        var resp = _parse_response(Span(raw), method)

        var keep = self.keep_alive and boundary_clean
        if keep and resp.protocol != "HTTP/1.1":
            keep = False  # an HTTP/1.0 peer closes unless negotiated; don't bet
        if keep:
            var conn_hdr = resp.headers.get(HeaderKey.CONNECTION)
            if conn_hdr and conn_hdr.value().lower() == "close":
                keep = False
        if keep:
            self._drop_idle()
            self._idle.append(conn^)
            self._idle_host = host
            self._idle_port = port
        else:
            try:
                conn.close()
            except:
                pass
        return resp^

    def _read_framed(
        self,
        conn: TCPConnection[NetworkType.tcp4],
        method: String,
        reused: Bool,
        mut out_raw: Bytes,
    ) raises -> Bool:
        """Read exactly one response into `out_raw`, ending where the
        framing says it ends.

        Returns whether the boundary was clean — a computed end with nothing
        past it. Close-delimited responses are read to EOF and are never
        clean (the close consumed the connection).
        """
        var raw = Bytes(capacity=8192)
        var until_close = False
        while True:
            var chunk = Bytes(capacity=8192)
            var n: UInt
            try:
                n = conn.read(chunk)
            except read_err:
                if read_err.isa[EOF]():
                    if until_close and len(raw) > 0:
                        out_raw = raw^
                        return False
                    if len(raw) == 0:
                        if reused:
                            raise Error(_STALE_RETRY_MSG)
                        raise Error(
                            "http client: server closed without a response"
                        )
                    raise Error(
                        "http client: connection closed mid-response"
                    )
                raise Error(
                    "http client: connection failed before the response"
                    " completed (timeout ",
                    self.timeout_s,
                    "s): ",
                    String(read_err),
                )
            if n == 0:
                if until_close and len(raw) > 0:
                    out_raw = raw^
                    return False
                if len(raw) == 0:
                    if reused:
                        raise Error(_STALE_RETRY_MSG)
                    raise Error("http client: server closed without a response")
                raise Error("http client: connection closed mid-response")
            raw.extend(Span(chunk))
            if len(raw) > self.max_response_bytes:
                raise Error(
                    "http client: response exceeded ",
                    self.max_response_bytes,
                    " bytes",
                )
            if until_close:
                continue  # only the close ends it; keep accumulating

            var frame = classify_response(Span(raw), method)
            if frame.kind == FRAME_COMPLETE:
                if frame.end != len(raw):
                    # Bytes past the boundary belong to no request of ours
                    # (we never pipeline) — drop them with the connection.
                    out_raw = Bytes(Span(raw)[: frame.end])
                    return False
                out_raw = raw^
                return True
            if frame.kind == FRAME_ERROR:
                raise Error("http client: malformed chunked framing in response")
            if frame.kind == FRAME_UNTIL_CLOSE:
                until_close = True


def _host_header(uri: URI) -> String:
    """`Host` header value: the authority, with the port only when it is not
    the scheme default."""
    if uri.port:
        if uri.port.value() != UInt16(80):
            return String(uri.host, ":", uri.port.value())
    return uri.host


def uri_host_for_dial(url: String) raises -> String:
    """The host component to dial, re-parsed from the URL.

    Separate from `_host_header` so `request` can consume its URI into the
    outgoing request before dialing.
    """
    return URI.parse(url).host


def _strip_brackets(host: String) -> String:
    """`[::1]` → `::1`, for the resolver. No-op for ordinary hosts."""
    if host.byte_length() >= 2:
        if host.as_bytes()[0] == UInt8(ord("[")):
            return String(StringSlice(host)[byte=1 : host.byte_length() - 1])
    return host


def _find_header_end(raw: Span[UInt8, _]) -> Int:
    """Offset just past the blank line ending the header section, or -1."""
    var n = len(raw)
    for i in range(3, n):
        if (
            raw[i - 3] == 0x0D
            and raw[i - 2] == 0x0A
            and raw[i - 1] == 0x0D
            and raw[i] == 0x0A
        ):
            return i + 1
    return -1


def _status_code(raw: Span[UInt8, _]) -> Int:
    """The status code from the status line, or -1 if unparseable."""
    # "HTTP/1.1 200 OK\r\n" — the code is the digits after the first space.
    var i = 0
    var n = len(raw)
    while i < n and raw[i] != 0x20:
        if raw[i] == 0x0D:
            return -1
        i += 1
    i += 1
    var code = 0
    var digits = 0
    while i < n and raw[i] >= 0x30 and raw[i] <= 0x39:
        code = code * 10 + Int(raw[i] - 0x30)
        digits += 1
        i += 1
    if digits == 0:
        return -1
    return code


def _raw_header_value(
    raw: Span[UInt8, _], header_end: Int, name_with_colon: String
) -> Optional[String]:
    """First matching header's trimmed value, scanned from the raw bytes.

    Raw because the parsed response is not trustworthy for framing:
    `read_body` quietly takes however many bytes are present and rewrites
    lengths to match. `name_with_colon` must be lowercase, colon included.
    """
    var i = 0
    while i < header_end:
        var eol = i
        while eol + 1 < header_end and not (
            raw[eol] == 0x0D and raw[eol + 1] == 0x0A
        ):
            eol += 1
        var line = String(StringSlice(unsafe_from_utf8=raw[i:eol])).lower()
        if line.startswith(name_with_colon):
            return _trim_ascii(String(line[byte = name_with_colon.byte_length() :]))
        i = eol + 2
    return None


def _advertised_content_length(raw: Span[UInt8, _], header_end: Int) -> Int:
    """The Content-Length the raw header block claims, or -1 when absent."""
    var value = _raw_header_value(raw, header_end, "content-length:")
    if not value:
        return -1
    try:
        return Int(value.value())
    except:
        return -1


def _trim_ascii(s: String) -> String:
    var bytes = s.as_bytes()
    var start = 0
    var end = s.byte_length()
    while start < end and (bytes[start] == 0x20 or bytes[start] == 0x09):
        start += 1
    while end > start and (bytes[end - 1] == 0x20 or bytes[end - 1] == 0x09):
        end -= 1
    return String(StringSlice(s)[byte=start:end])


def _parse_response(raw: Span[UInt8, _], method: String = "GET") raises -> HTTPResponse:
    """Parse a complete raw response (exactly one message's bytes).

    A bodiless response (HEAD, 204, 304, 1xx) may still advertise the
    Content-Length its body-bearing twin would have — those advertised
    bytes are a description, not a promise, and no truncation or body
    slicing applies to them.

    `HTTPResponse.from_bytes` handles the status line, headers, cookies, and
    a Content-Length body (raising on truncation, which the framing turns
    into a loud failure instead of a silent partial body). What it does not
    cover for a *complete* buffer, this adds:

    - **chunked**: decoded via `read_chunks`; the Transfer-Encoding header
      is then dropped, because the returned body is no longer encoded.
    - **close-delimited** (no Content-Length, not chunked): everything after
      the header section is the body — legal HTTP/1.1 that `content_length()
      == 0` would otherwise turn into a silently empty body.
    """
    var resp: HTTPResponse
    try:
        resp = HTTPResponse.from_bytes(raw)
    except parse_err:
        # The typed parse error is not Writable in this fork; the raw bytes
        # a caller logs are more diagnostic than its variant name anyway.
        raise Error("http client: unparseable response")

    var status = _status_code(raw)
    if (
        method == "HEAD"
        or status == 204
        or status == 304
        or (status >= 100 and status < 200)
    ):
        resp.body_raw = Bytes()
        return resp^

    var te = resp.headers.get(HeaderKey.TRANSFER_ENCODING)
    var chunked = False
    if te:
        chunked = te.value().lower() == "chunked"

    var header_end = _find_header_end(raw)
    if not chunked and header_end >= 0:
        var advertised = _advertised_content_length(raw, header_end)
        if advertised >= 0 and len(resp.body_raw) < advertised:
            raise Error(
                "http client: truncated response: Content-Length ",
                advertised,
                " but only ",
                len(resp.body_raw),
                " body bytes arrived before the close",
            )

    if chunked or resp.headers.get(HeaderKey.CONTENT_LENGTH) is None:
        if header_end < 0:
            return resp^  # from_bytes accepted it; nothing more to slice
        var rest = raw[header_end:]
        if chunked:
            resp.body_raw = Bytes()
            resp.set_content_length(0)
            resp.read_chunks(rest)
            resp.headers.pop(HeaderKey.TRANSFER_ENCODING)
        elif len(rest) > 0:
            resp.body_raw = Bytes(rest)
            resp.set_content_length(len(rest))

    return resp^
