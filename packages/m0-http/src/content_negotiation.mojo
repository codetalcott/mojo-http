"""Content negotiation with quality-factor parsing per RFC 7231.

Parses Accept headers and determines which media types the client
prefers. Supports the M0 framework media types plus standard types.
"""


struct AcceptResult(Copyable, Movable):
    """Parsed Accept header negotiation result."""
    var wants_html: Bool
    var wants_json: Bool
    var wants_links_json: Bool
    var wants_siren_bin: Bool
    var wants_siren_bin_patch: Bool
    var wants_event_stream: Bool

    fn __init__(out self):
        self.wants_html = False
        self.wants_json = False
        self.wants_links_json = False
        self.wants_siren_bin = False
        self.wants_siren_bin_patch = False
        self.wants_event_stream = False


fn _parse_quality(s: String) -> Float64:
    """Parse a quality factor value (0.0-1.0) from a string."""
    if len(s) == 0:
        return 1.0
    var result: Float64 = 0.0
    var decimal_place: Float64 = 0.0
    var bytes = s.as_bytes()
    for i in range(len(s)):
        var c = Int(bytes[i])
        if c == ord("."):
            decimal_place = 0.1
        elif c >= ord("0") and c <= ord("9"):
            var digit = Float64(c - ord("0"))
            if decimal_place > 0:
                result += digit * decimal_place
                decimal_place *= 0.1
            else:
                result = result * 10.0 + digit
        else:
            break
    return result


fn parse_accept(accept: String) -> AcceptResult:
    """Parse Accept header with quality factors per RFC 7231.

    Splits on comma, extracts media type and q= parameter.
    Quality of 0 disables a type.
    """
    var result = AcceptResult()
    if len(accept) == 0:
        return result^

    var start = 0
    var i = 0
    while i <= len(accept):
        var at_end = i == len(accept)
        var at_comma = False
        if not at_end:
            at_comma = accept.as_bytes()[i] == UInt8(ord(","))

        if at_comma or at_end:
            if i > start:
                var part = String(StringSlice(accept)[byte=start:i])
                _parse_media_range(part, result)
            start = i + 1
        i += 1

    return result^


fn _parse_media_range(part: String, mut result: AcceptResult):
    """Parse a single media range entry like 'application/json;q=0.8'."""
    var semi_pos = part.find(";")
    var media_type: String
    var quality: Float64 = 1.0

    if semi_pos != -1:
        media_type = _trim(String(StringSlice(part)[byte=0:semi_pos]))
        var params = String(StringSlice(part)[byte=semi_pos + 1:])
        var q_pos = params.find("q=")
        if q_pos != -1:
            var q_str = String(StringSlice(params)[byte=q_pos + 2:])
            quality = _parse_quality(q_str)
    else:
        media_type = _trim(part)

    # Match against known media types
    if media_type == "text/html":
        result.wants_html = quality > 0
    elif media_type == "application/json":
        result.wants_json = quality > 0
    elif media_type == "application/links+json":
        result.wants_links_json = quality > 0
    elif media_type == "application/vnd.siren+bin":
        result.wants_siren_bin = quality > 0
    elif media_type == "application/vnd.siren+bin-patch":
        result.wants_siren_bin_patch = quality > 0
    elif media_type == "text/event-stream":
        result.wants_event_stream = quality > 0
    elif media_type == "*/*":
        if not result.wants_json:
            result.wants_json = quality > 0


fn _trim(s: String) -> String:
    """Trim leading and trailing whitespace."""
    var bytes = s.as_bytes()
    var start = 0
    var end = len(s)
    while start < end and (bytes[start] == UInt8(ord(" ")) or bytes[start] == UInt8(ord("\t"))):
        start += 1
    while end > start and (bytes[end - 1] == UInt8(ord(" ")) or bytes[end - 1] == UInt8(ord("\t"))):
        end -= 1
    if start == 0 and end == len(s):
        return s
    return String(StringSlice(s)[byte=start:end])


# Convenience predicates
fn wants_siren_bin(accept: String) -> Bool:
    return parse_accept(accept).wants_siren_bin


fn wants_patch(accept: String) -> Bool:
    return parse_accept(accept).wants_siren_bin_patch


fn wants_html(accept: String) -> Bool:
    return parse_accept(accept).wants_html


fn wants_event_stream(accept: String) -> Bool:
    return parse_accept(accept).wants_event_stream
