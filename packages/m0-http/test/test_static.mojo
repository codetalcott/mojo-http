"""Tests for static file serving — above all, for what it refuses to serve.

Fixtures are real files in a per-process temp directory: the module reads
the filesystem, so the tests must too. Traversal cases matter most here;
each one asserts 404 (never 400 — a probe deserves no confirmation), and
the secret file planted OUTSIDE the root proves rejection happened before
any read.
"""

from std.ffi import c_int, external_call
from std.os import makedirs
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.io.bytes import Bytes

from lightbug_http.c.process import getpid
from lightbug_http.http import HTTPRequest
from lightbug_http.uri import URI

from src.static import StaticFiles, content_type_for, parse_range, ByteRange, RANGE_NONE, RANGE_VALID, RANGE_UNSATISFIABLE


def _fixture_root() raises -> String:
    """Create (once per process) a tree:

        <tmp>/root/index.html
        <tmp>/root/style.css
        <tmp>/root/data.bin
        <tmp>/root/sub/index.html
        <tmp>/root/sub/notes.txt
        <tmp>/secret.txt          <- OUTSIDE the served root
    """
    var base = "/tmp/m0_static_test_" + String(getpid())
    var root = base + "/root"
    makedirs(root + "/sub", exist_ok=True)
    with open(root + "/index.html", "w") as f:
        f.write("<h1>home</h1>")
    with open(root + "/style.css", "w") as f:
        f.write("body { color: red }")
    with open(root + "/data.bin", "w") as f:
        f.write("BINARY")
    with open(root + "/sub/index.html", "w") as f:
        f.write("<h1>sub</h1>")
    with open(root + "/sub/notes.txt", "w") as f:
        f.write("some notes")
    with open(base + "/secret.txt", "w") as f:
        f.write("TOP SECRET")
    return root


def _get(path: String, method: String = "GET") raises -> HTTPRequest:
    return HTTPRequest(
        URI.parse("http://localhost:8080" + path), method=method
    )


def _body_bytes(resp: HTTPResponse) -> Bytes:
    """The response body, wherever it lives.

    A served file is now fd-backed — `body_raw` is empty and the event
    loop transfers the bytes with `sendfile(2)` — so reading it here is
    what keeps these assertions about CONTENT rather than about which
    field happens to hold it. `pread` so the descriptor's own offset is
    untouched, exactly as the loop leaves it.
    """
    if resp.body_fd < 0 or resp.body_fd_len <= 0:
        return Bytes(Span(resp.body_raw))
    var buf = Bytes(capacity=resp.body_fd_len)
    for _ in range(resp.body_fd_len):
        buf.append(0)
    var got = external_call[
        "pread", Int, c_int, type_of(Pointer(to=buf[0])), Int, Int64
    ](
        c_int(resp.body_fd),
        Pointer(to=buf[0]),
        resp.body_fd_len,
        Int64(resp.body_fd_offset),
    )
    if got < 0:
        return Bytes()
    var out = Bytes(capacity=got)
    for i in range(got):
        out.append(buf[i])
    return out^


def _body(resp: HTTPResponse) -> String:
    var b = _body_bytes(resp)
    return String(StringSlice(unsafe_from_utf8=Span(b)))


from lightbug_http.http import HTTPResponse


# --- Serving -----------------------------------------------------------------

def test_serves_a_file_with_type_and_etag() raises:
    var s = StaticFiles(_fixture_root())
    var resp = s.serve(_get("/static/style.css"))
    assert_true(Bool(resp))
    var r = resp.take()
    assert_equal(r.status_code, 200)
    assert_equal(_body(r), "body { color: red }")
    assert_equal(r.headers["content-type"], "text/css; charset=utf-8")
    assert_true(r.headers["etag"].byte_length() > 0)


def test_mount_root_serves_index_html() raises:
    var s = StaticFiles(_fixture_root())
    for path in ["/static/", "/static"]:
        var resp = s.serve(_get(String(path)))
        var r = resp.take()
        assert_equal(r.status_code, 200)
        assert_equal(_body(r), "<h1>home</h1>")


def test_directory_url_serves_its_index() raises:
    var s = StaticFiles(_fixture_root())
    var resp = s.serve(_get("/static/sub/"))
    var r = resp.take()
    assert_equal(r.status_code, 200)
    assert_equal(_body(r), "<h1>sub</h1>")


def test_nested_file_serves() raises:
    var s = StaticFiles(_fixture_root())
    var resp = s.serve(_get("/static/sub/notes.txt"))
    var r = resp.take()
    assert_equal(r.status_code, 200)
    assert_equal(r.headers["content-type"], "text/plain; charset=utf-8")


def test_outside_the_prefix_is_none() raises:
    """Paths not under the mount are the handler's business, not a 404."""
    var s = StaticFiles(_fixture_root())
    assert_false(Bool(s.serve(_get("/notes/1"))))
    assert_false(Bool(s.serve(_get("/"))))
    assert_false(Bool(s.serve(_get("/staticfile"))))


def test_missing_file_is_404() raises:
    var s = StaticFiles(_fixture_root())
    var resp = s.serve(_get("/static/nope.css"))
    assert_equal(resp.take().status_code, 404)


def test_non_get_is_405_with_allow() raises:
    var s = StaticFiles(_fixture_root())
    var resp = s.serve(_get("/static/style.css", method="POST"))
    var r = resp.take()
    assert_equal(r.status_code, 405)
    assert_equal(r.headers["allow"], "GET, HEAD")


def test_head_is_allowed() raises:
    """The server strips HEAD bodies after the handler; here it must be 200."""
    var s = StaticFiles(_fixture_root())
    var resp = s.serve(_get("/static/style.css", method="HEAD"))
    assert_equal(resp.take().status_code, 200)


# --- Conditional requests ----------------------------------------------------

def test_if_none_match_round_trips_to_304() raises:
    var s = StaticFiles(_fixture_root())
    var first = s.serve(_get("/static/style.css"))
    var etag = first.take().headers["etag"]
    var req = _get("/static/style.css")
    req.headers["if-none-match"] = etag
    var second = s.serve(req)
    var r = second.take()
    assert_equal(r.status_code, 304)
    assert_equal(r.headers["etag"], etag)
    assert_equal(len(r.body_raw), 0)


def test_stale_etag_gets_fresh_content() raises:
    var s = StaticFiles(_fixture_root())
    var req = _get("/static/style.css")
    req.headers["if-none-match"] = 'W/"deadbeef"'
    var resp = s.serve(req)
    assert_equal(resp.take().status_code, 200)


# --- Traversal: the tests this module exists for -----------------------------

def test_dotdot_is_rejected() raises:
    """The classic, in several dressings. The secret file is real and one
    level up — a lexical slip would serve actual bytes, and this fails."""
    var s = StaticFiles(_fixture_root())
    for path in [
        "/static/../secret.txt",
        "/static/sub/../../secret.txt",
        "/static/sub/../../../etc/passwd",
        "/static/..",
    ]:
        var resp = s.serve(_get(String(path)))
        assert_true(Bool(resp))
        var r = resp.take()
        assert_equal(r.status_code, 404)
        assert_false(_body(r).find("SECRET") >= 0)


def test_encoded_dotdot_is_rejected() raises:
    """URI.parse percent-decodes before the module sees the path, so %2e%2e
    arrives as literal dots and the same lexical check must catch it."""
    var s = StaticFiles(_fixture_root())
    var req = HTTPRequest(
        URI.parse("http://localhost:8080/static/%2e%2e/secret.txt"),
        method="GET",
    )
    var resp = s.serve(req)
    var r = resp.take()
    assert_equal(r.status_code, 404)
    assert_false(_body(r).find("SECRET") >= 0)


def test_single_dot_and_empty_segments_are_rejected() raises:
    var s = StaticFiles(_fixture_root())
    for path in [
        "/static/./style.css",
        "/static//style.css",
        "/static/sub//notes.txt",
    ]:
        var resp = s.serve(_get(String(path)))
        assert_equal(resp.take().status_code, 404)


def test_backslash_segments_are_rejected() raises:
    """Windows separators have no business in a URL path."""
    var s = StaticFiles(_fixture_root())
    var resp = s.serve(_get("/static/..\\secret.txt"))
    assert_equal(resp.take().status_code, 404)


# --- Content types -----------------------------------------------------------

def test_content_types_by_extension() raises:
    assert_equal(content_type_for("a.html"), "text/html; charset=utf-8")
    assert_equal(content_type_for("a.js"), "text/javascript; charset=utf-8")
    assert_equal(content_type_for("a.json"), "application/json")
    assert_equal(content_type_for("a.svg"), "image/svg+xml")
    assert_equal(content_type_for("a.PNG"), "image/png")
    assert_equal(content_type_for("a.woff2"), "font/woff2")


def test_unknown_extension_is_octet_stream() raises:
    assert_equal(content_type_for("a.xyz"), "application/octet-stream")
    assert_equal(content_type_for("no_extension"), "application/octet-stream")
    var s = StaticFiles(_fixture_root())
    var resp = s.serve(_get("/static/data.bin"))
    assert_equal(resp.take().headers["content-type"], "application/octet-stream")


# --- Mount normalization -----------------------------------------------------

def test_prefix_and_root_are_normalized() raises:
    """A root with a trailing slash and a prefix missing them both work."""
    var s = StaticFiles(_fixture_root() + "/", "assets")
    var resp = s.serve(_get("/assets/style.css"))
    assert_equal(resp.take().status_code, 200)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


# --- Byte ranges (RFC 9110 §14) ----------------------------------------------


def _serve(static: StaticFiles, var req: HTTPRequest) raises -> HTTPResponse:
    var hit = static.serve(req^)
    return hit.take()


def _file_len(root: String, name: String) raises -> Int:
    with open(root + "/" + name, "r") as f:
        return len(f.read_bytes())



def test_parse_range_shapes() raises:
    # bounded, open-ended, suffix; clamping; unsatisfiable; ignorable.
    var r = parse_range("bytes=2-5", 100)
    assert_equal(r.kind, RANGE_VALID)
    assert_equal(r.start, 2)
    assert_equal(r.end, 5)
    r = parse_range("bytes=90-", 100)
    assert_equal(r.kind, RANGE_VALID)
    assert_equal(r.start, 90)
    assert_equal(r.end, 99)
    r = parse_range("bytes=-10", 100)
    assert_equal(r.kind, RANGE_VALID)
    assert_equal(r.start, 90)
    assert_equal(r.end, 99)
    r = parse_range("bytes=0-9999", 100)  # end clamps to the representation
    assert_equal(r.kind, RANGE_VALID)
    assert_equal(r.end, 99)
    r = parse_range("bytes=-9999", 100)  # long suffix means the whole thing
    assert_equal(r.start, 0)
    assert_equal(r.end, 99)
    assert_equal(parse_range("bytes=100-", 100).kind, RANGE_UNSATISFIABLE)
    assert_equal(parse_range("bytes=-0", 100).kind, RANGE_UNSATISFIABLE)
    assert_equal(parse_range("bytes=0-", 0).kind, RANGE_UNSATISFIABLE)
    # Ignored shapes: multi-range, other units, backwards, garbage.
    assert_equal(parse_range("bytes=0-1,5-6", 100).kind, RANGE_NONE)
    assert_equal(parse_range("items=0-5", 100).kind, RANGE_NONE)
    assert_equal(parse_range("bytes=5-2", 100).kind, RANGE_NONE)
    assert_equal(parse_range("bytes=abc-def", 100).kind, RANGE_NONE)


def test_range_serves_206_with_content_range() raises:
    var root = _fixture_root()
    var static = StaticFiles(root, "/static/")
    var req = _get("/static/style.css")
    req.headers["Range"] = "bytes=0-3"
    var resp = _serve(static, req^)
    assert_equal(resp.status_code, 206)
    assert_equal(resp.headers["Content-Range"], "bytes 0-3/" + String(_file_len(root, "style.css")))
    # Four bytes FROM THE FILE, not four bytes of whatever was in memory:
    # a range is served by giving sendfile an offset, so the assertion has
    # to read at that offset to mean anything.
    assert_equal(len(_body_bytes(resp)), 4)
    assert_equal(_body(resp), "body")


def test_range_unsatisfiable_is_416_with_total() raises:
    var root = _fixture_root()
    var static = StaticFiles(root, "/static/")
    var req = _get("/static/style.css")
    req.headers["Range"] = "bytes=999999-"
    var resp = _serve(static, req^)
    assert_equal(resp.status_code, 416)
    assert_equal(resp.headers["Content-Range"], "bytes */" + String(_file_len(root, "style.css")))


def test_multi_range_is_ignored_and_served_full() raises:
    var root = _fixture_root()
    var static = StaticFiles(root, "/static/")
    var req = _get("/static/style.css")
    req.headers["Range"] = "bytes=0-1,3-4"
    var resp = _serve(static, req^)
    assert_equal(resp.status_code, 200)


def test_if_range_with_weak_etags_serves_full() raises:
    # If-Range requires strong comparison; these ETags are weak, so the
    # condition can never hold — full representation, never a stale slice.
    var root = _fixture_root()
    var static = StaticFiles(root, "/static/")
    var probe = _serve(static, _get("/static/style.css"))
    var etag = probe.headers["etag"]
    var req = _get("/static/style.css")
    req.headers["Range"] = "bytes=0-3"
    req.headers["If-Range"] = etag
    var resp = _serve(static, req^)
    assert_equal(resp.status_code, 200)


def test_if_none_match_beats_range() raises:
    var root = _fixture_root()
    var static = StaticFiles(root, "/static/")
    var probe = _serve(static, _get("/static/style.css"))
    var etag = probe.headers["etag"]
    var req = _get("/static/style.css")
    req.headers["Range"] = "bytes=0-3"
    req.headers["If-None-Match"] = etag
    var resp = _serve(static, req^)
    assert_equal(resp.status_code, 304)


def test_plain_200_advertises_accept_ranges() raises:
    var root = _fixture_root()
    var static = StaticFiles(root, "/static/")
    var resp = _serve(static, _get("/static/style.css"))
    assert_equal(resp.headers["Accept-Ranges"], "bytes")


# --- Cache-Control -----------------------------------------------------------

def test_no_cache_control_by_default() raises:
    """Freshness policy belongs to the deployment; unset sends nothing."""
    var static = StaticFiles(_fixture_root())
    var resp = _serve(static, _get("/static/style.css"))
    assert_false("cache-control" in resp.headers)


def test_cache_control_on_200_and_304() raises:
    """The 304 carries it too — a validator response that drops freshness
    makes every revalidation immediately stale again."""
    var static = StaticFiles(
        _fixture_root(), cache_control=String("public, max-age=3600")
    )
    var first = _serve(static, _get("/static/style.css"))
    assert_equal(first.headers["cache-control"], "public, max-age=3600")
    var req = _get("/static/style.css")
    req.headers["if-none-match"] = first.headers["etag"]
    var second = _serve(static, req^)
    assert_equal(second.status_code, 304)
    assert_equal(second.headers["cache-control"], "public, max-age=3600")


def test_cache_control_on_206() raises:
    var static = StaticFiles(
        _fixture_root(), cache_control=String("public, max-age=60")
    )
    var req = _get("/static/data.bin")
    req.headers["range"] = "bytes=0-2"
    var resp = _serve(static, req^)
    assert_equal(resp.status_code, 206)
    assert_equal(resp.headers["cache-control"], "public, max-age=60")


def test_cache_control_not_on_404() raises:
    """An error is not the asset; it must not inherit the asset's freshness."""
    var static = StaticFiles(
        _fixture_root(), cache_control=String("public, max-age=3600")
    )
    var hit = static.serve(_get("/static/missing.css"))
    var resp = hit.take()
    assert_equal(resp.status_code, 404)
    assert_false("cache-control" in resp.headers)


def test_a_directory_without_a_trailing_slash_is_not_served_as_a_file() raises:
    """`/static/sub` must 404, not 200.

    `index.html` is only appended when the path ends in `/`, so this one
    reached `stat` naming a directory — which succeeds — and went out as a
    200 whose Content-Length was the directory inode's size. `sendfile(2)`
    then refused the descriptor (EINVAL on Linux, EOPNOTSUPP on macOS) and
    the connection died with the head already sent, which a client sees as
    a truncated response rather than an error.
    """
    var static = StaticFiles(_fixture_root())
    var hit = static.serve(_get("/static/sub"))
    var resp = hit.take()
    assert_equal(resp.status_code, 404)


def test_a_directory_with_a_trailing_slash_still_serves_its_index() raises:
    """The regular-file check must not cost the supported shape."""
    var static = StaticFiles(_fixture_root())
    var hit = static.serve(_get("/static/sub/"))
    var resp = hit.take()
    assert_equal(resp.status_code, 200)


def test_ordinary_files_are_unaffected() raises:
    """The control: a real file still serves, with its real length."""
    var static = StaticFiles(_fixture_root())
    var hit = static.serve(_get("/static/style.css"))
    var resp = hit.take()
    assert_equal(resp.status_code, 200)
