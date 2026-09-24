"""Datastar SSE event generation (v1.0.4).

Functions for generating Server-Sent Events following the Datastar protocol.
Each function returns a formatted SSE string ready for wire transmission.
Uses List[UInt8] buffer for efficient string building.

The specification is the SDK's `sdk/ADR.md` at the pinned tag, and its
conformance cases are vendored in `test/sdk/` and run by `poe
check-datastar-sdk` (SPEC I27). A value that may span lines -- `elements`,
`signals` -- is split into one dataline per line; a value that must stay on
one line -- a selector, a mode, a namespace, an event id -- is refused when
it carries CR or LF (SPEC I29), because the break would end its field and
the rest would be read as fields, or a whole event, of its own.
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


def split_data_lines(data: String) -> List[String]:
    """Split a payload on CRLF, CR, or LF.

    The SSE spec treats all three as line terminators, so splitting on LF alone
    would let a bare CR — routine in HTML from a Windows-authored template —
    reach a `data:` field, where the client reads it as a line break and the
    remainder as a new, malformed field.

    Deliberately duplicated from `m0_http.sse.format.split_sse_lines` rather
    than imported: `consts.mojo` and `sse.mojo` stay dependency-free so the
    Datastar wire format is usable without the rest of the framework. The
    duplication is why this function needed the SAME fix twice: the one in
    `m0_http` was corrected first and this one kept trapping.

    Every cut is a BYTE-span slice, never `[byte=a:b]` (SPEC G14). What
    reaches here is a RENDERED FRAGMENT, and an application builds that out
    of request data — `apps/datastar_todo` renders a todo's text, which is
    whatever the browser posted. HTML escaping does not make a string UTF-8:
    it leaves bytes above 0x7F alone and does not touch newlines, so a todo
    reading `a\\n<0x80>b` puts a non-boundary byte immediately after a line
    break, which is exactly where this cuts. `[byte=a:b]` asserts a codepoint
    boundary there and traps the LOOP thread — measured before this fix as
    one unauthenticated `POST /add` killing the whole process, every tab with
    it (`smoke-todo`'s hostile phase).
    """
    var lines = List[String]()
    var bytes = data.as_bytes()
    var n = data.byte_length()
    var start = 0
    var i = 0
    while i < n:
        var c = bytes[i]
        if c == UInt8(ord("\r")) or c == UInt8(ord("\n")):
            lines.append(String(unsafe_from_utf8=bytes[start:i]))
            if c == UInt8(ord("\r")):
                if i + 1 < n and bytes[i + 1] == UInt8(ord("\n")):
                    i += 1
            start = i + 1
        i += 1
    lines.append(String(unsafe_from_utf8=bytes[start:n]))
    return lines^


def _buf_to_string(var buf: List[UInt8]) -> String:
    """Convert a byte buffer to a String (takes ownership)."""
    return String(unsafe_from_utf8=Span(buf))


def _refuse_line_break(field: String, value: String) raises:
    """Raise if `value` holds CR or LF, either of which ends an SSE line.

    A selector built from request data is the realistic way one arrives:
    `#a\\n\\nevent: ...` would close this event and open another of the
    sender's choosing. Refused rather than stripped or cut, because either
    of those silently names a different target (SPEC I29).
    """
    var bytes = value.as_bytes()
    for i in range(value.byte_length()):
        if bytes[i] == UInt8(ord("\r")) or bytes[i] == UInt8(ord("\n")):
            raise Error(
                String(
                    "m0_datastar: the ",
                    field,
                    " carries a line break, which would end its SSE line",
                )
            )


def _hex_digit(n: Int) -> UInt8:
    if n < 10:
        return UInt8(ord("0") + n)
    return UInt8(ord("a") + n - 10)


def _js_string(s: String) -> String:
    """`s` as a double-quoted JavaScript string literal that stays inside it.

    The literal lands in a `<script>` element's text, which the HTML parser
    ends at the first `</script`, so `<` is escaped as well as the quote,
    the backslash and every control byte -- and U+2028/U+2029, the line
    separators older engines refused inside a literal. Bytes above 0x7F
    otherwise pass through: the stream is decoded as UTF-8 and a malformed
    byte becomes U+FFFD, which ends nothing.
    """
    var src = s.as_bytes()
    var n = s.byte_length()
    var out = List[UInt8](capacity=n + 2)
    out.append(UInt8(ord('"')))
    var i = 0
    while i < n:
        var c = src[i]
        if c == UInt8(ord('"')) or c == UInt8(ord("\\")):
            out.append(UInt8(ord("\\")))
            out.append(c)
        elif c == UInt8(ord("<")) or c < UInt8(0x20) or c == UInt8(0x7F):
            _buf_write(out, "\\u00")
            out.append(_hex_digit(Int(c) >> 4))
            out.append(_hex_digit(Int(c) & 0xF))
        elif (
            c == UInt8(0xE2)
            and i + 2 < n
            and src[i + 1] == UInt8(0x80)
            and (src[i + 2] == UInt8(0xA8) or src[i + 2] == UInt8(0xA9))
        ):
            _buf_write(out, "\\u202")
            out.append(UInt8(ord("8")) if src[i + 2] == UInt8(0xA8) else UInt8(ord("9")))
            i += 2
        else:
            out.append(c)
        i += 1
    out.append(UInt8(ord('"')))
    return _buf_to_string(out^)


def _build_sse(
    event_type: String,
    data_lines: List[String],
    event_id: String = "",
    retry_duration: Int = -1,
) raises -> String:
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
    _refuse_line_break("event id", event_id)
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
) raises -> String:
    """Generate a Datastar patch-elements SSE event.

    Only non-default datalines are emitted, per the SDK spec, and an empty
    `elements` emits none: `remove` mode takes a selector and no elements.

    Raises when `selector`, `mode`, `namespace`, `view_transition_selector`
    or `event_id` carries CR or LF (SPEC I29).

    Args:
        elements: HTML content to patch into the DOM; may span lines.
        selector: CSS selector for the target element.
        mode: Patch mode (outer, inner, replace, prepend, append, before, after, remove).
        namespace: XML namespace (svg, mathml) if applicable.
        use_view_transition: Whether to use the View Transition API.
        view_transition_selector: CSS selector for the element to run the view
            transition on. Only emitted when use_view_transition is True.
        event_id: Optional SSE event ID.
        retry_duration: Optional SSE retry duration in ms.
    """
    _refuse_line_break("selector", selector)
    _refuse_line_break("mode", mode)
    _refuse_line_break("namespace", namespace)
    _refuse_line_break("view transition selector", view_transition_selector)
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

    # One dataline per line of HTML; none at all for no HTML.
    if elements.byte_length() > 0:
        var parts = split_data_lines(elements)
        for i in range(len(parts)):
            lines.append(DL_ELEMENTS + parts[i])

    return _build_sse(EVENT_PATCH_ELEMENTS, lines, event_id, retry_duration)


def patch_signals(
    signals: String,
    event_id: String = "",
    only_if_missing: Bool = False,
    retry_duration: Int = -1,
) raises -> String:
    """Generate a Datastar patch-signals SSE event.

    A pretty-printed JSON object spans lines, and each goes out as its own
    `signals` dataline -- the client joins them back with newlines. One
    dataline holding the whole value would end at the first line break,
    and the lines after it would be read as fields named after their JSON
    keys (the SDK's `patchSignalsWithMultilineJson` case).

    Raises when `event_id` carries CR or LF (SPEC I29).

    Args:
        signals: JSON string of signals to update; may span lines.
        event_id: Optional SSE event ID.
        only_if_missing: Only patch signals that don't already exist.
        retry_duration: Optional SSE retry duration in ms.
    """
    var lines = List[String]()
    if only_if_missing:
        lines.append(DL_ONLY_IF_MISSING + "true")
    var parts = split_data_lines(signals)
    for i in range(len(parts)):
        lines.append(DL_SIGNALS + parts[i])
    return _build_sse(EVENT_PATCH_SIGNALS, lines, event_id, retry_duration)


def execute_script(
    script: String,
    auto_remove: Bool = True,
    attributes: List[String] = List[String](),
    event_id: String = "",
    retry_duration: Int = -1,
) raises -> String:
    """Generate a script execution event by patching a <script> element.

    Raises when `event_id` carries CR or LF (SPEC I29).

    Args:
        script: JavaScript code to execute on the client; may span lines.
        auto_remove: Remove the script element after execution.
        attributes: Attributes for the script tag, each already written
            as `name="value"` -- the Go SDK's shape. They go out verbatim,
            before `data-effect`, so a value from request data must be
            escaped by the caller.
        event_id: Optional SSE event ID.
        retry_duration: Optional SSE retry duration in ms.
    """
    var buf = List[UInt8](capacity=128)
    _buf_write(buf, "<script")
    for i in range(len(attributes)):
        _buf_write(buf, " ")
        _buf_write(buf, attributes[i])
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


def redirect(
    location: String,
    event_id: String = "",
    retry_duration: Int = -1,
) raises -> String:
    """Generate a redirect event that navigates to a new URL.

    Not in the SDK spec (the Go SDK has none); this package's own sugar
    over `execute_script`. The location is written as a JavaScript string
    literal by `_js_string`, so no byte of it can end the literal or the
    script element around it -- a `next=` parameter after a login is the
    usual way request data reaches here (SPEC I29).

    Args:
        location: URL or path to redirect the client to.
        event_id: Optional SSE event ID.
        retry_duration: Optional SSE retry duration in ms.
    """
    var buf = List[UInt8](capacity=64)
    _buf_write(buf, "setTimeout(() => window.location = ")
    _buf_write(buf, _js_string(location))
    _buf_write(buf, ")")
    return execute_script(
        _buf_to_string(buf^),
        event_id=event_id,
        retry_duration=retry_duration,
    )
