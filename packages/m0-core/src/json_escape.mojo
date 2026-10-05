"""
JSON String Escape — SIMD-accelerated JSON string escaping.

Generic escape logic with no dependency on any serialization format.

Uses 64-byte SIMD scan for bulk safe-range detection + memcpy, then an
8-byte SWAR scan for the tail and a scalar scan for its last few bytes.

`escape_json_string` allocates and returns a String;
`escape_json_string_into` appends to a buffer the caller owns, which is
what anything assembling several escaped values into one document wants.
"""

from std.bit import count_trailing_zeros
from std.memory import unsafe_memcpy
from .hashing import _load_u64, hex_nibble


comptime _ONES: UInt64 = 0x0101010101010101
comptime _HIGHS: UInt64 = 0x8080808080808080


def _swar_escape_mask(w: UInt64) -> UInt64:
    """High bit of each byte of `w` that needs JSON escape, exact up to and
    including the lowest flagged byte.

    The has-zero / has-less-than tricks: a borrow can only flag a byte above
    one that is truly flagged, so the lowest set bit is always right, and
    that is the only bit the caller reads.
    """
    var q = w ^ (_ONES * 0x22)
    var b = w ^ (_ONES * 0x5C)
    var is_quote = (q - _ONES) & ~q
    var is_bslash = (b - _ONES) & ~b
    var is_ctrl = (w - _ONES * 0x20) & ~w
    return (is_quote | is_bslash | is_ctrl) & _HIGHS


def simd_find_escape_char(ptr: Pointer[UInt8, _], length: Int) -> Int:
    """Find first byte needing JSON escape using 64-byte SIMD.

    Detects: " (0x22), \\ (0x5C), or any control char < 0x20.
    Returns offset or -1 if not found in complete 64-byte chunks.
    """
    var quote_vec = SIMD[DType.uint8, 64](0x22)
    var bslash_vec = SIMD[DType.uint8, 64](0x5C)
    var mask_e0 = SIMD[DType.uint8, 64](0xE0)
    var i = 0
    while i + 64 <= length:
        var chunk = ptr.unsafe_offset(i).unsafe_load[width=64]()
        var has_quote = (chunk ^ quote_vec).reduce_min() == 0
        var has_bslash = (chunk ^ bslash_vec).reduce_min() == 0
        var has_ctrl = (chunk & mask_e0).reduce_min() == 0
        if has_quote or has_bslash or has_ctrl:
            for lane in range(64):
                var b = chunk[lane]
                if b == 0x22 or b == 0x5C or b < 0x20:
                    return i + lane
        i += 64
    return -1


def escape_json_string(s: String) -> String:
    """Escape a string for JSON output, wrapping in double quotes.

    Uses SIMD scan for bulk safe-range detection + memcpy.
    """
    var out = List[UInt8](capacity=s.byte_length() + 18)
    escape_json_string_into(out, s)
    # `Span(out)` keeps `out` alive through the copy; see `escape_html`.
    return String(unsafe_from_utf8=Span(out))


def escape_json_string_into(mut out: List[UInt8], s: String):
    """Append the escaped, quoted form of `s` to `out`.

    The same routine `escape_json_string` runs — it is the wrapper — but
    writing into a buffer the caller already owns. A caller assembling
    several escaped values into one document would otherwise allocate a
    String per value and then copy each one into the result; `format_json`
    in m0-http did exactly that, twelve times per access-log line.
    """
    var bytes = s.as_bytes()
    var slen = s.byte_length()
    out.append(UInt8(ord('"')))

    var pos = 0
    var ptr = bytes.unsafe_ptr()

    while pos < slen:
        var remaining = slen - pos
        var found = -1

        if remaining >= 64:
            found = simd_find_escape_char(ptr.unsafe_offset(pos), remaining)

        if found == -1 and remaining % 64 != 0:
            var j = slen - remaining % 64
            while j + 8 <= slen:
                var m = _swar_escape_mask(_load_u64(ptr, j))
                if m != 0:
                    found = j + Int(count_trailing_zeros(m) >> 3) - pos
                    break
                j += 8
            if found == -1:
                for k in range(j, slen):
                    var b = bytes[k]
                    if b == 0x22 or b == 0x5C or b < 0x20:
                        found = k - pos
                        break

        if found == -1:
            var count = slen - pos
            var old_len = len(out)
            out.resize(old_len + count, 0)
            unsafe_memcpy(
                dest=out.unsafe_ptr().unsafe_offset(old_len),
                src=ptr.unsafe_offset(pos),
                count=count,
            )
            pos = slen
        else:
            if found > 0:
                var old_len = len(out)
                out.resize(old_len + found, 0)
                unsafe_memcpy(
                    dest=out.unsafe_ptr().unsafe_offset(old_len),
                    src=ptr.unsafe_offset(pos),
                    count=found,
                )
            pos += found
            var c = bytes[pos]
            if c == 0x22:
                out.append(UInt8(ord('\\')))
                out.append(0x22)
            elif c == 0x5C:
                out.append(UInt8(ord('\\')))
                out.append(0x5C)
            elif c == 0x0A:
                out.append(UInt8(ord('\\')))
                out.append(UInt8(ord('n')))
            elif c == 0x0D:
                out.append(UInt8(ord('\\')))
                out.append(UInt8(ord('r')))
            elif c == 0x09:
                out.append(UInt8(ord('\\')))
                out.append(UInt8(ord('t')))
            else:
                out.append(UInt8(ord('\\')))
                out.append(UInt8(ord('u')))
                out.append(UInt8(ord('0')))
                out.append(UInt8(ord('0')))
                out.append(hex_nibble(Int(c) >> 4))
                out.append(hex_nibble(Int(c) & 0x0F))
            pos += 1

    out.append(UInt8(ord('"')))
