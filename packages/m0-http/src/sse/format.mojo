"""SSE wire-protocol formatting.

Extracted from siren-grail's sse_registry.mojo. Pure functions
with no subscriber state — usable by any SSE producer.
"""


fn format_sse_event(event_id: Int, event_type: String, data: String) -> String:
    """Format a single SSE event as wire-protocol string.

    Output: "id: N\\nevent: type\\ndata: json\\n\\n"
    """
    var out = String("id: ") + String(event_id) + "\n"
    out += "event: " + event_type + "\n"
    out += "data: " + data + "\n"
    out += "\n"
    return out^


fn format_sse_heartbeat() -> String:
    """Format an SSE heartbeat comment.

    Output: ": heartbeat\\n\\n"
    """
    return ": heartbeat\n\n"


fn format_sse_event_bytes(event_id: Int, event_type: String, data: String) -> List[UInt8]:
    """Format a single SSE event as wire-protocol bytes."""
    var s = format_sse_event(event_id, event_type, data)
    return List[UInt8](s.as_bytes())


fn format_sse_heartbeat_bytes() -> List[UInt8]:
    """Format an SSE heartbeat comment as bytes."""
    var s = format_sse_heartbeat()
    return List[UInt8](s.as_bytes())
