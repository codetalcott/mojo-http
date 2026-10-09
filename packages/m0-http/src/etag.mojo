"""ETag computation and matching.

Thin wrapper over m0-core's wyhash64 hashing. Produces weak ETags
(W/"hex") suitable for conditional responses (304 Not Modified).
"""

from m0_core.hashing import wyhash64, format_hash64


def compute_etag(buf: List[UInt8]) -> String:
    """Compute a weak ETag from a byte buffer using wyhash64.

    Returns: W/"<16-char-hex>"
    """
    var hash = wyhash64(Span(buf))
    return String('W/"') + format_hash64(hash) + String('"')


def _opaque_bounds(value: String, start: Int, end: Int) -> Tuple[Int, Int]:
    """The `[start, end)` of `bytes[start:end]` without its blanks and without
    a leading `W/`. Bytes only: a client's value may hold any byte (SPEC G14)."""
    var bytes = value.as_bytes()
    var a = start
    var b = end
    while a < b and (bytes[a] == 0x20 or bytes[a] == 0x09):
        a += 1
    while b > a and (bytes[b - 1] == 0x20 or bytes[b - 1] == 0x09):
        b -= 1
    if b - a >= 2 and bytes[a] == 0x57 and bytes[a + 1] == 0x2F:
        a += 2
    return (a, b)


def etag_matches(etag: String, if_none_match: String) -> Bool:
    """Check if an ETag matches an If-None-Match header value.

    Compares WEAKLY, as RFC 9110 §13.1.2 requires for `If-None-Match`: the
    opaque tags must be equal, whichever side carries the `W/` mark. Handles
    comma-separated lists and the `*` wildcard, and matches whole tokens
    (not substrings).
    """
    var inm = if_none_match.as_bytes()
    var want_bytes = etag.as_bytes()
    var want = _opaque_bounds(etag, 0, etag.byte_length())
    var want_len = want[1] - want[0]
    var n = len(inm)
    var seg = 0
    while seg <= n:
        var stop = seg
        while stop < n and inm[stop] != 0x2C:
            stop += 1
        var part = _opaque_bounds(if_none_match, seg, stop)
        var part_len = part[1] - part[0]
        if part_len == 1 and inm[part[0]] == 0x2A and seg == 0 and stop == n:
            return True
        if part_len > 0 and part_len == want_len:
            var same = True
            for k in range(part_len):
                if inm[part[0] + k] != want_bytes[want[0] + k]:
                    same = False
                    break
            if same:
                return True
        seg = stop + 1
    return False
