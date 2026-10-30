"""Whether a WebSocket handshake's `Origin` may open a held socket.

Under `--realtime` a plain view approves an upgrade with `M0-Hold:
websocket` and m0serve performs it (`WSGIHandler`'s hold branch). That view
is a synchronous one in a framework with no WebSocket in it, so nothing
between the browser and the socket asked where the page that opened it
came from. A page on any origin can open a WebSocket, and the browser
attaches the site's cookies: WebSockets are outside the same-origin policy
that keeps that page from reading a `fetch` (cross-site WebSocket
hijacking). Since 1.17.0 the server asks, as gorilla/websocket and Phoenix
do by default (SPEC I48):

- No `Origin`: allowed. Every browser sends one on an upgrade, so a
  handshake without one is a client with no cookie jar to be tricked with.
- An `Origin` naming the request's own `Host`, or the first
  `X-Forwarded-Host` a proxy set: allowed, the same origin. A page's script
  cannot put a header on a handshake, so neither can be forged by the page
  this guards against.
- An `Origin` the operator named with `--ws-origin` (or `M0_WS_ORIGIN`):
  allowed. `*` allows every origin, the behaviour before 1.17.0.
- Anything else, `null` included unless named: refused with 403.

Case is folded in ASCII only. Unicode `lower()` reads KELVIN SIGN (U+212A)
as `k` (review record LF63), and here a fold that matched what the browser
did not send would be a way past the check. An ASGI application is not
asked: it sees the handshake and accepts it itself, as under uvicorn, and
its framework's origin check is the one that applies.
"""


def _ascii_lower(s: String) -> String:
    """`s` with A-Z folded to a-z and every other byte kept."""
    var out = List[UInt8](capacity=s.byte_length())
    for b in s.as_bytes():
        if b >= UInt8(ord("A")) and b <= UInt8(ord("Z")):
            out.append(b + 32)
        else:
            out.append(b)
    return String(unsafe_from_utf8=Span(out))


def _without_default_port(authority: String, https: Bool) -> String:
    """`authority` without `:443` (https) or `:80` (http) at its end: a
    browser leaves a default port out of `Origin`, and a client may put it
    in `Host`."""
    var port = String(":443") if https else String(":80")
    var n = authority.byte_length()
    var p = port.byte_length()
    if n > p and authority.endswith(port):
        return String(unsafe_from_utf8=authority.as_bytes()[: n - p])
    return authority


def _split_origin(lowered: String) -> Tuple[Bool, Bool, String]:
    """`(ok, https, authority)` of an ASCII-lowered `scheme://authority`
    origin, the authority without its default port. Not ok for any other
    scheme, an empty authority, or one carrying a path, query or fragment."""
    var https = lowered.startswith("https://")
    var http = lowered.startswith("http://")
    if not https and not http:
        return (False, False, String(""))
    var skip = 8 if https else 7
    var rest = String(unsafe_from_utf8=lowered.as_bytes()[skip:])
    if rest.byte_length() == 0:
        return (False, https, String(""))
    for b in rest.as_bytes():
        if b == UInt8(ord("/")) or b == UInt8(ord("?")) or b == UInt8(ord("#")):
            return (False, https, String(""))
    return (True, https, _without_default_port(rest, https))


def normalize_ws_origin(value: String) raises -> String:
    """A `--ws-origin` value as the check compares it, or an error saying
    what it should look like.

    `*` and `null` are kept. An origin is `http://` or `https://` and a
    host with an optional port, as a browser sends it: folded to lower
    case, one trailing `/` dropped, a default port dropped.
    """
    var v = String(value.strip())
    if v == "*":
        return v
    var lowered = _ascii_lower(v)
    if lowered == "null":
        return lowered
    if lowered.endswith("/"):
        var trimmed = String(
            unsafe_from_utf8=lowered.as_bytes()[: lowered.byte_length() - 1]
        )
        lowered = trimmed^
    var parts = _split_origin(lowered)
    if not parts[0]:
        raise Error(
            "--ws-origin expects an origin like https://example.com (a"
            " scheme, a host and an optional port, no path), 'null' or '*',"
            " got '" + value + "'"
        )
    return (String("https://") if parts[1] else String("http://")) + parts[2]


def ws_origin_allowed(
    origin: String,
    host: String,
    forwarded_host: String,
    allowed: List[String],
) -> Bool:
    """Whether a handshake carrying `origin` (empty: none was sent) may be
    upgraded, the request naming `host` in `Host` and `forwarded_host` in
    `X-Forwarded-Host` (empty: none). `allowed` holds the operator's
    origins, each through `normalize_ws_origin`. The rules are the
    module docstring's."""
    if origin.byte_length() == 0:
        return True
    var lowered = _ascii_lower(String(origin.strip()))
    var parts = _split_origin(lowered)
    var normal = lowered
    if parts[0]:
        normal = (String("https://") if parts[1] else String("http://")) + parts[2]
    for i in range(len(allowed)):
        if allowed[i] == "*" or allowed[i] == normal:
            return True
    if not parts[0]:
        return False
    if host.byte_length() > 0:
        if _without_default_port(_ascii_lower(String(host.strip())), parts[1]) == parts[2]:
            return True
    if forwarded_host.byte_length() > 0:
        # A proxy that appends gives the client-facing host first.
        var first = forwarded_host
        var comma = forwarded_host.find(",")
        if comma >= 0:
            first = String(unsafe_from_utf8=forwarded_host.as_bytes()[:comma])
        if _without_default_port(_ascii_lower(String(first.strip())), parts[1]) == parts[2]:
            return True
    return False
