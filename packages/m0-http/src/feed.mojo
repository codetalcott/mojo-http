"""A stream whose event ids are the application's, and whose memory is not
the server's.

`DatastarStream` numbers its frames and keeps a journal, so that a
reconnecting client can be replayed what it missed. A `Feed` does neither:
the id of every frame is a number the APPLICATION owns -- a stamp from
`m0_sqlite`'s `stamp_head`, or any number that places a client among the
changes -- and a reconnect is answered by asking the application for what
lies above the client's number. The server keeps one integer per
subscriber, the registry's last event id, and nothing else.

    struct Store(ViewState):
        var feed: Feed
        ...
        def refresh(mut self) raises:
            var now = self.reader.data_version()
            if now == self.clock and not self.feed.lagging():
                return
            self.clock = now
            var head = stamp_head(self.reader)
            for slot in self.feed.behind(head):
                var at = self.feed.at(slot)
                var d = changes_above(self.reader, at)   # the application's
                if d.head == at:
                    self.feed.skip(slot, head)
                else:
                    _ = self.feed.send(slot, d.head, d.frames)

        def tick(mut self, now_ms: Int):               # the trait's, so it does not raise
            try:
                self.refresh()
            except e:
                print("feed:", e)

    def events(req: HTTPRequest, params: List[String], mut st: Store) raises -> HTTPResponse:
        return st.feed.open(req, "notes")          # add_write(..., on_loop=True); the next tick sends

Three rules, each found by breaking it in an application that fed pages
from stamped tables (docs/notes/a-database-that-remembers-what-changed.md):

- **Fan-out is per subscriber, from its own number.** A broadcast assumes
  every subscriber stands together; one refused frame then leaves a gap
  that nothing closes. Here each subscriber is brought from where IT
  stands to the head, and most stand together, so an application caches
  the delta by `at`.
- **A delta goes whole or not at all.** A client holds a row iff the row
  was created at or below the client's number, which is true only of a
  number that was the head of a snapshot the client has all of. So `send`
  takes a delta of any size into a slot with nothing pending, and refuses
  one that does not fit beside what is pending, leaving the subscriber
  where it stands; the next delta from there holds this one and whatever
  followed. A slow client gets fewer, larger updates, never a gap; and
  while its socket has not moved since the refusal, `behind` leaves it
  out, so it costs the application no rendering.
- **A subscriber with nothing of its own above its number** is moved to
  the head without a frame (`skip`), or it is asked for again every tick.
- **A number the application never gave is not a place to wait at.** A
  subscriber above the head is brought back by the application's resync,
  as one below the floor is; `behind` names both.

The frames are bytes the application built -- `m0_datastar`'s
`patch_elements` and `patch_signals` with `event_id=`, or any SSE -- and
go out verbatim. The id belongs on the LAST frame of a delta: a client
that saw it saw all of them.
"""

from lightbug_http.http import HTTPRequest, HTTPResponse

from .reply import problem
from .sse import SSERegistry, sse_response

comptime FEED_SLOT_BUDGET = 65536
"""Bytes a subscriber may hold unsent beside a new delta. A delta is never
cut to fit: a slot with nothing pending takes one of any size."""


def _parse_stamp(s: String) -> Int:
    """A client's number: decimal digits, no sign, no leading zero but for
    0 itself; -1 for anything else."""
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 18:
        return -1
    if len(b) > 1 and b[0] == 0x30:
        return -1
    var v = 0
    for i in range(len(b)):
        var d = Int(b[i]) - 48
        if d < 0 or d > 9:
            return -1
        v = v * 10 + d
    return v


def since_of(req: HTTPRequest) -> Int:
    """Where the client stands: its `Last-Event-ID`, else `?since=`, else
    0; -1 when what it sent is not a number."""
    var lei = req.headers.get("last-event-id")
    if lei:
        return _parse_stamp(lei.value())
    var since = req.uri.queries.get("since")
    if since:
        return _parse_stamp(since.value())
    return 0


struct Feed(Movable):
    """Subscribers, each at a number of the application's."""

    var _registry: SSERegistry
    var capacity: Int
    var sent: Int
    """Deltas queued."""
    var refused: Int
    """Deltas a subscriber could not take yet, beside what it still holds."""
    var _lagging: Bool
    var _refused_at: List[Int]
    """Per slot: how many bytes it held when a delta was last refused, or
    -1. While it holds exactly that many, nothing has drained and the
    same delta would be refused again, so `behind` leaves it out: a stuck
    subscriber costs no rendering until its socket moves."""

    def __init__(out self, capacity: Int):
        """`capacity` is the server's connection slots, as for any registry."""
        self._registry = SSERegistry(capacity)
        self.capacity = capacity
        self.sent = 0
        self.refused = 0
        self._lagging = False
        self._refused_at = List[Int](capacity=capacity)
        for _ in range(capacity):
            self._refused_at.append(-1)

    # --- opening ---------------------------------------------------------------

    def open(mut self, req: HTTPRequest, key: String) -> HTTPResponse:
        """Subscribe the request's slot under `key`, standing at `since_of(req)`,
        and answer the response that opens the stream.

        409 for a request with no slot (a stream opens on the loop: register
        the view `on_loop=True`), 400 for a number that is not one. The
        application fans out on its next refresh, which it calls after this.
        """
        if req.slot_id < 0:
            return problem(409, "Conflict", "a stream opens on the loop", req.uri.path)
        var since = since_of(req)
        if since < 0:
            return problem(400, "Invalid Stamp", "since is a number: decimal digits", req.uri.path)
        # A slot whose last stream never reached the loop (a view that
        # raised after opening) may still hold bytes: not this client's.
        self._registry.pending_bufs[req.slot_id] = List[UInt8]()
        self._refused_at[req.slot_id] = -1
        self._registry.subscribe(req.slot_id, key, since)
        self._lagging = True
        return sse_response()

    # --- fanning out -----------------------------------------------------------

    def lagging(self) -> Bool:
        """Whether a subscriber is known to stand below the head: one that
        just opened, or one whose delta was refused. An application refreshes
        when its clock moves OR this is true."""
        return self._lagging

    def behind(mut self, head: Int) -> List[Int]:
        """The slots not standing at `head`: below it, to bring up, and
        ABOVE it, which is a number this application never gave (a client
        of another incarnation, a database restored) and is answered by
        the application's resync like a number below the floor. Clears
        `lagging`; `send` sets it again for a slot it had to refuse."""
        self._lagging = False
        var out = List[Int]()
        for slot in range(self.capacity):
            if not self._registry.is_streaming[slot] or self._registry.last_event_ids[slot] == head:
                continue
            if self._refused_at[slot] >= 0 and len(self._registry.pending_bufs[slot]) == self._refused_at[slot]:
                # Nothing drained since the refusal: asking again would
                # cost the application a delta it cannot queue.
                self._lagging = True
                continue
            out.append(slot)
        return out^

    def at(self, slot: Int) -> Int:
        """Where the subscriber on `slot` stands."""
        if slot < 0 or slot >= self.capacity:
            return 0
        return self._registry.last_event_ids[slot]

    def key(self, slot: Int) -> String:
        """What the subscriber on `slot` opened: the `key` given to `open`."""
        if slot < 0 or slot >= self.capacity:
            return String("")
        return self._registry.filter_urls[slot]

    def send(mut self, slot: Int, head: Int, frames: String) -> Bool:
        """Queue a delta, whole, and move the subscriber to `head`.

        Taken when the slot holds nothing unsent, whatever the size, or
        when the delta fits beside what it holds under `FEED_SLOT_BUDGET`.
        Otherwise refused: the subscriber stays where it stands, `lagging`
        is set, and the next refresh asks for its delta again from there.
        False for a refusal or a slot that is not streaming.
        """
        if slot < 0 or slot >= self.capacity or not self._registry.is_streaming[slot]:
            return False
        var pending = len(self._registry.pending_bufs[slot])
        if pending > 0 and pending + frames.byte_length() > FEED_SLOT_BUDGET:
            self.refused += 1
            self._refused_at[slot] = pending
            self._lagging = True
            return False
        self._refused_at[slot] = -1
        self._registry.pending_bufs[slot].extend(frames.as_bytes())
        # Where the application says, down as well as up: a resync for a
        # client that stood above the head brings it back to the head.
        self._registry.last_event_ids[slot] = head
        self.sent += 1
        return True

    def skip(mut self, slot: Int, head: Int):
        """Move the subscriber to `head` with nothing to send: the head
        moved for changes that were not its key's."""
        if slot < 0 or slot >= self.capacity:
            return
        self._registry.last_event_ids[slot] = head

    # --- what the handler forwards --------------------------------------------

    def subscribers(self, key: String) -> Int:
        return self._registry.subscriber_count(key)

    def drain(mut self, slot: Int) -> List[UInt8]:
        """`sse_drain_slot`."""
        return self._registry.drain(slot)

    def is_streaming(self, slot: Int) -> Bool:
        """`sse_is_streaming`."""
        return self._registry.is_slot_streaming(slot)

    def closed(mut self, slot: Int):
        """`sse_slot_disconnected`."""
        if slot >= 0 and slot < self.capacity:
            self._refused_at[slot] = -1
        self._registry.unsubscribe(slot)
