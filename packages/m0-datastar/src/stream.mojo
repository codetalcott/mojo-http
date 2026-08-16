"""Datastar SSE fan-out: owns subscriptions, formats frames, queues them.

`consts.mojo` and `sse.mojo` are pure wire format with no dependencies. This
module is where the dependency on `m0_http` and `lightbug_http` lands, so an
application that only wants to generate Datastar frames never pays for it.

Why this cannot go through `SSERegistry.notify`: the builders in `sse.mojo`
return a *complete* SSE frame, while `notify` takes a payload and frames it
itself. Passing one to the other double-frames the event — the browser sees a
single event whose data is the literal text of your frame. The two framers also
disagree on field order, since the Datastar SDK spec mandates `event:` before
`id:` while `format_sse_event` emits `id:` first. Both problems are why this
uses `notify_frame`, which queues bytes verbatim.
"""

# Top-level package, not the `lightbug_http.http` subpackage — see the note in
# signals.mojo. Everything needed is re-exported here anyway.
from lightbug_http import Headers, Header, HeaderKey, HTTPRequest, HTTPResponse

from m0_http import SSERegistry, sse_response

from .consts import DEFAULT_PATCH_MODE
from .sse import (
    patch_elements as _frame_patch_elements,
    patch_signals as _frame_patch_signals,
    execute_script as _frame_execute_script,
    redirect as _frame_redirect,
)


struct DatastarStream:
    """Datastar SSE fan-out for one handler.

    Hold one per `HTTPService`. Wire the four SSE hooks straight through to
    `drain` / `is_streaming` / `closed`, open a stream from a GET handler with
    `open`, and broadcast from any other handler:

        def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
            return self.stream.drain(slot)
        def sse_is_streaming(self, slot: Int) -> Bool:
            return self.stream.is_streaming(slot)
        def sse_slot_disconnected(mut self, slot: Int):
            self.stream.closed(slot)

    Two limits worth knowing before you design around this:

    - **Single process.** `WorkerSupervisor` forks, and each child gets its own
      `DatastarStream`, so a broadcast on one worker never reaches subscribers
      pinned to another. `M0_WORKERS > 1` and SSE fan-out are mutually
      exclusive today.
    - **No server-initiated push.** `HTTPService` has no tick hook, so every
      broadcast must be caused by an inbound request — client A's POST pushing
      to client B's stream. A shared todo list is expressible; a clock is not.
    """

    var registry: SSERegistry
    var next_event_id: Int
    # The replay journal: the last `journal_cap` broadcast frames, verbatim,
    # as parallel lists (the repo's SoA convention — List[Struct] fights
    # ImplicitlyCopyable). A reconnecting client's `Last-Event-ID` is caught
    # up from here in `open`. In-memory only; an app that wants replay to
    # survive a restart persists (id, url, frame) after each broadcast and
    # feeds rows back through `restore` at boot — see apps/datastar_todo.
    var journal_urls: List[String]
    var journal_ids: List[Int]
    var journal_frames: List[List[UInt8]]
    var journal_cap: Int

    def __init__(out self, capacity: Int = 1024, journal_entries: Int = 64):
        """Create a stream sized for `capacity` connection slots.

        `capacity` must be at least the server's max connections, since slots
        are indexed directly by `req.slot_id`.

        `journal_entries` bounds the replay journal; 0 disables replay
        entirely (reconnecting clients simply resume from the live feed).
        """
        self.registry = SSERegistry(capacity)
        self.next_event_id = 0
        self.journal_urls = List[String]()
        self.journal_ids = List[Int]()
        self.journal_frames = List[List[UInt8]]()
        self.journal_cap = journal_entries

    # --- Lifecycle: drive these from the HTTPService SSE hooks -------------

    def open(mut self, req: HTTPRequest, url: String) -> HTTPResponse:
        """Subscribe this request's slot to `url` and open the stream.

        Returns `409 Conflict` when the request has no event-loop slot
        (`slot_id < 0`), which means it did not arrive over the streaming
        server and cannot be held open.

        A request carrying `Last-Event-ID` is a reconnection, and gets caught
        up: every journaled frame for `url` newer than the id it presents is
        queued before any live broadcast, and the id also suppresses
        redelivery of frames the client already has. A request without the
        header is a new consumer and starts from the live feed — SSE
        semantics, and what keeps a first-time visitor from replaying stale
        patches onto a freshly rendered page.

        An id *ahead* of this process's counter is clamped to it: the id came
        from an incarnation whose history this process does not have, and
        taking it literally would suppress every subsequent event. Processes
        that restore a persisted journal at boot (`restore`) seed the counter
        past this clamp, which is what makes replay work across restarts.
        """
        if req.slot_id < 0:
            return HTTPResponse(
                body_bytes=String(
                    '{"error":"no streaming slot; this request did not arrive'
                    ' over the event-loop server"}'
                ).as_bytes(),
                headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
                status_code=409,
                status_text="Conflict",
            )
        var last_id = 0
        var reconnecting = False
        var header = req.headers.get("last-event-id")
        if header:
            reconnecting = True
            last_id = _parse_event_id(header.value())
            if last_id > self.next_event_id:
                last_id = self.next_event_id
        self.registry.subscribe(req.slot_id, url, last_id)
        if reconnecting:
            for i in range(len(self.journal_ids)):
                if self.journal_urls[i] == url and self.journal_ids[i] > last_id:
                    self.registry.queue_frame(
                        req.slot_id,
                        self.journal_ids[i],
                        self.journal_frames[i].copy(),
                    )
        return sse_response()

    def drain(mut self, slot: Int) -> List[UInt8]:
        """Return and clear pending bytes for a slot. Wire to `sse_drain_slot`."""
        return self.registry.drain(slot)

    def is_streaming(self, slot: Int) -> Bool:
        """Whether a slot is streaming. Wire to `sse_is_streaming`."""
        return self.registry.is_slot_streaming(slot)

    def closed(mut self, slot: Int):
        """Release a disconnected slot. Wire to `sse_slot_disconnected`."""
        self.registry.unsubscribe(slot)

    # --- Replay journal ----------------------------------------------------

    def _dispatch(mut self, url: String, event_id: Int, frame: String):
        """Journal a broadcast frame, then queue it for every subscriber."""
        var bytes = List[UInt8](frame.as_bytes())
        self._record(url, event_id, bytes)
        self.registry.notify_frame(url, event_id, bytes)

    def _record(mut self, url: String, event_id: Int, frame: List[UInt8]):
        if self.journal_cap <= 0:
            return
        self.journal_urls.append(url)
        self.journal_ids.append(event_id)
        self.journal_frames.append(frame.copy())
        while len(self.journal_ids) > self.journal_cap:
            _ = self.journal_urls.pop(0)
            _ = self.journal_ids.pop(0)
            _ = self.journal_frames.pop(0)

    def restore(mut self, url: String, event_id: Int, frame: List[UInt8]):
        """Reload one persisted frame into the journal — the boot-time path.

        Call once per persisted row, in ascending id order, before serving.
        Seeds `next_event_id` so ids stay monotonic across restarts — the
        property that makes a client's pre-restart `Last-Event-ID` meaningful
        to this process. Without it the counter restarts at 0 and `open`'s
        clamp writes the reconnecting client's id off entirely.
        """
        self._record(url, event_id, frame)
        if event_id > self.next_event_id:
            self.next_event_id = event_id

    def frame_for(self, event_id: Int) -> List[UInt8]:
        """The journaled frame bytes for `event_id`, empty if evicted/unknown.

        This is what an app persists after a broadcast: the broadcast methods
        return the id they assigned, and this returns the exact bytes that
        went out under it.
        """
        for i in range(len(self.journal_ids)):
            if self.journal_ids[i] == event_id:
                return self.journal_frames[i].copy()
        return List[UInt8]()

    # --- Broadcast: each returns the event id it assigned ------------------

    def patch_elements(
        mut self,
        url: String,
        elements: String,
        selector: String = "",
        mode: String = DEFAULT_PATCH_MODE,
    ) -> Int:
        """Patch HTML into every subscriber's DOM."""
        self.next_event_id += 1
        var frame = _frame_patch_elements(
            elements=elements,
            selector=selector,
            mode=mode,
            event_id=String(self.next_event_id),
        )
        self._dispatch(url, self.next_event_id, frame)
        return self.next_event_id

    def patch_signals(
        mut self, url: String, signals: String, only_if_missing: Bool = False
    ) -> Int:
        """Merge a signal JSON object into every subscriber's signal store."""
        self.next_event_id += 1
        var frame = _frame_patch_signals(
            signals=signals,
            event_id=String(self.next_event_id),
            only_if_missing=only_if_missing,
        )
        self._dispatch(url, self.next_event_id, frame)
        return self.next_event_id

    def execute_script(mut self, url: String, script: String) -> Int:
        """Run a script in every subscriber's browser."""
        self.next_event_id += 1
        var frame = _frame_execute_script(
            script=script, event_id=String(self.next_event_id)
        )
        self._dispatch(url, self.next_event_id, frame)
        return self.next_event_id

    def redirect_to(mut self, url: String, location: String) -> Int:
        """Redirect every subscriber to `location`."""
        self.next_event_id += 1
        var frame = _frame_redirect(
            location=location, event_id=String(self.next_event_id)
        )
        self._dispatch(url, self.next_event_id, frame)
        return self.next_event_id

    def send_frame(mut self, url: String, frame: String) -> Int:
        """Queue a pre-built frame verbatim — the escape hatch.

        Use when you have composed a frame the helpers above do not cover. The
        frame must be complete, including its terminating blank line.
        """
        self.next_event_id += 1
        self._dispatch(url, self.next_event_id, frame)
        return self.next_event_id

    # --- Introspection -----------------------------------------------------

    def subscriber_count(self, url: String) -> Int:
        """How many slots are streaming for `url`."""
        return self.registry.subscriber_count(url)

    def has_subscribers(self, url: String) -> Bool:
        """Whether anyone is listening — skip an expensive render if not."""
        return self.registry.has_subscribers(url)


def _parse_event_id(s: String) -> Int:
    """Parse a decimal `Last-Event-ID`; anything malformed is 0.

    Ids here are always decimal (`next_event_id` stringified), so a value that
    is not one came from somewhere else and carries no position — 0 means
    "replay whatever the journal holds", the safe reading of an id we cannot
    place.
    """
    if s.byte_length() == 0:
        return 0
    var result = 0
    var bytes = s.as_bytes()
    for i in range(s.byte_length()):
        var c = Int(bytes[i])
        if c < ord("0") or c > ord("9"):
            return 0
        result = result * 10 + (c - ord("0"))
    return result
