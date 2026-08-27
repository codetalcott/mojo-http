"""API key authentication with constant-time comparison.

Provides check_api_key() which compares a provided key against an
expected key without early exit, preventing timing side-channels.
"""

from lightbug_http.header import Headers


comptime _COMPARE_ROUNDS = 64
"""Rounds the key comparison always runs, whatever the two lengths are.

Comfortably over any sane API key, and fixed so the loop's cost carries no
information about the expected key's length. 64 XORs is nothing next to
the request that carried the header.
"""


def check_api_key(headers: Headers, expected_key: String) -> Bool:
    """Check X-API-Key header against expected key (constant-time).

    Returns True if the key matches, False otherwise. Uses an XOR
    accumulator over a FIXED number of rounds, so neither the key's bytes
    nor its length is inferable from how long the comparison took. Returns
    False immediately only when no key was provided at all, which is not a
    secret.
    """
    if expected_key.byte_length() == 0:
        return True  # auth disabled

    var key_hdr = headers.get("x-api-key")
    if not key_hdr:
        return False

    var provided = key_hdr.value()
    var expected_bytes = expected_key.as_bytes()
    var provided_bytes = provided.as_bytes()

    # The trip count depends on the EXPECTED key alone, never on what the
    # caller sent — so it is the same for every request this deployment
    # ever serves, and a caller cannot move it.
    #
    # It used to be `max(len(expected), len(provided))`, which is
    # content-independent but not length-independent: an attacker sweeping
    # the length of their own key sees a flat time until they pass the
    # expected length and a rising one after, and the knee is the secret's
    # size. Knowing the length does not yield the key, but it is free to
    # withhold and it narrows a search.
    #
    # At least the whole expected key, so every byte of it is compared —
    # a fixed 64 rounds alone would silently ignore bytes 65 onward of a
    # longer key, which is a far worse bug than the one being fixed. The
    # floor keeps short keys from advertising their length.
    var rounds = _COMPARE_ROUNDS
    if len(expected_bytes) > rounds:
        rounds = len(expected_bytes)

    # Both operands are indexed modulo their own length so the loop reads
    # real bytes throughout — comparing a secret against a fixed run of
    # zeros would make the count meaningless. The length difference is
    # folded in separately, so a rotation ("ab" against "abab") is still a
    # mismatch.
    var diff: UInt8 = 0
    for i in range(rounds):
        var a: UInt8 = expected_bytes[i % len(expected_bytes)]
        var b: UInt8 = provided_bytes[
            i % len(provided_bytes)
        ] if len(provided_bytes) > 0 else 0
        diff |= a ^ b

    # Length mismatch is itself a failure, and is what stops a rotation of
    # the same bytes from passing the comparison above.
    if len(expected_bytes) != len(provided_bytes):
        diff |= 1

    return diff == 0
