"""SSE wire-protocol formatting.

Pure functions with no subscriber state — usable by any SSE producer.

Field order is not significant to SSE clients, so these emit `id:` before
`event:`. The Datastar adapter in m0-datastar fixes the opposite order
because the Datastar SDK spec mandates it; see `m0_datastar.sse._build_sse`.
"""


comptime NO_EVENT_ID = -1
"""Pass as `event_id` to emit a frame with no `id:` field."""


def split_sse_lines(data: String) -> List[String]:
    """Split a payload on CRLF, CR, or LF.

    The SSE spec treats all three as line terminators. Splitting on LF alone
    would let a bare CR — routine in HTML from a Windows-authored template —
    pass through into a `data:` field, where the client reads it as a line
    break and the rest of the payload as a new, malformed field.
    """
    var lines = List[String]()
    var bytes = data.as_bytes()
    var n = data.byte_length()
    var start = 0
    var i = 0
    while i < n:
        var c = bytes[i]
        if c == UInt8(ord("\r")) or c == UInt8(ord("\n")):
            lines.append(String(StringSpan(data)[byte=start:i]))
            if c == UInt8(ord("\r")):
                if i + 1 < n and bytes[i + 1] == UInt8(ord("\n")):
                    i += 1
            start = i + 1
        i += 1
    lines.append(String(StringSpan(data)[byte=start:n]))
    return lines^


def format_sse_event(event_id: Int, event_type: String, data: String) -> String:
    """Format a single SSE event as wire-protocol string.

    Multi-line data is split into separate data: fields per the SSE spec.
    Output: "id: N\\nevent: type\\ndata: line1\\ndata: line2\\n\\n"

    Pass `NO_EVENT_ID` to omit the `id:` field entirely. An `id: 0` would set
    the client's Last-Event-ID to "0", which is not the same as sending no id.
    """
    var out = String("")
    if event_id != NO_EVENT_ID:
        out += "id: " + String(event_id) + "\n"
    out += "event: " + event_type + "\n"
    var parts = split_sse_lines(data)
    for i in range(len(parts)):
        out += "data: " + parts[i] + "\n"
    out += "\n"
    return out^


def format_sse_heartbeat() -> String:
    """Format an SSE heartbeat comment.

    Output: ": heartbeat\\n\\n"
    """
    return ": heartbeat\n\n"


def format_sse_event_bytes(event_id: Int, event_type: String, data: String) -> List[UInt8]:
    """Format a single SSE event as wire-protocol bytes."""
    var s = format_sse_event(event_id, event_type, data)
    return List[UInt8](s.as_bytes())


def format_sse_heartbeat_bytes() -> List[UInt8]:
    """Format an SSE heartbeat comment as bytes."""
    var s = format_sse_heartbeat()
    return List[UInt8](s.as_bytes())


def sse_data_payload(frame: Span[Byte, _]) -> List[UInt8]:
    """The `data` payload of one SSE frame — the inverse of `format_sse_event`.

    Returns exactly what a browser's `EventSource` hands to `onmessage` as
    `event.data`: every `data` field's value, joined with a single `\\n`, with
    no trailing newline. `id:`, `event:`, `retry:` and comment lines are
    dropped; a frame carrying no `data` field at all (a `: heartbeat`
    comment, say) yields an empty payload, which is how a caller tells the
    two apart.

    This exists because a frame that has already been *framed* as SSE
    sometimes has to reach a subscriber on a different transport. The
    `BroadcastBus` carries complete SSE frames, and a WebSocket subscriber
    needs the payload, not the framing — `apps/django_realtime` re-encodes
    exactly this with `encode_ws_frame`, so its WebSocket clients and its
    `EventSource` clients see byte-identical messages from one publish.

    Field parsing follows the WHATWG event-stream rules: the name runs to the
    first colon, one optional space after the colon is stripped, and a line
    with no colon is a field with an empty value. Line terminators are
    CRLF, CR, or LF, as in `split_sse_lines`.
    """
    var text = String(StringSpan(unsafe_from_utf8=frame))
    var lines = split_sse_lines(text)
    var out = List[UInt8]()
    var first = True
    for i in range(len(lines)):
        var line = lines[i]
        if line.byte_length() == 0:
            # The blank line ends the event; a frame is one event, so
            # anything after it belongs to no event this function reports.
            break
        if line.as_bytes()[0] == UInt8(ord(":")):
            continue  # comment
        var colon = line.find(":")
        var name = line if colon < 0 else String(StringSpan(line)[byte=0:colon])
        if name != "data":
            continue
        var value = String("")
        if colon >= 0:
            var start = colon + 1
            # Exactly one space after the colon is part of the framing.
            if start < line.byte_length() and line.as_bytes()[start] == UInt8(ord(" ")):
                start += 1
            value = String(StringSpan(line)[byte=start:line.byte_length()])
        if not first:
            out.append(UInt8(ord("\n")))
        out.extend(value.as_bytes())
        first = False
    return out^
