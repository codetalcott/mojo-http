"""Reproduce the inbound ASGI WebSocket message loss (ROADMAP, Known issues).

NOT a gate -- it reproduces a known defect and reports a number, so it is
deliberately not wired into CI and deliberately has no assertion. Turning it
into `smoke-ws-inbound` is the last step of fixing the defect, not a step
before it.

Sends N messages of SIZE bytes down one WebSocket WITHOUT reading, then reads
back and counts the echoes. Not reading is what reproduces it: the app awaits
`send` inside its `receive` loop, so a stalled client blocks that send on its
outbound credit window, which stops the app calling `receive`, which stops the
executor draining the submit channel that inbound messages ride. The loop then
discards each further message with a log line the client never sees.

    python3 scripts/ws_inbound_loss_repro.py 200 4096
    -> sent 200 inbound messages of 4096B, got 80 echoes back (120 lost)

Pass a small SIZE (64) or run scripts/ws_inbound_loss_repro.py with a
concurrently-reading client to see it NOT reproduce; both were measured.
"""
import base64, os, socket, struct, subprocess, sys, time

PORT = 8331
N = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
SIZE = int(sys.argv[2]) if len(sys.argv) > 2 else 64
LOG = os.environ.get("M0_REPRO_LOG", "ws_inbound_loss.log")

log = open(LOG, "w")
srv = subprocess.Popen(["./bin/m0serve", "bareapp.asgi:application",
                        "--app-dir", "apps/asgi_bare", "--port", str(PORT)],
                       stdout=log, stderr=subprocess.STDOUT)
try:
    for _ in range(300):
        try:
            socket.create_connection(("127.0.0.1", PORT), timeout=0.5).close(); break
        except OSError: time.sleep(0.1)
    time.sleep(0.5)

    s = socket.create_connection(("127.0.0.1", PORT), timeout=30)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(("GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n" % key).encode())
    head = b""
    while b"\r\n\r\n" not in head: head += s.recv(4096)
    assert b" 101 " in head.split(b"\r\n", 1)[0], head[:100]

    def frame(op, p):
        m = os.urandom(4)
        hdr = bytes([0x80 | op])
        if len(p) < 126: hdr += bytes([0x80 | len(p)])
        else: hdr += bytes([0x80 | 126]) + struct.pack(">H", len(p))
        return hdr + m + bytes(b ^ m[i % 4] for i, b in enumerate(p))

    # Blast without reading: the loop parses frames as fast as they arrive
    # and pushes each at the executor's submit channel, which has no
    # inbound credit gate of any kind.
    payload = b"m" * SIZE
    burst = b"".join(frame(0x1, payload) for _ in range(N))
    s.sendall(burst)

    # Now read the echoes back. The app answers each with "echo:" + text.
    s.settimeout(20)
    got, buf = 0, b""
    deadline = time.time() + 40
    while got < N and time.time() < deadline:
        try: chunk = s.recv(1 << 20)
        except socket.timeout: break
        if not chunk: break
        buf += chunk
        # count complete server frames (unmasked)
        i = 0
        while i + 2 <= len(buf):
            ln = buf[i + 1] & 0x7F
            hdr = 2
            if ln == 126:
                if i + 4 > len(buf): break
                ln = struct.unpack(">H", buf[i+2:i+4])[0]; hdr = 4
            elif ln == 127:
                if i + 10 > len(buf): break
                ln = struct.unpack(">Q", buf[i+2:i+10])[0]; hdr = 10
            if i + hdr + ln > len(buf): break
            if buf[i] & 0x0F == 0x1: got += 1
            i += hdr + ln
        buf = buf[i:]
    print("sent %d inbound messages of %dB, got %d echoes back (%d lost)"
          % (N, SIZE, got, N - got))
    s.close()
finally:
    srv.terminate()
    try: srv.wait(timeout=10)
    except subprocess.TimeoutExpired: srv.kill()
    log.close()
lost = [l for l in open(LOG) if "it is lost" in l]
print("server logged %d lost-inbound-message lines" % len(lost))
for l in lost[:2]: print("   ", l.strip())
