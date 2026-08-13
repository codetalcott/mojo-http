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

    def __init__(out self, capacity: Int = 1024):
        """Create a stream sized for `capacity` connection slots.

        `capacity` must be at least the server's max connections, since slots
        are indexed directly by `req.slot_id`.
        """
        self.registry = SSERegistry(capacity)
        self.next_event_id = 0

    # --- Lifecycle: drive these from the HTTPService SSE hooks -------------

    def open(mut self, req: HTTPRequest, url: String) -> HTTPResponse:
        """Subscribe this request's slot to `url` and open the stream.

        Returns `409 Conflict` when the request has no event-loop slot
        (`slot_id < 0`), which means it did not arrive over the streaming
        server and cannot be held open.

        The client's `Last-Event-ID` is deliberately ignored: `next_event_id`
        restarts at 0 in every process, so honouring an id from a previous
        process would suppress every subsequent event. Replay across restarts
        needs a durable log — `m0_http.sse.PatchJournal` is the building block,
        but wiring it is an application decision.
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
        self.registry.subscribe(req.slot_id, url, 0)
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
        self.registry.notify_frame(url, self.next_event_id, List[UInt8](frame.as_bytes()))
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
        self.registry.notify_frame(url, self.next_event_id, List[UInt8](frame.as_bytes()))
        return self.next_event_id

    def execute_script(mut self, url: String, script: String) -> Int:
        """Run a script in every subscriber's browser."""
        self.next_event_id += 1
        var frame = _frame_execute_script(
            script=script, event_id=String(self.next_event_id)
        )
        self.registry.notify_frame(url, self.next_event_id, List[UInt8](frame.as_bytes()))
        return self.next_event_id

    def redirect_to(mut self, url: String, location: String) -> Int:
        """Redirect every subscriber to `location`."""
        self.next_event_id += 1
        var frame = _frame_redirect(
            location=location, event_id=String(self.next_event_id)
        )
        self.registry.notify_frame(url, self.next_event_id, List[UInt8](frame.as_bytes()))
        return self.next_event_id

    def send_frame(mut self, url: String, frame: String) -> Int:
        """Queue a pre-built frame verbatim — the escape hatch.

        Use when you have composed a frame the helpers above do not cover. The
        frame must be complete, including its terminating blank line.
        """
        self.next_event_id += 1
        self.registry.notify_frame(url, self.next_event_id, List[UInt8](frame.as_bytes()))
        return self.next_event_id

    # --- Introspection -----------------------------------------------------

    def subscriber_count(self, url: String) -> Int:
        """How many slots are streaming for `url`."""
        return self.registry.subscriber_count(url)

    def has_subscribers(self, url: String) -> Bool:
        """Whether anyone is listening — skip an expensive render if not."""
        return self.registry.has_subscribers(url)
