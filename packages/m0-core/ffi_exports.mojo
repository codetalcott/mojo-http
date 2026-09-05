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

The calling convention is the `abi("C")` *effect* on each function, which
sits after the argument list and BEFORE the return arrow, beside where
`raises` would go — not a decorator, not an `@export` argument, and not
anything after the return type (every one of those was tried first and
each is a parse error or "use of unknown declaration 'abi'", which is how
`ABI="C"` on `@export` survived here for a while, deprecated). With the
effect in place a bare `@export("name")` is warning-free on Mojo 1.0.0
(ed45d567), the symbol is emitted with C linkage, and `smoke-ffi` calls it
through `ctypes`. `abi("C")` cannot be combined with `raises`.
"""

from std.atomic import Atomic

from src.hashing import _fnv1a_ptr, _xxhash32_ptr


@export("m0_fnv1a")
def m0_fnv1a(
    data: Pointer[UInt8, MutAnyOrigin], length: UInt32
) abi("C") -> UInt32:
    """Compute FNV-1a 32-bit hash over a byte buffer."""
    return _fnv1a_ptr(data, Int(length))


@export("m0_xxhash32")
def m0_xxhash32(
    data: Pointer[UInt8, MutAnyOrigin], length: UInt32, seed: UInt32
) abi("C") -> UInt32:
    """Compute xxHash32 over a byte buffer."""
    return _xxhash32_ptr(data, Int(length), seed)


@export("m0_format_hash")
def m0_format_hash(
    hash: UInt32, out_buf: Pointer[UInt8, MutAnyOrigin], buf_len: UInt32
) abi("C") -> UInt32:
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
        out_buf[unsafe_offset=i] = hex.as_bytes()[nibble]

    return 8


@export("m0_shared_fetch_add")
def m0_shared_fetch_add(addr: UInt64, delta: Int64) abi("C") -> Int64:
    """Atomically add `delta` to the Int64 at `addr`; returns the PREVIOUS value.

    The one export that is not a pure function: it exists so a foreign
    caller can take a number from a counter another *process* is also
    taking from. `m0-http`'s `SharedAtomics` mmaps a `MAP_SHARED` page
    before forking, and `SharedAtomics.addr(i)` names a slot on it; every
    worker — and any interpreter embedded in one — addresses the same
    physical word, so a fetch-add here is globally ordered across the whole
    worker set.

    That is what lets `apps/django_realtime`'s `m0pub.py` number the events
    it publishes: Python has no atomic fetch-and-add over a raw address,
    `ctypes` cannot express one, and a non-atomic read-modify-write would
    hand two workers the same id under any concurrency at all.

    Deliberately a byte-level mirror of `m0_http.multiworker.shared_fetch_add`
    rather than a call to it — m0-core depends on nothing, and importing
    m0-http here would invert the dependency direction the whole repo is
    arranged around. What keeps the two honest is that both are the only
    thing they can be: `Atomic[DType.int64].fetch_add` on the address.

    `addr` is 0-checked and answered with 0, so an unwired caller — one whose
    server never exported a slot — degrades to "no numbering" instead of
    dereferencing null. Any other address is trusted: it must come from
    `SharedAtomics.addr`, and a bad one is a segfault exactly as it would be
    in C.
    """
    if addr == UInt64(0):
        return Int64(0)
    var slot = Pointer[Atomic[DType.int64], MutUntrackedOrigin](
        unsafe_from_address=Int(addr)
    )
    return slot[].fetch_add(delta)
