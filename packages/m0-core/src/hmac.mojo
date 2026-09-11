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

from .sha256 import Sha256, sha256, BLOCK_SIZE, DIGEST_SIZE


struct HmacSha256(Copyable, Movable):
    """An HMAC-SHA256 key, prepared once: `mac(message)` any number of times."""

    var inner: Sha256
    """The state after `key XOR ipad`; a message continues from a copy."""
    var outer: Sha256
    """The state after `key XOR opad`; the inner digest finishes from a copy."""

    def __init__(out self, key: Span[UInt8, _]):
        var k = SIMD[DType.uint8, 64](0)
        if len(key) > BLOCK_SIZE:
            var hashed = sha256(key)
            for i in range(DIGEST_SIZE):
                k[i] = hashed[i]
        else:
            for i in range(len(key)):
                k[i] = key[i]
        var ipad = List[UInt8](capacity=BLOCK_SIZE)
        var opad = List[UInt8](capacity=BLOCK_SIZE)
        for i in range(BLOCK_SIZE):
            ipad.append(k[i] ^ 0x36)
            opad.append(k[i] ^ 0x5C)
        self.inner = Sha256()
        self.inner.update(Span(ipad))
        self.outer = Sha256()
        self.outer.update(Span(opad))

    def __init__(out self, *, copy: Self):
        self.inner = copy.inner.copy()
        self.outer = copy.outer.copy()

    def __init__(out self, *, deinit move: Self):
        self.inner = move.inner^
        self.outer = move.outer^

    def mac_into(self, message: Span[UInt8, _], mut out: List[UInt8]):
        """Append the 32-byte tag of `message` to `out`."""
        var i = self.inner.copy()
        i.update(message)
        var inner_digest = List[UInt8](capacity=DIGEST_SIZE)
        i.digest_into(inner_digest)
        var o = self.outer.copy()
        o.update(Span(inner_digest))
        o.digest_into(out)

    def mac(self, message: Span[UInt8, _]) -> List[UInt8]:
        """The 32-byte tag of `message`, freshly allocated."""
        var out = List[UInt8](capacity=DIGEST_SIZE)
        self.mac_into(message, out)
        return out^

    def verify(self, message: Span[UInt8, _], tag: Span[UInt8, _]) -> Bool:
        """Whether `tag` is the full 32-byte tag of `message`, compared in
        constant time. A truncated tag is refused: it is shorter."""
        var expected = List[UInt8](capacity=DIGEST_SIZE)
        self.mac_into(message, expected)
        return constant_time_equal(Span(expected), tag)


def hmac_sha256(key: Span[UInt8, _], message: Span[UInt8, _]) -> List[UInt8]:
    """One-shot HMAC-SHA256, 32 bytes. Prepare an `HmacSha256` instead when
    one key signs or checks more than one message."""
    return HmacSha256(key).mac(message)


def constant_time_equal(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    """Whether `a == b`, in time that depends on the length and not the
    contents: every byte is read and the differences are OR-ed together, so
    a tag that differs in its first byte takes as long as one that differs
    in its last. Unequal lengths return at once; a tag's length is public.
    """
    if len(a) != len(b):
        return False
    var acc = UInt8(0)
    for i in range(len(a)):
        acc |= a[i] ^ b[i]
    return acc == 0
