"""HMAC-SHA256 against RFC 4231's seven test cases, and the compare.

Every expected tag was produced by CPython's `hmac` module over
`hashlib.sha256` and pasted; the RFC's own tables print the same values.
Cases 6 and 7 have 131-byte keys, which RFC 2104 §2 says are hashed to 32
bytes before padding; case 5 is the one the RFC prints truncated.
"""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from src.hmac import HmacSha256, hmac_sha256, constant_time_equal
from src.hashing import hex_digest


def _repeat(byte: UInt8, n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(byte)
    return out^


def _range(lo: Int, hi: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=hi - lo)
    for i in range(lo, hi):
        out.append(UInt8(i))
    return out^


def test_rfc_4231_case_1() raises:
    """RFC 4231 §4.2, test case 1.

    covers: G15
    """
    var key = _repeat(UInt8(0x0B), 20)
    var msg = List[UInt8](String("Hi There").as_bytes())
    var tag = hmac_sha256(Span(key), Span(msg))
    assert_equal(
        hex_digest(Span(tag)),
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
    )


def test_rfc_4231_case_2() raises:
    """RFC 4231 §4.3, test case 2.

    covers: G15
    """
    var key = List[UInt8](String("Jefe").as_bytes())
    var msg = List[UInt8](String("what do ya want for nothing?").as_bytes())
    var tag = hmac_sha256(Span(key), Span(msg))
    assert_equal(
        hex_digest(Span(tag)),
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
    )


def test_rfc_4231_case_3() raises:
    """RFC 4231 §4.4, test case 3.

    covers: G15
    """
    var key = _repeat(UInt8(0xAA), 20)
    var msg = _repeat(UInt8(0xDD), 50)
    var tag = hmac_sha256(Span(key), Span(msg))
    assert_equal(
        hex_digest(Span(tag)),
        "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
    )


def test_rfc_4231_case_4() raises:
    """RFC 4231 §4.5, test case 4.

    covers: G15
    """
    var key = _range(1, 26)
    var msg = _repeat(UInt8(0xCD), 50)
    var tag = hmac_sha256(Span(key), Span(msg))
    assert_equal(
        hex_digest(Span(tag)),
        "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b",
    )


def test_rfc_4231_case_5() raises:
    """RFC 4231 §4.6, test case 5.

    covers: G15
    """
    var key = _repeat(UInt8(0x0C), 20)
    var msg = List[UInt8](String("Test With Truncation").as_bytes())
    var tag = hmac_sha256(Span(key), Span(msg))
    assert_equal(
        hex_digest(Span(tag)),
        "a3b6167473100ee06e0c796c2955552bfa6f7c0a6a8aef8b93f860aab0cd20c5",
    )
    # RFC 4231 prints this one truncated to 128 bits; the full tag's
    # first sixteen bytes are that value.
    assert_equal(
        hex_digest(Span(tag)[0:16]), "a3b6167473100ee06e0c796c2955552b"
    )


def test_rfc_4231_case_6() raises:
    """RFC 4231 §4.7, test case 6. The key exceeds the block size and is hashed first.

    covers: G15
    """
    var key = _repeat(UInt8(0xAA), 131)
    var msg = List[UInt8](
        String(
            "Test Using Larger Than Block-Size Key - Hash Key First"
        ).as_bytes()
    )
    var tag = hmac_sha256(Span(key), Span(msg))
    assert_equal(
        hex_digest(Span(tag)),
        "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
    )


def test_rfc_4231_case_7() raises:
    """RFC 4231 §4.8, test case 7. The key exceeds the block size and is hashed first.

    covers: G15
    """
    var key = _repeat(UInt8(0xAA), 131)
    var msg = List[UInt8](
        String(
            "This is a test using a larger than block-size key and a larger"
            " than block-size data. The key needs to be hashed before being"
            " used by the HMAC algorithm."
        ).as_bytes()
    )
    var tag = hmac_sha256(Span(key), Span(msg))
    assert_equal(
        hex_digest(Span(tag)),
        "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2",
    )


def test_a_prepared_key_signs_many_messages() raises:
    """`HmacSha256` absorbs the key once; each `mac` starts from that state
    and agrees with the one-shot form, and a block-size key is used as is."""
    var key = _range(0, 64)
    var h = HmacSha256(Span(key))
    var one = h.mac(Span(String("block-size key").as_bytes()))
    assert_equal(
        hex_digest(Span(one)),
        "1dad230598e011a4e4eabc6c8da8f55ef9a66a8881d1e16e23ea116ae28231ec",
    )
    var again = h.mac(Span(String("block-size key").as_bytes()))
    assert_equal(
        hex_digest(Span(again)),
        "1dad230598e011a4e4eabc6c8da8f55ef9a66a8881d1e16e23ea116ae28231ec",
    )
    var other = h.mac(Span(String("another message").as_bytes()))
    assert_equal(
        hex_digest(Span(other)),
        hex_digest(
            Span(
                hmac_sha256(
                    Span(key), Span(String("another message").as_bytes())
                )
            )
        ),
    )
    assert_true(h.verify(Span(String("block-size key").as_bytes()), Span(one)))
    assert_false(
        h.verify(Span(String("block-size key").as_bytes()), Span(other))
    )
    # A truncated tag is not the tag.
    assert_false(
        h.verify(Span(String("block-size key").as_bytes()), Span(one)[0:16])
    )


def test_constant_time_equal() raises:
    """Equal, unequal in the first byte, unequal in the last, and a length
    mismatch. What this cannot test is the timing; the implementation reads
    every byte by construction and has no early exit but the length one."""
    var a = _range(0, 32)
    var b = _range(0, 32)
    assert_true(constant_time_equal(Span(a), Span(b)))
    b[0] = UInt8(255)
    assert_false(constant_time_equal(Span(a), Span(b)))
    b[0] = UInt8(0)
    b[31] = UInt8(0)
    assert_false(constant_time_equal(Span(a), Span(b)))
    var shorter = _range(0, 31)
    assert_false(constant_time_equal(Span(a), Span(shorter)))
    var empty = List[UInt8]()
    var empty_too = List[UInt8]()
    assert_true(constant_time_equal(Span(empty), Span(empty_too)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
