"""Tests for the C-ABI export surface.

`ffi_exports.mojo` at the package root exists so a foreign caller can load
`m0_shared_fetch_add` from a shared object; `poe build-ffi` emits it, and
`m0serve`'s `m0pub` calls it through `ctypes` to number the events it
publishes.

The module lives outside `src/` because it is the `--emit shared-lib` entry
point, and code outside `src/` once rotted here unnoticed (nothing compiled
it, and `@export`'s rejection of parametric functions went undetected).
These tests importing the module directly are what prevents a repeat: every
`test-core` run compiles it. `poe smoke-ffi` covers the other half — that
the emitted shared object actually loads and answers through `ctypes`.
"""

from std.testing import assert_equal, TestSuite

from ffi_exports import m0_shared_fetch_add


# --- m0_shared_fetch_add ------------------------------------------------------
#
# The address form is the whole point: `m0-http`'s SharedAtomics hands out
# raw addresses into an mmap'd MAP_SHARED page so processes that cannot pass
# each other pointers can still share a counter. A `List[Int64]` here is that
# same shape locally — an 8-byte-aligned Int64 named by its address — which
# is all the export can see, so it exercises the identical code path.


def _cell(value: Int) -> List[Int64]:
    """One 8-byte-aligned Int64, addressable — a SharedAtomics slot's shape."""
    var c = List[Int64](unsafe_uninit_length=1)
    c[0] = Int64(value)
    return c^


def test_shared_fetch_add_returns_the_previous_value() raises:
    var cell = _cell(0)
    var addr = UInt64(Int(cell.unsafe_ptr()))
    assert_equal(Int(m0_shared_fetch_add(addr, Int64(1))), 0)
    assert_equal(Int(m0_shared_fetch_add(addr, Int64(1))), 1)
    assert_equal(Int(m0_shared_fetch_add(addr, Int64(1))), 2)
    assert_equal(Int(cell[0]), 3)


def test_shared_fetch_add_writes_through_to_the_word() raises:
    """The caller's memory is the state; nothing is cached in the library."""
    var cell = _cell(41)
    var addr = UInt64(Int(cell.unsafe_ptr()))
    assert_equal(Int(m0_shared_fetch_add(addr, Int64(1))), 41)
    assert_equal(Int(cell[0]), 42)


def test_shared_fetch_add_accepts_a_negative_delta() raises:
    var cell = _cell(10)
    var addr = UInt64(Int(cell.unsafe_ptr()))
    assert_equal(Int(m0_shared_fetch_add(addr, Int64(-4))), 10)
    assert_equal(Int(cell[0]), 6)


def test_shared_fetch_add_answers_a_null_address_with_zero() raises:
    """An unwired caller degrades to `no numbering`, not a segfault."""
    assert_equal(Int(m0_shared_fetch_add(UInt64(0), Int64(1))), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
