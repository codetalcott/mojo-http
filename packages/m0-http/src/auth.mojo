"""API key authentication with constant-time comparison.

Provides check_api_key() which compares a provided key against an
expected key without early exit, preventing timing side-channels.
"""

from lightbug_http.header import Headers


def check_api_key(headers: Headers, expected_key: String) -> Bool:
    """Check X-API-Key header against expected key (constant-time).

    Returns True if the key matches, False otherwise. Uses XOR
    accumulator to avoid timing side-channels from early exit.
    Returns False immediately only if no key is provided (not secret).
    """
    if expected_key.byte_length() == 0:
        return True  # auth disabled

    var key_hdr = headers.get("x-api-key")
    if not key_hdr:
        return False

    var provided = key_hdr.value()
    var expected_bytes = expected_key.as_bytes()
    var provided_bytes = provided.as_bytes()

    # Length mismatch — still do work to avoid timing leak on length
    var max_len = len(expected_bytes)
    if len(provided_bytes) > max_len:
        max_len = len(provided_bytes)

    var diff: UInt8 = 0
    # XOR accumulator: any difference sets bits in diff
    for i in range(max_len):
        var a: UInt8 = expected_bytes[i] if i < len(expected_bytes) else 0
        var b: UInt8 = provided_bytes[i] if i < len(provided_bytes) else 0
        diff |= a ^ b

    # Length mismatch also counts as failure
    if len(expected_bytes) != len(provided_bytes):
        diff |= 1

    return diff == 0
