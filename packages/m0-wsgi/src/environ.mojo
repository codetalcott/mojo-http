"""`HTTPRequest` → the request blob the bridge ships to Python.

The environ dict itself is built *inside* the interpreter by the bridge's
shim, because building it from Mojo would leak every entry (see
`bridge.mojo`). What lives here is the pure half: the CGI header-name
transform and the blob serializer, both testable without an interpreter.

Blob layout, all integers little-endian u32, strings raw bytes:

    method | path | query | protocol      each as  u32 len + bytes
    u32 header-count
    per header:  cgi-name, value          each as  u32 len + bytes
    u32 body-len + body bytes

`PATH_INFO` comes from `req.uri.path`, which the URI parser has already
percent-decoded — which is what PEP 3333 asks for. `QUERY_STRING` comes from
`req.uri.query_string`, which is deliberately still raw. The shim decodes
every string field as latin-1, PEP 3333's byte-tunneling convention.
"""

from lightbug_http import HTTPRequest


def cgi_header_name(header_key: String) -> String:
    """Lowercased header name → CGI variable name.

    `content-type` → `CONTENT_TYPE`, everything else gets the `HTTP_` prefix:
    `accept-encoding` → `HTTP_ACCEPT_ENCODING`. PEP 3333 requires
    Content-Type and Content-Length *without* the prefix.
    """
    var upper = header_key.upper().replace("-", "_")
    if upper == "CONTENT_TYPE" or upper == "CONTENT_LENGTH":
        return upper
    return String("HTTP_", upper)


def _append_u32(mut out: List[UInt8], value: Int):
    out.append(UInt8(value & 0xFF))
    out.append(UInt8((value >> 8) & 0xFF))
    out.append(UInt8((value >> 16) & 0xFF))
    out.append(UInt8((value >> 24) & 0xFF))


def _append_str(mut out: List[UInt8], s: String):
    _append_u32(out, s.byte_length())
    out.extend(s.as_bytes())


def serialize_request(req: HTTPRequest) raises -> List[UInt8]:
    """Serialize one request into the bridge's blob format."""
    var out = List[UInt8](capacity=256 + len(req.body_raw))

    _append_str(out, req.method)
    _append_str(out, req.uri.path)
    _append_str(out, req.uri.query_string)
    _append_str(out, req.protocol)

    var present = List[String]()
    for key in req.headers.keys():
        present.append(key)
    _append_u32(out, len(present))
    for key in present:
        var value = req.headers.get(key)
        if value:
            _append_str(out, cgi_header_name(key))
            _append_str(out, value.value())
        else:
            # keys() promised presence; keep the count honest regardless.
            _append_str(out, cgi_header_name(key))
            _append_str(out, "")

    _append_u32(out, len(req.body_raw))
    out.extend(Span(req.body_raw))

    return out^
