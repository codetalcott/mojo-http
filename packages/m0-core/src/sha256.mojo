"""SHA-256, FIPS 180-4, in plain Mojo with no dependencies.

The first cryptographic hash in `m0-core`, and it is here for one caller:
`hmac.mojo`, which signs and verifies the grants a Django application hands
a browser for a stream the Mojo side holds, and which the login row (SPEC
N13) will sign a session cookie with. `wyhash64` and the other three hashes
in `hashing.mojo` are not suitable for either; this is the one that is.

Streaming and one-shot. `Sha256` absorbs bytes in any split, and `digest`
does not consume the state, so an HMAC can absorb its padded key once and
finish many messages from that point — the precomputation `HmacSha256`
relies on. The internal block is a 64-lane SIMD value and the chaining
state an 8-lane one, so the struct is a value type of 108 bytes with no
allocation: copying a precomputed state per verification costs a register
spill, not a malloc. The output is written into a caller's `List[UInt8]`
(`digest_into`, appending 32 bytes) so a hot path can reuse one buffer;
`digest` allocates a fresh one for callers that do not care.

Correctness rests on the vectors in `test/test_sha256.mojo`: the FIPS
examples ("abc", the 448- and 896-bit messages, a million `a`s), the empty
message, a NIST short-message case, and every split of one message across
`update` calls at the block boundaries where a padding bug would show.
Throughput is not a goal; a grant is a hundred bytes, and this absorbs a
byte at a time except for whole blocks, which it takes straight from the
caller's span.
"""

from std.bit import rotate_bits_right


comptime DIGEST_SIZE = 32
"""Bytes in a SHA-256 digest."""

comptime BLOCK_SIZE = 64
"""Bytes in one compression block; also HMAC's key-padding length."""

# FIPS 180-4 §4.2.2: the first thirty-two bits of the fractional parts of
# the cube roots of the first sixty-four primes.
comptime _K = SIMD[DType.uint32, 64](
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
)

# FIPS 180-4 §5.3.3: the first thirty-two bits of the fractional parts of
# the square roots of the first eight primes.
comptime _IV = SIMD[DType.uint32, 8](
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
)


@always_inline
def _big_sigma0(x: UInt32) -> UInt32:
    return rotate_bits_right[shift=2](x) ^ rotate_bits_right[shift=13](x) ^ rotate_bits_right[shift=22](x)


@always_inline
def _big_sigma1(x: UInt32) -> UInt32:
    return rotate_bits_right[shift=6](x) ^ rotate_bits_right[shift=11](x) ^ rotate_bits_right[shift=25](x)


@always_inline
def _small_sigma0(x: UInt32) -> UInt32:
    return rotate_bits_right[shift=7](x) ^ rotate_bits_right[shift=18](x) ^ (x >> 3)


@always_inline
def _small_sigma1(x: UInt32) -> UInt32:
    return rotate_bits_right[shift=17](x) ^ rotate_bits_right[shift=19](x) ^ (x >> 10)


def _compress(mut h: SIMD[DType.uint32, 8], words: SIMD[DType.uint32, 16]):
    """One block (FIPS 180-4 §6.2.2), the sixteen message words already
    loaded big-endian."""
    var w = SIMD[DType.uint32, 64](0)
    for t in range(16):
        w[t] = words[t]
    for t in range(16, 64):
        w[t] = _small_sigma1(w[t - 2]) + w[t - 7] + _small_sigma0(w[t - 15]) + w[t - 16]
    var a = h[0]
    var b = h[1]
    var c = h[2]
    var d = h[3]
    var e = h[4]
    var f = h[5]
    var g = h[6]
    var hh = h[7]
    for t in range(64):
        var t1 = hh + _big_sigma1(e) + ((e & f) ^ (~e & g)) + _K[t] + w[t]
        var t2 = _big_sigma0(a) + ((a & b) ^ (a & c) ^ (b & c))
        hh = g
        g = f
        f = e
        e = d + t1
        d = c
        c = b
        b = a
        a = t1 + t2
    h[0] += a
    h[1] += b
    h[2] += c
    h[3] += d
    h[4] += e
    h[5] += f
    h[6] += g
    h[7] += hh


@always_inline
def _word_at(block: SIMD[DType.uint8, 64], i: Int) -> UInt32:
    return (
        (UInt32(block[4 * i]) << 24)
        | (UInt32(block[4 * i + 1]) << 16)
        | (UInt32(block[4 * i + 2]) << 8)
        | UInt32(block[4 * i + 3])
    )


@always_inline
def _word_from(data: Span[UInt8, _], at: Int) -> UInt32:
    return (
        (UInt32(data[at]) << 24)
        | (UInt32(data[at + 1]) << 16)
        | (UInt32(data[at + 2]) << 8)
        | UInt32(data[at + 3])
    )


struct Sha256(Copyable, Movable):
    """A SHA-256 in progress: absorb with `update`, read with `digest`.

    `digest` leaves the state intact, so one absorbed prefix can finish many
    messages -- `HmacSha256` absorbs its padded key once per thread and
    finishes every grant from that copy.
    """

    var h: SIMD[DType.uint32, 8]
    var block: SIMD[DType.uint8, 64]
    var block_len: Int
    var total: UInt64
    """Bytes absorbed so far; the padding writes it as a bit count."""

    def __init__(out self):
        self.h = _IV
        self.block = SIMD[DType.uint8, 64](0)
        self.block_len = 0
        self.total = 0

    def __init__(out self, *, copy: Self):
        self.h = copy.h
        self.block = copy.block
        self.block_len = copy.block_len
        self.total = copy.total

    def __init__(out self, *, deinit move: Self):
        self.h = move.h
        self.block = move.block
        self.block_len = move.block_len
        self.total = move.total

    def update(mut self, data: Span[UInt8, _]):
        """Absorb `data`; any split across calls gives the same digest."""
        var n = len(data)
        var i = 0
        self.total += UInt64(n)
        # Top up a partial block first.
        while self.block_len > 0 and i < n:
            self.block[self.block_len] = data[i]
            self.block_len += 1
            i += 1
            if self.block_len == BLOCK_SIZE:
                self._compress_block()
        # Whole blocks straight from the span, no copy.
        while n - i >= BLOCK_SIZE:
            var words = SIMD[DType.uint32, 16](0)
            for t in range(16):
                words[t] = _word_from(data, i + 4 * t)
            _compress(self.h, words)
            i += BLOCK_SIZE
        # The tail waits for more, or for the padding.
        while i < n:
            self.block[self.block_len] = data[i]
            self.block_len += 1
            i += 1

    def _compress_block(mut self):
        var words = SIMD[DType.uint32, 16](0)
        for t in range(16):
            words[t] = _word_at(self.block, t)
        _compress(self.h, words)
        self.block = SIMD[DType.uint8, 64](0)
        self.block_len = 0

    def digest_into(self, mut out: List[UInt8]):
        """Append the 32-byte digest of everything absorbed so far to `out`.

        Pads a copy (FIPS 180-4 §5.1.1): a `1` bit, zeros to 56 mod 64, the
        message length in bits as eight big-endian bytes. The state itself is
        untouched, so `update` may continue afterwards.
        """
        var s = self.copy()
        var bits = s.total * 8
        s.block[s.block_len] = 0x80
        s.block_len += 1
        if s.block_len > 56:
            for j in range(s.block_len, BLOCK_SIZE):
                s.block[j] = 0
            s._compress_block()
        for j in range(s.block_len, 56):
            s.block[j] = 0
        for j in range(8):
            s.block[56 + j] = UInt8((bits >> UInt64(8 * (7 - j))) & 0xFF)
        s._compress_block()
        for i in range(8):
            var word = s.h[i]
            out.append(UInt8((word >> 24) & 0xFF))
            out.append(UInt8((word >> 16) & 0xFF))
            out.append(UInt8((word >> 8) & 0xFF))
            out.append(UInt8(word & 0xFF))

    def digest(self) -> List[UInt8]:
        """The 32-byte digest of everything absorbed so far, freshly allocated."""
        var out = List[UInt8](capacity=DIGEST_SIZE)
        self.digest_into(out)
        return out^


def sha256(data: Span[UInt8, _]) -> List[UInt8]:
    """One-shot SHA-256 of `data`, 32 bytes."""
    var s = Sha256()
    s.update(data)
    return s.digest()


def sha256_hex(data: Span[UInt8, _]) -> String:
    """One-shot SHA-256 of `data` as 64 lowercase hex characters."""
    return hex_digest(Span(sha256(data)))


def hex_digest(digest: Span[UInt8, _]) -> String:
    """Lowercase hex of any byte string; two characters per byte."""
    var out = List[UInt8](capacity=len(digest) * 2)
    for b in digest:
        var v = Int(b)
        var hi = v >> 4
        var lo = v & 0xF
        out.append(UInt8(ord("0") + hi) if hi < 10 else UInt8(ord("a") + hi - 10))
        out.append(UInt8(ord("0") + lo) if lo < 10 else UInt8(ord("a") + lo - 10))
    return String(StringSpan(unsafe_from_utf8=Span(out)))
