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
            lines.append(String(StringSlice(data)[byte=start:i]))
            if c == UInt8(ord("\r")):
                if i + 1 < n and bytes[i + 1] == UInt8(ord("\n")):
                    i += 1
            start = i + 1
        i += 1
    lines.append(String(StringSlice(data)[byte=start:n]))
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
