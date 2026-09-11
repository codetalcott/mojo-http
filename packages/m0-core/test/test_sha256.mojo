"""SHA-256 against FIPS 180-4's examples and NIST's short-message vector.

Every expected value here was produced by CPython's `hashlib.sha256`, which
is OpenSSL's, and pasted -- none is from memory. The splits across `update`
are the cases a padding bug hides in: 55, 56, 63, 64 and 65 bytes straddle
the point where the length no longer fits the final block.
"""

from std.testing import assert_equal, TestSuite

from src.hashing import hex_digest
from src.sha256 import Sha256, sha256, sha256_hex, SHA256_DIGEST_SIZE


def _hex(data: String) -> String:
    return sha256_hex(Span(data.as_bytes()))


def _repeat(byte: UInt8, n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(byte)
    return out^


def test_fips_180_4_examples() raises:
    """The three messages FIPS 180-4 works through, plus the empty message.

    covers: G15
    """
    assert_equal(
        _hex(""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    )
    assert_equal(
        _hex("abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    )
    assert_equal(
        _hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    )
    assert_equal(
        _hex(
            "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        ),
        "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
    )


def test_a_million_a() raises:
    """FIPS 180-4's long example, absorbed in one call and in 64 KB pieces."""
    var data = _repeat(UInt8(ord("a")), 1_000_000)
    assert_equal(
        sha256_hex(Span(data)),
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
    )
    var s = Sha256()
    var i = 0
    while i < len(data):
        var j = min(i + 65536, len(data))
        s.update(Span(data)[i:j])
        i = j
    assert_equal(
        hex_digest(Span(s.digest())),
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
    )


def test_nist_short_message() raises:
    """One byte, 0xBD: the NIST CAVS short-message case with a high bit set."""
    var data = List[UInt8]()
    data.append(UInt8(0xBD))
    assert_equal(
        sha256_hex(Span(data)),
        "68325720aabd7c82f30f554b313d0570c95accbb7dc4b5aae11204c08ffe732b",
    )


def test_lengths_around_the_padding_boundary() raises:
    """55, 56, 64 and 65 bytes: where the length field does and does not
    fit in the final block, and a message that is exactly one block."""
    assert_equal(
        sha256_hex(Span(_repeat(UInt8(ord("x")), 55))),
        "d5e285683cd4efc02d021a5c62014694958901005d6f71e89e0989fac77e4072",
    )
    assert_equal(
        sha256_hex(Span(_repeat(UInt8(ord("x")), 56))),
        "04c26261370ee7541549d16dee320c723e3fd14671e66a099afe0a377c16888e",
    )
    assert_equal(
        sha256_hex(Span(_repeat(UInt8(ord("x")), 64))),
        "7ce100971f64e7001e8fe5a51973ecdfe1ced42befe7ee8d5fd6219506b5393c",
    )
    assert_equal(
        sha256_hex(Span(_repeat(UInt8(ord("x")), 65))),
        "9537c5fdf120482f7d58d25e9ed583f52c02b4e304ea814db1633ad565aed7e9",
    )


def test_every_split_gives_the_same_digest() raises:
    """200 bytes (0..199) absorbed whole, and split at every boundary from
    1 to 199 -- the same digest each time, and `digest` leaves the state
    usable so a second read after more input is the longer message's."""
    var data = List[UInt8](capacity=200)
    for i in range(200):
        data.append(UInt8(i))
    var whole = sha256_hex(Span(data))
    assert_equal(
        whole,
        "1901da1c9f699b48f6b2636e65cbf73abf99d0441ef67f5c540a42f7051dec6f",
    )
    for split in range(1, 200):
        var s = Sha256()
        s.update(Span(data)[0:split])
        s.update(Span(data)[split:200])
        assert_equal(
            hex_digest(Span(s.digest())), whole, "split at " + String(split)
        )
    var s = Sha256()
    s.update(Span(data)[0:100])
    var half = s.digest()
    assert_equal(len(half), SHA256_DIGEST_SIZE)
    s.update(Span(data)[100:200])
    assert_equal(hex_digest(Span(s.digest())), whole)


def test_digest_into_appends() raises:
    """`digest_into` appends to what the buffer already holds."""
    var out = List[UInt8]()
    out.append(UInt8(7))
    var s = Sha256()
    s.update(Span(String("abc").as_bytes()))
    s.digest_into(out)
    assert_equal(len(out), 1 + SHA256_DIGEST_SIZE)
    assert_equal(Int(out[0]), 7)
    assert_equal(
        hex_digest(Span(out)[1:33]),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
