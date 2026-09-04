"""
`m0-http`: HTTP framework components for the M0 framework.

Depends on: m0-core (hashing for ETags)

Provides routing, content negotiation, ETag computation, response caching,
SSE (Server-Sent Events) support, and multi-worker fork supervision.
"""

from .router import Router, MatchResult
from .content_negotiation import (
    AcceptResult,
    negotiate_encoding,
    negotiate_language,
    parse_accept,
    wants_html,
    wants_event_stream,
)
from .etag import compute_etag, etag_matches
from .reply import (
    accept_header,
    body_string,
    empty,
    html,
    json,
    no_content,
    param_int,
    problem,
    redirect,
    vary_accept,
)
from .reload import MtimeScanner, ScanResult
from .static import StaticFiles, content_type_for
from .response_cache import ResponseCache
from .sse import (
    format_sse_event,
    format_sse_heartbeat,
    split_sse_lines,
    sse_data_payload,
    NO_EVENT_ID,
    SSERegistry,
    PatchJournal,
    JournalResult,
    sse_response,
    SSE_CONTENT_TYPE,
)
from .multiworker import WorkerSupervisor, exit_worker, shared_fetch_add, shared_load
from .threads import (
    ThreadSet, ThreadBlock, ShutdownFanout, dup_fd, read_one_byte_blocking,
    BLK_INDEX, BLK_LISTEN_FD, BLK_SHUTDOWN_FD, BLK_BUS_FD, BLK_USER, BLK_STATUS,
    BLK_LANE, BLK_TURN_ADDR, BLK_QOS,
    request_qos_class, QOS_CLASS_USER_INTERACTIVE, QOS_CLASS_USER_INITIATED,
    STATUS_OK, STATUS_RAISED, STATUS_NEVER_RAN,
)
from .ws import WSHub
from .cors import CorsConfig, apply_cors_headers
from .auth import check_api_key
from .request_context import RequestContext
from .log import LogEntry, log_json, log_access
from .signal import (
    create_shutdown_pipe, ShutdownHandle,
    install_shutdown_signals, shutdown_signals_active,
)
from .health import HealthRegistry
from .config import AppConfig, threads_conflict
from .client import Client
