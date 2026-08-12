"""
Hash Algorithms — FNV-1a, xxHash32, wyhash64, and hex formatting.

Consolidated from modfixi/mojo (FNV-1a, xxHash32) and mojo-siren-grail (wyhash64).

- FNV-1a 32-bit: Element ID generation from DOM paths.
- xxHash32: Fast effect deduplication in runtime queues.
- wyhash64: Vectorized 64-bit hash for ETag computation.

Internal _*_ptr functions operate on raw byte pointers and are shared
by both the String-based API and C-ABI FFI exports.
"""

from std.bit import rotate_bits_left
from std.memory import Pointer


# ============================================================================
# Hex Formatting (shared by all hash algorithms)
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
    var out = List[UInt8](capacity=nibbles + 1)
    for i in range(nibbles):
        var shift = UInt64((nibbles - 1 - i) * 4)
        out.append(hex_nibble(Int((val >> shift) & 0xF)))
    out.append(0)
    return String(unsafe_from_utf8=Span(unsafe_ptr=out.unsafe_ptr(), length=nibbles))


def format_hash32(hash: UInt32) -> String:
    """Format a 32-bit hash as an 8-character zero-padded hex string."""
    return _format_hex(UInt64(hash), 8)


def format_hash64(val: UInt64) -> String:
    """Format a 64-bit hash as a 16-character zero-padded hex string."""
    return _format_hex(val, 16)


# ============================================================================
# FNV-1a 32-bit Hash
# ============================================================================

comptime FNV_OFFSET_BASIS: UInt32 = 2166136261
comptime FNV_PRIME: UInt32 = 16777619


def fnv1a_step(hash: UInt32, char_code: UInt32) -> UInt32:
    """Perform a single FNV-1a hash step for one character code."""
    var h = hash ^ char_code
    h = h + (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24)
    return h


def _fnv1a_ptr(data: Pointer[UInt8, _], length: Int) -> UInt32:
    """Compute FNV-1a 32-bit hash over a raw byte buffer.

    Shared implementation used by both the String API and C-ABI exports.
    """
    var hash = FNV_OFFSET_BASIS
    for i in range(length):
        hash = fnv1a_step(hash, UInt32(data[i]))
    return hash


def fnv1a(s: String) -> UInt32:
    """Compute FNV-1a 32-bit hash for a string.

    Non-cryptographic hash with excellent distribution. Used for generating
    stable element IDs from DOM paths.
    """
    var bytes = s.as_bytes()
    return _fnv1a_ptr(bytes.unsafe_ptr(), len(bytes))


# ============================================================================
# xxHash32
# ============================================================================

comptime PRIME32_1: UInt32 = 0x9E3779B1
comptime PRIME32_2: UInt32 = 0x85EBCA77
comptime PRIME32_3: UInt32 = 0xC2B2AE3D
comptime PRIME32_4: UInt32 = 0x27D4EB2F
comptime PRIME32_5: UInt32 = 0x165667B1


def _read_u32_le(data: Pointer[UInt8, _], offset: Int) -> UInt32:
    """Read a little-endian UInt32 from a byte pointer via bitcast.

    All target platforms (osx-arm64) are little-endian,
    so a direct bitcast load produces the correct value.
    """
    return data.unsafe_offset(offset).unsafe_bitcast[UInt32]()[]


def _xxhash32_round(acc: UInt32, input: UInt32) -> UInt32:
    """Perform a single xxHash32 accumulation round."""
    var a = acc + input * PRIME32_2
    a = rotate_bits_left[shift=13](a)
    return a * PRIME32_1


def _xxhash32_ptr(data: Pointer[UInt8, _], length: Int, seed: UInt32) -> UInt32:
    """Compute xxHash32 over a raw byte buffer.

    Shared implementation used by both the String API and C-ABI exports.
    """
    var h32: UInt32
    var i: Int = 0

    if length >= 16:
        var v1 = seed + PRIME32_1 + PRIME32_2
        var v2 = seed + PRIME32_2
        var v3 = seed
        var v4 = seed - PRIME32_1

        var limit = length - 16
        while i <= limit:
            v1 = _xxhash32_round(v1, _read_u32_le(data, i))
            v2 = _xxhash32_round(v2, _read_u32_le(data, i + 4))
            v3 = _xxhash32_round(v3, _read_u32_le(data, i + 8))
            v4 = _xxhash32_round(v4, _read_u32_le(data, i + 12))
            i += 16

        h32 = (
            rotate_bits_left[shift=1](v1)
            + rotate_bits_left[shift=7](v2)
            + rotate_bits_left[shift=12](v3)
            + rotate_bits_left[shift=18](v4)
        )
    else:
        h32 = seed + PRIME32_5

    h32 = h32 + UInt32(length)

    while i <= length - 4:
        var k = _read_u32_le(data, i)
        h32 = rotate_bits_left[shift=17](h32 + k * PRIME32_3) * PRIME32_4
        i += 4

    while i < length:
        h32 = rotate_bits_left[shift=11](h32 + UInt32(data[i]) * PRIME32_5) * PRIME32_1
        i += 1

    h32 ^= h32 >> 15
    h32 = h32 * PRIME32_2
    h32 ^= h32 >> 13
    h32 = h32 * PRIME32_3
    h32 ^= h32 >> 16

    return h32


def xxhash32(input: String, seed: UInt32 = 0) -> UInt32:
    """Compute xxHash32 for a string input.

    Faster than JSON-based hashing with fewer collisions. Used for effect
    deduplication in runtime queues.
    """
    var input_bytes = input.as_bytes()
    return _xxhash32_ptr(input_bytes.unsafe_ptr(), len(input_bytes), seed)


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


# ============================================================================
# SIMD Batch Hashing
# ============================================================================


def fnv1a_batch(strings: List[String]) -> List[UInt32]:
    """Compute FNV-1a for multiple strings using SIMD parallelism.

    Processes 4 strings simultaneously using SIMD lanes. Each lane
    independently computes FNV-1a up to its string's length, with
    the min-length prefix processed in lockstep SIMD and remaining
    bytes handled per-lane.
    """
    var count = len(strings)
    var results = List[UInt32]()

    var i = 0
    while i + 4 <= count:
        var s0 = strings[i].as_bytes()
        var s1 = strings[i + 1].as_bytes()
        var s2 = strings[i + 2].as_bytes()
        var s3 = strings[i + 3].as_bytes()
        var len0 = len(s0)
        var len1 = len(s1)
        var len2 = len(s2)
        var len3 = len(s3)

        var min_len = len0
        if len1 < min_len: min_len = len1
        if len2 < min_len: min_len = len2
        if len3 < min_len: min_len = len3

        var hash = SIMD[DType.uint32, 4](FNV_OFFSET_BASIS)
        for j in range(min_len):
            var bytes_vec = SIMD[DType.uint32, 4](
                UInt32(Int(s0[j])), UInt32(Int(s1[j])),
                UInt32(Int(s2[j])), UInt32(Int(s3[j]))
            )
            var xored = hash ^ bytes_vec
            hash = xored + (xored << 1) + (xored << 4) + (xored << 7) + (xored << 8) + (xored << 24)

        var h0 = hash[0]
        var h1 = hash[1]
        var h2 = hash[2]
        var h3 = hash[3]
        for j in range(min_len, len0):
            h0 = fnv1a_step(h0, UInt32(Int(s0[j])))
        for j in range(min_len, len1):
            h1 = fnv1a_step(h1, UInt32(Int(s1[j])))
        for j in range(min_len, len2):
            h2 = fnv1a_step(h2, UInt32(Int(s2[j])))
        for j in range(min_len, len3):
            h3 = fnv1a_step(h3, UInt32(Int(s3[j])))

        results.append(h0)
        results.append(h1)
        results.append(h2)
        results.append(h3)
        i += 4

    while i < count:
        results.append(fnv1a(strings[i]))
        i += 1

    return results^


def xxhash32_batch(strings: List[String], seed: UInt32 = 0) -> List[UInt32]:
    """Compute xxHash32 for multiple strings.

    Uses scalar xxhash32 per string. The primary win comes from batching
    calls and reducing interpreter overhead.
    """
    var results = List[UInt32]()
    for i in range(len(strings)):
        results.append(xxhash32(strings[i], seed))
    return results^
