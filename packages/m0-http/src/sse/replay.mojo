"""A bounded journal of numbered frames, so a subscriber that reconnects
with `Last-Event-ID` can be caught up on what it missed.

`SSERegistry`'s delivery filter is suppression alone: a slot subscribed at
`last_event_id` is not sent an id it already has, and what was published
while it was away is gone. `ReplayJournal` keeps the last `cap` numbered
frames delivered through it, verbatim and in id order, and beside them one
number, `floor`: the newest id it cannot replay — published before this
journal saw anything (a worker spawned into a running cluster), or dropped
to stay within `cap`.

`catch_up` is all or nothing, `DatastarStream`'s rule (SPEC I30): a client
the journal can serve whole gets every frame it missed, in order, before
anything live; one it cannot gets nothing from history, and the caller says
so. Served in part, a client would hold a state with a hole in it and no
way to know.

The floor is one number for every channel, on purpose. Ids are one counter
across every channel, so a client of a quiet channel whose id is older than
the floor may have missed nothing — but telling would take a mark per
channel the journal ever dropped a frame of, which on a server that opens a
channel per visitor is a list that only grows. Bounded memory wins: such a
client is told it may have missed something and fetches, which costs one
request. A larger `cap` makes that rarer.

Unnumbered frames (`NO_EVENT_ID`) are never journaled: a heartbeat or a
resync is not a change. In memory only: a restart begins an empty journal
whose floor is wherever the counter stands, and a reconnect across it is a
gap, which is the truth.
"""

from .format import NO_EVENT_ID
from .registry import SSERegistry


struct ReplayJournal:
    """The last `cap` numbered frames, by url, and the newest id not kept."""

    var urls: List[String]
    var ids: List[Int]
    var frames: List[List[UInt8]]
    var cap: Int
    var floor: Int
    """The newest id this journal cannot replay: a client whose
    `Last-Event-ID` is below it may have missed a frame."""
    var head: Int
    """The newest id seen, 0 before any."""

    def __init__(out self, cap: Int = 64):
        """`cap` bounds the journal in frames; 0 keeps none, so every
        reconnect that missed a frame is a gap."""
        self.urls = List[String]()
        self.ids = List[Int]()
        self.frames = List[List[UInt8]]()
        self.cap = cap if cap > 0 else 0
        self.floor = 0
        self.head = 0

    def start_after(mut self, event_id: Int):
        """Frames numbered up to `event_id` were published before this
        journal existed: a respawned worker reads the shared counter and
        passes it here, so a client resuming from before it is a gap and
        not a silent miss."""
        if event_id > self.floor:
            self.floor = event_id
        if event_id > self.head:
            self.head = event_id

    def record(mut self, url: String, event_id: Int, frame: List[UInt8]):
        """Journal one delivered frame. Unnumbered frames are not changes
        and are skipped; so is one at or below the floor, which no client
        the journal can serve is owed."""
        if event_id == NO_EVENT_ID:
            return
        if self.head == 0 and event_id - 1 > self.floor:
            # The first frame this journal sees: everything before it is
            # history it does not have. A first-generation loop sees id 1
            # first and keeps a floor of 0.
            self.floor = event_id - 1
        if event_id > self.head:
            self.head = event_id
        if event_id <= self.floor:
            return
        if self.cap == 0:
            self.floor = event_id
            return
        # Insert in id order: a frame from a peer worker can arrive behind
        # one already recorded, and replay walks the journal in order —
        # `queue_frame` advances the slot's last-seen id as it goes, so an
        # out-of-order entry would be skipped, not replayed late.
        var pos = len(self.ids)
        while pos > 0 and self.ids[pos - 1] > event_id:
            pos -= 1
        self.urls.insert(pos, url)
        self.ids.insert(pos, event_id)
        self.frames.insert(pos, frame.copy())
        while len(self.ids) > self.cap:
            _ = self.urls.pop(0)
            var gone = self.ids.pop(0)
            _ = self.frames.pop(0)
            if gone > self.floor:
                self.floor = gone

    def covers(self, last_id: Int) -> Bool:
        """Whether every frame after `last_id`, on any channel, is in the
        journal: `last_id` is at or past the floor, so any frame numbered
        above it arrived after the journal began and was not dropped."""
        return last_id >= self.floor

    def catch_up(
        mut self, mut registry: SSERegistry, slot: Int, url: String, last_id: Int
    ) -> Bool:
        """Queue every journaled frame of `url` after `last_id` for `slot`,
        or none.

        False when the journal cannot catch the client up — it does not
        cover `last_id` (`covers`), or the frames do not fit the slot's
        outbox — in which case whatever was queued is taken back, leaving
        the slot subscribed at `last_id` with nothing pending. The slot
        must already be subscribed to `url` at `last_id`.
        """
        if not self.covers(last_id):
            return False
        for i in range(len(self.ids)):
            if self.urls[i] == url and self.ids[i] > last_id:
                if not registry.queue_frame(slot, self.ids[i], self.frames[i].copy()):
                    registry.unsubscribe(slot)
                    registry.subscribe(slot, url, last_id)
                    return False
        return True

    def entries(self) -> Int:
        """How many frames the journal holds."""
        return len(self.ids)
