"""`m0-datastar`: Datastar SSE protocol for Mojo (v1.0.2).

Two layers. `consts` and `sse` are the pure wire format with no dependencies —
usable on their own to generate Datastar frames for any transport. `stream` and
`signals` connect that format to this framework's HTTP server, and are the only
parts that depend on `m0_http` and `lightbug_http`.
"""

from .consts import (
    VERSION,
    DATASTAR_KEY,
    DEFAULT_SSE_RETRY_DURATION,
    DEFAULT_ELEMENTS_USE_VIEW_TRANSITIONS,
    DEFAULT_PATCH_SIGNALS_ONLY_IF_MISSING,
    DEFAULT_PATCH_MODE,
    PATCH_MODE_OUTER,
    PATCH_MODE_INNER,
    PATCH_MODE_REMOVE,
    PATCH_MODE_REPLACE,
    PATCH_MODE_PREPEND,
    PATCH_MODE_APPEND,
    PATCH_MODE_BEFORE,
    PATCH_MODE_AFTER,
    EVENT_PATCH_ELEMENTS,
    EVENT_PATCH_SIGNALS,
    DL_SELECTOR,
    DL_MODE,
    DL_NAMESPACE,
    DL_USE_VIEW_TRANSITION,
    DL_VIEW_TRANSITION_SELECTOR,
    DL_ELEMENTS,
    DL_SIGNALS,
    DL_ONLY_IF_MISSING,
    NS_HTML,
    NS_SVG,
    NS_MATHML,
    js_bool,
)
from .sse import (
    patch_elements,
    patch_signals,
    execute_script,
    redirect,
    split_data_lines,
)
from .stream import DatastarStream
from .signals import read_signals, SIGNALS_QUERY_PARAM, EMPTY_SIGNALS
