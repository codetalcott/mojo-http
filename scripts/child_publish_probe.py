#!/usr/bin/env python3
"""Can a child process a view spawns publish onto the bus safely? (#322)

Serves `bareapp.childpub` under `--realtime` in each shape below and, for
each child mode (see that module), holds an SSE stream, has a view spawn one
child that publishes, and reads the child's frame off the stream. What each
mode must produce:

- `inherit`, `scrub`, `stale_fd`: the child exits 0 and publishes an
  UNNUMBERED frame (id -1, no `id:` line). Before the fix `inherit` was
  SIGSEGV on Linux (exit 139, the report) and, on macOS, exit 0 with an id
  taken from whatever the child had mapped at the parent's address -- 1,
  then 161, while the parent's counter stood at 3 -- which a subscriber that
  had seen a higher id then silently dropped. `stale_fd` also requires the
  file it put on the page's descriptor number to be untouched.
- `handoff`: `m0pub.child_fds()` passed, and the child's id comes from the
  SAME counter: strictly between the ids the parent took just before and
  just after, and on the frame's `id:` line.

The child must be able to load libm0core, or every mode publishes unnumbered
frames and the probe passes having reached nothing. The tree's macOS build
resolves the Mojo runtime next to itself (`@loader_path`), which only a
process that already has it loaded (the server) gets for free; so on macOS
the probe lays the library out the way the wheel's `_lib/` does, beside the
runtime `build-serve` bundles into `bin/`, and names it in `M0_CORE_LIB`.
Every numbered mode then asserts the child really took an id.

    python3 scripts/child_publish_probe.py --port 8671

Prints one `CHILD shape=... mode=... id=... exit=...` line per case.
"""
import argparse
import glob
import http.client
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import traceback

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PHASE = "startup"

SHAPES = [
    ("one-worker", []),
    ("workers-2", ["--workers", "2"]),
    ("spawn-workers", ["--workers", "2", "--spawn-workers"]),
]
UNNUMBERED = ("inherit", "scrub", "stale_fd")


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("child_publish_probe FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def core_lib(tmp):
    """A libm0core a plain Python child can load, and its path."""
    if sys.platform == "darwin":
        src = os.path.join(REPO, "packages", "m0-core", "libm0core.dylib")
        runtime = glob.glob(os.path.join(REPO, "bin", "*.dylib"))
        if not os.path.exists(src) or not runtime:
            sys.exit("need packages/m0-core/libm0core.dylib (poe build-ffi) and "
                     "bin/*.dylib (poe build-serve)")
        for path in [src] + runtime:
            shutil.copy(path, tmp)
        lib = os.path.join(tmp, "libm0core.dylib")
    else:
        lib = os.path.join(REPO, "packages", "m0-core", "libm0core.so")
        if not os.path.exists(lib):
            sys.exit("need packages/m0-core/libm0core.so (poe build-ffi)")
    check = subprocess.run(
        [sys.executable, "-c", "import ctypes,sys; ctypes.CDLL(sys.argv[1])", lib],
        capture_output=True, text=True)
    if check.returncode != 0:
        sys.exit("a plain Python process cannot load %s, so no child could "
                 "take an id and this probe would test nothing:\n%s" % (lib, check.stderr))
    return lib


def wait_healthy(port, log):
    deadline = time.time() + 120
    while time.time() < deadline:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            conn.request("GET", "/nope")
            conn.getresponse().read()
            conn.close()
            return
        except OSError:
            time.sleep(0.5)
    sys.exit("server never answered; it said:\n" + open(log).read())


def open_stream(port, channel):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    conn.request("GET", "/events?channel=" + channel,
                 headers={"Accept": "text/event-stream"})
    resp = conn.getresponse()
    if resp.status != 200:
        raise RuntimeError("stream on %s answered %d" % (channel, resp.status))
    line = resp.fp.readline()
    if not line.startswith(b": connected"):
        raise RuntimeError("stream on %s opened with %r" % (channel, line))
    return conn, resp


def read_child_frame(resp):
    """The `id:` of the frame carrying `from-child`, or None if it had none."""
    event_id = None
    while True:
        line = resp.fp.readline()
        if not line:
            raise RuntimeError("stream ended before the child's frame")
        text = line.decode("utf-8", "replace").rstrip("\r\n")
        if text.startswith("id: "):
            event_id = int(text[4:])
        elif text == "data: from-child":
            return event_id
        elif text == "":
            event_id = None


def run_case(port, shape, mode, problems):
    channel = "child-%s-%s" % (shape, mode)
    phase("%s/%s: holding the stream" % (shape, mode))
    conn, resp = open_stream(port, channel)
    try:
        phase("%s/%s: spawning" % (shape, mode))
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
        c.request("GET", "/spawn?mode=%s&channel=%s" % (mode, channel))
        answer = json.loads(c.getresponse().read())
        c.close()
        child = answer["child"]
        print("CHILD shape=%s mode=%s id=%s exit=%s before=%s after=%s"
              % (shape, mode, child.get("id"), child.get("exit"),
                 answer["before"], answer["after"]))
        where = "%s/%s" % (shape, mode)
        if "error" in child:
            problems.append("%s: %s" % (where, child["error"]))
            return
        if child.get("exit") != 0:
            problems.append("%s: the child exited %s (a negative code is the signal that killed it: -11 SIGSEGV); stderr: %s"
                            % (where, child.get("exit"), child.get("stderr", "").strip()[-400:]))
            return
        if answer["before"] <= 0:
            problems.append("%s: the parent took no id (%s), so nothing here is "
                            "numbered and the case proves nothing" % (where, answer["before"]))
            return
        got = child.get("id")
        if mode in UNNUMBERED and got != -1:
            problems.append("%s: the child published id %s where it has no page of "
                            "its own and must publish unnumbered (-1); the parent's "
                            "counter was at %s" % (where, got, answer["before"]))
        if mode == "handoff" and not (answer["before"] < got < answer["after"]):
            problems.append("%s: the child's id %s is not between the parent's %s and %s, "
                            "so it did not come from the shared counter"
                            % (where, got, answer["before"], answer["after"]))
        if mode == "stale_fd" and not child.get("occupied_file_untouched"):
            problems.append("%s: the file on the page's old descriptor number was written"
                            % where)
        phase("%s/%s: reading the child's frame" % (shape, mode))
        on_wire = read_child_frame(resp)
        want = None if got == -1 else got
        if on_wire != want:
            problems.append("%s: the frame carried id %s, the child reported %s"
                            % (where, on_wire, got))
    finally:
        conn.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(REPO, "bin", "m0serve"))
    ap.add_argument("--port", type=int, default=8671)
    ap.add_argument("--modes", default="inherit,scrub,stale_fd,handoff")
    args = ap.parse_args()

    problems = []
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, M0_CORE_LIB=core_lib(tmp))
        for i, (shape, flags) in enumerate(SHAPES):
            port = args.port + i
            log = os.path.join(tmp, shape + ".log")
            phase("%s: starting" % shape)
            srv = subprocess.Popen(
                [args.bin, "bareapp.childpub:application", "--app-dir",
                 os.path.join(REPO, "apps", "wsgi_bare"), "--realtime",
                 "--port", str(port)] + flags,
                stdout=open(log, "w"), stderr=subprocess.STDOUT, env=env, cwd=REPO)
            try:
                wait_healthy(port, log)
                for mode in args.modes.split(","):
                    run_case(port, shape, mode, problems)
            finally:
                srv.terminate()
                try:
                    srv.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    srv.kill()
    if problems:
        print("child_publish_probe FAIL:")
        for p in problems:
            print("  - " + p)
        return 1
    print("child_publish_probe OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
