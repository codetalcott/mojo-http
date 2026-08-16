"""Accept-header content negotiation per RFC 9110 §12.5.1.

Parses Accept headers and determines which media types the client prefers.
Four standard types are recognised directly; anything else — vendor types such
as `application/vnd.siren+bin` — is supplied by the caller as a list of extra
media types, so this layer stays independent of any representation format.

Supports quality factors, case-insensitive media ranges, subtype wildcards
(`text/*`), and `*/*`, with more specific ranges taking precedence over less
specific ones regardless of the order they appear in the header.
"""


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
        return _contains(self.extra_types, media_type.lower())


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
    """Parse Accept header with quality factors per RFC 7231.

    Recognises the four standard types only. To match vendor types, pass them
    via the two-argument overload.
    """
    return parse_accept(accept, List[String]())


def parse_accept(accept: String, extra: List[String]) -> AcceptResult:
    """Parse Accept header with quality factors per RFC 7231.

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
                var part = String(StringSlice(accept)[byte=start:i])
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
        var vendor = extra[j].lower()
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
    """
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

    ranges.append(media_type.lower())
    qualities.append(quality)


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
        var subtype_wildcard = String(StringSlice(target)[byte=0:slash]) + "/*"
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


def _trim(s: String) -> String:
    """Trim leading and trailing whitespace."""
    var bytes = s.as_bytes()
    var start = 0
    var end = s.byte_length()
    while start < end and (bytes[start] == UInt8(ord(" ")) or bytes[start] == UInt8(ord("\t"))):
        start += 1
    while end > start and (bytes[end - 1] == UInt8(ord(" ")) or bytes[end - 1] == UInt8(ord("\t"))):
        end -= 1
    if start == 0 and end == s.byte_length():
        return s
    return String(StringSlice(s)[byte=start:end])


def _contains(types: List[String], media_type: String) -> Bool:
    """Whether a media type appears in a list."""
    for i in range(len(types)):
        if types[i] == media_type:
            return True
    return False


# Convenience predicates
def wants_html(accept: String) -> Bool:
    return parse_accept(accept).wants_html


def wants_event_stream(accept: String) -> Bool:
    return parse_accept(accept).wants_event_stream


# --- Accept-Encoding (RFC 9110 §12.5.3) --------------------------------------


def _parse_codings(
    header: String, mut ranges: List[String], mut qualities: List[Float64]
):
    """Split an Accept-Encoding header into (coding, quality) pairs.

    Reuses the media-range splitter: a content-coding entry is the same
    `token;q=...` shape, just without a slash.
    """
    var start = 0
    var i = 0
    while i <= header.byte_length():
        var at_end = i == header.byte_length()
        var at_comma = False
        if not at_end:
            at_comma = header.as_bytes()[i] == UInt8(ord(","))
        if at_comma or at_end:
            if i > start:
                var part = String(StringSlice(header)[byte=start:i])
                _split_media_range(part, ranges, qualities)
            start = i + 1
        i += 1


def _coding_quality(
    ranges: List[String], qualities: List[Float64], coding: String
) -> Float64:
    """Quality for a coding: its own last occurrence, else `*`, else -1."""
    var q = _last_quality(ranges, qualities, coding)
    if q >= 0.0:
        return q
    return _last_quality(ranges, qualities, "*")


def negotiate_encoding(
    accept_encoding: String, available: List[String]
) -> String:
    """Choose a content-coding per RFC 9110 §12.5.3.

    `available` lists the codings the caller can actually serve, most
    preferred first — for example `["br", "gzip"]` when precompressed
    variants exist. This layer only *picks*; it never compresses anything,
    for the same reason `AcceptResult` never renders anything: negotiation
    stays representation-agnostic, and what codings exist is the caller's
    business. `OK(body, content_type, content_encoding)` is the far end of
    the handshake.

    Returns the chosen coding, lowercased. Returns `"identity"` when no
    listed coding is acceptable but an unencoded response is — identity is
    implicitly acceptable unless the client refuses it (`identity;q=0`, or
    `*;q=0` without identity being named). Returns `""` when even identity
    is refused: the caller should answer 406.

    Selection: the acceptable available coding with the highest quality
    wins; on a quality tie the earlier entry in `available` (the server's
    preference) wins. An implicitly acceptable identity never outranks a
    coding the client explicitly accepted — a client that said `gzip;q=0.1`
    asked for gzip, however faintly.

    A response chosen this way varies by request header: send
    `Vary: Accept-Encoding` alongside it, and do not put it in a URL-keyed
    cache such as `ResponseCache`.
    """
    if accept_encoding.byte_length() == 0:
        # No header: the client states no preference, and an unencoded
        # response is the one nobody has to guess about — the same
        # conservative default as `*/*` resolving to JSON.
        return String("identity")

    var ranges = List[String]()
    var qualities = List[Float64]()
    _parse_codings(accept_encoding, ranges, qualities)

    var best = String("")
    var best_q: Float64 = 0.0
    for i in range(len(available)):
        var coding = available[i].lower()
        if coding == "identity":
            continue  # identity is the fallback below, never an "encoding"
        var q = _coding_quality(ranges, qualities, coding)
        if q > best_q:
            best = coding^
            best_q = q
    if best.byte_length() > 0:
        return best^

    var identity_q = _coding_quality(ranges, qualities, "identity")
    if identity_q < 0.0 or identity_q > 0.0:
        return String("identity")
    return String("")
