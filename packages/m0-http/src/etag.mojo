"""ETag computation and matching.

Thin wrapper over m0-core's wyhash64 hashing. Produces weak ETags
(W/"hex") suitable for conditional responses (304 Not Modified).
"""

from lightbug_http.strings import next_list_member, trim_ows
from m0_core.hashing import wyhash64, format_hash64


def compute_etag(buf: List[UInt8]) -> String:
    """Compute a weak ETag from a byte buffer using wyhash64.

    Returns: W/"<16-char-hex>"
    """
    var hash = wyhash64(Span(buf))
    return String('W/"') + format_hash64(hash) + String('"')


def _opaque_bounds(bytes: Span[UInt8, _], a: Int, b: Int) -> Tuple[Int, Int]:
    """The `[a, b)` of a tag already trimmed of its blanks, without a leading
    `W/`. Bytes only: a client's value may hold any byte (SPEC G14)."""
    if b - a >= 2 and bytes[a] == 0x57 and bytes[a + 1] == 0x2F:
        return (a + 2, b)
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
    var trimmed = trim_ows(want_bytes, 0, len(want_bytes))
    var want = _opaque_bounds(want_bytes, trimmed[0], trimmed[1])
    var want_len = want[1] - want[0]
    var n = len(inm)
    var seg = 0
    while seg <= n:
        var member = next_list_member(inm, seg)
        var part = _opaque_bounds(inm, member[0], member[1])
        var part_len = part[1] - part[0]
        # `*` alone, the whole value: the first member and the last.
        if part_len == 1 and inm[part[0]] == 0x2A and seg == 0 and member[2] == n + 1:
            return True
        if part_len > 0 and part_len == want_len:
            var same = True
            for k in range(part_len):
                if inm[part[0] + k] != want_bytes[want[0] + k]:
                    same = False
                    break
            if same:
                return True
        seg = member[2]
    return False
