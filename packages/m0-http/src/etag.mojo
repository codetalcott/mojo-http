"""ETag computation and matching.

Thin wrapper over m0-core's wyhash64 hashing. Produces weak ETags
(W/"hex") suitable for conditional responses (304 Not Modified).
"""

from m0_core.hashing import wyhash64, format_hash64


fn compute_etag(buf: List[UInt8]) -> String:
    """Compute a weak ETag from a byte buffer using wyhash64.

    Returns: W/"<16-char-hex>"
    """
    var hash = wyhash64(buf)
    return String('W/"') + format_hash64(hash) + String('"')


fn etag_matches(etag: String, if_none_match: String) -> Bool:
    """Check if an ETag matches an If-None-Match header value.

    Handles comma-separated lists and * wildcard.
    """
    if len(if_none_match) == 0:
        return False
    if if_none_match == "*":
        return True
    return if_none_match.find(etag) != -1
