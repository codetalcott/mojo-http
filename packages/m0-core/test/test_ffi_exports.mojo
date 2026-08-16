"""Tests for the C-ABI export surface.

`ffi_exports.mojo` at the package root exists so Bun's `dlopen` and Node's
N-API can call the hash functions directly; `poe build-ffi` emits it as a
shared object. Its docstring claims the exports delegate to the shared
`_fnv1a_ptr` / `_xxhash32_ptr` internals — single source of truth for both
APIs; these tests are what makes that claim checkable, by asserting the
exported entry points agree with the ordinary Mojo ones on the same input.

The module lives outside `src/` because it is the `--emit shared-lib` entry
point, and code outside `src/` once rotted here unnoticed (nothing compiled
it, and `@export`'s rejection of parametric functions went undetected).
These tests importing the module directly are what prevents a repeat: every
`test-core` run compiles it. `poe smoke-ffi` covers the other half — that
the emitted shared object actually loads and answers known vectors through
`ctypes`.
"""

from std.memory import UnsafePointer
from std.testing import assert_equal, assert_true, TestSuite

from src.hashing import fnv1a, xxhash32, format_hash32
from ffi_exports import m0_fnv1a, m0_xxhash32, m0_format_hash


def _any_origin(p: Pointer[UInt8, _]) -> UnsafePointer[UInt8, MutAnyOrigin]:
    """Erase a pointer's origin, the way a foreign caller's address arrives.

    `@export` cannot be applied to a parametric function, so these entry points
    name a concrete origin rather than inferring one — which is exactly right
    for their real callers, who hand over a bare address, and means Mojo-side
    callers have to say so explicitly.
    """
    return UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=Int(p))


def test_exported_fnv1a_matches_the_mojo_function() raises:
    var s = String("hello world")
    var bytes = s.as_bytes()
    assert_equal(
        m0_fnv1a(_any_origin(bytes.unsafe_ptr()), UInt32(len(bytes))), fnv1a(s)
    )


def test_exported_xxhash32_matches_the_mojo_function() raises:
    var s = String("hello world")
    var bytes = s.as_bytes()
    assert_equal(
        m0_xxhash32(
            _any_origin(bytes.unsafe_ptr()), UInt32(len(bytes)), UInt32(0)
        ),
        xxhash32(s, 0),
    )


def test_exported_xxhash32_respects_the_seed() raises:
    var s = String("hello world")
    var bytes = s.as_bytes()
    var p = _any_origin(bytes.unsafe_ptr())
    var a = m0_xxhash32(p, UInt32(len(bytes)), UInt32(0))
    var b = m0_xxhash32(p, UInt32(len(bytes)), UInt32(7))
    assert_true(a != b, "seed had no effect")
    assert_equal(b, xxhash32(s, 7))


def test_exported_hash_of_empty_input() raises:
    var s = String("")
    var bytes = s.as_bytes()
    assert_equal(m0_fnv1a(_any_origin(bytes.unsafe_ptr()), UInt32(0)), fnv1a(s))


def test_exported_format_hash_writes_eight_hex_bytes() raises:
    var out = List[UInt8](unsafe_uninit_length=8)
    var written = m0_format_hash(
        UInt32(0xDEADBEEF), _any_origin(out.unsafe_ptr()), UInt32(8)
    )
    assert_equal(Int(written), 8)
    var got = String(unsafe_from_utf8=out)
    assert_equal(got, "deadbeef")
    assert_equal(got, format_hash32(UInt32(0xDEADBEEF)))


def test_exported_format_hash_refuses_a_short_buffer() raises:
    """The caller owns the buffer, so a short one must be reported, not filled."""
    var out = List[UInt8](unsafe_uninit_length=8)
    assert_equal(
        Int(
            m0_format_hash(
                UInt32(1), _any_origin(out.unsafe_ptr()), UInt32(7)
            )
        ),
        0,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
