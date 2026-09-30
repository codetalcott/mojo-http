"""C-ABI exports for m0-core — the shared-library entry point.

Exposes `m0_shared_fetch_add` via `@export` with the C calling convention,
for a foreign caller that can load a shared object — `m0serve`'s `m0pub`
loads it through Python's `ctypes`, which is the one caller there is.
`poe build-ffi` emits it:

    uv run poe build-ffi        # packages/m0-core/libm0core.{so,dylib}

Until 2026-09-29 it also exported FNV-1a, xxHash32 and a 32-bit hex
formatter, offered to Bun's `dlopen` and Node's N-API; nothing in the tree
called them, and they left with the hashes
(docs/notes/what-the-m0-wheel-promises.md).

**Why this file lives at the package root, outside `src/`.** `mojo build
--emit shared-lib` compiles one top-level entry file, and a top-level entry
cannot use relative imports — `from ..hashing import` dies with "cannot
import relative to a top-level package". Inside `src/` the file could only be
part of the precompiled package, from which `@export` symbols cannot be
emitted into a shared object; a wrapper entry file re-exporting them is
rejected ("invalid re-export"), and a bare import doesn't force symbol
emission. So the C surface is defined *here*, and `mojo precompile src`
never sees it. The historical risk of
code outside `src/` — nothing compiles it, so it drifts — is covered by
`test_ffi_exports.mojo` importing this module directly and by `build-ffi`
running in CI.

`@export` cannot be applied to a parametric function, so an entry point
names concrete types rather than inferring them — which is exactly right for
its real callers, who hand over a bare address. `m0_shared_fetch_add` takes
that address as a `UInt64`, so a Mojo-side caller converts its pointer to
an integer first; the test shows how.

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


@export("m0_shared_fetch_add")
def m0_shared_fetch_add(addr: UInt64, delta: Int64) abi("C") -> Int64:
    """Atomically add `delta` to the Int64 at `addr`; returns the PREVIOUS value.

    It exists so a foreign caller can take a number from a counter another
    *process* is also taking from. `m0-http`'s `SharedAtomics` mmaps a `MAP_SHARED` page
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
    thing they can be: `Atomic[Int64].fetch_add` on the address.

    `addr` is 0-checked and answered with 0, so an unwired caller — one whose
    server never exported a slot — degrades to "no numbering" instead of
    dereferencing null. Any other address is trusted: it must come from
    `SharedAtomics.addr`, and a bad one is a segfault exactly as it would be
    in C.
    """
    if addr == UInt64(0):
        return Int64(0)
    var slot = Pointer[Atomic[Int64], MutUntrackedOrigin](
        unsafe_from_address=Int(addr)
    )
    return slot[].fetch_add(delta)
