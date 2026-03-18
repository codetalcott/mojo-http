"""Datastar SSE event generation (v1.0.0-RC.8).

Functions for generating Server-Sent Events following the Datastar protocol.
Each function returns a formatted SSE string ready for wire transmission.
"""

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
    DL_ELEMENTS,
    DL_SIGNALS,
    DL_ONLY_IF_MISSING,
    js_bool,
)


fn _build_sse(
    event_type: String,
    data_lines: List[String],
    event_id: String = "",
    retry_duration: Int = -1,
) -> String:
    """Build a raw SSE event string with multi-line data support.

    Output format:
        id: <event_id>
        event: <event_type>
        retry: <duration>
        data: <line1>
        data: <line2>
        <blank line>
    """
    var s = String("")
    if len(event_id) > 0:
        s += "id: " + event_id + "\n"
    s += "event: " + event_type + "\n"
    if retry_duration != -1 and retry_duration != DEFAULT_SSE_RETRY_DURATION:
        s += "retry: " + String(retry_duration) + "\n"
    for i in range(len(data_lines)):
        s += "data: " + data_lines[i] + "\n"
    s += "\n"
    return s^


fn patch_elements(
    elements: String,
    selector: String = "",
    mode: String = DEFAULT_PATCH_MODE,
    namespace: String = "",
    use_view_transition: Bool = False,
    event_id: String = "",
    retry_duration: Int = -1,
) -> String:
    """Generate a Datastar patch-elements SSE event.

    Args:
        elements: HTML content to patch into the DOM.
        selector: CSS selector for the target element.
        mode: Patch mode (outer, inner, replace, prepend, append, before, after, remove).
        namespace: XML namespace (svg, mathml) if applicable.
        use_view_transition: Whether to use the View Transition API.
        event_id: Optional SSE event ID.
        retry_duration: Optional SSE retry duration in ms.
    """
    var lines = List[String]()
    if len(mode) > 0:
        lines.append(DL_MODE + mode)
    if len(selector) > 0:
        lines.append(DL_SELECTOR + selector)
    if len(namespace) > 0:
        lines.append(DL_NAMESPACE + namespace)
    if use_view_transition:
        lines.append(DL_USE_VIEW_TRANSITION + "true")

    # Split multi-line elements into separate data lines
    var parts = elements.split("\n")
    for i in range(len(parts)):
        lines.append(DL_ELEMENTS + parts[i])

    return _build_sse(EVENT_PATCH_ELEMENTS, lines, event_id, retry_duration)


fn patch_signals(
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


fn execute_script(
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
    var tag = String("<script")
    if auto_remove:
        tag += " data-effect='el.remove()'"
    tag += ">" + script + "</script>"
    return patch_elements(
        tag,
        selector="body",
        mode=PATCH_MODE_APPEND,
        event_id=event_id,
        retry_duration=retry_duration,
    )


fn redirect(location: String) -> String:
    """Generate a redirect event that navigates to a new URL.

    Args:
        location: URL or path to redirect the client to.
    """
    return execute_script(
        "setTimeout(() => window.location = '" + location + "')"
    )
