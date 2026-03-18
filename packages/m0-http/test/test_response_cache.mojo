"""Tests for the response cache."""

from std.testing import assert_equal, assert_true

from src.response_cache import ResponseCache


fn _b(v: UInt8) -> List[UInt8]:
    var b = List[UInt8]()
    b.append(v)
    return b^


fn _b3() -> List[UInt8]:
    var b = List[UInt8]()
    b.append(1); b.append(2); b.append(3)
    return b^


fn test_cache_miss() raises:
    """Unknown URL should return empty."""
    var cache = ResponseCache()
    assert_equal(cache.get_etag("/missing"), "")
    assert_equal(len(cache.get_buffer("/missing")), 0)


fn test_cache_put_get() raises:
    """Put and get should round-trip."""
    var cache = ResponseCache()
    var buf = _b3()
    cache.put("/orders", buf, 'W/"abc"', '{"ok":true}')
    assert_equal(cache.get_etag("/orders"), 'W/"abc"')
    assert_equal(cache.get_json("/orders"), '{"ok":true}')
    var got = cache.get_buffer("/orders")
    assert_equal(len(got), 3)


fn test_cache_update() raises:
    """Putting same URL should update the entry."""
    var cache = ResponseCache()
    cache.put("/a", _b(1), "e1")
    var b23 = List[UInt8]()
    b23.append(2); b23.append(3)
    cache.put("/a", b23, "e2")
    assert_equal(cache.get_etag("/a"), "e2")
    assert_equal(len(cache.get_buffer("/a")), 2)
    assert_equal(cache.size(), 1)


fn test_cache_invalidate() raises:
    """Invalidate should remove the entry."""
    var cache = ResponseCache()
    cache.put("/a", _b(1), "e1")
    cache.invalidate("/a")
    assert_equal(cache.get_etag("/a"), "")
    assert_equal(cache.size(), 0)


fn test_cache_invalidate_prefix() raises:
    """Invalidate prefix should remove matching entries."""
    var cache = ResponseCache()
    cache.put("/orders/1", _b(1), "e1")
    cache.put("/orders/2", _b(2), "e2")
    cache.put("/users/1", _b(3), "e3")
    cache.invalidate_prefix("/orders")
    assert_equal(cache.size(), 1)
    assert_equal(cache.get_etag("/users/1"), "e3")


fn test_cache_lru_eviction() raises:
    """Cache should evict LRU entries when at capacity."""
    var cache = ResponseCache(max_entries=3)
    cache.put("/a", _b(1), "e1")
    cache.put("/b", _b(2), "e2")
    cache.put("/c", _b(3), "e3")
    # Access /a and /c to make /b the LRU
    _ = cache.get_etag("/a")
    _ = cache.get_etag("/c")
    # Adding /d should evict /b
    cache.put("/d", _b(4), "e4")
    assert_equal(cache.size(), 3)
    assert_equal(cache.get_etag("/b"), "")
    assert_equal(cache.get_etag("/a"), "e1")
