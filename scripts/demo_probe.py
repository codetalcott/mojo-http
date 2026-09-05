"""The live demo (apps/demo, https://demo.m0serve.dev), proven from outside.

    python3 scripts/demo_probe.py --image --wheel-dir dist/wheels   # the tree's wheel (CI)
    python3 scripts/demo_probe.py --image --version 0.17.0          # a PyPI release
    python3 scripts/demo_probe.py --url http://127.0.0.1:8190       # a running server
    python3 scripts/demo_probe.py --url https://demo.m0serve.dev    # the live deploy

`--image` builds deploy/demo/Dockerfile from the repository root exactly as
`fly deploy` does, starts it with a published port, and adds the container
phases -- m0serve is PID 1 by `/proc/1/cmdline`, and `docker stop` is the
drain's exit 0 inside its grace. `--url` runs the HTTP phases alone against
whatever is listening there, which is how the deploy workflow verifies the
live site and how a developer checks `poe serve-demo`.

What the HTTP phases assert, each the demo's own promise rather than the
server's (those are I11, I12 and I20):

  * the page answers 200, hands a first visitor a token cookie and names the
    m0serve version that `/about` reports;
  * without the cookie, the hold views refuse (403) rather than hold an
    anonymous connection, and a WebSocket upgrade from a foreign Origin is
    refused too;
  * an SSE hold is subscribed: the head is the view's `hello` event naming
    the worker that holds it;
  * one HTTP publish reaches a SECOND stream on the same visitor's channel
    and NOT a stranger's stream, which hears only heartbeat comments for a
    measured silence -- the isolation check, and one of the two sabotages;
  * a WebSocket upgrade is a real 101 (accept key verified), a text frame
    sent on it comes back to the socket AND to the visitor's streams marked
    `via websocket`, and the stranger still hears nothing;
  * the limits: a message over the size cap is 413, and a burst of publishes
    meets a 429 with `Retry-After` inside the window the limit implies --
    none within the first LIMIT attempts (the limit is per worker, and no
    worker can have seen more than LIMIT of them), at least one within
    workers*LIMIT+1 -- the other sabotage.

Needs docker for `--image`; on a Mac, colima, where `--platform linux/arm64`
keeps a cached amd64 base image from being picked (the x86-64-v2 binary
SIGFPEs under emulation). Timings are recorded through `scripts/emit.py` (a
no-op outside CI).
"""

import argparse
import base64
import glob
import hashlib
import http.client
import json
import os
import re
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import time
import traceback
import urllib.parse
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from emit import emit  # noqa: E402

WHEELHOUSE = REPO / "deploy" / "demo" / "wheelhouse"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
COOKIE = "m0demo"

# The probe phase stamp (scripts/phase_stamp_check.py): every phase reaches
# the server through the same helpers, so an unhandled error inside one would
# name the call that failed and never the phase being proven.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name
    print(f"--- {name}")


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("demo_probe: FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fail(msg):
    sys.exit(f"demo_probe: FAIL: {PHASE}: {msg}")


def run(*argv, check=True, timeout=600, **kw):
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd=REPO, **kw)
    if check and proc.returncode != 0:
        fail(f"`{' '.join(argv)}` exited {proc.returncode}:\n{proc.stdout[-2000:]}\n{proc.stderr[-2000:]}")
    return proc


def logs(name):
    p = run("docker", "logs", name, check=False)
    return (p.stdout + p.stderr)[-3000:]


# --- HTTP helpers --------------------------------------------------------------


class Target:
    """Where the demo is: scheme, host, port, and how to open a connection."""

    def __init__(self, base):
        u = urllib.parse.urlsplit(base)
        self.base = base.rstrip("/")
        self.tls = u.scheme == "https"
        self.host = u.hostname
        self.port = u.port or (443 if self.tls else 80)
        self.hostport = u.netloc

    def conn(self, timeout=10):
        if self.tls:
            return http.client.HTTPSConnection(self.host, self.port, timeout=timeout)
        return http.client.HTTPConnection(self.host, self.port, timeout=timeout)

    def raw_socket(self, timeout=10):
        sock = socket.create_connection((self.host, self.port), timeout=timeout)
        if self.tls:
            sock = ssl.create_default_context().wrap_socket(sock, server_hostname=self.host)
        return sock


def request(t, method, path, body=None, headers=None, cookie=None):
    """(status, headers-lowercased, body bytes) for one closed request."""
    h = dict(headers or {})
    if cookie:
        h["Cookie"] = f"{COOKIE}={cookie}"
    c = t.conn()
    c.request(method, path, body, h)
    r = c.getresponse()
    data = r.read()
    out = {k.lower(): v for k, v in r.getheaders()}
    # Several Set-Cookie lines would fold; the demo sets one.
    c.close()
    return r.status, out, data


def expect(t, method, path, status, cookie=None, body=None, headers=None):
    code, h, data = request(t, method, path, body=body, headers=headers, cookie=cookie)
    if code != status:
        fail(f"{method} {path}: want {status}, got {code}: {data[:200]!r}")
    return h, data


class Stream:
    """One held SSE connection, read event by event, with a silence check.

    Raw socket, own framing: http.client hands the socket to the response
    on a close-delimited body and hides it, and a stream needs its timeout
    changed per wait. Chunked and close-delimited bodies both work; the
    terminating chunk -- the server ending the stream -- is a failure,
    because nothing here asks for one.
    """

    def __init__(self, t, cookie, path="/events"):
        self.sock = t.raw_socket()
        self.sock.sendall((f"GET {path} HTTP/1.1\r\nHost: {t.hostport}\r\nCookie: {COOKIE}={cookie}\r\n"
                           "Accept: text/event-stream\r\n\r\n").encode())
        raw = b""
        while b"\r\n\r\n" not in raw:
            chunk = self.sock.recv(4096)
            if not chunk:
                fail("connection closed before the stream's headers arrived")
            raw += chunk
        head, _, self.raw = raw.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        self.status = int(lines[0].split()[1])
        self.headers = {k.strip().lower(): v.strip() for k, v in
                        (ln.split(":", 1) for ln in lines[1:] if ":" in ln)}
        self.chunked = "chunked" in self.headers.get("transfer-encoding", "").lower()
        self.worker = self.headers.get("x-worker")
        self.buf = b""
        self._decode()

    def _decode(self):
        """Move what is decodable from the wire buffer into the body buffer."""
        if not self.chunked:
            self.buf += self.raw
            self.raw = b""
            return
        while b"\r\n" in self.raw:
            size_line, rest = self.raw.split(b"\r\n", 1)
            size = int(size_line.split(b";")[0], 16)
            if size == 0:
                fail("the held stream was ended by the server (terminating chunk)")
            if len(rest) < size + 2:
                return
            self.buf += rest[:size]
            self.raw = rest[size + 2:]

    def next_event(self, timeout):
        """The next event's parsed JSON `data`, or None on silence.

        Comment lines (heartbeats) are dropped; a frame with no data is not
        an event.
        """
        deadline = time.monotonic() + timeout
        while True:
            while b"\n\n" in self.buf:
                frame, self.buf = self.buf.split(b"\n\n", 1)
                data = [ln[5:].lstrip(b" ") for ln in frame.split(b"\n") if ln.startswith(b"data:")]
                if data:
                    return json.loads(b"\n".join(data).decode("utf-8"))
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            self.sock.settimeout(remaining)
            try:
                chunk = self.sock.recv(65536)
            except (socket.timeout, TimeoutError):
                return None
            if not chunk:
                fail("the held stream was closed by the server")
            self.raw += chunk
            self._decode()

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def visitor(t):
    """Load the page as a new visitor; return (token, page body, headers)."""
    h, body = expect(t, "GET", "/", 200)
    m = re.search(rf"{COOKIE}=([0-9a-f]{{32}})", h.get("set-cookie", ""))
    if not m:
        fail(f"no {COOKIE} cookie handed to a first visitor: {h.get('set-cookie')!r}")
    return m.group(1), body, h


# --- WebSocket helpers (RFC 6455 spoken raw, as in realtime_probe.py) ----------


def ws_open(t, cookie, origin=None):
    """Handshake; returns (sock, worker) on 101 or (None, status_line, body)."""
    sock = t.raw_socket()
    key = base64.b64encode(os.urandom(16)).decode()
    lines = ["GET /ws HTTP/1.1", f"Host: {t.hostport}", "Upgrade: websocket", "Connection: Upgrade",
             f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13"]
    if cookie:
        lines.append(f"Cookie: {COOKIE}={cookie}")
    if origin:
        lines.append(f"Origin: {origin}")
    sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv(4096)
        if not chunk:
            fail("connection closed during the WebSocket handshake")
        resp += chunk
    head, _, rest = resp.partition(b"\r\n\r\n")
    hlines = head.decode("latin-1").split("\r\n")
    status = hlines[0]
    if " 101 " not in status + " ":
        sock.close()
        return None, status, rest
    accept = worker = None
    for ln in hlines[1:]:
        low = ln.lower()
        if low.startswith("sec-websocket-accept:"):
            accept = ln.split(":", 1)[1].strip()
        if low.startswith("x-worker:"):
            worker = ln.split(":", 1)[1].strip()
        if low.startswith("m0-hold:") or low.startswith("m0-channel:"):
            fail("instruction header leaked to the client: " + ln)
    expected = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    if accept != expected:
        fail("bad Sec-WebSocket-Accept: the handshake was not really performed")
    return sock, worker


def ws_send(sock, opcode, payload):
    mask = os.urandom(4)
    n = len(payload)
    header = bytes([0x80 | opcode])
    if n <= 125:
        header += bytes([0x80 | n])
    elif n <= 0xFFFF:
        header += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", n)
    sock.sendall(header + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(payload)))


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            fail("WebSocket closed wanting %d bytes" % n)
        buf += chunk
    return buf


def ws_read_text(sock, timeout):
    """Next text frame as parsed JSON; pings are answered; None on silence."""
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        sock.settimeout(remaining)
        try:
            hdr = _recv_exact(sock, 2)
        except (socket.timeout, TimeoutError):
            return None
        op, ln = hdr[0] & 0x0F, hdr[1] & 0x7F
        if hdr[1] & 0x80:
            fail("server frame is masked")
        if ln == 126:
            ln = struct.unpack(">H", _recv_exact(sock, 2))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", _recv_exact(sock, 8))[0]
        payload = _recv_exact(sock, ln)
        if op == 0x9:
            ws_send(sock, 0xA, payload)
            continue
        if op == 0x1:
            return json.loads(payload.decode("utf-8"))
        fail("unexpected WebSocket frame op=%d" % op)


def ws_close(sock):
    try:
        ws_send(sock, 0x8, struct.pack(">H", 1000))
        sock.close()
    except OSError:
        pass


# --- the HTTP phases -----------------------------------------------------------


def probe_http(t, silence=2.0, deliver=8.0):
    phase("the page answers and names the server")
    token, page, h = visitor(t)
    if "text/html" not in h.get("content-type", ""):
        fail(f"/ is {h.get('content-type')!r}, not HTML")
    text = page.decode("utf-8", "replace")
    for needle in ('new EventSource("/events")', 'new WebSocket('):
        if needle not in text:
            fail(f"the page does not open {needle}")
    _, about_body = expect(t, "GET", "/about", 200)
    about = json.loads(about_body)
    version = about.get("m0serve", "")
    if not version or f"m0serve {version}" not in text:
        fail(f"the page's version line does not say 'm0serve {version}' (from /about)")
    workers = int(about.get("workers") or 1)
    limit = int(about["limits"]["messages_per_minute_per_worker"])
    max_bytes = int(about["limits"]["message_bytes"])
    print(f"m0serve {version}, {workers} worker(s), limits {limit}/min/worker, {max_bytes} bytes")

    phase("no cookie, no hold; no foreign Origin on a socket")
    expect(t, "GET", "/events", 403)
    expect(t, "GET", "/publish", 405, cookie=token)
    expect(t, "POST", "/publish", 403, body="text=anon",
           headers={"Content-Type": "application/x-www-form-urlencoded"})
    refused = ws_open(t, None)
    if refused[0] is not None:
        fail("a WebSocket without a visitor cookie was upgraded")
    if " 403 " not in refused[1] + " ":
        fail(f"anonymous upgrade: want the view's 403, got {refused[1]}")
    foreign = ws_open(t, token, origin="https://evil.example")
    if foreign[0] is not None:
        fail("a cross-origin WebSocket upgrade was accepted")
    if " 403 " not in foreign[1] + " ":
        fail(f"cross-origin upgrade: want 403, got {foreign[1]}")
    # /ws/message is the server's path: from the network it is a 404 before
    # Django, so the CSRF-exempt view cannot be reached by a POST.
    expect(t, "POST", "/ws/message", 404, cookie=token, body="x",
           headers={"M0-Channel": "demo/" + token, "M0-Opcode": "1"})

    phase("an SSE hold is subscribed, with the view's hello as its head")
    s1 = Stream(t, token)
    if s1.status != 200 or "text/event-stream" not in s1.headers.get("content-type", ""):
        fail(f"/events: {s1.status} {s1.headers.get('content-type')!r}")
    if "m0-hold" in s1.headers or "m0-channel" in s1.headers:
        fail("instruction headers leaked to the SSE client")
    hello = s1.next_event(deliver)
    if not hello or hello.get("type") != "hello" or not hello.get("worker"):
        fail(f"the stream's head is not the view's hello event: {hello!r}")
    print(f"stream 1 held by worker {s1.worker}, hello from {hello['worker']}")

    phase("one publish reaches a second tab on the same channel and not a stranger")
    s2 = Stream(t, token)
    stranger_token, _, _ = visitor(t)
    s3 = Stream(t, stranger_token)
    for s in (s2, s3):
        if not s.next_event(deliver):
            fail("a second stream never received its hello")
    marker = "sse-" + uuid.uuid4().hex[:8]
    _, body = expect(t, "POST", "/publish", 200, cookie=token,
                     body=urllib.parse.urlencode({"text": marker}),
                     headers={"Content-Type": "application/x-www-form-urlencoded"})
    published = json.loads(body)
    if not published.get("ok") or published.get("workers", 0) < 1:
        fail(f"publish did not report reaching a worker: {published!r}")
    for name, s in (("first", s1), ("second", s2)):
        ev = s.next_event(deliver)
        if not ev or ev.get("text") != marker or ev.get("via") != "http":
            fail(f"the {name} stream heard {ev!r}, wanted {marker!r} via http")
    leaked = s3.next_event(silence)
    if leaked is not None:
        fail(f"a STRANGER's stream heard {leaked!r} -- channels are not isolated")
    print(f"publish #{published.get('id')} reached streams on workers {s1.worker} and {s2.worker}; "
          f"the stranger on worker {s3.worker} heard nothing for {silence:.0f}s")

    phase("a WebSocket is held, and a frame sent on it reaches every tab")
    sock, ws_worker = ws_open(t, token)
    if sock is None:
        fail(f"upgrade refused: {ws_worker}")
    marker = "ws-" + uuid.uuid4().hex[:8]
    ws_send(sock, 0x1, marker.encode())
    echo = ws_read_text(sock, deliver)
    if not echo or echo.get("text") != marker or echo.get("via") != "websocket":
        fail(f"the socket heard {echo!r}, wanted its own message back via websocket")
    for name, s in (("first", s1), ("second", s2)):
        ev = s.next_event(deliver)
        if not ev or ev.get("text") != marker or ev.get("via") != "websocket":
            fail(f"the {name} stream heard {ev!r}, wanted the socket's {marker!r}")
    if s3.next_event(silence) is not None:
        fail("a stranger's stream heard a WebSocket message from another visitor's channel")
    ws_send(sock, 0x2, b"\x00\x01")  # a binary frame: dropped by the view, heard by nobody
    if ws_read_text(sock, silence) is not None:
        fail("a binary frame was rebroadcast")
    print(f"socket held by worker {ws_worker}; its message came back to the socket and both streams")

    phase("the limits: size 413, then a burst meets 429 inside the window the limit implies")
    _, body = expect(t, "POST", "/publish", 413, cookie=token,
                     body=urllib.parse.urlencode({"text": "x" * (max_bytes + 1)}),
                     headers={"Content-Type": "application/x-www-form-urlencoded"})
    # A fresh visitor, so the count starts at zero on every worker. No 429
    # may come inside the first LIMIT attempts (each worker has seen at most
    # LIMIT), and one must come by workers*LIMIT+1 (pigeonhole).
    burst_token, _, _ = visitor(t)
    first_429 = None
    retry_after = None
    for i in range(1, workers * limit + 2):
        code, h, _ = request(t, "POST", "/publish", body=urllib.parse.urlencode({"text": f"burst {i}"}),
                             headers={"Content-Type": "application/x-www-form-urlencoded"}, cookie=burst_token)
        if code == 429:
            first_429, retry_after = i, h.get("retry-after")
            break
        if code != 200:
            fail(f"burst attempt {i}: want 200 or 429, got {code}")
    if first_429 is None:
        fail(f"no 429 in {workers * limit + 1} publishes from one visitor -- the rate limit is not enforced")
    if first_429 <= limit:
        fail(f"429 on attempt {first_429}, inside the first {limit} -- the limit is tighter than /about says")
    if not retry_after or not retry_after.isdigit() or int(retry_after) < 1:
        fail(f"the 429 carries no usable Retry-After: {retry_after!r}")
    emit("demo.first_429_attempt", first_429, limit=workers * limit + 1, task="smoke-demo")
    print(f"413 for {max_bytes + 1} bytes; 429 on attempt {first_429} (limit {limit} x {workers} workers), "
          f"Retry-After {retry_after}s")

    ws_close(sock)
    for s in (s2, s3):
        s.close()
    # The first stream stays held: the caller's shutdown phase, if it has
    # one, must drain with a live subscriber rather than an empty server.
    return version, s1


# --- the container phases --------------------------------------------------------


def probe_image(args):
    if run("docker", "info", check=False).returncode != 0:
        fail("docker is not available (daemon not running, or not installed)")
    base = f"http://127.0.0.1:{args.port}"
    tag = f"m0serve-demo-probe:{uuid.uuid4().hex[:8]}"
    name = f"m0serve-demo-probe-{uuid.uuid4().hex[:8]}"
    platform = ["--platform", args.platform] if args.platform else []
    staged = []
    try:
        phase("build the image")
        build_args = []
        if args.wheel_dir:
            wheels = sorted(glob.glob(os.path.join(args.wheel_dir, "m0serve-*.whl")))
            if len(wheels) != 1:
                fail(f"--wheel-dir {args.wheel_dir}: want exactly one m0serve wheel, found {wheels}")
            dest = WHEELHOUSE / os.path.basename(wheels[0])
            shutil.copyfile(wheels[0], dest)
            staged.append(dest)
            version = re.match(r"m0serve-([^-]+)-", dest.name).group(1)
            build_args += ["--build-arg", "PIP_INDEX=--no-index", "--build-arg", f"M0SERVE_VERSION={version}"]
        elif args.version:
            build_args += ["--build-arg", f"M0SERVE_VERSION={args.version}"]
        t0 = time.monotonic()
        run("docker", "build", "-q", *platform, "-f", "deploy/demo/Dockerfile", "-t", tag, *build_args, ".")
        emit("demo_image.build_s", round(time.monotonic() - t0, 1), unit="s", task="smoke-demo")

        phase("start it")
        run("docker", "run", "-d", *platform, "--name", name, "-p", f"127.0.0.1:{args.port}:8080", tag)
        t = Target(base)
        deadline = time.monotonic() + 30
        while True:
            try:
                if request(t, "GET", "/health")[0] == 200:
                    break
            except (OSError, http.client.HTTPException):
                pass
            if run("docker", "inspect", "-f", "{{.State.Running}}", name).stdout.strip() != "true":
                fail("container exited before answering:\n" + logs(name))
            if time.monotonic() > deadline:
                fail("no answer on /health within 30s:\n" + logs(name))
            time.sleep(0.5)

        phase("m0serve is PID 1")
        argv0 = run("docker", "exec", name, "python", "-c",
                    "print(open('/proc/1/cmdline','rb').read().split(b'\\0')[0].decode())").stdout.strip()
        if os.path.basename(argv0) != "m0serve":
            fail(f"PID 1 is {argv0!r}, not m0serve -- the assertions below would test a wrapper")
        served = run("docker", "exec", name, "m0serve", "--version").stdout.strip()
        print(f"container serves with {served}")

        version, held = probe_http(t)
        if version not in served:
            fail(f"the page says m0serve {version}; the binary says {served!r}")
        if held.next_event(0.5) is not None:
            fail("the held stream heard an event nobody published")

        phase("docker stop is the drain, not SIGKILL")
        grace = 10
        t0 = time.monotonic()
        run("docker", "stop", "-t", str(grace), name, timeout=grace + 30)
        elapsed = time.monotonic() - t0
        code = int(run("docker", "inspect", "-f", "{{.State.ExitCode}}", name).stdout)
        emit("demo_image.stop_s", round(elapsed, 1), unit="s", limit=grace, task="smoke-demo")
        if code != 0:
            fail(f"docker stop: exit {code} after {elapsed:.1f}s (137 is SIGKILL at the deadline)\n" + logs(name))
        if elapsed > grace - 2:
            fail(f"docker stop: exit 0 only after {elapsed:.1f}s of a {grace}s grace")
        held.close()
        print(f"drained and exited 0 in {elapsed:.1f}s with a stream held; served by {served}")
    finally:
        for p in staged:
            p.unlink(missing_ok=True)
        if not args.keep:
            run("docker", "rm", "-f", name, check=False)
            run("docker", "rmi", "-f", tag, check=False)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--image", action="store_true", help="build deploy/demo/Dockerfile and probe the container")
    mode.add_argument("--url", help="probe a server already listening at this base URL")
    ap.add_argument("--wheel-dir", help="--image: install m0serve from this directory's wheel, not PyPI")
    ap.add_argument("--version", default="", help="--image: pin the PyPI release (default: newest)")
    ap.add_argument("--platform", default="", help="--image: docker --platform (linux/arm64 on colima)")
    ap.add_argument("--port", type=int, default=8183, help="--image: published port")
    ap.add_argument("--keep", action="store_true", help="--image: leave the image and container behind")
    args = ap.parse_args()
    if args.image:
        probe_image(args)
    else:
        probe_http(Target(args.url))[1].close()
    print("demo_probe: OK")


if __name__ == "__main__":
    main()
