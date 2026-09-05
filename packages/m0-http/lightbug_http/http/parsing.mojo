from lightbug_http.io.bytes import ByteReader, Bytes, create_string_from_ptr
from lightbug_http.strings import BytesConstant, is_printable_ascii, is_token_char
from std.math import iota
from std.utils import Variant


# --- SIMD scan helpers ---
#
# Every scanner here asks one question of a chunk: which lane, if any, is
# the first in a byte class. It used to be answered in two steps — a
# `reduce_min` to learn whether ANY lane matched, then a scalar loop over
# up to 64 lanes to learn which — at 9.4 ns per chunk for a CR at lane 46
# (measured beside `scripts/bench_http_parts.mojo`). A `select` of `iota`
# against 255 and one `reduce_min` answers both at once in 0.8 ns, with no
# branch and no lane extraction. The old CR-first three-stage scan also
# answered wrong: it reported the first CR even when an LF or a NUL sat
# ahead of it in the same chunk, which the scalar tail never did — so a
# bare-LF line ending followed by a CR within 64 bytes swallowed the next
# line. One mask, the tail's own predicate, is both faster and right.
#
# Each search runs 64 lanes wide while it can, 16 wide over what is left,
# and scalar for the last fifteen bytes. The 64-wide loop alone left up to
# 63 bytes to a `try_peek` per byte, and a request's last two or three
# headers always sit in that tail.

comptime _NO_LANE: UInt8 = 255


@always_inline
def _first_lane[W: Int](mask: SIMD[DType.bool, W]) -> Int:
    """Index of the first True lane of `mask`, or -1 if none is."""
    var lane = mask.select(
        iota[DType.uint8, W](), SIMD[DType.uint8, W](_NO_LANE)
    ).reduce_min()
    if lane == _NO_LANE:
        return -1
    return Int(lane)


@always_inline
def _field_end_lanes[W: Int](chunk: SIMD[DType.uint8, W]) -> SIMD[DType.bool, W]:
    """Lanes that end a field value: a control byte other than HTAB, or DEL.

    RFC 9110 §5.5 field content is VCHAR / SP / HTAB / obs-text, so the
    first byte outside that set is the line terminator or an error — the
    caller looks at the byte to say which.
    """
    var low = chunk.lt(SIMD[DType.uint8, W](0x20)) & chunk.ne(
        SIMD[DType.uint8, W](BytesConstant.TAB)
    )
    return low | chunk.eq(SIMD[DType.uint8, W](0x7F))


@always_inline
def _stop_lanes[W: Int](chunk: SIMD[DType.uint8, W], stop: UInt8) -> SIMD[DType.bool, W]:
    """Lanes holding `stop`, any control byte (HTAB included), or DEL.

    The token scanner and the request-target scanner each stop at one
    delimiter, and a control byte before it is an error for both — so one
    class serves both and the caller tells the two apart by the byte.
    """
    var ctl = chunk.lt(SIMD[DType.uint8, W](0x20)) | chunk.eq(SIMD[DType.uint8, W](0x7F))
    return ctl | chunk.eq(SIMD[DType.uint8, W](stop))


def _find_field_end(ptr: Pointer[UInt8, _], length: Int) -> Int:
    """Offset of the first byte in `length` that cannot be field content, or -1."""
    var i = 0
    while i + 64 <= length:
        var lane = _first_lane[64](_field_end_lanes[64](ptr.unsafe_offset(i).unsafe_load[width=64]()))
        if lane >= 0:
            return i + lane
        i += 64
    while i + 16 <= length:
        var lane = _first_lane[16](_field_end_lanes[16](ptr.unsafe_offset(i).unsafe_load[width=16]()))
        if lane >= 0:
            return i + lane
        i += 16
    while i < length:
        var b = ptr[unsafe_offset=i]
        if (b < 0x20 and b != BytesConstant.TAB) or b == 0x7F:
            return i
        i += 1
    return -1


def _find_stop(ptr: Pointer[UInt8, _], length: Int, stop: UInt8) -> Int:
    """Offset of the first `stop`, control byte or DEL in `length` bytes, or -1."""
    var i = 0
    while i + 64 <= length:
        var lane = _first_lane[64](_stop_lanes[64](ptr.unsafe_offset(i).unsafe_load[width=64](), stop))
        if lane >= 0:
            return i + lane
        i += 64
    while i + 16 <= length:
        var lane = _first_lane[16](_stop_lanes[16](ptr.unsafe_offset(i).unsafe_load[width=16](), stop))
        if lane >= 0:
            return i + lane
        i += 16
    while i < length:
        var b = ptr[unsafe_offset=i]
        if b < 0x20 or b == 0x7F or b == stop:
            return i
        i += 1
    return -1


struct HTTPHeader(Copyable, Movable):
    """One parsed field, as OFFSETS into the buffer the parser was given.

    Four integers, no Strings. It used to carry `name: String` and
    `value: String`, materialised by the scanners and then read back as
    bytes by the one consumer — `parse_request_headers` / the response
    twin — which copied them AGAIN into the `Headers` blob. Two copies of
    every header per request, the first of which existed only to be the
    source of the second; measured at 1.2 µs of a 3.7 µs user-space request
    on the twelve-header browser shape (`scripts/bench_http_parts.mojo`).
    As offsets the intermediate is gone, and the 100-element fill the
    parser preallocates is 3.2 KB of integers rather than 200 String
    constructions.

    `name_len == 0` is an obs-fold continuation line, exactly as an empty
    `name` String was.
    """

    var name_start: Int
    var name_len: Int
    var value_start: Int
    var value_len: Int

    def __init__(out self):
        self.name_start = 0
        self.name_len = 0
        self.value_start = 0
        self.value_len = 0


@fieldwise_init
struct ParseError(Movable, Writable, TrivialRegisterPassable):
    """Invalid HTTP syntax error."""

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write("ParseError: Invalid HTTP syntax")

    def __str__(self) -> String:
        return String(self)


@fieldwise_init
struct IncompleteError(Movable, Writable, TrivialRegisterPassable):
    """Need more data to complete parsing."""

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write("IncompleteError: Need more data")

    def __str__(self) -> String:
        return String(self)


@fieldwise_init
struct HTTPParseError(Movable, Writable):
    """Error variant for HTTP parsing operations."""

    comptime type = Variant[ParseError, IncompleteError]
    var value: Self.type

    @implicit
    def __init__(out self, value: ParseError):
        self.value = value

    @implicit
    def __init__(out self, value: IncompleteError):
        self.value = value

    def write_to[W: Writer, //](self, mut writer: W):
        if self.value.isa[ParseError]():
            writer.write(self.value[ParseError])
        elif self.value.isa[IncompleteError]():
            writer.write(self.value[IncompleteError])

    def isa[T: AnyType](self) -> Bool:
        return self.value.isa[T]()

    def __getitem__[T: AnyType](self) -> ref [origin_of(self.value)._get_owned_interior["value"]] T:
        return self.value[T]

    def __str__(self) -> String:
        return String(self)


def try_peek[origin: ImmOrigin](reader: ByteReader[origin]) -> Optional[UInt8]:
    """Try to peek at current byte, returns None if unavailable."""
    if reader.available():
        try:
            return reader.peek()
        except:
            return None
    return None


def try_peek_at[origin: ImmOrigin](reader: ByteReader[origin], offset: Int) -> Optional[UInt8]:
    """Try to peek at byte at relative offset, returns None if out of bounds."""
    var abs_pos = reader.read_pos + offset
    if abs_pos < len(reader._inner):
        return reader._inner[abs_pos]
    return None


def try_get_byte[origin: ImmOrigin](mut reader: ByteReader[origin]) -> Optional[UInt8]:
    """Try to get current byte and advance, returns None if unavailable."""
    if reader.available():
        var byte = reader._inner[reader.read_pos]
        reader.increment()
        return byte
    return None


def create_string_from_reader[origin: ImmOrigin](reader: ByteReader[origin], start_offset: Int, length: Int) -> String:
    """Create a string from a range in the reader."""
    if start_offset >= 0 and start_offset + length <= len(reader._inner):
        var ptr = reader._inner.unsafe_ptr().unsafe_offset(start_offset)
        return create_string_from_ptr(ptr, length)
    return String()


def scan_to_eol[
    origin: ImmOrigin
](mut buf: ByteReader[origin], mut start: Int, mut length: Int) raises HTTPParseError:
    """Advance past one field value to its line end, reported as an offset pair.

    `start` and `length` index `buf`'s underlying span; nothing is copied.
    `get_token_to_eol` is this plus a `String`, for the two callers that
    need one (the response status message); `parse_headers` uses this
    directly, because a header's value only ever becomes bytes in the
    `Headers` blob — the `String` it used to build was a copy made to be
    copied again, and at twelve headers per request that copying was a
    third of the whole user-space request (`scripts/bench_http_parts.mojo`).
    """
    var token_start = buf.read_pos

    # RFC 9110 §5.5: the value runs to the first control character (< 0x20
    # except HTAB) or DEL; SP, visible ASCII and obs-text (0x80–0xFF) are
    # content. The whole remaining buffer is searched here, so "no such
    # byte" means the line has not finished arriving.
    var remaining = len(buf._inner) - buf.read_pos
    var found = _find_field_end(buf._inner.unsafe_ptr().unsafe_offset(buf.read_pos), remaining)
    if found < 0:
        raise IncompleteError()
    buf.read_pos += found

    var current_byte = buf._inner[buf.read_pos]
    if current_byte == BytesConstant.CR:
        buf.increment()
        var next_byte = try_peek(buf)
        # A CR as the buffer's last byte is a line whose LF has not arrived,
        # not a bad line: the TCP segment ended between the two. Reporting
        # it invalid answered 400 to a request the next read would have
        # completed. Found by the release fuzz (seed 5, iteration 147067)
        # and latent in every release before 0.18.0.
        if not next_byte:
            raise IncompleteError()
        if next_byte.value() != BytesConstant.LF:
            raise ParseError()
        length = buf.read_pos - 1 - token_start
        buf.increment()
    elif current_byte == BytesConstant.LF:
        length = buf.read_pos - token_start
        buf.increment()
    else:
        raise ParseError()
    start = token_start


def get_token_to_eol[
    origin: ImmOrigin
](mut buf: ByteReader[origin], mut token: String, mut token_len: Int) raises HTTPParseError:
    var start = 0
    scan_to_eol(buf, start, token_len)
    token = create_string_from_reader(buf, start, token_len)


def is_complete[origin: ImmOrigin](mut buf: ByteReader[origin], last_len: Int) raises HTTPParseError:
    var ret_cnt = 0
    var start_offset = 0 if last_len < 3 else last_len - 3

    var scan_buf = ByteReader(buf._inner)
    scan_buf.read_pos = start_offset

    while scan_buf.available():
        var byte = try_get_byte(scan_buf)
        if not byte:
            raise IncompleteError()

        if byte.value() == BytesConstant.CR:
            var next = try_peek(scan_buf)
            if not next:
                raise IncompleteError()
            if next.value() != BytesConstant.LF:
                raise ParseError()
            scan_buf.increment()
            ret_cnt += 1
        elif byte.value() == BytesConstant.LF:
            ret_cnt += 1
        else:
            ret_cnt = 0

        if ret_cnt == 2:
            return

    raise IncompleteError()


def scan_token[
    origin: ImmOrigin
](mut buf: ByteReader[origin], next_char: UInt8, mut start: Int, mut length: Int) raises HTTPParseError:
    """Advance past one token up to `next_char`, reported as an offset pair.

    The offset-only core of `parse_token`; see `scan_to_eol` for why.
    """
    var buf_start = buf.read_pos

    # Find the delimiter — or a control byte, which can only mean the line
    # ended without one — then confirm every byte before it is a tchar.
    # The outcomes are exactly the byte-at-a-time loop's: the delimiter
    # after a run of token characters succeeds, any other byte before it
    # is a ParseError, and a buffer that holds neither is incomplete
    # unless it already holds a byte no token could contain.
    var remaining = len(buf._inner) - buf.read_pos
    var found = _find_stop(buf._inner.unsafe_ptr().unsafe_offset(buf.read_pos), remaining, next_char)
    if found >= 0:
        if buf._inner[buf.read_pos + found] != next_char:
            raise ParseError()
        for j in range(found):
            if not is_token_char(buf._inner[buf.read_pos + j]):
                raise ParseError()
        buf.read_pos += found
        start = buf_start
        length = found
        return

    for j in range(remaining):
        if not is_token_char(buf._inner[buf.read_pos + j]):
            raise ParseError()
    raise IncompleteError()


def parse_token[
    origin: ImmOrigin
](mut buf: ByteReader[origin], mut token: String, mut token_len: Int, next_char: UInt8,) raises HTTPParseError:
    var start = 0
    scan_token(buf, next_char, start, token_len)
    token = create_string_from_reader(buf, start, token_len)


@always_inline
def _expect_byte[origin: ImmOrigin](mut buf: ByteReader[origin], want: UInt8) raises HTTPParseError:
    var byte = try_get_byte(buf)
    if not byte or byte.value() != want:
        raise ParseError()


def parse_http_version[origin: ImmOrigin](mut buf: ByteReader[origin], mut minor_version: Int) raises HTTPParseError:
    if buf.remaining() < 9:
        raise IncompleteError()

    # "HTTP/1." as seven constant compares. This used to build a
    # List[UInt8] of the literal on every request to loop over it.
    _expect_byte(buf, BytesConstant.H)
    _expect_byte(buf, BytesConstant.T)
    _expect_byte(buf, BytesConstant.T)
    _expect_byte(buf, BytesConstant.P)
    _expect_byte(buf, BytesConstant.SLASH)
    _expect_byte(buf, BytesConstant.ONE)
    _expect_byte(buf, BytesConstant.DOT)

    var version_byte = try_peek(buf)
    if not version_byte:
        raise IncompleteError()

    if version_byte.value() < BytesConstant.ZERO or version_byte.value() > BytesConstant.NINE:
        raise ParseError()

    minor_version = Int(version_byte.value() - BytesConstant.ZERO)
    buf.increment()


def parse_headers[
    buf_origin: ImmOrigin, header_origin: MutOrigin
](
    mut buf: ByteReader[buf_origin],
    headers: Span[HTTPHeader, header_origin],
    mut num_headers: Int,
    max_headers: Int,
) raises HTTPParseError:
    while buf.available():
        var byte = try_peek(buf)
        if not byte:
            raise IncompleteError()

        if byte.value() == BytesConstant.CR:
            buf.increment()
            var next = try_peek(buf)
            if not next:
                raise IncompleteError()
            if next.value() != BytesConstant.LF:
                raise ParseError()
            buf.increment()
            return
        elif byte.value() == BytesConstant.LF:
            buf.increment()
            return

        if num_headers >= max_headers:
            raise ParseError()

        if num_headers == 0 or (byte.value() != BytesConstant.whitespace and byte.value() != BytesConstant.TAB):
            var name_start = 0
            var name_len = 0
            scan_token(buf, BytesConstant.COLON, name_start, name_len)
            if name_len == 0:
                raise ParseError()

            headers[num_headers].name_start = name_start
            headers[num_headers].name_len = name_len
            buf.increment()

            while buf.available():
                var ws = try_peek(buf)
                if not ws:
                    break
                if ws.value() != BytesConstant.whitespace and ws.value() != BytesConstant.TAB:
                    break
                buf.increment()
        else:
            # obs-fold continuation: no name, the value joins the previous
            # field's. An empty span, exactly what the empty String was.
            headers[num_headers].name_start = 0
            headers[num_headers].name_len = 0

        var value_start = 0
        var value_len = 0
        scan_to_eol(buf, value_start, value_len)

        # Trailing OWS comes off the LENGTH. This used to re-slice the value
        # into a third String when any was present.
        while value_len > 0:
            var c = buf._inner[value_start + value_len - 1]
            if c != BytesConstant.whitespace and c != BytesConstant.TAB:
                break
            value_len -= 1

        headers[num_headers].value_start = value_start
        headers[num_headers].value_len = value_len
        num_headers += 1

    raise IncompleteError()


def http_parse_request_headers[
    buf_origin: ImmOrigin, header_origin: MutOrigin
](
    buf_start: Pointer[UInt8, buf_origin],
    len: Int,
    mut method: String,
    mut path: String,
    mut minor_version: Int,
    headers: Span[HTTPHeader, header_origin],
    mut num_headers: Int,
    last_len: Int,
) -> Int:
    """Parse HTTP request headers. Returns bytes consumed or negative error code."""
    var max_headers = num_headers

    method = String()
    var method_len = 0
    path = String()
    minor_version = -1
    num_headers = 0

    var buf_span = Span[UInt8, buf_origin](unsafe_ptr=buf_start, length=len)
    var buf = ByteReader(buf_span)

    try:
        if last_len != 0:
            is_complete(buf, last_len)

        while buf.available():
            var byte = try_peek(buf)
            if not byte:
                return -2

            if byte.value() == BytesConstant.CR:
                buf.increment()
                var next = try_peek(buf)
                if not next:
                    return -2
                if next.value() != BytesConstant.LF:
                    break
                buf.increment()
            elif byte.value() == BytesConstant.LF:
                buf.increment()
            else:
                break

        parse_token(buf, method, method_len, BytesConstant.whitespace)
        buf.increment()

        while buf.available():
            var byte = try_peek(buf)
            if not byte or byte.value() != BytesConstant.whitespace:
                break
            buf.increment()

        var path_start = buf.read_pos

        # The request target runs to the SP before the version. A control
        # byte or DEL inside it is a ParseError; obs-text (>= 0x80) is let
        # through, as the byte-at-a-time loop this replaces let it through.
        # `len` is this function's byte-count parameter, hence `__len__`.
        var path_remaining = buf._inner.__len__() - buf.read_pos
        var path_found = _find_stop(
            buf._inner.unsafe_ptr().unsafe_offset(buf.read_pos),
            path_remaining,
            BytesConstant.whitespace,
        )
        if path_found < 0:
            return -2
        if buf._inner[buf.read_pos + path_found] != BytesConstant.whitespace:
            return -1
        buf.read_pos += path_found

        var path_len = buf.read_pos - path_start
        path = create_string_from_reader(buf, path_start, path_len)

        while buf.available():
            var byte = try_peek(buf)
            if not byte or byte.value() != BytesConstant.whitespace:
                break
            buf.increment()

        if not buf.available():
            return -2

        if method_len == 0 or path_len == 0:
            return -1

        parse_http_version(buf, minor_version)

        if not buf.available():
            return -2

        var byte = try_peek(buf)
        if not byte:
            return -2

        if byte.value() == BytesConstant.CR:
            buf.increment()
            var next = try_peek(buf)
            if not next:
                return -2
            if next.value() != BytesConstant.LF:
                return -1
            buf.increment()
        elif byte.value() == BytesConstant.LF:
            buf.increment()
        else:
            return -1

        parse_headers(buf, headers, num_headers, max_headers)

        return buf.read_pos
    except e:
        if e.isa[IncompleteError]():
            return -2
        else:
            return -1


def http_parse_response_headers[
    buf_origin: ImmOrigin, header_origin: MutOrigin
](
    buf_start: Pointer[UInt8, buf_origin],
    len: Int,
    mut minor_version: Int,
    mut status: Int,
    mut msg: String,
    headers: Span[HTTPHeader, header_origin],
    mut num_headers: Int,
    last_len: Int,
) -> Int:
    """Parse HTTP response headers. Returns bytes consumed or negative error code."""
    var max_headers = num_headers

    minor_version = -1
    status = 0
    msg = String()
    var msg_len = 0
    num_headers = 0

    var buf_span = Span[UInt8, buf_origin](unsafe_ptr=buf_start, length=len)
    var buf = ByteReader(buf_span)

    try:
        if last_len != 0:
            is_complete(buf, last_len)

        parse_http_version(buf, minor_version)

        var byte = try_peek(buf)
        if not byte or byte.value() != BytesConstant.whitespace:
            return -1

        while buf.available():
            byte = try_peek(buf)
            if not byte or byte.value() != BytesConstant.whitespace:
                break
            buf.increment()

        if buf.remaining() < 4:
            return -2

        status = 0
        for _ in range(3):
            byte = try_get_byte(buf)
            if not byte:
                return -2
            if byte.value() < BytesConstant.ZERO or byte.value() > BytesConstant.NINE:
                return -1
            status = status * 10 + Int(byte.value() - BytesConstant.ZERO)

        get_token_to_eol(buf, msg, msg_len)

        if msg_len > 0 and msg[byte=0:1] == " ":
            var i = 0
            while i < msg_len and msg[byte=i : i + 1] == " ":
                i += 1
            # Materialize into a temp first — constructing directly into `msg`
            # while the slice still borrows it now trips the aliasing check.
            var trimmed = String(msg[byte=i:])
            msg = trimmed^
            msg_len -= i
        elif msg_len > 0 and msg[byte=0:1] != String(" "):
            return -1

        parse_headers(buf, headers, num_headers, max_headers)

        return buf.read_pos
    except e:
        if e.isa[IncompleteError]():
            return -2
        else:
            return -1


def http_parse_headers[
    buf_origin: ImmOrigin, header_origin: MutOrigin
](
    buf_start: Pointer[UInt8, buf_origin],
    len: Int,
    headers: Span[HTTPHeader, header_origin],
    mut num_headers: Int,
    last_len: Int,
) -> Int:
    """Parse only headers (for standalone header parsing). Returns bytes consumed or negative error code."""
    var max_headers = num_headers
    num_headers = 0

    var buf_span = Span[UInt8, buf_origin](unsafe_ptr=buf_start, length=len)
    var buf = ByteReader(buf_span)

    try:
        if last_len != 0:
            is_complete(buf, last_len)

        parse_headers(buf, headers, num_headers, max_headers)

        return buf.read_pos
    except e:
        if e.isa[IncompleteError]():
            return -2
        else:
            return -1
