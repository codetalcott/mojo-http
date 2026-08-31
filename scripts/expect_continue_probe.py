#!/usr/bin/env python3
"""`Expect: 100-continue` — RFC 9110 §10.1.1, both directions.

A11 was `implemented` with the sheet's own note that "no test or smoke
exercises it". Gating it found two defects, which is the third time in this
repo that gating an ungated mechanism has.

**The mechanism, and why the two halves both matter.** A client with a large
body sends its headers with `Expect: 100-continue` and WAITS. The server
either invites the body (`100 Continue`) or refuses outright — which is the
entire point: a 1 GB upload the server will reject should be rejected before
it is sent, not after. So a gate has to assert both that the invitation
arrives when it should and that it does NOT when it should not; a server
that answers 100 Continue to everything would pass a one-sided test while
throwing away the mechanism's only benefit.

What was wrong, both measured against a running server before being fixed:

- **The expectation-name was compared exactly.** §10.1.1 says it is
  case-insensitive, and `100-Continue` — the capitalisation most
  documentation uses — got SILENCE. A client then waits out its own timeout
  (curl: one second) and sends anyway, so it presents as latency rather than
  breakage, which is why nothing noticed.
- **HTTP/1.0 clients were sent 100 Continue.** §10.1.1: a server MUST NOT.
  HTTP/1.0 has no 1xx, so that client reads the interim response as THE
  response and the real one behind it as garbage.

Deliberately NOT asserted: an unknown expectation is answered with silence
and the request served. §10.1.1 says a server MAY answer 417 there; MAY is
not MUST, and pinning a permitted behaviour as required is how a gate starts
blocking legitimate change.

    python3 scripts/expect_continue_probe.py PORT

Exits 0 on success, 1 naming the rule that broke.
"""

import socket
import sys
import time
import traceback

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8404
PATH = "/input/read"
# Long enough that a server which simply never answers is distinguishable
# from one that answers late; short enough not to pad the smoke.
WAIT = 1.5


PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("expect_continue FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fail(msg):
    print("expect_continue FAIL:", msg)
    sys.exit(1)


def ask(expect_hdr, proto="HTTP/1.1", body=b"hello", declared=None):
    """Send headers and WAIT. Returns (interim_bytes, final_status).

    Not sending the body until the server has spoken is what makes this a
    test of the mechanism rather than of the response: a server that ignores
    Expect entirely still answers 200 once the body arrives.
    """
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    length = len(body) if declared is None else declared
    head = "POST %s %s\r\nHost: x\r\n" % (PATH, proto)
    if expect_hdr is not None:
        head += "Expect: %s\r\n" % expect_hdr
    head += "Content-Length: %d\r\nContent-Type: text/plain\r\n\r\n" % length
    sock.sendall(head.encode())

    sock.settimeout(WAIT)
    interim = b""
    try:
        interim = sock.recv(4096)
    except socket.timeout:
        pass

    final = ""
    try:
        sock.sendall(body)
        sock.settimeout(6)
        buf = interim
        deadline = time.time() + 6
        while time.time() < deadline:
            want = 2 if b"100 Continue" in interim else 1
            if buf.count(b"HTTP/1.") >= want and b"\r\n\r\n" in buf:
                break
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
        pieces = [p for p in buf.split(b"HTTP/1.") if p.strip()]
        if pieces:
            final = "HTTP/1." + pieces[-1].split(b"\r\n", 1)[0].decode(
                "latin-1", "replace"
            ).strip()
    except OSError:
        pass
    try:
        sock.close()
    except OSError:
        pass
    return interim, final


def got_continue(interim):
    return b"100 Continue" in interim


def main():
    # --- the invitation arrives, whatever the case of the name -------------
    for name in ("100-continue", "100-Continue", "100-CONTINUE"):
        phase("Expect: %s must be invited (the name is case-insensitive)" % name)
        interim, final = ask(name)
        if not got_continue(interim):
            fail(
                "`Expect: %s` was answered with %r instead of 100 Continue. "
                "RFC 9110 §10.1.1 makes the expectation-name case-insensitive, "
                "and a client that is not invited waits out its own timeout "
                "before sending the body anyway -- latency, not breakage, "
                "which is why this went unnoticed"
                % (name, interim[:40] or b"silence")
            )
        if "200" not in final:
            fail("`Expect: %s` was invited but the request then failed: %s"
                 % (name, final))

    # --- and NOT to a client that must not receive it ----------------------
    phase("an HTTP/1.0 client must NOT be sent 100 Continue")
    interim, final = ask("100-continue", proto="HTTP/1.0")
    if got_continue(interim):
        fail(
            "an HTTP/1.0 client was sent 100 Continue. RFC 9110 §10.1.1 says "
            "a server MUST NOT: 1.0 has no 1xx, so the client reads the "
            "interim response as THE response and the real one behind it as "
            "garbage"
        )

    phase("a request with no Expect header must NOT be sent 100 Continue")
    interim, _ = ask(None)
    if got_continue(interim):
        fail(
            "100 Continue was sent to a request that never asked for it. A "
            "server that answers it unconditionally would pass the first "
            "half of this probe while throwing the mechanism away"
        )

    # --- the refusal, which is the whole point of asking first -------------
    phase("an oversized body is refused BEFORE it is invited")
    interim, final = ask("100-continue", body=b"x" * 10, declared=99_000_000)
    if got_continue(interim):
        fail(
            "a body over `max_request_body_size` was INVITED with 100 "
            "Continue. Refusing after the upload is exactly what asking "
            "first exists to avoid"
        )
    if "413" not in (interim.decode("latin-1", "replace") + final):
        fail(
            "an oversized body with Expect got %r / %s, want 413 before the "
            "body is sent" % (interim[:40], final or "no final response")
        )

    print("expect_continue OK: invited on any case, refused to HTTP/1.0 and "
          "to the unasked, and an oversized body refused before the upload")


if __name__ == "__main__":
    main()
