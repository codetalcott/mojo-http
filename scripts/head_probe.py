#!/usr/bin/env python3
"""Is the head on the wire the one the application sent? (SPEC A21, K12, L27)

Reads the bare apps' response-head routes, whose handlers send exactly the
headers each case names, so anything else on the wire is the server's: a
`Content-Type` nobody set, a HEAD's `Content-Length` rewritten to 0, a
length on a 204 or 304, a body after a head that may carry none.

Each case goes out on a keep-alive connection of its own and is followed by
a `GET /` on the SAME socket. A body that leaked past a head -- a 204's
bytes, a HEAD answered by a streaming application -- is then the start of
the next response, which does not parse. A head check alone passes a leak:
the leaked bytes arrive after the head it reads.

    python3 scripts/head_probe.py --port 8086 --app wsgi
    python3 scripts/head_probe.py --port 8088 --app asgi [--no-stream-case]

`--no-stream-case` drops the HEAD to a streaming route, the executor's case
(L27): the buffered bridge joins a stream before answering, so there is
nothing for it to leak. Prints one line per failing case, then the verdict.
"""
import argparse
import socket
import sys
import traceback

PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("head_probe FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped

# What `GET /` answers on each bare app: the follow-up must parse to this.
ROOT_TEXT = {"wsgi": b"bare wsgi app", "asgi": b"hello from asgi_bare"}

# (method, path, status, must carry {name: value, or None for "any value"},
#  must NOT carry [names])
CASES = [
    ("GET", "/no-content-type", 200, {"content-length": None}, ["content-type"]),
    ("GET", "/redirect", 303, {"location": "/"}, ["content-type"]),
    ("GET", "/nocontent", 204, {},
     ["content-length", "content-type", "transfer-encoding"]),
    # Django's CommonMiddleware shape: its length and its seven bytes must
    # both stay off the wire, which only the follow-up request can see.
    ("GET", "/nocontent-cl", 204, {}, ["content-length", "transfer-encoding"]),
    ("GET", "/notmodified", 304, {"etag": '"v1"'},
     ["content-length", "content-type", "transfer-encoding"]),
    ("GET", "/notmodified-cl", 304, {"etag": '"v1"', "content-length": "12345"},
     ["content-type"]),
    ("HEAD", "/sized", 200, {"content-length": "12345"}, ["transfer-encoding"]),
]
ASGI_ONLY = [
    # L27: a HEAD to a streaming route is its head and nothing else; the
    # application sent no length, so none is invented.
    ("HEAD", "/stream?size=10000&piece=1000", 200,
     {"content-type": "application/octet-stream"},
     ["content-length", "transfer-encoding"]),
]

# Headers whose repetition is itself a framing defect (RFC 9112 §6.3).
SINGLE = ("content-length", "transfer-encoding", "content-type")


class Conn:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.buf = b""

    def close(self):
        self.sock.close()

    def _fill(self):
        data = self.sock.recv(65536)
        if not data:
            raise EOFError("the server closed the connection with %d bytes "
                           "unread: %r" % (len(self.buf), self.buf[:24]))
        self.buf += data

    def read_until(self, marker, limit=65536):
        while marker not in self.buf:
            if len(self.buf) > limit:
                raise ValueError("no %r in the first %d bytes: %r"
                                 % (marker, limit, self.buf[:120]))
            self._fill()
        i = self.buf.index(marker) + len(marker)
        out, self.buf = self.buf[:i], self.buf[i:]
        return out

    def read_exact(self, n):
        while len(self.buf) < n:
            self._fill()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def request(self, method, path):
        self.sock.sendall(("%s %s HTTP/1.1\r\nHost: localhost\r\n\r\n"
                           % (method, path)).encode("latin-1"))

    def response(self, method):
        """Status, header pairs and body, read exactly as the framing says."""
        head = self.read_until(b"\r\n\r\n")
        lines = head[:-4].split(b"\r\n")
        parts = lines[0].decode("latin-1").split(" ", 2)
        if len(parts) < 2 or not parts[0].startswith("HTTP/1.") \
                or not parts[1].isdigit():
            raise ValueError("not a status line: %r" % lines[0][:120])
        status = int(parts[1])
        headers = []
        for line in lines[1:]:
            name, sep, value = line.decode("latin-1").partition(":")
            if not sep:
                raise ValueError("not a header line: %r" % line[:120])
            headers.append((name.strip().lower(), value.strip()))
        first = {}
        for name, value in headers:
            first.setdefault(name, value)
        if method == "HEAD" or 100 <= status < 200 or status in (204, 304):
            body = b""
        elif "chunked" in first.get("transfer-encoding", "").lower():
            body = b""
            while True:
                size = int(self.read_until(b"\r\n")[:-2].split(b";")[0], 16)
                if size == 0:
                    self.read_until(b"\r\n")
                    break
                body += self.read_exact(size)
                self.read_exact(2)
        elif "content-length" in first:
            body = self.read_exact(int(first["content-length"]))
        else:
            raise ValueError("status %d with neither Content-Length nor "
                             "chunking: the connection cannot be reused" % status)
        return status, headers, body


def check(port, app, case):
    """The problems with one case, as a list of strings; empty means clean."""
    method, path, want_status, must, must_not = case
    phase("%s %s" % (method, path))
    problems = []
    c = None
    try:
        c = Conn(port)
        c.request(method, path)
        status, headers, _ = c.response(method)
        names = [n for n, _ in headers]
        if status != want_status:
            problems.append("status %d, want %d" % (status, want_status))
        for name, value in must.items():
            got = [v for n, v in headers if n == name]
            if not got:
                problems.append("no %s" % name)
            elif value is not None and got[0] != value:
                problems.append("%s: %s, want %s" % (name, got[0], value))
        for name in must_not:
            for n, v in headers:
                if n == name:
                    problems.append("%s: %s must not be on the wire" % (name, v))
        for name in SINGLE:
            if names.count(name) > 1:
                problems.append("%s appears %d times" % (name, names.count(name)))
        phase("GET / after %s %s" % (method, path))
        c.request("GET", "/")
        status, _, body = c.response("GET")
        if status != 200 or body != ROOT_TEXT[app]:
            problems.append("the next response on the connection was %d %r: "
                            "the case's bytes did not end at its head"
                            % (status, body[:60]))
    except (OSError, EOFError, ValueError) as exc:
        problems.append("%s: %r" % (PHASE, exc))
    finally:
        if c is not None:
            c.close()
    return problems


def main():
    phase("arguments")
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--app", choices=sorted(ROOT_TEXT), required=True)
    ap.add_argument("--no-stream-case", action="store_true",
                    help="skip the HEAD to a streaming route (the executor's)")
    args = ap.parse_args()
    cases = list(CASES)
    if args.app == "asgi" and not args.no_stream_case:
        cases += ASGI_ONLY
    failed = 0
    for case in cases:
        problems = check(args.port, args.app, case)
        if problems:
            failed += 1
            print("head_probe FAIL: %s %s: %s"
                  % (case[0], case[1], "; ".join(problems)))
    if failed:
        print("head_probe: %d of %d cases FAILED (%s, port %d)"
              % (failed, len(cases), args.app, args.port))
        return 1
    print("head_probe OK: %d cases (%s, port %d)" % (len(cases), args.app, args.port))
    return 0


if __name__ == "__main__":
    sys.exit(main())
