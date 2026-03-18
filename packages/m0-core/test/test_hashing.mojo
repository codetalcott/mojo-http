"""Tests for FNV-1a, xxHash32, wyhash64, and hex formatting."""

from std.testing import assert_equal, assert_not_equal, assert_true

from src.hashing import (
    fnv1a, fnv1a_step, format_hash, format_hash32, format_hash64,
    xxhash32, format_xxhash, wyhash64, wyhash64_string,
)


fn test_fnv1a_empty_string() raises:
    """FNV-1a of empty string should return the offset basis."""
    var result = fnv1a("")
    assert_equal(result, UInt32(2166136261))


fn test_fnv1a_hello() raises:
    """FNV-1a should produce consistent results for known inputs."""
    var hash1 = fnv1a("hello")
    var hash2 = fnv1a("hello")
    assert_equal(hash1, hash2)


fn test_fnv1a_different_inputs() raises:
    """Different inputs should produce different hashes."""
    var hash1 = fnv1a("hello")
    var hash2 = fnv1a("world")
    assert_not_equal(hash1, hash2)


fn test_fnv1a_dom_path() raises:
    """FNV-1a should handle DOM-path-like strings (the real use case)."""
    var path1 = "BUTTON:0/DIV:2/BODY:0/HTML:0/"
    var path2 = "BUTTON:1/DIV:2/BODY:0/HTML:0/"
    var hash1 = fnv1a(path1)
    var hash2 = fnv1a(path2)
    assert_not_equal(hash1, hash2)


fn test_format_hash_zero() raises:
    """Zero hash should format as 8 zeros."""
    assert_equal(format_hash(UInt32(0)), "00000000")


fn test_format_hash_max() raises:
    """Max UInt32 should format as 8 f's."""
    assert_equal(format_hash(UInt32(0xFFFFFFFF)), "ffffffff")


fn test_format_hash_length() raises:
    """Formatted hash should always be 8 characters."""
    var formatted = format_hash(fnv1a("test"))
    assert_equal(len(formatted), 8)


fn test_xxhash32_empty() raises:
    """xxHash32 of empty string with seed 0."""
    var result = xxhash32("")
    assert_true(result > 0)


fn test_xxhash32_consistency() raises:
    """xxHash32 should produce consistent results."""
    var hash1 = xxhash32("test input")
    var hash2 = xxhash32("test input")
    assert_equal(hash1, hash2)


fn test_xxhash32_different_inputs() raises:
    """Different inputs should produce different xxHash32 values."""
    var hash1 = xxhash32("hello")
    var hash2 = xxhash32("world")
    assert_not_equal(hash1, hash2)


fn test_xxhash32_seed() raises:
    """Different seeds should produce different hashes for same input."""
    var hash1 = xxhash32("hello", seed=0)
    var hash2 = xxhash32("hello", seed=42)
    assert_not_equal(hash1, hash2)


fn test_xxhash32_long_string() raises:
    """xxHash32 should handle strings >= 16 chars (activates block processing)."""
    var long_input = "this is a longer string that exceeds sixteen characters"
    var hash = xxhash32(long_input)
    assert_true(hash > 0)
    assert_equal(hash, xxhash32(long_input))


fn test_xxhash32_effect_like() raises:
    """xxHash32 on effect-like canonical strings (the real use case)."""
    var effect1 = "o:{key:s:user-1,store:s:memory,type:s:storage.get}"
    var effect2 = "o:{key:s:user-2,store:s:memory,type:s:storage.get}"
    var hash1 = xxhash32(effect1)
    var hash2 = xxhash32(effect2)
    assert_not_equal(hash1, hash2)


fn test_format_xxhash() raises:
    """format_xxhash should produce 8-char hex strings."""
    var hash = xxhash32("test")
    var formatted = format_xxhash(hash)
    assert_equal(len(formatted), 8)


fn test_format_hash64() raises:
    """format_hash64 should produce 16-char hex strings."""
    var formatted = format_hash64(UInt64(0))
    assert_equal(len(formatted), 16)
    assert_equal(formatted, "0000000000000000")

    var formatted_max = format_hash64(UInt64(0xFFFFFFFFFFFFFFFF))
    assert_equal(len(formatted_max), 16)
    assert_equal(formatted_max, "ffffffffffffffff")


fn test_wyhash64_consistency() raises:
    """wyhash64 should produce consistent results."""
    var hash1 = wyhash64_string("hello world")
    var hash2 = wyhash64_string("hello world")
    assert_equal(hash1, hash2)


fn test_wyhash64_different_inputs() raises:
    """Different inputs should produce different wyhash64 values."""
    var hash1 = wyhash64_string("hello")
    var hash2 = wyhash64_string("world")
    assert_not_equal(hash1, hash2)


fn test_wyhash64_long_string() raises:
    """wyhash64 should handle strings >= 32 chars (activates block processing)."""
    var long_input = "this is a longer string that exceeds thirty-two characters easily"
    var hash = wyhash64_string(long_input)
    assert_true(hash > 0)
    assert_equal(hash, wyhash64_string(long_input))
