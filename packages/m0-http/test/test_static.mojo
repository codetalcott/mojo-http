"""Tests for static file serving — above all, for what it refuses to serve.

Fixtures are real files in a per-process temp directory: the module reads
the filesystem, so the tests must too. Traversal cases matter most here;
each one asserts 404 (never 400 — a probe deserves no confirmation), and
the secret file planted OUTSIDE the root proves rejection happened before
any read.
"""

from std.os import makedirs
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.c.process import getpid
from lightbug_http.http import HTTPRequest
from lightbug_http.uri import URI

from src.static import StaticFiles, content_type_for


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


def _body(resp: HTTPResponse) -> String:
    return String(StringSlice(unsafe_from_utf8=Span(resp.body_raw)))


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
