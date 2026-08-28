"""The `HTTPService` contract: `func` is required, the other eight default.

This file is the guard for the trait's default bodies. `MinimalService`
implements `func` and nothing else — **it not compiling is the failure**, so
the assertions below are secondary to the file existing at all. Revert any
default in `service.mojo` to `...` and `poe test-http` fails naming this file.

The defaults are not cosmetic. The event loop calls all nine methods on every
handler regardless of what the handler cares about (`event_loop.mojo` is
parameterized on `[T: HTTPService, B: EventLoopBackend]`), so a default that
returned the wrong thing would be a silent behaviour change across every app
rather than a compile error. That is what the value assertions pin: an empty
drain, a non-streaming slot, and a `before_request` that does not
short-circuit.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.http import HTTPRequest, HTTPResponse, OK
from lightbug_http.service import HTTPService
from lightbug_http.uri import URI


@fieldwise_init
struct MinimalService(HTTPService):
    """Implements ONLY `func`. Everything else is inherited from the trait."""

    var calls: Int

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        self.calls += 1
        return OK("ok", "text/plain")


@fieldwise_init
struct OverridingService(HTTPService):
    """Implements `func` and overrides two defaults, to pin that overriding works."""

    var ticks: Int

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return OK("ok", "text/plain")

    def sse_is_streaming(self, slot: Int) -> Bool:
        return True

    def tick(mut self, now_ms: Int):
        self.ticks += 1


def _request() raises -> HTTPRequest:
    return HTTPRequest(URI.parse("http://127.0.0.1:8080/"))


def test_minimal_service_answers() raises:
    """A handler that writes only `func` is a complete `HTTPService`."""
    var s = MinimalService(0)
    var resp = s.func(_request())
    assert_equal(resp.status_code, 200)
    assert_equal(s.calls, 1)


def test_default_before_request_does_not_short_circuit() raises:
    """The default must return None, or every request would be answered by it."""
    var s = MinimalService(0)
    var early = s.before_request(_request())
    assert_false(Bool(early))


def test_default_sse_drain_is_empty() raises:
    """The loop drains every slot each pass; a non-empty default would inject bytes."""
    var s = MinimalService(0)
    assert_equal(len(s.sse_drain_slot(0)), 0)


def test_default_sse_is_streaming_is_false() raises:
    """True here would make the loop hold every connection open."""
    var s = MinimalService(0)
    assert_false(s.sse_is_streaming(0))


def test_default_hooks_are_callable_and_inert() raises:
    """The four `pass` defaults must exist and change nothing observable."""
    var s = MinimalService(0)
    var resp = OK("ok", "text/plain")
    s.after_response(String("GET"), String("/"), resp)
    s.sse_slot_disconnected(0)
    s.sse_peer_frame(String("/events"), 1, List[UInt8]())
    s.tick(1000)
    s.ws_message(0, 1, List[UInt8]())
    assert_equal(s.calls, 0)


def test_overriding_a_default_wins() raises:
    """A handler's own implementation must beat the trait's."""
    var s = OverridingService(0)
    assert_true(s.sse_is_streaming(0))
    s.tick(1000)
    s.tick(2000)
    assert_equal(s.ticks, 2)


def _drive[T: HTTPService](mut svc: T) raises -> Int:
    """Call the trait generically, the way the event loop does."""
    var resp = svc.func(_request())
    var n = len(svc.sse_drain_slot(0))
    svc.tick(1)
    svc.after_response(String("GET"), String("/"), resp)
    return resp.status_code + n


def test_defaults_reach_through_a_generic_bound() raises:
    """`event_loop` is `[T: HTTPService, ...]`; defaults must survive that path."""
    var minimal = MinimalService(0)
    assert_equal(_drive(minimal), 200)
    var overriding = OverridingService(0)
    assert_equal(_drive(overriding), 200)
    assert_equal(overriding.ticks, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
