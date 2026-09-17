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

1. **Refuse what it does not serve** (`host_refusal`): `M0_THREADS`,
   `M0_BLOCKING_THREADS` and `M0_SPAWN_WORKERS` are m0serve's, and a
   variable the host silently ignored would be a configuration that reads as
   applied; and more workers than `AppHandler.max_workers()` allows, for an
   application whose state lives in one process. Exit 78, before anything
   is bound.
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
10. **Start the producer** on the tick owner (worker 0) alone, handed EVERY
    worker's bus channel through a `Publisher` that always sends to all of
    them — the application never sees a descriptor, so it cannot publish to
    a subset.
11. **Serve** with this worker's bus channel drained and its share bound.
12. **Stop and join the producer** within `JOIN_TIMEOUT_NS`, the drain's own
    bound. A producer still inside a step after that is abandoned by name
    and the process leaves with `_exit`, because `pthread_join` has no
    timeout and waiting longer only makes SIGTERM a no-op.
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
  and reported to the step as `False`. A step that raises ends the producer,
  named in the log; the server keeps serving what it has.

**A table and its state need no handler of their own.** `ViewsApp[S]` is
the host's `ViewService`: a state type conforming to `ViewState` (`make`,
`urls`, optionally `max_workers` and `page_slots`) is served as
`serve[ViewsApp[MyState]](config)`, with `func` dispatching the table and
`before_request` answering its loop routes. An application that also owns
the SSE hooks writes its own `AppHandler` over `Views.dispatch`, as
`apps/blobs` does.

**What it does not do (v1).** No pool lanes (`MojoPool`), no `--threads`
loops, no `--spawn-workers`, no CLI flags or `--doctor`: `AppConfig`'s
environment is the whole configuration. Each is refused or absent rather
than half-served.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.time import perf_counter_ns, sleep

from lightbug_http.broadcast import BroadcastBus, publish_to_channels
from lightbug_http.c.process import process_exit
from lightbug_http.connection import ListenConfig
from lightbug_http.mojo_pool import JOIN_TIMEOUT_NS
from lightbug_http.server import Server
from lightbug_http.server_config import ServerConfig
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.service import HTTPService

# Fork -> m0_http, like `event_loop` -> `m0_http.log` and `mojo_pool` ->
# `m0_http.threads`: framework code on both sides of `packages/m0-http/`,
# so the cycle never crosses a package boundary. See the module docstring.
from m0_http.config import AppConfig
from m0_http.multiworker import EX_CONFIG, SharedAtomics, WorkerSupervisor, exit_worker
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

comptime SLEEP_SLICE_NS = 50_000_000
"""The longest a producer sleeps before it looks at `BLK_STOP` again."""


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

    def __init__(
        out self,
        worker: Int,
        workers: Int,
        capacity: Int,
        page: Int,
        id_addr: Int,
        var bus: BroadcastBus,
        var config: AppConfig,
    ):
        self.worker = worker
        self.workers = workers
        self.capacity = capacity
        self.page = page
        self.id_addr = id_addr
        self.bus = bus^
        self.config = config^

    def tick_owner(self) -> Bool:
        """Whether this worker does the once-per-interval work: worker 0."""
        return self.worker == 0


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
        return self.views.answer_on_loop(req)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return self.views.dispatch(req, self.state)


struct Publisher(Movable):
    """A producer's only way out: one frame to every worker's channel."""

    var _fds: List[Int]
    var refused: Int
    """Frames at least one channel did not take: over `BUS_MAX_FRAME`, a
    reserved name, or a full channel."""

    def __init__(out self, var write_fds: List[Int]):
        self._fds = write_fds^
        self.refused = 0

    def channels(self) -> Int:
        return len(self._fds)

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
    producer is destroyed before the body reports its status."""
    ref ctx = Pointer[HostContext, MutUntrackedOrigin](
        unsafe_from_address=block.get(BLK_USER)
    )[]
    var out = Publisher(ctx.bus.write_fds.copy())
    var producer = P.make(ctx)
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
        """Spawn the producer. `ctx` is copied to memory that outlives the
        caller: a producer abandoned at the join may outlive `main`."""
        var owned = unsafe_alloc[HostContext](count=1)
        owned.unsafe_write(ctx.copy())
        var block = self._set.block(0)
        block.set(BLK_USER, Int(owned))
        block.set(BLK_STOP, 0)
        var body = _producer_body[P]
        self._set.spawn(0, Pointer(to=body).unsafe_bitcast[Int]()[])
        self._started = True

    def running(self) -> Bool:
        """Whether the producer is still inside its body."""
        return self._started and self._set.status(0) == STATUS_NEVER_RAN

    def status(self) -> Int:
        return self._set.status(0)

    def stop_and_join(mut self, timeout_ns: Int) raises -> Int:
        """Tell the producer to stop and wait up to `timeout_ns`.

        Returns how many were left running (0 or 1), also kept in
        `stragglers`. A producer never started joins at once.
        """
        if not self._started:
            return 0
        self._set.block(0).set(BLK_STOP, 1)
        self.stragglers = self._set.join_within(timeout_ns)
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
            " loop per process (unset it, or use M0_WORKERS)"
        )
    if config.blocking_threads > 0:
        return String(
            "M0_BLOCKING_THREADS is m0serve's handler pool; the Mojo host"
            " answers on its loops (unset it)"
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
    var handler = H.make(ctx)
    var producer = ProducerThread()
    if ctx.tick_owner() and P.wanted(ctx):
        producer.start[P](ctx)

    var server = Server(server_config^, config.address())
    server.serve_nonblocking(
        listener,
        handler,
        shutdown_read_fd=shutdown_fd,
        bus_read_fd=bus.read_fd(worker),
        accept_share=share^,
    )

    # A producer still inside its step is left running, and the process
    # leaves with `_exit` rather than through teardown under that thread. (A
    # plain return was measured to exit just as promptly; `_exit` is here so
    # teardown never races a step, not because anything on the wire differs.)
    if producer.stop_and_join(JOIN_TIMEOUT_NS) > 0:
        print(
            String(
                "host: abandoned a producer step still running ",
                JOIN_TIMEOUT_NS // 1_000_000_000,
                " s after the drain; exiting without it",
            ),
            flush=True,
        )
        process_exit(0)
    if forked:
        exit_worker()
