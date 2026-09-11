"""HMAC-SHA256 (RFC 2104 over `sha256.mojo`) and a constant-time compare.

What signs and verifies a grant: Django issues one, the Mojo side holds a
stream against it, and the two agree on a key by sharing a process tree.
`wyhash64` is not a MAC and never was (SPEC D15, the reason no session
cookie is signed yet); this is the primitive that decision waited for.

The shape is the one a hot verifier wants. `HmacSha256(key)` absorbs the
padded key into two `Sha256` states once -- `key XOR ipad` and `key XOR
opad`, a key longer than a block hashed first, as RFC 2104 §2 says -- and
`mac` finishes a message from copies of those states, so verifying a grant
costs the message's own blocks plus one, never the key's. The states are
value types with no allocation; a pool thread builds one when its handler
is built and keeps it for the thread's life.

`constant_time_equal` is the compare a tag must be checked with: it reads
every byte of both inputs whatever the first mismatch, so the time it takes
says nothing about where two tags differ. A length mismatch returns at
once, which leaks only the length, and the tag length is public.

Correctness is the seven RFC 4231 test cases in `test/test_hmac.mojo`,
including the truncated one and the two whose keys exceed the block size.
"""

from .sha256 import Sha256, sha256, SHA256_BLOCK_SIZE, SHA256_DIGEST_SIZE


struct HmacSha256(Copyable, Movable):
    """An HMAC-SHA256 key, prepared once: `mac(message)` any number of times."""

    var inner: Sha256
    """The state after `key XOR ipad`; a message continues from a copy."""
    var outer: Sha256
    """The state after `key XOR opad`; the inner digest finishes from a copy."""

    def __init__(out self, key: Span[UInt8, _]):
        """Prepares the key: hashed first if longer than a block (RFC 2104 §2).

        Args:
            key: The secret, any length.
        """
        var k = SIMD[DType.uint8, 64](0)
        if len(key) > SHA256_BLOCK_SIZE:
            var hashed = sha256(key)
            for i in range(SHA256_DIGEST_SIZE):
                k[i] = hashed[i]
        else:
            for i in range(len(key)):
                k[i] = key[i]
        var ipad = List[UInt8](capacity=SHA256_BLOCK_SIZE)
        var opad = List[UInt8](capacity=SHA256_BLOCK_SIZE)
        for i in range(SHA256_BLOCK_SIZE):
            ipad.append(k[i] ^ 0x36)
            opad.append(k[i] ^ 0x5C)
        self.inner = Sha256()
        self.inner.update(Span(ipad))
        self.outer = Sha256()
        self.outer.update(Span(opad))

    def mac_into(self, message: Span[UInt8, _], mut out: List[UInt8]):
        """Appends the 32-byte tag of `message` to `out`.

        Args:
            message: The bytes to authenticate.
            out: The buffer the tag is appended to.
        """
        var i = self.inner.copy()
        i.update(message)
        var inner_digest = List[UInt8](capacity=SHA256_DIGEST_SIZE)
        i.digest_into(inner_digest)
        var o = self.outer.copy()
        o.update(Span(inner_digest))
        o.digest_into(out)

    def mac(self, message: Span[UInt8, _]) -> List[UInt8]:
        """Computes the 32-byte tag of `message`.

        Args:
            message: The bytes to authenticate.

        Returns:
            A freshly allocated 32-byte list.
        """
        var out = List[UInt8](capacity=SHA256_DIGEST_SIZE)
        self.mac_into(message, out)
        return out^

    def verify(self, message: Span[UInt8, _], tag: Span[UInt8, _]) -> Bool:
        """Checks `tag` against the full 32-byte tag of `message`, in constant time.

        A truncated tag is refused: it is shorter.

        Args:
            message: The bytes the tag claims to authenticate.
            tag: The tag presented.

        Returns:
            True if `tag` is exactly the tag of `message`.
        """
        var expected = List[UInt8](capacity=SHA256_DIGEST_SIZE)
        self.mac_into(message, expected)
        return constant_time_equal(Span(expected), tag)


def hmac_sha256(key: Span[UInt8, _], message: Span[UInt8, _]) -> List[UInt8]:
    """Computes an HMAC-SHA256 in one call.

    Prepare an `HmacSha256` instead when one key signs or checks more than
    one message.

    Args:
        key: The secret, any length.
        message: The bytes to authenticate.

    Returns:
        The 32-byte tag.
    """
    return HmacSha256(key).mac(message)


def constant_time_equal(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    """Compares `a` and `b` in time that depends on their length, not their contents.

    Every byte is read and the differences are OR-ed together, so a tag that
    differs in its first byte takes as long as one that differs in its last.
    Unequal lengths return at once; a tag's length is public.

    Args:
        a: One byte string.
        b: The other.

    Returns:
        True if the two are equal.
    """
    if len(a) != len(b):
        return False
    var acc = UInt8(0)
    for i in range(len(a)):
        acc |= a[i] ^ b[i]
    return acc == 0
