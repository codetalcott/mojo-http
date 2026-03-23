"""SSE wire-protocol formatting.

Extracted from siren-grail's sse_registry.mojo. Pure functions
with no subscriber state — usable by any SSE producer.
"""


def format_sse_event(event_id: Int, event_type: String, data: String) -> String:
    """Format a single SSE event as wire-protocol string.

    Multi-line data is split into separate data: fields per the SSE spec.
    Output: "id: N\\nevent: type\\ndata: line1\\ndata: line2\\n\\n"
    """
    var out = String("id: ") + String(event_id) + "\n"
    out += "event: " + event_type + "\n"
    var parts = data.split("\n")
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
