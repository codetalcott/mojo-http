"""
JSON String Escape — SIMD-accelerated JSON string escaping.

Extracted from mojo-siren-grail's json_writer.mojo. This module provides
the generic escape logic without any SirenBin dependency.

Uses 64-byte SIMD scan for bulk safe-range detection + memcpy, falling
back to scalar scan for the tail.
"""

from std.memory import unsafe_memcpy
from .hashing import hex_nibble


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
    var bytes = s.as_bytes()
    var slen = s.byte_length()
    var out = List[UInt8](capacity=slen + 18)
    out.append(UInt8(ord('"')))

    var pos = 0
    var ptr = bytes.unsafe_ptr()

    while pos < slen:
        var remaining = slen - pos
        var found = -1

        if remaining >= 64:
            found = simd_find_escape_char(ptr.unsafe_offset(pos), remaining)

        if found == -1:
            var scan_start = pos + ((remaining // 64) * 64) if remaining >= 64 else pos
            for j in range(scan_start, slen):
                var b = bytes[j]
                if b == 0x22 or b == 0x5C or b < 0x20:
                    found = j - pos
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
    return String(unsafe_from_utf8=Span(unsafe_ptr=out.unsafe_ptr(), length=len(out)))
