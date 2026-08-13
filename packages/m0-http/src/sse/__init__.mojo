"""SSE (Server-Sent Events) support: wire format, subscriber registry, event journal."""

from .format import (
    format_sse_event,
    format_sse_heartbeat,
    format_sse_event_bytes,
    format_sse_heartbeat_bytes,
    split_sse_lines,
    NO_EVENT_ID,
)
from .registry import SSERegistry, MAX_PENDING_BYTES
from .journal import PatchJournal, JournalResult
from .response import sse_response, SSE_CONTENT_TYPE, SSE_OPEN_COMMENT
