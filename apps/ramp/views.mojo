"""The ramp module: one views table, compiled into two hosts.

    GET  /x/               the index: two links, reversed through the mount
    GET  /x/now            the trivial route the placement gate times (loop)
    GET  /x/search?sel=&k= a compute view: a filtered similarity scan
    GET  /x/slow?ms=       a spin for `ms`: the placement load

This is Phase 3 of the Mojo host plan (docs/notes/the-ramp-test.md, SPEC
N20): the same `Views[Ramp]` table, the same view functions and the same
state type serve under `m0serve --mount /x=mojo` (the `MojoMount` adapter
in `mount/m0serve_mount.mojo`, built with `M0SERVE_MOUNT_DIR`) and under
the Mojo host (`server.mojo`, `serve[ViewsApp[Ramp]]`), and `smoke-ramp`
asserts the two answer BYTE-IDENTICAL responses apart from `Date`, follow
the same rendered link, and keep `/now` answered while `/slow` holds a
pool thread on each.

What the module must not do, and why:

- **Name where it ran.** The demo mount's bodies carry `"thread":N`,
  which on the host would be a lane index and on the loop -1; a body
  that differs by placement cannot be compared. Nothing here does.
- **Spell its prefix twice.** Every link goes through `st.at.url_for`.
  Under `m0serve` the prefix is the lane's (`PoolContext.prefix`, from
  the CLI); under the host, which has no mount table, it is
  `RAMP_PREFIX` here -- the one value the smoke passes to `--mount` too,
  so a disagreement is a dead link the gate follows.
- **Depend on the host.** The state's constructor takes what both hosts
  can supply: the prefix. `make(ctx: HostContext)` is the host's
  conformance; `Ramp.generate(at)` is what both adapters call.

The corpus and the scan are lifted from `packages/m0-wsgi/mount/
m0serve_mount.mojo`, the demo mount, which keeps its job (its bodies name
the thread on purpose, for `smoke-mojo-mount` and the fairness probe).
"""

from std.memory.alloc import unsafe_alloc
from std.time import perf_counter_ns

from lightbug_http import HTTPRequest, HTTPResponse
from lightbug_http.host import HostContext, ViewState
from m0_http import Html, Mount, Views, reply


comptime RAMP_PREFIX = "/x"
"""Where the host serves the table. The smoke mounts m0serve here too."""

comptime RAMP_INDEX = "/"
comptime RAMP_NOW = "/now"
comptime RAMP_SEARCH = "/search"
comptime RAMP_SLOW = "/slow"
"""The routes, as values: given to the table and reversed by the index
through the mount, so no link is spelled by hand."""

comptime CORPUS_ROWS = 4096
comptime CORPUS_DIMS = 256
comptime CORPUS_SEED = 20260917
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
    state = state * 6364136223846793005 + 1442695040888963407
    return (state >> 33) & 0x7FFFFFFF


def _lcg_next(mut state: UInt64) -> Float32:
    return Float32(Int(_lcg_bits(state))) / Float32(1073741824.0) - Float32(1.0)


def _dot(
    a: Pointer[Float32, MutUntrackedOrigin],
    b: Pointer[Float32, MutUntrackedOrigin],
    d: Int,
) -> Float32:
    """Four independent accumulator chains (the demo mount's measurement:
    one chain runs at FMA latency rather than throughput)."""
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


@fieldwise_init
struct Ramp(ViewState):
    """The table's state: where it is mounted, and the corpus `search`
    scans. One per handler instance -- per pool thread, and the loop's own
    -- generated from a fixed seed, so every instance answers the same
    bytes and there is no fixture to ship."""

    var at: Mount
    var rows: Int
    var dims: Int
    var vecs: Pointer[Float32, MutUntrackedOrigin]
    var tags: Pointer[UInt8, MutUntrackedOrigin]
    var query: Pointer[Float32, MutUntrackedOrigin]
    var scores: Pointer[Float32, MutUntrackedOrigin]

    @staticmethod
    def generate(at: Mount) raises -> Self:
        """What both adapters call: the state from the prefix alone."""
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
        return Self(at, rows, dims, vecs, tags, query, scores)

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        """The host's conformance: the prefix is the module's own."""
        return Self.generate(Mount(RAMP_PREFIX))

    @staticmethod
    def urls() raises -> Views[Self]:
        return ramp_urls(Mount(RAMP_PREFIX))

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


def ramp_index(
    req: HTTPRequest, params: List[String], st: Ramp
) raises -> HTTPResponse:
    """GET / under the mount: the routes, as links that carry the prefix.

    On the loop (`on_loop=True`): it reads the state, and it is the page
    a person lands on, which should answer while the lane is busy. Under
    `m0serve` the flag is not honoured (D32) and a pool thread answers
    the same bytes from its own copy of the state.
    """
    var h = Html()
    h.open("ul")
    h.open("li")
    h.open("a")
    h.attr("href", st.at.url_for(RAMP_NOW))
    h.text("now")
    h.close("a")
    h.close("li")
    h.open("li")
    h.open("a")
    h.attr("href", String(st.at.url_for(RAMP_SEARCH), "?sel=10&k=5"))
    h.text("search")
    h.close("a")
    h.close("li")
    h.close("ul")
    return reply.html(h^.finish())


def ramp_now(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    """The timed trivial route. Stateless, so both hosts can answer it on
    the loop -- and `m0serve` answers it on a pool thread (D32)."""
    return reply.json(200, String("OK"), String('{"route":"now"}'))


def ramp_search(
    req: HTTPRequest, params: List[String], mut st: Ramp
) raises -> HTTPResponse:
    """The compute view. A writing view because the scan fills the
    instance's own score buffer."""
    var sel = _qint(req, String("sel"), 100)
    var k = _qint(req, String("k"), 10)
    if sel < 1 or sel > 100:
        sel = 100
    if k < 1 or k > 64:
        k = 10
    return reply.json(
        200,
        String("OK"),
        String('{"sel":', sel, ',"k":', k, ',"top":[', st.search(sel, k), "]}"),
    )


def ramp_slow(
    req: HTTPRequest, params: List[String], st: Ramp
) raises -> HTTPResponse:
    """A spin for `ms` milliseconds: what holds the thread that serves it,
    and what the placement gate loads each host with. A spin, not a
    sleep, on purpose -- a sleeping view would release the loop and hide
    the cost the gate exists to show."""
    var ms = _qint(req, String("ms"), 0)
    if ms > 10_000:
        ms = 10_000
    var deadline = perf_counter_ns() + ms * 1_000_000
    var spins = 0
    while perf_counter_ns() < deadline:
        spins += 1
    # Not the spin count: it differs per run and per host, and the gate
    # compares bodies byte for byte.
    return reply.json(200, String("OK"), String('{"ms":', ms, "}"))


def ramp_urls(at: Mount) raises -> Views[Ramp]:
    """The table, registered under `at`. What both adapters build."""
    var v = Views[Ramp](at)
    v.add_read("GET", RAMP_INDEX, ramp_index, on_loop=True)
    v.add_loop("GET", RAMP_NOW, ramp_now)
    v.add_write("GET", RAMP_SEARCH, ramp_search)
    v.add_read("GET", RAMP_SLOW, ramp_slow)
    return v^
