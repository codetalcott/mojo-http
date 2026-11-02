"""SSE subscriber registry.

Manages which connection slots are subscribed to SSE streams,
queues outbound data for the event loop to drain.
Parallel arrays indexed by slot_id (SoA pattern).
"""

from .format import format_sse_event_bytes, NO_EVENT_ID

# Backpressure: drop events if a slot's pending buffer exceeds this size.
comptime MAX_PENDING_BYTES = 65536

# The methods a loop reaches once a stream a pass (`drain`,
# `is_slot_streaming`, `has_pending`) or once a subscriber a frame
# (`mark_ready`) are `@always_inline`, and it is load-bearing: a `mut self`
# of 256 B or less is copied in and stored back at a call boundary
# (docs/notes/mut-arguments-and-raw-addresses.md), and this struct is
# 160 B. Called, the Mojo host's counter at 1008 idle streams answered
# 145.3k requests a second, the copy at every stream's visit; inlined into
# a caller that holds the registry by reference, 151.1k (SPEC C24).


struct SSERegistry:
    """Manages SSE stream subscriptions and outbound event queues."""

    var is_streaming: List[Bool]
    var filter_urls: List[String]
    var last_event_ids: List[Int]
    var pending_bufs: List[List[UInt8]]
    var _capacity: Int
    var ready: List[Int]
    """Slots whose outbox has gained bytes, or whose subscription has ended,
    since the last `take_ready`: what a handler names to the loop's drain
    (`take_ready_streams`, SPEC C24). Each slot at most once."""
    var _named: List[Bool]
    var _active: Int
    """Slots streaming now, kept as `subscribe` and `unsubscribe` change
    them, the only writers of `is_streaming`: `active_count` is m0serve's
    health answer under `--realtime`, and counting there walked every slot
    on every health check (SPEC C24)."""

    def __init__(out self, capacity: Int):
        self._capacity = capacity
        self.is_streaming = List[Bool](capacity=capacity)
        self.filter_urls = List[String](capacity=capacity)
        self.last_event_ids = List[Int](capacity=capacity)
        self.pending_bufs = List[List[UInt8]](capacity=capacity)
        self.ready = List[Int]()
        self._named = List[Bool](length=capacity, fill=False)
        self._active = 0
        for _ in range(capacity):
            self.is_streaming.append(False)
            self.filter_urls.append(String(""))
            self.last_event_ids.append(0)
            self.pending_bufs.append(List[UInt8]())

    def subscribe(mut self, slot: Int, url: String, last_event_id: Int):
        """Register a slot as an SSE stream subscriber for the given URL."""
        if slot < 0 or slot >= self._capacity:
            return
        if not self.is_streaming[slot]:
            self._active += 1
        self.is_streaming[slot] = True
        self.filter_urls[slot] = url
        self.last_event_ids[slot] = last_event_id

    def unsubscribe(mut self, slot: Int):
        """Remove a slot from SSE streaming."""
        if slot < 0 or slot >= self._capacity:
            return
        if self.is_streaming[slot]:
            self._active -= 1
        self.is_streaming[slot] = False
        self.filter_urls[slot] = String("")
        self.last_event_ids[slot] = 0
        self.pending_bufs[slot] = List[UInt8]()
        # A channel stream's end is read by the loop's drain
        # (`sse_is_streaming` gone False), so it is named like bytes are.
        self.mark_ready(slot)

    @always_inline
    def mark_ready(mut self, slot: Int):
        """Name `slot` to the loop at the next `take_ready` (SPEC C24).

        The registry names every slot it queues for and every slot it
        unsubscribes; a caller that appends to `pending_bufs` itself, or
        changes what its `sse_drain_slot` reads, calls this, or the loop's
        drain does not visit the slot until something else names it."""
        if slot < 0 or slot >= self._capacity or self._named[slot]:
            return
        self._named[slot] = True
        self.ready.append(slot)

    def take_ready(mut self, mut into: List[Int]):
        """Append the slots named since the last call to `into`, and forget
        them. What a handler's `take_ready_streams` forwards."""
        for i in range(len(self.ready)):
            var slot = self.ready[i]
            into.append(slot)
            self._named[slot] = False
        self.ready.clear()

    def notify(mut self, url: String, event_id: Int, event_type: String, data: String) -> Int:
        """Push an SSE event to all slots subscribed to the given URL.

        Frames the event in this module's wire format. Producers with their own
        framing rules should use `notify_frame` instead.

        Returns the number of slots the event was queued for — see
        `notify_frame` for why a caller should look at it, and for the
        one-id-many-events trap that motivated it (#120).

        Drops events if the pending buffer exceeds MAX_PENDING_BYTES.
        """
        return self.notify_frame(url, event_id, format_sse_event_bytes(event_id, event_type, data))

    def notify_frame(mut self, url: String, event_id: Int, frame: List[UInt8]) -> Int:
        """Queue a pre-formatted SSE frame verbatim for every slot on `url`.

        Unlike `notify`, the caller owns the wire format: `frame` must already
        be a complete SSE frame including the terminating blank line. This is
        what producers with their own framing rules need — Datastar, for one,
        mandates `event:` before `id:`, the opposite of `format_sse_event`.

        `event_id` still drives redelivery suppression exactly as `notify` does,
        so a reconnecting client does not replay what it already has. Pass
        `NO_EVENT_ID` for frames carrying no `id:` line: those always deliver
        and never advance the slot's last-seen id, which keeps an unnumbered
        heartbeat or comment from masking a real event.

        **Reusing an id across successive calls delivers only the first**: the
        first call advances every reached slot's last-seen id to `event_id`,
        so the second fails `event_id > last_event_ids[slot]` and is dropped —
        silently, for the life of the app, which is how #120 was lived before
        it was found. Derived or always-safe-to-redeliver events belong on
        `NO_EVENT_ID`.

        Backpressure applies either way — a frame that would push a slot past
        MAX_PENDING_BYTES is dropped for that slot alone.

        Returns the number of slots the frame was queued for. A caller
        broadcasting to a URL it knows has subscribers and getting 0 back has
        a local, immediate signal that suppression or backpressure ate the
        frame — the two behaviours that used to be invisible at the call site.
        """
        var queued = 0
        for slot in range(self._capacity):
            if self.is_streaming[slot] and self.filter_urls[slot] == url:
                var deliver = event_id == NO_EVENT_ID or event_id > self.last_event_ids[slot]
                if deliver:
                    if len(self.pending_bufs[slot]) + len(frame) <= MAX_PENDING_BYTES:
                        self.pending_bufs[slot].extend(Span(frame))
                        if event_id != NO_EVENT_ID:
                            self.last_event_ids[slot] = event_id
                        self.mark_ready(slot)
                        queued += 1
        return queued

    def queue_frame(mut self, slot: Int, event_id: Int, frame: List[UInt8]) -> Bool:
        """Queue a pre-formatted frame for ONE slot — the replay path.

        `notify_frame` for a single subscriber: the same delivery filter and
        backpressure, scoped to one slot. This is what catches a reconnecting
        client up from its `Last-Event-ID` without re-broadcasting history to
        everyone else. Bounds-safe; a slot that is not streaming gets nothing.

        Returns whether the frame was queued — False means an invalid or
        non-streaming slot, id suppression, or backpressure (#120).
        """
        if slot < 0 or slot >= self._capacity:
            return False
        if not self.is_streaming[slot]:
            return False
        var deliver = event_id == NO_EVENT_ID or event_id > self.last_event_ids[slot]
        if deliver:
            if len(self.pending_bufs[slot]) + len(frame) <= MAX_PENDING_BYTES:
                self.pending_bufs[slot].extend(Span(frame))
                if event_id != NO_EVENT_ID:
                    self.last_event_ids[slot] = event_id
                self.mark_ready(slot)
                return True
        return False

    def has_subscribers(self, url: String) -> Bool:
        """Whether any slot is streaming for `url`.

        Lets a handler skip an expensive render when nobody is listening.
        """
        for slot in range(self._capacity):
            if self.is_streaming[slot] and self.filter_urls[slot] == url:
                return True
        return False

    def subscriber_count(self, url: String) -> Int:
        """Number of slots streaming for `url`."""
        var count = 0
        for slot in range(self._capacity):
            if self.is_streaming[slot] and self.filter_urls[slot] == url:
                count += 1
        return count

    def filter_url(self, slot: Int) -> String:
        """The url a slot subscribed to, or "" — the inverse of `subscribe`.

        The fan-out paths never need this: they are handed a url and look for
        matching slots. A handler that must answer *about* one connection
        does — `apps/django_realtime` reads the channel a WebSocket joined
        when a message arrives on it, because the frame itself carries no
        channel and the subscription is the only record of one.
        """
        if slot < 0 or slot >= self._capacity:
            return String("")
        return self.filter_urls[slot]

    @always_inline
    def is_slot_streaming(self, slot: Int) -> Bool:
        """Whether a slot is in SSE streaming mode. Bounds-safe."""
        if slot < 0 or slot >= self._capacity:
            return False
        return self.is_streaming[slot]

    @always_inline
    def has_pending(self, slot: Int) -> Bool:
        """Check if a slot has outbound SSE data waiting to be sent."""
        if slot < 0 or slot >= self._capacity:
            return False
        return len(self.pending_bufs[slot]) > 0

    @always_inline
    def drain(mut self, slot: Int) -> List[UInt8]:
        """Return and clear the pending outbound buffer for a slot."""
        if slot < 0 or slot >= self._capacity:
            return List[UInt8]()
        var buf = self.pending_bufs[slot].copy()
        self.pending_bufs[slot].clear()
        return buf^

    def active_count(self) -> Int:
        """The slots streaming now, in O(1)."""
        return self._active
