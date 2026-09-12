"""`m0serve` — serve any WSGI application from one built binary.

    uv run poe build-serve                                        # -> bin/m0serve
    bin/m0serve myproject.wsgi:application --app-dir /path/to/project \\
        --host 0.0.0.0 --port 8000 --workers 4 --static /static/=/path/to/static

The uvicorn-shaped entry point. `MODULE[:ATTR]` names the callable (ATTR
defaults to `application`), `--app-dir` is prepended to `sys.path` so the
module can be imported, and every `M0_*` environment variable keeps its
meaning with the matching flag winning over it. `--help` lists the rest.

**Why this file lives at the package root, outside `src/`.** It is a
compiled entry file, the same shape as `packages/m0-core/ffi_exports.mojo`
and for the same reasons: `mojo precompile src` never sees it, so it cannot
land inside `m0_wsgi.mojoc`, and it imports `m0_wsgi` through that `.mojoc`
rather than through `src.*` — an entry file outside any package resolves
`src` by the first `-I` root, which is exactly the fragility every package's
`test_resolution.mojo` exists to catch. `build-apps`'s `apps/*/server.mojo`
glob never sees it either, which is why `poe build-serve` is its own task.

**The order of `main()` is the load-bearing part.** Bind the listener first,
so every worker inherits one shared socket (gunicorn's model; per-worker
`SO_REUSEPORT` binds would not do — they do not distribute on macOS and hash
blind on Linux). Which worker WINS an accept on it is the scheduler's, and
it is the same worker nearly every time on both platforms, so under
`--workers N` the winner passes each connection to the least-loaded sibling
over a channel created here before the fork (`lightbug_http/accept_share.mojo`,
SPEC E16; `M0_ACCEPT_SHARE=0` is the A/B knob). Fork second, BEFORE any
Python: Mojo initializes the interpreter lazily on first use, forking a live
CPython is unsafe, and so each worker's own `WSGIApp` construction after
`fork_all()` returns must stay the process's first Python call. Everything
that can be validated without an interpreter — the flags, the directories —
is validated before the bind, so a typo fails in milliseconds with a message
that names it rather than as an `ImportError` five frames deep.

`func` runs the application synchronously on the event loop, so a process
serves one request at a time and a slow view stalls its whole process;
concurrency is `--workers`. A forked worker must end with `exit_worker()`,
never by returning from `main` — the runtime's teardown reaches into
libdispatch, which is unusable in a process forked without exec.

**`--reload` forces a supervisor**, even at one worker and even under
`--threads N`, because something has to outlive the process it restarts.
That composes with both modes for one reason: the supervisor never touches
Python. It watches files with `listdir` and `stat`, which is libc and
therefore allowed in a process forked without exec, and the fork still
precedes the first Python call because the supervisor never makes one. What
reloads is the *worker* — a fresh interpreter importing the changed module.
The Mojo binary is never re-exec'd, so a changed `.mojo` still needs a
rebuild and a restart.
"""

from std.os import getenv, setenv
from std.os.path import isdir, isfile
from std.python import Python, PythonObject
from std.sys.arg import argv
from std.sys.info import CompilationTarget

from lightbug_http import (
    Server, MojoPool, PoolContext, PoolHandler, HTTPRequest, HTTPResponse,
)
from m0_http import request_qos_class, QOS_CLASS_USER_INTERACTIVE
from m0_http import Html, Mount, Views, reply
from m0_http import GrantKeys, verify_grant, GRANT_KEY_ENV
from lightbug_http.http.date import unix_now
from lightbug_http.broadcast import BroadcastBus
from lightbug_http.event_loop import run_event_loop
from lightbug_http.offload import OffloadPool
from lightbug_http.accept_share import AcceptShare, accept_share_slots
from lightbug_http.connection import ListenConfig, NoTLSListener
from lightbug_http.address import NetworkType, TCPAddr, parse_address
from lightbug_http.socket import Socket
from lightbug_http.c.process import process_exit, executable_path, keep_across_exec
from lightbug_http.server_config import ServerConfig
from lightbug_http.header import Header, Headers, HeaderKey
from std.memory.alloc import unsafe_alloc
from lightbug_http.c.platform import PlatformBackend

from m0_http import (
    StaticFiles, WorkerSupervisor, install_shutdown_signals, exit_worker,
    threads_conflict,
)
from m0_http.config import AppConfig
from m0_http.multiworker import SharedAtomics
from m0_wsgi import (
    WSGIApp, WSGIHandler, ServeOptions, parse_args, parse_app_spec, usage,
    ThreadedServer, require_free_threading, BlockingPool, DetachingBackend,
    AsgiExecutor, serve_inverted, JOIN_TIMEOUT_NS, detect_protocol, discovery_specs, resolve_blocking_threads,
    zero_config_topology, use_asgi_executor, wsgi_lanes, mojo_lanes, has_wsgi_mount, asgi_mount_names,
    hold_lanes, is_compiled_mount, has_python_mount,
    effective_cpus, performance_cpus, pool_cpus, usable_cpus, apple_target, Report, probe_free_threading, EXIT_NOT_FREE_THREADED,
    use_loop_inversion,
    asgi_free_threading_refusal,
    M0SERVE_VERSION, prepend_to_path, DEFAULT_PORT, EXIT_USAGE, EXIT_STARTUP, PROTOCOL_ASGI,
)



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

    **This is the file a user edits.** A Mojo handler is a compile-time type,
    not an importable object, so there is no way to name one on a command
    line against a prebuilt binary: you replace this struct and rebuild.
    That is the whole distribution story for a Mojo mount, and it is why the
    shipped wheel remains a Python host and nothing more.

    It lives in the entry file rather than in `src/` because `PoolHandler` is
    an app-facing trait: a conformance declared behind the `.mojoc` has its
    witness table silently never emitted (`lightbug_http/mojo_pool.mojo`
    records why the trait itself sits in the fork). The same is why this
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

comptime HOLD_STREAM = "/stream"
"""The hold mount's one route: `GET <prefix>/stream?g=<grant>`."""


struct GrantGate(Movable):
    """The hold mount's per-thread state: the keys it verifies against."""

    var keys: GrantKeys

    def __init__(out self, var keys: GrantKeys):
        self.keys = keys^

    def __init__(out self, *, deinit move: Self):
        self.keys = move.keys^


def hold_stream(
    req: HTTPRequest, params: List[String], st: GrantGate
) raises -> HTTPResponse:
    """The grant-verified hold: `GET <prefix>/stream?g=<grant>`.

    The application decided, in its own view with its own session, whether
    this browser may hold a stream and on which channel, and signed that
    decision into the URL (`m0serve.grant`); this verifies it -- signature
    in constant time, expiry against this host's clock, the session cookie
    the browser sends against the binding the issuer put in -- and takes
    the hold with the two headers a Django hold view returns, which the
    pool thread turns into the same `h` frame. No Python is asked. A refusal
    is a 401 whose body says `expired` (fetch a fresh URL) or `invalid`
    (stop), and names the reason.
    """
    var g = String("")
    try:
        ref q = req.uri.queries
        if "g" in q:
            g = q["g"]
    except:
        pass
    if g.byte_length() == 0:
        return reply.json(
            401, String("Unauthorized"),
            String('{"error":"invalid","reason":"no grant"}'),
        )
    var verdict = verify_grant(
        Span(g.as_bytes()), st.keys, unix_now(), req.cookies.get(st.keys.cookie)
    )
    if not verdict.ok:
        var kind = String("expired") if verdict.reason == "expired" else String("invalid")
        return reply.json(
            401, String("Unauthorized"),
            String('{"error":"', kind, '","reason":"', verdict.reason, '"}'),
        )
    return HTTPResponse(
        body_bytes=String(": open\n\n").as_bytes(),
        headers=Headers(
            Header("M0-Hold", "stream"),
            Header("M0-Channel", verdict.channel),
        ),
        status_code=200,
        status_text="OK",
    )


def hold_urls(at: Mount) raises -> Views[GrantGate]:
    var v = Views[GrantGate](at)
    v.add_read("GET", HOLD_STREAM, hold_stream)
    return v^


struct HoldMount(PoolHandler):
    """The handler behind `--mount PREFIX=hold`: a stream held against a grant.

    The one built-in mount a Python application uses without a Mojo build
    of its own: the application keeps every authorization decision in its
    own views and hands the browser a signed URL into this mount
    (`m0serve.grant.stream_url`), and the mount holds the stream on a
    pool thread that never attaches to the interpreter. Needs `--realtime`
    (what wires a pool thread's hold to the loop) and `M0_GRANT_KEY` (what
    the application signed with); `main` refuses to start without either.
    `smoke-hold-mount` is the gate; the design is
    docs/notes/grant-verified-holds.md.
    """

    var views: Views[GrantGate]
    var state: GrantGate

    def __init__(out self, var views: Views[GrantGate], var state: GrantGate):
        self.views = views^
        self.state = state^

    @staticmethod
    def make(ctx: PoolContext) raises -> Self:
        # The keys are prepared once per thread, here: an HMAC state each,
        # so a verification costs the grant's bytes and nothing of the key's.
        return Self(hold_urls(Mount(ctx.prefix)), GrantGate(GrantKeys.from_env()))

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return self.views.dispatch(req, self.state)

    def shutdown(mut self):
        pass


def _realtime_without_wsgi(opts: ServeOptions, is_asgi: Bool) -> Bool:
    """Whether `--realtime` has no application that could ever take a hold.

    `M0-Hold` is a response-header protocol for buffered WSGI responses, so
    the flag needs a WSGI application somewhere. Unmounted that is the whole
    question. **Mounted it is per mount**: a server whose WSGI mounts take
    holds while its ASGI mounts stream through their own executor is exactly
    the mixed application this pair was refused for, and the loop tells the
    two apart by lane. Only a mounted server with no WSGI mount at all is
    asking for nothing.
    """
    if len(opts.mount_prefixes) == 0:
        return is_asgi
    # Asked positively. `len(asgi_mounts) == len(mount_prefixes)` was the
    # same question while there were two kinds; with a third it lets a
    # server of one Mojo mount and no WSGI mount pass the check and take
    # `--realtime` with nothing that could ever hold a connection.
    return not has_wsgi_mount(opts)


def _fail(message: String, code: Int):
    """Report and exit with `code`.

    `process_exit` is `_exit(2)`: no atexit, no unwinding — which is what a
    forked worker needs (the runtime's teardown is unusable after fork) and
    harmless everywhere else, because every message is flushed first. (The
    stdlib's `exit` was tried and the status did not reach the shell.)
    """
    print("m0serve: " + message, flush=True)
    process_exit(code)


def _discover_core_lib() -> String:
    """Where `libm0core` is, for `m0pub`'s `ctypes` lookup. Empty = not found.

    Only consulted under `--realtime`, and only when `M0_CORE_LIB` is not
    already set. The library holds `m0_shared_fetch_add`, which is how a
    Python publisher takes a globally unique event id from the shared slot —
    Python has no atomic read-modify-write over a raw address, and a racy one
    would hand two workers the same id. Without it publishing still works;
    frames go out unnumbered, which costs duplicate suppression on reconnect.

    Two candidates, most specific first: beside the binary (how a built
    `bin/m0serve` ships), then `poe build-ffi`'s output relative to the
    working directory (how the repo runs). `m0pub` has the same fallbacks,
    so an unset variable is not a failure — exporting it just means the
    lookup cannot be defeated by the working directory.
    """
    var ext = String(".dylib") if CompilationTarget.is_macos() else String(".so")
    var candidates = List[String]()
    var exe = String(argv()[0])
    var slash = exe.rfind("/")
    if slash >= 0:
        candidates.append(
            String(StringSpan(exe)[byte = :slash]) + "/libm0core" + ext
        )
    candidates.append(String("packages/m0-core/libm0core") + ext)
    for i in range(len(candidates)):
        if isfile(candidates[i]):
            return candidates[i]
    return String("")


comptime _HOLD_MOUNT_NEEDS_REALTIME = (
    "--mount PREFIX=hold needs --realtime: the flag is what wires a pool"
    " thread's hold to the event loop, and a hold mount can do nothing else"
)
comptime _HOLD_MOUNT_NEEDS_KEY = (
    "--mount PREFIX=hold needs M0_GRANT_KEY: the mount verifies grants the"
    " application signed with it (32 random bytes; openssl rand -base64 32)"
)
comptime _REALTIME_ASGI_CONFLICT = (
    "--realtime requires a WSGI application: the M0-Hold contract is a"
    " response-header protocol for buffered WSGI responses, and an ASGI"
    " application streams through its own send() instead. Serve it without"
    " --realtime."
)


def _refuse_executor_on_free_threaded(executor_mode: Bool) raises:
    """Exit 78 when the asyncio executor would run on a free-threaded build.

    The executor's `ExecutorPort` is built with `PythonModuleBuilder`, and
    the stdlib's `PyObject` is the GIL build's 16-byte header; a
    free-threaded build's is 32, so module creation segfaults
    (modular/modular#5726). Checked wherever `use_asgi_executor` said yes
    -- prefork's worker, the threaded path, and the doctor -- and keyed on
    the BUILD (`Py_GIL_DISABLED`), not on whether the GIL happens to be
    enabled, because the layout is the build's. Under prefork this runs in
    the worker (detection cannot precede the fork), and the supervisor
    treats a worker's 78 as the refusal it is rather than a crash to
    respawn (`WorkerSupervisor`, `EX_CONFIG`).
    """
    if not executor_mode:
        return
    var report = probe_free_threading()
    if report.free_threaded_build:
        _fail(asgi_free_threading_refusal(report), EXIT_NOT_FREE_THREADED)


def _specs_tried(specs: List[String]) -> String:
    """The discovery candidates as one comma-separated list, for errors."""
    var joined = String("")
    for i in range(len(specs)):
        if i > 0:
            joined += ", "
        joined += specs[i]
    return joined^


def spawned_worker_index() -> Int:
    """This process's worker index when it was `exec`'d by the supervisor
    under `--spawn-workers`, else -1.

    `M0_WORKER_SPAWNED=1` and `M0_WORKER_INDEX` are set by the supervisor in
    the forked child just before its `execv` (`WorkerSupervisor.enable_spawn`),
    so they are only ever seen by a fresh image whose parent is supervising
    it. Such a process binds nothing: it inherits the listener, the bus
    channels and the shared page by fd number and rebuilds each from the
    environment, then serves exactly as a forked worker of the same index.
    """
    if getenv("M0_WORKER_SPAWNED", "") != "1":
        return -1
    var raw = getenv("M0_WORKER_INDEX", "")
    if raw.byte_length() == 0:
        return -1
    try:
        return Int(raw)
    except:
        return -1


def _int_list_env(name: String) -> List[Int]:
    var out = List[Int]()
    var raw = getenv(name, "")
    if raw.byte_length() == 0:
        return out^
    for part in raw.split(","):
        try:
            out.append(Int(String(part)))
        except:
            pass
    return out^


def _adopt_listener(opts: ServeOptions) raises -> NoTLSListener[NetworkType.tcp4]:
    """The listener a spawned worker inherited, by fd number (`M0_LISTEN_FD`)."""
    var raw = getenv("M0_LISTEN_FD", "")
    var fd: Int
    try:
        fd = Int(raw)
    except:
        _fail("spawned worker: M0_LISTEN_FD is not set", EXIT_STARTUP)
        raise Error("unreachable")
    var local = parse_address[NetworkType.tcp4](opts.address())
    var sock = Socket[TCPAddr[NetworkType.tcp4]](
        fd=FileDescriptor(fd),
        local_address=TCPAddr[NetworkType.tcp4](ip=local.host, port=local.port),
    )
    return NoTLSListener[NetworkType.tcp4](sock^)


def _listen_or_fail(opts: ServeOptions) raises -> NoTLSListener[NetworkType.tcp4]:
    """Bind, or say why not and exit `EXIT_STARTUP`.

    Five attempts a second apart: a restart racing the previous process's
    5 s drain still succeeds, and a port still busy after that belongs to
    another server — which is the message a developer needs, not the
    listener's retry chatter. `SO_REUSEPORT` is off (the `ListenConfig`
    default since 0.14.0), so a second `m0serve` on a busy port fails here
    instead of binding beside the first and taking a share of its
    connections. `quiet=True`: the startup line printed after the
    application loads is the ready signal, so "ready" means ready — the
    banner used to print before the load, and a failed import read as
    "Ready" followed by exit 1. `smoke-serve` pins both.
    """
    if spawned_worker_index() >= 0:
        return _adopt_listener(opts)
    try:
        var listener = ListenConfig(max_bind_retries=5, quiet=True).listen(
            opts.address()
        )
        # Where a spawned worker finds it. Set unconditionally: it is one
        # variable, and the fd number is the same whether or not anyone
        # execs — a forked worker simply keeps using the listener itself.
        _ = setenv("M0_LISTEN_FD", String(listener.socket.fd.value), True)
        _ = keep_across_exec(Int(listener.socket.fd.value))
        return listener^
    except:
        _fail(
            "address already in use: " + opts.address()
            + " -- is another server running? (pick another --port, or"
            + " stop it)",
            EXIT_STARTUP,
        )
        raise Error("unreachable: _fail exits the process")


def _resolve_spec(mut opts: ServeOptions) raises -> Bool:
    """Import, resolve discovery, and detect the protocol — no lifespan.

    An explicit `MODULE:ATTR` detects exactly what it names. A bare
    `MODULE` tries the `discovery_specs` conventions in order — Django's
    `asgi.py`/`wsgi.py` and the `main:app` shape — and the first one that
    imports and classifies wins; `opts` is updated to the winner so the
    banner and the per-thread handlers name what is actually being served.
    On a total miss, the primary spec's own error leads and every
    candidate tried is listed.

    Detection is deliberately separate from `WSGIApp` construction: the
    executor mode's decision needs the protocol BEFORE any bridge exists,
    so that exactly one lifespan runs per event loop (the executor's), not
    one per candidate tried. The caller must have put `--app-dir` on
    `sys.path`; the imports here are `sys.modules` hits for everything
    that follows.
    """
    if opts.attribute_explicit:
        return detect_protocol(opts.module, opts.attribute, opts.protocol)
    var specs = discovery_specs(opts.module)
    var first_error = String("")
    for i in range(len(specs)):
        var pair = parse_app_spec(specs[i])
        try:
            var is_asgi = detect_protocol(pair[0], pair[1], opts.protocol)
            opts.module = pair[0]
            opts.attribute = pair[1]
            return is_asgi
        except e:
            # A candidate that exists and RAISES on import is the answer,
            # not a miss to be papered over by the next convention: the
            # shim attaches the traceback to exactly that case, and the
            # discovery list would only hide it.
            if String(e).find("Traceback (most recent call last)") >= 0:
                raise Error(String(e))
            if i == 0:
                first_error = String(e)
    raise Error(first_error + " (tried " + _specs_tried(specs) + ")")


def _resolve_mounts(mut opts: ServeOptions) raises -> Bool:
    """Detect every mount's protocol; returns True when they are all ASGI.

    Each mount resolves independently — discovery included, so
    `--mount /=djangoproj` finds `djangoproj.wsgi` exactly as a positional
    spec would — and the winner is written back so the banner and every
    handler name what is actually served.

    Mixed WSGI/ASGI mounts are the point: each gets its native execution
    mode, so `opts.asgi_mounts` records which mounts are ASGI rather than
    reducing detection to one answer for the process. A `--mount X=mojo`
    is skipped here: it has no importable object, so there is nothing to
    detect and nothing to discover. Any number of each:
    every ASGI mount gets its own executor, on its own submit lane, with
    its own drain-ack pair — the chunk channel is the one thing executors
    share, and its datagrams are slot-addressed.
    """
    var asgi_count = 0
    for i in range(len(opts.mount_prefixes)):
        # A Mojo mount has no importable object to detect a protocol from —
        # its handler is a type this binary was compiled with. Nothing to
        # resolve, and nothing to import: skip it entirely so a mounted
        # server of one Mojo mount starts no interpreter work for it.
        if is_compiled_mount(opts, i):
            continue
        var module = opts.mount_modules[i]
        var attribute = opts.mount_attributes[i]
        var is_asgi: Bool
        if opts.mount_explicit[i]:
            is_asgi = detect_protocol(module, attribute, opts.protocol)
        else:
            var specs = discovery_specs(module)
            var first_error = String("")
            var found = False
            is_asgi = False
            for k in range(len(specs)):
                var pair = parse_app_spec(specs[k])
                try:
                    is_asgi = detect_protocol(pair[0], pair[1], opts.protocol)
                    opts.mount_modules[i] = pair[0]
                    opts.mount_attributes[i] = pair[1]
                    found = True
                    break
                except e:
                    if k == 0:
                        first_error = String(e)
            if not found:
                raise Error(
                    first_error + " (tried " + _specs_tried(specs) + ")"
                )
        if is_asgi:
            asgi_count += 1
            opts.asgi_mounts.append(i)
    return asgi_count > 0


def _reload_dirs(opts: ServeOptions) -> List[String]:
    """What `--reload` watches: `--reload-dir` if given, else `--app-dir`.

    `--app-dir` is the right default because it is already the directory the
    application is imported from — the one place a `.py` edit can change
    what a worker serves.
    """
    if len(opts.reload_dirs) > 0:
        return opts.reload_dirs.copy()
    var dirs = List[String]()
    dirs.append(opts.app_dir)
    return dirs^


def _prepare_realtime(opts: ServeOptions, channels: Int) raises -> BroadcastBus:
    """Everything `--realtime` must create BEFORE the fork and before Python.

    Returns the bus (size 0, and therefore inert, when the mode is off).

    Three exports, and the ordering rule is the same for all of them: they
    must precede the fork so every worker's environment agrees, and they must
    precede any Python touch because CPython snapshots the C environ at
    interpreter init. Under `--threads` there is no fork, but the second half
    still binds — the interpreter comes up inside `require_free_threading`.

    `channels` is `--workers` under prefork and `--threads` under the threaded
    mode. The bus does not care which: a `SOCK_DGRAM` socketpair delivers the
    same whether the peer draining it is another process or another thread.
    """
    # The bus is created UNCONDITIONALLY now, --realtime or not, one
    # worker or many: an ASGI application's pub/sub (`state["m0"]`) rides
    # it, the decision must be made here -- pre-fork and pre-Python, while
    # protocol detection can only happen after the fork -- and a
    # single-worker app publishing to its own subscribers still needs its
    # own loop's channel (there is no separate local-delivery path to keep
    # in sync, by design). The cost when nothing uses it is one socketpair
    # per worker plus three env vars.
    if spawned_worker_index() >= 0:
        # A spawned worker: the parent created all of this before the fork
        # and the fd numbers came through the exec. The shared page's
        # ADDRESS did not — mappings die at exec — so it is mapped again
        # here and the exported address replaced before Python starts.
        var inherited = BroadcastBus(
            read_fds=_int_list_env("M0_BUS_READ_FDS"),
            write_fds=_int_list_env("M0_BUS_WRITE_FDS"),
        )
        var shared_fd = _int_list_env("M0_SHARED_ID_FD")
        if len(shared_fd) == 1:
            var mapped = SharedAtomics(
                from_fd=shared_fd[0], count=accept_share_slots(opts.workers)
            )
            _ = setenv("M0_SHARED_ID_ADDR", String(mapped.addr(0)), True)
        return inherited^

    var bus = BroadcastBus(channels if channels > 0 else 1)
    var fds_csv = String("")
    var read_csv = String("")
    for i in range(len(bus.write_fds)):
        if i > 0:
            fds_csv += ","
            read_csv += ","
        fds_csv += String(bus.write_fds[i])
        read_csv += String(bus.read_fds[i])
        _ = keep_across_exec(bus.write_fds[i])
        _ = keep_across_exec(bus.read_fds[i])
    _ = setenv("M0_BUS_WRITE_FDS", fds_csv, True)
    _ = setenv("M0_BUS_READ_FDS", read_csv, True)

    # One MAP_SHARED page: slot 0 is the event id every publish takes a
    # number from, and the rest is accept sharing's per-worker load words
    # (`accept_share_slots`; one cache line each, so the per-pass stores
    # contend with nothing). Shared memory across processes, and plain
    # memory across threads. Under `--spawn-workers` the page is
    # file-backed, because an anonymous mapping does not survive the
    # worker's exec; its fd is exported and the worker maps it (above).
    var shared = SharedAtomics(
        accept_share_slots(opts.workers), file_backed=opts.spawn_workers
    )
    _ = setenv("M0_SHARED_ID_ADDR", String(shared.addr(0)), True)
    if shared.fd >= 0:
        _ = setenv("M0_SHARED_ID_FD", String(shared.fd), True)

    if getenv("M0_CORE_LIB", "").byte_length() == 0:
        var lib = _discover_core_lib()
        if lib.byte_length() > 0:
            _ = setenv("M0_CORE_LIB", lib, True)

    return bus^


def accept_sharing_wanted(opts: ServeOptions) -> Bool:
    """Whether this configuration shares accepts: two or more workers,
    unless `M0_ACCEPT_SHARE=0` asks for the bare race (the A/B knob)."""
    return opts.workers > 1 and getenv("M0_ACCEPT_SHARE", "") != "0"


def _prepare_accept_share(opts: ServeOptions) raises -> AcceptShare:
    """The channels accept sharing passes connections over (SPEC E16).

    Created pre-fork like the bus, one datagram pair per worker, every
    worker holding every send end; exported by fd number for a spawned
    worker, which adopts rather than creates. Inactive — a value with no
    channels — with one worker, under `--threads`, and under the knob.
    """
    if not accept_sharing_wanted(opts):
        return AcceptShare()
    if spawned_worker_index() >= 0:
        return AcceptShare(
            read_fds=_int_list_env("M0_ACCEPT_READ_FDS"),
            write_fds=_int_list_env("M0_ACCEPT_WRITE_FDS"),
        )
    var share = AcceptShare(opts.workers)
    var read_csv = String("")
    var write_csv = String("")
    for i in range(share.workers()):
        if i > 0:
            read_csv += ","
            write_csv += ","
        read_csv += String(share.read_fds[i])
        write_csv += String(share.write_fds[i])
        _ = keep_across_exec(share.read_fds[i])
        _ = keep_across_exec(share.write_fds[i])
    _ = setenv("M0_ACCEPT_READ_FDS", read_csv, True)
    _ = setenv("M0_ACCEPT_WRITE_FDS", write_csv, True)
    return share^


def _bind_accept_share(mut share: AcceptShare, worker: Int):
    """After the fork: this worker's index and the shared page's address,
    which `_prepare_realtime` exported (and a spawned worker re-derived)."""
    if share.workers() <= 1:
        return
    var page: Int
    try:
        page = Int(getenv("M0_SHARED_ID_ADDR", "0"))
    except:
        page = 0
    share.bind(worker, page)


comptime _DOCTOR_PROBE = """
import sys, platform


def where():
    return (sys.executable or '', sys.prefix or '', platform.machine() or '',
            platform.python_implementation() or '')
"""


def _doctor_dirs(mut report: Report, opts: ServeOptions):
    """The three directory checks, in `main`'s order and with its exit code."""
    if not isdir(opts.app_dir):
        report.fail_check(
            String("app-dir"),
            "app dir does not exist: " + opts.app_dir,
            "create it, or pass --app-dir with the directory holding "
            + opts.module,
            EXIT_STARTUP,
        )
    else:
        report.pass_check(String("app-dir"), opts.app_dir + " exists")
    for i in range(len(opts.static_dirs)):
        if not isdir(opts.static_dirs[i]):
            report.fail_check(
                String("static-dir"),
                "static dir does not exist: " + opts.static_dirs[i],
                "create it, or drop --static " + opts.static_prefixes[i],
                EXIT_STARTUP,
            )
    for i in range(len(opts.reload_dirs)):
        if not isdir(opts.reload_dirs[i]):
            report.fail_check(
                String("reload-dir"),
                "reload dir does not exist: " + opts.reload_dirs[i],
                "create it, or drop --reload-dir " + opts.reload_dirs[i],
                EXIT_STARTUP,
            )


def _doctor_conflicts(mut report: Report, opts: ServeOptions):
    """The refusals `main` makes before it binds — all EXIT_USAGE."""
    var conflict = threads_conflict(opts.workers, opts.threads)
    if conflict:
        report.fail_check(
            String("threads-vs-workers"),
            conflict.value(),
            String("give one of --workers or --threads, not both"),
            EXIT_USAGE,
        )
    else:
        report.pass_check(
            String("threads-vs-workers"),
            String("topology flags are consistent"),
        )
    if opts.protocol == PROTOCOL_ASGI and opts.realtime:
        report.fail_check(
            String("protocol-vs-realtime"),
            String(_REALTIME_ASGI_CONFLICT),
            String("drop --realtime; an ASGI app streams natively"),
            EXIT_USAGE,
        )
    if len(opts.hold_mounts) > 0:
        if not opts.realtime:
            report.fail_check(
                String("hold-mount-vs-realtime"),
                String(_HOLD_MOUNT_NEEDS_REALTIME),
                String("add --realtime"),
                EXIT_USAGE,
            )
        elif getenv(GRANT_KEY_ENV, "").byte_length() == 0:
            report.fail_check(
                String("hold-mount-key"),
                String(_HOLD_MOUNT_NEEDS_KEY),
                String("export M0_GRANT_KEY, the same value the application signs with"),
                EXIT_USAGE,
            )
        else:
            report.pass_check(
                String("hold-mount"),
                String("--realtime is on and M0_GRANT_KEY is set"),
            )


def _run_doctor(mut opts: ServeOptions) -> Int:
    """`--doctor`: report the configuration, bind nothing, fork nothing.

    The order of `report.*` calls IS the order `main` performs the same
    checks, because `Report.exit_code` returns the first failure rather than
    the worst one — so a configuration that trips two refusals reports the
    one the server would actually hit first. Keeping the two in step is
    manual and therefore worth stating: if a check moves in `main`, it moves
    here.

    Never raises. A doctor that dies while diagnosing is the one failure
    mode it cannot have, so every fallible step is caught and becomes a
    failed check with the exit code that step would have produced.
    """
    var report = Report(String(M0SERVE_VERSION))
    report.add_fact(String("build"), String("version"), String(M0SERVE_VERSION))
    report.add_fact(
        String("build"),
        String("os"),
        String("macos") if CompilationTarget.is_macos() else String("linux"),
    )
    # Spelled as the wheel filenames spell it -- macosx_13_0_arm64,
    # manylinux_2_35_x86_64, manylinux_2_35_aarch64 -- so someone debugging
    # a `pip` refusal can compare this line to the file pip declined.
    var arch: String
    if CompilationTarget.is_x86():
        arch = String("x86_64")
    elif CompilationTarget.is_macos():
        arch = String("arm64")
    else:
        arch = String("aarch64")
    report.add_fact(String("build"), String("arch"), arch)
    # The generation the binary was compiled for (`apple_target`): the
    # wheel says m1 on every Mac, a native build names its host.
    comptime if CompilationTarget.is_macos():
        report.add_fact(String("build"), String("apple_target"), apple_target())

    # The interpreter, probed here for its FACTS but checked further down.
    # `probe_free_threading` is the process's first Python call, so this is
    # also where a binary that cannot resolve libpython reports why -- the
    # most common install failure, and otherwise visible only as a traceback
    # at serve time.
    #
    # Facts now, checks later, because `Report.exit_code` returns the FIRST
    # failure and must therefore agree with the order `main` fails in: dirs
    # and usage conflicts are decided before any Python runs. Recording the
    # interpreter check here instead made `--workers 2 --threads 2` report
    # 78 where the server exits 2.
    var py_ok = False
    var py_version = String("")
    var py_ft_build = False
    var py_gil = True
    var py_error = String("")
    try:
        var py = probe_free_threading()
        py_ok = True
        py_version = py.version
        py_ft_build = py.free_threaded_build
        py_gil = py.gil_enabled
        report.add_fact(String("python"), String("version"), py.version)
        report.add_bool(
            String("python"), String("free_threaded_build"),
            py.free_threaded_build,
        )
        report.add_bool(String("python"), String("gil_enabled"), py.gil_enabled)
        try:
            var builtins = Python.import_module("builtins")
            var ns = Python.dict()
            builtins.exec(PythonObject(_DOCTOR_PROBE), ns)
            var where = ns["where"]()
            report.add_fact(
                String("python"), String("executable"), String(py=where[0])
            )
            report.add_fact(
                String("python"), String("prefix"), String(py=where[1])
            )
            report.add_fact(
                String("python"), String("machine"), String(py=where[2])
            )
            report.add_fact(
                String("python"), String("implementation"), String(py=where[3])
            )
        except:
            pass  # the version facts above are the load-bearing ones
    except e:
        py_error = String(e)

    _doctor_dirs(report, opts)
    _doctor_conflicts(report, opts)

    # Python enters here, in `main`'s order: after every check that needs no
    # interpreter at all.
    var threads_ok = True
    if py_ok:
        report.pass_check(
            String("interpreter"), "CPython " + py_version + " resolved"
        )
        # 78 only when a threaded mode was actually asked for -- that is
        # `require_free_threading`'s own rule, and the doctor must not
        # invent a refusal the server would not make.
        if opts.threads > 1:
            if py_gil:
                threads_ok = False
                report.fail_check(
                    String("free-threading"),
                    "--threads " + String(opts.threads)
                    + " requires free-threaded CPython with the GIL disabled;"
                    + (
                        " this is not a free-threaded build"
                        if not py_ft_build
                        else " the GIL is enabled (PYTHON_GIL=1?)"
                    ),
                    String(
                        "use --workers N instead, or run on 3.14t with"
                        " PYTHON_GIL=0"
                    ),
                    EXIT_NOT_FREE_THREADED,
                )
            else:
                report.pass_check(
                    String("free-threading"),
                    String("interpreter is free-threaded and the GIL is off"),
                )
    else:
        threads_ok = False
        report.fail_check(
            String("interpreter"),
            "could not initialize CPython: " + py_error,
            String(
                "run m0serve from a virtualenv whose python3 is on PATH, or"
                " set MOJO_PYTHON_LIBRARY to the libpython to load"
            ),
            EXIT_STARTUP,
        )

    # The application. Skipped -- not failed -- when there is nothing to
    # load: `m0serve --doctor` with no MODULE is the "is this environment
    # sane" call, and reporting a missing app as a defect would make the
    # useful invocation always exit non-zero.
    var have_app = opts.module.byte_length() > 0 or len(opts.mount_prefixes) > 0
    var is_asgi = False
    var resolved = False
    if not have_app:
        report.add_bool(String("application"), String("requested"), False)
    elif not threads_ok:
        # The interpreter is unusable or refused; an import would only
        # produce a second, derivative failure.
        report.add_bool(String("application"), String("requested"), True)
        report.add_fact(
            String("application"), String("resolved"), String("skipped")
        )
    else:
        report.add_bool(String("application"), String("requested"), True)
        try:
            if opts.app_dir.byte_length() > 0 and isdir(opts.app_dir):
                prepend_to_path(opts.app_dir)
            if len(opts.mount_prefixes) > 0:
                is_asgi = _resolve_mounts(opts)
            else:
                is_asgi = _resolve_spec(opts)
            resolved = True
        except e:
            report.fail_check(
                String("application"),
                "could not load " + opts.served() + " from " + opts.app_dir
                + ": " + String(e),
                String(
                    "check --app-dir and the MODULE[:ATTR] spec; a bare"
                    " MODULE also tries MODULE.asgi, MODULE.wsgi, MODULE:app"
                    " and MODULE.main:app"
                ),
                EXIT_STARTUP,
            )
        if resolved:
            report.add_fact(
                String("application"), String("spec"), opts.served()
            )
            report.add_fact(
                String("application"),
                String("protocol"),
                String("asgi") if is_asgi else String("wsgi"),
            )
            report.add_bool(
                String("application"),
                String("protocol_forced"),
                opts.protocol != String("auto"),
            )
            if len(opts.mount_prefixes) > 0:
                var mounts = String("[")
                for i in range(len(opts.mount_prefixes)):
                    if i > 0:
                        mounts += ","
                    var prefix = opts.mount_prefixes[i]
                    var mount_asgi = False
                    for k in range(len(opts.asgi_mounts)):
                        if opts.asgi_mounts[k] == i:
                            mount_asgi = True
                            break
                    mounts += '{"prefix":"' + (
                        prefix if prefix.byte_length() > 0 else String("/")
                    ) + '","spec":"' + opts.mount_modules[i] + ":"
                    mounts += opts.mount_attributes[i] + '","protocol":"'
                    mounts += (
                        String("asgi") if mount_asgi else String("wsgi")
                    ) + '"}'
                mounts += "]"
                report.add_raw(
                    String("application"), String("mounts"), mounts
                )
            report.pass_check(
                String("application"),
                opts.served() + " imports and classifies as "
                + (String("asgi") if is_asgi else String("wsgi")),
            )
            # The two refusals that need the detected protocol -- the same
            # pair main makes right after its own resolve, at EXIT_STARTUP.
            if opts.realtime and _realtime_without_wsgi(opts, is_asgi):
                report.fail_check(
                    String("realtime-vs-asgi"),
                    String(_REALTIME_ASGI_CONFLICT),
                    String("drop --realtime; an ASGI app streams natively"),
                    EXIT_STARTUP,
                )

    # Topology, resolved the way the server resolves it -- which needs the
    # protocol, hence its place after the import. Without a resolved app the
    # requested values are reported and `resolved` says so.
    var cpus = effective_cpus()
    report.add_int(String("topology"), String("cpus"), cpus)
    report.add_int(
        String("topology"), String("performance_cpus"), performance_cpus()
    )
    # What the MACHINE has online, and what this PROCESS may use, are
    # different numbers in a container and only the second is actionable
    # (`usable_cpus`). Reported beside each other rather than one replacing
    # the other: `cpus` has always meant the machine, and a diagnostic that
    # silently changes what a field means is worse than one that adds a
    # field. Equal on an unconstrained host.
    report.add_int(String("topology"), String("usable_cpus"), usable_cpus())
    report.add_bool(String("topology"), String("qos"), opts.qos)
    report.add_int(String("topology"), String("workers"), opts.workers)
    report.add_fact(
        String("topology"), String("worker_mode"),
        String("spawn") if opts.spawn_workers else String("fork"),
    )
    report.add_bool(
        String("topology"), String("accept_sharing"), accept_sharing_wanted(opts)
    )
    report.add_int(String("topology"), String("threads"), opts.threads)
    if resolved:
        var auto_pool = zero_config_topology(opts)
        var blocking = resolve_blocking_threads(opts, is_asgi, pool_cpus())
        var executor = use_asgi_executor(opts, is_asgi)
        report.add_int(
            String("topology"), String("blocking_threads"), blocking
        )
        report.add_fact(
            String("topology"),
            String("blocking_threads_source"),
            String("default") if auto_pool else String("configured"),
        )
        report.add_bool(String("topology"), String("asgi_executor"), executor)
        # The refusal main makes right after the same decision, at 78:
        # the executor's Python type cannot be built on a free-threaded
        # build (modular/modular#5726). A probe that itself fails invents
        # no refusal; the interpreter check above already spoke.
        if executor:
            try:
                var ft = probe_free_threading()
                if ft.free_threaded_build:
                    report.fail_check(
                        String("asgi-vs-free-threading"),
                        asgi_free_threading_refusal(ft),
                        String(
                            "run this application on a GIL-enabled CPython"
                            " (3.10-3.14 without the t suffix), with"
                            " --workers for concurrency"
                        ),
                        EXIT_NOT_FREE_THREADED,
                    )
            except:
                pass
        var mode: String
        if opts.threads > 1:
            mode = String("threads")
        elif opts.workers > 1:
            mode = String("prefork")
        else:
            mode = String("single")
        report.add_fact(String("topology"), String("mode"), mode)
        # WHICH LOOP, which `mode` does not say: it answered `single` for
        # the pump and for the inversion alike, so the two shapes were
        # indistinguishable from outside the process and only the startup
        # banner told you which one you had. `use_loop_inversion` is the
        # same predicate `main` branches on, so this cannot drift from what
        # actually runs. "n/a" where no executor serves the application at
        # all (WSGI, or an explicit pool).
        var loop_shape: String
        if not executor:
            loop_shape = String("n/a")
        elif use_loop_inversion(opts, executor, blocking):
            loop_shape = String("inverted")
        else:
            loop_shape = String("pump")
        report.add_fact(String("topology"), String("loop"), loop_shape)
    else:
        report.add_int(
            String("topology"),
            String("blocking_threads"),
            opts.blocking_threads,
        )
        report.add_bool(String("topology"), String("resolved"), False)

    report.add_fact(String("server"), String("host"), opts.host)
    report.add_int(String("server"), String("port"), opts.port)
    report.add_fact(String("server"), String("app_dir"), opts.app_dir)
    report.add_bool(String("server"), String("access_log"), opts.access_log)
    report.add_bool(String("server"), String("metrics"), opts.metrics)
    report.add_bool(String("server"), String("realtime"), opts.realtime)
    report.add_bool(String("server"), String("reload"), opts.reload)
    report.add_fact(
        String("server"), String("health_path"), opts.health_path
    )
    report.add_int(String("server"), String("max_body"), opts.max_body)
    report.add_int(
        String("server"), String("max_keepalive_requests"),
        opts.max_keepalive_requests,
    )
    report.add_int(
        String("server"), String("idle_timeout"), opts.idle_timeout
    )
    var statics = String("[")
    for i in range(len(opts.static_prefixes)):
        if i > 0:
            statics += ","
        statics += '{"prefix":"' + opts.static_prefixes[i] + '","dir":"'
        statics += opts.static_dirs[i] + '"}'
    statics += "]"
    report.add_raw(String("server"), String("static"), statics)

    print(report.render(), flush=True)
    return report.exit_code()


def main() raises:
    var args = List[String]()
    var raw = argv()
    for i in range(1, len(raw)):
        args.append(String(raw[i]))

    var opts: ServeOptions
    try:
        opts = parse_args(args, ServeOptions.from_env())
    except e:
        print(usage(), flush=True)
        _fail(String(e), EXIT_USAGE)
        return
    if opts.show_help:
        print(usage(), flush=True)
        return
    if opts.show_version:
        print("m0serve " + M0SERVE_VERSION, flush=True)
        return
    # Before the directory checks below, because those `_fail` on the first
    # problem and the doctor's job is to report all of them at once.
    if opts.show_doctor:
        process_exit(_run_doctor(opts))
        return

    # Everything checkable without an interpreter, checked before the bind.
    if not isdir(opts.app_dir):
        _fail("app dir does not exist: " + opts.app_dir, EXIT_STARTUP)
    for i in range(len(opts.static_dirs)):
        if not isdir(opts.static_dirs[i]):
            _fail("static dir does not exist: " + opts.static_dirs[i], EXIT_STARTUP)
    for i in range(len(opts.reload_dirs)):
        if not isdir(opts.reload_dirs[i]):
            _fail("reload dir does not exist: " + opts.reload_dirs[i], EXIT_STARTUP)

    var conflict = threads_conflict(opts.workers, opts.threads)
    if conflict:
        print(usage(), flush=True)
        _fail(conflict.value(), EXIT_USAGE)

    # `--blocking-threads` moves `func` onto a pool thread, but the streaming
    # hooks — `sse_drain_slot`, `sse_slot_disconnected`, `ws_message` — are
    # called on the LOOP's handler, which owns a different `SSERegistry` and a
    # different `WSHub`. A stream opened by a pool thread's handler would be
    # invisible to the loop that has to feed it. Refused rather than half-wired,
    # which is the same call `--threads` makes about a GIL-enabled interpreter.

    # The forced half of the ASGI/realtime refusal is checkable without an
    # interpreter; the auto-detected half fails after the app loads, with
    # the same message.
    if opts.protocol == PROTOCOL_ASGI and opts.realtime:
        print(usage(), flush=True)
        _fail(_REALTIME_ASGI_CONFLICT, EXIT_USAGE)

    # Bind before forking; every worker accepts from this one socket.
    var listener = _listen_or_fail(opts)

    # Then everything `--realtime` shares, still before the fork and still
    # before the first Python call. Inert without the flag.
    var channels = opts.threads if opts.threads > 1 else opts.workers
    var bus = _prepare_realtime(opts, channels)
    var share = _prepare_accept_share(opts)

    # Fork before touching Python — see the module docstring. The parent
    # stays inside fork_all() supervising; only workers return here.
    #
    # `--reload` forces a supervisor even for one worker and even under
    # `--threads`, because something has to outlive the process it
    # restarts. That is safe for exactly the reason the prefork rule is:
    # the supervisor never touches Python. It watches files with `listdir`
    # and `stat`, which are libc, and a process forked without `exec` may
    # use those. `--threads` and `--workers>1` are mutually exclusive, so
    # `opts.workers` is 1 under threads and the supervisor manages the one
    # multi-threaded child.
    var multiprocess = opts.workers > 1
    var supervised = multiprocess or opts.reload
    var worker = 0
    # A spawned worker is a supervised process that must NOT supervise: its
    # parent already does, and it serves the index it was exec'd with.
    var spawned = spawned_worker_index()
    if spawned >= 0:
        supervised = False
        worker = spawned
    if opts.reload:
        # Set before the fork and before the first Python call, because the
        # interpreter reads it once at startup.
        #
        # Without it `--reload` can serve stale code, and the way it does is
        # not obvious. CPython validates a cached `.pyc` against the source's
        # mtime **in whole seconds** and its size; a rewrite that lands in
        # the same second at the same length therefore looks unchanged to the
        # import system even though the file on disk is different. The
        # reloader notices (it compares nanoseconds), re-forks, and the fresh
        # worker imports the *old* bytecode — a reload that visibly happened
        # and changed nothing. Writing no bytecode at all means there is
        # never a cache to go stale. The cost is slower imports on a
        # development-only flag.
        _ = setenv("PYTHONDONTWRITEBYTECODE", "1", True)
    if supervised:
        var supervisor = WorkerSupervisor(opts.workers)
        if opts.reload:
            supervisor.enable_reload(_reload_dirs(opts), String(".py"))
        if opts.spawn_workers:
            # The worker re-runs THIS argv in a fresh image; the listener,
            # the bus and the shared page reach it by fd through the env
            # exports above. `executable_path` rather than argv[0], which
            # may be a bare name or relative to a cwd the worker keeps.
            var full_argv = List[String]()
            for i in range(len(raw)):
                full_argv.append(String(raw[i]))
            supervisor.enable_spawn(executable_path(), full_argv^)
        supervisor.fork_all()
        worker = supervisor.worker_index
    # Accept sharing binds to this worker's index; inert with one worker
    # (`--threads` included), so a single-worker server pays nothing.
    _bind_accept_share(share, worker)

    if opts.threads > 1:
        # The listener is borrowed, not reduced to its fd: its last use would
        # otherwise be that read, and Mojo's destroy-at-last-use would close
        # the listening socket before the threads dup it — the dup then lands
        # on whatever descriptor number the kernel recycled, and four loops
        # watch a pipe. Prefork never hits this because `serve_nonblocking`
        # uses the listener itself, later.
        _serve_threaded(opts, listener, bus)
        if supervised:
            # Forked, so it must leave through `exit_worker()` — returning
            # from `main` runs a teardown that reaches into libdispatch.
            exit_worker()
        return

    # The first Python call in this process: put --app-dir on sys.path and
    # resolve the spec + protocol, WITHOUT building a bridge — the executor
    # decision below needs the protocol before any lifespan may run.
    var is_asgi: Bool
    try:
        if opts.app_dir.byte_length() > 0:
            prepend_to_path(opts.app_dir)
        if len(opts.mount_prefixes) > 0:
            is_asgi = _resolve_mounts(opts)
        else:
            is_asgi = _resolve_spec(opts)
    except e:
        _fail(
            "could not load " + opts.served() + " from " + opts.app_dir + ": "
            + String(e),
            EXIT_STARTUP,
        )
        return

    if len(opts.mount_prefixes) > 0 and not has_python_mount(opts):
        # Every mount is compiled in (`mojo`, `hold`), so this binary is
        # hosting no Python at all — and m0serve exists to host Python.
        # Write a Mojo server binary instead; `apps/pool_spike` is the
        # shape. Refused rather than served, because `WSGIHandler.build`
        # has no application to build and the process would carry an
        # interpreter for nothing.
        _fail(
            "every --mount is 'mojo' or 'hold', so there is no Python"
            " application to host; write a Mojo server binary instead of"
            " using m0serve",
            EXIT_USAGE,
        )
        return

    if len(opts.hold_mounts) > 0 and not opts.realtime:
        _fail(_HOLD_MOUNT_NEEDS_REALTIME, EXIT_USAGE)
        return
    if len(opts.hold_mounts) > 0 and getenv(GRANT_KEY_ENV, "").byte_length() == 0:
        _fail(_HOLD_MOUNT_NEEDS_KEY, EXIT_USAGE)
        return

    if opts.realtime and _realtime_without_wsgi(opts, is_asgi):
        _fail(_REALTIME_ASGI_CONFLICT, EXIT_STARTUP)

    # Zero-config: with no topology flag or M0_* topology variable at all,
    # the protocol picks the concurrency — a pool for WSGI, the asyncio
    # executor for ASGI. Detection had to run first, which is why this
    # sits after the resolve (and, under prefork, inside each worker;
    # every worker resolves the same app to the same answer).
    var auto_pool = zero_config_topology(opts)
    opts.blocking_threads = resolve_blocking_threads(
        opts, is_asgi, pool_cpus()
    )
    var executor_mode = use_asgi_executor(opts, is_asgi)
    _refuse_executor_on_free_threaded(executor_mode)
    # In executor mode the loop's own handler is the queue-overflow
    # fallback: its bridge gets a loop but no lifespan, so the executor's
    # app owns the one lifespan this process runs. Its registries do size
    # up, though — they are the outboxes ASGI response chunks ride.
    opts.handler_lifespan = not executor_mode
    # Registries size up wherever the chunk channel will exist: for the
    # executor's ASGI streams, and for the WSGI iterables a handler pool
    # streams through the same channel.
    opts.asgi_streaming = executor_mode or opts.blocking_threads > 0

    var handler: WSGIHandler
    try:
        handler = WSGIHandler.build(
            opts,
            multiprocess=multiprocess,
            multithread=False,
            lifespan=not executor_mode,
        )
    except e:
        _fail(
            "could not load " + opts.served() + " from " + opts.app_dir + ": "
            + String(e),
            EXIT_STARTUP,
        )
        return

    print(
        "🔥 m0serve: " + opts.served() + " on http://" + opts.address()
        + " (protocol=" + ("asgi" if is_asgi else "wsgi")
        + " workers=" + String(opts.workers) + ")"
        + (
            (" asgi-loop@" + asgi_mount_names(opts))
            if (executor_mode and len(opts.asgi_mounts) > 0)
            else (" asgi-loop" if executor_mode else "")
        )
        + (
            " blocking-threads=" + String(opts.blocking_threads)
            + (" (auto)" if auto_pool else "")
            if opts.blocking_threads > 0 else ""
        )
        + (" realtime" if opts.realtime else "")
        + (" reload" if opts.reload else "")
        + (" spawn" if opts.spawn_workers and opts.workers > 1 else "")
        + (" shared-accepts" if share.active() else ""),
        flush=True,
    )
    var server_config = opts.server_config(AppConfig(default_port=DEFAULT_PORT))
    # After fork_all — each worker arms its own pipe.
    var shutdown_fd = install_shutdown_signals()

    var mounted_mix = (
        len(opts.mount_prefixes) > 0 and len(opts.asgi_mounts) > 0
    )
    if executor_mode or opts.blocking_threads > 0 or mounted_mix:
        # Offloaded serving under prefork: this process gets one acceptor
        # loop and either the asyncio executor (ASGI) or a handler pool.
        # The threads are spawned AFTER `fork_all()` returned and after the
        # resolve above made this process's first Python call, so the
        # prefork rule is untouched — a forked child that then makes
        # threads is fine; a threaded parent that then forks is not.
        _serve_offloaded(
            opts, listener, handler, server_config, shutdown_fd,
            executor_mode,
            asgi_lanes=opts.asgi_mounts.copy(),
            wsgi_lanes=wsgi_lanes(opts),
            peer_bus_fd=bus.read_fd(worker),
            # Under `--realtime` a pool thread's hold reaches THIS worker's
            # loop through this worker's own channel — `m0pub` writes every
            # channel, a hold must write exactly one: slot numbers are
            # this loop's.
            hold_notify_fd=(
                bus.write_fds[worker]
                if (opts.realtime and worker >= 0 and worker < len(bus.write_fds))
                else -1
            ),
            accept_share=share,
        )
        # The loop's own handler serves the inline fallback; in executor
        # mode its lifespan never ran, and shutdown just closes its loop.
        handler.shutdown()
        if supervised:
            exit_worker()
        return

    var server = Server(server_config^)
    # `bus.read_fd` answers -1 off the flag, which is what "no bus" means to
    # the loop. Passed unconditionally under `--realtime`, single worker
    # included: draining our own channel IS local delivery, because `m0pub`
    # writes every channel including the publisher's. There is no second
    # delivery path to keep in sync with this one.
    if opts.qos:
        _ = request_qos_class(QOS_CLASS_USER_INTERACTIVE)
    server.serve_nonblocking(
        listener, handler,
        shutdown_read_fd=shutdown_fd,
        bus_read_fd=bus.read_fd(worker),
        accept_share=share,
    )
    handler.shutdown()
    if supervised:
        exit_worker()


def _serve_offloaded(
    opts: ServeOptions,
    listener: NoTLSListener[NetworkType.tcp4],
    mut handler: WSGIHandler,
    config: ServerConfig,
    shutdown_fd: Int,
    executor: Bool,
    var asgi_lanes: List[Int] = List[Int](),
    var wsgi_lanes: List[Int] = List[Int](),
    peer_bus_fd: Int = -1,
    hold_notify_fd: Int = -1,
    accept_share: AcceptShare = AcceptShare(),
) raises:
    """One acceptor loop feeding either a handler pool or the executor.

    `--blocking-threads N` (WSGI, or the ASGI escape hatch) puts N handler
    threads behind the loop; `executor` puts the one asyncio-executor
    thread there instead — both speak the same `OffloadPool`, so the loop
    is identical either way.

    `Server.serve_nonblocking` is bypassed for one reason — the loop thread
    serves with NO thread state (docs/notes/detached-loop.md). It runs no
    Python except the inline fallback, which `WSGIHandler.func` attaches
    around for itself. Attached, it re-acquired the GIL after every wait
    and was blocked in that acquire 36–45 % of wall time under load, so the
    executor's and the pool's Python never overlapped its own parsing and
    writing; detached, the executor and pool rows ran +50–100 %.
    `M0_LOOP_ATTACHED=1` restores the old shape for an A/B.

    With `--mount`, both run AT ONCE: `asgi_lanes` names the mounts that
    get an executor each and `wsgi_lanes` the mounts the pool threads
    serve, so sync applications and async ones share this loop, this
    listener and this shutdown while each keeps its native concurrency.
    That is the whole point of mounts, and it is only expressible because
    a lane is a submit channel rather than a mode for the process.

    Several executors share ONE chunk channel — datagrams are
    slot-addressed and the queue is globally FIFO, so the recycled-slot
    safety argument survives two writers — but each gets its own drain-ack
    pair (`enable_stream_ack`): credit belongs to the executor that owns
    the slot, and an ack routed anywhere else is a stream stalled forever.

    `peer_bus_fd` is this worker's BroadcastBus channel (M0_WORKERS>1),
    registered beside the chunk channel: GRIP-named frames on it are
    forwarded to the executors for `state["m0"]` subscribers. `--realtime`
    composes with the pool (`hold_notify_fd`: a pool thread's hold reaches
    this loop's registries as a reserved frame on this loop's own bus
    channel) and is still refused with the executor and with `--mount`.
    """
    var pool = OffloadPool(config.max_connections)
    # Without a GIL a parked thread beside a queued job is an idle core,
    # so the pool wakes eagerly there (`OffloadPool.parallel`). A Python
    # call, startup-only, on the worker's attached main thread — after
    # the process's first.
    pool.set_parallel(not probe_free_threading().gil_enabled)
    # The loop's handler needs the pool for one thing only: a chunk frame
    # its outbox has to refuse must abort the stream rather than vanish.
    # See `WSGIHandler.abort_pool_addr`.
    handler.set_abort_pool(pool.addr())
    if hold_notify_fd >= 0:
        pool.set_hold_notify(hold_notify_fd)
    var mounted = len(opts.mount_prefixes) > 0
    if mounted:
        # Lane i is mount i, so the loop's `submit(slot, path)` and the
        # handler's `app_for(path)` cannot disagree: both ask
        # `match_path_prefix` the same question about the same table.
        for i in range(len(opts.mount_prefixes)):
            pool.add_lane(opts.mount_prefixes[i])
    var mojo_ln = mojo_lanes(opts)
    var hold_ln = hold_lanes(opts)
    var pool_count = (
        opts.blocking_threads
        if (len(wsgi_lanes) > 0 or not executor) else 0
    )
    if mounted and len(wsgi_lanes) == 0:
        # No WSGI mount: no WSGI pool. Without this the pool starts with an
        # empty lane list, `BlockingPool.start` deals every thread lane -1,
        # and -1 is lane 0 — which on a Mojo-only mounted server is the Mojo
        # mount's lane. Its jobs would be taken by threads holding a
        # `WSGIHandler` for an application that was never imported.
        pool_count = 0
    if use_loop_inversion(opts, executor, pool_count) and not mounted:
        # M0_INVERTED: the loop inversion, on one thread. Unmounted,
        # pool-free ASGI only -- the benchmark shape -- and behind the
        # variable until its gate passes (docs/ROADMAP.md, "The loop
        # inversion"), so the A/B against the pump is one env var. Every
        # other topology stays on the pump below.
        #
        # Known limitation, measured 2026-08-29 and recorded rather than
        # fixed: the drain is the blocking first cut, so a request that
        # is mid-await at SIGTERM is answered at the 5 s drain deadline
        # (5.30 s for a 1.5 s request; the pump answers it at 1.50 s).
        # Give an inverted server a stop grace of 10 s or more. The
        # reshaped drain is ROADMAP design item 6, deferred to the
        # inversion's promotion bar.
        pool.enable_stream_channel()
        pool.enable_base_stream_ack()
        serve_inverted(
            opts, listener.socket.fd, config, opts.address(), shutdown_fd,
            pool, peer_bus_fd, accept_share,
        )
        return
    var pool_threads = BlockingPool(0 if (executor and not mounted) else pool_count)
    var exec_thread = AsgiExecutor(
        len(asgi_lanes) if len(asgi_lanes) > 0 else 1
    )
    var opts_ptr = Pointer(to=opts)
    var opts_addr = Pointer(to=opts_ptr).unsafe_bitcast[Int]()[]
    var run_executor = executor or len(asgi_lanes) > 0
    if run_executor:
        # The streaming channels exist before any executor thread does, so
        # their fds are plain fields by the time anything reads them; the
        # shared chunk pair's read end is this loop's bus fd, and the
        # handler learns where to send each lane's disconnect tags — on
        # that mount's own submit channel, since that is where its
        # executor is parked.
        pool.enable_stream_channel()
        pool.enable_base_stream_ack()
        # The pump: the loop thread keeps its per-pass outbox sweep even
        # with no stream open, because the microsecond it costs is what
        # lets a pass batch submits (offload.mojo, `sweeps_every_pass`).
        pool.set_sweep_every_pass()
        if len(asgi_lanes) == 0:
            handler.set_asgi_notify(pool.submit_write_fd(-1))
        for k in range(len(asgi_lanes)):
            var lane = asgi_lanes[k]
            pool.enable_stream_ack(lane)
            handler.set_lane_notify(lane, pool.submit_write_fd(lane))
        exec_thread.start(pool.addr(), opts_addr, asgi_lanes.copy(), qos=opts.qos)
    if pool_threads.count > 0 and not pool.chunk_active():
        # Pool threads stream WSGI iterables through the same chunk channel
        # the executor uses — a second producer on one FIFO — so a
        # pure-WSGI pool server creates it too. NOT the executor's ack
        # pair: `stream_active()` keeps meaning "an executor exists", which
        # is what keeps an M0-Hold on this loop from being mistaken for a
        # channel stream.
        pool.enable_stream_channel()
    if pool_threads.count > 0:
        # Where an inbound WebSocket message goes when a pool thread's view
        # held the socket: that mount's own submit lane, so the frame is
        # served by a thread that has that urlconf and no other. Read before
        # the lanes are moved into `start`.
        if opts.realtime:
            if len(wsgi_lanes) == 0:
                handler.set_ws_pool_notify(-1, pool.submit_write_fd(-1))
            for wl in range(len(wsgi_lanes)):
                handler.set_ws_pool_notify(
                    wsgi_lanes[wl], pool.submit_write_fd(wsgi_lanes[wl])
                )
        pool_threads.start[WSGIHandler](
            pool.addr(), opts_addr, wsgi_lanes^, qos=opts.qos
        )
    # The Mojo mount's workers. They are started like the WSGI pool and are
    # unlike it in the one way that matters: `MojoPool`'s body has no
    # attach/detach bracket, because there is nothing to attach to. A job on
    # one of these lanes never touches the interpreter, which is what lets
    # this mount answer while every Python thread is behind the GIL.
    var mojo_threads = MojoPool(
        opts.blocking_threads if len(mojo_ln) > 0 else 0
    )
    if mojo_threads.count > 0:
        mojo_threads.start[MojoMount](
            pool.addr(), user=0, lanes=mojo_ln.copy()
        )
    # The hold mount's workers: the same pool shape, a different handler
    # type. Two `MojoPool`s rather than one because `start[T]` is generic
    # over the handler, and each lane is dealt only its own kind.
    var hold_threads = MojoPool(
        opts.blocking_threads if len(hold_ln) > 0 else 0
    )
    if hold_threads.count > 0:
        hold_threads.start[HoldMount](
            pool.addr(), user=0, lanes=hold_ln.copy()
        )

    var stream_bus_fd = pool.stream_chunk_read if pool.chunk_active() else -1

    # The loop releases its thread state here and takes it back only after
    # `run_event_loop` returns. Everything the loop does in between is Mojo;
    # `WSGIHandler.func` attaches for itself on the inline fallback. The
    # detached wait below is then a plain wait. Attached (M0_LOOP_ATTACHED=1,
    # the A/B knob) is the pre-0.18 shape: re-attach after every wait.
    var loop_attached = getenv("M0_LOOP_ATTACHED", "") == "1"
    ref cpy0 = Python().cpython()
    if not loop_attached:
        handler.set_attach_in_func()
    var loop_ts = cpy0.PyEval_SaveThread()
    if loop_attached:
        cpy0.PyEval_RestoreThread(loop_ts)

    if opts.qos:
        _ = request_qos_class(QOS_CLASS_USER_INTERACTIVE)
    var backend = DetachingBackend[PlatformBackend](PlatformBackend())
    if not loop_attached:
        backend.set_loop_detached()
    run_event_loop(
        listener.socket.fd, handler, backend, config, opts.address(), True,
        shutdown_fd, stream_bus_fd, pool.addr(),
        peer_bus_fd=peer_bus_fd,
        accept_share=accept_share,
    )
    if not loop_attached:
        cpy0.PyEval_RestoreThread(loop_ts)

    # Detached across it, for the reason the pool body details: a thread
    # finishing its last job (or the executor draining its tasks) has to
    # attach, and it cannot while this thread holds a state and blocks in
    # `pthread_join`.
    ref cpy = Python().cpython()
    var join_ts = cpy.PyEval_SaveThread()
    var failed = 0
    var stuck = 0
    if run_executor:
        failed += exec_thread.stop_and_join(pool, JOIN_TIMEOUT_NS)
        stuck += exec_thread.stragglers
    if pool_threads.count > 0:
        failed += pool_threads.stop_and_join(pool, JOIN_TIMEOUT_NS)
        stuck += pool_threads.stragglers
    if mojo_threads.count > 0:
        # Pills go per lane, so a Mojo thread parked on lane 2 is not woken
        # by one sent to lane 0. `MojoPool.stop_and_join` sends its own.
        failed += mojo_threads.stop_and_join(pool, JOIN_TIMEOUT_NS)
        stuck += mojo_threads.stragglers
    if hold_threads.count > 0:
        failed += hold_threads.stop_and_join(pool, JOIN_TIMEOUT_NS)
        stuck += hold_threads.stragglers
    if stuck > 0:
        # A thread still inside the application after the drain AND the join
        # budget is not coming back: a response that never ends (an SSE
        # generator served buffered under WSGI; docs/REAL_APP_VALIDATION.md)
        # holds it for the life of the process. Nothing here can unwind
        # Python on another thread, so leave the way a forked worker does --
        # `_exit`, no teardown -- with every connection the loop could answer
        # already answered. The alternative was a SIGTERM that did nothing
        # until `docker stop` gave up and sent SIGKILL, which is what it did.
        print(
            "m0serve: " + String(stuck) + " handler thread(s) still inside the"
            " application " + String(JOIN_TIMEOUT_NS // 1_000_000_000)
            + " s after the drain; exiting without them",
            flush=True,
        )
        process_exit(0)
    cpy.PyEval_RestoreThread(join_ts)
    if failed > 0:
        print(
            String(failed) + " offload thread(s) did not exit cleanly",
            flush=True,
        )
    # `pool` must outlive the join: a thread still finishing a job writes into
    # it. This use is what stops destroy-at-last-use freeing it above.
    _ = pool.capacity


def _serve_threaded(
    mut opts: ServeOptions,
    listener: NoTLSListener[NetworkType.tcp4],
    bus: BroadcastBus,
) raises:
    """`--threads N`: N event loops on N threads, one interpreter.

    The order here is the threaded mode's load-bearing part, the mirror
    image of the prefork rule above. The interpreter comes up on THIS
    thread (`require_free_threading` is the first Python call, and the
    place a GIL-enabled interpreter is refused), the application is
    imported once here so Django's `setup()` runs single-threaded, the
    signal pipe is armed once for the process — and only then does
    `ThreadedServer.serve` detach this thread and spawn the loops, each of
    which builds its own `WSGIHandler` from `opts` via `WSGIHandler.make`.
    No fork, so `main` returns normally.

    Under `--realtime` each thread also drains its own bus channel, exactly
    as a worker drains its own. `bus` was built on the main thread before
    any of this, so `M0_BUS_WRITE_FDS` is already in the environment the
    interpreter is about to snapshot, and `m0pub` reaches N threads with the
    same N `os.write`s it used to reach N processes — it never learns which
    it is talking to.
    """
    require_free_threading(opts.threads)
    if opts.app_dir.byte_length() > 0:
        prepend_to_path(opts.app_dir)
    # Import once on main (so Django's setup() runs single-threaded) and
    # detect the protocol while at it — the imports below are sys.modules
    # hits for every serving thread.
    var is_asgi: Bool
    try:
        if len(opts.mount_prefixes) > 0:
            is_asgi = _resolve_mounts(opts)
        else:
            is_asgi = _resolve_spec(opts)
    except e:
        _fail(
            "could not load " + opts.served() + " from " + opts.app_dir + ": "
            + String(e),
            EXIT_STARTUP,
        )
        return
    if opts.realtime and _realtime_without_wsgi(opts, is_asgi):
        _fail(_REALTIME_ASGI_CONFLICT, EXIT_STARTUP)
    var auto_pool = zero_config_topology(opts)
    opts.blocking_threads = resolve_blocking_threads(
        opts, is_asgi, pool_cpus()
    )
    var executor_mode = use_asgi_executor(opts, is_asgi)
    # `--threads` REQUIRES a free-threaded build, and the executor cannot
    # run on one: an ASGI application under --threads is refused here on
    # this toolchain, whatever the thread count.
    _refuse_executor_on_free_threaded(executor_mode)
    # Each serving thread's own loop handler is only the fallback in
    # executor mode; the one lifespan per loop belongs to that loop's
    # executor. Registries size up for the chunk outboxes — the executor's
    # ASGI streams and the pool's streamed WSGI iterables alike.
    opts.handler_lifespan = not executor_mode
    opts.asgi_streaming = executor_mode or opts.blocking_threads > 0

    var shutdown_fd = install_shutdown_signals()
    var opts_ptr = Pointer(to=opts)
    var opts_addr = Pointer(to=opts_ptr).unsafe_bitcast[Int]()[]
    print(
        "🔥 m0serve: " + opts.served() + " on http://" + opts.address()
        + " (protocol=" + ("asgi" if is_asgi else "wsgi")
        + " threads=" + String(opts.threads) + ")"
        + (
            (" asgi-loop@" + asgi_mount_names(opts))
            if (executor_mode and len(opts.asgi_mounts) > 0)
            else (" asgi-loop" if executor_mode else "")
        )
        + (
            " blocking-threads=" + String(opts.blocking_threads)
            + (" (auto)" if auto_pool else "")
            if opts.blocking_threads > 0 else ""
        )
        + (" realtime" if opts.realtime else "")
        + (" reload" if opts.reload else ""),
        flush=True,
    )
    var server = ThreadedServer(
        opts.server_config(AppConfig(default_port=DEFAULT_PORT)),
        opts.address(),
        listener.socket.fd.value,
    )
    server.blocking_threads = opts.blocking_threads
    server.asgi_executor = executor_mode
    for i in range(bus.size()):
        server.bus_read_fds.append(bus.read_fd(i))
        server.bus_write_fds.append(bus.write_fds[i])
    var failed = server.serve[WSGIHandler](opts.threads, opts_addr, shutdown_fd)
    # `listener` must outlive `serve`; this use is what keeps it alive.
    _ = listener.socket.fd.value
    if failed > 0:
        process_exit(EXIT_STARTUP)
