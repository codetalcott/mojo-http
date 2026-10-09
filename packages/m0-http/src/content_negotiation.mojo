"""Accept-header content negotiation per RFC 9110 §12.5.1.

Parses Accept headers and determines which media types the client prefers.
Four standard types are recognised directly; anything else — vendor types such
as `application/vnd.siren+bin` — is supplied by the caller as a list of extra
media types, so this layer stays independent of any representation format.

Supports quality factors, case-insensitive media ranges, subtype wildcards
(`text/*`), and `*/*`, with more specific ranges taking precedence over less
specific ones regardless of the order they appear in the header.
"""

from lightbug_http.header import ascii_lowercase, name_is
from lightbug_http.strings import trim_ows


struct AcceptResult(Copyable, Movable):
    """Parsed Accept header negotiation result."""
    var wants_html: Bool
    var wants_json: Bool
    var wants_event_stream: Bool
    var wants_problem_json: Bool
    var extra_types: List[String]
    """Caller-registered media types the client accepted, case-folded."""

    def __init__(out self):
        self.wants_html = False
        self.wants_json = False
        self.wants_event_stream = False
        self.wants_problem_json = False
        self.extra_types = List[String]()

    def accepts(self, media_type: String) -> Bool:
        """Whether a caller-registered media type was accepted with q > 0.

        Only matches types passed to `parse_accept` as extra types; the four
        standard types have their own fields. Comparison is case-insensitive.
        """
        return _contains(self.extra_types, ascii_lowercase(media_type.as_bytes()))


def _parse_quality(s: String) -> Float64:
    """Parse a quality factor value (0.0-1.0) from a string."""
    if s.byte_length() == 0:
        return 1.0
    var result: Float64 = 0.0
    var decimal_place: Float64 = 0.0
    var bytes = s.as_bytes()
    for i in range(s.byte_length()):
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


def parse_accept(accept: String) -> AcceptResult:
    """Parse Accept header with quality factors per RFC 9110 §12.5.1.

    Recognises the four standard types only. To match vendor types, pass them
    via the two-argument overload.
    """
    return parse_accept(accept, List[String]())


def parse_accept(accept: String, extra: List[String]) -> AcceptResult:
    """Parse Accept header with quality factors per RFC 9110 §12.5.1.

    Splits on comma, extracts media type and q= parameter.
    Quality of 0 disables a type.

    Any media type in `extra` that the client accepts with q > 0 is recorded in
    `AcceptResult.extra_types`, queryable with `AcceptResult.accepts()`.
    """
    var result = AcceptResult()
    if accept.byte_length() == 0:
        return result^

    # Pass 1 — split into (media range, quality) pairs, case-folded.
    var ranges = List[String]()
    var qualities = List[Float64]()
    var start = 0
    var i = 0
    while i <= accept.byte_length():
        var at_end = i == accept.byte_length()
        var at_comma = False
        if not at_end:
            at_comma = accept.as_bytes()[i] == UInt8(ord(","))

        if at_comma or at_end:
            if i > start:
                var part = String(unsafe_from_utf8=accept.as_bytes()[start:i])
                _split_media_range(part, ranges, qualities)
            start = i + 1
        i += 1

    # Pass 2 — resolve each type independently, most specific range first. Doing
    # this after the whole header is parsed is what keeps a trailing `*/*` from
    # reviving a type that was explicitly refused with q=0.
    result.wants_html = _resolve(ranges, qualities, "text/html")
    result.wants_json = _resolve(ranges, qualities, "application/json")
    result.wants_event_stream = _resolve(ranges, qualities, "text/event-stream")
    result.wants_problem_json = _resolve(ranges, qualities, "application/problem+json")

    # `*/*` is deliberately a JSON-only fallback. A client that says it will
    # take anything should not be handed HTML, an event stream, or an opaque
    # vendor binary on that basis — JSON is the safe default representation.
    # An explicit `application/json;q=0` still wins, hence the absence check.
    if not result.wants_json:
        if _last_quality(ranges, qualities, "application/json") < 0.0:
            if _last_quality(ranges, qualities, "*/*") > 0.0:
                result.wants_json = True

    # Vendor types must be named exactly. They are never selected by a wildcard:
    # a caller registering `application/vnd.acme+cbor` wants clients to ask for
    # it, not to receive it because they sent `Accept: */*`.
    for j in range(len(extra)):
        var vendor = ascii_lowercase(extra[j].as_bytes())
        if _last_quality(ranges, qualities, vendor) > 0.0:
            if not _contains(result.extra_types, vendor):
                result.extra_types.append(vendor^)

    return result^


def _split_media_range(
    part: String, mut ranges: List[String], mut qualities: List[Float64]
):
    """Split one entry like 'application/json;q=0.8' into range and quality.

    The media range is case-folded: RFC 9110 §8.3.1 makes type and subtype
    case-insensitive, so `Text/HTML` and `text/html` are the same range.

    The weight is the first parameter named `q` (§12.4.2), read off the
    parameters split on `;` (`_weight`). It was the first substring `q=`,
    so `Q=0` was no weight and `xq=0` was one (review record LF69).
    """
    var bytes = part.as_bytes()
    var semi_pos = part.find(";")
    var media_end = len(bytes)
    var quality: Float64 = 1.0

    if semi_pos != -1:
        media_end = semi_pos
        var start = semi_pos + 1
        while start <= len(bytes):
            var end = start
            while end < len(bytes) and bytes[end] != UInt8(ord(";")):
                end += 1
            var weight = _weight(String(unsafe_from_utf8=bytes[start:end]))
            if weight >= 0.0:
                quality = weight
                break
            start = end + 1

    var media_type = trim_ows(bytes, 0, media_end)
    # ASCII folding only: Unicode `String.lower()` read KELVIN SIGN as `k`
    # and an overlong `C1 A2` as `b`, so a range the client never sent
    # matched a registered vendor type (review record LF63).
    ranges.append(ascii_lowercase(bytes[media_type[0]:media_type[1]]))
    qualities.append(quality)


def _weight(param: String) -> Float64:
    """The weight `param` sets when it is the parameter named `q`, else -1.0.

    A parameter's name is case-insensitive (RFC 9110 §5.6.6), compared in
    ASCII, so `Q=0.5` is a weight and `xq=0` is not. Whitespace around the
    `=` is tolerated though §5.6.6 allows none: a client that sent `q = 0`
    meant a refusal, and `q= 0.5` read as 0 refused what it asked for.
    """
    var eq = param.find("=")
    if eq == -1:
        return -1.0
    var bytes = param.as_bytes()
    var name = trim_ows(bytes, 0, eq)
    if not name_is(bytes[name[0]:name[1]], "q"):
        return -1.0
    var value = trim_ows(bytes, eq + 1, len(bytes))
    return _parse_quality(String(unsafe_from_utf8=bytes[value[0]:value[1]]))


def _resolve(
    ranges: List[String], qualities: List[Float64], target: String
) -> Bool:
    """Whether `target` is acceptable, checking ranges most specific first.

    Precedence follows RFC 9110 §12.5.1: an exact `type/subtype` beats a
    `type/*` subtype wildcard. A more specific range settles the question
    outright, so `text/*;q=0, text/html` still accepts HTML regardless of the
    order the two appear in.

    `*/*` is not consulted here — the caller applies it, because which
    representation a "will take anything" client should get is a policy
    decision, not a parsing one.
    """
    var q = _last_quality(ranges, qualities, target)
    if q >= 0.0:
        return q > 0.0

    var slash = target.find("/")
    if slash != -1:
        var subtype_wildcard = String(unsafe_from_utf8=target.as_bytes()[0:slash]) + "/*"
        q = _last_quality(ranges, qualities, subtype_wildcard)
        if q >= 0.0:
            return q > 0.0

    return False


def _last_quality(
    ranges: List[String], qualities: List[Float64], target: String
) -> Float64:
    """Quality of the last occurrence of `target`, or -1.0 when absent.

    Last occurrence wins so a repeated range behaves like an overwrite.
    """
    var found: Float64 = -1.0
    for i in range(len(ranges)):
        if ranges[i] == target:
            found = qualities[i]
    return found


def _contains(types: List[String], media_type: String) -> Bool:
    """Whether a media type appears in a list."""
    for i in range(len(types)):
        if types[i] == media_type:
            return True
    return False

