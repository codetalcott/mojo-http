"""The event loop's per-slot lifecycle.

The transitions (`event_loop.mojo`'s "Per-slot lifecycle" section, review
record C4). Each helper owns the resets of its phase, which is what makes a
stale-state defect a helper's bug rather than one call site's. They are
driven here over `FakeBackend`, which keeps one socket's registration the
way epoll does -- ONE registration, so a read added replaces a pending
write -- the stricter of the two, and the one a wrong arm is wrong on.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from lightbug_http.connection import ConnectionState
from lightbug_http.event_loop import (
    WS_CLOSE_LINGER_NS,
    _arm_ws_linger,
    _await_write,
    _begin_request,
    _end_request,
)
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.io.bytes import Bytes
from lightbug_http.server import ProvisionPool
from lightbug_http.server_config import ServerConfig
from lightbug_http.websocket import WSState


struct FakeBackend(EventLoopBackend):
    """One socket's registration, kept as epoll keeps it: read and write
    interest are ONE registration, so adding reads replaces a pending write
    one-shot, registering the write one-shot replaces the reads, and a
    delete takes both."""

    var read: Bool
    var write: Bool
    var read_adds: Int

    def __init__(out self):
        self.read = False
        self.write = False
        self.read_adds = 0

    def wait(mut self, timeout_ms: Int) raises -> Int:
        return 0

    def event_ident(self, i: Int) -> UInt:
        return 0

    def event_filter(self, i: Int) -> Int16:
        return 0

    def event_flags(self, i: Int) -> UInt16:
        return 0

    def event_data(self, i: Int) -> Int:
        return 0

    def add_read_listen(mut self, fd: Int) raises:
        pass

    def add_read(mut self, fd: Int) raises:
        self.read = True
        self.write = False
        self.read_adds += 1

    def try_add_read(mut self, fd: Int):
        try:
            self.add_read(fd)
        except:
            pass

    def add_write_oneshot(mut self, fd: Int) raises:
        self.write = True
        self.read = False

    def try_add_write_oneshot(mut self, fd: Int):
        try:
            self.add_write_oneshot(fd)
        except:
            pass

    def try_delete_read(mut self, fd: Int):
        self.read = False
        self.write = False

    def try_delete_write(mut self, fd: Int):
        self.write = False

    def try_add_timer(mut self, ident: UInt, timeout_ms: Int):
        pass

    def try_delete_timer(mut self, ident: UInt):
        pass


comptime SLOTS = 4
comptime FD = 7


struct Slots:
    """The loop's per-slot lists, as `prepare_loop` builds them."""

    var response: List[Bytes]
    var send_offset: List[Int]
    var header_start: List[Int]
    var sse: List[Bool]
    var ws: List[Bool]
    var read_armed: List[Bool]
    var deadline: List[Int]
    var ws_state: List[WSState]

    def __init__(out self):
        self.response = List[Bytes]()
        self.send_offset = List[Int]()
        self.header_start = List[Int]()
        self.sse = List[Bool]()
        self.ws = List[Bool]()
        self.read_armed = List[Bool]()
        self.deadline = List[Int]()
        self.ws_state = List[WSState]()
        for _ in range(SLOTS):
            self.response.append(Bytes())
            self.send_offset.append(0)
            self.header_start.append(0)
            self.sse.append(False)
            self.ws.append(False)
            self.read_armed.append(False)
            self.deadline.append(0)
            self.ws_state.append(WSState(1024))


def _config() -> ServerConfig:
    var config = ServerConfig()
    config.idle_timeout = 5
    config.sse_heartbeat_ms = 0
    return config^


def test_the_linger_arms_once() raises:
    """Arm once, and that is the whole bound: the drain reaches its linger
    branches on every pass while a slot lingers, and re-stamping pushed the
    deadline out for good."""
    var s = Slots()
    _arm_ws_linger(1, s.ws_state, s.deadline)
    var first = s.deadline[1]
    assert_true(first > 0)
    assert_true(first <= perf_counter_ns() + WS_CLOSE_LINGER_NS)
    assert_true(s.ws_state[1].closing)
    _arm_ws_linger(1, s.ws_state, s.deadline)
    assert_equal(s.deadline[1], first)


def test_a_request_begins_with_no_idle_deadline() raises:
    """B2: the keep-alive deadline bounds the wait BETWEEN requests, and a
    request's first bytes end it -- left standing it cut an upload begun
    late in the window at the previous response's deadline."""
    var s = Slots()
    s.deadline[2] = perf_counter_ns() + 1_000_000_000
    _begin_request(2, s.deadline)
    assert_equal(s.deadline[2], 0)


def test_the_keepalive_transition_owns_its_resets() raises:
    """`_end_request`: the next request's count, a clean provision, the
    header clock stopped until the next request's bytes, the idle deadline
    in place of any send deadline, and read interest back."""
    var backend = FakeBackend()
    var config = _config()
    var pool = ProvisionPool(SLOTS, config)
    var slot = pool.borrow()
    var s = Slots()
    pool.provisions[slot].state = ConnectionState.responding()
    s.header_start[slot] = perf_counter_ns()
    s.response[slot] = Bytes(String("HTTP/1.1 200 OK\r\n\r\n").as_bytes())
    s.send_offset[slot] = len(s.response[slot])
    assert_true(_await_write(backend, slot, FD, s.read_armed))
    assert_false(s.read_armed[slot])
    var before = perf_counter_ns()
    _end_request(
        backend, slot, FD, config, s.response, s.send_offset, s.header_start,
        pool, s.read_armed, s.deadline,
    )
    assert_equal(pool.provisions[slot].keepalive_count, 1)
    assert_equal(pool.provisions[slot].state.kind, ConnectionState.READING_HEADERS)
    assert_equal(s.header_start[slot], 0)
    assert_equal(s.send_offset[slot], 0)
    assert_equal(len(s.response[slot]), 0)
    assert_true(s.deadline[slot] >= before + config.idle_timeout * 1_000_000_000)
    assert_true(backend.read)
    assert_true(s.read_armed[slot])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
