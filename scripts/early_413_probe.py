#!/usr/bin/env python3
"""A 413 sent before the body is read must reach a client still uploading.

The server refuses an oversized body as soon as it knows the size: at the
headers for a `Content-Length`, partway through for a chunked body. The
client is still uploading at that moment, and most clients do not read
until they have finished writing -- `http.client`, and so `urllib` and
`requests`, send the whole body before calling `getresponse`. Closing the
socket then, with the rest of the body unread in its receive buffer, makes
the kernel answer with RST rather than FIN: the client's next write fails
with EPIPE or ECONNRESET, and the 413 already in its receive buffer is
discarded with the connection. Found from outside: a Flask app served by
m0serve 1.5.0 answered `http.client` with `BrokenPipeError` where
Werkzeug's own server answered 413.

RFC 9112 §9.6 describes the cure, which nginx calls a lingering close:
half-close the write side after the response, keep reading and discarding
until the client closes or a bound expires, then close. This probe pins
the refusal's shape (phase 0: `Connection: close`, and a FIN at once),
that the 413 is READABLE (phases 1-4), that the linger is BOUNDED (phase
5, which trickles past the bound so that a deadline re-armed per read
would never expire), and that the deadline's close is clean for a client
that reads late (phase 6).

Everything it asserts holds on both kernels, so both CI legs run it. The
two rules that exist for epoll's edge trigger -- drain at the refusal,
re-register a spent budget -- cannot be made to fail on demand, and the
code says why beside each (`_reject_and_linger`, `_linger_discard`).

usage: early_413_probe.py PORT [LIMIT_BYTES] [LINGER_S]
"""
import http.client
import socket
import sys
import threading
import time
import traceback

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
LIMIT = int(sys.argv[2]) if len(sys.argv) > 2 else 4 * 1024 * 1024
LINGER_S = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0
OVER = LIMIT + 1024 * 1024
ROUNDS = 5
CONCURRENT = 8
TIMEOUT_S = 30

# Which phase is running, for the crash handler below. A traceback names
# the call that raised, which several phases share; the phase is what says
# which property failed (apps/asgi_bare/ws_probe.py has the original).
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("early_413_probe: FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fail(msg):
    print("early_413_probe: FAIL: %s: %s" % (PHASE, msg))
    sys.exit(1)


def connect():
    s = socket.create_connection(("127.0.0.1", PORT), timeout=TIMEOUT_S)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def read_to_close(s):
    """Everything the server sends until it stops sending."""
    data = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            return data
        data += chunk


def status_of(data):
    line = data.split(b"\r\n", 1)[0]
    parts = line.split(b" ", 2)
    if len(parts) < 2 or not parts[0].startswith(b"HTTP/1."):
        return None
    return int(parts[1])


def content_length_request():
    head = (b"POST /health HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
            % OVER)
    return head + b"x" * OVER


def chunked_request():
    piece = b"y" * 65536
    n = OVER // len(piece) + 1
    body = (b"%x\r\n%s\r\n" % (len(piece), piece)) * n + b"0\r\n\r\n"
    head = (b"POST /health HTTP/1.1\r\nHost: x\r\n"
            b"Transfer-Encoding: chunked\r\n\r\n")
    return head + body


def send_whole_then_read(request):
    """The client shape that lost the 413: every byte out, then read."""
    s = connect()
    try:
        s.sendall(request)
        return status_of(read_to_close(s))
    finally:
        s.close()


def expect_413(label, request):
    got = send_whole_then_read(request)
    if got != 413:
        fail("%s: expected 413, got %r" % (label, got))


def main():
    phase("0: the early 413 says the connection is closing")
    # The connection ends after this response, and a response that says
    # `keep-alive` there invites a client to send its next request down a
    # socket that is closing (RFC 9112 §9.6: a server's final response on
    # a connection SHOULD carry `close`). Headers only; nothing to upload.
    # Its FIN follows at once, too: the write side is shut behind the
    # refusal while the read side lingers, so a client that reads to EOF
    # is not left waiting out the linger for an answer it already has.
    s = connect()
    s.sendall(b"POST /health HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
              % OVER)
    s.settimeout(3)
    try:
        head = read_to_close(s)
    except socket.timeout:
        fail("no FIN within 3 s of the 413: the write side is not shut")
    finally:
        s.close()
    if status_of(head) != 413:
        fail("expected the 413 at the headers, got %r" % head[:60])
    fields = head.split(b"\r\n\r\n", 1)[0].lower().split(b"\r\n")[1:]
    if b"connection: close" not in fields:
        fail("the 413 does not say `Connection: close`: %r" % head[:200])

    phase("1: Content-Length over the cap, whole body sent before reading")
    for _ in range(ROUNDS):
        expect_413("content-length", content_length_request())

    phase("2: chunked over the cap, whole body sent before reading")
    for _ in range(ROUNDS):
        expect_413("chunked", chunked_request())

    phase("3: http.client, the shape urllib and requests share")
    for _ in range(ROUNDS):
        c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=TIMEOUT_S)
        try:
            c.request("POST", "/health", b"z" * OVER)
            r = c.getresponse()
            if r.status != 413:
                fail("http.client: expected 413, got %d" % r.status)
            r.read()
        finally:
            c.close()

    phase("4: %d concurrent uploads over the cap" % CONCURRENT)
    errors = []
    request = content_length_request()

    def one():
        try:
            got = send_whole_then_read(request)
            if got != 413:
                errors.append("got %r" % got)
        except Exception as e:  # noqa: BLE001 - a reset IS the failure
            errors.append(repr(e))

    threads = [threading.Thread(target=one) for _ in range(CONCURRENT)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if errors:
        fail("%d of %d: %s" % (len(errors), CONCURRENT, errors[0]))

    phase("5: the linger is bounded against a client that never finishes")
    # Declare far more than will ever be sent, read the 413 (it is sent at
    # the headers), then keep trickling. The server must close within the
    # linger plus the once-a-second sweep that reaps it, however long the
    # client keeps going: a deadline re-armed per read would never expire.
    s = connect()
    s.sendall(b"POST /health HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
              % (64 * LIMIT))
    s.settimeout(5)
    head = s.recv(65536)
    if status_of(head) != 413:
        fail("expected the 413 at the headers, got %r" % head[:60])
    t0 = time.monotonic()
    bound = LINGER_S + 2.5
    closed_after = None
    while time.monotonic() - t0 < bound + 10:
        try:
            s.send(b"t" * 1024)
        except OSError:
            closed_after = time.monotonic() - t0
            break
        time.sleep(0.2)
    s.close()
    if closed_after is None:
        fail("still open %.1f s after the 413; the bound is %.1f s"
             % (bound + 10, bound))
    if closed_after > bound:
        fail("closed %.1f s after the 413; the bound is %.1f s"
             % (closed_after, bound))
    print("early_413_probe: linger closed %.1f s after the 413" % closed_after)

    phase("6: %d clients that stop sending and read after the linger ends"
          % CONCURRENT)
    # Headers and 32 KB of the body in one write, then nothing until the
    # linger is over. The server closes at the deadline either way; what
    # decides whether the 413 survives is whether it had read everything
    # by then, because an unread byte turns the close into RST, and RST
    # discards the 413 the client has not read yet. The only phase where
    # the DEADLINE ends the linger with a response still unread: a linger
    # that stops reading fails it 8 of 8 (sabotage-verified). What makes
    # the buffered bytes readable again after the refusal read only the
    # headers is covered twice -- the refusal drains at once, and on
    # Linux its own SHUT_WR wakes epoll as well (measured) -- so removing
    # either alone passes here.
    errors = []
    partial = (b"POST /health HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
               % OVER) + b"p" * 32768

    def slow():
        try:
            s = connect()
            try:
                s.sendall(partial)
                time.sleep(LINGER_S + 2.5)
                got = status_of(read_to_close(s))
                if got != 413:
                    errors.append("got %r" % got)
            finally:
                s.close()
        except Exception as e:  # noqa: BLE001 - a reset IS the failure
            errors.append(repr(e))

    threads = [threading.Thread(target=slow) for _ in range(CONCURRENT)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if errors:
        fail("%d of %d: %s" % (len(errors), CONCURRENT, errors[0]))

    phase("7: the server still answers")
    s = connect()
    s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    got = status_of(read_to_close(s))
    s.close()
    if got != 200:
        fail("expected 200, got %r" % got)

    print("early_413_probe: OK")


if __name__ == "__main__":
    main()
