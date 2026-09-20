"""`m0 dev [-- HOST_ARGS]`: build, serve, and rebuild when a source changes.

Build-then-swap, and the order is the point. A build is ~10 s, which is too
long to be down, so the OLD server keeps serving while the next binary
compiles -- `m0 build` renames into place and never touches a running
inode -- and it keeps serving when that build FAILS: a syntax error costs a
compiler message, not the page in the browser. Only a build that succeeded
ends the old process:

    SIGTERM, by pid -> wait for that pid to exit -> start the new binary

The wait is `STOP_SECONDS` (6: the host's 5 s drain plus one). A process
still there after it is SIGKILLed and named on stderr, because the new
server cannot bind beside it. The new one starts only after the old one is
GONE, so there is never more than one process on the port. How it ended is
said (`pid N exited 0`): a drain that fails is otherwise invisible here.

What is watched is a stdlib mtime poll of `src/` and `pyproject.toml` --
no watcher dependency (D40). Edits that land during a build are seen by the
next poll, since the snapshot is taken BEFORE the build starts.

Ctrl-C (and SIGTERM) stop the server by pid and exit 0. A server that exits
on its own -- a refused configuration, a crash -- is reported with its code
and m0 dev stays up: the next edit builds and starts again.
"""

import os
import signal
import subprocess
import sys
import time

from m0 import build, checks, paths

POLL_SECONDS = 0.5
STOP_SECONDS = 6.0
WATCHED_FILE = "pyproject.toml"
WATCHED_DIR = "src"


def snapshot(project):
    """{path: (mtime_ns, size)} for everything a build reads from the project."""
    seen = {}
    single = project / WATCHED_FILE
    try:
        st = single.stat()
        seen[str(single)] = (st.st_mtime_ns, st.st_size)
    except OSError:
        pass
    for root, dirs, files in os.walk(project / WATCHED_DIR):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in files:
            # An editor's swap and backup files are not an edit.
            if name.startswith(".") or name.endswith("~"):
                continue
            path = os.path.join(root, name)
            try:
                st = os.stat(path)
            except OSError:
                continue
            seen[path] = (st.st_mtime_ns, st.st_size)
    return seen


def say(message):
    print(f"m0 dev: {message}", file=sys.stderr, flush=True)


def start(project, host_args):
    server = subprocess.Popen([str(project / paths.BINARY), *host_args], cwd=project)
    say(f"serving, pid {server.pid}")
    return server


def stop(server, wait=STOP_SECONDS):
    """End `server` by pid and return once it is GONE. True if it took SIGKILL."""
    if server is None or server.poll() is not None:
        return False
    server.send_signal(signal.SIGTERM)
    killed = False
    try:
        server.wait(timeout=wait)
    except subprocess.TimeoutExpired:
        say(f"pid {server.pid} did not exit within {wait:g} s of SIGTERM; sent SIGKILL")
        server.kill()
        server.wait()
        killed = True
    # The drain's own verdict: 0 is a clean one, and anything else is worth a
    # line in a loop that otherwise hides how the old process ended.
    say(f"pid {server.pid} exited {server.returncode}")
    return killed


class _Stop(Exception):
    pass


def _raise_stop(signum, frame):
    raise _Stop()


def run(args):
    project = args.project
    failed = checks.preflight(project)
    if failed is not None:
        return checks.refuse(failed)

    previous = signal.signal(signal.SIGTERM, _raise_stop)
    server = None
    try:
        seen = snapshot(project)
        if build.build(project) == 0:
            server = start(project, args.host_args)
        else:
            say("the build failed; nothing is serving yet -- fix it and save")
        while True:
            time.sleep(POLL_SECONDS)
            if server is not None and server.poll() is not None:
                say(f"the server exited {server.returncode} on its own; "
                    "the next edit builds and starts it again")
                server = None
            now = snapshot(project)
            if now == seen:
                continue
            seen = now
            say("change seen, building" + (
                f" (pid {server.pid} keeps serving)" if server is not None else ""))
            if build.build(project) != 0:
                say("the build failed" + (
                    f"; pid {server.pid} is still serving the last good build"
                    if server is not None else ""))
                continue
            stop(server)
            server = start(project, args.host_args)
    except (KeyboardInterrupt, _Stop):
        stop(server)
        return 0
    finally:
        signal.signal(signal.SIGTERM, previous)
        if server is not None and server.poll() is None:
            server.kill()
