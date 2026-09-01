"""Tests for the cross-worker broadcast bus and shared atomics.

The bus is exercised in-process: all channels of a `BroadcastBus` live in this
one process, so publishing as worker 0 and draining as worker 1 proves the
datagram path without forking. The fork half — descriptors and the mmap page
surviving into children — is proven by the multi-worker phase of
`poe smoke-counter` against the real server.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.broadcast import (
    BroadcastBus, BUS_MAX_FRAME, CHANNEL_CONTROL_BYTE,
    channel_is_reserved,
    encode_bus_frame, decode_bus_frame, drain_bus_channel,
    publish_to_channels,
)
from lightbug_http.c.kqueue import set_nonblocking, is_nonblocking
from lightbug_http.c.socketpair import socketpair_dgram

from src.multiworker import SharedAtomics, shared_fetch_add, shared_load, shared_store


def _bytes(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def asgi_stream_url_like(kind: String, slot: Int) -> String:
    """A reserved channel name, built the way m0-wsgi builds them.

    Spelled out here rather than imported: m0-http is the lower package and
    may not import m0_wsgi (that is the zero-upward-imports rule). It has to
    match `asgi_stream_url` in `m0-wsgi/src/handler.mojo` — which is the
    point of the test, since the wire format is the shared contract.
    """
    var b = List[UInt8]()
    b.append(CHANNEL_CONTROL_BYTE)
    for ch in kind.as_bytes():
        b.append(ch)
    b.append(UInt8(ord("/")))
    for ch in String(slot).as_bytes():
        b.append(ch)
    return String(StringSlice(unsafe_from_utf8=Span(b)))


def _text(buf: List[UInt8]) -> String:
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


# --- Codec -------------------------------------------------------------------

def test_codec_round_trips() raises:
    var frame = _bytes("event: datastar-patch-signals\nid: 42\ndata: signals {}\n\n")
    var dg = encode_bus_frame("/events", 42, Span(frame))
    var decoded = decode_bus_frame(Span(dg))
    assert_true(Bool(decoded))
    var f = decoded.take()
    assert_equal(f.url, "/events")
    assert_equal(f.event_id, 42)
    assert_equal(_text(f.frame), _text(frame))


def test_codec_survives_large_ids_and_empty_frames() raises:
    """Ids well past 32 bits must survive; an empty frame is legal."""
    var dg = encode_bus_frame("/e", 1 << 40, Span(List[UInt8]()))
    var decoded = decode_bus_frame(Span(dg))
    var f = decoded.take()
    assert_equal(f.event_id, 1 << 40)
    assert_equal(len(f.frame), 0)


def test_codec_rejects_truncation() raises:
    """A datagram cut anywhere in the header or url is dropped, not misread."""
    var dg = encode_bus_frame("/events", 7, Span(_bytes("data\n\n")))
    assert_false(Bool(decode_bus_frame(Span(dg)[:5])))   # inside the id
    assert_false(Bool(decode_bus_frame(Span(dg)[:9])))   # inside url_len
    assert_false(Bool(decode_bus_frame(Span(dg)[:12])))  # inside the url
    assert_false(Bool(decode_bus_frame(Span(List[UInt8]()))))


# --- Bus ---------------------------------------------------------------------

def test_publish_reaches_every_peer_but_not_self() raises:
    var bus = BroadcastBus(3)
    bus.publish(0, "/events", 1, Span(_bytes("f\n\n")))
    assert_equal(len(drain_bus_channel(bus.read_fd(1))), 1)
    assert_equal(len(drain_bus_channel(bus.read_fd(2))), 1)
    assert_equal(len(drain_bus_channel(bus.read_fd(0))), 0)


def test_drain_preserves_order_and_boundaries() raises:
    """Two publishes arrive as two frames, in order, bytes intact."""
    var bus = BroadcastBus(2)
    bus.publish(0, "/a", 1, Span(_bytes("one\n\n")))
    bus.publish(0, "/b", 2, Span(_bytes("two\n\n")))
    var got = drain_bus_channel(bus.read_fd(1))
    assert_equal(len(got), 2)
    assert_equal(got[0].url, "/a")
    assert_equal(_text(got[0].frame), "one\n\n")
    assert_equal(got[1].url, "/b")
    assert_equal(got[1].event_id, 2)


def test_drain_empty_channel_returns_nothing() raises:
    var bus = BroadcastBus(2)
    assert_equal(len(drain_bus_channel(bus.read_fd(1))), 0)


def test_max_size_frame_crosses_the_bus() raises:
    """A frame at exactly BUS_MAX_FRAME must survive; one past it must not.

    The cap matches the registry's MAX_PENDING_BYTES: anything bigger could
    not be queued for any subscriber, so dropping it loses nothing.
    """
    var bus = BroadcastBus(2)
    var big = List[UInt8](capacity=BUS_MAX_FRAME)
    for _ in range(BUS_MAX_FRAME):
        big.append(UInt8(ord("x")))
    bus.publish(0, "/e", 1, Span(big))
    var got = drain_bus_channel(bus.read_fd(1))
    assert_equal(len(got), 1)
    assert_equal(len(got[0].frame), BUS_MAX_FRAME)

    big.append(UInt8(ord("x")))
    bus.publish(0, "/e", 2, Span(big))
    assert_equal(len(drain_bus_channel(bus.read_fd(1))), 0)


def test_publish_to_channels_skips_named_worker() raises:
    """The free-function form (what DatastarStream holds) behaves like the bus."""
    var bus = BroadcastBus(2)
    publish_to_channels(bus.write_fds, 1, "/e", 5, Span(_bytes("f\n\n")))
    assert_equal(len(drain_bus_channel(bus.read_fd(0))), 1)
    assert_equal(len(drain_bus_channel(bus.read_fd(1))), 0)


# --- the reserved control namespace -----------------------------------------

def test_channel_is_reserved_identifies_the_control_namespace() raises:
    """Only a LEADING 0x01 is reserved — the byte elsewhere is an ordinary
    (if odd) channel name, and refusing those would break apps needlessly."""
    assert_true(channel_is_reserved(asgi_stream_url_like("s", 3)))
    assert_true(channel_is_reserved(String("\x01")))
    assert_false(channel_is_reserved(String("news")))
    assert_false(channel_is_reserved(String("")))
    assert_false(channel_is_reserved(String("news\x01")))


def test_publish_rejects_reserved_channel() raises:
    """An application publish may not address the internal namespace.

    This is the fix for a confirmed hole, so the test is written as the
    attack: the m0-wsgi handler reads a bus frame named `\\x01s/<slot>` as
    "queue these bytes into connection slot <slot>'s stream", ignoring what
    that connection actually subscribed to. Application channel names are
    routinely user input — the shipped django_realtime `/publish` view takes
    `request.POST['channel']`, and `%01` in a form body decodes to a real
    control byte — so an unauthenticated POST could inject events into, or
    tear down, any other client's stream. Publishing is where an untrusted
    name crosses into the namespace, so that is where it is refused.

    Internal senders are unaffected: they build `encode_bus_frame`
    datagrams and send them directly, never through `publish_to_channels`.

    covers: G7
    """
    var bus = BroadcastBus(2)

    # The attack: every reserved kind the handler acts on.
    var kinds = [
        String("s"), String("e"), String("b"), String("h"),
        String("H"), String("B"), String("w"), String("x"),
        String("P"),
    ]
    for kind in kinds:
        publish_to_channels(
            bus.write_fds, 1, asgi_stream_url_like(kind, 0), 1,
            Span(_bytes("event: message\ndata: injected\n\n")),
        )
    assert_equal(len(drain_bus_channel(bus.read_fd(0))), 0)

    # The control: an ordinary channel still goes through, so the guard is
    # rejecting the namespace and not simply breaking publish.
    publish_to_channels(bus.write_fds, 1, "news", 1, Span(_bytes("f\n\n")))
    var got = drain_bus_channel(bus.read_fd(0))
    assert_equal(len(got), 1)
    assert_equal(got[0].url, "news")


def test_bus_publish_method_rejects_reserved_channel() raises:
    """The method form shares the guard — it delegates to the free function.

    covers: G8
    """
    var bus = BroadcastBus(2)
    bus.publish(0, asgi_stream_url_like("s", 7), 1, Span(_bytes("x\n\n")))
    assert_equal(len(drain_bus_channel(bus.read_fd(1))), 0)


# --- set_nonblocking (the Darwin variadic-fcntl fix) -------------------------

def test_set_nonblocking_takes_effect() raises:
    """O_NONBLOCK must actually be set — per F_GETFL, not per hope.

    On ARM64 macOS this was a silent no-op for the fork's whole life (the
    variadic third argument never reached fcntl), which is how the bus's
    drain loop hung a CI runner. The padded-call fix in `_fcntl` is ABI
    reasoning; this test is what holds it to account on the macOS runner —
    and it probes via F_GETFL, which never had the bug, rather than by
    recv-blocking, which would hang the suite instead of failing it.
    """
    var pair = socketpair_dgram()
    var a = FileDescriptor(pair[0])
    assert_false(is_nonblocking(a))
    set_nonblocking(a)
    assert_true(is_nonblocking(a))
    # The other end is untouched: the flag is per-fd, not per-pair.
    assert_false(is_nonblocking(FileDescriptor(pair[1])))


def test_bus_channels_are_nonblocking() raises:
    """Every bus fd carries O_NONBLOCK from construction.

    MSG_DONTWAIT on each call is the guarantee the drain loop relies on;
    this asserts the belt under the braces is real too.
    """
    var bus = BroadcastBus(2)
    for w in range(2):
        assert_true(is_nonblocking(FileDescriptor(bus.read_fds[w])))
        assert_true(is_nonblocking(FileDescriptor(bus.write_fds[w])))


# --- Shared atomics ----------------------------------------------------------

def test_shared_atomics_slots_are_independent() raises:
    var shm = SharedAtomics(3)
    shm.store(0, 10)
    shm.store(2, 30)
    assert_equal(shm.load(0), 10)
    assert_equal(shm.load(1), 0)
    assert_equal(shm.load(2), 30)


def test_shared_fetch_add_returns_previous() raises:
    var shm = SharedAtomics(1)
    assert_equal(shm.fetch_add(0, 5), 0)
    assert_equal(shm.fetch_add(0, -2), 5)
    assert_equal(shm.load(0), 3)


def test_shared_addr_form_aliases_the_same_slot() raises:
    """The Int-address form (how DatastarStream holds a slot) sees the
    same memory as the struct."""
    var shm = SharedAtomics(2)
    var a = shm.addr(1)
    shared_store(a, 7)
    assert_equal(shm.load(1), 7)
    assert_equal(shared_fetch_add(a, 1), 7)
    assert_equal(shared_load(a), 8)


def test_shared_addr_zero_fails_soft() raises:
    """An unwired consumer (addr 0) must not crash — it just gets zeros."""
    assert_equal(shared_fetch_add(0, 5), 0)
    assert_equal(shared_load(0), 0)
    shared_store(0, 9)


def test_shared_atomics_out_of_range_addr_is_zero() raises:
    var shm = SharedAtomics(1)
    assert_equal(shm.addr(-1), 0)
    assert_equal(shm.addr(1), 0)
    assert_true(shm.addr(0) != 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
