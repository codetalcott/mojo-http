"""
m0-http: HTTP framework components for the M0 framework.

Depends on: m0-core (hashing for ETags)

Provides routing, content negotiation, ETag computation, response caching,
and SSE (Server-Sent Events) support. Multiworker and shutdown deferred
until lightbug_http is vendored.
"""

from .router import Router, MatchResult
from .content_negotiation import (
    AcceptResult,
    parse_accept,
    wants_siren_bin,
    wants_patch,
    wants_html,
    wants_event_stream,
)
from .etag import compute_etag, etag_matches
from .response_cache import ResponseCache
from .sse import (
    format_sse_event,
    format_sse_heartbeat,
    SSERegistry,
    PatchJournal,
    JournalResult,
)
