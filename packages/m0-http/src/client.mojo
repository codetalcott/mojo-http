"""A minimal HTTP/1.1 client — the server's building blocks, pointed outward.

Everything hard was already in the fork, built once for the server side:
`create_connection` dials with real `getaddrinfo` DNS, `HTTPRequest.encode()`
serializes, `HTTPResponse.from_bytes()` parses, and `read_chunks` decodes
chunked bodies. This module assembles them and owns the one genuinely
client-side concern: response framing.

**Framing: every request is `Connection: close`.** The client sends it, then
reads to EOF — which delimits *every* body shape (Content-Length, chunked,
and close-delimited) with one loop and no speculation about whether more
bytes are coming. One TCP connection per request is the honest v1; keep-alive
reuse is a future that changes framing and is deliberately not half-done
here.

Deliberate non-goals, matching the server's constraints:

- **No TLS.** `https://` URLs are rejected loudly. Terminate at a proxy,
  exactly as the server side documents.
- **No redirect following.** A 3xx is returned to the caller undisturbed.
- **No connection pooling.**

Usage::

    from m0_http import Client

    var client = Client()
    var resp = client.get("http://localhost:8080/health")
    # resp.status_code == 200, resp.body_raw holds the bytes

    var created = client.post(
        "http://localhost:8080/notes",
        String('{"title":"hi"}').as_bytes(),
        content_type="application/json",
    )
"""

from lightbug_http import HTTPRequest, HTTPResponse
from lightbug_http.address import NetworkType
from lightbug_http.connection import TCPConnection, create_connection
from lightbug_http.socket import EOF
from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.io.bytes import Bytes
from lightbug_http.uri import URI


comptime DEFAULT_TIMEOUT_S = 30
comptime DEFAULT_MAX_RESPONSE = 16 * 1024 * 1024


struct Client(Copyable, Movable):
    """One outbound HTTP/1.1 request at a time, one connection each."""

    var timeout_s: Int
    """Socket receive timeout, seconds. A server that stalls longer mid-read
    fails the request; there is no separate connect timeout."""
    var max_response_bytes: Int
    """Cap on the accumulated response (headers + body). A response that
    exceeds it fails the request rather than growing without bound."""

    def __init__(
        out self,
        timeout_s: Int = DEFAULT_TIMEOUT_S,
        max_response_bytes: Int = DEFAULT_MAX_RESPONSE,
    ):
        self.timeout_s = timeout_s
        self.max_response_bytes = max_response_bytes

    def __init__(out self, *, copy: Self):
        self.timeout_s = copy.timeout_s
        self.max_response_bytes = copy.max_response_bytes

    def __init__(out self, *, deinit move: Self):
        self.timeout_s = move.timeout_s
        self.max_response_bytes = move.max_response_bytes

    def get(self, url: String, *, accept: String = "") raises -> HTTPResponse:
        return self.request("GET", url, accept=accept)

    def post(
        self,
        url: String,
        var body: Bytes,
        *,
        content_type: String = "application/json",
    ) raises -> HTTPResponse:
        return self.request("POST", url, body^, content_type=content_type)

    def request(
        self,
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

        var headers = Headers(
            Header(HeaderKey.HOST, _host_header(uri)),
            Header(HeaderKey.CONNECTION, "close"),
        )
        if content_type.byte_length() > 0:
            headers[HeaderKey.CONTENT_TYPE] = content_type
        if accept.byte_length() > 0:
            headers[HeaderKey.ACCEPT] = accept
        if len(body) > 0:
            headers[HeaderKey.CONTENT_LENGTH] = String(len(body))

        var req = HTTPRequest(uri^, headers=headers^, method=method, body=body^)
        var payload = req^.encode()

        var host = String(_strip_brackets(uri_host_for_dial(url)))
        var conn = create_connection(host, port)
        try:
            conn.set_recv_timeout(self.timeout_s)
        except:
            pass  # a missing timeout must not fail the request

        try:
            var written = 0
            while written < len(payload):
                var n = Int(conn.write(Span(payload)[written:]))
                if n <= 0:
                    raise Error("http client: send made no progress")
                written += n

            var raw = self._read_to_eof(conn)
            var resp = _parse_response(Span(raw))
            try:
                conn.close()
            except:
                pass
            return resp^
        except e:
            try:
                conn.close()
            except:
                pass
            raise e^

    def _read_to_eof(
        self, conn: TCPConnection[NetworkType.tcp4]
    ) raises -> Bytes:
        """Accumulate the whole response; `Connection: close` makes EOF the
        end-of-message marker for every body shape."""
        var raw = Bytes(capacity=8192)
        while True:
            var chunk = Bytes(capacity=8192)
            var n: UInt
            try:
                n = conn.read(chunk)
            except read_err:
                # The clean close that ends the message arrives as the EOF
                # variant, not as a zero-byte read.
                if read_err.isa[EOF]():
                    break
                # A timeout or reset mid-response is a failed request: with
                # close-framing there is no way to know the message ended.
                raise Error(
                    "http client: connection failed before EOF (timeout ",
                    self.timeout_s,
                    "s): ",
                    String(read_err),
                )
            if n == 0:
                break
            raw.extend(Span(chunk))
            if len(raw) > self.max_response_bytes:
                raise Error(
                    "http client: response exceeded ",
                    self.max_response_bytes,
                    " bytes",
                )
        if len(raw) == 0:
            raise Error("http client: server closed without a response")
        return raw^


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


def _advertised_content_length(raw: Span[UInt8, _], header_end: Int) -> Int:
    """The Content-Length the raw header block claims, or -1 when absent.

    Read from the raw bytes because the parsed response is not trustworthy
    here: `read_body` quietly takes however many bytes are present and
    rewrites the length to match, which would let a truncated response
    masquerade as a short-but-complete one.
    """
    var i = 0
    while i < header_end:
        # find end of this line
        var eol = i
        while eol + 1 < header_end and not (
            raw[eol] == 0x0D and raw[eol + 1] == 0x0A
        ):
            eol += 1
        var line = String(StringSlice(unsafe_from_utf8=raw[i:eol])).lower()
        if line.startswith("content-length:"):
            var value = _trim_ascii(String(line[byte=15:]))
            try:
                return Int(value)
            except:
                return -1
        i = eol + 2
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


def _parse_response(raw: Span[UInt8, _]) raises -> HTTPResponse:
    """Parse a complete raw response (headers through EOF).

    `HTTPResponse.from_bytes` handles the status line, headers, cookies, and
    a Content-Length body (raising on truncation, which close-framing turns
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
