"""A rendering kept until a clock moves, and the conditional answer to a GET.

Two pieces an application over a table composes, neither knowing what the
other's inputs are:

- `Cached` keeps one rendering and the clock value it was made at. The
  clock is any integer the application can ask cheaply and that differs
  once the data may have: `m0_sqlite`'s `Connection.data_version()` is the
  one this was written against, about a microsecond where the rendering it
  spares is milliseconds. This module imports no database; the clock
  arrives as a number.
- `conditional` answers a GET whose client already holds the bytes with a
  304. The validator is a hash of the response's own body, so it is exact
  whatever went into the body -- the cached rows, the shell around them,
  the page or the bare fragment -- and a clock that moves for a change
  elsewhere leaves it alone.

The clock decides when to look; the hash decides what to say. Deriving
the validator from the clock was measured the other way round: a clock is
database-wide, so every table's tag moved on any commit.

```mojo
def index(req: HTTPRequest, params: List[String], mut st: Store) raises -> HTTPResponse:
    var now = st.reader.data_version()
    if not st.rows.current(now):
        _ = st.rows.fill(now, render_rows(st.reader))
    return conditional(req, page_or_fragment(req, st.rows.body, Site("notes")))
```

That view writes -- it fills the cache -- so it registers with
`add_write`, on a state each thread builds for itself.
"""

from lightbug_http.header import HeaderKey
from lightbug_http.http import HTTPRequest, HTTPResponse

from m0_core.hashing import wyhash64

from .etag import compute_etag, etag_matches
from .reply import empty


struct Cached(Movable):
    """One rendering, and the clock value it was rendered at."""

    var body: String
    """The rendering; empty until the first `fill`."""
    var clock: Int
    """The clock value `body` was rendered at. Meaningless until `filled`."""
    var filled: Bool
    var fills: Int
    """How many times `fill` ran: what a test or a `/stats` reads to say a
    request was answered without rendering."""
    var _hash: UInt64

    def __init__(out self):
        self.body = String("")
        self.clock = 0
        self.filled = False
        self.fills = 0
        self._hash = 0

    def current(self, clock: Int) -> Bool:
        """Whether `body` was rendered at `clock`. Compared for equality:
        a clock is not a count, and one that went back has moved."""
        return self.filled and self.clock == clock

    def fill(mut self, clock: Int, var body: String) -> Bool:
        """Keep `body` as the rendering at `clock`. True when its bytes
        differ from the rendering it replaces -- when the data this
        renders changed, and not merely the clock -- which is what an
        application announcing changes announces."""
        var hash = wyhash64(body.as_bytes())
        var changed = (not self.filled) or hash != self._hash
        self.body = body^
        self.clock = clock
        self.filled = True
        self.fills += 1
        self._hash = hash
        return changed


def conditional(req: HTTPRequest, var resp: HTTPResponse) -> HTTPResponse:
    """`resp` with an `ETag` over its body, or a 304 in its place when the
    request's `If-None-Match` names that tag.

    Only a 200 to a GET or a HEAD is touched; anything else is returned as
    given, as is a response whose body is a file (`StaticFiles` has its
    own validator) or a stream. The tag is weak (`W/"..."`, `compute_etag`),
    and `If-None-Match` compares weakly (RFC 9110 §13.1.2): a client that
    sends the tag back without its `W/` is answered 304 too.

    `Cache-Control: no-cache` is added when the response names no policy:
    keep it, and ask before using it. That is what makes a browser send
    the tag back. A response an application marked `no-store` keeps the
    mark, and a tag nobody will send back.

    The 304 carries the `ETag`, `Cache-Control`, `Vary` and
    `Content-Location` the 200 would have (RFC 9110 §15.4.5; an `Expires`
    is not carried, `no-cache` making it moot), the 200's cookies, and no
    content.
    """
    if resp.status_code != 200 or resp.body_fd >= 0 or resp.sse_streaming:
        return resp^
    if req.method != "GET" and req.method != "HEAD":
        return resp^
    var tag = compute_etag(resp.body_raw)
    if HeaderKey.CACHE_CONTROL not in resp.headers:
        resp.headers[HeaderKey.CACHE_CONTROL] = "no-cache"
    var asked = req.headers.get(HeaderKey.IF_NONE_MATCH)
    if asked and etag_matches(tag, asked.value()):
        var not_modified = empty(304, String("Not Modified"))
        not_modified.headers[HeaderKey.ETAG] = tag
        for name in [HeaderKey.CACHE_CONTROL, HeaderKey.VARY, HeaderKey.CONTENT_LOCATION]:
            var had = resp.headers.get(name)
            if had:
                not_modified.headers[name] = had.value()
        not_modified.cookies = resp.cookies.copy()
        return not_modified^
    resp.headers[HeaderKey.ETAG] = tag
    return resp^
