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
  unknown opcodes. Text payloads are NOT validated as UTF-8 (RFC 1007) —
  the handler owns interpretation of its own payloads.

SHA-1 and base64 are implemented here rather than imported: the handshake
needs exactly one hash of one short string per connection open, nothing
else in the repo needs either, and `m0-core` stays the place for hashes
things actually keep calling.
"""

from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.io.bytes import Bytes


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
    for i in range(len(data)):
        msg.append(data[i])
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
    for i in range(n):
        out.append(payload[i])
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

    def __init__(out self, max_message_size: Int):
        self.buffer = List[UInt8]()
        self.frag_opcode = -1
        self.frag_payload = List[UInt8]()
        self.max_message_size = max_message_size

    def reset(mut self):
        """Back to a fresh connection's state (slot reuse)."""
        self.buffer.clear()
        self.frag_opcode = -1
        self.frag_payload.clear()

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
        for i in range(len(data)):
            self.buffer.append(data[i])

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

            var payload = List[UInt8](capacity=plen)
            for j in range(plen):
                payload.append(
                    self.buffer[mask_at + 4 + j] ^ self.buffer[mask_at + (j % 4)]
                )
            i += header + plen

            if opcode >= 0x8:
                # Control frames: never fragmented, payload <= 125 (§5.5).
                if not fin or plen > 125:
                    return self._fail(WS_CLOSE_PROTOCOL_ERROR)
                if opcode == WS_OP_PING:
                    var pong = encode_ws_frame(WS_OP_PONG, Span(payload))
                    for j in range(len(pong)):
                        res.reply.append(pong[j])
                elif opcode == WS_OP_PONG:
                    pass  # answers to our heartbeat pings; nothing to do
                elif opcode == WS_OP_CLOSE:
                    # Echo the close (with its code, if any) and finish. Bytes
                    # after a close frame are the client's problem.
                    var echo_body = List[UInt8]()
                    if len(payload) >= 2:
                        echo_body.append(payload[0])
                        echo_body.append(payload[1])
                    var echo = encode_ws_frame(WS_OP_CLOSE, Span(echo_body))
                    for j in range(len(echo)):
                        res.reply.append(echo[j])
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
                for j in range(plen):
                    self.frag_payload.append(payload[j])
                if fin:
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
            for j in range(i, n):
                rest.append(self.buffer[j])
            self.buffer = rest^
        return res^
