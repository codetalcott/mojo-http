"""SSE subscriber registry.

Manages which connection slots are subscribed to SSE streams,
queues outbound data for the event loop to drain.
Parallel arrays indexed by slot_id (SoA pattern).
"""

from .format import format_sse_event_bytes

# Backpressure: drop events if a slot's pending buffer exceeds this size.
comptime MAX_PENDING_BYTES = 65536


struct SSERegistry:
    """Manages SSE stream subscriptions and outbound event queues."""

    var is_streaming: List[Bool]
    var filter_urls: List[String]
    var last_event_ids: List[Int]
    var pending_bufs: List[List[UInt8]]
    var _capacity: Int

    fn __init__(out self, capacity: Int):
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

    fn subscribe(mut self, slot: Int, url: String, last_event_id: Int):
        """Register a slot as an SSE stream subscriber for the given URL."""
        if slot < 0 or slot >= self._capacity:
            return
        self.is_streaming[slot] = True
        self.filter_urls[slot] = url
        self.last_event_ids[slot] = last_event_id

    fn unsubscribe(mut self, slot: Int):
        """Remove a slot from SSE streaming."""
        if slot < 0 or slot >= self._capacity:
            return
        self.is_streaming[slot] = False
        self.filter_urls[slot] = String("")
        self.last_event_ids[slot] = 0
        self.pending_bufs[slot] = List[UInt8]()

    fn notify(mut self, url: String, event_id: Int, event_type: String, data: String):
        """Push an SSE event to all slots subscribed to the given URL.

        Drops events if the pending buffer exceeds MAX_PENDING_BYTES.
        """
        var event_bytes = format_sse_event_bytes(event_id, event_type, data)
        for slot in range(self._capacity):
            if self.is_streaming[slot] and self.filter_urls[slot] == url:
                if event_id > self.last_event_ids[slot]:
                    if len(self.pending_bufs[slot]) + len(event_bytes) <= MAX_PENDING_BYTES:
                        self.pending_bufs[slot].extend(Span(event_bytes))
                        self.last_event_ids[slot] = event_id

    fn has_pending(self, slot: Int) -> Bool:
        """Check if a slot has outbound SSE data waiting to be sent."""
        if slot < 0 or slot >= self._capacity:
            return False
        return len(self.pending_bufs[slot]) > 0

    fn drain(mut self, slot: Int) -> List[UInt8]:
        """Return and clear the pending outbound buffer for a slot."""
        if slot < 0 or slot >= self._capacity:
            return List[UInt8]()
        var buf = self.pending_bufs[slot].copy()
        self.pending_bufs[slot].clear()
        return buf^

    fn active_count(self) -> Int:
        """Count the number of active SSE streaming slots."""
        var count = 0
        for slot in range(self._capacity):
            if self.is_streaming[slot]:
                count += 1
        return count
