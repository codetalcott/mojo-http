"""SSE (Server-Sent Events) support: wire format, subscriber registry, event journal."""

from .format import format_sse_event, format_sse_heartbeat, format_sse_event_bytes, format_sse_heartbeat_bytes
from .registry import SSERegistry
from .journal import PatchJournal, JournalResult
