"""A chunked body whose FRAMING outweighs its payload must be refused.

    python3 scripts/chunked_overhead_probe.py PORT MAX_BODY

`max_request_body_size` caps what the application receives. It does not cap
what the connection COST: framing is consumed and dropped as it is decoded, so
a body of one-byte chunks is six bytes on the wire for every byte delivered,
and the decoded cap alone leaves the raw stream bounded only by the abuse-ratio
guard -- which needs 100 KB of charged overhead before it can fire. The second
bound is `chunk_decoder._total_read > 2 * max_request_body_size`, in
`event_loop.mojo` and `server.mojo`.

Nothing exercised it. The unit suite covers the ratio guard
(`test_a_body_that_is_mostly_framing_still_trips_the_abuse_guard`) and the
chunk-size limits, all of which live inside the decoder; this bound lives in
the connection and needs a socket.

Three shapes, and the middle one is the assertion:

    one 400 B chunk         decoded 400, raw ~407   -> 200
    400 one-byte chunks     decoded 400, raw ~2226  -> 413   <-- decoded is LEGAL
    900 one-byte chunks     decoded 900, raw ~5400  -> 413

The middle case is the whole point: its decoded size is under the cap, so only
the raw bound can refuse it. Delete that bound and it becomes a 200.

The server answers and closes while the client is still writing, so a
BrokenPipeError partway through is expected rather than a failure -- the
response is already in the socket. Reading after the write fails is what makes
this probe see a 413 where a naive one sees only a broken pipe.
"""

import socket
import sys
import traceback


# Which phase is running, for the crash handler below. A traceback names the
# CALL that raised -- here `attempt`, which both phases share -- and never the PHASE being proven.
# apps/asgi_bare/ws_probe.py carries the original of this comment and the
# 2026-08-30 failure that motivated it.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("chunked overhead FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def attempt(port, chunks):
    """(status line, raw bytes sent). Tolerates the server answering early."""
    s = socket.create_connection(("127.0.0.1", port), timeout=15)
    s.sendall(
        b"POST /input/read HTTP/1.1\r\nHost: x\r\n"
        b"Transfer-Encoding: chunked\r\nContent-Type: text/plain\r\n\r\n"
    )
    raw = 0
    try:
        for c in chunks:
            frame = b"%x\r\n" % len(c) + c + b"\r\n"
            raw += len(frame)
            s.sendall(frame)
        s.sendall(b"0\r\n\r\n")
    except (BrokenPipeError, ConnectionResetError):
        pass  # answered and closed mid-write; the response is already queued
    try:
        s.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    data = b""
    try:
        while True:
            got = s.recv(4096)
            if not got:
                break
            data += got
    except OSError:
        pass
    s.close()
    text = data.decode("latin-1", "replace")
    return (text.splitlines()[0] if text else "<no response>"), raw


def main():
    port = int(sys.argv[1])
    cap = int(sys.argv[2])
    failures = []

    # Under both caps: the control. If this is not a 200 the probe is wrong
    # about the server rather than the server being wrong.
    phase("the control: an ordinary chunked body under both caps")
    line, raw = attempt(port, [b"x" * (cap // 2)])
    print(f"  ordinary chunk: decoded {cap // 2}, raw {raw} -> {line}")
    if "200" not in line:
        failures.append(f"an ordinary chunked body under the cap answered {line!r}")

    # Decoded UNDER the cap, raw OVER twice it. Only the raw bound can refuse.
    phase("one-byte chunks: decoded under the cap, raw over twice it")
    payload = [b"x"] * (cap // 2)
    line, raw = attempt(port, payload)
    print(f"  one-byte chunks: decoded {len(payload)}, raw {raw} -> {line}")
    if raw <= 2 * cap:
        failures.append(
            f"the probe never exceeded the raw ceiling (raw {raw}, ceiling "
            f"{2 * cap}) — it is not testing what it claims"
        )
    elif "413" not in line:
        failures.append(
            f"a body of {len(payload)} decoded bytes (legal) costing {raw} raw "
            f"bytes (over the {2 * cap} ceiling) answered {line!r}, want 413 — "
            "the raw bound is not enforced, so framing is unbounded"
        )

    for f in failures:
        print(f"FAIL: {f}")
    if failures:
        sys.exit(1)
    print("chunked overhead OK: the raw ceiling refuses a legally-sized body")


if __name__ == "__main__":
    main()
