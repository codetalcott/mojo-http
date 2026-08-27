"""Static file serving: a directory mounted under a URL prefix.

Composes the machinery that already exists rather than growing new kinds:
ETags come from `etag.compute_etag` (weak, wyhash) with `If-None-Match`
honoured as a `304`, content types come from a deliberately small extension
map, and requests outside the mount return `None` so the handler's own
routing continues.

The load-bearing part is what this refuses to serve. The URL path arrives
percent-DECODED (the fork's URI parser resolves `%2e` before anything here
runs), so traversal is rejected lexically, segment by segment: `..`, `.`,
empty segments (`//`), backslashes, and NUL all answer 404 — 404 and not
400, because a traversal probe deserves no confirmation that it was
understood. What this does NOT defend against is a symlink inside the root
pointing out of it: like most servers' defaults, following symlinks is the
filesystem owner's decision.

Single byte ranges are honoured (RFC 9110 §14): `bytes=a-b`, `bytes=a-`,
and `bytes=-suffix` answer `206` with a `Content-Range`; a parseable range
past the end answers `416` with `bytes */total`; everything else a Range
header can say — multiple ranges, other units, backwards bounds — is
ignored and served as the full `200`, which the RFC explicitly permits.
`If-Range` is never satisfied here: it requires strong comparison and
these ETags are weak by design, so a conditional range falls back to the
full representation rather than risking a stale slice. No directory
listings — a request for a directory serves its `index.html` or 404s,
whether or not the URL ended in `/`.

**Only regular files are served.** A directory named without a trailing
slash gets no `index.html` appended, and `stat` answers for it perfectly
well, so it used to reach the send path: a `200` went out carrying the
directory inode's size, `sendfile(2)` then refused the descriptor, and the
connection died mid-response. The `S_ISREG` check also keeps a FIFO in the
served tree from parking the loop inside `open`, and keeps device and
socket nodes out.

**A hit never reads the file.** `stat` supplies the size — which is what
Range arithmetic and `Content-Length` need — and the validator is derived
from size and mtime, so a 304 or a refusal costs one syscall and no I/O.
A served body is handed to the event loop as an open descriptor and moved
by `sendfile(2)`, so the bytes never enter this process: measured at 64 KB
of RSS growth while serving 192 MB, against ~200 MB when the same files
are buffered (`poe smoke-sendfile` pins both halves of that).

That replaced a wyhash64 over the whole file, and the trade is worth
stating plainly rather than discovering: a rewrite that preserves both
size and mtime is now a cache *hit* the content hash would have caught.
nginx and Apache make the same trade for the same reason. What did NOT
change is what the tag claims — it is still weak, so `If-Range` stays
unsatisfiable exactly as above.
"""

from std.os import stat

from lightbug_http import HTTPRequest, HTTPResponse
from lightbug_http.header import Headers, Header, HeaderKey

from .threads import dup_fd

from .etag import compute_etag, etag_matches


# The file-type bits of `st_mode`, and the one value this module serves.
# POSIX constants, spelled out because Mojo's `std.os` does not export them.
comptime _S_IFMT = 0o170000
comptime _S_IFREG = 0o100000


struct StaticFiles(Copyable, Movable):
    """Serve files from `root` at URLs under `prefix`.

    Construct once in the handler, call `serve` early in `func`:

        var static = StaticFiles("apps/notes_api/public", "/static/")
        ...
        var hit = self.static.serve(req)
        if hit:
            return hit.take()

    `serve` answers `None` only for paths outside the prefix; everything
    under the prefix gets a definitive response (200, 304, 404, or 405).
    """

    var root: String
    var prefix: String
    var cache_control: String
    """Emitted verbatim as `Cache-Control` on 200, 206, and 304 when
    non-empty. On 304 deliberately: RFC 9110 has the validator response
    carry the same freshness the full response would, and omitting it there
    makes every revalidation immediately stale again. Empty (the default)
    sends no header — freshness policy belongs to the deployment, not this
    module."""

    def __init__(
        out self,
        var root: String,
        var prefix: String = "/static/",
        *,
        var cache_control: String = "",
    ):
        # Root never ends in "/", prefix always does: the join below then
        # has exactly one shape.
        while root.byte_length() > 1 and root.endswith("/"):
            var trimmed = String(root[byte = : root.byte_length() - 1])
            root = trimmed^
        if not prefix.endswith("/"):
            prefix += "/"
        if not prefix.startswith("/"):
            prefix = "/" + prefix
        self.root = root^
        self.prefix = prefix^
        self.cache_control = cache_control^

    def __init__(out self, *, copy: Self):
        self.root = copy.root
        self.prefix = copy.prefix
        self.cache_control = copy.cache_control

    def __init__(out self, *, deinit move: Self):
        self.root = move.root^
        self.prefix = move.prefix^
        self.cache_control = move.cache_control^

    def _with_cache_control(self, var resp: HTTPResponse) -> HTTPResponse:
        if self.cache_control.byte_length() > 0:
            resp.headers[HeaderKey.CACHE_CONTROL] = self.cache_control
        return resp^

    def matches(self, path: String) -> Bool:
        """Whether `path` is under this mount (serve() would not answer None)."""
        return path.startswith(self.prefix) or path == String(self.prefix[byte = : self.prefix.byte_length() - 1])

    def serve(self, req: HTTPRequest) raises -> Optional[HTTPResponse]:
        """Serve `req` if it targets this mount; `None` if it does not."""
        var path = req.uri.path
        # "/static" (no slash) means the mount root, same as "/static/".
        if path == String(self.prefix[byte = : self.prefix.byte_length() - 1]):
            path = self.prefix
        if not path.startswith(self.prefix):
            return None

        if req.method != "GET" and req.method != "HEAD":
            var resp = HTTPResponse(
                body_bytes=String('{"error":"method not allowed"}').as_bytes(),
                headers=Headers(
                    Header(HeaderKey.CONTENT_TYPE, "application/json"),
                    Header("Allow", "GET, HEAD"),
                ),
                status_code=405,
                status_text="Method Not Allowed",
            )
            return resp^

        var rel = String(path[byte = self.prefix.byte_length() :])
        if rel.byte_length() == 0 or rel.endswith("/"):
            rel += "index.html"

        var fs_path = _safe_join(self.root, rel)
        if not fs_path:
            return _not_found()

        # `stat` rather than a read: the size is what Range arithmetic and
        # Content-Length need, and the validator is derived from it, so a
        # cache hit or a refusal never touches the file's bytes at all.
        var total: Int
        var etag: String
        try:
            var st = stat(fs_path.value())
            # Regular files only. Without this a request for a subdirectory
            # WITHOUT a trailing slash — which never gets `index.html`
            # appended, and which `stat` answers happily — was served as
            # though it were a file: a 200 head went out carrying the
            # directory inode's size as Content-Length, and then
            # `sendfile(2)` refused it (EINVAL on Linux, EOPNOTSUPP on
            # macOS) and the connection died mid-response. The same check
            # keeps a FIFO in the served tree from blocking the loop or a
            # pool thread inside `open`, which has no O_NONBLOCK here, and
            # keeps device and socket nodes out.
            #
            # 404 rather than a redirect to `<path>/`: this module answers
            # a directory request with its `index.html` or nothing, and a
            # redirect would be a new promise about URL shape. Symlinks are
            # still followed (`stat`, not `lstat`) — the module docstring
            # says so, and it stays the filesystem owner's decision.
            if (Int(st.st_mode) & _S_IFMT) != _S_IFREG:
                return _not_found()
            total = Int(st.st_size)
            etag = stat_etag(
                total,
                Int(st.st_mtimespec.tv_sec) * 1_000_000_000
                + Int(st.st_mtimespec.tv_subsec),
            )
        except:
            return _not_found()

        var inm = req.headers.get(HeaderKey.IF_NONE_MATCH)
        if inm:
            if etag_matches(etag, inm.value()):
                var not_modified = HTTPResponse(
                    body_bytes=String("").as_bytes(),
                    headers=Headers(Header(HeaderKey.ETAG, etag)),
                    status_code=304,
                    status_text="Not Modified",
                )
                return self._with_cache_control(not_modified^)

        # A single satisfiable byte range is sent from an offset rather
        # than sliced; If-Range never matches (strong comparison, weak
        # ETags), so a conditional range falls back to the full
        # representation. GET only: a ranged HEAD would advertise a length
        # no GET here ever sends for that request.
        var range_hdr = req.headers.get("range")
        if range_hdr and req.method == "GET" and not req.headers.get("if-range"):
            var r = parse_range(range_hdr.value(), total)
            if r.kind == RANGE_UNSATISFIABLE:
                var unsat = HTTPResponse(
                    body_bytes=String("").as_bytes(),
                    headers=Headers(
                        Header("Content-Range", "bytes */" + String(total)),
                        Header(HeaderKey.ETAG, etag),
                    ),
                    status_code=416,
                    status_text="Range Not Satisfiable",
                )
                return unsat^
            if r.kind == RANGE_VALID:
                var part_fd = _open_read(fs_path.value())
                if part_fd < 0:
                    return _not_found()
                var partial = HTTPResponse(
                    body_bytes=String("").as_bytes(),
                    headers=Headers(
                        Header(HeaderKey.CONTENT_TYPE, content_type_for(rel)),
                        Header(HeaderKey.ETAG, etag),
                        Header("Accept-Ranges", "bytes"),
                        Header(
                            "Content-Range",
                            "bytes " + String(r.start) + "-" + String(r.end)
                            + "/" + String(total),
                        ),
                    ),
                    status_code=206,
                    status_text="Partial Content",
                )
                # sendfile takes an offset, so a range is the same transfer
                # as a whole file with different bounds — no slicing, and
                # nothing proportional to the range is ever allocated.
                partial.set_file_body(part_fd, r.start, r.end - r.start + 1)
                return self._with_cache_control(partial^)

        # Opened LAST, after every refusal above has already returned:
        # from here the descriptor belongs to the response, and a path
        # that built one and then bailed would leak it.
        var fd = _open_read(fs_path.value())
        if fd < 0:
            return _not_found()
        var resp = HTTPResponse(
            body_bytes=String("").as_bytes(),
            headers=Headers(
                Header(HeaderKey.CONTENT_TYPE, content_type_for(rel)),
                Header(HeaderKey.ETAG, etag),
                Header("Accept-Ranges", "bytes"),
            ),
            status_code=200,
            status_text="OK",
        )
        resp.set_file_body(fd, 0, total)
        return self._with_cache_control(resp^)


def _open_read(path: String) -> Int:
    """A raw read-only descriptor for `path`, or -1.

    `sendfile(2)` wants a descriptor, but Mojo's `open` hands back a
    `FileHandle` that closes itself at end of scope — exactly wrong here,
    since the response outlives this function and the event loop is what
    eventually closes the file. So: open normally, `dup(2)` the
    descriptor, and let the handle close its own copy. The dup survives
    on the same open file description, offset included.

    Binding `open(2)` directly was tried first and does not work: it is
    variadic, the stdlib already declares it with a different signature,
    and the two collide at link time ("failed to legalize operation
    'pop.external_call'"). `dup` has no such problem.
    """
    try:
        with open(path, "r") as f:
            return dup_fd(Int(f._get_raw_fd()))
    except:
        return -1


def stat_etag(size: Int, mtime_ns: Int) -> String:
    """A validator from `stat` alone: `W/"<size>-<mtime_ns>"`.

    Hashing the contents would be a stronger validator, and it is what
    this module used to do — but it required reading every byte of every
    hit, which is the cost `sendfile` exists to remove. nginx and Apache
    both derive static validators from size and mtime for the same reason.

    Still WEAK, and deliberately so. Two representations can share a size
    and an mtime truncated to whatever the filesystem records, so this
    cannot promise the byte-for-byte identity a strong validator asserts.
    That keeps `If-Range` unsatisfiable here exactly as before — a
    conditional range still falls back to the full representation — so the
    change is confined to how the tag is computed, not to what it claims.

    The nanosecond field is used where the filesystem provides it, which
    narrows but does not close the same-second rewrite window.
    """
    return String('W/"') + String(size) + "-" + String(mtime_ns) + '"'


comptime RANGE_NONE = 0
"""No usable range: absent, malformed, multi-range, or a non-bytes unit —
serve the full representation (RFC 9110 lets a server ignore Range)."""
comptime RANGE_VALID = 1
"""A satisfiable single range, clamped to the representation."""
comptime RANGE_UNSATISFIABLE = 2
"""Parseable but past the end — answer 416 with `bytes */total`."""


@fieldwise_init
struct ByteRange(Copyable, Movable):
    """One parsed byte range; `start`/`end` are inclusive, valid when kind
    is RANGE_VALID."""

    var kind: Int
    var start: Int
    var end: Int


def parse_range(header: String, total: Int) -> ByteRange:
    """Parse a Range header against a representation of `total` bytes.

    Deliberately answers RANGE_NONE for anything this server chooses not
    to satisfy (multiple ranges, non-bytes units, backwards bounds) — the
    caller serves the full 200, which is always a correct answer to Range.
    """
    var h = header.lower()
    if not h.startswith("bytes="):
        return ByteRange(RANGE_NONE, 0, 0)
    var spec = String(h[byte=6:])
    # One dash, no commas — found by byte scan ("-" at index 0 is a valid
    # suffix range, which index-as-truthiness would silently drop).
    var dash_idx = -1
    var sb = spec.as_bytes()
    for i in range(spec.byte_length()):
        if Int(sb[i]) == ord(","):
            return ByteRange(RANGE_NONE, 0, 0)
        if Int(sb[i]) == ord("-") and dash_idx < 0:
            dash_idx = i
    if dash_idx < 0:
        return ByteRange(RANGE_NONE, 0, 0)
    var lo = String(spec[byte = : dash_idx])
    var hi = String(spec[byte = dash_idx + 1 :])

    if lo.byte_length() == 0:
        # Suffix: the LAST `hi` bytes.
        var suffix: Int
        try:
            suffix = Int(hi)
        except:
            return ByteRange(RANGE_NONE, 0, 0)
        if suffix <= 0 or total == 0:
            return ByteRange(RANGE_UNSATISFIABLE, 0, 0)
        if suffix >= total:
            return ByteRange(RANGE_VALID, 0, total - 1)
        return ByteRange(RANGE_VALID, total - suffix, total - 1)

    var start: Int
    try:
        start = Int(lo)
    except:
        return ByteRange(RANGE_NONE, 0, 0)
    if start < 0:
        return ByteRange(RANGE_NONE, 0, 0)
    if start >= total:
        return ByteRange(RANGE_UNSATISFIABLE, 0, 0)

    if hi.byte_length() == 0:
        return ByteRange(RANGE_VALID, start, total - 1)
    var end: Int
    try:
        end = Int(hi)
    except:
        return ByteRange(RANGE_NONE, 0, 0)
    if end < start:
        return ByteRange(RANGE_NONE, 0, 0)
    if end >= total:
        end = total - 1
    return ByteRange(RANGE_VALID, start, end)


def _safe_join(root: String, rel: String) -> Optional[String]:
    """`root`/`rel`, or None when any segment smells like traversal.

    Lexical, not filesystem-based: a segment that IS `..` or `.`, an empty
    segment (from `//`), a backslash (Windows separators have no business in
    a URL path), or a NUL each disqualify the whole path. The result stays
    under `root` by construction, so no realpath round-trip is needed.
    """
    var joined = root
    var start = 0
    var bytes = rel.as_bytes()
    var n = rel.byte_length()
    for i in range(n + 1):
        var at_sep = i == n or Int(bytes[i]) == ord("/")
        if not at_sep:
            if Int(bytes[i]) == 0 or Int(bytes[i]) == ord("\\"):
                return None
            continue
        var seg = String(rel[byte = start:i])
        start = i + 1
        if seg.byte_length() == 0 or seg == "." or seg == "..":
            return None
        joined += "/" + seg
    return joined


def content_type_for(name: String) -> String:
    """Content type by file extension; unknown answers octet-stream.

    Deliberately small: the standard web types plus what this repo's own
    examples serve. Vendor types stay the caller's business, exactly as in
    content negotiation.
    """
    var dot = name.rfind(".")
    if not dot:
        return "application/octet-stream"
    var ext = String(name[byte = dot.value() + 1 :]).lower()
    if ext == "html" or ext == "htm":
        return "text/html; charset=utf-8"
    if ext == "css":
        return "text/css; charset=utf-8"
    if ext == "js" or ext == "mjs":
        return "text/javascript; charset=utf-8"
    if ext == "json":
        return "application/json"
    if ext == "svg":
        return "image/svg+xml"
    if ext == "png":
        return "image/png"
    if ext == "jpg" or ext == "jpeg":
        return "image/jpeg"
    if ext == "gif":
        return "image/gif"
    if ext == "webp":
        return "image/webp"
    if ext == "ico":
        return "image/x-icon"
    if ext == "txt" or ext == "md":
        return "text/plain; charset=utf-8"
    if ext == "wasm":
        return "application/wasm"
    if ext == "woff2":
        return "font/woff2"
    if ext == "pdf":
        return "application/pdf"
    return "application/octet-stream"


def _not_found() -> HTTPResponse:
    return HTTPResponse(
        body_bytes=String('{"error":"not found"}').as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=404,
        status_text="Not Found",
    )
