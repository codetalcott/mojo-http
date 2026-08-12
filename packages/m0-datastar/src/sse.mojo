"""Datastar SSE event generation (v1.0.2).

Functions for generating Server-Sent Events following the Datastar protocol.
Each function returns a formatted SSE string ready for wire transmission.
Uses List[UInt8] buffer for efficient string building.
"""

from std.memory import unsafe_memcpy

from .consts import (
    EVENT_PATCH_ELEMENTS,
    EVENT_PATCH_SIGNALS,
    DEFAULT_PATCH_MODE,
    PATCH_MODE_APPEND,
    DEFAULT_SSE_RETRY_DURATION,
    DL_MODE,
    DL_SELECTOR,
    DL_NAMESPACE,
    DL_USE_VIEW_TRANSITION,
    DL_VIEW_TRANSITION_SELECTOR,
    DL_ELEMENTS,
    DL_SIGNALS,
    DL_ONLY_IF_MISSING,
    NS_HTML,
    js_bool,
)


def _buf_write(mut buf: List[UInt8], s: String):
    """Append a string's bytes to a byte buffer."""
    var bytes = s.as_bytes()
    var old_len = len(buf)
    var count = len(bytes)
    buf.resize(old_len + count, 0)
    unsafe_memcpy(
        dest=buf.unsafe_ptr().unsafe_offset(old_len),
        src=bytes.unsafe_ptr(),
        count=count,
    )


def _buf_to_string(var buf: List[UInt8]) -> String:
    """Convert a byte buffer to a String (takes ownership)."""
    return String(unsafe_from_utf8=Span(unsafe_ptr=buf.unsafe_ptr(), length=len(buf)))


def _build_sse(
    event_type: String,
    data_lines: List[String],
    event_id: String = "",
    retry_duration: Int = -1,
) -> String:
    """Build a raw SSE event string with multi-line data support.

    Field order is mandated by the Datastar SDK spec (ADR "Implementation
    Requirements"): event, then id, then retry, then the data lines.

    Output format:
        event: <event_type>
        id: <event_id>
        retry: <duration>
        data: <line1>
        data: <line2>
        <blank line>
    """
    var buf = List[UInt8](capacity=256)
    _buf_write(buf, "event: ")
    _buf_write(buf, event_type)
    _buf_write(buf, "\n")
    if event_id.byte_length() > 0:
        _buf_write(buf, "id: ")
        _buf_write(buf, event_id)
        _buf_write(buf, "\n")
    if retry_duration != -1 and retry_duration != DEFAULT_SSE_RETRY_DURATION:
        _buf_write(buf, "retry: ")
        _buf_write(buf, String(retry_duration))
        _buf_write(buf, "\n")
    for i in range(len(data_lines)):
        _buf_write(buf, "data: ")
        _buf_write(buf, data_lines[i])
        _buf_write(buf, "\n")
    _buf_write(buf, "\n")
    return _buf_to_string(buf^)


def patch_elements(
    elements: String,
    selector: String = "",
    mode: String = DEFAULT_PATCH_MODE,
    namespace: String = "",
    use_view_transition: Bool = False,
    view_transition_selector: String = "",
    event_id: String = "",
    retry_duration: Int = -1,
) -> String:
    """Generate a Datastar patch-elements SSE event.

    Only non-default datalines are emitted, per the SDK spec.

    Args:
        elements: HTML content to patch into the DOM.
        selector: CSS selector for the target element.
        mode: Patch mode (outer, inner, replace, prepend, append, before, after, remove).
        namespace: XML namespace (svg, mathml) if applicable.
        use_view_transition: Whether to use the View Transition API.
        view_transition_selector: CSS selector for the element to run the view
            transition on. Only emitted when use_view_transition is True.
        event_id: Optional SSE event ID.
        retry_duration: Optional SSE retry duration in ms.
    """
    var lines = List[String]()
    if selector.byte_length() > 0:
        lines.append(DL_SELECTOR + selector)
    if mode.byte_length() > 0 and mode != DEFAULT_PATCH_MODE:
        lines.append(DL_MODE + mode)
    if use_view_transition:
        lines.append(DL_USE_VIEW_TRANSITION + "true")
        if view_transition_selector.byte_length() > 0:
            lines.append(DL_VIEW_TRANSITION_SELECTOR + view_transition_selector)
    if namespace.byte_length() > 0 and namespace != NS_HTML:
        lines.append(DL_NAMESPACE + namespace)

    # Split multi-line elements into separate data lines
    var parts = elements.split("\n")
    for i in range(len(parts)):
        lines.append(DL_ELEMENTS + parts[i])

    return _build_sse(EVENT_PATCH_ELEMENTS, lines, event_id, retry_duration)


def patch_signals(
    signals: String,
    event_id: String = "",
    only_if_missing: Bool = False,
    retry_duration: Int = -1,
) -> String:
    """Generate a Datastar patch-signals SSE event.

    Args:
        signals: JSON string of signals to update.
        event_id: Optional SSE event ID.
        only_if_missing: Only patch signals that don't already exist.
        retry_duration: Optional SSE retry duration in ms.
    """
    var lines = List[String]()
    if only_if_missing:
        lines.append(DL_ONLY_IF_MISSING + "true")
    lines.append(DL_SIGNALS + signals)
    return _build_sse(EVENT_PATCH_SIGNALS, lines, event_id, retry_duration)


def execute_script(
    script: String,
    auto_remove: Bool = True,
    event_id: String = "",
    retry_duration: Int = -1,
) -> String:
    """Generate a script execution event by patching a <script> element.

    Args:
        script: JavaScript code to execute on the client.
        auto_remove: Remove the script element after execution.
        event_id: Optional SSE event ID.
        retry_duration: Optional SSE retry duration in ms.
    """
    var buf = List[UInt8](capacity=128)
    _buf_write(buf, "<script")
    if auto_remove:
        # Double quotes are mandated by the SDK spec.
        _buf_write(buf, ' data-effect="el.remove()"')
    _buf_write(buf, ">")
    _buf_write(buf, script)
    _buf_write(buf, "</script>")
    return patch_elements(
        _buf_to_string(buf^),
        selector="body",
        mode=PATCH_MODE_APPEND,
        event_id=event_id,
        retry_duration=retry_duration,
    )


def redirect(location: String) -> String:
    """Generate a redirect event that navigates to a new URL.

    Args:
        location: URL or path to redirect the client to.
    """
    var buf = List[UInt8](capacity=64)
    _buf_write(buf, "setTimeout(() => window.location = '")
    _buf_write(buf, location)
    _buf_write(buf, "')")
    return execute_script(_buf_to_string(buf^))
