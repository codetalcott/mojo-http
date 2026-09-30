"""
Hashing — wyhash64 and hex formatting.

wyhash64 is a non-cryptographic 64-bit hash, used for ETag computation; it
is not suitable for security decisions (`sha256` and `hmac` are the
cryptographic primitives). The hex formatters print a 64-bit hash
(`format_hash64`) and a digest of any length (`hex_digest`).
"""

from std.memory import Pointer


# ============================================================================
# Hex Formatting
# ============================================================================

def hex_nibble(val: Int) -> UInt8:
    """Convert a nibble (0-15) to its ASCII hex character."""
    if val < 10:
        return UInt8(ord('0') + val)
    return UInt8(ord('a') + val - 10)


def _format_hex(val: UInt64, nibbles: Int) -> String:
    """Format the low `nibbles` nibbles of `val` as a lowercase hex string.

    Builds the byte buffer via hex_nibble() rather than indexing into a
    comptime string lookup. The previous `_HEX_CHARS.as_bytes().unsafe_ptr()`
    pattern crashed Mojo nightly's Linux x86_64 JIT runtime — the temporary
    Span returned by .as_bytes() is dropped immediately, and on Linux the
    pointer extracted from it does not survive (macOS arm64 happens to
    tolerate it). Avoiding the unsafe-pointer-from-comptime-string pattern
    entirely is the robust fix.
    """
    var out = List[UInt8](capacity=nibbles)
    for i in range(nibbles):
        var shift = UInt64((nibbles - 1 - i) * 4)
        out.append(hex_nibble(Int((val >> shift) & 0xF)))
    # `Span(out)`, not `Span(unsafe_ptr=...)`: the pointer form carries no
    # origin, so `out` is destroyed after its last use -- the pointer
    # extraction -- and the String copies from freed memory.
    return String(unsafe_from_utf8=Span(out))


def format_hash64(val: UInt64) -> String:
    """Format a 64-bit hash as a 16-character zero-padded hex string."""
    return _format_hex(val, 16)


def hex_digest(digest: Span[UInt8, _]) -> String:
    """Formats any byte string as lowercase hex, two characters per byte.

    What a SHA-256 or HMAC digest is printed as; `format_hash64` is the same
    formatting for the 64-bit hashes.

    Args:
        digest: The bytes to format.

    Returns:
        The hex string, `2 * len(digest)` characters.
    """
    var out = List[UInt8](capacity=len(digest) * 2)
    for b in digest:
        out.append(hex_nibble(Int(b) >> 4))
        out.append(hex_nibble(Int(b) & 0xF))
    return String(StringSpan(unsafe_from_utf8=Span(out)))


# ============================================================================
# wyhash64 — Vectorized 64-bit hash for ETag computation
# ============================================================================

comptime _SECRET0: UInt64 = 0xA0761D6478BD642F
comptime _SECRET1: UInt64 = 0xE7037ED1A0B428DB
comptime _SECRET2: UInt64 = 0x8EBC6AF09C88C6E3
comptime _SECRET3: UInt64 = 0x589965CC75374CC3


def _wymix(a: UInt64, b: UInt64) -> UInt64:
    """wyhash-style mixing: fold the high and low 64 bits of the 128-bit product `a * b`.

    Mojo does not currently expose UInt128, so this assembles the 128-bit
    product schoolbook-style from four 32x32 -> 64 partial products.
    """
    var a_lo: UInt64 = a & 0xFFFFFFFF
    var a_hi: UInt64 = a >> 32
    var b_lo: UInt64 = b & 0xFFFFFFFF
    var b_hi: UInt64 = b >> 32

    var ll = a_lo * b_lo
    var lh = a_lo * b_hi
    var hl = a_hi * b_lo
    var hh = a_hi * b_hi

    # mid = lh + hl, propagating carry into the high half
    var mid_lo = (lh & 0xFFFFFFFF) + (hl & 0xFFFFFFFF) + (ll >> 32)
    var mid_hi = (lh >> 32) + (hl >> 32) + (mid_lo >> 32)

    var lo = (ll & 0xFFFFFFFF) | (mid_lo << 32)
    var hi = hh + mid_hi
    return lo ^ hi


def _load_u64(ptr: Pointer[UInt8, _], offset: Int) -> UInt64:
    """Load an unaligned little-endian UInt64 at `offset` bytes past `ptr`.

    Uses the ungated `unsafe_*` pointer spellings: as of nightly
    26.5.0.dev2026072806 `Span.unsafe_ptr()` returns a safe `Pointer`, and the
    `+`, `bitcast`, and `load` operators are gated on `not _safe`. The
    `unsafe_offset` / `unsafe_bitcast` / `unsafe_load` twins are ungated and
    preserve the pointer's origin (unlike casting to `UnsafeAnyOrigin`).

    alignment=1: the buffer is byte-aligned, so request unaligned loads.
    """
    return ptr.unsafe_offset(offset).unsafe_bitcast[UInt64]().unsafe_load[
        alignment=1
    ]()


def wyhash64(buf: Span[UInt8, _]) -> UInt64:
    """Compute wyhash64 over a byte buffer.

    Fast non-cryptographic 64-bit hash. Processes 32 bytes per iteration
    via 4x UInt64 word loads with wyhash-style mixing.

    Uses secret constants as second args to _wymix to prevent
    zero-annihilation (since _wymix(anything, 0) == 0).

    Targets little-endian, unaligned-load-tolerant architectures
    (osx-arm64, linux x86_64).
    """
    var ptr = buf.unsafe_ptr()
    var length = len(buf)

    var h: UInt64 = 0x2D358DCCAA6C78A5 ^ UInt64(length)
    var i = 0

    # Process 32 bytes at a time (4x UInt64 words).
    # alignment=1: the buffer is byte-aligned (e.g. String.as_bytes() into
    # small-string storage), so request unaligned loads. x86_64 tolerates them
    # at the hardware level, but the Linux Mojo nightly traps aligned loads on
    # misaligned addresses via alignment sanitization.
    while i + 32 <= length:
        var a = _load_u64(ptr, i)
        var b = _load_u64(ptr, i + 8)
        var c = _load_u64(ptr, i + 16)
        var d = _load_u64(ptr, i + 24)
        h = _wymix(h ^ a, b ^ _SECRET0) ^ _wymix(c ^ _SECRET1, d ^ _SECRET2)
        i += 32

    # Process remaining 8-byte words
    while i + 8 <= length:
        var word = _load_u64(ptr, i)
        h = _wymix(h ^ word, _SECRET3)
        i += 8

    # Scalar tail (< 8 bytes)
    if i < length:
        var tail: UInt64 = 0
        for j in range(length - i):
            tail |= UInt64(buf[i + j]) << UInt64(j * 8)
        h = _wymix(h ^ tail, _SECRET3)

    # Final avalanche
    h ^= h >> 32
    h *= 0xBF58476D1CE4E5B9
    h ^= h >> 31

    return h


def wyhash64_string(s: String) -> UInt64:
    """Compute wyhash64 for a string."""
    return wyhash64(s.as_bytes())

