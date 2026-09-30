"""Tests for wyhash64 and hex formatting."""

from std.testing import assert_equal, assert_not_equal, assert_true, TestSuite

from src.hashing import format_hash64, wyhash64_string


def test_format_hash64() raises:
    """`format_hash64` should produce 16-char hex strings."""
    var formatted = format_hash64(UInt64(0))
    assert_equal(formatted.byte_length(), 16)
    assert_equal(formatted, "0000000000000000")

    var formatted_max = format_hash64(UInt64(0xFFFFFFFFFFFFFFFF))
    assert_equal(formatted_max.byte_length(), 16)
    assert_equal(formatted_max, "ffffffffffffffff")


def test_wyhash64_consistency() raises:
    """`wyhash64` should produce consistent results."""
    var hash1 = wyhash64_string("hello world")
    var hash2 = wyhash64_string("hello world")
    assert_equal(hash1, hash2)


def test_wyhash64_different_inputs() raises:
    """Different inputs should produce different wyhash64 values."""
    var hash1 = wyhash64_string("hello")
    var hash2 = wyhash64_string("world")
    assert_not_equal(hash1, hash2)


def test_wyhash64_long_string() raises:
    """`wyhash64` should handle strings >= 32 chars (activates block processing)."""
    var long_input = "this is a longer string that exceeds thirty-two characters easily"
    var hash = wyhash64_string(long_input)
    assert_true(hash > 0)
    assert_equal(hash, wyhash64_string(long_input))


# --- Pinned wyhash64 outputs ---
# These vectors are not standard wyhash test vectors; they capture the M0
# `_wymix`-based fold so future changes to the mix function are caught.
# If any of these need to be updated, every served ETag changes on deploy.

def test_wyhash64_pinned_empty() raises:
    """Pinned: wyhash64_string('') — change here means ETag churn for clients."""
    assert_equal(wyhash64_string(""), UInt64(0x83F76D8D51E39EF9))


def test_wyhash64_pinned_a() raises:
    """Pinned: wyhash64_string('a') — short-tail path."""
    assert_equal(wyhash64_string("a"), UInt64(0x3CF845EB0C3F00C0))


def test_wyhash64_pinned_64byte() raises:
    """Pinned: wyhash64 on a 64-byte input crossing the 32-byte block boundary."""
    var s = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    assert_equal(wyhash64_string(s), UInt64(0xA83D130D54B64584))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
