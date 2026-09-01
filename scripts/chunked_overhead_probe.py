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
import time
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


def attempt_split(port, chunks, first_frames):
    """Head, then the body in TWO writes with a pause between them.

    A third arrival shape, split so the first write stays just under the raw
    ceiling and the second crosses it. It is NOT what pins either bound: the
    pre-decode check's buffer-size half already refuses this, which was
    established by reverting each bound in turn and watching this phase pass
    both ways. It is here because it is a shape a real client produces and
    the two decode sites treat differently, so a future change to either can
    be seen to keep it working -- not because it discriminates a rule today.
    """
    head = (
        b"POST /input/read HTTP/1.1\r\nHost: x\r\n"
        b"Transfer-Encoding: chunked\r\nContent-Type: text/plain\r\n\r\n"
    )
    frames = [b"%x\r\n" % len(c) + c + b"\r\n" for c in chunks]
    raw = sum(len(f) for f in frames)
    s = socket.create_connection(("127.0.0.1", port), timeout=15)
    try:
        s.sendall(head + b"".join(frames[:first_frames]))
        time.sleep(0.25)
        s.sendall(b"".join(frames[first_frames:]) + b"0\r\n\r\n")
    except (BrokenPipeError, ConnectionResetError):
        pass
    return _read_status(s), raw


def _read_status(s):
    try:
        s.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    data = b""
    try:
        while True:
            c = s.recv(65536)
            if not c:
                break
            data += c
    except (socket.timeout, ConnectionResetError, OSError):
        pass
    s.close()
    return data.split(b"\r\n")[0].decode("latin-1", "replace")


def attempt(port, chunks, one_write=False):
    """(status line, raw bytes sent). Tolerates the server answering early.

    `one_write` puts the headers and the whole body in a SINGLE `sendall`.
    That is not a stylistic choice: chunked bodies are decoded at two sites,
    and which one runs depends on whether the body arrives with its headers.
    Pacing the writes reaches the READING_BODY path; one write reaches the
    inline path, which had no body bound at all. Whether a limit applied came
    down to how the client's writes happened to be coalesced, and 512 separate
    6-byte writes coalesce differently on a loaded CI runner than on a laptop
    -- which is how this passed everywhere for as long as it did.
    """
    head = (
        b"POST /input/read HTTP/1.1\r\nHost: x\r\n"
        b"Transfer-Encoding: chunked\r\nContent-Type: text/plain\r\n\r\n"
    )
    body = b"".join(b"%x\r\n" % len(c) + c + b"\r\n" for c in chunks)
    raw = len(body)
    s = socket.create_connection(("127.0.0.1", port), timeout=15)
    try:
        if one_write:
            s.sendall(head + body + b"0\r\n\r\n")
        else:
            s.sendall(head)
            for c in chunks:
                s.sendall(b"%x\r\n" % len(c) + c + b"\r\n")
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
    payload = [b"x"] * (cap // 2)
    for one_write, how in ((False, "paced, one write per chunk"),
                           (True, "head and body in ONE write")):
        phase("one-byte chunks over the raw ceiling (%s)" % how)
        line, raw = attempt(port, payload, one_write=one_write)
        print(f"  one-byte chunks [{how}]: decoded {len(payload)}, "
              f"raw {raw} -> {line}")
        if raw <= 2 * cap:
            failures.append(
                f"the probe never exceeded the raw ceiling (raw {raw}, ceiling "
                f"{2 * cap}) — it is not testing what it claims"
            )
        elif "413" not in line:
            failures.append(
                f"[{how}] a body of {len(payload)} decoded bytes (legal) "
                f"costing {raw} raw bytes (over the {2 * cap} ceiling) answered "
                f"{line!r}, want 413 — the raw bound is not enforced, so "
                "framing is unbounded"
            )

    # The split case: under the ceiling on the first write, over it on the
    # second. Only a bound tested AFTER the decode can refuse this one.
    phase("one-byte chunks over the ceiling, crossed by the second write")
    # The first write must land JUST UNDER the ceiling: that is what makes
    # the second read's pre-decode check pass, so only a check after the
    # decode can refuse the body the second write completes. Each frame
    # of a one-byte chunk is 6 bytes on the wire.
    under_ceiling = (2 * cap) // 6 - 1
    line, raw = attempt_split(port, payload, first_frames=under_ceiling)
    print(f"  one-byte chunks [crossed by the 2nd write]: "
          f"decoded {len(payload)}, raw {raw} -> {line}")
    if "413" not in line:
        failures.append(
            f"[crossed by the 2nd write] a body costing {raw} raw bytes (over "
            f"the {2 * cap} ceiling) answered {line!r}, want 413 — the bound is "
            "tested before the decode that crosses it, so the body that "
            "crosses it is never measured"
        )

    for f in failures:
        print(f"FAIL: {f}")
    if failures:
        sys.exit(1)
    print("chunked overhead OK: the raw ceiling refuses a legally-sized body")


if __name__ == "__main__":
    main()
