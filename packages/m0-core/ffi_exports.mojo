"""C-ABI exports for m0-core — the shared-library entry point.

Exposes the pure hash functions via `@export` with C calling convention for
foreign callers: Bun's `dlopen`, Node's N-API, Python's `ctypes`, anything
that can load a shared object. `poe build-ffi` emits it:

    uv run poe build-ffi        # packages/m0-core/libm0core.{so,dylib}

All functions operate on raw byte pointers and lengths, matching the UTF-8
byte buffers foreign runtimes pass across an FFI boundary. They delegate to
the `_fnv1a_ptr` / `_xxhash32_ptr` internals in `src/hashing.mojo` — a single
source of truth for the exported and the Mojo-native APIs, which
`test_ffi_exports.mojo` pins by asserting the two agree.

**Why this file lives at the package root, outside `src/`.** `mojo build
--emit shared-lib` compiles one top-level entry file, and a top-level entry
cannot use relative imports — `from ..hashing import` dies with "cannot
import relative to a top-level package". Inside `src/` the file could only be
part of the precompiled package, from which `@export` symbols cannot be
emitted into a shared object; a wrapper entry file re-exporting them is
rejected ("invalid re-export"), and a bare import doesn't force symbol
emission. So the C surface is defined *here*, importing the internals
absolutely, and `mojo precompile src` never sees it. The historical risk of
code outside `src/` — nothing compiles it, so it drifts — is covered by
`test_ffi_exports.mojo` importing this module directly and by `build-ffi`
running in CI.

`@export` cannot be applied to a parametric function, so these entry points
name a concrete pointer origin (`MutAnyOrigin`) rather than inferring one —
which is exactly right for their real callers, who hand over a bare address.
Mojo-side callers must erase the origin explicitly; the test shows how.
"""

from src.hashing import _fnv1a_ptr, _xxhash32_ptr


@export("m0_fnv1a", ABI="C")
def m0_fnv1a(data: Pointer[UInt8, MutAnyOrigin], length: UInt32) -> UInt32:
    """Compute FNV-1a 32-bit hash over a byte buffer."""
    return _fnv1a_ptr(data, Int(length))


@export("m0_xxhash32", ABI="C")
def m0_xxhash32(
    data: Pointer[UInt8, MutAnyOrigin], length: UInt32, seed: UInt32
) -> UInt32:
    """Compute xxHash32 over a byte buffer."""
    return _xxhash32_ptr(data, Int(length), seed)


@export("m0_format_hash", ABI="C")
def m0_format_hash(
    hash: UInt32, out_buf: Pointer[UInt8, MutAnyOrigin], buf_len: UInt32
) -> UInt32:
    """Format a 32-bit hash as 8 hex chars into a caller-provided buffer.

    Returns the number of bytes written: 8 on success, 0 if the buffer is
    too small. No NUL terminator is written; the caller owns framing.
    """
    if buf_len < UInt32(8):
        return 0

    comptime hex = "0123456789abcdef"
    var val = hash

    for i in range(8):
        var shift = UInt32((7 - i) * 4)
        var nibble = Int((val >> shift) & 0xF)
        out_buf[i] = hex.as_bytes()[nibble]

    return 8
