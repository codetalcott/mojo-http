"""ETag computation and matching.

Thin wrapper over m0-core's wyhash64 hashing. Produces weak ETags
(W/"hex") suitable for conditional responses (304 Not Modified).
"""

from m0_core.hashing import wyhash64, format_hash64


def compute_etag(buf: List[UInt8]) -> String:
    """Compute a weak ETag from a byte buffer using wyhash64.

    Returns: W/"<16-char-hex>"
    """
    var hash = wyhash64(Span(ptr=buf.unsafe_ptr(), length=len(buf)))
    return String('W/"') + format_hash64(hash) + String('"')


def _trim(s: String) -> String:
    """Strip leading and trailing ASCII whitespace."""
    var bytes = s.as_bytes()
    var start = 0
    var end = s.byte_length()
    while start < end and (bytes[start] == 0x20 or bytes[start] == 0x09):
        start += 1
    while end > start and (bytes[end - 1] == 0x20 or bytes[end - 1] == 0x09):
        end -= 1
    if start == 0 and end == s.byte_length():
        return s
    return String(s[byte=start:end])


def etag_matches(etag: String, if_none_match: String) -> Bool:
    """Check if an ETag matches an If-None-Match header value.

    Handles comma-separated lists and * wildcard.
    Performs exact token matching (not substring search).
    """
    if if_none_match.byte_length() == 0:
        return False
    if if_none_match == "*":
        return True
    var parts = if_none_match.split(",")
    for i in range(len(parts)):
        if _trim(String(parts[i])) == etag:
            return True
    return False
