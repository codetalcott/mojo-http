"""The Mojo host: everything in a Mojo application's `main` that is not the application.

    def main() raises:
        serve[MyHandler, MyProducer](AppConfig())

Every Mojo app with more than one process, or a thread of its own, used to
write the same forty to a hundred lines of startup by hand, re-derived from
comments, and the reference apps got them wrong: a bus joined only above one
worker, a producer handed one worker's channel, no accept sharing at all. The
rules those lines obey are this repo's hardest-won (CLAUDE.md, "Runtime
constraints"), so `serve` owns them and an application cannot spell them
wrong. In this order:

1. **Refuse what it does not serve** (`host_refusal`): `M0_THREADS` and
   `M0_SPAWN_WORKERS` are m0serve's, and a variable the host silently
   ignored would be a configuration that reads as applied; and more workers
   than `AppHandler.max_workers()` allows, for an application whose state
   lives in one process. Exit 78, before anything is bound.
2. **Listen**, once, in the process that will fork.
3. **The shared pages**, before the fork. The host's own page is
   m0serve's, made by the same function (`m0_http.prefork.prefork_page`):
   slot 0 the SSE event id, slot 2 `SHARED_PAGE_MAGIC`, each worker's
   accept-share line after, file-backed where the host allows it and
   exported by descriptor. The application's page, if
   `AppHandler.page_slots` asks for one, is separate, so an app numbers its
   words from 0 and can never write over a sibling's load.
4. **The bus, unconditionally**, at one worker too: it is the
   thread-to-loop channel as well as the worker-to-worker one, and a
   producer publishing into a channel nothing drains fails silently.
5. **The accept-share channels** (SPEC E16), above one worker unless
   `M0_ACCEPT_SHARE=0` asks for the bare race.
6. **Fork** when `M0_WORKERS > 1`. The supervisor never returns.
7. **Bind** this worker's accept share to the page.
8. **Arm the signals**, after the fork: a pre-fork install points every
   worker at the supervisor's pipe, which nothing watches.
9. **Build the handler** with `H.make(ctx)`, after the fork, per worker.
    A `make` that raises is a REFUSAL, not a crash: the error is printed
    under `host:` and the worker exits 78, which the supervisor reads as a
    configuration it must not respawn (`EX_CONFIG`). It used to crash-loop
    five times and exit 1 under `M0_WORKERS=2`, and print the listening
    banner before the trace at one worker.
9a. **The pool lane**, under `M0_BLOCKING_THREADS=N` (since 2026-09-17,
    D31): N `MojoPool` threads behind this worker's loop, each building
    the application's handler AGAIN with `H.make` on its own thread
    (`PoolLane[H]` is the `PoolHandler` the pool asks for; `ctx.thread`
    says which thread, -1 being the loop's own instance), on one lane the
    host marks GIL-free -- there is no interpreter here -- so a job that
    has waited past the idle spin wakes a parked sibling. Every `func`
    then runs on a pool thread; `before_request` and the streaming hooks
    stay the loop's, so a route that must answer while the pool is busy,
    or that opens a stream, is `add_loop` or `on_loop=True` on its table
    (`m0_http.views`). A stream begun in `func` is refused 409 from a pool
    thread, per request and named in the log, exactly as on a Mojo mount.
    The host WAITS for every thread to report its handler built before it
    serves, and a `make` that raises on a pool thread is the same 78 the
    loop's gets -- never a server one thread short. No pool by default;
    `M0_BLOCKING_THREADS=0` is the same as unset.
10. **Start the producer** on the tick owner (worker 0) alone, handed EVERY
    worker's bus channel through a `Publisher` that always sends to all of
    them — the application never sees a descriptor, so it cannot publish to
    a subset — and the shared event-id word through `Publisher.next_id`,
    so a respawned producer continues the numbering its siblings' streams
    have seen rather than restarting at 1 below it. The producer is BUILT
    here, on the spawning thread, before the server listens, so a raising
    `Producer.make` is refused with 78 as the handler's is, by construction
    rather than by racing the banner; the thread takes it from there.
11. **Serve** with this worker's bus channel drained and its share bound.
12. **Stop and join the producer and the pool** within `JOIN_TIMEOUT_NS`,
    counted from the moment the DRAIN BEGAN, not from its end: the loop
    stamps the producer's stop word as its first act of the drain
    (`run_event_loop`'s `stop_addr`), so the producer ends while the drain
    runs and the join afterwards waits only for what is left of the one
    bound. The pool is pilled after the loop returns -- a pill read with a
    job still on the ring would strand it -- and joined within the same
    remainder, floored at `POOL_JOIN_FLOOR_NS` so idle threads are not
    miscounted as stragglers. A producer or thread still inside its work
    after that is abandoned by name and the process leaves with `_exit`,
    because `pthread_join` has no timeout and waiting longer only makes
    SIGTERM a no-op. Told to stop only after the drain, as until
    2026-09-17, a 4 s request in flight at SIGTERM beside a step past its
    bound took 8.5 s to leave -- the two 5 s budgets in sequence, most of
    `docker stop`'s default grace.
13. **`exit_worker()`** in a forked worker, never a return from `main`.

**Where it lives, and why.** In the fork, beside `mojo_pool.mojo`, and for
the same reason: an application must CONFORM to `AppHandler` and
`Producer`, and on the pinned toolchain a conformance to a trait inside a
precompiled package gets no witness table (the package's name and its
source directory disagree; `poe check-mojoc-trait`). A source-resolved
module has no such mismatch. It costs six more fork -> `m0_http` edges
(`config`, `multiworker`, `prefork`, `signal`, `threads` and `views`),
inside `packages/m0-http/` as the existing two are; CLAUDE.md's cycle paragraph and
NOTICE list them. When the pin moves, this can move to `m0_http`.

**What the host decides for every producer** (DECISIONS D26, which it
retires):

- *Cadence*: `step` returns the nanoseconds from this step's scheduled start
  to the next one. Fixed-rate, never catching up: a step that overruns moves
  the schedule to now rather than running the missed steps back to back. A
  producer that pauses returns its poll interval and publishes nothing; one
  that changes pace returns a different number. Sleeps are sliced
  (`SLEEP_SLICE_NS`), so a long period never delays the stop.
- *Shutdown bound*: the drain's own 5 s (`JOIN_TIMEOUT_NS`); then the
  process leaves without the producer and says so.
- *Publish shape*: every worker's channel, `skip_worker = -1` (nothing has
  queued the frame locally), with each shortfall counted on the publisher
  and reported to the step as `False`, and every id from the ONE shared
  word (`Publisher.next_id`, `fetch_add` on `HostContext.id_addr`) that
  the handlers' own publishes number from. The id is handed out rather
  than stamped inside `publish`, because it sits inside the frame body
  and the framing is the application's (`format_sse_event` puts `id:`
  first, Datastar puts `event:` first), so the publisher cannot write it;
  what `publish` could check instead — an id at or below the word's
  current value — is true of every correctly numbered frame too, a
  handler having taken the next one meanwhile. A step that raises ends the
  producer, named in the log; the server keeps serving what it has.

**A table and its state need no handler of their own.** `ViewsApp[S]` is
the host's `ViewService`: a state type conforming to `ViewState` (`make`,
`urls`, optionally `max_workers` and `page_slots`) is served as
`serve[ViewsApp[MyState]](config)`, with `func` dispatching the table and
`before_request` answering its loop routes. An application that also owns
the SSE hooks writes its own `AppHandler` over `Views.dispatch`, as
`apps/blobs` does.

**What it does not do.** No `--threads` loops, no `--spawn-workers`, no
CLI flags or `--doctor`: `AppConfig`'s environment is the whole
configuration. Each is refused or absent rather than half-served. The pool
lane (D31) is the one thing v1 refused that is served now; a hold from a
pool thread (`set_hold_notify`) is not, and a Mojo application that wants a
held stream opens it on the loop.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.time import perf_counter_ns, sleep

from lightbug_http.accept_share import AcceptShare
from lightbug_http.address import NetworkType
from lightbug_http.broadcast import BroadcastBus, publish_to_channels
from lightbug_http.c.platform import PlatformBackend
from lightbug_http.c.process import process_exit
from lightbug_http.connection import ListenConfig, NoTLSListener
from lightbug_http.event_loop import run_event_loop
from lightbug_http.mojo_pool import JOIN_TIMEOUT_NS, MojoPool, PoolContext, PoolHandler
from lightbug_http.offload import OffloadPool
from lightbug_http.server_config import ServerConfig
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.service import HTTPService

# Fork -> m0_http, like `event_loop` -> `m0_http.log` and `mojo_pool` ->
# `m0_http.threads`: framework code on both sides of `packages/m0-http/`,
# so the cycle never crosses a package boundary. See the module docstring.
from m0_http.config import AppConfig
from m0_http.multiworker import (
    EX_CONFIG,
    SharedAtomics,
    WorkerSupervisor,
    exit_worker,
    shared_fetch_add,
)
from m0_http.prefork import (
    bind_accept_share,
    prefork_accept_share,
    prefork_bus,
    prefork_page,
    spawned_worker_index,
)
from m0_http.signal import install_shutdown_signals
from m0_http.views import Views
from m0_http.threads import (
    BLK_STATUS,
    BLK_USER,
    STATUS_NEVER_RAN,
    STATUS_OK,
    STATUS_RAISED,
    ThreadBlock,
    ThreadSet,
)


comptime BLK_STOP = 10
"""Producer block slot: set to 1 to end the producer. `ThreadSet` names
slots 0-9; 10 upward are the spawner's."""

comptime BLK_PRODUCER = 11
"""Producer block slot: the address of the producer `start` built, which
the thread takes as its first act."""

comptime SLEEP_SLICE_NS = 50_000_000
"""The longest a producer sleeps before it looks at `BLK_STOP` again."""

comptime POOL_JOIN_FLOOR_NS = 500_000_000
"""The least the pool's join waits after the drain, whatever is left of the
bound. A thread that is idle takes its pill and ends in microseconds, but
under a loaded runner not always inside the zero a spent bound leaves, and
a thread counted a straggler while it is exiting is a lie in the log."""


struct HostContext(Copyable, Movable):
    """What `AppHandler.make` and `Producer.make` are handed."""

    var worker: Int
    """This worker's index, 0-based. Always 0 for a producer."""
    var workers: Int
    """How many workers serve: `M0_WORKERS`."""
    var capacity: Int
    """The server's connection capacity. Slots index a stream registry
    directly, so a registry needs at least this many entries."""
    var page: Int
    """Address of the application's shared page (`AppHandler.page_slots`
    words, created before the fork), or 0 when it asked for none."""
    var id_addr: Int
    """Address of the shared SSE event-id word every worker numbers from."""
    var bus: BroadcastBus
    """Every worker's channel. The loop already drains this worker's; a
    handler that publishes to its peers (`DatastarStream.enable_bus`) takes
    it from here."""
    var config: AppConfig
    """The environment the host was started with."""
    var thread: Int
    """Which instance this `make` builds: -1 for the loop's own handler, the
    one whose `before_request` and streaming hooks run; 0 upward for a pool
    thread's under `M0_BLOCKING_THREADS`, whose `func` runs there. A handler
    that keeps a stream registry keeps it on the loop's instance alone."""

    def __init__(
        out self,
        worker: Int,
        workers: Int,
        capacity: Int,
        page: Int,
        id_addr: Int,
        var bus: BroadcastBus,
        var config: AppConfig,
        thread: Int = -1,
    ):
        self.worker = worker
        self.workers = workers
        self.capacity = capacity
        self.page = page
        self.id_addr = id_addr
        self.bus = bus^
        self.config = config^
        self.thread = thread

    def tick_owner(self) -> Bool:
        """Whether this worker does the once-per-interval work: worker 0."""
        return self.worker == 0

    def on_loop(self) -> Bool:
        """Whether this is the loop's own instance (see `thread`)."""
        return self.thread < 0


trait AppHandler(HTTPService, Movable, Deinitable):
    """An `HTTPService` the host can build once per worker, after the fork."""

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        """Build this worker's handler. Called once, in the worker."""
        ...

    @staticmethod
    def page_slots(workers: Int) -> Int:
        """How many shared Int64 words the application needs for `workers`.

        The page is created before the fork and every worker and the
        producer see the same memory at `ctx.page`. 0, the default, asks for
        no page.
        """
        return 0

    @staticmethod
    def max_workers() -> Int:
        """The most workers this application can be served from; 0, the
        default, is any number.

        An application whose state lives in one process's memory (a list in
        a struct, not a database or the shared page) answers 1, and the host
        refuses `M0_WORKERS` above it with 78 rather than serving workers
        that each hold a different copy.
        """
        return 0


trait ViewState(Movable, Deinitable):
    """The state a `Views` table dispatches to, served by `ViewsApp`."""

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        """Build this worker's state. Called once, in the worker."""
        ...

    @staticmethod
    def urls() raises -> Views[Self]:
        """The table. Built once per worker, beside the state."""
        ...

    @staticmethod
    def page_slots(workers: Int) -> Int:
        """As `AppHandler.page_slots`."""
        return 0

    @staticmethod
    def max_workers() -> Int:
        """As `AppHandler.max_workers`."""
        return 0


struct ViewsApp[S: ViewState](AppHandler):
    """A `Views` table and its state as the host's handler.

    `m0_http.ViewService` with a `make`: it forwards `func` to `dispatch`
    and `before_request` to `answer_on_loop`, and nothing else.
    """

    var views: Views[Self.S]
    var state: Self.S

    def __init__(out self, var views: Views[Self.S], var state: Self.S):
        self.views = views^
        self.state = state^

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return Self(Self.S.urls(), Self.S.make(ctx))

    @staticmethod
    def page_slots(workers: Int) -> Int:
        return Self.S.page_slots(workers)

    @staticmethod
    def max_workers() -> Int:
        return Self.S.max_workers()

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        # With the state: an `on_loop` route is answered here, on the loop
        # instance, before the request becomes a pool job.
        return self.views.answer_on_loop(req, self.state)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return self.views.dispatch(req, self.state)


struct PoolLane[H: AppHandler](PoolHandler):
    """A pool thread's instance of the application's handler.

    What `MojoPool.start[T]` asks for is a `PoolHandler`, built by
    `make(PoolContext)` on the thread that will use it; what the
    application wrote is an `AppHandler`, built by `make(HostContext)`.
    This is the adapter between the two, so an application conforms ONCE
    and the host does the rest: `ctx.user` is the address of the worker's
    `HostContext` (copied to memory that outlives `serve`, as the
    producer's is), and the copy handed to `H.make` names the thread in
    `thread`. Only `func`, `before_request` and `after_response` are
    forwarded, because only those run on a pool thread; the streaming
    hooks, `tick` and `ws_message` are the loop instance's.

    A raising `H.make` is printed here under `host:` with the thread named
    and re-raised, so the thread ends `STATUS_RAISED`, `wait_ready` counts
    it, and `serve` exits 78 (D30) -- the same refusal the loop's own
    `make` gets, and the line the smoke greps for.
    """

    var inner: Self.H

    def __init__(out self, var inner: Self.H):
        self.inner = inner^

    @staticmethod
    def make(ctx: PoolContext) raises -> Self:
        ref host = Pointer[HostContext, MutUntrackedOrigin](
            unsafe_from_address=ctx.user
        )[]
        var mine = host.copy()
        mine.thread = ctx.index
        try:
            return Self(Self.H.make(mine))
        except e:
            print(
                "host: the handler's make raised on pool thread "
                + String(ctx.index)
                + ", so this configuration is refused: "
                + String(e),
                flush=True,
            )
            raise e

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return self.inner.before_request(req)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return self.inner.func(req)

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        self.inner.after_response(req_method, req_path, resp)

    def shutdown(mut self):
        pass


struct Publisher(Movable):
    """A producer's only way out: one frame to every worker's channel, and
    the one id space every stream is numbered in."""

    var _fds: List[Int]
    var _id_addr: Int
    var refused: Int
    """Frames at least one channel did not take: over `BUS_MAX_FRAME`, a
    reserved name, or a full channel."""

    def __init__(out self, var write_fds: List[Int], id_addr: Int) raises:
        """`id_addr` is `HostContext.id_addr`, the pre-fork word. 0 is
        refused: `shared_fetch_add` answers 0 for it, and an id of 0 is
        below every slot's last-seen id, so nothing would be delivered."""
        if id_addr == 0:
            raise Error("Publisher: the shared event-id word's address is 0")
        self._fds = write_fds^
        self._id_addr = id_addr
        self.refused = 0

    def channels(self) -> Int:
        return len(self._fds)

    def next_id(self) -> Int:
        """The next event id, from the word every worker numbers from.

        `SSERegistry` delivers a frame only if its id is above the slot's
        last-seen id. A producer numbering from its own counter restarts at
        1 when the supervisor respawns worker 0, and every stream held on a
        sibling then goes silent for exactly the pre-crash uptime; numbered
        here, the respawned producer's first id is above whatever the
        streams have seen. Take it BEFORE formatting the frame, since the
        frame carries it.
        """
        return shared_fetch_add(self._id_addr, 1) + 1

    def publish(mut self, url: String, event_id: Int, frame: Span[Byte, _]) -> Bool:
        """Send `frame` on `url` to every worker; False if any channel refused it.

        `skip_worker = -1`: nothing has queued the frame locally, so this
        worker's own subscribers want it as much as any sibling's.
        """
        var sent = publish_to_channels(self._fds, -1, url, event_id, frame)
        if sent < len(self._fds):
            self.refused += 1
            return False
        return True


trait Producer(Movable, Deinitable):
    """Work on a cadence, off the loop, published through the bus."""

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        """Build the producer, ON its own thread. Called once."""
        ...

    @staticmethod
    def wanted(ctx: HostContext) -> Bool:
        """Whether this configuration runs a producer at all.

        Asked on the tick owner only. `NoProducer` answers False; an app with
        an A/B knob that moves the work elsewhere answers from the knob.
        """
        return True

    def step(mut self, mut out: Publisher) raises -> Int:
        """One step. Returns the nanoseconds from this step's scheduled
        start to the next one's; 0 or less means at once."""
        ...


struct NoProducer(Producer):
    """What an application with nothing to produce names: no thread."""

    def __init__(out self):
        pass

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return NoProducer()

    @staticmethod
    def wanted(ctx: HostContext) -> Bool:
        return False

    def step(mut self, mut out: Publisher) raises -> Int:
        return 0


def _producer_run[P: Producer](block: ThreadBlock) raises:
    """The producer's whole life. Separate from `_producer_body` so the
    producer is destroyed before the body reports its status.

    The producer itself was built by `start`, on the spawning thread; this
    thread takes it out of the memory `start` left it in and owns it from
    the first step to the last.
    """
    ref ctx = Pointer[HostContext, MutUntrackedOrigin](
        unsafe_from_address=block.get(BLK_USER)
    )[]
    var out = Publisher(ctx.bus.write_fds.copy(), ctx.id_addr)
    var built = Pointer[P, MutUntrackedOrigin](
        unsafe_from_address=block.get(BLK_PRODUCER)
    )
    var producer = built.unsafe_take_pointee()
    built.unsafe_free()
    var next_ns = perf_counter_ns()
    while block.get(BLK_STOP) == 0:
        var wait_ns = producer.step(out)
        if wait_ns < 0:
            wait_ns = 0
        next_ns += wait_ns
        # Behind: never catch up, or an overrun compounds into a loop that
        # never sleeps.
        var now = perf_counter_ns()
        if next_ns <= now:
            next_ns = now
            continue
        while block.get(BLK_STOP) == 0:
            var left = next_ns - perf_counter_ns()
            if left <= 0:
                break
            if left > SLEEP_SLICE_NS:
                left = SLEEP_SLICE_NS
            sleep(Float64(left) / 1_000_000_000.0)


def _producer_body[P: Producer](arg: Int) -> Int:
    """pthread start routine: produce, then report."""
    var block = ThreadBlock(arg)
    var status = STATUS_RAISED
    try:
        _producer_run[P](block)
        status = STATUS_OK
    except e:
        print("host: the producer raised and has stopped: " + String(e), flush=True)
    # Last act, and load-bearing: `join_within` waits on this slot.
    block.set(BLK_STATUS, status)
    return 0


struct ProducerThread(Movable):
    """One producer on a thread of its own, stopped and joined within a bound."""

    var _set: ThreadSet
    var _started: Bool
    var stragglers: Int
    """1 when `stop_and_join` left the producer running: still inside a
    step when its bound ran out."""

    def __init__(out self):
        self._set = ThreadSet(1)
        self._started = False
        self.stragglers = 0

    def __init__(out self, *, deinit move: Self):
        self._set = move._set^
        self._started = move._started
        self.stragglers = move.stragglers

    def start[P: Producer](mut self, ctx: HostContext) raises:
        """Build the producer, then spawn its thread.

        `P.make` runs HERE, on the calling thread, and a raise propagates
        to the caller with no thread started: `serve` turns it into the
        same exit 78 a raising `AppHandler.make` gets, before the server
        listens. Built on its own thread instead, the refusal would race
        the listening banner, since the thread starts just before the
        serve. The producer and `ctx` are copied to memory that outlives
        the caller: a producer abandoned at the join may outlive `main`.
        """
        var producer = P.make(ctx)
        var built = unsafe_alloc[P](count=1)
        built.unsafe_write(producer^)
        var owned = unsafe_alloc[HostContext](count=1)
        owned.unsafe_write(ctx.copy())
        var block = self._set.block(0)
        block.set(BLK_USER, Int(owned))
        block.set(BLK_PRODUCER, Int(built))
        block.set(BLK_STOP, 0)
        var body = _producer_body[P]
        self._set.spawn(0, Pointer(to=body).unsafe_bitcast[Int]()[])
        self._started = True

    def running(self) -> Bool:
        """Whether the producer is still inside its body."""
        return self._started and self._set.status(0) == STATUS_NEVER_RAN

    def status(self) -> Int:
        return self._set.status(0)

    def stop_addr(self) -> Int:
        """The stop word's address, for the loop to stamp when its drain
        begins (`run_event_loop`'s `stop_addr`). Valid before `start` and
        for a producer never started: the block is the thread set's, made
        with it and never freed."""
        return self._set.block(0).slot_addr(BLK_STOP)

    def drain_began(self) -> Int:
        """When the loop stamped the stop word (`perf_counter_ns`), or 0 if
        nothing has told the producer to stop yet."""
        return self._set.block(0).get(BLK_STOP)

    def stop_and_join(mut self, timeout_ns: Int) raises -> Int:
        """Tell the producer to stop and wait until `timeout_ns` after it
        was told.

        The stop word holds WHEN it was set: the loop stamps it as its
        drain begins, so a producer told then has been stopping through
        the drain and the join here waits only for what is left of the
        bound. Unstamped -- no loop, or a test -- it is set now and the
        whole bound applies. Returns how many were left running (0 or 1),
        also kept in `stragglers`. A producer never started joins at once.
        """
        if not self._started:
            return 0
        var block = self._set.block(0)
        var now = perf_counter_ns()
        var began = block.get(BLK_STOP)
        if began == 0:
            block.set(BLK_STOP, now)
            began = now
        var left = began + timeout_ns - now
        if left < 0:
            left = 0
        self.stragglers = self._set.join_within(left)
        return self.stragglers


def host_refusal(config: AppConfig, max_workers: Int = 0) -> Optional[String]:
    """Why the host will not serve `config`, or None.

    Each is a variable another server honours, or a count the application
    cannot keep one state across; ignoring either would serve a
    configuration other than the one written down.
    """
    if config.workers < 1:
        return String("M0_WORKERS must be at least 1, not ", config.workers)
    if max_workers > 0 and config.workers > max_workers:
        return String(
            "M0_WORKERS=", config.workers, ", but this application serves from"
            " at most ", max_workers, " process(es): its state lives in one"
            " process's memory",
        )
    if config.threads > 1:
        return String(
            "M0_THREADS is m0serve's threaded mode; the Mojo host serves one"
            " loop per process (unset it, or use M0_WORKERS, or"
            " M0_BLOCKING_THREADS for a pool behind each loop)"
        )
    if config.spawn_workers:
        return String(
            "M0_SPAWN_WORKERS is m0serve's; the Mojo host forks without exec"
            " (unset it)"
        )
    if spawned_worker_index() >= 0:
        # An exec'd m0serve worker's marker, inherited: the pre-fork pieces
        # would be adopted from descriptors this process never received.
        return String(
            "M0_WORKER_SPAWNED marks an exec'd m0serve worker; the Mojo host"
            " forks without exec (unset it)"
        )
    return None


def serve[H: AppHandler, P: Producer = NoProducer](config: AppConfig) raises:
    """Serve `H` (and run `P` on the tick owner) as the environment says."""
    serve[H, P](config, config.server_config())


def _make_handler[H: AppHandler](ctx: HostContext) raises -> H:
    """`H.make`, or the refusal a raise means.

    A handler that cannot be built would not be built by the next
    incarnation either, so the worker leaves with `EX_CONFIG` and the
    supervisor stops rather than respawning it five times. Named under
    `host:` with the application's own error, because that error is the
    whole diagnosis.
    """
    try:
        return H.make(ctx)
    except e:
        print(
            "host: the handler's make raised, so this configuration is refused: "
            + String(e),
            flush=True,
        )
        process_exit(EX_CONFIG)
        raise e  # never reached: the process has left


def serve[H: AppHandler, P: Producer = NoProducer](
    config: AppConfig, var server_config: ServerConfig
) raises:
    """`serve`, with server tuning the environment does not reach."""
    var refusal = host_refusal(config, H.max_workers())
    if refusal:
        print("host: " + refusal.value(), flush=True)
        process_exit(EX_CONFIG)
    var workers = config.workers

    var listener = ListenConfig().listen(config.address())
    # The page, the bus and the accept-share channels are m0serve's too:
    # `m0_http.prefork` makes (and exports) all three for both hosts.
    var host_page = prefork_page(workers)
    var app_page = 0
    var app_slots = H.page_slots(workers)
    if app_slots > 0:
        app_page = SharedAtomics(app_slots).addr(0)
    var bus = prefork_bus(workers)
    var share = prefork_accept_share(workers)

    var worker = 0
    var forked = workers > 1
    if forked:
        var supervisor = WorkerSupervisor(workers)
        supervisor.fork_all()
        worker = supervisor.worker_index
    # Inactive with one worker or under the knob; binding is harmless there.
    bind_accept_share(share, worker, host_page.addr(0))
    var shutdown_fd = install_shutdown_signals()

    var ctx = HostContext(
        worker, workers, server_config.max_connections, app_page,
        host_page.addr(0), bus.copy(), config.copy(),
    )
    var handler = _make_handler[H](ctx)
    var producer = ProducerThread()
    if ctx.tick_owner() and P.wanted(ctx):
        # Built on this thread, before the serve: a raise here is the same
        # refusal as the handler's, and the supervisor ends the siblings
        # for it, since a server with no worker 0 and no producer is not
        # the configuration that was written down.
        try:
            producer.start[P](ctx)
        except e:
            print(
                "host: the producer's make raised, so this configuration is refused: "
                + String(e),
                flush=True,
            )
            process_exit(EX_CONFIG)

    # The pool lane (docstring, 9a). One pool per loop, and this worker has
    # one loop; one lane, which the host marks GIL-free because nothing
    # here ever attaches to an interpreter. A disabled pool (capacity 0)
    # when there is none, since `Optional` will not hold this type.
    var pooled = config.blocking_threads > 0
    var pool = OffloadPool(server_config.max_connections if pooled else 0)
    var threads = MojoPool(config.blocking_threads if pooled else 0)
    if pooled:
        pool.set_lane_gil_free(0)
        # The context every pool thread's `make` reads, in memory that
        # outlives this frame: a thread abandoned at the join may outlive
        # `main`, as the producer may.
        var owned = unsafe_alloc[HostContext](count=1)
        owned.unsafe_write(ctx.copy())
        threads.start[PoolLane[H]](pool.addr(), user=Int(owned))
        # Every thread has its handler, or one of them could not build it:
        # then this is the refusal the loop's own `make` gets, before the
        # server takes a connection, never a pool one thread short.
        if threads.wait_ready(JOIN_TIMEOUT_NS) > 0:
            print(
                "host: a pool thread could not build the handler, so this"
                " configuration is refused",
                flush=True,
            )
            process_exit(EX_CONFIG)
        print(
            String(
                "host: ", config.blocking_threads,
                " handler thread(s) behind the loop (M0_BLOCKING_THREADS)",
            ),
            flush=True,
        )

    # `run_event_loop` directly rather than through `Server`, for the two
    # things `Server.serve_nonblocking` cannot pass: the pool, and the stop
    # word the loop stamps as its drain begins (docstring, 12).
    _run_loop(
        listener,
        handler,
        server_config,
        config.address(),
        shutdown_fd,
        bus_read_fd=bus.read_fd(worker),
        offload_addr=pool.addr() if pooled else 0,
        accept_share=share^,
        stop_addr=producer.stop_addr(),
    )

    # The drain is over. The pool first, pilled only now (a pill read with a
    # job still on the ring strands the job) and joined within what the
    # drain left of the bound; a thread still inside a view is the one the
    # drain already waited its budget for. Then the producer, told to stop
    # when the drain began and joined within the rest of ITS bound. Either
    # still running is left, named, and the process leaves with `_exit`
    # rather than through teardown under that thread. (A plain return was
    # measured to exit just as promptly; `_exit` is here so teardown never
    # races a step, not because anything on the wire differs.)
    var stuck = 0
    if pooled:
        _ = threads.stop_and_join(pool, _left_of_bound(producer.drain_began()))
        stuck = threads.stragglers
        if stuck > 0:
            print(
                String(
                    "host: ", stuck, " handler thread(s) still inside the"
                    " application ", JOIN_TIMEOUT_NS // 1_000_000_000,
                    " s after the drain began; exiting without them",
                ),
                flush=True,
            )
    if producer.stop_and_join(JOIN_TIMEOUT_NS) > 0:
        print(
            String(
                "host: abandoned a producer step still running ",
                JOIN_TIMEOUT_NS // 1_000_000_000,
                " s after the drain; exiting without it",
            ),
            flush=True,
        )
        stuck += 1
    if stuck > 0:
        process_exit(0)
    if forked:
        exit_worker()


def _run_loop[H: AppHandler](
    listener: NoTLSListener[NetworkType.tcp4],
    mut handler: H,
    config: ServerConfig,
    address: String,
    shutdown_fd: Int,
    bus_read_fd: Int,
    offload_addr: Int,
    var accept_share: AcceptShare,
    stop_addr: Int,
) raises:
    """The serve, with the listener BORROWED for its whole duration.

    Not inlined into `serve` on purpose: `listener.socket.fd` as a call
    argument is a value, and the expression that reads it was the
    listener's last use -- Mojo destroyed it there, its destructor closed
    the socket, and the loop's first `fcntl` on the fd failed with EBADF
    before a connection was taken (measured on 2026-09-17, both with and
    without a pool). A read parameter lives for the call.
    """
    var backend = PlatformBackend()
    run_event_loop(
        listener.socket.fd,
        handler,
        backend,
        config,
        address,
        True,
        shutdown_read_fd=shutdown_fd,
        bus_read_fd=bus_read_fd,
        offload_addr=offload_addr,
        accept_share=accept_share^,
        stop_addr=stop_addr,
    )


def _left_of_bound(began: Int) -> Int:
    """What remains of `JOIN_TIMEOUT_NS` counted from `began` (a
    `perf_counter_ns` stamp; 0 means never stamped and the whole bound
    applies), never less than `POOL_JOIN_FLOOR_NS`."""
    if began == 0:
        return JOIN_TIMEOUT_NS
    var left = began + JOIN_TIMEOUT_NS - perf_counter_ns()
    if left < POOL_JOIN_FLOOR_NS:
        return POOL_JOIN_FLOOR_NS
    return left
