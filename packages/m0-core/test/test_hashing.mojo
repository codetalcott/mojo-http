"""Tests for FNV-1a, xxHash32, wyhash64, and hex formatting."""

from std.testing import assert_equal, assert_not_equal, assert_true, TestSuite

from src.hashing import (
    fnv1a, fnv1a_step, format_hash32, format_hash64,
    xxhash32, wyhash64, wyhash64_string, _xxhash32_ptr,
)


def test_fnv1a_empty_string() raises:
    """FNV-1a of empty string should return the offset basis."""
    var result = fnv1a("")
    assert_equal(result, UInt32(2166136261))


def test_fnv1a_known_vector_a() raises:
    """Standard FNV-1a 32-bit test vector for 'a'."""
    assert_equal(fnv1a("a"), UInt32(0xE40C292C))


def test_fnv1a_known_vector_foobar() raises:
    """Standard FNV-1a 32-bit test vector for 'foobar'."""
    assert_equal(fnv1a("foobar"), UInt32(0xBF9CF968))


def test_fnv1a_hello() raises:
    """FNV-1a should produce consistent results for known inputs."""
    var hash1 = fnv1a("hello")
    var hash2 = fnv1a("hello")
    assert_equal(hash1, hash2)


def test_fnv1a_different_inputs() raises:
    """Different inputs should produce different hashes."""
    var hash1 = fnv1a("hello")
    var hash2 = fnv1a("world")
    assert_not_equal(hash1, hash2)


def test_fnv1a_dom_path() raises:
    """FNV-1a should handle DOM-path-like strings (the real use case)."""
    var path1 = "BUTTON:0/DIV:2/BODY:0/HTML:0/"
    var path2 = "BUTTON:1/DIV:2/BODY:0/HTML:0/"
    var hash1 = fnv1a(path1)
    var hash2 = fnv1a(path2)
    assert_not_equal(hash1, hash2)


def test_format_hash32_zero() raises:
    """Zero hash should format as 8 zeros."""
    assert_equal(format_hash32(UInt32(0)), "00000000")


def test_format_hash32_max() raises:
    """Max UInt32 should format as 8 f's."""
    assert_equal(format_hash32(UInt32(0xFFFFFFFF)), "ffffffff")


def test_format_hash32_length() raises:
    """Formatted hash should always be 8 characters."""
    var formatted = format_hash32(fnv1a("test"))
    assert_equal(formatted.byte_length(), 8)


def test_xxhash32_empty() raises:
    """`xxHash32` of empty string with seed 0 is a known constant."""
    assert_equal(xxhash32(""), UInt32(0x02CC5D05))


def test_xxhash32_consistency() raises:
    """`xxHash32` should produce consistent results."""
    var hash1 = xxhash32("test input")
    var hash2 = xxhash32("test input")
    assert_equal(hash1, hash2)


def test_xxhash32_different_inputs() raises:
    """Different inputs should produce different xxHash32 values."""
    var hash1 = xxhash32("hello")
    var hash2 = xxhash32("world")
    assert_not_equal(hash1, hash2)


def test_xxhash32_seed() raises:
    """Different seeds should produce different hashes for same input."""
    var hash1 = xxhash32("hello", seed=0)
    var hash2 = xxhash32("hello", seed=42)
    assert_not_equal(hash1, hash2)


def test_xxhash32_long_string() raises:
    """`xxHash32` should handle strings >= 16 chars (activates block processing)."""
    var long_input = "this is a longer string that exceeds sixteen characters"
    var hash = xxhash32(long_input)
    assert_true(hash > 0)
    assert_equal(hash, xxhash32(long_input))


def test_xxhash32_at_every_alignment() raises:
    """The same bytes hash the same from any address, and to the reference.

    `_read_u32_le` loads the input four bytes at a time from the CALLER's
    address -- a byte offset into a String, or whatever a foreign caller
    hands `m0_xxhash32` -- so 71 bytes are hashed from offsets 0 to 7 of
    one buffer, every alignment class of a 4- and an 8-byte word, through
    four 16-byte stripes, a 4-byte tail word and three tail bytes. Offset
    0 is the aligned copy; each other must match it, and all must match
    the `xxhash` library's own answer for these bytes and seeds.

    This proves the ANSWER at a misaligned address, not the load: arm64
    and x86-64 both tolerate a misaligned load, so the 4-aligned load this
    replaced passed here too. The load itself is in the IR -- `load i32,
    align 4` before, `align 1` after (review R17).
    """
    comptime N = 71
    var buf = List[UInt8](length=N + 8, fill=0)
    for seed_and_want in [(UInt32(0), UInt32(0x541DEF65)), (UInt32(7), UInt32(0xF98BCFD0))]:
        var seed = seed_and_want[0]
        var aligned = UInt32(0)
        for off in range(8):
            for j in range(N + 8):
                buf[j] = UInt8(0xAA)
            for j in range(N):
                buf[off + j] = UInt8(j)
            var got = _xxhash32_ptr(buf.unsafe_ptr().unsafe_offset(off), N, seed)
            if off == 0:
                aligned = got
            assert_equal(got, aligned)
            assert_equal(got, seed_and_want[1])


def test_xxhash32_effect_like() raises:
    """`xxHash32` on effect-like canonical strings (the real use case)."""
    var effect1 = "o:{key:s:user-1,store:s:memory,type:s:storage.get}"
    var effect2 = "o:{key:s:user-2,store:s:memory,type:s:storage.get}"
    var hash1 = xxhash32(effect1)
    var hash2 = xxhash32(effect2)
    assert_not_equal(hash1, hash2)


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
