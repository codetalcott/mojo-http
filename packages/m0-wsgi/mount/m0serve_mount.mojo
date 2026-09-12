"""The Mojo mount `m0serve` builds in: `--mount PREFIX=mojo`.

**This is the file a user replaces.** A Mojo handler is a compile-time
type, not an importable object, so no command line can name one against a
prebuilt binary. `m0serve.mojo` imports `MojoMount` from a module called
`m0serve_mount`, and the build's `-I` roots decide which file that is:
`poe build-serve` puts `packages/m0-wsgi/mount/` on the path, so the demo
below is what ships, and an application builds its own binary with its
own directory FIRST on the path, holding its own `m0serve_mount.mojo`.
The entry file is never copied, so it cannot drift from the release the
application builds against.

The contract is one name: `struct MojoMount(PoolHandler)`. It is built on
each pool thread by `make(ctx)`, answers `func`, and is told `shutdown`.
Everything else in this module is the demo's own business.
"""

from lightbug_http import PoolContext, PoolHandler, HTTPRequest, HTTPResponse
from lightbug_http.header import Header, Headers
from m0_http import Html, Mount, Views, reply
from std.memory.alloc import unsafe_alloc


comptime CORPUS_ROWS = 4096
comptime CORPUS_DIMS = 256
comptime CORPUS_SEED = 20260910
comptime _W = 8
comptime _ACC = 4


def _qint(req: HTTPRequest, key: String, fallback: Int) -> Int:
    """A decimal query parameter, or `fallback`. Never raises: a bad value in
    a URL is the client's, and a 500 is the wrong answer to it."""
    var raw = String("")
    try:
        ref q = req.uri.queries
        if key in q:
            raw = q[key]
    except:
        return fallback
    var n = raw.byte_length()
    if n == 0 or n > 9:
        return fallback
    var out = 0
    var bytes = raw.as_bytes()
    for i in range(n):
        var c = Int(bytes[i])
        if c < ord("0") or c > ord("9"):
            return fallback
        out = out * 10 + (c - ord("0"))
    return out


def _lcg_bits(mut state: UInt64) -> UInt64:
    """Knuth's LCG. `bench/mojo_mount/app.py` reproduces it exactly, so both
    arms of the benchmark score the same corpus without shipping a fixture."""
    state = state * 6364136223846793005 + 1442695040888963407
    return (state >> 33) & 0x7FFFFFFF


def _lcg_next(mut state: UInt64) -> Float32:
    return Float32(Int(_lcg_bits(state))) / Float32(1073741824.0) - Float32(1.0)


def _dot(
    a: Pointer[Float32, MutUntrackedOrigin],
    b: Pointer[Float32, MutUntrackedOrigin],
    d: Int,
) -> Float32:
    """Four independent accumulator chains, not one: a single chain runs at
    FMA latency rather than throughput, which measured 31 GFLOP/s against 42."""
    var acc = InlineArray[SIMD[DType.float32, _W], _ACC](fill=0)
    var step = _W * _ACC
    var i = 0
    while i + step <= d:
        comptime for k in range(_ACC):
            var o = i + k * _W
            acc[k] += a.unsafe_offset(o).unsafe_load[width=_W]() * b.unsafe_offset(
                o
            ).unsafe_load[width=_W]()
        i += step
    var tot = SIMD[DType.float32, _W](0)
    comptime for k in range(_ACC):
        tot += acc[k]
    var total = tot.reduce_add()
    while i < d:
        total += a[unsafe_offset=i] * b[unsafe_offset=i]
        i += 1
    return total

comptime MOUNT_INDEX = "/"
comptime MOUNT_PROBE = "/probe"
comptime MOUNT_SEARCH = "/search"
comptime MOUNT_HOLD = "/hold"
"""The Mojo mount's routes, as values: given to the table and reversed by
the index through the mount, so no link is spelled by hand."""


@fieldwise_init
struct Corpus(Movable):
    """The Mojo mount's per-thread state: where the mount is, and the corpus
    `search` scans.

    Per-thread rather than shared for the reason the pool exists: a thread
    owns its handler, and nothing here is worth a lock. The corpus is
    generated from a fixed seed on each thread rather than read from a
    file, so there is no fixture to ship and no I/O in the request path.
    """

    var thread_index: Int
    var at: Mount
    """Where this mount is served, from the lane's own prefix. Every link
    the mount renders reverses through it, which is what keeps a link
    right under `--mount /native=mojo` — the case `smoke-mojo-mount`
    follows one to check."""
    var rows: Int
    var dims: Int
    var vecs: Pointer[Float32, MutUntrackedOrigin]
    var tags: Pointer[UInt8, MutUntrackedOrigin]
    var query: Pointer[Float32, MutUntrackedOrigin]
    var scores: Pointer[Float32, MutUntrackedOrigin]

    @staticmethod
    def generate(ctx: PoolContext, at: Mount) raises -> Self:
        var rows = CORPUS_ROWS
        var dims = CORPUS_DIMS
        var vecs = unsafe_alloc[Float32](count=rows * dims)
        var tags = unsafe_alloc[UInt8](count=rows)
        var query = unsafe_alloc[Float32](count=dims)
        var scores = unsafe_alloc[Float32](count=rows)
        var state = UInt64(CORPUS_SEED)
        for r in range(rows):
            for d in range(dims):
                vecs[unsafe_offset=r * dims + d] = _lcg_next(state)
            tags[unsafe_offset=r] = UInt8(_lcg_bits(state) % 100)
        for d in range(dims):
            query[unsafe_offset=d] = _lcg_next(state)
        return Self(ctx.index, at, rows, dims, vecs, tags, query, scores)

    def search(mut self, sel: Int, k: Int) -> String:
        """One fused pass: the tag is checked before the row is touched."""
        var dims = self.dims
        for r in range(self.rows):
            if sel < 100 and Int(self.tags[unsafe_offset=r]) >= sel:
                self.scores[unsafe_offset=r] = Float32(-1e30)
                continue
            self.scores[unsafe_offset=r] = _dot(
                self.vecs.unsafe_offset(r * dims), self.query, dims
            )
        var ids = String("")
        var best = List[Int](capacity=k)
        var bsc = List[Float32](capacity=k)
        for _ in range(k):
            best.append(-1)
            bsc.append(Float32(-1e30))
        for r in range(self.rows):
            var sc = self.scores[unsafe_offset=r]
            if sc <= bsc[k - 1]:
                continue
            var j = k - 1
            while j > 0 and bsc[j - 1] < sc:
                bsc[j] = bsc[j - 1]
                best[j] = best[j - 1]
                j -= 1
            bsc[j] = sc
            best[j] = r
        for i in range(k):
            if i > 0:
                ids += ","
            ids += String(best[i])
        return ids^


def mount_index(
    req: HTTPRequest, params: List[String], st: Corpus
) raises -> HTTPResponse:
    """GET / under the mount: its routes, as links that carry the prefix.

    The one thing here a person clicks. Both hrefs come from
    `st.at.url_for`, so they are right wherever the mount is —
    `/native/probe` under `--mount /native=mojo`. A reverse that forgot the
    prefix would render `/probe`, which the application at the root
    answers 404: a dead link nobody sees until it is followed, which is
    exactly what `smoke-mojo-mount` does.
    """
    var h = Html()
    h.open("ul")
    h.open("li")
    h.open("a")
    h.attr("href", st.at.url_for(MOUNT_PROBE))
    h.text("probe")
    h.close("a")
    h.close("li")
    h.open("li")
    h.open("a")
    h.attr("href", String(st.at.url_for(MOUNT_SEARCH), "?sel=10&k=5"))
    h.text("search")
    h.close("a")
    h.close("li")
    h.close("ul")
    return reply.html(h^.finish())


def mount_probe(
    req: HTTPRequest, params: List[String], st: Corpus
) raises -> HTTPResponse:
    """The route the smoke and the fairness probe hit: which thread, no work."""
    return reply.json(
        200,
        String("OK"),
        String(
            '{"mount":"mojo","path":"', req.uri.path,
            '","thread":', st.thread_index, "}",
        ),
    )


def mount_search(
    req: HTTPRequest, params: List[String], mut st: Corpus
) raises -> HTTPResponse:
    """The route that exists to be measured (`poe bench-mojo-mount`): a
    filtered similarity scan over this thread's corpus. A writing view
    because the scan fills the thread's own score buffer."""
    var sel = _qint(req, String("sel"), 100)
    var k = _qint(req, String("k"), 10)
    if sel < 1 or sel > 100:
        sel = 100
    if k < 1 or k > 64:
        k = 10
    return reply.json(
        200,
        String("OK"),
        String(
            '{"mount":"mojo","sel":', sel, ',"thread":',
            st.thread_index, ',"top":[', st.search(sel, k), "]}",
        ),
    )


def mount_hold(
    req: HTTPRequest, params: List[String], st: Corpus
) raises -> HTTPResponse:
    """GET /hold?channel=NAME under the mount: an SSE hold from a Mojo view.

    Spelled exactly the way a Django view spells it — the two instruction
    headers, the body as the head of the stream — so the pool thread takes
    it the way a WSGI pool thread takes a Django one (`mojo_pool.mojo`),
    and a publish from Python reaches the stream through the loop's
    registries. `smoke-mojo-mount-hold` is the gate. **Unauthenticated,
    like `apps/django_realtime`'s publish, and wrong for production for the
    same reason**: anyone who can reach the port can subscribe to any
    channel. A real mount decides here whether this connection may be held
    and which channel it joins, as a Django hold view does with its session.
    """
    var channel = String("news")
    try:
        ref q = req.uri.queries
        if "channel" in q:
            channel = q["channel"]
    except:
        pass
    return HTTPResponse(
        body_bytes=String(
            'event: connected\ndata: {"mount":"mojo","thread":',
            st.thread_index, "}\n\n",
        ).as_bytes(),
        headers=Headers(
            Header("M0-Hold", "stream"),
            Header("M0-Channel", channel),
        ),
        status_code=200,
        status_text="OK",
    )


def mount_urls(at: Mount) raises -> Views[Corpus]:
    """The mount's table, registered under its prefix."""
    var v = Views[Corpus](at)
    v.add_read("GET", MOUNT_INDEX, mount_index)
    v.add_read("GET", MOUNT_PROBE, mount_probe)
    v.add_write("GET", MOUNT_SEARCH, mount_search)
    v.add_read("GET", MOUNT_HOLD, mount_hold)
    return v^


struct MojoMount(PoolHandler):
    """The handler behind `--mount PREFIX=mojo`.

    **An application replaces this module, not this struct in place.** A
    Mojo handler is a compile-time type, not an importable object, so there
    is no way to name one on a command line against a prebuilt binary: an
    application writes its own `m0serve_mount.mojo` holding its own
    `MojoMount` and builds with `M0SERVE_MOUNT_DIR` naming that directory
    (`smoke-mount-seam`, SPEC N14). That is the whole distribution story for
    a Mojo mount, and it is why the shipped wheel remains a Python host and
    nothing more.

    It lives in a module the build resolves from SOURCE rather than in
    `src/` because `PoolHandler` is an app-facing trait: a conformance
    declared behind the `.mojoc` has its witness table silently never
    emitted (`lightbug_http/mojo_pool.mojo` records why the trait itself
    sits in the fork). A module found on an `-I` root compiles with the
    entry file, as the entry file itself did, and `smoke-mojo-mount`
    passing with this struct here is the measurement that says so. The same is why this
    struct, and not `m0_http.ViewService`, is what conforms: it holds a
    `Views` table and its per-thread state and forwards `func`, which is
    all `ViewService` does, and is the shape any mounted Mojo app takes.

    It runs on a `MojoPool` thread, which **never attaches to the
    interpreter**. That is the entire point of the mount: this path answers
    at full speed while every Python thread in the same process is behind
    the GIL.

    Three routes. `/probe` is what the smoke and the fairness probe hit;
    `/search` exists to be measured, the way `apps/pool_spike`'s `/slow`
    does — a filtered similarity scan, the shape a compute endpoint
    actually has and the shape numpy cannot hand to one BLAS call, because
    a per-row filter forces it to either gather the selected rows or score
    every row and mask, and its gather holds the GIL (`bench/mojo_mount/`
    holds the Python arm; `poe bench-mojo-mount` compares them in one
    process); and `/` renders the other two as links, through the mount,
    so that a prefix-blind reverse is a failed click in the smoke rather
    than a surprise in production.
    """

    var views: Views[Corpus]
    var state: Corpus

    def __init__(out self, var views: Views[Corpus], var state: Corpus):
        self.views = views^
        self.state = state^

    @staticmethod
    def make(ctx: PoolContext) raises -> Self:
        # The prefix comes from the lane this thread serves, which the pool
        # filled from the same table the loop routes by — so the paths this
        # table matches and the links it renders cannot disagree with where
        # the loop sends requests.
        var at = Mount(ctx.prefix)
        return Self(mount_urls(at), Corpus.generate(ctx, at))

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return self.views.dispatch(req, self.state)

    def shutdown(mut self):
        pass
