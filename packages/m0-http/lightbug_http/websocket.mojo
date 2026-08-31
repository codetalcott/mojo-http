"""WebSocket (RFC 6455), server side.

Everything protocol-shaped lives here, socket-free, so the whole state
machine is unit-testable without a connection: the opening handshake
(`websocket_upgrade`), frame encoding (`encode_ws_frame`), and the
incremental frame parser (`WSState.feed`). The event loop owns the sockets
and calls in; see `event_loop.mojo` for the wiring.

The split of responsibilities is deliberate:

- **The loop answers control frames.** Ping is answered with pong and close
  with close by `feed` emitting reply bytes the loop sends — the handler
  never sees them. Handlers deal in complete messages only.
- **Fragmented messages arrive assembled.** `feed` accumulates continuation
  frames and delivers one (opcode, payload) per message, capped by
  `max_message_size` — the same bound the server puts on request bodies.
- **Protocol violations close the connection**, with the RFC's close code
  (1002 protocol error, 1009 too big) in the close frame: unmasked client
  frames, reserved bits, interleaved data frames, oversized control frames,
  unknown opcodes — and text messages that are not valid UTF-8, which
  close with 1007 once the complete message is assembled (RFC 6455 §8.1).
  Binary payloads are the handler's to interpret.

SHA-1 and base64 are implemented here rather than imported: the handshake
needs exactly one hash of one short string per connection open, nothing
else in the repo needs either, and `m0-core` stays the place for hashes
things actually keep calling.
"""

from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.io.bytes import Bytes
from std.memory import bitcast


# Opcodes (RFC 6455 §5.2).
comptime WS_OP_CONT = 0x0
comptime WS_OP_TEXT = 0x1
comptime WS_OP_BINARY = 0x2
comptime WS_OP_CLOSE = 0x8
comptime WS_OP_PING = 0x9
comptime WS_OP_PONG = 0xA

# Close codes (RFC 6455 §7.4.1) — the ones this server sends.
comptime WS_CLOSE_NORMAL = 1000
comptime WS_CLOSE_GOING_AWAY = 1001
comptime WS_CLOSE_PROTOCOL_ERROR = 1002
comptime WS_CLOSE_INVALID_DATA = 1007
comptime WS_CLOSE_TOO_BIG = 1009

comptime _WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


# --- SHA-1 (FIPS 180-1) ------------------------------------------------------


def _rotl32(x: UInt32, n: UInt32) -> UInt32:
    return (x << n) | (x >> (32 - n))


def sha1(data: Span[Byte, _]) -> List[UInt8]:
    """SHA-1 digest, 20 bytes. Handshake-sized inputs only — no streaming."""
    var h0: UInt32 = 0x67452301
    var h1: UInt32 = 0xEFCDAB89
    var h2: UInt32 = 0x98BADCFE
    var h3: UInt32 = 0x10325476
    var h4: UInt32 = 0xC3D2E1F0

    # Pad: 0x80, zeros to 56 mod 64, then the bit length big-endian.
    var msg = List[UInt8](capacity=len(data) + 72)
    msg.extend(data)
    msg.append(0x80)
    while len(msg) % 64 != 56:
        msg.append(0)
    var bit_len = UInt64(len(data)) * 8
    for shift in range(56, -8, -8):
        msg.append(UInt8((bit_len >> UInt64(shift)) & 0xFF))

    var w = List[UInt32](capacity=80)
    for _ in range(80):
        w.append(0)

    for chunk in range(0, len(msg), 64):
        for t in range(16):
            var o = chunk + t * 4
            w[t] = (
                (UInt32(msg[o]) << 24)
                | (UInt32(msg[o + 1]) << 16)
                | (UInt32(msg[o + 2]) << 8)
                | UInt32(msg[o + 3])
            )
        for t in range(16, 80):
            w[t] = _rotl32(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1)

        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4
        for t in range(80):
            var f: UInt32
            var k: UInt32
            if t < 20:
                f = (b & c) | ((~b) & d)
                k = 0x5A827999
            elif t < 40:
                f = b ^ c ^ d
                k = 0x6ED9EBA1
            elif t < 60:
                f = (b & c) | (b & d) | (c & d)
                k = 0x8F1BBCDC
            else:
                f = b ^ c ^ d
                k = 0xCA62C1D6
            var temp = _rotl32(a, 5) + f + e + k + w[t]
            e = d
            d = c
            c = _rotl32(b, 30)
            b = a
            a = temp
        h0 += a
        h1 += b
        h2 += c
        h3 += d
        h4 += e

    var out = List[UInt8](capacity=20)
    for h in [h0, h1, h2, h3, h4]:
        for shift in range(24, -8, -8):
            out.append(UInt8((h >> UInt32(shift)) & 0xFF))
    return out^


# --- base64 (RFC 4648, standard alphabet) ------------------------------------

comptime _B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def base64_encode(data: Span[Byte, _]) -> String:
    var alphabet = _B64_ALPHABET.as_bytes()
    var out = List[UInt8](capacity=((len(data) + 2) // 3) * 4)
    var i = 0
    while i + 3 <= len(data):
        var n = (UInt32(data[i]) << 16) | (UInt32(data[i + 1]) << 8) | UInt32(data[i + 2])
        out.append(alphabet[Int((n >> 18) & 0x3F)])
        out.append(alphabet[Int((n >> 12) & 0x3F)])
        out.append(alphabet[Int((n >> 6) & 0x3F)])
        out.append(alphabet[Int(n & 0x3F)])
        i += 3
    var rem = len(data) - i
    if rem == 1:
        var n = UInt32(data[i]) << 16
        out.append(alphabet[Int((n >> 18) & 0x3F)])
        out.append(alphabet[Int((n >> 12) & 0x3F)])
        out.append(UInt8(ord("=")))
        out.append(UInt8(ord("=")))
    elif rem == 2:
        var n = (UInt32(data[i]) << 16) | (UInt32(data[i + 1]) << 8)
        out.append(alphabet[Int((n >> 18) & 0x3F)])
        out.append(alphabet[Int((n >> 12) & 0x3F)])
        out.append(alphabet[Int((n >> 6) & 0x3F)])
        out.append(UInt8(ord("=")))
    return String(StringSlice(unsafe_from_utf8=Span(out)))


# --- Opening handshake (RFC 6455 §4) ------------------------------------------


def compute_accept_key(client_key: String) -> String:
    """Sec-WebSocket-Accept for a client's Sec-WebSocket-Key."""
    var material = client_key + _WS_GUID
    var digest = sha1(material.as_bytes())
    return base64_encode(Span(digest))


def websocket_upgrade(req: HTTPRequest) -> Optional[HTTPResponse]:
    """Answer a WebSocket opening handshake.

    Returns None when the request is not attempting an upgrade at all — the
    caller's ordinary routing continues. When it IS an upgrade attempt, the
    result is always a response: `101 Switching Protocols` on success (the
    event loop recognises it and switches the connection to frame mode),
    `426` with the supported version for a version mismatch, `400` for a
    malformed attempt (missing key, wrong method).
    """
    var upgrade_hdr = req.headers.get(HeaderKey.UPGRADE)
    if not upgrade_hdr:
        return None
    if upgrade_hdr.value().lower() != "websocket":
        return None

    if req.method != "GET":
        return _handshake_reject(400, "Bad Request", "WebSocket upgrade requires GET")

    # Connection must include the "upgrade" token (it can carry several).
    var conn_hdr = req.headers.get(HeaderKey.CONNECTION)
    if not conn_hdr or conn_hdr.value().lower().find("upgrade") < 0:
        return _handshake_reject(400, "Bad Request", "Connection header must include upgrade")

    var version = req.headers.get("sec-websocket-version")
    if not version or version.value() != "13":
        var resp = _handshake_reject(426, "Upgrade Required", "Unsupported WebSocket version")
        resp.headers["Sec-WebSocket-Version"] = "13"
        return resp^

    var key = req.headers.get("sec-websocket-key")
    # The key is 16 random bytes base64'd: always 24 characters.
    if not key or key.value().byte_length() != 24:
        return _handshake_reject(400, "Bad Request", "Missing or malformed Sec-WebSocket-Key")

    var accept = compute_accept_key(key.value())
    var resp = HTTPResponse(
        body_bytes=String("").as_bytes(),
        status_code=101,
        status_text="Switching Protocols",
    )
    resp.headers[HeaderKey.UPGRADE] = "websocket"
    resp.headers[HeaderKey.CONNECTION] = "Upgrade"
    resp.headers["Sec-WebSocket-Accept"] = accept
    return resp^


def _handshake_reject(status: Int, text: String, detail: String) -> HTTPResponse:
    return HTTPResponse(
        body_bytes=detail.as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/plain")),
        status_code=status,
        status_text=text,
    )


def is_ws_upgrade_response(resp: HTTPResponse) -> Bool:
    """Whether a handler's response switches the connection to WebSocket.

    The event loop calls this on every response instead of a flag on
    `HTTPResponse`: 101 + `Upgrade: websocket` IS the signal, on the wire
    and in memory.
    """
    if resp.status_code != 101:
        return False
    var upgrade_hdr = resp.headers.get(HeaderKey.UPGRADE)
    return Bool(upgrade_hdr) and upgrade_hdr.value().lower() == "websocket"


# --- Frames (RFC 6455 §5) -----------------------------------------------------


def encode_ws_frame(opcode: Int, payload: Span[Byte, _]) -> List[UInt8]:
    """A complete server frame: FIN set, unmasked (servers MUST NOT mask)."""
    var n = len(payload)
    var out = List[UInt8](capacity=n + 10)
    out.append(UInt8(0x80 | (opcode & 0x0F)))
    if n <= 125:
        out.append(UInt8(n))
    elif n <= 0xFFFF:
        out.append(126)
        out.append(UInt8((n >> 8) & 0xFF))
        out.append(UInt8(n & 0xFF))
    else:
        out.append(127)
        for shift in range(56, -8, -8):
            out.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xFF))
    out.extend(payload)
    return out^


def encode_ws_frame_masked(
    opcode: Int, payload: Span[Byte, _], mask: List[UInt8]
) -> List[UInt8]:
    """A masked client frame — what a browser sends. Tests and clients only."""
    var n = len(payload)
    var out = List[UInt8](capacity=n + 14)
    out.append(UInt8(0x80 | (opcode & 0x0F)))
    if n <= 125:
        out.append(UInt8(0x80 | n))
    elif n <= 0xFFFF:
        out.append(0x80 | 126)
        out.append(UInt8((n >> 8) & 0xFF))
        out.append(UInt8(n & 0xFF))
    else:
        out.append(0x80 | 127)
        for shift in range(56, -8, -8):
            out.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xFF))
    for i in range(4):
        out.append(mask[i])
    for i in range(n):
        out.append(payload[i] ^ mask[i % 4])
    return out^


def close_frame(code: Int) -> List[UInt8]:
    """A close frame carrying a status code (big-endian, per §5.5.1)."""
    var body = List[UInt8](capacity=2)
    body.append(UInt8((code >> 8) & 0xFF))
    body.append(UInt8(code & 0xFF))
    return encode_ws_frame(WS_OP_CLOSE, Span(body))


def unmask_payload(
    masked: Span[Byte, _], mask: SIMD[DType.uint8, 4]
) -> List[UInt8]:
    """Undo a client frame's masking (RFC 6455 §5.3), 64 bytes at a time.

    The mask is four bytes applied cyclically, so a scalar loop pays an
    index-modulo per byte. Splatting it across 64 lanes turns the whole
    payload into one XOR per chunk; 64 is a multiple of 4, so the pattern
    stays phase-aligned and the scalar tail needs no special casing.

    The splat itself is on the critical path for small frames — building it
    with 64 lane stores costs more than the XOR it enables, and made short
    frames slower than the scalar loop it replaced. Widening the four bytes
    to a word and broadcasting that is effectively free. Bytes and word are
    reinterpreted through `bitcast` in both directions, so lane k holds
    `mask[k % 4]` whatever the platform's byte order is; do not "simplify"
    either half to an arithmetic shift, which would bake in little-endian.

    The mask arrives as four lanes rather than a `Span` so that a caller
    holding both halves in one buffer — which `feed` does — is not passing
    two aliasing spans of the same list.
    """
    var n = len(masked)
    var out = List[UInt8](capacity=n if n > 0 else 1)
    if n == 0:
        return out^
    out.resize(n, 0)

    var mvec = bitcast[DType.uint8, 64](
        SIMD[DType.uint32, 16](bitcast[DType.uint32, 1](mask))
    )

    var src = masked.unsafe_ptr()
    var dst = out.unsafe_ptr()
    var i = 0
    while i + 64 <= n:
        dst.unsafe_offset(i).unsafe_store[width=64](
            src.unsafe_offset(i).unsafe_load[width=64]() ^ mvec
        )
        i += 64
    # `i` is a multiple of 64 and therefore of 4: the tail stays in phase.
    while i < n:
        dst.unsafe_offset(i).unsafe_store(
            src.unsafe_offset(i).unsafe_load() ^ mask[i % 4]
        )
        i += 1
    return out^


def close_code_is_valid_from_peer(code: Int) -> Bool:
    """Close codes RFC 6455 §7.4 permits a peer to put ON THE WIRE.

    The distinction the old code missed is that some codes exist only for
    an endpoint to report to its OWN application and MUST NOT be sent:
    1005 ("no status received") and 1006 ("abnormal closure") describe the
    absence of a close frame, so a close frame carrying one is a
    contradiction, and 1015 says the TLS handshake failed. 1004 was never
    assigned. 1016-2999 is reserved for future revisions of the protocol,
    so nothing there is legal yet.

    What is legal: 1000-1003 and 1007-1011, the protocol's own; 1012-1014,
    registered with IANA after the RFC (service restart, try again later,
    bad gateway) -- hence the range ending at 1014 and excluding 1015; and
    3000-4999, the registered and private-use ranges libraries and
    applications pick from.
    """
    if code >= 1000 and code <= 1003:
        return True
    if code >= 1007 and code <= 1014:
        return True
    if code >= 3000 and code <= 4999:
        return True
    return False


def is_valid_utf8(data: Span[Byte, _]) -> Bool:
    """Strict UTF-8 (RFC 3629): rejects bad continuations, overlong
    encodings, surrogates (U+D800–U+DFFF), and anything past U+10FFFF.

    ASCII runs are skipped 64 bytes at a time by testing the high bit of a
    whole chunk; every byte that is not plain ASCII still goes through the
    scalar decoder below, so the strictness is exactly as before. The bulk
    skip only advances past chunks that are entirely ASCII, so it can never
    step into the middle of a multi-byte sequence.

    The vector probe is guarded on the *current* byte being ASCII rather
    than run unconditionally at the top of the loop: text that is mostly
    multi-byte would otherwise pay a failed 64-byte load per character.
    """
    var i = 0
    var n = len(data)
    var ptr = data.unsafe_ptr()
    var high = SIMD[DType.uint8, 64](0x80)
    while i < n:
        var b0 = Int(data[i])
        if b0 < 0x80:
            # Bulk-skip the ASCII run, then finish it a byte at a time.
            while i + 64 <= n:
                var chunk = ptr.unsafe_offset(i).unsafe_load[width=64]()
                if (chunk & high).reduce_max() != 0:
                    break
                i += 64
            while i < n and data[i] < 0x80:
                i += 1
            continue
        var needed: Int
        var lo = 0x80
        var hi = 0xBF
        if b0 >= 0xC2 and b0 <= 0xDF:
            needed = 1
        elif b0 == 0xE0:
            needed = 2
            lo = 0xA0  # excludes overlongs
        elif b0 >= 0xE1 and b0 <= 0xEC:
            needed = 2
        elif b0 == 0xED:
            needed = 2
            hi = 0x9F  # excludes surrogates
        elif b0 >= 0xEE and b0 <= 0xEF:
            needed = 2
        elif b0 == 0xF0:
            needed = 3
            lo = 0x90  # excludes overlongs
        elif b0 >= 0xF1 and b0 <= 0xF3:
            needed = 3
        elif b0 == 0xF4:
            needed = 3
            hi = 0x8F  # excludes > U+10FFFF
        else:
            return False  # 0x80–0xC1 (stray continuation/overlong), 0xF5+
        if i + needed >= n:
            return False  # truncated sequence
        var b1 = Int(data[i + 1])
        if b1 < lo or b1 > hi:
            return False
        for j in range(2, needed + 1):
            var bj = Int(data[i + j])
            if bj < 0x80 or bj > 0xBF:
                return False
        i += needed + 1
    return True


struct WSParseResult(Movable):
    """What one `feed` produced. Parallel arrays, per repo convention."""

    var msg_opcodes: List[Int]
    """Opcode per complete message (WS_OP_TEXT or WS_OP_BINARY)."""
    var msg_payloads: List[List[UInt8]]
    """Payload per complete message, fragments already assembled."""
    var reply: List[UInt8]
    """Encoded frames the loop must send back (pongs, the close echo)."""
    var close_after_reply: Bool
    """Send `reply`, then close the connection (close handshake or error)."""

    def __init__(out self):
        self.msg_opcodes = List[Int]()
        self.msg_payloads = List[List[UInt8]]()
        self.reply = List[UInt8]()
        self.close_after_reply = False


struct WSState(Movable):
    """Per-connection incremental parser. One per slot, reset on reuse."""

    var buffer: List[UInt8]
    """Bytes received but not yet parsed (partial frames wait here)."""
    var frag_opcode: Int
    """Opcode of the in-progress fragmented message; -1 when none."""
    var frag_payload: List[UInt8]
    """Accumulated payload of the in-progress fragmented message."""
    var max_message_size: Int
    var closing: Bool
    """True once THIS side has sent a Close frame and is waiting for the
    peer's. RFC 6455 §5.5.1: the endpoint that sends Close first waits to
    RECEIVE one before closing the underlying connection. The loop reads it
    to know that a Close arriving now needs no echo — the echo is what this
    side already sent — and that the slot is lingering rather than idle."""
    var inbound_suspended: Bool
    """True while this socket's read is DELIBERATELY off the read set —
    the handler could not forward a message and parked it, so the loop
    stopped reading to let TCP's zero window throttle the client.

    It lives here rather than beside `slot_read_armed` because it is the
    one thing that flag cannot express: `not armed` is also the ordinary
    state between a write registration and its re-arm, and `_after_send`
    re-arms on exactly that condition. Without this distinction the
    socket's own echo re-armed the read it had just suspended, and the
    parked queue lost its bound — it is bounded by ONE `recv` only
    because no further read happens while it is non-empty."""

    def __init__(out self, max_message_size: Int):
        self.buffer = List[UInt8]()
        self.frag_opcode = -1
        self.frag_payload = List[UInt8]()
        self.max_message_size = max_message_size
        self.closing = False
        self.inbound_suspended = False

    def reset(mut self):
        """Back to a fresh connection's state (slot reuse)."""
        self.buffer.clear()
        self.frag_opcode = -1
        self.frag_payload.clear()
        self.closing = False
        self.inbound_suspended = False

    def _fail(mut self, code: Int) -> WSParseResult:
        var res = WSParseResult()
        res.reply = close_frame(code)
        res.close_after_reply = True
        self.buffer.clear()
        self.frag_opcode = -1
        self.frag_payload.clear()
        return res^

    def feed(mut self, data: Span[Byte, _]) -> WSParseResult:
        """Consume received bytes; return whatever became actionable.

        Partial frames stay buffered for the next feed. On a protocol
        violation the result carries a close frame and `close_after_reply`
        — the connection is done either way.
        """
        self.buffer.extend(data)

        var res = WSParseResult()
        var i = 0
        var n = len(self.buffer)

        while True:
            if n - i < 2:
                break
            var b0 = Int(self.buffer[i])
            var b1 = Int(self.buffer[i + 1])
            var fin = (b0 & 0x80) != 0
            var opcode = b0 & 0x0F
            if (b0 & 0x70) != 0:
                # RSV bits without a negotiated extension.
                return self._fail(WS_CLOSE_PROTOCOL_ERROR)
            if (b1 & 0x80) == 0:
                # Client frames MUST be masked (§5.1).
                return self._fail(WS_CLOSE_PROTOCOL_ERROR)

            var header = 2
            var plen = b1 & 0x7F
            if plen == 126:
                if n - i < 4:
                    break
                plen = (Int(self.buffer[i + 2]) << 8) | Int(self.buffer[i + 3])
                header = 4
            elif plen == 127:
                if n - i < 10:
                    break
                var plen64: UInt64 = 0
                for j in range(8):
                    plen64 = (plen64 << 8) | UInt64(self.buffer[i + 2 + j])
                if plen64 > UInt64(self.max_message_size):
                    return self._fail(WS_CLOSE_TOO_BIG)
                plen = Int(plen64)
                header = 10
            if plen > self.max_message_size:
                return self._fail(WS_CLOSE_TOO_BIG)

            var mask_at = i + header
            header += 4
            if n - i < header + plen:
                break  # partial frame: wait for more bytes

            var frame_mask = SIMD[DType.uint8, 4](
                self.buffer[mask_at],
                self.buffer[mask_at + 1],
                self.buffer[mask_at + 2],
                self.buffer[mask_at + 3],
            )
            var payload = unmask_payload(
                Span(self.buffer)[mask_at + 4 : mask_at + 4 + plen], frame_mask
            )
            i += header + plen

            if opcode >= 0x8:
                # Control frames: never fragmented, payload <= 125 (§5.5).
                if not fin or plen > 125:
                    return self._fail(WS_CLOSE_PROTOCOL_ERROR)
                if opcode == WS_OP_PING:
                    var pong = encode_ws_frame(WS_OP_PONG, Span(payload))
                    res.reply.extend(Span(pong))
                elif opcode == WS_OP_PONG:
                    pass  # answers to our heartbeat pings; nothing to do
                elif opcode == WS_OP_CLOSE:
                    # Echo the close (with its code, if any) and finish. Bytes
                    # after a close frame are the client's problem.
                    #
                    # The body is validated FIRST (§5.5.1, §7.4.1). It used to
                    # be copied through unexamined, which made this server a
                    # mirror for codes the RFC says to reject -- a peer could
                    # close with 1006 ("abnormal closure", a value that by
                    # definition never appears in a frame) and be answered
                    # with its own 1006. Autobahn 7.9.1-7.9.9 and 7.5.1 are
                    # the cases; all ten failed on every release up to here.
                    #
                    # A one-byte body cannot be a code, so it is a protocol
                    # error rather than a close with no code (§5.5.1: "If
                    # there is a body, the first two bytes MUST be a 2-byte
                    # unsigned integer").
                    if len(payload) == 1:
                        return self._fail(WS_CLOSE_PROTOCOL_ERROR)
                    if len(payload) >= 2:
                        var close_code = (
                            (Int(payload[0]) << 8) | Int(payload[1])
                        )
                        if not close_code_is_valid_from_peer(close_code):
                            return self._fail(WS_CLOSE_PROTOCOL_ERROR)
                        # Anything after the code is a reason, and a reason
                        # is text: invalid UTF-8 there is 1007, the same
                        # answer a text frame gets (§8.1).
                        if len(payload) > 2 and not is_valid_utf8(
                            Span(payload)[2:]
                        ):
                            return self._fail(WS_CLOSE_INVALID_DATA)
                    var echo_body = List[UInt8]()
                    if len(payload) >= 2:
                        echo_body.append(payload[0])
                        echo_body.append(payload[1])
                    var echo = encode_ws_frame(WS_OP_CLOSE, Span(echo_body))
                    res.reply.extend(Span(echo))
                    res.close_after_reply = True
                    self.buffer.clear()
                    return res^
                else:
                    return self._fail(WS_CLOSE_PROTOCOL_ERROR)
            elif opcode == WS_OP_TEXT or opcode == WS_OP_BINARY:
                if self.frag_opcode != -1:
                    # A new data frame may not interleave with a fragmented
                    # message in progress (§5.4).
                    return self._fail(WS_CLOSE_PROTOCOL_ERROR)
                if fin:
                    if opcode == WS_OP_TEXT and not is_valid_utf8(Span(payload)):
                        return self._fail(WS_CLOSE_INVALID_DATA)
                    res.msg_opcodes.append(opcode)
                    res.msg_payloads.append(payload^)
                else:
                    self.frag_opcode = opcode
                    self.frag_payload = payload^
            elif opcode == WS_OP_CONT:
                if self.frag_opcode == -1:
                    return self._fail(WS_CLOSE_PROTOCOL_ERROR)
                if len(self.frag_payload) + plen > self.max_message_size:
                    return self._fail(WS_CLOSE_TOO_BIG)
                self.frag_payload.extend(Span(payload))
                if fin:
                    # Validated on the ASSEMBLED message: a multi-byte
                    # character legitimately split across fragments is valid
                    # even though neither fragment alone is.
                    if self.frag_opcode == WS_OP_TEXT and not is_valid_utf8(
                        Span(self.frag_payload)
                    ):
                        return self._fail(WS_CLOSE_INVALID_DATA)
                    res.msg_opcodes.append(self.frag_opcode)
                    res.msg_payloads.append(self.frag_payload.copy())
                    self.frag_opcode = -1
                    self.frag_payload.clear()
            else:
                # Reserved data opcodes 0x3–0x7.
                return self._fail(WS_CLOSE_PROTOCOL_ERROR)

        # Keep only the unparsed tail.
        if i > 0:
            var rest = List[UInt8](capacity=n - i)
            rest.extend(Span(self.buffer)[i:n])
            self.buffer = rest^
        return res^
