"""Tests for the pure parts of the WSGI mapping.

Deliberately no interpreter here: `cgi_header_name`, `serialize_request`, and
`split_status` are plain byte/string transforms, and keeping them testable
without Python is why they are separate from the bridge and `build_response`.
"""

from std.testing import assert_equal, assert_true, TestSuite

from lightbug_http import HTTPRequest
from lightbug_http.uri import URI

from src.environ import cgi_header_name, serialize_request
from src.response import split_status


def _read_u32(blob: List[UInt8], off: Int) -> Tuple[Int, Int]:
    var n = (
        Int(blob[off])
        | (Int(blob[off + 1]) << 8)
        | (Int(blob[off + 2]) << 16)
        | (Int(blob[off + 3]) << 24)
    )
    return (n, off + 4)


def _read_str(blob: List[UInt8], off: Int) -> Tuple[String, Int]:
    var pair = _read_u32(blob, off)
    var n = pair[0]
    var start = pair[1]
    var out = String()
    for i in range(n):
        out += String(chr(Int(blob[start + i])))
    return (out^, start + n)


def test_cgi_header_name_prefixes_ordinary_headers() raises:
    """Ordinary headers get HTTP_ and are upper-cased with dashes to underscores."""
    assert_equal(cgi_header_name("accept-encoding"), "HTTP_ACCEPT_ENCODING")
    assert_equal(cgi_header_name("host"), "HTTP_HOST")
    assert_equal(cgi_header_name("x-forwarded-proto"), "HTTP_X_FORWARDED_PROTO")


def test_cgi_header_name_content_headers_unprefixed() raises:
    """PEP 3333: Content-Type and Content-Length carry no HTTP_ prefix."""
    assert_equal(cgi_header_name("content-type"), "CONTENT_TYPE")
    assert_equal(cgi_header_name("content-length"), "CONTENT_LENGTH")


def test_cgi_header_name_is_case_insensitive() raises:
    """`Headers` lowercases keys, but the mapping must not depend on that."""
    assert_equal(cgi_header_name("Content-Type"), "CONTENT_TYPE")
    assert_equal(cgi_header_name("USER-AGENT"), "HTTP_USER_AGENT")


# --- serialize_request -------------------------------------------------------
# The blob is the whole request's trip across the interpreter boundary; the
# shim parses it positionally, so field order and framing are contract.


def test_serialize_request_line_fields_in_order() raises:
    """method, path, query, protocol — each u32-length-prefixed, in order."""
    var req = HTTPRequest(
        URI.parse("http://localhost:8080/widgets?name=ada"), method="GET"
    )
    var blob = serialize_request(req)
    var off = 0
    var method = _read_str(blob, off)
    assert_equal(method[0], "GET")
    var path = _read_str(blob, method[1])
    assert_equal(path[0], "/widgets")
    var query = _read_str(blob, path[1])
    assert_equal(query[0], "name=ada")
    var protocol = _read_str(blob, query[1])
    assert_true(protocol[0].startswith("HTTP/"))


def test_serialize_request_headers_use_cgi_names() raises:
    """Headers cross already CGI-transformed, so the shim stays dumb."""
    var req = HTTPRequest(
        URI.parse("http://localhost:8080/"), method="GET"
    )
    req.headers["content-type"] = "text/plain"
    var blob = serialize_request(req)
    # Skip the four request-line strings, then the header count.
    var off = 0
    for _ in range(4):
        off = _read_str(blob, off)[1]
    var count_pair = _read_u32(blob, off)
    off = count_pair[1]
    var found = False
    for _ in range(count_pair[0]):
        var k = _read_str(blob, off)
        var v = _read_str(blob, k[1])
        off = v[1]
        if k[0] == "CONTENT_TYPE":
            assert_equal(v[0], "text/plain")
            found = True
    assert_true(found, "CONTENT_TYPE header did not cross")


def test_blob_header_names_match_cgi_header_name() raises:
    """The serializer and `cgi_header_name` must never disagree.

    The rule is implemented twice on purpose: `cgi_header_name` is the
    readable statement of it, and the serializer writes the same bytes
    without allocating three Strings per header to do so (see
    `_append_cgi_name`). Two implementations can drift, so this asserts
    they agree on every shape the rule distinguishes — the `HTTP_` prefix,
    the two unprefixed names, dashes, and a name that merely starts like a
    content header.
    """
    var req = HTTPRequest(URI.parse("http://localhost:8080/"), method="GET")
    # `connection` is not set here: HTTPRequest adds it itself, along with
    # `host` and `content-length`. It is listed so the count below is exact.
    var names = [
        String("connection"),
        String("host"),
        String("accept-encoding"),
        String("x-forwarded-proto"),
        String("content-type"),
        String("content-length"),
        String("content-disposition"),
        String("a"),
    ]
    for name in names:
        if name != "connection":
            req.headers[name] = "v"
    var blob = serialize_request(req)

    var off = 0
    for _ in range(4):
        off = _read_str(blob, off)[1]
    var count_pair = _read_u32(blob, off)
    off = count_pair[1]
    assert_equal(count_pair[0], len(names))

    var seen = 0
    for _ in range(count_pair[0]):
        var k = _read_str(blob, off)
        var v = _read_str(blob, k[1])
        off = v[1]
        # Whatever name this is, the blob's spelling of it must be the one
        # `cgi_header_name` would have produced.
        var matched = False
        for name in names:
            if cgi_header_name(name) == k[0]:
                matched = True
                break
        assert_true(matched, "blob name has no cgi_header_name source: " + k[0])
        seen += 1
    assert_equal(seen, len(names))

    # And the distinguishing cases specifically, so a change that made every
    # name agree by making them all wrong would still fail.
    assert_equal(cgi_header_name("content-disposition"), "HTTP_CONTENT_DISPOSITION")
    assert_equal(cgi_header_name("a"), "HTTP_A")


def test_serialize_request_body_is_last_and_binary() raises:
    """The body is the final field: u32 length + raw bytes, untouched."""
    var req = HTTPRequest(
        URI.parse("http://localhost:8080/echo"), method="POST"
    )
    req.body_raw = List[UInt8]()
    req.body_raw.append(0)
    req.body_raw.append(127)
    req.body_raw.append(255)
    var blob = serialize_request(req)
    var n = len(blob)
    assert_equal(Int(blob[n - 3]), 0)
    assert_equal(Int(blob[n - 2]), 127)
    assert_equal(Int(blob[n - 1]), 255)
    # the u32 immediately before the body says 3
    var len_pair = _read_u32(blob, n - 7)
    assert_equal(len_pair[0], 3)


def test_split_status_ordinary() raises:
    """A normal status line splits into code and reason phrase."""
    var ok = split_status("200 OK")
    assert_equal(ok[0], 200)
    assert_equal(ok[1], "OK")

    var missing = split_status("404 Not Found")
    assert_equal(missing[0], 404)
    assert_equal(missing[1], "Not Found")


def test_split_status_multiword_reason() raises:
    """The reason phrase keeps its spaces."""
    var status = split_status("500 Internal Server Error")
    assert_equal(status[0], 500)
    assert_equal(status[1], "Internal Server Error")


def test_split_status_code_only() raises:
    """A bare code is legal; the reason phrase is optional in WSGI practice."""
    var status = split_status("204")
    assert_equal(status[0], 204)
    assert_equal(status[1], "")


def test_split_status_malformed_becomes_500() raises:
    """A malformed status must not discard an already-computed body."""
    var status = split_status("banana")
    assert_equal(status[0], 500)
    assert_equal(status[1], "Internal Server Error")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
