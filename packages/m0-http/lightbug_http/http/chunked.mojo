import std.sys as sys
from std.sys import size_of

from lightbug_http.io.bytes import Bytes
from lightbug_http.strings import BytesConstant
from std.memory import memcpy


# Chunked decoder states
@fieldwise_init
struct DecoderState(Equatable, ImplicitlyCopyable):
    var value: UInt8
    comptime IN_CHUNK_SIZE = Self(0)
    comptime IN_CHUNK_EXT = Self(1)
    comptime IN_CHUNK_HEADER_EXPECT_LF = Self(2)
    comptime IN_CHUNK_DATA = Self(3)
    comptime IN_CHUNK_DATA_EXPECT_CR = Self(4)
    comptime IN_CHUNK_DATA_EXPECT_LF = Self(5)
    comptime IN_TRAILERS_LINE_HEAD = Self(6)
    comptime IN_TRAILERS_LINE_MIDDLE = Self(7)

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value


struct HTTPChunkedDecoder(Defaultable):
    var bytes_left_in_chunk: Int
    var consume_trailer: Bool
    var _hex_count: Int
    var _sig_hex_count: Int  # significant (non-leading-zero) hex digits seen
    var _state: DecoderState
    var _total_read: Int
    var _total_overhead: Int
    var pending_bytes: Int
    """Undecoded bytes the last `decode` left at the front of its buffer.

    `decode` already compacts them there — decoded output first, then the
    partial chunk header (or half-read size line) it could not finish — but
    it only *returns* the decoded length, so a caller resuming across
    several reads had no way to know where the next batch should be
    appended. That is why this decoder was reconstructed per read event,
    which made a chunked body cost O(N²): every event re-copied and
    re-scanned the whole body accumulated so far, and it also reset
    `_total_overhead`, disabling the abuse ratio below.

    Feeding one decoder only the NEW bytes is what this makes possible.
    Meaningless after an error return, and equal to `ret` on a completed
    body (both are "bytes after the chunked data").
    """

    def __init__(out self):
        self.bytes_left_in_chunk = 0
        self.consume_trailer = False
        self._hex_count = 0
        self._sig_hex_count = 0
        self._state = DecoderState.IN_CHUNK_SIZE
        self._total_read = 0
        self._total_overhead = 0
        self.pending_bytes = 0

    def decode[origin: MutOrigin](mut self, buf: Span[Byte, origin]) -> Tuple[Int, Int]:
        """Decode chunked transfer encoding.

        Parameters:
            origin: Origin of the buffer, must be mutable.

        Args:
            buf: The buffer containing chunked data.

        Returns:
            The number of bytes left after chunked data, -1 for error, -2 for incomplete
            The new buffer size (decoded data length).
        """
        var dst = 0
        var src = 0
        var ret = -2  # incomplete
        var buffer_len = len(buf)

        # NB: the totals are accumulated at the BOTTOM, from `src`/`dst`, not
        # here from `buffer_len`. See the abuse-ratio block.

        while True:
            if self._state == DecoderState.IN_CHUNK_SIZE:
                while src < buffer_len:
                    ref byte = buf[src]
                    var v = decode_hex(byte)
                    if v == -1:
                        if self._hex_count == 0:
                            return (-1, dst)

                        # Check for valid characters after chunk size
                        if (
                            byte != BytesConstant.whitespace
                            and byte != BytesConstant.TAB
                            and byte != BytesConstant.SEMICOLON
                            and byte != BytesConstant.LF
                            and byte != BytesConstant.CR
                        ):
                            return (-1, dst)
                        break

                    # Enforce 16-digit limit only on *significant* digits
                    # (those from the first non-zero hex digit onward).
                    # Leading zeros are legal per RFC 7230 §4.1 and must not
                    # be counted toward the limit (Apache truncation CVE).
                    if self._sig_hex_count == 16:
                        return (-1, dst)

                    if self.bytes_left_in_chunk > (Int.MAX >> 4):
                        return (-1, dst)  # Chunk size would overflow
                    self.bytes_left_in_chunk = self.bytes_left_in_chunk * 16 + v
                    self._hex_count += 1
                    # bytes_left_in_chunk > 0 iff at least one non-zero digit
                    # has been accumulated, meaning this digit is significant.
                    if self.bytes_left_in_chunk > 0:
                        self._sig_hex_count += 1
                    src += 1

                if src >= buffer_len:
                    break

                self._hex_count = 0
                self._sig_hex_count = 0
                self._state = DecoderState.IN_CHUNK_EXT

            elif self._state == DecoderState.IN_CHUNK_EXT:
                while src < buffer_len:
                    if buf[src] == BytesConstant.CR:
                        break
                    elif buf[src] == BytesConstant.LF:
                        return (-1, dst)
                    src += 1

                if src >= buffer_len:
                    break

                src += 1
                self._state = DecoderState.IN_CHUNK_HEADER_EXPECT_LF

            elif self._state == DecoderState.IN_CHUNK_HEADER_EXPECT_LF:
                if src >= buffer_len:
                    break

                if buf[src] != BytesConstant.LF:
                    return (-1, dst)

                src += 1

                if self.bytes_left_in_chunk == 0:
                    if self.consume_trailer:
                        self._state = DecoderState.IN_TRAILERS_LINE_HEAD
                        continue
                    else:
                        ret = buffer_len - src
                        break

                self._state = DecoderState.IN_CHUNK_DATA

            elif self._state == DecoderState.IN_CHUNK_DATA:
                var avail = buffer_len - src
                if avail < self.bytes_left_in_chunk:
                    if dst != src:
                        var _bp = buf.unsafe_ptr()
                        for _k in range(avail):
                            _bp[unsafe_offset = dst + _k] = _bp[unsafe_offset = src + _k]
                    src += avail
                    dst += avail
                    self.bytes_left_in_chunk -= avail
                    break

                if dst != src:
                    var _bp = buf.unsafe_ptr()
                    for _k in range(self.bytes_left_in_chunk):
                        _bp[unsafe_offset = dst + _k] = _bp[unsafe_offset = src + _k]

                src += self.bytes_left_in_chunk
                dst += self.bytes_left_in_chunk
                self.bytes_left_in_chunk = 0
                self._state = DecoderState.IN_CHUNK_DATA_EXPECT_CR

            elif self._state == DecoderState.IN_CHUNK_DATA_EXPECT_CR:
                if src >= len(buf):
                    break

                if buf[src] != BytesConstant.CR:
                    return (-1, dst)

                src += 1
                self._state = DecoderState.IN_CHUNK_DATA_EXPECT_LF

            elif self._state == DecoderState.IN_CHUNK_DATA_EXPECT_LF:
                if src >= buffer_len:
                    break

                if buf[src] != BytesConstant.LF:
                    return (-1, dst)

                src += 1
                self._state = DecoderState.IN_CHUNK_SIZE

            elif self._state == DecoderState.IN_TRAILERS_LINE_HEAD:
                while src < buffer_len:
                    if buf[src] != BytesConstant.CR:
                        break
                    src += 1

                if src >= buffer_len:
                    break

                if buf[src] == BytesConstant.LF:
                    src += 1
                    ret = buffer_len - src
                    break

                self._state = DecoderState.IN_TRAILERS_LINE_MIDDLE

            elif self._state == DecoderState.IN_TRAILERS_LINE_MIDDLE:
                while src < buffer_len:
                    if buf[src] == BytesConstant.LF:
                        break
                    src += 1

                if src >= buffer_len:
                    break

                src += 1
                self._state = DecoderState.IN_TRAILERS_LINE_HEAD

        # Move remaining data to beginning of buffer
        if dst != src and src < buffer_len:
            var _bp = buf.unsafe_ptr()
            var _rem = buffer_len - src
            for _k in range(_rem):
                _bp[unsafe_offset = dst + _k] = _bp[unsafe_offset = src + _k]

        var new_bufsz = dst
        # Where the next batch of raw bytes belongs: right after the
        # leftover the block above just moved to buf[dst:]. See the field's
        # docstring for why this is recorded rather than recomputed.
        self.pending_bytes = buffer_len - src

        # Check for excessive overhead: a body that is mostly chunk framing
        # and hardly any data.
        #
        # Measured against what this call actually CONSUMED (`src`) and
        # produced (`dst`), so the framing cost is `src - dst`.
        #
        # It was `buffer_len - dst`, which charged the whole
        # not-yet-decodable tail as overhead. That was harmless while a
        # throwaway decoder saw the entire body in one call, and is wrong
        # now that one decoder is fed per read: the unconsumed tail is
        # re-offered on the next call, so those bytes were charged again
        # every time, and `_total_read` double-counted them alongside. No
        # request is known to have been refused because of it — the ratio
        # needs 100 KB of charged overhead before it can fire, and the
        # 400s seen while building this were the `bytes_read` desync in
        # `event_loop.mojo`, not this. It is corrected because the numbers
        # should mean what they say; `test_a_body_that_is_mostly_framing_
        # still_trips_the_abuse_guard` pins that the guard still fires on
        # what it was written for.
        if ret == -2:
            self._total_read += src
            self._total_overhead += src - dst
            if self._total_overhead >= 100 * 1024 and self._total_read - self._total_overhead < self._total_read // 4:
                ret = -1
        else:
            self._total_read += src
            self._total_overhead += src - dst

        return (ret, new_bufsz)

    def is_in_chunk_data(self) -> Bool:
        """Check if decoder is currently in chunk data state."""
        return self._state == DecoderState.IN_CHUNK_DATA


def decode_hex(ch: Byte) -> Int:
    """Decode hexadecimal character."""
    if ch >= BytesConstant.ZERO and ch <= BytesConstant.NINE:
        return Int(ch - BytesConstant.ZERO)
    elif ch >= BytesConstant.A_UPPER and ch <= BytesConstant.F_UPPER:
        return Int(ch - BytesConstant.A_UPPER + 10)
    elif ch >= BytesConstant.A_LOWER and ch <= BytesConstant.F_LOWER:
        return Int(ch - BytesConstant.A_LOWER + 10)
    else:
        return -1


# --- Encoder ---------------------------------------------------------------
#
# The decoder above is the client's; this is the server's. They are the two
# halves of RFC 9112 §7.1 and live together so the framing rules have one
# home: `chunk-size` in lowercase hex with no extensions, CRLF, the data,
# CRLF, and a zero-size chunk plus a bare CRLF to end (no trailers, which is
# what lets a reader stop at `0\r\n\r\n`).


comptime _HEX_DIGITS = "0123456789abcdef"


def append_chunk_size(mut out: Bytes, size: Int):
    """Append `size` as lowercase hex with no leading zeros, then CRLF.

    Split out because the terminator needs the same digits: a chunk header
    and the final `0` differ only in the value, and writing the `0` by hand
    somewhere else is how the two drift.
    """
    if size == 0:
        out.append(BytesConstant.ZERO)
    else:
        # Emit most-significant digit first: find the top nibble, then walk
        # down. No buffer, no reverse.
        var shift = 0
        var probe = size
        while probe >= 16:
            probe = probe >> 4
            shift += 4
        while shift >= 0:
            var nibble = (size >> shift) & 0xF
            out.append(_HEX_DIGITS.as_bytes()[nibble])
            shift -= 4
    out.append(BytesConstant.CR)
    out.append(BytesConstant.LF)


def encode_chunk(payload: Span[Byte, _]) -> Bytes:
    """Frame `payload` as one chunk: `size CRLF payload CRLF`.

    A zero-length payload is NOT encodable as a chunk — a zero-size chunk is
    the end-of-stream marker, so emitting one mid-stream would truncate the
    body. Callers must skip empty drains; the loop does.
    """
    var out = Bytes()
    var n = len(payload)
    append_chunk_size(out, n)
    out.extend(payload)
    out.append(BytesConstant.CR)
    out.append(BytesConstant.LF)
    return out^


def chunked_terminator() -> Bytes:
    """The end of a chunked body: `0 CRLF CRLF`.

    No trailer section. After these bytes the message is complete and the
    connection may carry another request — which is the whole point of
    framing a stream rather than closing it.
    """
    var out = Bytes()
    append_chunk_size(out, 0)
    out.append(BytesConstant.CR)
    out.append(BytesConstant.LF)
    return out^
