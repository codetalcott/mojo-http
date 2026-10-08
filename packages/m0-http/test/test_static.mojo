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

from src.static import StaticFiles, content_type_for, parse_range, ByteRange, RANGE_NONE, RANGE_VALID, RANGE_UNSATISFIABLE, static_headers, svg_policy_for, SVG_SANDBOX_POLICY
from lightbug_http.header import Header, Headers


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
    with open(root + "/icon.svg", "w") as f:
        f.write('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>')
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
    return String(StringSpan(unsafe_from_utf8=Span(b)))


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


def test_missing_file_falls_through() raises:
    """A path under the prefix that names no file is the handler's to
    answer, so a mount at `/` can front an application's own routes. It
    used to be a definitive 404 here, which made a root mount swallow the
    application entirely."""
    var s = StaticFiles(_fixture_root())
    assert_false(Bool(s.serve(_get("/static/nope.css"))))


def test_non_get_on_a_miss_falls_through() raises:
    """The 405 is about a file the mount holds; a POST to a path it does
    not hold must reach the application, or a root mount would 405 every
    form on the site."""
    var s = StaticFiles(_fixture_root())
    assert_false(Bool(s.serve(_get("/static/api/submit", method="POST"))))


def _not_served(var hit: Optional[HTTPResponse]) raises:
    """Refused (404 here) or fallen through (None) — never a 200."""
    if hit:
        assert_equal(hit.take().status_code, 404)


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
    level up — a lexical slip would serve actual bytes, and this fails.

    covers: G5
    """
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
    arrives as literal dots and the same lexical check must catch it.

    covers: G6
    """
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
    # A sitemap served as octet-stream is one a crawler may refuse to parse;
    # the docs site's sitemap.xml is why this row exists.
    assert_equal(content_type_for("sitemap.xml"), "application/xml")
    assert_equal(content_type_for("a.svg"), "image/svg+xml")
    assert_equal(content_type_for("a.PNG"), "image/png")
    assert_equal(content_type_for("a.woff2"), "font/woff2")


def test_every_listed_type() raises:
    """The table, entry by entry: what a browser displays or plays opened
    directly, what a proxy compresses, what an agent reads by type. The
    rule is `content_type_for`'s docstring; a change here is a change of
    what the server tells every client.

    covers: J13
    """
    var exts = [
        "html", "htm", "css", "js", "mjs", "json", "map", "svg", "png", "jpg",
        "jpeg", "gif", "webp", "avif", "ico", "bmp", "woff2", "woff", "ttf",
        "otf", "txt", "md", "markdown", "csv", "tsv", "vtt", "ics", "xml",
        "rss", "atom", "webmanifest", "jsonld", "geojson", "yaml", "yml",
        "parquet", "mp4", "m4v", "webm", "ogv", "mov", "mp3", "m4a", "ogg",
        "oga", "opus", "wav", "flac", "aac", "pdf", "wasm", "zip", "gz",
    ]
    var types = [
        "text/html; charset=utf-8", "text/html; charset=utf-8",
        "text/css; charset=utf-8", "text/javascript; charset=utf-8",
        "text/javascript; charset=utf-8", "application/json",
        "application/json", "image/svg+xml", "image/png", "image/jpeg",
        "image/jpeg", "image/gif", "image/webp", "image/avif", "image/x-icon",
        "image/bmp", "font/woff2", "font/woff", "font/ttf", "font/otf",
        "text/plain; charset=utf-8", "text/markdown; charset=utf-8",
        "text/markdown; charset=utf-8", "text/csv; charset=utf-8",
        "text/tab-separated-values; charset=utf-8", "text/vtt; charset=utf-8",
        "text/calendar; charset=utf-8", "application/xml",
        "application/rss+xml", "application/atom+xml",
        "application/manifest+json", "application/ld+json",
        "application/geo+json", "application/yaml", "application/yaml",
        "application/vnd.apache.parquet", "video/mp4", "video/mp4",
        "video/webm", "video/ogg", "video/quicktime", "audio/mpeg",
        "audio/mp4", "audio/ogg", "audio/ogg", "audio/ogg", "audio/wav",
        "audio/flac", "audio/aac", "application/pdf", "application/wasm",
        "application/zip", "application/gzip",
    ]
    assert_equal(len(exts), len(types))
    for i in range(len(exts)):
        assert_equal(
            content_type_for("dir/file." + String(exts[i])), String(types[i]),
            "." + String(exts[i]),
        )
        # Case does not matter: a camera writes IMG_0001.JPG.
        assert_equal(
            content_type_for("FILE." + String(exts[i]).upper()), String(types[i]),
            "." + String(exts[i]).upper(),
        )


def test_build_inputs_weights_and_jsonl_stay_unlisted() raises:
    """Unlisted on purpose (`content_type_for`'s docstring): a browser cannot
    run JSX or TypeScript whatever the label says, `.ts` is also an MPEG
    transport stream to an HLS player, weights and the like are downloads,
    and JSON Lines has no registered type yet."""
    for ext in [
        "jsx", "tsx", "ts", "mts", "safetensors", "gguf", "onnx",
        "pkl", "npy", "jsonl", "ndjson",
    ]:
        assert_equal(
            content_type_for("a." + String(ext)), "application/octet-stream",
            "." + String(ext),
        )


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


def _raw(*bytes: Int) -> String:
    """A String holding exactly these bytes, valid UTF-8 or not."""
    var l = List[UInt8]()
    for b in bytes:
        l.append(UInt8(b))
    return String(unsafe_from_utf8=Span(l))


def test_a_path_that_is_not_utf8_does_not_trap() raises:
    """`serve` sliced the path past the prefix, `_safe_join` sliced each
    segment and `content_type_for` sliced the extension, all as Strings —
    a codepoint-boundary assert, so `GET /static/<0x80>x` killed the
    process. `parse_range` had the same shape on the Range header. Every
    one must get past its slices to the `stat`, which finds no such file
    and declines the request (None: the app's 404 to give), with the
    process still running to give it.

    covers: G14
    """
    var s = StaticFiles(_fixture_root())
    # Past the prefix: the slice used to start on the bad byte.
    assert_false(Bool(s.serve(_get(String("/static/") + _raw(0x80) + String("%41.css")))))
    # A whole segment of it, through `_safe_join`.
    assert_false(Bool(s.serve(_get(String("/static/") + _raw(0x80) + String("/x.css")))))
    # In the extension.
    assert_false(Bool(s.serve(_get(String("/static/x.") + _raw(0x80)))))
    assert_equal(content_type_for(String("x.") + _raw(0x80)), "application/octet-stream")
    # The Range header, sliced after `bytes=` and around the dash.
    var r = parse_range(String("bytes=") + _raw(0x80) + String("-"), 100)
    assert_equal(r.kind, RANGE_NONE)
    r = parse_range(String("bytes=0-") + _raw(0x80), 100)
    assert_equal(r.kind, RANGE_NONE)


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


def test_the_range_unit_is_bytes_in_ascii_case_only() raises:
    """`bytes=` is matched with ASCII case folding and nothing else. The
    header was lowered by Unicode `String.lower()`, which decodes an
    overlong `C1 A2` as `b`: `<C1 A2>ytes=0-1` was served as a range where
    any other hop reads an unknown unit and serves the whole (review record
    LF63).

    covers: J2
    """
    var l = List[UInt8]()
    l.append(0xC1)
    l.append(0xA2)
    l.extend("ytes=0-1".as_bytes())
    assert_equal(parse_range(String(unsafe_from_utf8=Span(l)), 100).kind, RANGE_NONE)
    var r = parse_range("BYTES=2-5", 100)
    assert_equal(r.kind, RANGE_VALID)
    assert_equal(r.start, 2)
    assert_equal(r.end, 5)
    assert_equal(parse_range("Bytes=-10", 100).start, 90)


def test_range_serves_206_with_content_range() raises:
    """Declared coverage.

    covers: J2
    """
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
    """Declared coverage.

    covers: J3
    """
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
    """Declared coverage.

    covers: J5
    """
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
    """Declared coverage.

    covers: J4
    """
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
    """An error is not the asset; it must not inherit the asset's freshness.
    A refusal is the 404 this module still answers itself (a plain miss
    falls through and has no response here to carry the header)."""
    var static = StaticFiles(
        _fixture_root(), cache_control=String("public, max-age=3600")
    )
    var hit = static.serve(_get("/static/../secret.txt"))
    var resp = hit.take()
    assert_equal(resp.status_code, 404)
    assert_false("cache-control" in resp.headers)


# --- The mount's headers -------------------------------------------------------


def _every_answer(static: StaticFiles) raises -> List[HTTPResponse]:
    """One of each response `serve` gives: 200, 304, 206, 416, 405, and a
    refusal's 404, in that order."""
    var out = List[HTTPResponse]()
    var ok = _serve(static, _get("/static/style.css"))
    var etag = ok.headers["etag"]
    out.append(ok^)
    var cond = _get("/static/style.css")
    cond.headers["if-none-match"] = etag
    out.append(_serve(static, cond^))
    var part = _get("/static/data.bin")
    part.headers["range"] = "bytes=0-2"
    out.append(_serve(static, part^))
    var past = _get("/static/data.bin")
    past.headers["range"] = "bytes=100-200"
    out.append(_serve(static, past^))
    out.append(_serve(static, _get("/static/style.css", "POST")))
    out.append(_serve(static, _get("/static/../secret.txt")))
    var want = [200, 304, 206, 416, 405, 404]
    for i in range(len(want)):
        assert_equal(out[i].status_code, want[i])
    return out^


def test_nosniff_on_every_answer() raises:
    """`X-Content-Type-Options: nosniff` on everything a mount answers, with
    nothing configured: the type always comes from the extension table, so
    nothing is left for a browser to sniff.

    covers: J12
    """
    var answers = _every_answer(StaticFiles(_fixture_root()))
    for i in range(len(answers)):
        assert_equal(
            answers[i].headers.get("x-content-type-options").or_else(""),
            "nosniff",
            "status " + String(answers[i].status_code),
        )


def test_mount_headers_on_every_answer_errors_included() raises:
    """A deployment's headers ride every answer, the 404 and the 416 as
    much as the 200 -- unlike Cache-Control, which is the asset's."""
    var static = StaticFiles(
        _fixture_root(),
        cache_control=String("public, max-age=60"),
        headers=Headers(
            Header("Referrer-Policy", "strict-origin-when-cross-origin"),
            Header("X-Frame-Options", "DENY"),
        ),
    )
    var answers = _every_answer(static)
    for i in range(len(answers)):
        var why = "status " + String(answers[i].status_code)
        assert_equal(
            answers[i].headers.get("referrer-policy").or_else(""),
            "strict-origin-when-cross-origin", why,
        )
        assert_equal(answers[i].headers.get("x-frame-options").or_else(""), "DENY", why)
        assert_equal(
            answers[i].headers.get("x-content-type-options").or_else(""), "nosniff", why
        )
    # Cache-Control is still the successes' alone.
    assert_false("cache-control" in answers[3].headers)
    assert_false("cache-control" in answers[5].headers)


def test_a_named_nosniff_replaces_the_default() raises:
    """Named by the deployment, `X-Content-Type-Options` is its value, sent
    once: `static_headers` lays the deployment's over the default."""
    var given = Headers(Header("X-Content-Type-Options", "NOSNIFF"))
    var static = StaticFiles(_fixture_root(), headers=given)
    var resp = _serve(static, _get("/static/style.css"))
    assert_equal(resp.headers["x-content-type-options"], "NOSNIFF")
    var all = static_headers(given)
    assert_equal(all.count(), 1)


def test_a_mount_header_never_replaces_the_responses_own() raises:
    """A name the response sets itself is left as the response set it, so
    the API cannot unsay a type, a validator or a range's bounds (m0serve
    refuses such a name before this; a Mojo caller is held here)."""
    var static = StaticFiles(
        _fixture_root(),
        headers=Headers(
            Header("Content-Type", "text/html"), Header("ETag", '"forged"'),
            Header("Allow", "DELETE"),
        ),
    )
    var resp = _serve(static, _get("/static/style.css"))
    assert_equal(resp.headers["content-type"], content_type_for("style.css"))
    assert_true(resp.headers["etag"] != '"forged"')
    var refused = _serve(static, _get("/static/style.css", "POST"))
    assert_equal(refused.headers["allow"], "GET, HEAD")


def _csp(resp: HTTPResponse) -> String:
    return resp.headers.get("content-security-policy").or_else("<none>")


def test_an_svg_is_answered_sandboxed() raises:
    """An SVG's 200, 304 and 206 carry `SVG_SANDBOX_POLICY`: opened directly
    or framed, its script would otherwise run as this origin. Nothing else
    does -- a stylesheet, a refusal's 404 -- since the policy is about the
    document an SVG is, not the mount.

    covers: J14
    """
    var static = StaticFiles(_fixture_root())
    assert_true(String(SVG_SANDBOX_POLICY).startswith("default-src 'none';"))
    assert_true(String(SVG_SANDBOX_POLICY).endswith("; sandbox"))
    var ok = _serve(static, _get("/static/icon.svg"))
    assert_equal(ok.status_code, 200)
    assert_equal(_csp(ok), String(SVG_SANDBOX_POLICY))
    var cond = _get("/static/icon.svg")
    cond.headers["if-none-match"] = ok.headers["etag"]
    var not_modified = _serve(static, cond^)
    assert_equal(not_modified.status_code, 304)
    assert_equal(_csp(not_modified), String(SVG_SANDBOX_POLICY))
    var part = _get("/static/icon.svg")
    part.headers["range"] = "bytes=0-3"
    var partial = _serve(static, part^)
    assert_equal(partial.status_code, 206)
    assert_equal(_csp(partial), String(SVG_SANDBOX_POLICY))
    var refused = _serve(static, _get("/static/../secret.txt"))
    assert_equal(refused.status_code, 404)
    assert_equal(_csp(refused), "<none>")
    assert_equal(_csp(_serve(static, _get("/static/style.css"))), "<none>")


def test_a_named_policy_replaces_the_svg_sandbox() raises:
    """A deployment that names its own Content-Security-Policy has it on
    every answer, an SVG's included, in place of the sandbox -- not beside
    it, which a browser would enforce as both."""
    var own = String("default-src 'self'")
    var given = Headers(Header("Content-Security-Policy", own))
    var static = StaticFiles(_fixture_root(), headers=given)
    assert_equal(_csp(_serve(static, _get("/static/icon.svg"))), own)
    assert_equal(_csp(_serve(static, _get("/static/style.css"))), own)
    assert_equal(svg_policy_for(given), own)
    assert_equal(svg_policy_for(Headers()), String(SVG_SANDBOX_POLICY))


def test_a_directory_without_a_trailing_slash_is_not_served_as_a_file() raises:
    """`/static/sub` must not be served — it falls through (None), so the
    handler behind the mount may redirect to `/static/sub/` — and above
    all must not be a 200.

    `index.html` is only appended when the path ends in `/`, so this one
    reached `stat` naming a directory — which succeeds — and went out as a
    200 whose Content-Length was the directory inode's size. `sendfile(2)`
    then refused the descriptor (EINVAL on Linux, EOPNOTSUPP on macOS) and
    the connection died with the head already sent, which a client sees as
    a truncated response rather than an error.
    """
    var static = StaticFiles(_fixture_root())
    assert_false(Bool(static.serve(_get("/static/sub"))))


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


# --- encoded slashes ---------------------------------------------------------

def test_an_encoded_slash_does_not_become_a_path_separator() raises:
    """`%2F` must not open a new segment.

    The traversal defense is lexical and per segment, so a `%2F` that
    decoded to a real `/` would hand it segments it never inspected.
    """
    var static = StaticFiles(_fixture_root())
    _not_served(static.serve(_get("/static/sub%2F..%2F..%2Fsecret.txt")))


def test_an_encoded_slash_does_not_silently_vanish() raises:
    """`%2F` used to be DELETED from the path, so `/static/sub%2Findex.html`
    became `/static/subindex.html` — a different file than the client asked
    for, and a target no component in front would agree on. It is now kept
    encoded, which matches no real file here, so it is not served."""
    var static = StaticFiles(_fixture_root())
    _not_served(static.serve(_get("/static/sub%2Findex.html")))


def test_ordinary_percent_escapes_still_decode() raises:
    """The change is scoped to the disallowed byte; everything else decodes
    as before, which is what PATH_INFO is supposed to carry."""
    var static = StaticFiles(_fixture_root())
    var hit = static.serve(_get("/static/style%2Ecss"))
    var resp = hit.take()
    assert_equal(resp.status_code, 200)
