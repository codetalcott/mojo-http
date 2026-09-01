"""Tests for the chunked transfer-encoding ENCODER.

The decoder in the same module is the client's half and already had
coverage through `test_client.mojo`; these pin the server's half, and the
round-trip tests deliberately feed the encoder's output to that decoder —
the two are the only readers of each other's rules, so a framing mistake
that both halves shared would otherwise pass unnoticed.
"""

from std.testing import assert_equal, assert_true, TestSuite

from lightbug_http.http.chunked import (
    HTTPChunkedDecoder,
    append_chunk_size,
    chunked_terminator,
    encode_chunk,
)
from lightbug_http.io.bytes import Bytes


def _s(b: Bytes) -> String:
    """Bytes as a String, for readable assertions on ASCII framing."""
    return String(StringSlice(unsafe_from_utf8=Span(b)))


def _b(s: String) -> Bytes:
    var out = Bytes()
    out.extend(s.as_bytes())
    return out^


def test_chunk_size_is_lowercase_hex_no_leading_zeros() raises:
    var out = Bytes()
    append_chunk_size(out, 0)
    assert_equal(_s(out), "0\r\n")

    out = Bytes()
    append_chunk_size(out, 1)
    assert_equal(_s(out), "1\r\n")

    out = Bytes()
    append_chunk_size(out, 15)
    assert_equal(_s(out), "f\r\n")

    out = Bytes()
    append_chunk_size(out, 16)
    assert_equal(_s(out), "10\r\n")

    out = Bytes()
    append_chunk_size(out, 255)
    assert_equal(_s(out), "ff\r\n")

    out = Bytes()
    append_chunk_size(out, 256)
    assert_equal(_s(out), "100\r\n")

    # 64 KB, the ASGI credit window — the size that actually goes on the
    # wire most often.
    out = Bytes()
    append_chunk_size(out, 65536)
    assert_equal(_s(out), "10000\r\n")


def test_encode_chunk_frames_payload() raises:
    var payload = _b("hello")
    var framed = encode_chunk(Span(payload))
    assert_equal(_s(framed), "5\r\nhello\r\n")


def test_encode_chunk_binary_payload_is_untouched() raises:
    """Framing must not reinterpret the bytes it wraps."""
    var payload = Bytes()
    payload.append(0)
    payload.append(0xFF)
    payload.append(0x0D)
    payload.append(0x0A)
    var framed = encode_chunk(Span(payload))
    # "4\r\n" + the four bytes + "\r\n"
    assert_equal(len(framed), 3 + 4 + 2)
    assert_equal(framed[3], 0)
    assert_equal(framed[4], 0xFF)
    assert_equal(framed[5], 0x0D)
    assert_equal(framed[6], 0x0A)


def test_terminator_is_zero_chunk_and_bare_crlf() raises:
    assert_equal(_s(chunked_terminator()), "0\r\n\r\n")


def test_round_trip_single_chunk() raises:
    """Declared coverage.

    covers: A8
    """
    var payload = _b("hello world")
    var wire = encode_chunk(Span(payload))
    wire.extend(chunked_terminator())

    var dec = HTTPChunkedDecoder()
    # Matches the real consumer (`http/response.mojo`): with the trailer
    # section consumed, a complete body reports zero bytes left over.
    dec.consume_trailer = True
    var res = dec.decode(Span(wire))
    assert_equal(res[0], 0)  # no bytes left after the body
    assert_equal(res[1], len(payload))
    var decoded = Bytes()
    for i in range(res[1]):
        decoded.append(wire[i])
    assert_equal(_s(decoded), "hello world")


def test_round_trip_many_chunks_reassembles_in_order() raises:
    """Several drains of different sizes must decode to the concatenation."""
    var parts = List[String]()
    parts.append("a")
    parts.append("bcdefghij")
    parts.append("k" * 300)
    parts.append("tail")

    var expected = String("")
    var wire = Bytes()
    for i in range(len(parts)):
        expected += parts[i]
        var p = _b(parts[i])
        wire.extend(encode_chunk(Span(p)))
    wire.extend(chunked_terminator())

    var dec = HTTPChunkedDecoder()
    # Matches the real consumer (`http/response.mojo`): with the trailer
    # section consumed, a complete body reports zero bytes left over.
    dec.consume_trailer = True
    var res = dec.decode(Span(wire))
    assert_equal(res[0], 0)
    assert_equal(res[1], expected.byte_length())
    var decoded = Bytes()
    for i in range(res[1]):
        decoded.append(wire[i])
    assert_equal(_s(decoded), expected)


def test_round_trip_large_chunk() raises:
    """A chunk past the 4-hex-digit boundary, where the size encoding grows."""
    var payload = Bytes()
    for i in range(70000):
        payload.append(UInt8(i % 251))
    var wire = encode_chunk(Span(payload))
    wire.extend(chunked_terminator())

    var dec = HTTPChunkedDecoder()
    # Matches the real consumer (`http/response.mojo`): with the trailer
    # section consumed, a complete body reports zero bytes left over.
    dec.consume_trailer = True
    var res = dec.decode(Span(wire))
    assert_equal(res[0], 0)
    assert_equal(res[1], 70000)
    # Spot-check the payload survived byte-exact.
    assert_equal(wire[0], UInt8(0))
    assert_equal(wire[250], UInt8(250))
    assert_equal(wire[251], UInt8(0))
    assert_equal(wire[69999], UInt8((70000 - 1) % 251))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
