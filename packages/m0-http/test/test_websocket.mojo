"""RFC 6455 protocol tests — handshake crypto, frames, and the parser.

Everything here runs socket-free: `WSState.feed` is handed bytes the way
recv() would deliver them, including split mid-frame, and the assertions
are on what a real client would experience — the accept key it validates,
the pong that answers its ping, the close code a violation earns.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.http import HTTPRequest
from lightbug_http.uri import URI
from lightbug_http.websocket import (
    sha1,
    base64_encode,
    compute_accept_key,
    websocket_upgrade,
    is_ws_upgrade_response,
    encode_ws_frame,
    encode_ws_frame_masked,
    close_frame,
    WSState,
    WS_OP_TEXT,
    WS_OP_BINARY,
    WS_OP_CONT,
    WS_OP_CLOSE,
    WS_OP_PING,
    WS_OP_PONG,
    WS_CLOSE_PROTOCOL_ERROR,
    WS_CLOSE_INVALID_DATA,
    WS_CLOSE_TOO_BIG,
    is_valid_utf8,
)


def _hex(data: List[UInt8]) raises -> String:
    var digits = "0123456789abcdef".as_bytes()
    var out = List[UInt8](capacity=len(data) * 2)
    for i in range(len(data)):
        out.append(digits[Int(data[i]) >> 4])
        out.append(digits[Int(data[i]) & 0xF])
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def _mask() raises -> List[UInt8]:
    var m = List[UInt8]()
    m.append(0x37)
    m.append(0xFA)
    m.append(0x21)
    m.append(0x3D)
    return m^


def _ws_request(
    upgrade: String = "websocket",
    connection: String = "Upgrade",
    version: String = "13",
    key: String = "dGhlIHNhbXBsZSBub25jZQ==",
    method: String = "GET",
) raises -> HTTPRequest:
    var headers = Headers(
        Header(HeaderKey.HOST, "localhost"),
        Header(HeaderKey.UPGRADE, upgrade),
        Header(HeaderKey.CONNECTION, connection),
        Header("Sec-WebSocket-Version", version),
        Header("Sec-WebSocket-Key", key),
    )
    return HTTPRequest(
        URI.parse("http://localhost/ws"), headers=headers^, method=method
    )


# --- SHA-1 / base64 / accept key ---------------------------------------------


def test_sha1_known_vectors() raises:
    assert_equal(
        _hex(sha1("abc".as_bytes())),
        "a9993e364706816aba3e25717850c26c9cd0d89d",
    )
    assert_equal(
        _hex(sha1("".as_bytes())),
        "da39a3ee5e6b4b0d3255bfef95601890afd80709",
    )
    # 64+ bytes: exercises the multi-chunk path.
    assert_equal(
        _hex(sha1(
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".as_bytes()
        )),
        "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
    )


def test_base64_rfc4648_vectors() raises:
    assert_equal(base64_encode("".as_bytes()), "")
    assert_equal(base64_encode("f".as_bytes()), "Zg==")
    assert_equal(base64_encode("fo".as_bytes()), "Zm8=")
    assert_equal(base64_encode("foo".as_bytes()), "Zm9v")
    assert_equal(base64_encode("foob".as_bytes()), "Zm9vYg==")
    assert_equal(base64_encode("fooba".as_bytes()), "Zm9vYmE=")
    assert_equal(base64_encode("foobar".as_bytes()), "Zm9vYmFy")


def test_accept_key_rfc6455_example() raises:
    # RFC 6455 §1.3 — the canonical handshake example.
    assert_equal(
        compute_accept_key("dGhlIHNhbXBsZSBub25jZQ=="),
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
    )


# --- Opening handshake --------------------------------------------------------


def test_upgrade_success_is_101_with_accept() raises:
    var resp_opt = websocket_upgrade(_ws_request())
    assert_true(Bool(resp_opt))
    var resp = resp_opt.take()
    assert_equal(resp.status_code, 101)
    assert_equal(resp.headers["Sec-WebSocket-Accept"], "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    assert_equal(resp.headers[HeaderKey.UPGRADE], "websocket")
    assert_true(is_ws_upgrade_response(resp))


def test_non_upgrade_request_returns_none() raises:
    var headers = Headers(Header(HeaderKey.HOST, "localhost"))
    var req = HTTPRequest(URI.parse("http://localhost/ws"), headers=headers^)
    assert_false(Bool(websocket_upgrade(req)))


def test_wrong_version_is_426_advertising_13() raises:
    var resp_opt = websocket_upgrade(_ws_request(version="8"))
    assert_true(Bool(resp_opt))
    var resp = resp_opt.take()
    assert_equal(resp.status_code, 426)
    assert_equal(resp.headers["Sec-WebSocket-Version"], "13")
    assert_false(is_ws_upgrade_response(resp))


def test_malformed_key_is_400() raises:
    var resp_opt = websocket_upgrade(_ws_request(key="short"))
    assert_true(Bool(resp_opt))
    assert_equal(resp_opt.take().status_code, 400)


def test_post_upgrade_is_400() raises:
    var resp_opt = websocket_upgrade(_ws_request(method="POST"))
    assert_true(Bool(resp_opt))
    assert_equal(resp_opt.take().status_code, 400)


def test_connection_without_upgrade_token_is_400() raises:
    var resp_opt = websocket_upgrade(_ws_request(connection="keep-alive"))
    assert_true(Bool(resp_opt))
    assert_equal(resp_opt.take().status_code, 400)


# --- Frame encoding -----------------------------------------------------------


def test_encode_small_frame_header() raises:
    var f = encode_ws_frame(WS_OP_TEXT, "Hello".as_bytes())
    assert_equal(Int(f[0]), 0x81)  # FIN + text
    assert_equal(Int(f[1]), 5)  # unmasked, 7-bit length
    assert_equal(len(f), 7)


def test_encode_16bit_length_boundary() raises:
    var payload = List[UInt8]()
    for _ in range(126):
        payload.append(UInt8(ord("x")))
    var f = encode_ws_frame(WS_OP_BINARY, Span(payload))
    assert_equal(Int(f[1]), 126)
    assert_equal((Int(f[2]) << 8) | Int(f[3]), 126)
    assert_equal(len(f), 4 + 126)


def test_encode_64bit_length() raises:
    var payload = List[UInt8]()
    for _ in range(70000):
        payload.append(0)
    var f = encode_ws_frame(WS_OP_BINARY, Span(payload))
    assert_equal(Int(f[1]), 127)
    var n: Int = 0
    for j in range(8):
        n = (n << 8) | Int(f[2 + j])
    assert_equal(n, 70000)


# --- Parser: the happy path ---------------------------------------------------


def test_masked_text_round_trip() raises:
    var state = WSState(1 << 20)
    var frame = encode_ws_frame_masked(WS_OP_TEXT, "Hello".as_bytes(), _mask())
    var res = state.feed(Span(frame))
    assert_equal(len(res.msg_opcodes), 1)
    assert_equal(res.msg_opcodes[0], WS_OP_TEXT)
    assert_equal(String(StringSlice(unsafe_from_utf8=Span(res.msg_payloads[0]))), "Hello")
    assert_false(res.close_after_reply)
    assert_equal(len(res.reply), 0)


def test_partial_frame_across_feeds() raises:
    var state = WSState(1 << 20)
    var frame = encode_ws_frame_masked(WS_OP_TEXT, "split brain".as_bytes(), _mask())
    var cut = 4  # mid-header/payload
    var res1 = state.feed(Span(frame)[:cut])
    assert_equal(len(res1.msg_opcodes), 0)
    var res2 = state.feed(Span(frame)[cut:])
    assert_equal(len(res2.msg_opcodes), 1)
    assert_equal(String(StringSlice(unsafe_from_utf8=Span(res2.msg_payloads[0]))), "split brain")


def test_two_frames_in_one_feed() raises:
    var state = WSState(1 << 20)
    var bytes = encode_ws_frame_masked(WS_OP_TEXT, "one".as_bytes(), _mask())
    var second = encode_ws_frame_masked(WS_OP_TEXT, "two".as_bytes(), _mask())
    for j in range(len(second)):
        bytes.append(second[j])
    var res = state.feed(Span(bytes))
    assert_equal(len(res.msg_opcodes), 2)
    assert_equal(String(StringSlice(unsafe_from_utf8=Span(res.msg_payloads[0]))), "one")
    assert_equal(String(StringSlice(unsafe_from_utf8=Span(res.msg_payloads[1]))), "two")


def test_fragmented_message_assembles() raises:
    var state = WSState(1 << 20)
    # text "frag" without FIN, then continuation "ment" with FIN.
    var f1 = encode_ws_frame_masked(WS_OP_TEXT, "frag".as_bytes(), _mask())
    f1[0] = f1[0] & 0x7F  # clear FIN
    var f2 = encode_ws_frame_masked(WS_OP_CONT, "ment".as_bytes(), _mask())
    var res1 = state.feed(Span(f1))
    assert_equal(len(res1.msg_opcodes), 0)
    var res2 = state.feed(Span(f2))
    assert_equal(len(res2.msg_opcodes), 1)
    assert_equal(res2.msg_opcodes[0], WS_OP_TEXT)
    assert_equal(String(StringSlice(unsafe_from_utf8=Span(res2.msg_payloads[0]))), "fragment")


def test_ping_earns_pong_with_same_payload() raises:
    var state = WSState(1 << 20)
    var ping = encode_ws_frame_masked(WS_OP_PING, "marco".as_bytes(), _mask())
    var res = state.feed(Span(ping))
    assert_equal(len(res.msg_opcodes), 0)
    assert_false(res.close_after_reply)
    var expected = encode_ws_frame(WS_OP_PONG, "marco".as_bytes())
    assert_equal(len(res.reply), len(expected))
    for j in range(len(expected)):
        assert_equal(res.reply[j], expected[j])


def test_pong_is_ignored() raises:
    var state = WSState(1 << 20)
    var pong = encode_ws_frame_masked(WS_OP_PONG, "hb".as_bytes(), _mask())
    var res = state.feed(Span(pong))
    assert_equal(len(res.msg_opcodes), 0)
    assert_equal(len(res.reply), 0)
    assert_false(res.close_after_reply)


def test_close_is_echoed_with_code_then_closes() raises:
    var state = WSState(1 << 20)
    var body = List[UInt8]()
    body.append(0x03)
    body.append(0xE8)  # 1000
    var close = encode_ws_frame_masked(WS_OP_CLOSE, Span(body), _mask())
    var res = state.feed(Span(close))
    assert_true(res.close_after_reply)
    # Echo carries the same code back.
    assert_equal(Int(res.reply[0]), 0x88)
    assert_equal(Int(res.reply[1]), 2)
    assert_equal((Int(res.reply[2]) << 8) | Int(res.reply[3]), 1000)


# --- Parser: refusals ---------------------------------------------------------


def _close_code(res_reply: List[UInt8]) raises -> Int:
    return (Int(res_reply[2]) << 8) | Int(res_reply[3])


def test_unmasked_client_frame_is_protocol_error() raises:
    var state = WSState(1 << 20)
    var frame = encode_ws_frame(WS_OP_TEXT, "nope".as_bytes())  # server-style: unmasked
    var res = state.feed(Span(frame))
    assert_true(res.close_after_reply)
    assert_equal(_close_code(res.reply), WS_CLOSE_PROTOCOL_ERROR)
    assert_equal(len(res.msg_opcodes), 0)


def test_rsv_bits_are_protocol_error() raises:
    var state = WSState(1 << 20)
    var frame = encode_ws_frame_masked(WS_OP_TEXT, "x".as_bytes(), _mask())
    frame[0] = frame[0] | 0x40  # RSV1 without negotiated extension
    var res = state.feed(Span(frame))
    assert_true(res.close_after_reply)
    assert_equal(_close_code(res.reply), WS_CLOSE_PROTOCOL_ERROR)


def test_continuation_without_start_is_protocol_error() raises:
    var state = WSState(1 << 20)
    var frame = encode_ws_frame_masked(WS_OP_CONT, "orphan".as_bytes(), _mask())
    var res = state.feed(Span(frame))
    assert_true(res.close_after_reply)
    assert_equal(_close_code(res.reply), WS_CLOSE_PROTOCOL_ERROR)


def test_interleaved_data_frame_is_protocol_error() raises:
    var state = WSState(1 << 20)
    var f1 = encode_ws_frame_masked(WS_OP_TEXT, "frag".as_bytes(), _mask())
    f1[0] = f1[0] & 0x7F  # start a fragmented message
    _ = state.feed(Span(f1))
    var f2 = encode_ws_frame_masked(WS_OP_TEXT, "new".as_bytes(), _mask())
    var res = state.feed(Span(f2))
    assert_true(res.close_after_reply)
    assert_equal(_close_code(res.reply), WS_CLOSE_PROTOCOL_ERROR)


def test_fragmented_control_frame_is_protocol_error() raises:
    var state = WSState(1 << 20)
    var ping = encode_ws_frame_masked(WS_OP_PING, "x".as_bytes(), _mask())
    ping[0] = ping[0] & 0x7F  # control frame without FIN
    var res = state.feed(Span(ping))
    assert_true(res.close_after_reply)
    assert_equal(_close_code(res.reply), WS_CLOSE_PROTOCOL_ERROR)


def test_unknown_opcode_is_protocol_error() raises:
    var state = WSState(1 << 20)
    var frame = encode_ws_frame_masked(0x3, "x".as_bytes(), _mask())
    var res = state.feed(Span(frame))
    assert_true(res.close_after_reply)
    assert_equal(_close_code(res.reply), WS_CLOSE_PROTOCOL_ERROR)


def test_oversized_message_is_too_big() raises:
    var state = WSState(16)  # tiny cap for the test
    var payload = List[UInt8]()
    for _ in range(17):
        payload.append(0)
    var frame = encode_ws_frame_masked(WS_OP_BINARY, Span(payload), _mask())
    var res = state.feed(Span(frame))
    assert_true(res.close_after_reply)
    assert_equal(_close_code(res.reply), WS_CLOSE_TOO_BIG)


def test_oversized_fragmented_total_is_too_big() raises:
    var state = WSState(16)
    var chunk = List[UInt8]()
    for _ in range(10):
        chunk.append(0)
    var f1 = encode_ws_frame_masked(WS_OP_TEXT, Span(chunk), _mask())
    f1[0] = f1[0] & 0x7F
    var res1 = state.feed(Span(f1))
    assert_false(res1.close_after_reply)
    var f2 = encode_ws_frame_masked(WS_OP_CONT, Span(chunk), _mask())
    var res2 = state.feed(Span(f2))  # 20 total > 16
    assert_true(res2.close_after_reply)
    assert_equal(_close_code(res2.reply), WS_CLOSE_TOO_BIG)


def _seq(*bytes: Int) raises -> List[UInt8]:
    var out = List[UInt8]()
    for b in bytes:
        out.append(UInt8(b))
    return out^


def test_utf8_validator_accepts_and_rejects() raises:
    # Valid: ASCII, and 2/3/4-byte sequences (é, €, 😀).
    assert_true(is_valid_utf8("plain ascii".as_bytes()))
    assert_true(is_valid_utf8(Span(_seq(0xC3, 0xA9))))
    assert_true(is_valid_utf8(Span(_seq(0xE2, 0x82, 0xAC))))
    assert_true(is_valid_utf8(Span(_seq(0xF0, 0x9F, 0x98, 0x80))))
    # Boundary-valid: U+FFFD, U+10FFFF, lowest non-overlong per length.
    assert_true(is_valid_utf8(Span(_seq(0xEF, 0xBF, 0xBD))))
    assert_true(is_valid_utf8(Span(_seq(0xF4, 0x8F, 0xBF, 0xBF))))
    # Invalid shapes, each rejected.
    assert_false(is_valid_utf8(Span(_seq(0x80))))  # stray continuation
    assert_false(is_valid_utf8(Span(_seq(0xC3))))  # truncated
    assert_false(is_valid_utf8(Span(_seq(0xC0, 0xAF))))  # overlong 2-byte
    assert_false(is_valid_utf8(Span(_seq(0xE0, 0x80, 0xAF))))  # overlong 3-byte
    assert_false(is_valid_utf8(Span(_seq(0xED, 0xA0, 0x80))))  # surrogate
    assert_false(is_valid_utf8(Span(_seq(0xF4, 0x90, 0x80, 0x80))))  # > U+10FFFF
    assert_false(is_valid_utf8(Span(_seq(0xFF))))  # never valid
    assert_false(is_valid_utf8(Span(_seq(0xE2, 0x82, 0x41))))  # bad continuation


def test_invalid_utf8_text_closes_1007() raises:
    var state = WSState(1 << 20)
    var payload = List[UInt8]()
    payload.append(0xC3)  # lone lead byte, no continuation
    payload.append(0x28)
    var frame = encode_ws_frame_masked(WS_OP_TEXT, Span(payload), _mask())
    var res = state.feed(Span(frame))
    assert_true(res.close_after_reply)
    assert_equal(_close_code(res.reply), WS_CLOSE_INVALID_DATA)
    assert_equal(len(res.msg_opcodes), 0)


def test_binary_frames_carry_any_bytes() raises:
    var state = WSState(1 << 20)
    var payload = List[UInt8]()
    payload.append(0xFF)
    payload.append(0x00)
    payload.append(0x80)
    var frame = encode_ws_frame_masked(WS_OP_BINARY, Span(payload), _mask())
    var res = state.feed(Span(frame))
    assert_false(res.close_after_reply)
    assert_equal(len(res.msg_opcodes), 1)


def test_multibyte_char_split_across_fragments_is_valid() raises:
    # "€" = E2 82 AC, split mid-character: neither fragment is valid UTF-8
    # alone; the assembled message is — validation must happen at assembly.
    var state = WSState(1 << 20)
    var part1 = List[UInt8]()
    part1.append(0xE2)
    var part2 = List[UInt8]()
    part2.append(0x82)
    part2.append(0xAC)
    var f1 = encode_ws_frame_masked(WS_OP_TEXT, Span(part1), _mask())
    f1[0] = f1[0] & 0x7F  # clear FIN
    var f2 = encode_ws_frame_masked(WS_OP_CONT, Span(part2), _mask())
    _ = state.feed(Span(f1))
    var res = state.feed(Span(f2))
    assert_equal(len(res.msg_opcodes), 1)
    assert_false(res.close_after_reply)


def test_invalid_utf8_across_fragments_closes_1007() raises:
    var state = WSState(1 << 20)
    var part1 = List[UInt8]()
    part1.append(0xE2)  # needs two continuations...
    var part2 = List[UInt8]()
    part2.append(0x41)  # ...gets ASCII instead
    var f1 = encode_ws_frame_masked(WS_OP_TEXT, Span(part1), _mask())
    f1[0] = f1[0] & 0x7F
    var f2 = encode_ws_frame_masked(WS_OP_CONT, Span(part2), _mask())
    _ = state.feed(Span(f1))
    var res = state.feed(Span(f2))
    assert_true(res.close_after_reply)
    assert_equal(_close_code(res.reply), WS_CLOSE_INVALID_DATA)


def test_error_state_discards_buffered_bytes() raises:
    var state = WSState(1 << 20)
    var frame = encode_ws_frame(WS_OP_TEXT, "unmasked".as_bytes())
    _ = state.feed(Span(frame))
    assert_equal(len(state.buffer), 0)
    assert_equal(state.frag_opcode, -1)


def test_close_frame_helper_carries_code() raises:
    var f = close_frame(1001)
    assert_equal(Int(f[0]), 0x88)
    assert_equal(Int(f[1]), 2)
    assert_equal((Int(f[2]) << 8) | Int(f[3]), 1001)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
