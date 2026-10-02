#!/usr/bin/env python3
"""What every smoke probe needs, written once: the phase stamp, `fail`, a
server watched while it starts, a free port, an SSE reader and a WebSocket
client. Standard library only. The free port comes from below the kernel's
ephemeral range, whose ports go to whatever connects next (`free_port`).

    from probelib import WebSocket, fail, phase, stamp

    stamp("outbox_cap_probe: FAIL", fail="outbox-cap: {msg}")
    phase("the handshake")
    ws = WebSocket.connect("127.0.0.1", port, "/ws", host_header="localhost")

Each probe used to carry its own copy of all of this -- when this file was
written, 57 copies of the phase stamp, 42 of `fail()`, 18 readiness pollers
(ten of them named `wait_healthy`) and 17 hand-written WebSocket clients.
The copies drifted, and the drift was where the bugs were:

- two pollers watched a port for 120 s after the process behind it had
  died, and then said only "never answered";
- a client that took a read timeout for a close passed a server that had
  gone silent, and one whose timeout every heartbeat reset never failed at
  all -- the harness around it had to (`outbox_cap_probe.py`);
- a head read in 4096-byte chunks took the application's first frames with
  it, and a head read through `makefile()` stranded whatever the reader had
  buffered, which reads as "the server sent nothing".

A probe that moves onto this library keeps its command line and prints what
it printed: `stamp` takes the probe's own crash-line label and `fail` line,
because sabotage harnesses match those lines.

    python3 scripts/probelib.py --selftest   # each piece, against real sockets
"""

import base64
import collections
import contextlib
import errno
import hashlib
import http.client
import os
import random
import re
import signal
import socket
import struct
import subprocess
import sys
import time
import traceback
import urllib.parse

# --- the phase stamp -----------------------------------------------------------
#
# A probe's phases share its socket helpers, so a traceback names the CALL
# that raised and never the PHASE being proven: the 2026-08-30 CI failure was
# an unhandled reset inside a helper four phases shared, and two
# investigations guessed the wrong phase before a stamp named it on sight.
# scripts/phase_stamp_check.py holds every probe to the stamp, this file
# included, and proves each of its rules by sabotage.

PHASE = "startup"
_LABEL = "probe: FAIL"
_FAIL = None
_STREAM = None
_FAIL_STREAM = None
_ECHO = None


def phase(name):
    global PHASE
    PHASE = name
    if _ECHO is not None:
        print(_ECHO.format(phase=name), flush=True)


def _stamped(kind, exc, tb):
    # Both halves are load-bearing: the traceback says where, the line after
    # it says what was being proven.
    traceback.print_exception(kind, exc, tb)
    print("%s: %s: %r" % (_LABEL, PHASE, exc), file=_STREAM or sys.stdout)


def stamp(label, fail=None, stream=None, fail_stream=None, echo=None):
    """Install the crash handler, naming this probe.

    An unhandled exception prints its traceback and then
    `"<label>: <phase>: <repr>"`. `fail` is the template `fail()` prints,
    with `{msg}` and `{phase}` filled in; without one it is `"<label>:
    {msg}"`. `stream` is where both lines go, stdout unless given: the
    probes this replaced differ, and each keeps its own. `fail_stream`
    moves the `fail()` line alone, for a probe that failed through
    `sys.exit(msg)` -- stderr -- while its crash line went to stdout.
    `echo`, a template with `{phase}`, is printed to stdout as each phase
    begins, for a probe whose phases were also its progress lines.

    Called at the top of the probe, before anything can raise: a handler
    installed after the body that raises names nothing (the checker's
    dynamic half fails a probe that does that).
    """
    global _LABEL, _FAIL, _STREAM, _FAIL_STREAM, _ECHO
    _LABEL, _FAIL, _STREAM, _FAIL_STREAM, _ECHO = label, fail, stream, fail_stream, echo
    sys.excepthook = _stamped


def fail(msg):
    """Print this probe's failure line for `msg`, and exit 1."""
    template = _FAIL if _FAIL is not None else _LABEL + ": {msg}"
    line = template.format(msg=msg, phase=PHASE)
    print(line, file=_FAIL_STREAM or _STREAM or sys.stdout)
    sys.exit(1)


# --- a placement probe's summary ---------------------------------------------------


def placement_summary(samples, name):
    """A placement line's numbers, from `(total, connect, request)` per
    sample, each in milliseconds. A pure function of the list; `name` is
    what was sampled (`now`, `health`) and spells the first two keys.

    `second_<name>_ms` is the second-largest total (equal to the worst when
    two samples tie for it), and the connect and request figures are the
    WORST sample's own, not each column's maximum: they say where that one
    sample's time went. Whole milliseconds, truncated. Fewer than two
    samples have no second-worst, and are refused rather than answered with
    the only one. `ramp_probe.py selftest` holds the answers.
    """
    if len(samples) < 2:
        raise ValueError(
            "%d sample(s): a second-worst needs at least two" % len(samples)
        )
    ordered = sorted(samples, key=lambda s: s[0], reverse=True)
    worst, second = ordered[0], ordered[1]
    return {
        "worst_%s_ms" % name: int(worst[0]),
        "second_%s_ms" % name: int(second[0]),
        "worst_connect_ms": int(worst[1]),
        "worst_request_ms": int(worst[2]),
    }


def placement_line(samples, name, slow_requests):
    """The summary as one line, in dict order, `slow_requests=` last."""
    got = placement_summary(samples, name)
    fields = ["%s=%d" % pair for pair in got.items()]
    return " ".join(fields + ["slow_requests=%d" % slow_requests])


# --- a server, watched while it starts -------------------------------------------


class NotServing(RuntimeError):
    """A server that exited, or never answered, before it was ready.

    `str()` carries the tail of its log, for the traceback; `repr()` is the
    one-line reason, for the stamped line after it.
    """

    def __init__(self, reason, log_tail=""):
        RuntimeError.__init__(self, reason)
        self.reason = reason
        self.log_tail = log_tail

    def __str__(self):
        if not self.log_tail:
            return self.reason
        return "%s; its log ends:\n%s" % (self.reason, self.log_tail)

    def __repr__(self):
        return "NotServing(%r)" % (self.reason,)


def _exited(code):
    if code is not None and code < 0:
        try:
            name = signal.Signals(-code).name
        except ValueError:
            name = "signal %d" % -code
        return "was killed by %s" % name
    return "exited %s" % code


def _log_tail(log, lines=40):
    """The last `lines` of a log given as a path or an open file, or ""."""
    if log is None:
        return ""
    try:
        if isinstance(log, (str, os.PathLike)):
            with open(log, errors="replace") as fh:
                text = fh.read()
        else:
            log.seek(0)
            text = log.read()
            if isinstance(text, bytes):
                text = text.decode("utf-8", "replace")
    except (OSError, ValueError):
        return ""
    return "\n".join(text.splitlines()[-lines:])


def _answers(target, status, timeout):
    if isinstance(target, tuple):
        try:
            socket.create_connection(target, timeout=timeout).close()
            return True
        except OSError:
            return False
    parts = urllib.parse.urlsplit(target)
    path = (parts.path or "/") + ("?" + parts.query if parts.query else "")
    conn = http.client.HTTPConnection(parts.hostname, parts.port or 80, timeout=timeout)
    try:
        conn.request("GET", path)
        resp = conn.getresponse()
        resp.read()
        return status is None or resp.status == status
    except (OSError, http.client.HTTPException):
        return False
    finally:
        conn.close()


def wait_healthy(target, proc=None, timeout=30.0, log=None, status=200):
    """Poll `target` until it answers; raise NotServing if `proc` exits first.

    `target` is a URL to GET, where `status` is the answer that counts (None:
    any answer, a 404 included), or a `(host, port)` pair for a probe that
    only needs the listener. `proc`, a Popen, is looked at before every
    attempt, so a server that dies is reported within one attempt rather
    than at the timeout -- two of the copies this replaces polled for 120 s
    after the process had gone. `log`, a path or an open file, is what the
    failure quotes the tail of.
    """
    what = target if isinstance(target, str) else "%s:%d" % target
    name = _name(proc)
    deadline = time.monotonic() + timeout
    while True:
        if proc is not None and proc.poll() is not None:
            raise NotServing("%s %s before it answered %s"
                             % (name, _exited(proc.returncode), what), _log_tail(log))
        left = deadline - time.monotonic()
        if left <= 0:
            raise NotServing("%s did not answer %s within %g s" % (name, what, timeout),
                             _log_tail(log))
        if _answers(target, status, min(2.0, max(0.1, left))):
            return
        time.sleep(0.05)


def _name(proc):
    if proc is None:
        return "the server"
    args = proc.args if isinstance(proc.args, (list, tuple)) else [proc.args]
    return os.path.basename(str(args[0]))


def stop(proc, grace=15.0, group=False):
    """SIGTERM, `grace` seconds for the drain, then SIGKILL; reap it either
    way, and return its exit status.

    `group`: signal the process group the server leads (`server(...,
    group=True)` starts it as one), so forked workers are stopped with it,
    and once it is reaped nothing of the group outlives it: a worker left
    behind holds the port into the next phase.
    """
    def send(sig):
        try:
            if group:
                os.killpg(proc.pid, sig)
            elif proc.poll() is None:
                proc.send_signal(sig)
        except (ProcessLookupError, PermissionError):
            pass

    send(signal.SIGTERM)
    try:
        code = proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        send(signal.SIGKILL)
        code = proc.wait()
    if group:
        send(signal.SIGKILL)
    return code


@contextlib.contextmanager
def server(argv, target, timeout=30.0, log=None, status=200, grace=15.0,
           group=False, **popen):
    """Run `argv` as a server for the length of a `with`, and yield its Popen.

    Ready means `target` answered (see `wait_healthy`); a process that exits
    first raises NotServing at once. Its stdout and stderr go to `log`, a
    path (opened for writing here) or an open file; without one they are
    discarded. On the way out it is stopped as `stop` says, and reaped.
    """
    opened = None
    if isinstance(log, (str, os.PathLike)):
        opened = out = open(log, "w")
    else:
        out = log if log is not None else subprocess.DEVNULL
    if group:
        popen["start_new_session"] = True
    proc = subprocess.Popen(argv, stdout=out, stderr=subprocess.STDOUT, **popen)
    try:
        wait_healthy(target, proc, timeout, log, status)
        yield proc
    finally:
        stop(proc, grace, group)
        if opened is not None:
            opened.close()


PORT_FLOOR = 10000
"""The lowest port `free_port` gives: below it sit fixed-port services."""


def ephemeral_start():
    """Where the ports connect() and bind(0) hand out begin: /proc on Linux,
    sysctl on macOS, and 32768, the lower of their defaults, when neither
    says."""
    try:
        with open("/proc/sys/net/ipv4/ip_local_port_range") as fh:
            return int(fh.read().split()[0])
    except (OSError, ValueError, IndexError):
        pass
    for exe in ("sysctl", "/usr/sbin/sysctl"):
        try:
            out = subprocess.run([exe, "-n", "net.inet.ip.portrange.first"],
                                 capture_output=True, text=True, timeout=10)
            return int(out.stdout.split()[0])
        except (OSError, ValueError, IndexError, subprocess.SubprocessError):
            pass
    return 32768


def _port_free(port):
    """Free on the IPv4 AND the IPv6 wildcard: `localhost` may reach an IPv6
    listener first, and that would be somebody else's server."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.bind(("", port))
        except OSError:
            return False
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    except OSError:
        return True  # no IPv6 here, so nobody can answer localhost on it
    with s:
        try:
            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            s.bind(("::", port))
        except OSError as e:
            return e.errno != errno.EADDRINUSE  # anything else cannot be held
    return True


def _free_run(count, low, high):
    """The first of `count` consecutive free ports from a base drawn at random
    from low..high, or None when no base there has its whole run free."""
    for base in random.sample(range(low, high + 1), min(100, high - low + 1)):
        if all(_port_free(p) for p in range(base, base + count)):
            return base
    return None


def free_port(count=1):
    """A port nothing holds, for a server a probe starts itself: a fixed port
    is shared with every other run on the machine. With `count`, the first of
    that many consecutive ports, for a probe that serves one shape per port.

    Each port is free on IPv4 and IPv6, and the run is drawn at random from
    PORT_FLOOR up to the kernel's ephemeral range, never inside it. Every
    connect() and bind(0) on the machine takes its port from that range, and
    macOS hands them out in sequence, so the ports just above one bind(0)
    returned go to the next connections anyone makes, the probe's own
    included; a socket on a port then refuses a server's bind of it (on
    Linux any socket, on macOS past SO_REUSEADDR one owned by another user).
    Nothing is handed out below the range. scripts/smoke/lib.sh's
    `free_port` keeps the same rule for the shell tasks.
    """
    first = ephemeral_start()
    if first - count < PORT_FLOOR:
        raise RuntimeError("free_port: the ephemeral range starts at %d, leaving no run of "
                           "%d ports between %d and it" % (first, count, PORT_FLOOR))
    base = _free_run(count, PORT_FLOOR, first - count)
    if base is None:
        raise RuntimeError("free_port: no run of %d ports was free on both IPv4 and IPv6"
                           % count)
    return base


# --- server-sent events ------------------------------------------------------------


class Event(collections.namedtuple("Event", "event data id comments")):
    """One block of a text/event-stream, ended by a blank line.

    `data` is the block's `data:` lines joined by newlines, or None when it
    had none: a heartbeat is a block of comments alone, and a probe watching
    for one needs to see it, where a browser dispatches nothing. `id` is THIS
    block's own `id:` field, or None -- not the browser's last-event-ID,
    which persists from block to block -- because what a probe asserts is
    whether a frame carried one. `comments` holds the text after each `:`.
    """


_EOL = re.compile(rb"\r\n|\r|\n")


def _field_value(text):
    return text[1:] if text.startswith(" ") else text


class SSEParser:
    """text/event-stream, incrementally: `feed(bytes)` returns the events the
    bytes complete, and a partial line or block waits for the rest."""

    def __init__(self):
        self._pending = b""
        self._clear()

    def _clear(self):
        self._event, self._data, self._id, self._comments = None, [], None, []
        self._seen = False

    def feed(self, chunk):
        self._pending += chunk
        events = []
        while True:
            m = _EOL.search(self._pending)
            # A CR that ends the input may be half of a CRLF: wait for more.
            if m is None or (m.group() == b"\r" and m.end() == len(self._pending)):
                return events
            raw = self._pending[:m.start()]
            self._pending = self._pending[m.end():]
            ev = self.line(raw.decode("utf-8", "replace"))
            if ev is not None:
                events.append(ev)

    def line(self, text):
        """One line without its terminator; returns the Event a blank line
        completes, or None."""
        if text == "":
            if not self._seen:
                return None
            ev = Event(self._event, "\n".join(self._data) if self._data else None,
                       self._id, tuple(self._comments))
            self._clear()
            return ev
        self._seen = True
        if text.startswith(":"):
            self._comments.append(_field_value(text[1:]))
            return None
        name, colon, value = text.partition(":")
        value = _field_value(value) if colon else ""
        if name == "data":
            self._data.append(value)
        elif name == "event":
            self._event = value
        elif name == "id" and "\0" not in value:
            self._id = value
        # `retry:` and unknown fields are ignored, as a browser ignores them.
        return None


def sse_events(source, sock=None, deadline=None):
    """The events on a stream, read through `source.readline()` -- an
    http.client response's `fp`, or a socket's `makefile("rb")`.

    Ends at EOF, dropping a block the stream did not finish. With `deadline`
    (a `time.monotonic()` value) and the stream's `sock`, it also ends when
    the deadline passes: a per-read timeout alone never fires on a stream
    whose server sends a heartbeat comment more often than the timeout. A
    stream read past its deadline cannot be read again -- the timeout
    poisons a socket file -- so the probe is done with it.
    """
    if deadline is not None and sock is None:
        raise ValueError("a deadline needs the stream's socket")
    parser = SSEParser()
    saved = sock.gettimeout() if sock is not None else None
    try:
        while True:
            if deadline is not None:
                left = deadline - time.monotonic()
                if left <= 0:
                    return
                sock.settimeout(left)
            try:
                raw = source.readline()
            except socket.timeout:
                if deadline is None:
                    raise
                return
            if not raw:
                return
            for ev in parser.feed(raw):
                yield ev
    finally:
        if sock is not None:
            with contextlib.suppress(OSError):
                sock.settimeout(saved)


# --- WebSocket ---------------------------------------------------------------------

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
CONT, TEXT, BINARY, CLOSE, PING, PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA

Frame = collections.namedtuple("Frame", "fin rsv opcode masked payload")


def ws_key():
    return base64.b64encode(os.urandom(16)).decode()


def ws_accept(key):
    """The Sec-WebSocket-Accept a server owes `key` (RFC 6455 §4.2.2)."""
    return base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()


def upgrade_request(path, key, host="localhost", headers=()):
    """The opening handshake's request, as bytes; `headers` are extra
    (name, value) pairs after the protocol's own."""
    lines = ["GET %s HTTP/1.1" % path, "Host: %s" % host, "Upgrade: websocket",
             "Connection: Upgrade", "Sec-WebSocket-Key: %s" % key,
             "Sec-WebSocket-Version: 13"]
    lines += ["%s: %s" % (name, value) for name, value in headers]
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")


def mask(payload, key):
    """`payload` XORed with the 4-byte `key`, repeated. One integer XOR, not a
    byte loop: a probe that masks megabytes spent seconds in a generator."""
    n = len(payload)
    if n == 0:
        return b""
    stream = (bytes(key) * (n // 4 + 1))[:n]
    return (int.from_bytes(payload, "big") ^ int.from_bytes(stream, "big")).to_bytes(n, "big")


def encode_frame(opcode, payload=b"", fin=True, mask_key=None):
    """A client frame: masked, as a client's must be (RFC 6455 §5.3), with
    a fresh random key unless one is given; 7-, 16- or 64-bit length."""
    key = os.urandom(4) if mask_key is None else bytes(mask_key)
    n = len(payload)
    b0 = (0x80 if fin else 0) | opcode
    if n < 126:
        head = struct.pack(">BB", b0, 0x80 | n)
    elif n < 65536:
        head = struct.pack(">BBH", b0, 0x80 | 126, n)
    else:
        head = struct.pack(">BBQ", b0, 0x80 | 127, n)
    return head + key + mask(payload, key)


def _header_len(buf, at=0):
    """(header length, payload length) for the frame at `buf[at:]`, or None
    while the header itself is incomplete."""
    if len(buf) - at < 2:
        return None
    b1 = buf[at + 1]
    n, size = b1 & 0x7F, 2
    if n == 126:
        size = 4
    elif n == 127:
        size = 10
    if b1 & 0x80:
        size += 4
    if len(buf) - at < size:
        return None
    if n == 126:
        n = struct.unpack(">H", bytes(buf[at + 2:at + 4]))[0]
    elif n == 127:
        n = struct.unpack(">Q", bytes(buf[at + 2:at + 10]))[0]
    return size, n


def parse_frame(buf, at=0):
    """(Frame, end) for the complete frame at `buf[at:]`, or None if more
    bytes are needed. A masked payload is unmasked."""
    sizes = _header_len(buf, at)
    if sizes is None:
        return None
    size, n = sizes
    end = at + size + n
    if len(buf) < end:
        return None
    b0, b1 = buf[at], buf[at + 1]
    payload = bytes(buf[at + size:end])
    if b1 & 0x80:
        payload = mask(payload, bytes(buf[at + size - 4:at + size]))
    return Frame(bool(b0 & 0x80), (b0 >> 4) & 0x7, b0 & 0x0F, bool(b1 & 0x80), payload), end


def parse_frames(buf):
    """Every complete frame in `buf`, and how many bytes they took."""
    frames, at = [], 0
    while True:
        got = parse_frame(buf, at)
        if got is None:
            return frames, at
        frame, at = got
        frames.append(frame)


class WebSocket:
    """A client on one socket, with ONE buffer for everything it reads.

    One buffer because the hand-written clients lost bytes between two: a
    head read in chunks takes the application's first frames with it when
    the kernel coalesces them with the 101, and a head read through
    `makefile()` strands what that reader buffered. Here the bytes after
    the head stay in `buf`, and every read -- frames, and `recv_raw` for a
    probe that wants the wire -- starts there.

    What a surprise MEANS is the probe's to say, in its own words: the
    handshake returns the status line or None, and a connection that ends
    inside a frame is EOFError under `eof_ok`, otherwise `fail()` with the
    words every hand-written copy used. A masked server frame is `fail()`:
    servers MUST NOT mask (RFC 6455 §5.1).
    """

    def __init__(self, sock, buf=b""):
        self.sock = sock
        self.buf = bytearray(buf)
        self.key = None
        self.head = None
        self.status_line = None

    @classmethod
    def connect(cls, host, port, path="/ws", timeout=10.0, host_header=None, headers=()):
        """Connect, send the upgrade for `path` and read the head; check
        `status_line` for the answer. The Host header is `host:port` unless
        `host_header` says otherwise."""
        ws = cls(socket.create_connection((host, port), timeout=timeout))
        ws.handshake(path, "%s:%d" % (host, port) if host_header is None else host_header,
                     headers)
        return ws

    def handshake(self, path, host="localhost", headers=()):
        """Send the upgrade for `path` and read the response head; returns
        the status line, or None if the connection closed before a whole
        head arrived."""
        self.key = ws_key()
        self.sock.sendall(upgrade_request(path, self.key, host, headers))
        return self.read_head()

    def read_head(self):
        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                return None
            self.buf += chunk
        head, _, rest = bytes(self.buf).partition(b"\r\n\r\n")
        self.head, self.buf = head, bytearray(rest)
        self.status_line = head.split(b"\r\n", 1)[0]
        return self.status_line

    def header(self, name):
        """A response header's value by case-insensitive name, or None."""
        want = name.lower().encode("latin-1") + b":"
        for line in (self.head or b"").split(b"\r\n")[1:]:
            if line.lower().startswith(want):
                return line[len(want):].strip().decode("latin-1")
        return None

    def accept_ok(self):
        """The server's Sec-WebSocket-Accept is the one this key is owed."""
        return self.key is not None and self.header("Sec-WebSocket-Accept") == ws_accept(self.key)

    def send(self, opcode, payload=b"", fin=True, mask_key=None):
        self.sock.sendall(encode_frame(opcode, payload, fin, mask_key))

    def send_text(self, text):
        self.send(TEXT, text.encode())

    def send_close(self, code=None, reason=b""):
        self.send(CLOSE, b"" if code is None else struct.pack(">H", code) + reason)

    def settimeout(self, seconds):
        self.sock.settimeout(seconds)

    def _fill(self, deadline):
        if deadline is not None:
            left = deadline - time.monotonic()
            if left <= 0:
                raise socket.timeout("timed out")
            self.sock.settimeout(left)
        chunk = self.sock.recv(65536)
        if not chunk:
            return False
        self.buf += chunk
        return True

    def _ended(self, eof_ok):
        """The connection closed inside a frame: say how far in, the way
        each hand-written `recv_exact` did -- what the piece being read
        wanted, and what of it arrived."""
        have = len(self.buf)
        if have < 2:
            want, got = 2, have
        else:
            n = self.buf[1] & 0x7F
            ext = 2 if n == 126 else 8 if n == 127 else 0
            if have < 2 + ext:
                want, got = ext, have - 2
            else:
                size, length = _header_len(self.buf) or (2 + ext, 0)
                want, got = length, have - size
        msg = "connection closed wanting %d bytes (got %d)" % (want, got)
        if eof_ok:
            raise EOFError(msg)
        fail(msg)

    def recv_frame(self, deadline=None, eof_ok=False):
        """(opcode, payload) of the server's next frame, a ping included.

        `deadline` (a `time.monotonic()` value) bounds the whole read, not
        each `recv`: a server that pings more often than a per-read timeout
        otherwise keeps a read open for ever. Past it, socket.timeout; the
        socket's own timeout is put back either way.
        """
        saved = self.sock.gettimeout()
        try:
            while True:
                if len(self.buf) >= 2 and self.buf[1] & 0x80:
                    fail("server frame is masked (servers MUST NOT mask)")
                got = parse_frame(self.buf)
                if got is not None:
                    frame, end = got
                    del self.buf[:end]
                    return frame.opcode, frame.payload
                if not self._fill(deadline):
                    self._ended(eof_ok)
        finally:
            if deadline is not None:
                with contextlib.suppress(OSError):
                    self.sock.settimeout(saved)

    def recv_data(self, deadline=None, eof_ok=False, pong=True):
        """The next frame that is not a ping -- data, a pong, or a Close.
        Each ping is answered with its pong unless `pong` is False."""
        while True:
            opcode, payload = self.recv_frame(deadline, eof_ok)
            if opcode != PING:
                return opcode, payload
            if pong:
                self.send(PONG, payload)

    def recv_raw(self, n=65536):
        """Bytes off the wire, whatever they are: what is buffered first,
        then one `recv` -- b"" is the server's FIN."""
        if self.buf:
            out = bytes(self.buf[:n])
            del self.buf[:n]
            return out
        return self.sock.recv(n)

    def close(self):
        with contextlib.suppress(OSError):
            self.sock.close()


# --- selftest ----------------------------------------------------------------------


def _selftest():
    """Each piece against real sockets and processes; nothing is mocked."""
    import io
    import tempfile
    import threading

    ok = True

    def check(label, cond):
        nonlocal ok
        print(("  ok   " if cond else "  FAIL ") + label, flush=True)
        ok = ok and bool(cond)

    here = os.path.dirname(os.path.abspath(__file__))
    env = dict(os.environ, PYTHONPATH=here + os.pathsep + os.environ.get("PYTHONPATH", ""))

    def child(code):
        return subprocess.run([sys.executable, "-c", code], env=env,
                              capture_output=True, text=True, timeout=60)

    print("probelib selftest: the stamp and fail()")
    done = child("from probelib import phase, stamp\n"
                 "stamp('x_probe: FAIL')\n"
                 "phase('the second phase')\n"
                 "raise TimeoutError('timed out')\n")
    check("an unhandled error prints its traceback", "Traceback" in done.stderr
          and "TimeoutError: timed out" in done.stderr)
    check("...and then the line naming the phase it was raised in",
          done.stdout.splitlines() == ["x_probe: FAIL: the second phase: TimeoutError('timed out')"])
    check("...and exits 1", done.returncode == 1)
    done = child("import sys\nfrom probelib import stamp\n"
                 "stamp('x FAIL', stream=sys.stderr)\n"
                 "raise ValueError('v')\n")
    check("stream= moves the stamped line", done.stdout == ""
          and done.stderr.splitlines()[-1] == "x FAIL: startup: ValueError('v')")
    done = child("from probelib import fail, phase, stamp\n"
                 "stamp('x FAIL', fail='x-probe: {phase}: {msg}')\n"
                 "phase('p2')\nfail('it broke {braces} and all')\n")
    check("fail() prints its template with the phase and the message, and exits 1",
          (done.stdout, done.returncode) == ("x-probe: p2: it broke {braces} and all\n", 1))
    done = child("from probelib import fail, stamp\nstamp('x FAIL')\nfail('m')\n")
    check("fail() without a template prints '<label>: <msg>'", done.stdout == "x FAIL: m\n")
    split = ("import sys\nfrom probelib import fail, phase, stamp\n"
             "stamp('x FAIL', fail='x: {phase}: {msg}', fail_stream=sys.stderr)\n"
             "phase('p3')\n")
    done = child(split + "fail('m')\n")
    check("fail_stream= moves the fail() line alone",
          (done.stdout, done.stderr, done.returncode) == ("", "x: p3: m\n", 1))
    done = child(split + "raise ValueError('v')\n")
    check("...and leaves the crash line on its own stream",
          done.stdout == "x FAIL: p3: ValueError('v')\n" and "Traceback" in done.stderr
          and "x FAIL:" not in done.stderr)
    done = child("from probelib import phase, stamp\n"
                 "stamp('x FAIL', echo='--- {phase}')\n"
                 "phase('one')\nprint('between')\nphase('two')\n")
    check("echo= prints each phase as it begins, in order with the probe's own lines",
          done.stdout == "--- one\nbetween\n--- two\n")
    done = child("import os\nfrom probelib import phase, stamp\n"
                 "stamp('x FAIL', echo='--- {phase}')\n"
                 "phase('one')\nos._exit(3)\n")
    check("...flushed as it is printed: a probe that dies next has still said it",
          (done.stdout, done.returncode) == ("--- one\n", 3))
    # (Printed through a list: phase_stamp_check reads a print naming the
    # stamp's global on one line as the crash handler naming the phase, and
    # this line must not stand in for the handler's own.)
    done = child("import probelib\nfrom probelib import PHASE as copied, phase\n"
                 "phase('later')\nboth = [copied, probelib.PHASE]\nprint(' '.join(both))\n")
    check("PHASE imported by name is a stale copy; probelib.PHASE is read live",
          done.stdout.strip() == "startup later")

    print("probelib selftest: servers")
    port = free_port()
    check("free_port gives a port nothing listens on",
          not _answers(("127.0.0.1", port), None, 0.5))

    def range_start():
        # Read apart from ephemeral_start, which is under test.
        try:
            if sys.platform.startswith("linux"):
                with open("/proc/sys/net/ipv4/ip_local_port_range") as fh:
                    return int(fh.read().split()[0])
            if sys.platform == "darwin":
                return int(subprocess.run(
                    ["/usr/sbin/sysctl", "-n", "net.inet.ip.portrange.first"],
                    capture_output=True, text=True, timeout=10).stdout)
        except (OSError, ValueError, IndexError, subprocess.SubprocessError):
            pass
        return None

    def binds(port):
        # On the IPv4 and IPv6 wildcards, as a server binds it.
        for family, addr in ((socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")):
            try:
                s = socket.socket(family, socket.SOCK_STREAM)
            except OSError:
                continue  # no IPv6 here: nothing can answer localhost on it
            with s:
                try:
                    if family == socket.AF_INET6:
                        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                    s.bind((addr, port))
                except OSError:
                    return False
        return True

    # Inside the ephemeral range a port goes to whatever connects next -- on
    # macOS in sequence, so a run counted up from one bind(0) returned was
    # the next connections' -- and each can refuse the server's bind.
    first = range_start()
    check("...below the kernel's ephemeral range (which starts at %s), where "
          "nothing is handed out" % first, first is not None and PORT_FLOOR <= port < first)
    run = free_port(3)
    check("free_port(3) is three ports in a row below the range, each binding on "
          "the IPv4 and IPv6 wildcards", first is not None
          and PORT_FLOOR <= run <= first - 3 and all(binds(p) for p in range(run, run + 3)))
    # The run is checked whole, on both families, with the bases pinned (drawn
    # from all of them, a run of three would miss a trap nearly every time):
    # from bases b..b+2 every run holds b+2, so a listener there leaves no
    # answer, and from bases b..b+3 the one clear run is b+3's.
    b = next((c for c in (random.randint(PORT_FLOOR, (first or 32768) - 6)
                          for _ in range(200)) if all(binds(p) for p in range(c, c + 6))), None)
    check("six ports in a row are free below the range, for the traps", b is not None)
    for family, addr in ((socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")) if b else ():
        try:
            trap = socket.socket(family, socket.SOCK_STREAM)
        except OSError:
            continue
        with trap:
            if family == socket.AF_INET6:
                trap.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            trap.bind((addr, b + 2))
            trap.listen(1)
            check("with a listener on %s, no run of three from bases b..b+2 is free, "
                  "since each holds it" % addr, _free_run(3, b, b + 2) is None)
            check("...and from bases b..b+3 the answer is the one clear run, b+3's",
                  _free_run(3, b, b + 3) == b + 3)

    dead = subprocess.Popen([sys.executable, "-c", "import sys; sys.exit(3)"])
    t0 = time.monotonic()
    try:
        wait_healthy(("127.0.0.1", port), dead, timeout=30)
        raised = None
    except NotServing as exc:
        raised = exc
    took = time.monotonic() - t0
    check("a server that dies is reported within seconds, not at the 30 s timeout (%.2f s)"
          % took, raised is not None and took < 5)
    check("...naming how it exited", raised is not None and "exited 3" in raised.reason)

    with tempfile.TemporaryDirectory() as tmp:
        log = os.path.join(tmp, "server.log")
        port = free_port()
        loud = [sys.executable, "-c", "print('refusing: no such app'); raise SystemExit(78)"]
        try:
            with server(loud, "http://127.0.0.1:%d/health" % port, timeout=30, log=log):
                pass
            raised = None
        except NotServing as exc:
            raised = exc
        check("server() raises NotServing when the process exits first",
              raised is not None and "exited 78" in raised.reason)
        check("...carrying its log's tail, and a one-line repr for the stamp",
              raised is not None and "refusing: no such app" in str(raised)
              and "\n" not in repr(raised))

        port = free_port()
        # socketserver.TCPServer, not `python -m http.server`: HTTPServer's
        # server_bind() calls socket.getfqdn() between bind and listen, a
        # reverse lookup that took over 30 s on a macOS CI runner, which then
        # refused every connection while the process stayed alive.
        http_server = [sys.executable, "-c",
                       "import functools, http.server, socketserver, sys\n"
                       "socketserver.TCPServer.allow_reuse_address = True\n"
                       "h = functools.partial(http.server.SimpleHTTPRequestHandler,"
                       " directory=sys.argv[2])\n"
                       "socketserver.TCPServer(('127.0.0.1', int(sys.argv[1])), h)"
                       ".serve_forever()\n",
                       str(port), tmp]
        with server(http_server, "http://127.0.0.1:%d/" % port, timeout=30, log=log) as proc:
            check("server() yields once the target answers",
                  proc.poll() is None and _answers("http://127.0.0.1:%d/" % port, 200, 2))
            try:
                wait_healthy("http://127.0.0.1:%d/nope" % port, proc, timeout=0.5)
                raised = None
            except NotServing as exc:
                raised = exc
            check("status=200 does not take a 404 for ready",
                  raised is not None and "did not answer" in raised.reason)
            try:
                wait_healthy("http://127.0.0.1:%d/nope" % port, proc, timeout=5, status=None)
                took_404 = True
            except NotServing:
                took_404 = False
            check("status=None takes any answer, a 404 included", took_404)
        check("...and the server is stopped and reaped on the way out",
              proc.returncode is not None)

        # A server that ignores SIGTERM, with a worker of its own that does
        # too: group=True must take both, by SIGKILL (no crash report).
        pidfile = os.path.join(tmp, "worker.pid")
        stubborn = subprocess.Popen(
            [sys.executable, "-c",
             "import signal, subprocess, sys, time\n"
             "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
             "w = subprocess.Popen([sys.executable, '-c', 'import signal, time; "
             "signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'])\n"
             "open(sys.argv[1], 'w').write(str(w.pid))\n"
             "time.sleep(60)\n", pidfile],
            start_new_session=True)
        t0 = time.monotonic()
        while not os.path.exists(pidfile) and time.monotonic() - t0 < 20:
            time.sleep(0.05)
        time.sleep(0.2)
        worker = int(open(pidfile).read() or 0) if os.path.exists(pidfile) else 0
        t0 = time.monotonic()
        code = stop(stubborn, grace=0.5, group=True)
        took = time.monotonic() - t0
        check("stop() kills what ignores SIGTERM after its grace (%.2f s)" % took,
              code == -signal.SIGKILL and took < 5)
        gone = False
        for _ in range(100):
            try:
                os.kill(worker, 0)
            except ProcessLookupError:
                gone = True
                break
            time.sleep(0.05)
        check("...and group=True takes the worker it forked with it", worker > 0 and gone)

    print("probelib selftest: server-sent events")
    stream = (b": connected\n\n"
              b"id: 7\r\nevent: tick\r\ndata: one\r\ndata:two\r\ndata:  three\r\n\r\n"
              b"data: unnumbered\n\n"
              b": heartbeat\n\n"
              b"retry: 10\nfield-without-colon\ndata\nid: bad\0id\n\n"
              b"data: lone CR\r\r"
              b"data: never finished\n")
    whole = SSEParser().feed(stream)
    check("a comment-only block is an event with data None (a heartbeat is visible)",
          whole[0] == Event(None, None, None, ("connected",)))
    check("id, event and data lines; CRLF; one leading space stripped, no more",
          whole[1] == Event("tick", "one\ntwo\n three", "7", ()))
    check("a block's id is its own: the next block without one has None",
          whole[2] == Event(None, "unnumbered", None, ()))
    check("a bare `data` field is an empty line; an id holding NUL is ignored",
          whole[4] == Event(None, "", None, ()))
    check("a lone CR ends a line", whole[5] == Event(None, "lone CR", None, ()))
    check("a block the stream never finished is not dispatched", len(whole) == 6)
    parser, byte_by_byte = SSEParser(), []
    for i in range(len(stream)):
        byte_by_byte += parser.feed(stream[i:i + 1])
    check("fed one byte at a time, the same events (a CRLF split across reads)",
          byte_by_byte == whole)
    check("sse_events reads a readline() source to EOF",
          list(sse_events(io.BytesIO(stream))) == whole)

    # Heartbeats for 3 s against a 2 s read timeout, then silence: a reader
    # that ignored its deadline ends at about 5 s, not hanging the selftest,
    # and fails the `took < 2` bound below -- that bound is the check.
    # The first heartbeat rides the event's own write, so "a heartbeat
    # arrived" needs the beats thread scheduled once, as `first` already
    # does: counting the 50 ms beats inside the 0.4 s window failed on a
    # macOS runner that starved this thread ~300 ms (release run
    # 36648988834), with the deadline working.
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(4)
    stop_beats = threading.Event()

    def beats():
        conn, _ = listener.accept()
        until = time.monotonic() + 3
        with contextlib.suppress(OSError):
            conn.sendall(b"data: first\n\n: heartbeat\n\n")
            while not stop_beats.wait(0.05) and time.monotonic() < until:
                conn.sendall(b": heartbeat\n\n")
            stop_beats.wait(30)
        conn.close()

    beating = threading.Thread(target=beats, daemon=True)
    beating.start()
    sock = socket.create_connection(listener.getsockname(), timeout=2)
    t0 = time.monotonic()
    got = []
    with contextlib.suppress(socket.timeout):
        for ev in sse_events(sock.makefile("rb"), sock=sock, deadline=t0 + 0.4):
            got.append(ev)
    took = time.monotonic() - t0
    check("a deadline ends a stream whose heartbeats reset every read timeout (%.2f s)"
          % took, 0.3 < took < 2 and len(got) >= 2 and got[0].data == "first")
    check("...and puts the socket's own timeout back", sock.gettimeout() == 2)
    stop_beats.set()
    sock.close()
    beating.join(5)
    listener.close()

    print("probelib selftest: WebSocket framing")
    key = os.urandom(4)
    payload = os.urandom(1000)
    check("mask() is the byte-by-byte XOR it replaces",
          mask(payload, key) == bytes(b ^ key[i % 4] for i, b in enumerate(payload)))
    check("masking twice is the identity", mask(mask(payload, key), key) == payload)
    good = True
    for n in (0, 1, 125, 126, 127, 65535, 65536, 70000):
        body = os.urandom(n)
        for fin in (True, False):
            raw = encode_frame(BINARY, body, fin)
            frame, end = parse_frame(raw)
            good = good and end == len(raw) and frame == Frame(fin, 0, BINARY, True, body)
            head = 2 + (2 if 126 <= n < 65536 else 8 if n >= 65536 else 0)
            good = good and raw[1] & 0x7F == (n if n < 126 else 126 if n < 65536 else 127)
            good = good and len(raw) == head + 4 + n
    check("encode/parse round-trip at every length boundary, FIN set and clear", good)
    raw = encode_frame(TEXT, b"hello", mask_key=b"\0\0\0\0")
    check("a zero mask key leaves the payload readable on the wire", raw.endswith(b"hello"))
    raw = encode_frame(PING, b"p" * 300)
    check("parse_frame wants more at every truncation of a frame",
          all(parse_frame(raw[:i]) is None for i in range(len(raw))))
    server_frames = b"\x81\x05hello" + b"\x82\x7e\x01\x00" + b"x" * 256 + b"\x89\x00" + b"\x81"
    frames, used = parse_frames(server_frames)
    check("parse_frames takes every whole frame and leaves the partial one",
          [(f.opcode, len(f.payload), f.masked) for f in frames]
          == [(TEXT, 5, False), (BINARY, 256, False), (PING, 0, False)]
          and used == len(server_frames) - 1)
    check("a frame's RSV bits are reported", parse_frame(b"\xf1\x00")[0].rsv == 7)

    print("probelib selftest: a WebSocket against a scripted server")

    def serve(script):
        """Run `script(conn)` on the first connection; returns (port, thread)."""
        lsock = socket.socket()
        lsock.bind(("127.0.0.1", 0))
        lsock.listen(1)

        def run():
            conn, _ = lsock.accept()
            try:
                script(conn)
            except OSError:
                pass
            finally:
                conn.close()
                lsock.close()

        t = threading.Thread(target=run, daemon=True)
        t.start()
        return lsock.getsockname()[1], t

    def upgrade(conn, extra=b"", record=None):
        req = b""
        while b"\r\n\r\n" not in req:
            req += conn.recv(4096)
        # Recorded BEFORE the 101 goes out: the client returns as soon as it
        # reads the 101, so a record made after the send raced the check.
        if record is not None:
            record["request"] = req
        key = re.search(rb"Sec-WebSocket-Key: (\S+)", req).group(1).decode()
        conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                     b"Connection: Upgrade\r\nsec-websocket-accept: "
                     + ws_accept(key).encode() + b"\r\n\r\n" + extra)
        return req

    seen = {}

    def echo(conn):
        # The first frame is coalesced with the 101, as a kernel does to an
        # application that sends at once.
        upgrade(conn, extra=b"\x81\x05early", record=seen)
        buf = b""
        while True:
            got = parse_frame(buf)
            if got is None:
                chunk = conn.recv(65536)
                if not chunk:
                    return
                buf += chunk
                continue
            frame, end = got
            buf = buf[end:]
            seen.setdefault("frames", []).append(frame)
            if frame.opcode == TEXT:
                conn.sendall(b"\x89\x02hb" + struct.pack(">BB", 0x81, len(frame.payload))
                             + frame.payload)
            elif frame.opcode == CLOSE:
                conn.sendall(b"\x88\x02" + frame.payload[:2])
                return

    port, t = serve(echo)
    ws = WebSocket.connect("127.0.0.1", port, "/ws/x", timeout=5, host_header="x",
                           headers=[("Cookie", "a=b")])
    check("the handshake returns a 101 and the accept is the one owed",
          ws.status_line == b"HTTP/1.1 101 Switching Protocols" and ws.accept_ok())
    check("the request carries the path, the Host given and the extra header",
          seen["request"].startswith(b"GET /ws/x HTTP/1.1\r\nHost: x\r\nUpgrade: websocket")
          and b"\r\nCookie: a=b\r\n" in seen["request"])
    try:
        first = ws.recv_frame(deadline=time.monotonic() + 2)
    except socket.timeout:
        first = None
    check("a frame coalesced with the 101 is the first frame read, not lost",
          first == (TEXT, b"early"))
    ws.send_text("hi")
    check("recv_data answers the ping and returns the frame behind it",
          ws.recv_data() == (TEXT, b"hi"))
    ws.send_close(1000)
    check("a Close echoes back", ws.recv_data() == (CLOSE, struct.pack(">H", 1000)))
    check("recv_raw reads the FIN as b''", ws.recv_raw() == b"")
    ws.close()
    t.join(5)
    frames = seen.get("frames", [])
    check("the server saw masked frames: the text, the pong, the close",
          [(f.opcode, f.masked) for f in frames] == [(TEXT, True), (PONG, True), (CLOSE, True)]
          and frames[1].payload == b"hb")

    def cut(conn):
        upgrade(conn)
        conn.sendall(b"\x82\x7e\x00\xc8" + b"z" * 50)

    port, t = serve(cut)
    ws = WebSocket.connect("127.0.0.1", port, timeout=10)
    try:
        ws.recv_frame(eof_ok=True)
        said = None
    except EOFError as exc:
        said = str(exc)
    check("a close inside a frame is EOFError under eof_ok, saying how far in",
          said == "connection closed wanting 200 bytes (got 50)")
    ws.close()
    t.join(5)

    port, t = serve(lambda conn: (upgrade(conn), conn.sendall(b"\x81")))
    ws = WebSocket.connect("127.0.0.1", port, timeout=10)
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            ws.recv_frame()
        code = None
    except SystemExit as exc:
        code = exc.code
    check("...and without it, fail() with the words the copies used",
          code == 1 and out.getvalue().endswith(
              ": connection closed wanting 2 bytes (got 1)\n"))
    ws.close()
    t.join(5)

    port, t = serve(lambda conn: (upgrade(conn), conn.sendall(b"\x81\x82abcd" + b"xy")))
    ws = WebSocket.connect("127.0.0.1", port, timeout=10)
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            ws.recv_frame()
        code = None
    except SystemExit as exc:
        code = exc.code
    check("a masked server frame is fail()ed", code == 1
          and "server frame is masked (servers MUST NOT mask)" in out.getvalue())
    ws.close()
    t.join(5)

    # Pings for 3 s against a 2 s read timeout, then silence, as above.
    stop_pings = threading.Event()

    def pinger(conn):
        upgrade(conn)
        until = time.monotonic() + 3
        while not stop_pings.wait(0.05) and time.monotonic() < until:
            conn.sendall(b"\x89\x02hb")
        stop_pings.wait(30)

    port, t = serve(pinger)
    ws = WebSocket.connect("127.0.0.1", port, timeout=2)
    t0 = time.monotonic()
    try:
        ws.recv_data(deadline=t0 + 0.4)
        timed_out = False
    except socket.timeout:
        timed_out = True
    took = time.monotonic() - t0
    check("a deadline ends a read that pings would keep open for ever (%.2f s)" % took,
          timed_out and 0.3 < took < 2)
    check("...and puts the socket's own timeout back", ws.sock.gettimeout() == 2)
    stop_pings.set()
    ws.close()
    t.join(5)

    def hang_up(conn):
        # The request is read first: closing on unread bytes is an RST, and
        # the point here is the FIN.
        req = b""
        while b"\r\n\r\n" not in req:
            req += conn.recv(4096)

    port, t = serve(hang_up)
    ws = WebSocket.connect("127.0.0.1", port, timeout=10)
    check("a connection closed before any head: status_line None", ws.status_line is None)
    ws.close()
    t.join(5)

    print("probelib selftest: " + ("PASS" if ok else "FAIL"))
    return ok


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(0 if _selftest() else 1)
    print(__doc__)
    sys.exit(2)
