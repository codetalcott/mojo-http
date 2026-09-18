"""The Mojo host's pieces that run without a server: the producer thread, the
publisher, and the refusals.

`serve` itself forks, binds and signals, so it is gated on the wire
(`smoke-host`, SPEC E21-E23). What is proven here is what that gate would
only see as a symptom: that a producer's frames reach EVERY channel, that
its cadence never catches up, that a stop is prompt however long the period,
that an overrunning step is abandoned inside the bound rather than waited
for, that a raising step ends the thread with a status while a raising
`make` never starts one, and that every publisher numbers from the one
shared word.
"""

from std.os import setenv, unsetenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns, sleep

from lightbug_http.broadcast import BUS_MAX_FRAME, BroadcastBus, drain_bus_channel
from lightbug_http.host import (
    AppHandler,
    HostContext,
    NoProducer,
    PoolLane,
    Producer,
    ProducerThread,
    Publisher,
    ViewState,
    ViewsApp,
    host_refusal,
)
from lightbug_http.http import HTTPRequest, HTTPResponse, OK
from lightbug_http.uri import URI
from lightbug_http.mojo_pool import MojoPool, PoolContext
from lightbug_http.offload import OffloadPool
from lightbug_http.ring import atomic_at
from m0_http.config import AppConfig
from m0_http.views import Views
from m0_http.multiworker import SharedAtomics, shared_fetch_add, shared_load
from m0_http.threads import STATUS_NEVER_RAN, STATUS_OK, STATUS_RAISED

comptime P_PERIOD_NS = 0
comptime P_COST_NS = 1
comptime P_RAISE = 2
comptime P_STEPS = 3
comptime P_SLOW_STEP = 4
"""The one step that costs `P_COST_NS`; 0 makes every step cost it."""
comptime P_MAKE_RAISES = 5
"""1 makes `Ticker.make` raise, the shape of a producer that cannot be built."""
comptime P_ID = 6
"""The shared event-id word, what `HostContext.id_addr` names in `serve`."""
comptime P_SLOTS = 7


def _ctx(workers: Int, page: SharedAtomics) raises -> HostContext:
    var bus = BroadcastBus(workers)
    return HostContext(
        0, workers, 64, page.addr(0), page.addr(P_ID), bus^, AppConfig()
    )


def _page(
    period_ns: Int, cost_ns: Int = 0, raises_at: Int = 0, slow_step: Int = 0
) raises -> SharedAtomics:
    var page = SharedAtomics(P_SLOTS)
    page.store(P_PERIOD_NS, period_ns)
    page.store(P_COST_NS, cost_ns)
    page.store(P_RAISE, raises_at)
    page.store(P_SLOW_STEP, slow_step)
    return page^


struct Ticker(Producer):
    """Publishes its step number on `/t`, costing and pacing as the page says."""

    var page: Int
    var step_no: Int

    def __init__(out self, page: Int):
        self.page = page
        self.step_no = 0

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        if shared_load(ctx.page + P_MAKE_RAISES * 8) == 1:
            raise Error("this producer cannot be built")
        return Ticker(ctx.page)

    def load(self, slot: Int) -> Int:
        return shared_load(self.page + slot * 8)

    def step(mut self, mut out: Publisher) raises -> Int:
        self.step_no += 1
        if self.load(P_RAISE) == self.step_no:
            raise Error("step ", self.step_no, " raised on purpose")
        var cost = self.load(P_COST_NS)
        var slow = self.load(P_SLOW_STEP)
        if cost > 0 and (slow == 0 or slow == self.step_no):
            sleep(Float64(cost) / 1_000_000_000.0)
        var frame = String("step ", self.step_no)
        _ = out.publish("/t", out.next_id(), frame.as_bytes())
        _ = shared_fetch_add(self.page + P_STEPS * 8, 1)
        return self.load(P_PERIOD_NS)


struct Plain(AppHandler):
    """The smallest handler: `make` and `func`, nothing else -- plus which
    instance it is, so a pool lane's copy can be told from the loop's."""

    var thread: Int

    def __init__(out self, thread: Int = -1):
        self.thread = thread

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return Plain(ctx.thread)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return OK("plain")


struct Unbuildable(AppHandler):
    """A handler whose `make` raises, on any thread."""

    def __init__(out self):
        pass

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        raise Error("thread " + String(ctx.thread) + " cannot build this")

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return OK("never")


struct OneProcess(ViewState):
    """State that lives in one process, served through `ViewsApp`."""

    var worker: Int

    def __init__(out self, worker: Int):
        self.worker = worker

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return OneProcess(ctx.worker)

    @staticmethod
    def urls() raises -> Views[Self]:
        return Views[OneProcess]()

    @staticmethod
    def page_slots(workers: Int) -> Int:
        return 3 * workers

    @staticmethod
    def max_workers() -> Int:
        return 1


def _ids(fd: Int) raises -> List[Int]:
    var ids = List[Int]()
    for f in drain_bus_channel(fd):
        ids.append(f.event_id)
    return ids^


def _word() raises -> SharedAtomics:
    """A shared event-id word of its own, at 0."""
    return SharedAtomics(1)


def test_publisher_reaches_every_channel() raises:
    var bus = BroadcastBus(3)
    var word = _word()
    var out = Publisher(bus.write_fds.copy(), word.addr(0))
    assert_equal(out.channels(), 3)
    var frame = String("hello")
    assert_true(out.publish("/c", 7, frame.as_bytes()))
    for w in range(3):
        var got = drain_bus_channel(bus.read_fd(w))
        assert_equal(len(got), 1)
        assert_equal(got[0].url, "/c")
        assert_equal(got[0].event_id, 7)
    assert_equal(out.refused, 0)


def test_publisher_counts_a_refusal() raises:
    var bus = BroadcastBus(2)
    var word = _word()
    var out = Publisher(bus.write_fds.copy(), word.addr(0))
    var big = List[UInt8](length=BUS_MAX_FRAME + 1, fill=UInt8(120))
    assert_false(out.publish("/c", 1, Span(big)))
    # A reserved channel is refused too, not delivered.
    var small = String("x")
    assert_false(out.publish("\x01s/1", 2, small.as_bytes()))
    assert_equal(out.refused, 2)
    assert_equal(len(drain_bus_channel(bus.read_fd(0))), 0)
    assert_equal(len(drain_bus_channel(bus.read_fd(1))), 0)


def test_publishers_number_from_the_one_shared_word() raises:
    """Every id a producer publishes comes from `HostContext.id_addr`, so a
    publisher built later -- a respawned worker 0's -- continues above what
    the earlier one handed out, and two of them never hand out one id twice.

    The loop delivers a frame only if its id is above the slot's last-seen
    id, so a producer that numbered from a counter of its own restarted at
    1 after a respawn and every stream held on a sibling went silent for
    the pre-crash uptime (`smoke-host`'s respawn phase is the wire half).

    covers: E25
    """
    var bus = BroadcastBus(1)
    var word = _word()
    var first = Publisher(bus.write_fds.copy(), word.addr(0))
    var ids = List[Int]()
    for _ in range(5):
        ids.append(first.next_id())
    # The respawn shape: a second publisher over the same word, after the
    # first has numbered five frames.
    var second = Publisher(bus.write_fds.copy(), word.addr(0))
    for _ in range(3):
        ids.append(second.next_id())
    ids.append(first.next_id())
    for i in range(len(ids)):
        assert_equal(ids[i], i + 1, String("id ", i, " was ", ids[i]))
    assert_equal(word.load(0), 9)
    # A handler's own publish numbers from the same word (`DatastarStream`
    # under `enable_bus`), and the next producer id follows it.
    _ = shared_fetch_add(word.addr(0), 1)
    assert_equal(second.next_id(), 11)


def test_a_publisher_refuses_a_missing_word() raises:
    """`shared_fetch_add(0, 1)` answers 0, and an id of 0 is below every
    slot's last-seen id: a publisher over no word would number nothing
    deliverable, so it is refused at construction."""
    var bus = BroadcastBus(1)
    var refused = False
    try:
        _ = Publisher(bus.write_fds.copy(), 0)
    except:
        refused = True
    assert_true(refused, "a publisher was built over address 0")


def test_producer_publishes_to_every_worker_in_order() raises:
    """Every channel gets every step, in order, from one producer.

    covers: E21
    """
    var page = _page(10_000_000)
    var ctx = _ctx(2, page)
    var p = ProducerThread()
    p.start[Ticker](ctx)
    sleep(0.2)
    assert_equal(p.stop_and_join(5_000_000_000), 0)
    assert_equal(p.status(), STATUS_OK)
    var steps = page.load(P_STEPS)
    assert_true(steps >= 5, String("only ", steps, " steps in 200 ms at 100 Hz"))
    for w in range(2):
        var ids = _ids(ctx.bus.read_fd(w))
        assert_equal(len(ids), steps, String("worker ", w, " missed frames"))
        for i in range(len(ids)):
            assert_equal(ids[i], i + 1)


def test_an_overrun_does_not_catch_up() raises:
    """One 200 ms step on a 20 ms period, then free steps.

    Rescheduled from now, the window holds the overrun plus one step per
    period left in it. Caught up, the nine steps the overrun missed run back
    to back first, on top of that. (Every step slow would not tell the two
    apart: both run the steps back to back.) The bound comes from the
    window as measured, because a loaded runner oversleeps both the test's
    wait and the producer's periods; the nine caught-up steps take no sleep
    at all, so oversleeping cannot hide them.
    """
    var page = _page(20_000_000, cost_ns=200_000_000, slow_step=1)
    var p = ProducerThread()
    var t0 = perf_counter_ns()
    p.start[Ticker](_ctx(1, page))
    sleep(0.4)
    _ = p.stop_and_join(5_000_000_000)
    var window_ms = Int((perf_counter_ns() - t0) // 1_000_000)
    var steps = page.load(P_STEPS)
    var most = 1 + (window_ms - 200) // 20 + 1
    assert_true(
        steps <= most + 3,
        String(steps, " steps in ", window_ms, " ms, where rescheduling allows ", most,
               ": the overrun was caught up"),
    )
    assert_true(steps >= 2, String("only ", steps, " steps: nothing ran after the overrun"))


def test_a_long_period_does_not_delay_the_stop() raises:
    var page = _page(30_000_000_000)
    var p = ProducerThread()
    p.start[Ticker](_ctx(1, page))
    sleep(0.1)
    var t0 = perf_counter_ns()
    assert_equal(p.stop_and_join(5_000_000_000), 0)
    var took_ms = (perf_counter_ns() - t0) // 1_000_000
    assert_true(took_ms < 500, String("a stop took ", took_ms, " ms behind a 30 s period"))
    assert_equal(page.load(P_STEPS), 1)


def test_an_overrunning_step_is_abandoned_within_the_bound() raises:
    """A step still running when the bound ends is left, not waited for.

    covers: E23
    """
    var page = _page(1_000_000, cost_ns=3_000_000_000)
    var p = ProducerThread()
    p.start[Ticker](_ctx(1, page))
    sleep(0.05)
    var t0 = perf_counter_ns()
    assert_equal(p.stop_and_join(200_000_000), 1)
    var took_ms = (perf_counter_ns() - t0) // 1_000_000
    assert_true(took_ms < 1000, String("the bounded join took ", took_ms, " ms"))
    assert_equal(p.stragglers, 1)
    assert_true(p.running())


def test_a_raising_step_ends_the_producer() raises:
    """A step that raises ends the thread with `STATUS_RAISED`: the server
    keeps serving, the producer is named in the log. Distinct from a
    raising `make`, below, which starts no thread at all.

    covers: E23
    """
    var page = _page(1_000_000, raises_at=3)
    var p = ProducerThread()
    p.start[Ticker](_ctx(1, page))
    var t0 = perf_counter_ns()
    while p.running() and perf_counter_ns() - t0 < 2_000_000_000:
        sleep(0.01)
    assert_false(p.running())
    assert_equal(p.status(), STATUS_RAISED)
    assert_equal(page.load(P_STEPS), 2)
    assert_equal(p.stop_and_join(1_000_000_000), 0)


def test_a_raising_make_starts_no_thread() raises:
    """`Producer.make` runs on the spawning thread, inside `start`, and a
    raise there propagates to the caller with the thread never spawned --
    the status stays `STATUS_NEVER_RAN`, not `STATUS_RAISED`, and no step
    runs. That is what lets `serve` refuse the configuration with 78
    before the server listens, rather than a thread reporting a failure
    the loop has already started serving behind.

    covers: E25
    """
    var page = _page(1_000_000)
    page.store(P_MAKE_RAISES, 1)
    var p = ProducerThread()
    var raised = String("")
    try:
        p.start[Ticker](_ctx(1, page))
    except e:
        raised = String(e)
    assert_true("cannot be built" in raised, "start did not raise the make's error: " + raised)
    assert_false(p.running())
    assert_equal(p.status(), STATUS_NEVER_RAN)
    assert_equal(page.load(P_STEPS), 0)
    assert_equal(p.stop_and_join(1_000_000_000), 0)


def test_an_unstarted_producer_joins_at_once() raises:
    var p = ProducerThread()
    assert_false(p.running())
    assert_equal(p.status(), STATUS_NEVER_RAN)
    assert_equal(p.stop_and_join(5_000_000_000), 0)


def test_what_wants_a_producer() raises:
    var page = _page(1)
    var ctx = _ctx(1, page)
    assert_false(NoProducer.wanted(ctx))
    assert_true(Ticker.wanted(ctx))
    assert_true(ctx.tick_owner())


def test_page_slots_default_to_none() raises:
    assert_equal(Plain.page_slots(4), 0)
    assert_equal(Plain.max_workers(), 0)


def test_a_views_app_answers_for_its_state() raises:
    """`ViewsApp` forwards the state's page and worker limit, and builds it."""
    assert_equal(ViewsApp[OneProcess].page_slots(2), 6)
    assert_equal(ViewsApp[OneProcess].max_workers(), 1)
    var page = _page(1)
    var app = ViewsApp[OneProcess].make(_ctx(1, page))
    assert_equal(app.state.worker, 0)


def test_the_host_refuses_more_workers_than_the_app_serves() raises:
    """An application whose state is per process is not served twice.

    covers: E21
    """
    _ = setenv("M0_WORKERS", "2", True)
    var config = AppConfig()
    _ = unsetenv("M0_WORKERS")
    var why = host_refusal(config, 1)
    assert_true(Bool(why), "two workers were served for a one-process app")
    assert_true("M0_WORKERS=2" in why.value(), "the refusal does not name M0_WORKERS")
    assert_false(Bool(host_refusal(config, 2)))
    assert_false(Bool(host_refusal(config, 0)))
    assert_false(Bool(host_refusal(AppConfig(), 1)))


def _refusal_for(name: String, value: String) raises -> Optional[String]:
    _ = setenv(name, value, True)
    var config = AppConfig()
    _ = unsetenv(name)
    return host_refusal(config)


def test_the_host_refuses_what_it_does_not_serve() raises:
    for name in [String("M0_THREADS"), String("M0_SPAWN_WORKERS")]:
        var why = _refusal_for(name, String("2") if name != "M0_SPAWN_WORKERS" else String("1"))
        assert_true(Bool(why), name + " was not refused")
        assert_true(name in why.value(), "the refusal does not name " + name)
    assert_true(Bool(_refusal_for("M0_WORKERS", "0")))
    # An exec'd m0serve worker's marker, inherited by a Mojo host. Read by
    # `host_refusal` itself, not through the config, so it is set around
    # the call.
    _ = setenv("M0_WORKER_INDEX", "0", True)
    _ = setenv("M0_WORKER_SPAWNED", "1", True)
    var spawned = host_refusal(AppConfig())
    _ = unsetenv("M0_WORKER_SPAWNED")
    _ = unsetenv("M0_WORKER_INDEX")
    assert_true(Bool(spawned), "an inherited spawn marker was served")
    assert_true("M0_WORKER_SPAWNED" in spawned.value())


def test_the_host_serves_what_it_does() raises:
    """What the host does serve is not refused, the pool lane included.

    covers: E26
    """
    assert_false(Bool(host_refusal(AppConfig())))
    assert_false(Bool(_refusal_for("M0_WORKERS", "4")))
    # Present at their defaults is not a request for the other mode.
    assert_false(Bool(_refusal_for("M0_THREADS", "1")))
    assert_false(Bool(_refusal_for("M0_BLOCKING_THREADS", "0")))
    # The pool lane is served (D31), where v1 refused it (D29).
    assert_false(Bool(_refusal_for("M0_BLOCKING_THREADS", "4")))


def test_a_pool_lane_builds_the_handler_for_its_thread() raises:
    """`PoolLane[H].make` reads the worker's context back through
    `PoolContext.user` and hands `H.make` a copy naming the thread; the
    loop's own instance is built with `thread = -1`.

    covers: E26
    """
    var page = _page(1)
    var ctx = _ctx(2, page)
    assert_equal(Plain.make(ctx).thread, -1)
    assert_true(ctx.on_loop())
    var ctx_ptr = Pointer(to=ctx)
    var addr = Pointer(to=ctx_ptr).unsafe_bitcast[Int]()[]
    var lane = PoolLane[Plain].make(PoolContext(2, addr))
    assert_equal(lane.inner.thread, 2)
    var resp = lane.func(HTTPRequest(URI.parse(String("http://127.0.0.1/"))))
    assert_equal(resp.status_code, 200)
    _ = ctx


def test_a_pool_lane_reports_a_make_that_raised() raises:
    """A pool thread that cannot build the handler is counted by
    `wait_ready`, which is what turns it into the host's 78 rather than a
    pool one thread short (D30 on the lane).

    covers: E26
    """
    var page = _page(1)
    var ctx = _ctx(1, page)
    var ctx_ptr = Pointer(to=ctx)
    var addr = Pointer(to=ctx_ptr).unsafe_bitcast[Int]()[]
    var pool = OffloadPool(8)
    var threads = MojoPool(2)
    threads.start[PoolLane[Unbuildable]](pool.addr(), user=addr)
    assert_equal(threads.wait_ready(5_000_000_000), 2)
    _ = threads.stop_and_join(pool, 5_000_000_000)
    var sound = MojoPool(2)
    var pool2 = OffloadPool(8)
    sound.start[PoolLane[Plain]](pool2.addr(), user=addr)
    assert_equal(sound.wait_ready(5_000_000_000), 0)
    _ = sound.stop_and_join(pool2, 5_000_000_000)
    _ = ctx


def test_a_stop_stamped_by_the_loop_shortens_the_join() raises:
    """The loop stamps the stop word as its drain begins, so the join
    afterwards waits only for what is left of the bound. Stamped 900 ms
    ago, a 1 s bound has 100 ms left: the join must give up on a step
    still running well inside the bound, not wait the whole second again.
    `test_an_overrunning_step_is_abandoned_within_the_bound` is the
    unstamped control, which waits the whole bound.

    covers: E23
    """
    var page = _page(1_000_000, cost_ns=3_000_000_000)
    var ctx = _ctx(1, page)
    var producer = ProducerThread()
    producer.start[Ticker](ctx)
    sleep(0.05)
    assert_equal(producer.drain_began(), 0)
    # What the loop does at `_shutdown_begin`, 900 ms in the past.
    atomic_at(producer.stop_addr())[].store(Int64(perf_counter_ns() - 900_000_000))
    assert_true(producer.drain_began() > 0)
    var t0 = perf_counter_ns()
    var left = producer.stop_and_join(1_000_000_000)
    var took_ms = (perf_counter_ns() - t0) // 1_000_000
    assert_equal(left, 1, "the step should still be running")
    assert_true(took_ms < 500, String("the join waited ", took_ms, " ms, not the ~100 left"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
