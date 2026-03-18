"""
C-ABI Exports for M0 Core

Exposes pure hash functions via @export with C calling convention
for consumption by Bun's dlopen() or Node.js N-API.

All functions operate on raw byte pointers and lengths, matching
the UTF-8 encoded strings that Bun/Node pass across the FFI boundary.

Hash algorithms delegate to shared _fnv1a_ptr / _xxhash32_ptr internals
in hashing.mojo — single source of truth for both APIs.
"""

from std.memory import UnsafePointer

from ..hashing import _fnv1a_ptr, _xxhash32_ptr


@export("m0_fnv1a", ABI="C")
fn m0_fnv1a(data: UnsafePointer[UInt8, _], length: UInt32) -> UInt32:
    """Compute FNV-1a 32-bit hash over a byte buffer."""
    return _fnv1a_ptr(data, Int(length))


@export("m0_xxhash32", ABI="C")
fn m0_xxhash32(data: UnsafePointer[UInt8, _], length: UInt32, seed: UInt32) -> UInt32:
    """Compute xxHash32 over a byte buffer."""
    return _xxhash32_ptr(data, Int(length), seed)


@export("m0_format_hash", ABI="C")
fn m0_format_hash(hash: UInt32, out_buf: UnsafePointer[UInt8, _], buf_len: UInt32) -> UInt32:
    """Format a 32-bit hash as 8-character hex string into a caller-provided buffer.

    Returns number of bytes written (8 on success, 0 if buffer too small).
    """
    if buf_len < UInt32(8):
        return 0

    comptime hex = "0123456789abcdef"
    var val = hash

    for i in range(8):
        var shift = (7 - i) * 4
        var nibble = Int((val >> shift) & 0xF)
        out_buf[i] = hex.as_bytes()[nibble]

    return 8
