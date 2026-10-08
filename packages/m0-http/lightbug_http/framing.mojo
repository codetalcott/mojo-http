"""Where a request's head ends and how its body is framed, decided once.

`frame_request_head` is the event loop's one framing decision for a
request still in its head. It reads the bytes buffered so far and answers
INCOMPLETE (read on), REFUSED (by which rule), or REQUEST: the
head's end, the body's framing -- none, a length, chunked -- and, where the
head alone fixes it, where the request ends in the buffer (`request_end`;
for a chunked body the connection's decoder finds it). `loop/request.mojo`'s
`_handle_read_headers` acts on the answer and frames nothing itself.

Two framers read a head: `find_header_end`, the first CRLFCRLF, and the
parser, which stops at the empty line ending the fields. They disagreed
once -- the parser ended a head at a bare-LF empty line inside what the
loop framed as one head -- and a request pipelined behind it vanished, a
body past a `Content-Length` was answered as a request (SPEC B12). Both are
asked here, together, and a head they end apart is refused.

Pure: no socket, no slot, no clock -- the buffer, how far an earlier call
scanned it, and three limits. That is what lets `scripts/fuzz_request.mojo`
hold it to invariants that span the parser and the loop (SPEC B29): a
framed request ends its head where the parser stopped; a head split across
reads is framed as it is whole; a refusal stays one, and a framed request
is unchanged, whatever arrives behind it.
"""

from lightbug_http.header import (
    ParsedRequestHeaders,
    UnsupportedHTTPRequestError,
    find_header_end,
    holds_bare_lf,
    parse_request_headers,
)


# What the decision is.
comptime FRAME_INCOMPLETE = 0
comptime FRAME_REFUSED = 1
comptime FRAME_REQUEST = 2

# How a framed request's body is framed (`HeadFraming.body`).
comptime BODY_NONE = 0
comptime BODY_LENGTH = 1
comptime BODY_CHUNKED = 2

# Which rule refused (`HeadFraming.rule`), and so what the loop answers
# (`loop/request.mojo`'s `_refusal`, which knows every one of them).
comptime REFUSED_NONE = 0
comptime REFUSED_BARE_LF = 1  # 400, a head still arriving (SPEC B23)
comptime REFUSED_HEAD_TOO_LARGE = 2  # 431
comptime REFUSED_MALFORMED = 3  # 400
comptime REFUSED_NOT_IMPLEMENTED = 4  # 501 (SPEC B18, B21)
comptime REFUSED_FRAMERS_DISAGREE = 5  # 400 (SPEC B12)
comptime REFUSED_URI_TOO_LONG = 6  # 414
comptime REFUSED_BODY_TOO_LARGE = 7  # 413, answered while the body arrives


@fieldwise_init
struct HeadFraming(Copyable, Movable):
    """The framing decision for a request head (`frame_request_head`).

    Made by name -- `incomplete()`, `refused(rule)`, `request(...)` -- and
    numbers only. The parsed head of a framed request goes to the caller's
    own slot, never into this: carried here in an `Optional`, it cost the
    head path about 100 ns a request, 850 ns becoming 950 for a GET of
    twelve fields, where the slot costs nothing measurable.
    """

    var outcome: Int
    """`FRAME_INCOMPLETE`, `FRAME_REFUSED` or `FRAME_REQUEST`."""
    var rule: Int
    """For a refusal, which rule refused (`REFUSED_*`): the one key the loop
    answers by."""
    var head_end: Int
    """For a request, the offset of the first byte after the head's CRLFCRLF,
    which is where the parser stopped."""
    var body: Int
    """For a request, `BODY_NONE`, `BODY_LENGTH` or `BODY_CHUNKED`."""
    var content_length: Int
    """For a request, its `Content-Length` (0 with none, and when chunked)."""
    var request_end: Int
    """For a request, where it ends in the buffer: `head_end` plus its
    length. 0 for a chunked body, whose end the decoder finds."""

    @staticmethod
    def incomplete() -> Self:
        """No head yet: read on."""
        return Self(
            outcome=FRAME_INCOMPLETE, rule=REFUSED_NONE, head_end=0,
            body=BODY_NONE, content_length=0, request_end=0,
        )

    @staticmethod
    def refused(rule: Int) -> Self:
        """A head refused by `rule` (`REFUSED_*`)."""
        return Self(
            outcome=FRAME_REFUSED, rule=rule, head_end=0, body=BODY_NONE,
            content_length=0, request_end=0,
        )

    @staticmethod
    def request(head_end: Int, is_chunked: Bool, content_length: Int) -> Self:
        """A framed request whose head ends at `head_end`."""
        if is_chunked:
            return Self(
                outcome=FRAME_REQUEST, rule=REFUSED_NONE, head_end=head_end,
                body=BODY_CHUNKED, content_length=content_length,
                request_end=0,
            )
        return Self(
            outcome=FRAME_REQUEST, rule=REFUSED_NONE, head_end=head_end,
            body=BODY_LENGTH if content_length > 0 else BODY_NONE,
            content_length=content_length,
            request_end=head_end + content_length,
        )


def frame_request_head(
    buffer: Span[Byte, _],
    scanned: Int,
    max_header_size: Int,
    max_uri_length: Int,
    max_body_size: Int,
    mut head: Optional[ParsedRequestHeaders],
) -> HeadFraming:
    """Decide a request head's framing from the bytes buffered so far.

    `buffer` opens at the request's first byte. `scanned` is its length when
    an earlier call answered INCOMPLETE (0 for the first call): the
    terminator search starts just before it, and only the bytes after it are
    asked for a bare LF, each with the byte before it, so a head arriving
    in pieces is scanned once and a CR ending one read and the LF opening
    the next are a CRLF.

    Refused, in this order, each by its `REFUSED_*` rule: a head still
    incomplete that holds a bare LF (SPEC B23); a head longer than
    `max_header_size`; a head the parser refuses, or one asking for what
    this server does not implement (SPEC B18, B21); a head the parser ended
    anywhere but where `find_header_end` did (SPEC B12); a target longer
    than `max_uri_length`; a `Content-Length` over `max_body_size`. A
    chunked body's size is the decoder's to bound, as it arrives.

    A framed request's parsed head is moved into `head`, which is left as it
    was for any other answer.
    """
    # `find_header_end` backs off three bytes from `scanned`, never before
    # the first byte, so a CRLFCRLF the last read ended inside is found:
    # every call before this one searched all it was given, so a terminator
    # not yet found starts at `scanned - 3` or later (LF66).
    var header_end = find_header_end(buffer, scanned)
    if not header_end:
        # No CRLFCRLF frames a head yet. One holding a bare LF can only be
        # refused, and one of bare LFs only would never be framed at all,
        # so it is refused now rather than at its peer's EOF or the header
        # timeout's 408 (SPEC B23).
        if holds_bare_lf(buffer, scanned):
            return HeadFraming.refused(REFUSED_BARE_LF)
        return HeadFraming.incomplete()

    var head_end = header_end.value()
    if head_end > max_header_size:
        return HeadFraming.refused(REFUSED_HEAD_TOO_LARGE)

    var parsed: ParsedRequestHeaders
    try:
        parsed = parse_request_headers(buffer[:head_end])
    except parse_err:
        # A well-formed request for what this server does not implement is
        # 501 (SPEC B18), anything malformed 400.
        if parse_err.isa[UnsupportedHTTPRequestError]():
            return HeadFraming.refused(REFUSED_NOT_IMPLEMENTED)
        return HeadFraming.refused(REFUSED_MALFORMED)

    # The two framers must name the same byte. The parser refuses a bare LF,
    # so with it they agree; this refuses any head they would read
    # differently, so a future parser change cannot reopen the gap
    # silently. The strict parser never reaches it, and `poe sabotage-fuzz`
    # gates it: removed, its LF2-revert arm is caught by the framing
    # invariant instead of the parser's own, a miss (SPEC B12, B29).
    if parsed.bytes_consumed != head_end:
        return HeadFraming.refused(REFUSED_FRAMERS_DISAGREE)

    if parsed.path.byte_length() > max_uri_length:
        return HeadFraming.refused(REFUSED_URI_TOO_LONG)

    var content_length = parsed.content_length()
    var is_chunked = parsed.is_chunked_body()
    if not is_chunked and content_length > max_body_size:
        return HeadFraming.refused(REFUSED_BODY_TOO_LARGE)

    head = parsed^
    return HeadFraming.request(head_end, is_chunked, content_length)
