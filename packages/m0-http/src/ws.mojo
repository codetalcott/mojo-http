"""WSHub — the handler-side registry for WebSocket connections.

The event loop owns the protocol (`lightbug_http/websocket.mojo` parses
frames, answers pings, closes violators); what a handler still has to
manage is *who is connected and what they should be sent*. `WSHub` is that
bookkeeping, shaped like `DatastarStream` so the wiring reads the same:

    handler.func:                 hub.open(req.slot_id) after websocket_upgrade
    handler.ws_message:           hub.broadcast(url, frame_bytes)
    handler.sse_drain_slot:       return hub.drain(slot)
    handler.sse_is_streaming:     return hub.is_connected(slot)
    handler.sse_slot_disconnected hub.closed(slot)
    handler.sse_peer_frame:       hub.deliver_peer(frame_bytes)

Cross-worker fan-out rides the same `BroadcastBus` SSE uses — the bus never
cared what its payload bytes were, and `sse_peer_frame` is simply "a peer
worker broadcast something". A hub that joined the bus (`enable_bus`)
publishes every broadcast to peer workers, and each peer's hub queues the
frame for its own sockets. Delivery is at-least-once locally and
best-effort across workers, in bus arrival order: chat-shaped traffic,
where every message is an independent frame, wants exactly this; state
replication with replay wants `DatastarStream` instead.

Parallel `List` fields rather than a `List[Struct]` — the SoA pattern this
repo uses to sidestep `ImplicitlyCopyable` constraints.
"""

from lightbug_http.broadcast import BroadcastBus, publish_to_channels

from .multiworker import shared_fetch_add


struct WSHub(Movable):
    """Connected-slot registry with per-slot outboxes and bus fan-out."""

    var connected: List[Bool]
    var outbox: List[List[UInt8]]
    var capacity: Int

    # Bus state — empty/idle until enable_bus. Write fds are plain ints, so
    # holding a copy (instead of the whole bus) keeps this struct cheap.
    var bus_write_fds: List[Int]
    var bus_worker: Int
    var shared_id_addr: Int

    def __init__(out self, capacity: Int):
        """`capacity` must be at least the server's max connections — slots
        index these lists directly by `req.slot_id`."""
        self.connected = List[Bool](capacity=capacity)
        self.outbox = List[List[UInt8]](capacity=capacity)
        self.capacity = capacity
        for _ in range(capacity):
            self.connected.append(False)
            self.outbox.append(List[UInt8]())
        self.bus_write_fds = List[Int]()
        self.bus_worker = -1
        self.shared_id_addr = 0

    def _in_range(self, slot: Int) -> Bool:
        return slot >= 0 and slot < self.capacity

    # --- Connection lifecycle ----------------------------------------------

    def open(mut self, slot: Int):
        """Register an upgraded connection. Call right after
        `websocket_upgrade` returned the 101, with `req.slot_id`."""
        if not self._in_range(slot):
            return
        self.connected[slot] = True
        self.outbox[slot].clear()

    def closed(mut self, slot: Int):
        """Release a slot. Wire to `sse_slot_disconnected` — it fires on
        every close path (close handshake, vanished client, dead ping)."""
        if not self._in_range(slot):
            return
        self.connected[slot] = False
        self.outbox[slot].clear()

    def is_connected(self, slot: Int) -> Bool:
        return self._in_range(slot) and self.connected[slot]

    def count(self) -> Int:
        var n = 0
        for s in range(self.capacity):
            if self.connected[s]:
                n += 1
        return n

    # --- Sending ------------------------------------------------------------

    def send(mut self, slot: Int, frame: List[UInt8]):
        """Queue one encoded frame for one connection."""
        if not self.is_connected(slot):
            return
        for j in range(len(frame)):
            self.outbox[slot].append(frame[j])

    def drain(mut self, slot: Int) -> List[UInt8]:
        """Return and clear a slot's pending bytes. Wire to `sse_drain_slot`."""
        if not self._in_range(slot) or len(self.outbox[slot]) == 0:
            return List[UInt8]()
        var pending = self.outbox[slot].copy()
        self.outbox[slot].clear()
        return pending^

    def broadcast(mut self, url: String, frame: List[UInt8]):
        """Queue an encoded frame for every local connection — and, when the
        hub joined a bus, publish it so every peer worker's hub does the
        same. `url` names the endpoint on the bus wire; hubs deliver
        whatever arrives on their channel, so use one url per hub."""
        for s in range(self.capacity):
            if self.connected[s]:
                for j in range(len(frame)):
                    self.outbox[s].append(frame[j])
        if self.bus_worker >= 0:
            var event_id = 0
            if self.shared_id_addr != 0:
                # Ids keep bus datagrams well-formed and debuggable; the hub
                # itself has no redelivery filter to feed.
                event_id = shared_fetch_add(self.shared_id_addr, 1) + 1
            publish_to_channels(
                self.bus_write_fds, self.bus_worker, url, event_id, Span(frame)
            )

    # --- Cross-worker fan-out ----------------------------------------------

    def enable_bus(mut self, bus: BroadcastBus, worker: Int, shared_id_addr: Int):
        """Join a pre-fork `BroadcastBus` as `worker`.

        Same contract as `DatastarStream.enable_bus`: call after
        `fork_all()` in each worker, hand `bus.read_fd(worker)` to the
        server, and wire `sse_peer_frame` to `deliver_peer` — publishing
        without draining fills peers' channels silently. Pass a
        `SharedAtomics.addr` slot for cross-worker frame ids, or 0 to skip.
        """
        self.bus_write_fds = bus.write_fds.copy()
        self.bus_worker = worker
        self.shared_id_addr = shared_id_addr

    def deliver_peer(mut self, frame: List[UInt8]):
        """Queue a peer worker's broadcast for every local connection —
        wire `sse_peer_frame` here (the url and event id are the bus's
        concern; the hub delivers the bytes)."""
        for s in range(self.capacity):
            if self.connected[s]:
                for j in range(len(frame)):
                    self.outbox[s].append(frame[j])
