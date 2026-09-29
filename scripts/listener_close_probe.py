#!/usr/bin/env python3
"""The listener is closed once, by the drain (review record B26; SPEC D1).

    python3 scripts/listener_close_probe.py LABEL [--serving N] [VAR=value ...] -- CMD ARGS...

Linux only, with `strace` on PATH. `{port}` in CMD is replaced by a free
port, which is also exported as M0_PORT. The server runs under `strace -f`,
answers one request, is sent SIGTERM, and must drain and exit 0; then, in
every process the trace shows, no close or shutdown of the listener's
number may fail.

The event loop closes its listener as its drain begins. Until B26 the
listener's owner closed the number again once the loop returned, when the
drain had left it free for up to 5 s and something else in the process had
usually been given it -- a `print`'s `dup(1)` on the loop thread, a pool
thread's `.pyc`. That close failed EBADF when the number was free again,
and otherwise closed a descriptor the owner did not own, whose own close
then failed EBADF; under `--spawn-workers` the adopted listener was shut
down first, the same way. m0serve's owners are in its entry file, which no
unit test can call, so this is their gate; `test_listener_owner.mojo`
holds the fork's `Server` and the Mojo host to it on both platforms, with
an instrument that keeps the number past the owner's return -- the one
interleaving a trace's return codes cannot show.

A meter that can read only silence proves nothing: the drain's own close
must be in the trace too -- in each of N processes (`--serving`, 1 by
default; one per worker under a supervisor, which never closes it), the
first close of the number after the process was sent SIGTERM, which is the
drain's because the number names the listener until then, must succeed.
The probe waits for N loops to start before it signals: a worker still
starting has not armed its handler, and dies by the signal instead.
"""

from __future__ import annotations

import http.client
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from probelib import NotServing, fail, free_port, phase, stamp, wait_healthy

# Which phase is running, for the crash handler: a traceback names the CALL
# that raised and never the PHASE being proven.
# scripts/phase_stamp_check.py holds every probe to it.
stamp("listener_close_probe: FAIL",
      fail="listener_close_probe: {phase}: FAIL: {msg}", stream=sys.stderr)

CALLS = "listen,close,shutdown,clone,clone3,fork,vfork"
DRAIN_S = 30
LOOP_STARTED = "Event loop started"
"""What `prepare_loop` prints as each loop starts."""

LINE = re.compile(r"^(\d+) +(\w+)\((.*)\) += (-?\d+)(.*)$")
UNFINISHED = re.compile(r"^(\d+) +(\w+)\((.*) <unfinished \.\.\.>$")
RESUMED = re.compile(r"^(\d+) +<\.\.\. (\w+) resumed>(.*)\) += (-?\d+)(.*)$")
SIGNAL = re.compile(r"^(\d+) +--- (SIG[A-Z0-9]+) ")


def calls(path: str) -> list[tuple[int, str, str, int, str]]:
    """(tid, name, args, result, rest) for every call the trace completed,
    in the order they completed -- strace splits a call another thread
    interrupted into an unfinished line and a resumed one -- and
    (tid, "SIGTERM", "", 0, "") where a signal was delivered."""
    pending: dict[int, tuple[str, str]] = {}
    out = []
    with open(path) as f:
        for raw in f:
            raw = raw.rstrip("\n")
            m = SIGNAL.match(raw)
            if m:
                out.append((int(m.group(1)), m.group(2), "", 0, ""))
                continue
            m = LINE.match(raw)
            if m:
                out.append((int(m.group(1)), m.group(2), m.group(3),
                            int(m.group(4)), m.group(5)))
                continue
            m = UNFINISHED.match(raw)
            if m:
                pending[int(m.group(1))] = (m.group(2), m.group(3))
                continue
            m = RESUMED.match(raw)
            if m:
                tid = int(m.group(1))
                name, args = pending.pop(tid, (m.group(2), ""))
                out.append((tid, name, args + m.group(3), int(m.group(4)),
                            m.group(5)))
    return out


def processes(seq) -> dict[int, int]:
    """tid -> the tid whose descriptor table it uses: a clone that shares
    files (a thread) uses its parent's, and anything else gets its own
    copy, which an `execve` keeps."""
    edges = [(tid, ret, "CLONE_FILES" in args) for tid, name, args, ret, _ in seq
             if name in ("clone", "clone3", "fork", "vfork") and ret > 0]
    table = {seq[0][0]: seq[0][0]} if seq else {}
    for _ in range(len(edges) + 1):
        grew = False
        for parent, child, shares in edges:
            if parent in table and child not in table:
                table[child] = table[parent] if shares else child
                grew = True
        if not grew:
            break
    return table


def first_arg(args: str) -> str:
    return args.split(",", 1)[0].strip()


def server_child(tracer: int) -> int:
    """The traced server: strace's own child."""
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % entry) as f:
                fields = f.read().rsplit(")", 1)[1].split()
        except OSError:
            continue
        if int(fields[1]) == tracer:
            return int(entry)
    return -1


def main() -> None:
    argv = sys.argv[1:]
    if "--" not in argv or len(argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    if platform.system() != "Linux":
        # Not a skip: a green run that traced nothing would read as a pass.
        # The task runs this on Linux only.
        print("listener_close_probe: strace is Linux's; refusing to run on %s"
              % platform.system(), file=sys.stderr)
        sys.exit(2)
    split = argv.index("--")
    label, options, cmd = argv[0], argv[1:split], argv[split + 1:]
    serving = 1
    env = dict(os.environ)
    i = 0
    while i < len(options):
        if options[i] == "--serving":
            serving = int(options[i + 1])
            i += 2
            continue
        name, value = options[i].split("=", 1)
        env[name] = value
        i += 1
    strace = shutil.which("strace")
    if strace is None:
        fail("strace is not on PATH (apt-get install strace): the count is the "
             "kernel's, and nothing else here can take it")

    phase("start %s under strace" % label)
    port = free_port()
    cmd = [a.replace("{port}", str(port)) for a in cmd]
    env.update(M0_PORT=str(port), M0_HOST="127.0.0.1")
    work = tempfile.mkdtemp(prefix="listener-close-")
    trace = os.path.join(work, "trace")
    log = open(os.path.join(work, "server.log"), "w+")
    tracer = subprocess.Popen(
        [strace, "-f", "-qq", "-s", "0", "-e", "trace=" + CALLS, "-o", trace] + cmd,
        env=env, stdout=log, stderr=subprocess.STDOUT,
    )
    try:
        # strace is the process watched: it exits with the server it traces.
        wait_healthy("http://127.0.0.1:%d/" % port, tracer, timeout=90, log=log,
                     status=None)
    except NotServing as exc:
        fail(str(exc))
    # One answer means one loop. A worker still starting when the signal
    # comes has not armed its handler yet, and dies by the signal instead of
    # draining, so every loop must have started first.
    deadline = time.monotonic() + 90
    while True:
        log.seek(0)
        started = log.read().count(LOOP_STARTED)
        if started >= serving:
            break
        if time.monotonic() > deadline or tracer.poll() is not None:
            fail("%d of %d loops started" % (started, serving))
        time.sleep(0.1)

    phase("%s: one request" % label)
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    conn.request("GET", "/")
    conn.getresponse().read()
    conn.close()

    phase("%s: SIGTERM, and the drain" % label)
    child = server_child(tracer.pid)
    if child < 0:
        fail("strace's child is not in /proc")
    os.kill(child, signal.SIGTERM)
    try:
        # strace exits with its child's status.
        code = tracer.wait(timeout=DRAIN_S)
    except subprocess.TimeoutExpired:
        tracer.kill()
        fail("still running %d s after SIGTERM" % DRAIN_S)
    if code != 0:
        log.seek(0)
        fail("%s exited %d after SIGTERM, not 0; its log ends:\n%s"
             % (label, code, "\n".join(log.read().splitlines()[-30:])))

    phase("%s: the listener's closes" % label)
    seq = calls(trace)
    listens = [int(first_arg(args)) for _, name, args, _, _ in seq if name == "listen"]
    if not listens:
        fail("no listen() in the trace: strace is not seeing the server")
    number = listens[0]
    table = processes(seq)
    # In a process holding the listener, the number names nothing else
    # until the listener is closed, so the first close of it after the
    # process was told to stop is the drain's.
    signalled: set[int] = set()
    drained: dict[int, int] = {}
    failed: list[str] = []
    seen = False
    for tid, name, args, ret, rest in seq:
        proc = table.get(tid, tid)
        if name == "listen":
            seen = True
        if name == "SIGTERM":
            signalled.add(proc)
            continue
        if not seen or name not in ("close", "shutdown") or first_arg(args) != str(number):
            continue
        if name == "close" and proc in signalled and proc not in drained:
            drained[proc] = ret
        if ret < 0:
            failed.append("process %d (thread %d): %s(%s) = %d%s"
                          % (proc, tid, name, args, ret, rest))
    for proc in sorted(drained):
        print("%s: process %d's drain closed descriptor %d: %s"
              % (label, proc, number, "ok" if drained[proc] == 0 else drained[proc]))
    print("listener_closes_failed %d" % len(failed))
    if failed:
        fail("descriptor %d, the listener's, was closed again after the drain "
             "had closed it -- by then free, or another part of the process's "
             "(review B26):\n  %s" % (number, "\n  ".join(failed)))
    ok = sum(1 for ret in drained.values() if ret == 0)
    if ok < serving:
        fail("the trace shows a drain closing descriptor %d in %d process(es), "
             "not %d: the meter did not see the close it guards"
             % (number, ok, serving))
    print("%s: descriptor %d closed by the drain alone, in %d process(es)"
          % (label, number, ok))


if __name__ == "__main__":
    main()
