"""The Mojo host's pieces that run without a server: the producer thread, the
publisher, and the refusals.

`serve` itself forks, binds and signals, so it is gated on the wire
(`smoke-host`, SPEC E21-E23). What is proven here is what that gate would
only see as a symptom: that a producer's frames reach EVERY channel, that
its cadence never catches up, that a stop is prompt however long the period,
that an overrunning step is abandoned inside the bound rather than waited
for, and that a raising step ends the thread with a status.
"""

from std.os import setenv, unsetenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns, sleep

from lightbug_http.broadcast import BUS_MAX_FRAME, BroadcastBus, drain_bus_channel
from lightbug_http.host import (
    AppHandler,
    HostContext,
    NoProducer,
    Producer,
    ProducerThread,
    Publisher,
    ViewState,
    ViewsApp,
    host_refusal,
)
from lightbug_http.http import HTTPRequest, HTTPResponse, OK
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
comptime P_SLOTS = 5


def _ctx(workers: Int, page: SharedAtomics) raises -> HostContext:
    var bus = BroadcastBus(workers)
    return HostContext(0, workers, 64, page.addr(0), 0, bus^, AppConfig())


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
        _ = out.publish("/t", self.step_no, frame.as_bytes())
        _ = shared_fetch_add(self.page + P_STEPS * 8, 1)
        return self.load(P_PERIOD_NS)


struct Plain(AppHandler):
    """The smallest handler: `make` and `func`, nothing else."""

    def __init__(out self):
        pass

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return Plain()

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return OK("plain")


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


def test_publisher_reaches_every_channel() raises:
    var bus = BroadcastBus(3)
    var out = Publisher(bus.write_fds.copy())
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
    var out = Publisher(bus.write_fds.copy())
    var big = List[UInt8](length=BUS_MAX_FRAME + 1, fill=UInt8(120))
    assert_false(out.publish("/c", 1, Span(big)))
    # A reserved channel is refused too, not delivered.
    var small = String("x")
    assert_false(out.publish("\x01s/1", 2, small.as_bytes()))
    assert_equal(out.refused, 2)
    assert_equal(len(drain_bus_channel(bus.read_fd(0))), 0)
    assert_equal(len(drain_bus_channel(bus.read_fd(1))), 0)


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
    for name in [
        String("M0_THREADS"), String("M0_BLOCKING_THREADS"), String("M0_SPAWN_WORKERS"),
    ]:
        var why = _refusal_for(name, String("2") if name != "M0_SPAWN_WORKERS" else String("1"))
        assert_true(Bool(why), name + " was not refused")
        assert_true(name in why.value(), "the refusal does not name " + name)
    assert_true(Bool(_refusal_for("M0_WORKERS", "0")))


def test_the_host_serves_what_it_does() raises:
    assert_false(Bool(host_refusal(AppConfig())))
    assert_false(Bool(_refusal_for("M0_WORKERS", "4")))
    # Present at their defaults is not a request for the other mode.
    assert_false(Bool(_refusal_for("M0_THREADS", "1")))
    assert_false(Bool(_refusal_for("M0_BLOCKING_THREADS", "0")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
