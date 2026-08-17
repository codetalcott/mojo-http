"""WSHub — the handler-side WebSocket registry, local and across the bus.

The bus tests use real socketpairs (a `BroadcastBus`), so what's asserted
is the actual cross-worker path: hub A broadcasts, the datagram is drained
from hub B's channel exactly as the event loop would, and `deliver_peer`
queues it for B's sockets — not a mock of any of that.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.broadcast import BroadcastBus, drain_bus_channel
from src.multiworker import SharedAtomics
from src.ws import WSHub


def _frame(text: String) raises -> List[UInt8]:
    return List[UInt8](text.as_bytes())


def _text(bytes: List[UInt8]) raises -> String:
    return String(StringSlice(unsafe_from_utf8=Span(bytes)))


# --- Local registry -----------------------------------------------------------


def test_open_drain_close_lifecycle() raises:
    var hub = WSHub(8)
    assert_equal(hub.count(), 0)
    hub.open(3)
    assert_true(hub.is_connected(3))
    assert_equal(hub.count(), 1)
    hub.send(3, _frame("hi"))
    assert_equal(_text(hub.drain(3)), "hi")
    assert_equal(len(hub.drain(3)), 0)  # drained means drained
    hub.closed(3)
    assert_false(hub.is_connected(3))
    assert_equal(hub.count(), 0)


def test_broadcast_reaches_every_connection_only() raises:
    var hub = WSHub(8)
    hub.open(1)
    hub.open(4)
    hub.broadcast("/chat", _frame("all"))
    assert_equal(_text(hub.drain(1)), "all")
    assert_equal(_text(hub.drain(4)), "all")
    assert_equal(len(hub.drain(2)), 0)  # never connected, never queued


def test_send_to_disconnected_slot_is_dropped() raises:
    var hub = WSHub(8)
    hub.send(2, _frame("void"))
    assert_equal(len(hub.drain(2)), 0)


def test_close_discards_undrained_bytes() raises:
    # A vanished client's queued frames must not survive into the next
    # connection that reuses the slot.
    var hub = WSHub(8)
    hub.open(5)
    hub.send(5, _frame("stale"))
    hub.closed(5)
    hub.open(5)
    assert_equal(len(hub.drain(5)), 0)


def test_out_of_range_slots_are_ignored() raises:
    var hub = WSHub(4)
    hub.open(-1)
    hub.open(99)
    hub.send(99, _frame("x"))
    assert_equal(hub.count(), 0)
    assert_equal(len(hub.drain(99)), 0)


def test_frames_queue_in_order() raises:
    var hub = WSHub(4)
    hub.open(0)
    hub.send(0, _frame("one"))
    hub.send(0, _frame("two"))
    assert_equal(_text(hub.drain(0)), "onetwo")


# --- Across the bus -----------------------------------------------------------


def test_broadcast_publishes_to_peer_channels() raises:
    var bus = BroadcastBus(2)
    var shared = SharedAtomics(1)
    var hub_a = WSHub(4)
    hub_a.enable_bus(bus, 0, shared.addr(0))
    hub_a.open(1)

    hub_a.broadcast("/chat", _frame("hello peers"))

    # Local delivery happened...
    assert_equal(_text(hub_a.drain(1)), "hello peers")
    # ...and worker 1's channel carries the frame (worker 0's does not:
    # publish skips self).
    var got = drain_bus_channel(bus.read_fd(1))
    assert_equal(len(got), 1)
    assert_equal(got[0].url, "/chat")
    assert_equal(got[0].event_id, 1)
    assert_equal(_text(got[0].frame), "hello peers")
    assert_equal(len(drain_bus_channel(bus.read_fd(0))), 0)


def test_peer_frame_reaches_the_other_hubs_sockets() raises:
    # The full cross-worker path, exactly as the event loop drives it.
    var bus = BroadcastBus(2)
    var shared = SharedAtomics(1)
    var hub_a = WSHub(4)
    var hub_b = WSHub(4)
    hub_a.enable_bus(bus, 0, shared.addr(0))
    hub_b.enable_bus(bus, 1, shared.addr(0))
    hub_b.open(2)

    hub_a.broadcast("/chat", _frame("cross"))
    var got = drain_bus_channel(bus.read_fd(1))
    assert_equal(len(got), 1)
    hub_b.deliver_peer(got[0].frame)

    assert_equal(_text(hub_b.drain(2)), "cross")


def test_bus_ids_are_unique_across_hubs() raises:
    var bus = BroadcastBus(2)
    var shared = SharedAtomics(1)
    var hub_a = WSHub(4)
    var hub_b = WSHub(4)
    hub_a.enable_bus(bus, 0, shared.addr(0))
    hub_b.enable_bus(bus, 1, shared.addr(0))

    hub_a.broadcast("/chat", _frame("a"))
    hub_b.broadcast("/chat", _frame("b"))

    var to_b = drain_bus_channel(bus.read_fd(1))
    var to_a = drain_bus_channel(bus.read_fd(0))
    assert_equal(len(to_b), 1)
    assert_equal(len(to_a), 1)
    assert_true(to_b[0].event_id != to_a[0].event_id)


def test_without_bus_broadcast_is_local_only() raises:
    var bus = BroadcastBus(2)
    var hub = WSHub(4)  # never joined the bus
    hub.open(0)
    hub.broadcast("/chat", _frame("local"))
    assert_equal(_text(hub.drain(0)), "local")
    assert_equal(len(drain_bus_channel(bus.read_fd(1))), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
