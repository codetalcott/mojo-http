"""SSE subscriber registry.

Manages which connection slots are subscribed to SSE streams,
queues outbound data for the event loop to drain.
Parallel arrays indexed by slot_id (SoA pattern).
"""

from .format import format_sse_event_bytes, NO_EVENT_ID

# Backpressure: drop events if a slot's pending buffer exceeds this size.
comptime MAX_PENDING_BYTES = 65536


struct SSERegistry:
    """Manages SSE stream subscriptions and outbound event queues."""

    var is_streaming: List[Bool]
    var filter_urls: List[String]
    var last_event_ids: List[Int]
    var pending_bufs: List[List[UInt8]]
    var _capacity: Int

    def __init__(out self, capacity: Int):
        self._capacity = capacity
        self.is_streaming = List[Bool](capacity=capacity)
        self.filter_urls = List[String](capacity=capacity)
        self.last_event_ids = List[Int](capacity=capacity)
        self.pending_bufs = List[List[UInt8]](capacity=capacity)
        for _ in range(capacity):
            self.is_streaming.append(False)
            self.filter_urls.append(String(""))
            self.last_event_ids.append(0)
            self.pending_bufs.append(List[UInt8]())

    def subscribe(mut self, slot: Int, url: String, last_event_id: Int):
        """Register a slot as an SSE stream subscriber for the given URL."""
        if slot < 0 or slot >= self._capacity:
            return
        self.is_streaming[slot] = True
        self.filter_urls[slot] = url
        self.last_event_ids[slot] = last_event_id

    def unsubscribe(mut self, slot: Int):
        """Remove a slot from SSE streaming."""
        if slot < 0 or slot >= self._capacity:
            return
        self.is_streaming[slot] = False
        self.filter_urls[slot] = String("")
        self.last_event_ids[slot] = 0
        self.pending_bufs[slot] = List[UInt8]()

    def notify(mut self, url: String, event_id: Int, event_type: String, data: String):
        """Push an SSE event to all slots subscribed to the given URL.

        Frames the event in this module's wire format. Producers with their own
        framing rules should use `notify_frame` instead.

        Drops events if the pending buffer exceeds MAX_PENDING_BYTES.
        """
        self.notify_frame(url, event_id, format_sse_event_bytes(event_id, event_type, data))

    def notify_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
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

        Backpressure applies either way — a frame that would push a slot past
        MAX_PENDING_BYTES is dropped for that slot alone.
        """
        for slot in range(self._capacity):
            if self.is_streaming[slot] and self.filter_urls[slot] == url:
                var deliver = event_id == NO_EVENT_ID or event_id > self.last_event_ids[slot]
                if deliver:
                    if len(self.pending_bufs[slot]) + len(frame) <= MAX_PENDING_BYTES:
                        self.pending_bufs[slot].extend(Span(frame))
                        if event_id != NO_EVENT_ID:
                            self.last_event_ids[slot] = event_id

    def queue_frame(mut self, slot: Int, event_id: Int, frame: List[UInt8]):
        """Queue a pre-formatted frame for ONE slot — the replay path.

        `notify_frame` for a single subscriber: the same delivery filter and
        backpressure, scoped to one slot. This is what catches a reconnecting
        client up from its `Last-Event-ID` without re-broadcasting history to
        everyone else. Bounds-safe; a slot that is not streaming gets nothing.
        """
        if slot < 0 or slot >= self._capacity:
            return
        if not self.is_streaming[slot]:
            return
        var deliver = event_id == NO_EVENT_ID or event_id > self.last_event_ids[slot]
        if deliver:
            if len(self.pending_bufs[slot]) + len(frame) <= MAX_PENDING_BYTES:
                self.pending_bufs[slot].extend(Span(frame))
                if event_id != NO_EVENT_ID:
                    self.last_event_ids[slot] = event_id

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

    def is_slot_streaming(self, slot: Int) -> Bool:
        """Whether a slot is in SSE streaming mode. Bounds-safe."""
        if slot < 0 or slot >= self._capacity:
            return False
        return self.is_streaming[slot]

    def has_pending(self, slot: Int) -> Bool:
        """Check if a slot has outbound SSE data waiting to be sent."""
        if slot < 0 or slot >= self._capacity:
            return False
        return len(self.pending_bufs[slot]) > 0

    def drain(mut self, slot: Int) -> List[UInt8]:
        """Return and clear the pending outbound buffer for a slot."""
        if slot < 0 or slot >= self._capacity:
            return List[UInt8]()
        var buf = self.pending_bufs[slot].copy()
        self.pending_bufs[slot].clear()
        return buf^

    def active_count(self) -> Int:
        """Count the number of active SSE streaming slots."""
        var count = 0
        for slot in range(self._capacity):
            if self.is_streaming[slot]:
                count += 1
        return count
