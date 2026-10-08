"""A timer's slot in the epoll backend's map is its own at any descriptor
number (review record LF18).

`EpollBackend` keeps each timer's timerfd in a map indexed by the timer's
ident, `TIMER_<kind> + fd`. The map was five regions of 65536, one per
kind, so a descriptor at or above 65536 spilled into the next kind's
region: the SSE heartbeat of descriptor 65536 took the app tick's slot,
and the body timer of descriptor 131072 + k the heartbeat of descriptor k.
Adding the newcomer's timer re-armed the other one's timerfd, so the wrong
connection's timer fired, and deleting it closed the other one's timerfd
-- the app tick's included, which then never fired again. A descriptor
reaches 65536 wherever `RLIMIT_NOFILE` allows it, and the accept path
grows its own map past that. The slot is now `fd * 5 + kind` in a map
that grows with the descriptors timers are set for.

`_timer_slot` is arithmetic, so its test runs on every platform. The
other two drive the platform's backend: on Linux the epoll one, where
the aliasing was; on macOS kqueue, which keys a timer by its ident and
passes them either way.
"""

from std.testing import TestSuite, assert_equal, assert_true

from lightbug_http.c.epoll_backend import _timer_slot
from lightbug_http.c.kqueue import EVFILT_TIMER
from lightbug_http.c.platform import PlatformBackend
from lightbug_http.loop.state import (
    TIMER_APP_TICK, TIMER_BODY, TIMER_HEADER, TIMER_IDLE, TIMER_SSE_HEARTBEAT,
)


def test_every_timer_has_a_slot_of_its_own_at_any_descriptor() raises:
    """Every (kind, descriptor) pair maps to a slot no other pair takes, for
    descriptors on both sides of 65536 and of twice that.

    covers: C11
    """
    var kinds: List[UInt] = [
        TIMER_HEADER, TIMER_BODY, TIMER_IDLE, TIMER_SSE_HEARTBEAT,
    ]
    var fds: List[Int] = [0, 1, 5, 65535, 65536, 65537, 65541, 131072, 131077, 200000]
    var seen = List[Int]()
    var names = List[String]()
    for k in kinds:
        for fd in fds:
            seen.append(_timer_slot(k + UInt(fd)))
            names.append(String(k + UInt(fd)))
    seen.append(_timer_slot(TIMER_APP_TICK))
    names.append(String("the app tick"))
    for i in range(len(seen)):
        assert_true(seen[i] >= 0, String("no slot for ident ", names[i]))
        for j in range(i + 1, len(seen)):
            assert_true(
                seen[i] != seen[j],
                String("ident ", names[i], " and ", names[j], " share slot ", seen[i]),
            )


def _first_timer(mut backend: PlatformBackend, wait_ms: Int) raises -> Int:
    """The ident of the first timer event within `wait_ms`, or -1."""
    var n = backend.wait(wait_ms)
    for i in range(n):
        if backend.event_filter(i) == EVFILT_TIMER:
            return Int(backend.event_ident(i))
    return -1


def test_a_high_descriptors_heartbeat_leaves_the_app_tick_alone() raises:
    """With the app tick armed, a heartbeat set and deleted for descriptor
    65536 -- whose slot was the app tick's -- leaves the tick to fire."""
    var backend = PlatformBackend()
    backend.try_add_timer(TIMER_APP_TICK, 50)
    backend.try_add_timer(TIMER_SSE_HEARTBEAT + 65536, 60_000)
    backend.try_delete_timer(TIMER_SSE_HEARTBEAT + 65536)
    var fired = _first_timer(backend, 2000)
    assert_equal(
        fired, Int(TIMER_APP_TICK),
        "the app tick did not fire after descriptor 65536's heartbeat was deleted",
    )


def test_a_high_descriptors_body_timer_is_its_own() raises:
    """With descriptor 5's heartbeat armed for a minute, a 50 ms body timer
    for descriptor 131077 -- whose slot was that heartbeat's -- fires as
    its own, and the heartbeat does not."""
    var backend = PlatformBackend()
    backend.try_add_timer(TIMER_SSE_HEARTBEAT + 5, 60_000)
    backend.try_add_timer(TIMER_BODY + 131077, 50)
    var fired = _first_timer(backend, 2000)
    assert_equal(
        fired, Int(TIMER_BODY + 131077),
        "the body timer of descriptor 131077 fired as another timer, or not at all",
    )
    backend.try_delete_timer(TIMER_SSE_HEARTBEAT + 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
