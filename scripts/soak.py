#!/usr/bin/env python3
"""Drive a real application under a mixed, adversarial workload — the soak.

    python3 scripts/soak.py --manifest scripts/soak_manifests/hybrid_mix.json \
        --serve "bin/m0serve --mount ..." --seconds 60
    python3 scripts/soak.py --manifest M --url URL --baseline capture.json
    python3 scripts/soak.py --manifest M --url URL --capture capture.json
    python3 scripts/soak.py --manifest M --serve CMD --churn-every 30 \
        --churn-mode sigterm
    python3 scripts/soak.py --selftest

`docs/REAL_APP_VALIDATION.md`'s phase 5 is *6,000 keep-alive requests over a
mixed route set, sampling RSS, fds and threads*. That shape found nothing on
its own: the keep-alive-cap defect fell out of it only because one route
happened to be hit 700 times, and it presented as **nine truncated bodies
under a clean 200**. Three of the six defects across both passes were silent
in exactly that way — correct status line, short or empty body, nothing in
the log — so a driver that counts non-2xx would have passed every one.

Hence what this does that a request loop does not:

- **It asserts bytes.** Every verified response is compared against a
  recorded capture: status, normalised headers, and a digest of the
  normalised body. `--baseline` records that capture from a REFERENCE server
  (gunicorn, uvicorn, runserver), which is how byte-exactness becomes
  checkable without understanding the application.
- **It runs five populations at once**, because every hard defect in this
  server has lived at a seam between shapes rather than in volume: short
  keep-alive bursts that force slot recycling, long-lived streams, bulk
  transfers and logins, WebSocket echoes, and abandoners — clients that
  vanish mid-body. A browser does the last one every time somebody
  navigates away; no pass had ever done it.
- **It logs in.** A manifest's `login` block is a CSRF form round trip with
  a cookie jar per session, so the authenticated surface of a real
  application is reachable — and the login response itself is verified
  against the capture, because the previous pass's first defect (every
  `Set-Cookie` losing `expires` and `SameSite`) lived exactly there.
- **It churns the server** (`--churn-every`): SIGTERM and restart, or a
  `--reload` touch, with every population mid-flight. Connection errors are
  tolerated inside that window and nowhere else; a body cut short is a
  failure even inside it, because a drain that truncates is the defect.

The comparator is a pure function of (capture, observation) so `--selftest`
can drive it directly. That matters: a digest checker that cannot fail is
the "green having tested nothing" trap this repo has been bitten by, and
this one is the whole instrument.
"""

import argparse
import base64
import hashlib
import http.client
import json
import os
import re
import shlex
import signal
import socket
import ssl  # noqa: F401  (http.client imports it lazily; fail early if absent)
import struct
import subprocess
import sys
import threading
import time
import traceback
from urllib.parse import urlencode, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


# --- the comparator: a pure function of text, which --selftest drives ------

DEFAULT_IGNORE = [
    # Per-server or per-request by design. `x-thread` is this server's own
    # (documented, and absent under --blocking-threads 0); `date` moves;
    # `connection` differs between m0serve and runserver by design.
    "date", "server", "connection", "keep-alive", "x-thread",
    "content-length",   # compared through the digest, which is stricter
]

_COOKIE_VALUE = re.compile(r"^([^=;]+)=[^;]*")
_COOKIE_EXPIRES = re.compile(r"(?i)expires=[^;]*")


def normalize_cookie(value):
    """`sessionid=abc; expires=<date>; HttpOnly` -> `sessionid=X; expires=X; HttpOnly`.

    The value and the date are per-session and per-second; the ATTRIBUTES are
    the assertion. Defect 1 of the 2026-08-26 pass was every cookie reaching
    the browser as `name=value; Max-Age=…; Path=/` where every other server
    sends `expires=…; HttpOnly; Max-Age=…; Path=/; SameSite=Lax`, and it was
    invisible to curl's cookie jar, which stores name and value only.
    """
    value = _COOKIE_VALUE.sub(r"\1=X", value, count=1)
    return _COOKIE_EXPIRES.sub("expires=X", value)


_HTTP_DATE = re.compile(
    r"^[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT$")


def normalize_headers(headers, ignore):
    """Ignore what the manifest names; keep everything else, with two values
    reduced to their shape: a Set-Cookie's value and date (see
    `normalize_cookie`), and an `Expires` that is an HTTP date — Django's
    `never_cache` stamps the request's own time there, so the header's
    PRESENCE is the assertion and its timestamp is per-request noise that
    made one run report 803 "distinct" failures for one difference."""
    drop = {h.lower() for h in ignore}
    out = []
    for name, value in headers:
        name = name.lower()
        if name in drop:
            continue
        if name == "set-cookie":
            value = normalize_cookie(value)
        elif name == "expires" and _HTTP_DATE.match(value.strip()):
            value = "<http-date>"
        out.append([name, value])
    return sorted(out)


def normalize_body(body, subs):
    """Apply the manifest's substitutions to a body before digesting it.

    Every substitution is a hole in the assertion, so they are named one at
    a time in the manifest rather than inferred. `--selftest` proves that a
    truncation still shows through them: a pattern greedy enough to hide one
    is the way this instrument would go quietly blind.
    """
    for pattern, replacement in subs:
        body = re.sub(pattern.encode(), replacement.encode(), body)
    return body


def truncation_visible(body, subs):
    """Can a truncation of THIS body still be seen through THESE patterns?

    A substitution is a hole in the assertion, and a greedy one is a hole
    the whole instrument falls through: `"csrf": ".*` collapses a body and
    its own first twenty bytes to the same text, so a truncated response
    digests identically to a whole one and the soak reports nothing. The
    self-test found that on its first run, which is the point of having one.

    Checked empirically against the real body rather than by inspecting the
    pattern: what matters is whether truncation survives normalisation here,
    not whether the regex looks greedy.
    """
    if not subs or not body:
        return True
    whole = normalize_body(body, subs)
    for cut in (len(body) * 9 // 10, len(body) // 2, 20, 0):
        if cut >= len(body):
            continue
        if normalize_body(body[:cut], subs) == whole:
            return False
    return True


def blinding_patterns(body, subs):
    """Which substitutions individually hide a truncation of this body."""
    return [pattern for pattern, replacement in subs
            if not truncation_visible(body, [[pattern, replacement]])]


def observe(status, headers, body, ignore, subs):
    """One response, reduced to what is worth comparing."""
    normalized = normalize_body(body, subs)
    return {
        "status": status,
        "headers": normalize_headers(headers, ignore),
        "digest": hashlib.sha256(normalized).hexdigest()[:16],
        "bytes": len(body),
        "normalized_bytes": len(normalized),
    }


def compare(expected, actual):
    """Differences between a captured observation and a live one.

    Returns a list of strings; empty means identical. Deliberately reports
    every difference rather than the first, because a header difference and
    a body difference have different causes and a caller that saw only one
    would chase the wrong thing.
    """
    diffs = []
    if expected["status"] != actual["status"]:
        diffs.append("status %s != %s" % (expected["status"], actual["status"]))
    if expected["digest"] != actual["digest"]:
        diffs.append("body digest %s != %s (%d != %d bytes)"
                     % (expected["digest"], actual["digest"],
                        expected["bytes"], actual["bytes"]))
    exp_h = dict((k, v) for k, v in expected["headers"])
    act_h = dict((k, v) for k, v in actual["headers"])
    for key in sorted(set(exp_h) | set(act_h)):
        if exp_h.get(key) != act_h.get(key):
            diffs.append("header %s: %r != %r"
                         % (key, exp_h.get(key), act_h.get(key)))
    return diffs


NORMALIZER_VERSION = 2   # bump when normalize_headers/normalize_body change


def rules_fingerprint(ignore, subs):
    """What a capture's observations depend on besides the responses.

    A capture recorded under one set of rules compared under another is
    wrong on every route and looks like the server changed: the first
    bakerydemo run reported 1,700 failures in 17 shapes, all of them the
    capture predating an `Expires` normalisation and a new substitution.
    The fingerprint is stored in the capture and checked on load."""
    material = json.dumps({"v": NORMALIZER_VERSION, "ignore": sorted(
        h.lower() for h in ignore), "subs": subs}, sort_keys=True)
    return hashlib.sha256(material.encode()).hexdigest()[:12]


def extract_csrf(body, pattern):
    """The token a login form carries, by the manifest's own pattern."""
    m = re.search(pattern.encode(), body)
    return m.group(1).decode("latin-1") if m else None


# --- cookies: one jar per session, never shared -----------------------------

class Jar:
    """The cookies one client holds. A jar is a SESSION, so it is per burst
    connection or per login, never global — a global jar would make every
    population one user, and the concurrent-login shape (a session write per
    request, the 2026-08-26 pass's phase 3) needs many."""

    def __init__(self):
        self.cookies = {}

    def absorb(self, headers):
        for name, value in headers:
            if name.lower() != "set-cookie":
                continue
            pair = value.split(";", 1)[0]
            if "=" not in pair:
                continue
            k, v = pair.split("=", 1)
            k = k.strip()
            # An emptied cookie with Max-Age=0 is a deletion.
            if v == "" or "max-age=0" in value.lower():
                self.cookies.pop(k, None)
            else:
                self.cookies[k] = v

    def header(self):
        return "; ".join("%s=%s" % kv for kv in self.cookies.items())

    def copy(self):
        j = Jar()
        j.cookies = dict(self.cookies)
        return j


# --- HTTP -----------------------------------------------------------------

USER_AGENT = "m0serve-soak/1 (+https://github.com/codetalcott/mojo-http)"
DEFAULT_HEADERS = {}   # set from the manifest's `headers` block at startup


class KeepAlive:
    """One connection, many requests — the shape the keep-alive cap governs.

    `http.client` reconnects transparently when the server closes, which is
    exactly what must NOT go unnoticed here: the cap closing the connection
    is correct, the cap destroying the response is the defect. So the
    reconnect is counted and reported rather than hidden.
    """

    def __init__(self, host, port, timeout=30):
        self.host, self.port, self.timeout = host, port, timeout
        self.conn = None
        self.reconnects = 0
        self.requests = 0

    def _connect(self):
        self.conn = http.client.HTTPConnection(
            self.host, self.port, timeout=self.timeout)

    def request(self, method, path, body=None, headers=None, jar=None):
        merged = dict(DEFAULT_HEADERS)
        merged.update(headers or {})
        headers = merged
        headers.setdefault("User-Agent", USER_AGENT)
        if jar is not None and jar.cookies:
            headers["Cookie"] = jar.header()
        for attempt in (0, 1):
            if self.conn is None:
                self._connect()
                if self.requests:
                    self.reconnects += 1
            try:
                self.conn.request(method, path, body=body, headers=headers)
                resp = self.conn.getresponse()
                data = resp.read()
                self.requests += 1
                if jar is not None:
                    jar.absorb(resp.getheaders())
                if resp.will_close:
                    self.close()
                return resp.status, resp.getheaders(), data
            except (http.client.HTTPException, OSError):
                self.close()
                if attempt:
                    raise
        raise AssertionError("unreachable")

    def close(self):
        if self.conn is not None:
            try:
                self.conn.close()
            except OSError:
                pass
            self.conn = None


def fetch(host, port, path, method="GET", body=None, headers=None,
          timeout=30, jar=None):
    conn = KeepAlive(host, port, timeout)
    try:
        return conn.request(method, path, body=body, headers=headers, jar=jar)
    finally:
        conn.close()


def raw_request(host, port, path, headers=""):
    """A socket-level GET, for populations that must control the close."""
    sock = socket.create_connection((host, port), timeout=30)
    extra = "".join("%s: %s\r\n" % kv for kv in DEFAULT_HEADERS.items()
                    if kv[0].lower() != "user-agent")
    ua = DEFAULT_HEADERS.get("User-Agent", USER_AGENT)
    req = ("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUser-Agent: %s\r\n%s%s\r\n"
           % (path, host, port, ua, extra, headers)).encode()
    sock.sendall(req)
    return sock


# --- login: a CSRF form round trip, verified like any other route ---------

def login(cfg, jar, stats=None, who="login"):
    """Log one session in through the manifest's form.

    GET the form (the CSRF cookie and the token in the page), POST the
    fields with the token, then GET the `check` route, which must be 200 —
    a 302 from the POST alone is what a WRONG password produces on many
    frameworks, so the redirect is not the proof; the page behind it is.
    Every leg is verified against the capture when one exists, because the
    login POST is where cookies are minted and where defect 1 lived.
    Raises on any failure: a login that does not work is a result, and the
    populations that depend on it must not run as anonymous users.
    """
    spec = cfg["login"]
    host, port = cfg["host"], cfg["port"]
    status, headers, body = fetch(host, port, spec["form"], jar=jar)
    if status != 200:
        raise RuntimeError("login form %s answered %d" % (spec["form"], status))
    fields = dict(spec.get("fields", {}))
    if spec.get("csrf_pattern"):
        token = extract_csrf(body, spec["csrf_pattern"])
        if token is None:
            raise RuntimeError("no CSRF token in %s matching %r"
                               % (spec["form"], spec["csrf_pattern"]))
        fields[spec.get("csrf_field", "csrfmiddlewaretoken")] = token
    fields.update(spec.get("extra", {}))
    post = spec.get("post", spec["form"])
    status, headers, body = fetch(
        host, port, post, method="POST", body=urlencode(fields).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded",
                 "Referer": "http://%s:%d%s" % (host, port, spec["form"])},
        jar=jar)
    if status != spec.get("expect_status", 302):
        raise RuntimeError("login POST %s answered %d, expected %d"
                           % (post, status, spec.get("expect_status", 302)))
    if stats is not None:
        verify(cfg, stats, "POST " + post, status, headers, body, who)
    check = spec.get("check")
    if check:
        status, headers, body = fetch(host, port, check, jar=jar)
        if status != 200:
            raise RuntimeError("logged in, but %s answered %d" % (check, status))
    return status, headers, body


def open_sessions(cfg, n):
    """N logins at once — the concurrent-login shape — into N jars."""
    jars = [Jar() for _ in range(n)]
    errors = []

    def one(jar):
        try:
            login(cfg, jar)
        except Exception as exc:
            errors.append(repr(exc))

    threads = [threading.Thread(target=one, args=(j,)) for j in jars]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if errors:
        raise RuntimeError("%d of %d logins failed: %s"
                           % (len(errors), n, errors[0]))
    return jars


def jar_for(cfg, route, i):
    """The jar a request on this route sends, or None.

    Only `auth` routes carry a session: an anonymous page fetched WITH a
    session renders differently on most frameworks (Wagtail's userbar,
    Django's toolbar), so sending cookies everywhere would make every
    anonymous digest disagree with the capture."""
    if not route.get("auth") or not cfg["sessions"]:
        return None
    return cfg["sessions"][i % len(cfg["sessions"])]


# --- WebSocket: enough of a client to hold a socket open and echo ---------

def ws_connect(host, port, path):
    key = base64.b64encode(os.urandom(16)).decode()
    sock = socket.create_connection((host, port), timeout=30)
    sock.sendall((
        "GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
        "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n" % (path, host, port, key)
    ).encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise OSError("closed during websocket handshake")
        buf += chunk
    head, rest = buf.split(b"\r\n\r\n", 1)
    if b" 101 " not in head.split(b"\r\n")[0]:
        raise OSError("upgrade refused: %s" % head.split(b"\r\n")[0])
    return sock, rest


def ws_send(sock, payload, opcode=0x1):
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    n = len(payload)
    if n < 126:
        head = struct.pack(">BB", 0x80 | opcode, 0x80 | n)
    elif n < 65536:
        head = struct.pack(">BBH", 0x80 | opcode, 0x80 | 126, n)
    else:
        head = struct.pack(">BBQ", 0x80 | opcode, 0x80 | 127, n)
    sock.sendall(head + mask + masked)


class WSReader:
    """Frame reader with a pushback buffer, answering pings transparently."""

    def __init__(self, sock, initial=b""):
        self.sock, self.buf = sock, initial

    def _exact(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError("closed wanting %d bytes" % n)
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def frame(self):
        b0, b1 = self._exact(2)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", self._exact(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", self._exact(8))[0]
        return b0 & 0x0F, self._exact(n)

    def message(self):
        while True:
            op, payload = self.frame()
            if op == 0x9:                       # server heartbeat ping
                ws_send(self.sock, payload, opcode=0xA)
                continue
            if op == 0xA:
                continue
            return op, payload


# --- resource sampling ----------------------------------------------------

def children_of(pid):
    try:
        out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True,
                             text=True, timeout=10).stdout.split()
        return [int(p) for p in out]
    except Exception:
        return []


def sample(pid):
    """RSS/fds/threads for the process under test. Never raises: a sampling
    failure must not be mistaken for the thing being measured (`emit.py`'s
    rule).

    Under a supervisor (`--workers N`, or `--reload`, which forces one) the
    pid the driver holds is the parent, whose 12 MB says nothing about the
    workers doing the serving — so when it has children, they are what is
    sampled, summed, with the count reported as `workers`."""
    kids = children_of(pid)
    if kids:
        parts = [_sample_one(k) for k in kids]
        out = {"workers": len(kids)}
        for key in ("rss_kb", "fds", "threads"):
            vals = [p[key] for p in parts if p[key] is not None]
            out[key] = sum(vals) if vals else None
        return out
    return _sample_one(pid)


def _sample_one(pid):
    out = {"rss_kb": None, "fds": None, "threads": None}
    try:
        rss = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=10)
        if rss.stdout.strip():
            out["rss_kb"] = int(rss.stdout.strip().split()[0])
    except Exception:
        pass
    try:
        lsof = subprocess.run(["lsof", "-p", str(pid)],
                              capture_output=True, text=True, timeout=30)
        if lsof.stdout:
            out["fds"] = max(0, len(lsof.stdout.strip().splitlines()) - 1)
    except Exception:
        pass
    try:
        if sys.platform == "darwin":
            ps = subprocess.run(["ps", "-M", "-p", str(pid)],
                                capture_output=True, text=True, timeout=10)
            if ps.stdout:
                out["threads"] = max(0, len(ps.stdout.strip().splitlines()) - 1)
        else:
            ps = subprocess.run(["ps", "-o", "nlwp=", "-p", str(pid)],
                                capture_output=True, text=True, timeout=10)
            if ps.stdout.strip():
                out["threads"] = int(ps.stdout.strip().split()[0])
    except Exception:
        pass
    return out


INTERESTING_METRICS = (
    "http_requests_total", "http_active_connections", "http_pool_available",
    "http_closes_total", "http_request_duration_us_count",
)


def scrape(host, port, path):
    """Read the server's own view of itself, so a sample is not only the OS's.

    `http_active_connections` and `http_pool_available` are the slot
    occupancy the populations are supposed to be churning; a soak that
    never looks at them cannot tell a leaked slot from a busy one.
    Never raises -- a scrape failure is not the thing being measured.
    """
    if not path:
        return {}
    try:
        status, _, body = fetch(host, port, path, timeout=10)
        if status != 200:
            return {}
    except OSError:
        return {}
    out = {}
    for line in body.decode("latin-1").splitlines():
        if line.startswith("#") or " " not in line:
            continue
        name, _, value = line.rpartition(" ")
        name = name.strip()
        if name in INTERESTING_METRICS:
            try:
                out[name] = int(float(value))
            except ValueError:
                pass
    return out


# --- the server, when the driver owns it ----------------------------------


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


class Server:
    """The process under test, started by the driver so it can be churned.

    `shlex.split` rather than `shell=True`: a signal must reach the server,
    not a shell in front of it — bash execs a single `-c` command in some
    versions and not others, and a SIGTERM that lands on `/bin/sh` is a
    drain that never happened. Callers needing shell features wrap the
    command as `sh -c "exec …"` and own that decision.
    """

    def __init__(self, cmd, log_path, cwd=REPO):
        self.argv = shlex.split(cmd)
        self.log_path = log_path
        self.cwd = cwd
        self.proc = None
        self.epoch = 0

    @property
    def pid(self):
        return self.proc.pid if self.proc else None

    def start(self):
        log = open(self.log_path, "ab")
        self.proc = subprocess.Popen(self.argv, cwd=self.cwd, stdout=log,
                                     stderr=subprocess.STDOUT)
        self.epoch += 1
        return self.proc.pid

    def stop(self, sig=signal.SIGTERM, budget=15.0):
        """Signal, wait within `budget`, and say what happened.

        Returns (exit_code or None if it had to be killed, seconds,
        orphans): the children recorded before the signal that are still
        alive after the parent left. A supervisor whose workers outlive it
        is `docker stop` leaving processes behind.
        """
        if self.proc is None:
            return None, 0.0, []
        kids = children_of(self.proc.pid)
        t0 = time.time()
        self.proc.send_signal(sig)
        try:
            code = self.proc.wait(timeout=budget)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=10)
            code = None
        elapsed = time.time() - t0
        time.sleep(0.2)
        orphans = [k for k in kids if alive(k)]
        self.proc = None
        return code, elapsed, orphans

    def reloads_completed(self):
        """How many `reload N complete` lines the supervisor has written.

        The exact line, by regex: the banner ends in the word `reload`
        too, and the first version of this counted words and never saw a
        reload that the log plainly recorded."""
        try:
            with open(self.log_path, "rb") as fh:
                return len(re.findall(rb"reload \d+ complete", fh.read()))
        except OSError:
            return 0


def wait_ready(host, port, path, seconds=30):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            status, _, _ = fetch(host, port, path, timeout=5)
            if status < 500:
                return True
        except OSError:
            pass
        time.sleep(0.25)
    return False


# --- populations ----------------------------------------------------------

class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.counts = {}
        # Deduplicated by message, because one systematic difference is one
        # finding: the first cross-server run reported the same header
        # mismatch 260,000 times and buried everything else under it.
        self.failures = {}
        # The churn window. A CONNECTION error inside it is expected — the
        # server is being restarted — and is counted, not failed. Nothing
        # else is forgiven inside it: a body that came back short during a
        # drain is precisely the defect a drain can have.
        self.window = False

    def bump(self, key, n=1):
        with self.lock:
            self.counts[key] = self.counts.get(key, 0) + n

    def fail(self, what, connection=False):
        with self.lock:
            if connection and self.window:
                self.counts["churn_tolerated"] = \
                    self.counts.get("churn_tolerated", 0) + 1
                return
            self.failures[what] = self.failures.get(what, 0) + 1
            self.counts["failures"] = self.counts.get("failures", 0) + 1

    def open_window(self):
        with self.lock:
            self.window = True

    def close_window(self):
        with self.lock:
            self.window = False


def pop_burst(cfg, stop, stats):
    """Short requests on long-lived connections, verified against the capture.

    `requests_per_connection` deliberately exceeds the server's keep-alive
    cap (100), so every connection crosses it repeatedly. That is the one
    previously-silent defect; here it is traffic rather than luck.
    """
    routes = [r for r in cfg["routes"] if r.get("class") == "short"]
    if not routes:
        return
    i = 0
    loops = 0
    while not stop.is_set():
        conn = KeepAlive(cfg["host"], cfg["port"])
        loops += 1
        try:
            for _ in range(cfg["requests_per_connection"]):
                if stop.is_set():
                    break
                route = routes[i % len(routes)]
                i += 1
                try:
                    status, headers, body = conn.request(
                        "GET", route["path"], jar=jar_for(cfg, route, loops))
                except OSError as exc:
                    stats.fail("burst %s: %r" % (route["path"], exc),
                               connection=True)
                    break
                stats.bump("burst_requests")
                verify(cfg, stats, route["path"], status, headers, body,
                       "burst")
        finally:
            stats.bump("burst_reconnects", conn.reconnects)
            conn.close()


def pop_stream(cfg, stop, stats):
    """Long-lived responses read to completion, byte for byte."""
    routes = [r for r in cfg["routes"] if r.get("class") == "stream"]
    if not routes:
        return
    i = 0
    while not stop.is_set():
        route = routes[i % len(routes)]
        i += 1
        try:
            status, headers, body = fetch(
                cfg["host"], cfg["port"], route["path"], timeout=60,
                jar=jar_for(cfg, route, i))
        except OSError as exc:
            stats.fail("stream %s: %r" % (route["path"], exc), connection=True)
            continue
        stats.bump("stream_reads")
        if "bytes" in route and len(body) != route["bytes"]:
            stats.fail("stream %s: %d bytes, expected %d"
                       % (route["path"], len(body), route["bytes"]))
        verify(cfg, stats, route["path"], status, headers, body, "stream")


def pop_bulk(cfg, stop, stats):
    """Uploads, slow views, and — when the manifest can — a fresh login per
    round: bodies in, workers held, and a session write per request."""
    uploads = cfg.get("uploads", [])
    slow = [r for r in cfg["routes"] if r.get("class") == "slow"]
    has_login = bool(cfg.get("login"))
    if not uploads and not slow and not has_login:
        return
    i = 0
    while not stop.is_set():
        if uploads:
            up = uploads[i % len(uploads)]
            payload = (b"m0soak" * ((up["size"] // 6) + 1))[:up["size"]]
            try:
                status, _, body = fetch(
                    cfg["host"], cfg["port"], up["path"], method="POST",
                    body=payload,
                    headers={"Content-Type": "application/octet-stream"},
                    timeout=60, jar=jar_for(cfg, up, i))
                stats.bump("uploads")
                if status != up.get("status", 200):
                    stats.fail("upload %s: status %d" % (up["path"], status))
                elif up.get("echo") and len(body) != len(payload):
                    stats.fail("upload %s echoed %d of %d bytes"
                               % (up["path"], len(body), len(payload)))
            except OSError as exc:
                stats.fail("upload %s: %r" % (up["path"], exc),
                           connection=True)
        if slow and not stop.is_set():
            route = slow[i % len(slow)]
            try:
                status, headers, body = fetch(
                    cfg["host"], cfg["port"], route["path"], timeout=60,
                    jar=jar_for(cfg, route, i))
                stats.bump("slow_requests")
                verify(cfg, stats, route["path"], status, headers, body,
                       "bulk")
            except OSError as exc:
                stats.fail("slow %s: %r" % (route["path"], exc),
                           connection=True)
        if has_login and not stop.is_set() \
                and time.time() >= cfg.get("next_login", 0):
            # `min_interval_seconds` in the manifest's login block paces the
            # logins to the APPLICATION's own rate limit (allauth's default
            # is 30 per minute per IP; textshelf adds a middleware of its
            # own). A driver that trips a limiter measures the limiter.
            cfg["next_login"] = time.time() + cfg["login"].get(
                "min_interval_seconds", 0)
            try:
                login(cfg, Jar(), stats, who="login")
                stats.bump("logins")
            except OSError as exc:
                stats.fail("login: %r" % (exc,), connection=True)
            except RuntimeError as exc:
                stats.fail("login: %s" % exc)
        i += 1


def pop_abandon(cfg, stop, stats):
    """Clients that vanish mid-body, then reuse the slot immediately.

    Two shapes, alternating, because they are different events on the
    server: a clean FIN, and an RST forced with SO_LINGER 0. Each is
    followed at once by a short request, so the freed slot is recycled
    while the abandoned producer may still be running — the arrangement
    that found the executor's slot-ownership bug.
    """
    routes = [r for r in cfg["routes"] if r.get("class") in ("stream", "abandon")]
    if not routes:
        return
    i = 0
    while not stop.is_set():
        route = routes[i % len(routes)]
        reset = bool(i % 2)
        i += 1
        try:
            jar = jar_for(cfg, route, i)
            extra = "Cookie: %s\r\n" % jar.header() if jar and jar.cookies else ""
            sock = raw_request(cfg["host"], cfg["port"], route["path"], extra)
            # Leave after a short WINDOW, not after a byte count. A slow SSE
            # route emits ~15 bytes every 150 ms, so waiting for a fixed
            # number of bytes turns an abandoner into a reader that times
            # out -- which is what the first run of this driver did, and it
            # counted as a failure of the server rather than of the client.
            sock.settimeout(0.25)
            deadline = time.time() + cfg["abandon_seconds"]
            got = 0
            while got < cfg["abandon_bytes"] and time.time() < deadline:
                try:
                    chunk = sock.recv(4096)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                got += len(chunk)
            if reset:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                struct.pack("ii", 1, 0))
            sock.close()
            stats.bump("abandon_rst" if reset else "abandon_fin")
        except OSError as exc:
            stats.fail("abandon %s: %r" % (route["path"], exc),
                       connection=True)
            continue
        short = [r for r in cfg["routes"] if r.get("class") == "short"]
        if short and not stop.is_set():
            route = short[i % len(short)]
            try:
                status, headers, body = fetch(
                    cfg["host"], cfg["port"], route["path"],
                    jar=jar_for(cfg, route, i))
                stats.bump("recycle_requests")
                verify(cfg, stats, route["path"], status, headers, body,
                       "recycle")
            except OSError as exc:
                stats.fail("recycle %s: %r" % (route["path"], exc),
                           connection=True)


def pop_websocket(cfg, stop, stats):
    """Open a socket, echo through it, and close from THIS side.

    Closing from the client is what Autobahn does; closing from the app is
    what it structurally cannot test. Both happen here — the sockets that
    outlive the run are closed by the server's drain at shutdown.
    """
    sockets = cfg.get("websockets", [])
    if not sockets:
        return
    i = 0
    while not stop.is_set():
        spec = sockets[i % len(sockets)]
        i += 1
        try:
            sock, rest = ws_connect(cfg["host"], cfg["port"], spec["path"])
            reader = WSReader(sock, rest)
            for n in range(spec.get("messages", 8)):
                if stop.is_set():
                    break
                payload = ("soak-%d-%s" % (n, "x" * spec.get("pad", 0)))
                ws_send(sock, payload.encode())
                op, got = reader.message()
                stats.bump("ws_messages")
                if spec.get("echo") and payload.encode() not in got:
                    stats.fail("ws %s: echo %r for %r"
                               % (spec["path"], got[:60], payload[:60]))
            ws_send(sock, struct.pack(">H", 1000), opcode=0x8)
            try:
                sock.settimeout(5)
                reader.message()
            except (EOFError, OSError):
                pass
            sock.close()
            stats.bump("ws_connections")
        except (OSError, EOFError) as exc:
            stats.fail("ws %s: %r" % (spec["path"], exc), connection=True)


# --- verification ---------------------------------------------------------

def slug(path):
    return re.sub(r"[^A-Za-z0-9._-]+", "_", path).strip("_") or "root"


def dump_body(dirpath, path, body):
    """Keep a body on disk, once per route. A digest says THAT two bodies
    differ; only the bytes say WHERE, and the site-history route cost two
    rounds of guessing before this existed."""
    try:
        os.makedirs(dirpath, exist_ok=True)
        target = os.path.join(dirpath, slug(path))
        if not os.path.exists(target):
            with open(target, "wb") as fh:
                fh.write(body)
    except OSError:
        pass


def verify(cfg, stats, path, status, headers, body, who):
    capture = cfg["capture"]
    actual = observe(status, headers, body, cfg["ignore"], cfg["subs"])
    expected = capture.get(path)
    if expected is None:
        # No baseline for this route: pin the FIRST response seen and hold
        # every later one to it. Weaker than a reference server (it cannot
        # catch a defect that was already there on request one) and said so
        # in the report, but it still catches drift under load — which is
        # where every silent truncation in this server has come from.
        bad = blinding_patterns(body, cfg["subs"])
        if bad:
            stats.fail("%s %s: body_sub %s hides a truncation of this body — "
                       "every later comparison on this route is blind"
                       % (who, path, ", ".join(bad)))
            return
        with stats.lock:
            if path not in capture:
                capture[path] = actual
                stats.counts["self_pinned"] = \
                    stats.counts.get("self_pinned", 0) + 1
                return
        expected = capture[path]
    diffs = compare(expected, actual)
    if diffs:
        if cfg.get("dump_dir"):
            dump_body(cfg["dump_dir"], path, body)
        stats.fail("%s %s: %s" % (who, path, "; ".join(diffs)))
    else:
        stats.bump("verified")


# --- churn ----------------------------------------------------------------

def churn(cfg, server, stats, args, ready_path):
    """One restart of the server under full load, accounted for.

    SIGTERM: the drain must exit 0 inside `--drain-budget`, leave no worker
    behind, and the restarted server must become ready. `reload`: touch the
    manifest's `reload_touch` file (nanosecond mtime is what the watcher
    compares) and wait for the supervisor's own `reload N complete` line,
    then readiness. Connection errors are tolerated from the signal to
    readiness and at no other time; everything else stays strict.
    """
    host, port = cfg["host"], cfg["port"]
    mode = args.churn_mode
    stats.open_window()
    t0 = time.time()
    try:
        if mode == "sigterm":
            code, elapsed, orphans = server.stop(signal.SIGTERM,
                                                 args.drain_budget)
            stats.bump("churn_restarts")
            print("  churn: SIGTERM -> exit %s in %.2fs%s"
                  % (code, elapsed,
                     ", ORPHANS %s" % orphans if orphans else ""))
            if code is None:
                stats.fail("churn: drain did not finish inside %.0fs; killed"
                           % args.drain_budget)
            elif code != 0:
                stats.fail("churn: drain exited %d, not 0" % code)
            if orphans:
                stats.fail("churn: %d worker(s) outlived the supervisor"
                           % len(orphans))
            with stats.lock:
                stats.counts["churn_drain_ms_max"] = max(
                    stats.counts.get("churn_drain_ms_max", 0),
                    int(elapsed * 1000))
            server.start()
        elif mode == "reload":
            touch = cfg.get("reload_touch")
            if not touch:
                stats.fail("churn: --churn-mode reload needs `reload_touch` "
                           "in the manifest")
                return
            before = server.reloads_completed()
            os.utime(os.path.join(REPO, touch), None)
            deadline = time.time() + args.drain_budget
            while time.time() < deadline:
                if server.reloads_completed() > before:
                    break
                time.sleep(0.2)
            else:
                stats.fail("churn: no `reload N complete` within %.0fs of "
                           "touching %s" % (args.drain_budget, touch))
            stats.bump("churn_restarts")
            print("  churn: touched %s -> reload reported in %.2fs"
                  % (touch, time.time() - t0))
        if not wait_ready(host, port, ready_path, seconds=args.drain_budget):
            stats.fail("churn: server never became ready again")
        with stats.lock:
            stats.counts["churn_window_ms_max"] = max(
                stats.counts.get("churn_window_ms_max", 0),
                int((time.time() - t0) * 1000))
    finally:
        stats.close_window()


# --- modes ----------------------------------------------------------------

def build_cfg(manifest, url, capture, args):
    parts = urlsplit(url)
    # A subject's own defences decide what a client must look like.
    # textshelf scores each request's headers for "bot-ness" and answers a
    # suspicious login with a FAKE success page (200, no form, no error),
    # so the manifest names the headers it needs rather than the driver
    # impersonating a browser everywhere.
    DEFAULT_HEADERS.clear()
    DEFAULT_HEADERS.update(manifest.get("headers", {}))
    return {
        "name": manifest.get("name", "unnamed"),
        "host": parts.hostname or "127.0.0.1",
        "port": parts.port or 80,
        "routes": manifest["routes"],
        "uploads": manifest.get("uploads", []),
        "websockets": manifest.get("websockets", []),
        "login": manifest.get("login"),
        "sessions": [],
        "reload_touch": manifest.get("reload_touch"),
        "ignore": manifest.get("headers_ignore", DEFAULT_IGNORE),
        "subs": manifest.get("body_sub", []),
        "capture": capture,
        "requests_per_connection": args.requests_per_connection,
        "abandon_bytes": args.abandon_bytes,
        "abandon_seconds": args.abandon_seconds,
        "metrics_path": args.metrics_path,
        "dump_dir": (args.log + ".diffs") if getattr(args, "log", None) else None,
    }


def cmd_baseline(manifest, url, args):
    """Record every route from a reference server — logged in where the
    manifest can be, so the authenticated surface is captured too."""
    cfg = build_cfg(manifest, url, {}, args)
    capture = {}
    blind = []
    if cfg["login"]:
        # The login POST's own observation is what verifies cookie minting
        # against the reference server on every later login.
        stats = Stats()
        cfg["capture"] = capture
        jar = Jar()
        _, _, post_body = login(cfg, jar, stats)
        if stats.failures:
            print("soak FAIL: login against the reference server: %s"
                  % list(stats.failures)[0])
            return 1
        cfg["sessions"] = [jar]
        print("  logged in; POST %s captured" % cfg["login"].get(
            "post", cfg["login"]["form"]))
    for i, route in enumerate(manifest["routes"]):
        if route.get("class") == "abandon":
            print("  skipped  %-28s (abandon-only: never read to completion)"
                  % route["path"])
            continue
        status, headers, body = fetch(
            cfg["host"], cfg["port"], route["path"], timeout=60,
            jar=jar_for(cfg, route, i))
        capture[route["path"]] = observe(
            status, headers, body, cfg["ignore"], cfg["subs"])
        dump_body(args.baseline + ".bodies", route["path"], body)
        # A capture whose substitutions hide a truncation of its own body
        # records nothing, and would report a clean run forever. Refuse it
        # here, where the real body is in hand and the pattern can be named.
        bad = blinding_patterns(body, cfg["subs"])
        if bad:
            blind.append((route["path"], bad))
        print("  captured %-28s %s %d bytes%s%s"
              % (route["path"], status, len(body),
                 "  (auth)" if route.get("auth") else "",
                 "  BLINDED by %s" % bad if bad else ""))
    if blind:
        print("soak FAIL: %d route(s) have a body_sub pattern that hides a "
              "truncation of their own body — narrow the pattern:" % len(blind))
        for path, bad in blind:
            print("    %s: %s" % (path, ", ".join(bad)))
        return 1
    with open(args.baseline, "w") as fh:
        json.dump({"url": url, "manifest": manifest.get("name"),
                   "rules": rules_fingerprint(cfg["ignore"], cfg["subs"]),
                   "routes": capture}, fh, indent=2, sort_keys=True)
    print("baseline written to %s (%d routes; bodies beside it in %s.bodies/)"
          % (args.baseline, len(capture), args.baseline))
    return 0


def cmd_run(manifest, url, args):
    capture = {}
    source = "self-pinned (first response seen)"
    if args.capture:
        with open(args.capture) as fh:
            loaded = json.load(fh)
        capture = loaded["routes"]
        source = "%s (%s)" % (args.capture, loaded.get("url", "?"))
        want = rules_fingerprint(manifest.get("headers_ignore", DEFAULT_IGNORE),
                                 manifest.get("body_sub", []))
        if loaded.get("rules") != want:
            print("soak FAIL: %s was recorded under different normalisation "
                  "rules (%s, now %s) — re-run --baseline before comparing"
                  % (args.capture, loaded.get("rules"), want))
            return 1

    server = None
    if args.serve:
        server = Server(args.serve, args.log, cwd=args.cwd or REPO)
        server.start()
    elif args.churn_every:
        print("soak FAIL: --churn-every needs --serve (the driver must own "
              "the process it restarts)")
        return 1

    cfg = build_cfg(manifest, url, capture, args)
    stats = Stats()
    try:
        ready_path = manifest.get("ready", manifest["routes"][0]["path"])
        if not wait_ready(cfg["host"], cfg["port"], ready_path):
            print("soak FAIL: %s never became ready" % url)
            return 1

        if cfg["login"]:
            try:
                cfg["sessions"] = open_sessions(cfg, args.sessions)
            except Exception as exc:
                print("soak FAIL: %s" % exc)
                return 1
            print("  %d sessions logged in concurrently" % len(cfg["sessions"]))
        elif any(r.get("auth") for r in cfg["routes"]):
            print("soak FAIL: the manifest has `auth` routes but no `login`")
            return 1

        pid = args.pid or (server.pid if server else None)
        print("soak: %s at %s for %ds" % (cfg["name"], url, args.seconds))
        print("  baseline: %s" % source)
        print("  populations: burst(%d) stream(%d) bulk(%d) abandon(%d) ws(%d)"
              % (args.burst, args.stream, args.bulk, args.abandon, args.ws))
        if args.churn_every:
            print("  churn: %s every %ds" % (args.churn_mode, args.churn_every))

        stop = threading.Event()
        threads = []
        for count, fn in ((args.burst, pop_burst), (args.stream, pop_stream),
                          (args.bulk, pop_bulk), (args.abandon, pop_abandon),
                          (args.ws, pop_websocket)):
            for _ in range(count):
                t = threading.Thread(target=_guard, args=(fn, cfg, stop, stats),
                                     daemon=True)
                t.start()
                threads.append(t)

        samples = []
        start = time.time()
        deadline = start + args.seconds
        next_churn = start + args.churn_every if args.churn_every else None
        while time.time() < deadline:
            wait = min(args.sample_interval, max(0.0, deadline - time.time()))
            if next_churn is not None:
                wait = min(wait, max(0.0, next_churn - time.time()))
            time.sleep(wait)
            if next_churn is not None and time.time() >= next_churn:
                if time.time() >= deadline - 2:
                    # Too close to the end to restart and re-verify; and a
                    # due-but-skipped churn must not leave `wait` at zero,
                    # which spun the sampler at 20 samples a second.
                    next_churn = None
                else:
                    churn(cfg, server, stats, args, ready_path)
                    pid = server.pid if server else pid
                    next_churn = time.time() + args.churn_every
                    continue
            s = sample(pid) if pid else {"rss_kb": None, "fds": None,
                                         "threads": None}
            s["t"] = round(time.time() - start, 1)
            s["epoch"] = server.epoch if server else 1
            s.update(scrape(cfg["host"], cfg["port"], cfg["metrics_path"]))
            samples.append(s)
            print("  [%5.1fs] rss=%skB fds=%s threads=%s%s conns=%s "
                  "verified=%d failures=%d"
                  % (s["t"], s["rss_kb"], s["fds"], s["threads"],
                     " workers=%d" % s["workers"] if s.get("workers") else "",
                     s.get("http_active_connections", "-"),
                     stats.counts.get("verified", 0),
                     stats.counts.get("failures", 0)))
        stop.set()
        for t in threads:
            t.join(timeout=30)
        return report(cfg, stats, samples, args)
    finally:
        if server is not None and server.proc is not None:
            code, elapsed, orphans = server.stop(signal.SIGTERM, 20)
            if code != 0 or orphans:
                print("  final stop: exit %s in %.1fs%s" % (
                    code, elapsed, ", orphans %s" % orphans if orphans else ""))


def _guard(fn, cfg, stop, stats):
    try:
        fn(cfg, stop, stats)
    except Exception as exc:            # a population must not die silently
        stats.fail("%s crashed: %r" % (fn.__name__, exc))
        traceback.print_exc()


def report(cfg, stats, samples, args):
    print("\n--- %s ---" % cfg["name"])
    for key in sorted(stats.counts):
        print("  %-22s %d" % (key, stats.counts[key]))
    growth = None
    if len(samples) >= 2:
        # Growth is measured within the LAST epoch: a restart is a fresh
        # process, and its RSS says nothing about the one before it.
        last_epoch = samples[-1].get("epoch", 1)
        epoch = [s for s in samples if s.get("epoch", 1) == last_epoch
                 and s["rss_kb"] is not None]
        if len(epoch) >= 2:
            growth = epoch[-1]["rss_kb"] - epoch[0]["rss_kb"]
            print("  rss %skB -> %skB (grew %dkB%s)"
                  % (epoch[0]["rss_kb"], epoch[-1]["rss_kb"], growth,
                     ", epoch %d" % last_epoch if last_epoch > 1 else ""))
        fds = [s["fds"] for s in samples if s["fds"] is not None]
        if fds:
            print("  fds %d -> %d (max %d)" % (fds[0], fds[-1], max(fds)))
        thr = [s["threads"] for s in samples if s["threads"] is not None]
        if thr:
            print("  threads %d -> %d (max %d)" % (thr[0], thr[-1], max(thr)))
        conns = [s["http_active_connections"] for s in samples
                 if "http_active_connections" in s]
        if conns:
            print("  active connections %d -> %d (max %d)"
                  % (conns[0], conns[-1], max(conns)))
        avail = [s["http_pool_available"] for s in samples
                 if "http_pool_available" in s]
        if avail:
            print("  free slots %d -> %d (min %d)"
                  % (avail[0], avail[-1], min(avail)))

    _record(cfg, stats, growth, args)

    if stats.failures:
        ranked = sorted(stats.failures.items(), key=lambda kv: -kv[1])
        print("\n  %d failure(s) in %d distinct shape(s):"
              % (stats.counts.get("failures", 0), len(ranked)))
        for message, count in ranked[:20]:
            print("    x%-7d %s" % (count, message))
        if len(ranked) > 20:
            print("    ... and %d more shape(s)" % (len(ranked) - 20))
        if cfg.get("dump_dir") and os.path.isdir(cfg["dump_dir"]):
            print("  first mismatching body per route kept in %s/ — diff "
                  "against the capture's .bodies/ directory" % cfg["dump_dir"])
        print("soak FAIL: %s" % cfg["name"])
        return 1
    if not stats.counts.get("verified"):
        print("soak FAIL: nothing was verified — the run proved nothing")
        return 1
    if getattr(args, "churn_every", 0) and not stats.counts.get("churn_restarts"):
        print("soak FAIL: churn was requested and never happened")
        return 1
    if args.max_rss_growth_kb and growth is not None \
            and growth > args.max_rss_growth_kb:
        print("soak FAIL: rss grew %dkB (limit %dkB)"
              % (growth, args.max_rss_growth_kb))
        return 1
    print("soak ok: %s" % cfg["name"])
    return 0


def _record(cfg, stats, growth, args):
    """Hand the numbers to `emit.py`, which never fails and no-ops without
    $M0_RESULTS. Nothing here gates on a recorded value — the gates above
    are the plain comparisons beside them."""
    try:
        sys.path.insert(0, HERE)
        import emit
        task = "soak-%s" % cfg["name"]
        emit.emit("soak verified responses", stats.counts.get("verified", 0),
                  unit="", task=task)
        emit.emit("soak failures", stats.counts.get("failures", 0),
                  unit="", task=task)
        if growth is not None:
            emit.emit("soak rss growth", growth, unit="KB", task=task,
                      limit=args.max_rss_growth_kb or None)
        if stats.counts.get("churn_drain_ms_max"):
            emit.emit("soak drain ms max", stats.counts["churn_drain_ms_max"],
                      unit="ms", task=task)
    except Exception:
        pass


# --- self-test: prove the comparator can fail -----------------------------

def cmd_selftest():
    """A comparator that cannot report a difference records nothing.

    Each case is the shape of a defect this repo has actually shipped: a
    truncated body under a clean status (defect 3 and the keep-alive cap),
    a lost cookie attribute (defect 1, every Set-Cookie), and a status that
    moved. Then the pieces the login and churn steps rest on: cookie
    normalisation that hides values but not attributes, CSRF extraction,
    a jar that absorbs and deletes, and the churn window forgiving only
    connection errors and only while open.
    """
    ignore = DEFAULT_IGNORE
    subs = [[r'"csrf": "[^"]*"', '"csrf": "X"']]
    body = b'{"csrf": "abcdef0123", "items": [1, 2, 3], "tail": "end"}'
    headers = [("Content-Type", "application/json"),
               ("Set-Cookie", "s=1; expires=X; HttpOnly; SameSite=Lax"),
               ("Date", "now"), ("X-Thread", "3")]
    good = observe(200, headers, body, ignore, subs)

    cases = []

    # 0. identical but for the ignored and substituted parts: NO difference.
    same = observe(200,
                   [("Content-Type", "application/json"),
                    ("Set-Cookie", "s=1; expires=X; HttpOnly; SameSite=Lax"),
                    ("Date", "later"), ("X-Thread", "7")],
                   body.replace(b"abcdef0123", b"9999999999"), ignore, subs)
    cases.append(("identical modulo ignore+substitution", same, False))

    # 1. a truncated body under a clean 200 — the silent defect.
    cases.append(("truncated body, clean status",
                  observe(200, headers, body[:20], ignore, subs), True))

    # 2. an empty body under a clean 200 — the keep-alive cap's shape.
    cases.append(("empty body, clean status",
                  observe(200, headers, b"", ignore, subs), True))

    # 3. a cookie that lost its attributes — defect 1's shape.
    cases.append(("Set-Cookie lost expires and SameSite",
                  observe(200, [("Content-Type", "application/json"),
                                ("Set-Cookie", "s=1; Path=/")],
                          body, ignore, subs), True))

    # 4. a status that moved.
    cases.append(("status 200 -> 500",
                  observe(500, headers, body, ignore, subs), True))

    # 5. a cookie differing ONLY in value and expiry date is the same cookie.
    cases.append(("Set-Cookie: new value, new date, same attributes",
                  observe(200, [("Content-Type", "application/json"),
                                ("Set-Cookie", "s=zzz9; expires=Thu, 01 Jan "
                                 "2027 00:00:00 GMT; HttpOnly; SameSite=Lax")],
                          body, ignore, subs), False))

    # 5b. an Expires header that is an HTTP date is per-request noise;
    #     one that is anything else (`0`, `-1`) is compared verbatim.
    cases.append(("Expires: a different HTTP date is the same header",
                  observe(200, headers + [("Expires", "Wed, 02 Sep 2026 "
                                           "02:14:26 GMT")], body, ignore, subs),
                  False,
                  observe(200, headers + [("Expires", "Wed, 02 Sep 2026 "
                                           "02:13:06 GMT")], body, ignore, subs)))
    cases.append(("Expires: 0 vs an HTTP date is a difference",
                  observe(200, headers + [("Expires", "0")], body, ignore, subs),
                  True,
                  observe(200, headers + [("Expires", "Wed, 02 Sep 2026 "
                                           "02:13:06 GMT")], body, ignore, subs)))

    bad = 0

    for case in cases:
        label, actual, should_differ = case[0], case[1], case[2]
        expected = case[3] if len(case) > 3 else good
        diffs = compare(expected, actual)
        ok = bool(diffs) == should_differ
        print("  %-4s %-46s %s" % ("ok" if ok else "FAIL", label,
                                   ("; ".join(diffs))[:70] or "no difference"))
        if not ok:
            bad += 1

    # 6. the blinding lint. A greedy substitution collapses a body and its
    #    own prefix to the same text, so `compare` CANNOT see the truncation
    #    -- proven here rather than assumed -- and the lint is what refuses
    #    the manifest instead.
    greedy = [[r'"csrf": ".*', '"csrf": "X"']]
    g_full = observe(200, headers, body, ignore, greedy)
    g_short = observe(200, headers, body[:20], ignore, greedy)
    if compare(g_full, g_short):
        print("  FAIL a greedy substitution was expected to hide a truncation")
        bad += 1
    else:
        print("  ok   a greedy substitution does hide a truncation from "
              "compare()")
    if truncation_visible(body, greedy):
        print("  FAIL the lint passed a substitution that hides a truncation")
        bad += 1
    else:
        print("  ok   the lint refuses it: %s" % blinding_patterns(body, greedy))
    if not truncation_visible(body, subs):
        print("  FAIL the lint refuses a narrow, legitimate substitution")
        bad += 1
    else:
        print("  ok   the lint passes the narrow substitution")

    # 7. the login pieces.
    form = (b'<form><input type="hidden" name="csrfmiddlewaretoken" '
            b'value="tok123"><input name="next" value="/admin/"></form>')
    pat = r'name="csrfmiddlewaretoken" value="([^"]+)"'
    if extract_csrf(form, pat) == "tok123" and extract_csrf(b"<p>", pat) is None:
        print("  ok   CSRF token extracted by pattern, and absent reports None")
    else:
        print("  FAIL CSRF extraction")
        bad += 1
    jar = Jar()
    jar.absorb([("Set-Cookie", "csrftoken=abc; Path=/; SameSite=Lax"),
                ("Set-Cookie", "sessionid=s1; HttpOnly")])
    jar.absorb([("Set-Cookie", "sessionid=s2; HttpOnly")])
    if jar.header() == "csrftoken=abc; sessionid=s2":
        print("  ok   jar keeps two cookies and takes the newer value")
    else:
        print("  FAIL jar header: %r" % jar.header())
        bad += 1
    jar.absorb([("Set-Cookie", 'csrftoken=""; expires=Thu, 01 Jan 1970 '
                 '00:00:00 GMT; Max-Age=0; Path=/')])
    if jar.header() == "sessionid=s2":
        print("  ok   a Max-Age=0 cookie is deleted from the jar")
    else:
        print("  FAIL jar after deletion: %r" % jar.header())
        bad += 1

    # 8. the churn window forgives connection errors only, and only while
    #    open — a truncation during a drain is still a failure.
    st = Stats()
    st.fail("burst /: ConnectionRefusedError", connection=True)
    st.open_window()
    st.fail("burst /: ConnectionRefusedError", connection=True)
    st.fail("stream /big: body digest a != b (999 != 262144 bytes)")
    st.close_window()
    st.fail("burst /: ConnectionRefusedError", connection=True)
    if st.counts.get("failures") == 3 and st.counts.get("churn_tolerated") == 1:
        print("  ok   churn window: 1 tolerated, 3 failed (2 outside, 1 "
              "truncation inside)")
    else:
        print("  FAIL churn window accounting: %s" % st.counts)
        bad += 1

    # 8b. a capture's rules fingerprint moves with the rules, and only then.
    fp = rules_fingerprint(ignore, subs)
    if fp != rules_fingerprint(ignore, subs + [["x", "y"]]) \
            and fp != rules_fingerprint(ignore + ["expires"], subs) \
            and fp == rules_fingerprint(list(reversed(ignore)), subs):
        print("  ok   rules fingerprint tracks the substitutions and ignores, "
              "not their order")
    else:
        print("  FAIL rules fingerprint")
        bad += 1

    # 9. the sampler must never raise, whatever it is handed.
    for pid in (os.getpid(), 999999999):
        try:
            sample(pid)
            print("  ok   sample(%d) returned without raising" % pid)
        except Exception as exc:
            print("  FAIL sample(%d) raised %r" % (pid, exc))
            bad += 1

    # 10. a run that verified nothing must not be reported as a pass, and
    #     neither may a run whose requested churn never happened. These are
    #     the "green having tested nothing" cases: every population can be
    #     running and every route unreachable.
    class _Args:
        max_rss_growth_kb = 0
        churn_every = 0
    empty = Stats()
    rc = report({"name": "selftest-empty"}, empty, [], _Args())
    if rc == 0:
        print("  FAIL a run with zero verified responses reported success")
        bad += 1
    else:
        print("  ok   a run with zero verified responses fails")
    verified = Stats()
    verified.bump("verified", 10)
    _Args.churn_every = 5
    rc = report({"name": "selftest-nochurn"}, verified, [], _Args())
    if rc == 0:
        print("  FAIL churn requested, never happened, reported success")
        bad += 1
    else:
        print("  ok   requested churn that never happened fails")

    print("soak selftest: %s" % ("FAIL" if bad else "ok"))
    return 1 if bad else 0


# --- main -----------------------------------------------------------------

def main():
    # A run is minutes long and its samples are the point of watching it;
    # block-buffered stdout hides them all until the process exits.
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--manifest")
    ap.add_argument("--url", default="http://127.0.0.1:8000")
    ap.add_argument("--serve", help="command that starts the server (no shell; "
                    "wrap as sh -c \"exec ...\" if one is needed)")
    ap.add_argument("--log", default="soak.log")
    ap.add_argument("--cwd", help="directory to start --serve in (default: "
                    "the repo). A real project usually has to be served from "
                    "its own directory -- bakerydemo resolves its templates "
                    "relative to it -- so name it, and give --serve an "
                    "absolute path to bin/m0serve")
    ap.add_argument("--pid", type=int, help="pid to sample (default: --serve's)")
    ap.add_argument("--baseline", help="record a capture from --url and exit")
    ap.add_argument("--capture", help="compare against this capture file")
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--sample-interval", type=float, default=5.0)
    ap.add_argument("--burst", type=int, default=4)
    ap.add_argument("--stream", type=int, default=2)
    ap.add_argument("--bulk", type=int, default=1)
    ap.add_argument("--abandon", type=int, default=1)
    ap.add_argument("--ws", type=int, default=1)
    ap.add_argument("--sessions", type=int, default=4,
                    help="logins opened concurrently at startup")
    ap.add_argument("--requests-per-connection", type=int, default=120,
                    help="deliberately over the server's keep-alive cap")
    ap.add_argument("--abandon-bytes", type=int, default=4096)
    ap.add_argument("--abandon-seconds", type=float, default=0.5,
                    help="how long an abandoner reads before vanishing")
    ap.add_argument("--metrics-path", default="/__metrics",
                    help="sampled each interval; \"\" to skip")
    ap.add_argument("--churn-every", type=float, default=0,
                    help="restart the server this often (needs --serve)")
    ap.add_argument("--churn-mode", choices=("sigterm", "reload"),
                    default="sigterm")
    ap.add_argument("--drain-budget", type=float, default=15.0,
                    help="seconds a drain (or reload) may take")
    ap.add_argument("--max-rss-growth-kb", type=int, default=0)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return cmd_selftest()
    if not args.manifest:
        ap.error("--manifest is required (or --selftest)")
    with open(args.manifest) as fh:
        manifest = json.load(fh)
    if args.baseline:
        return cmd_baseline(manifest, args.url, args)
    return cmd_run(manifest, args.url, args)


if __name__ == "__main__":
    sys.exit(main())
