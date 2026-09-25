"""smoke-scaffold-dev: `uv run m0 dev` on a scaffolded app, from OUTSIDE the tree.

    python3 scripts/m0_scaffold_dev_smoke.py dist/m0 PORT

`m0 dev` is build-then-swap, and every claim in that phrase is asked here
of a real process tree, with the literal `uv run m0 dev -- --port PORT` a
user types:

  first     m0 dev builds and serves; the pid it names is the ONE process
            listening on the port (asked of the kernel through lsof or ss,
            not of m0 dev)
  swap      one string literal edited. The port is polled from the moment of
            the edit: the OLD literal must be answered at least three times
            AFTER it -- the old server serving while the build runs -- before
            the new one is ever seen. Then the old pid is GONE -- ended by a
            drain, `exited 0`, not a kill -- the pid listening is a different
            one, and there is exactly one
  broken    a syntax error saved -- into the ENTRY file, because mojo 1.1.0
            builds an imported module holding a malformed `def` nothing calls
            without a word (measured here: exit 0). m0 dev reports the failed
            build, stays alive, and the SAME pid serves the SAME literal --
            polled for two more seconds, since a swap that came late would
            pass a check made once
  mended    the error removed and another literal changed: served, by a
            third pid. m0 dev was still watching after a failure
  stop      SIGINT to m0 dev ALONE (its pid, not the process group, so the
            server sees no signal but the one m0 dev sends it): the server is
            gone, nothing listens, and the `uv run` that started it all
            exits 0

The watcher is a poll, so every wait here is a poll with a deadline; nothing
sleeps a fixed time and hopes. Only the `views` template runs: `m0 dev`
never reads what it builds.
"""

import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from m0_scaffold_smoke import check_installed_is_the_wheel, clean_env, request, sh
from m0_wheel_smoke import ROOT, phase

EDITED = "src/pages.mojo"
OLD, NEW, NEWER = "nothing yet", "nothing yet, swapped", "nothing yet, mended"
BUILD_DEADLINE = 180


def fail(msg):
    print("smoke-scaffold-dev: " + msg, file=sys.stderr)
    sys.exit(1)


def emit(*args):
    subprocess.run([sys.executable, str(ROOT / "scripts" / "emit.py"), *args,
                    "--task", "smoke-scaffold-dev"])


def listeners(port):
    """The pids LISTENING on `port`, asked of the kernel."""
    lsof = shutil.which("lsof") or next(
        (p for p in ("/usr/sbin/lsof", "/usr/bin/lsof") if os.path.exists(p)), None)
    if lsof:
        done = subprocess.run([lsof, "-nP", "-iTCP:%d" % port, "-sTCP:LISTEN", "-t"],
                              capture_output=True, text=True)
        return sorted({int(p) for p in done.stdout.split()})
    ss = shutil.which("ss")
    if ss:
        done = subprocess.run([ss, "-ltnpH", "sport = :%d" % port],
                              capture_output=True, text=True)
        return sorted({int(p) for p in re.findall(r"pid=(\d+)", done.stdout)})
    fail("neither lsof nor ss is here to ask who listens on the port")


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def body(port):
    """GET /items' body, or None while nothing answers."""
    try:
        status, _, _, text = request(port, "GET", "/items")
        return text if status == 200 else None
    except OSError:
        return None


class Dev:
    def __init__(self, project, env, port):
        self.log_path = project.parent / "dev.log"
        self.log = open(self.log_path, "w")
        self.port = port
        # A session of its own, so cleanup can end the whole tree and so the
        # `stop` phase's signal reaches m0 dev alone.
        self.proc = subprocess.Popen(
            ["uv", "run", "m0", "dev", "--", "--port", str(port)], cwd=project, env=env,
            stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)

    def said(self):
        return self.log_path.read_text(errors="replace")

    def pids(self):
        return [int(p) for p in re.findall(r"^m0 dev: serving, pid (\d+)$", self.said(), re.M)]

    def must_live(self, when):
        if self.proc.poll() is not None:
            fail("m0 dev exited %d %s:\n%s" % (self.proc.returncode, when, self.said()[-3000:]))

    def wait_for(self, what, test, deadline=BUILD_DEADLINE):
        end = time.time() + deadline
        while time.time() < end:
            self.must_live("while waiting for " + what)
            got = test()
            if got:
                return got
            time.sleep(0.25)
        fail("%s did not happen inside %d s:\n%s" % (what, deadline, self.said()[-3000:]))

    def cleanup(self):
        if self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGKILL)
            except OSError:
                pass
        for pid in self.pids():
            if alive(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
        self.log.close()


def one_listener(dev, want, when):
    got = listeners(dev.port)
    if got != [want]:
        fail("%s the port is listened on by %s, and m0 dev names %d" % (when, got, want))


def edit(project, old, new):
    path = project / EDITED
    text = path.read_text()
    if text.count('"%s"' % old) != 1:
        fail("%s holds the literal %r %d times" % (EDITED, old, text.count('"%s"' % old)))
    path.write_text(text.replace('"%s"' % old, '"%s"' % new))


def run(work, whl, port):
    uv = shutil.which("uv")
    env = clean_env(UV_FIND_LINKS=str(whl.parent))
    python = os.path.realpath(sys.executable)
    # `--refresh-package m0`, for the reason m0_scaffold_smoke.check_new gives:
    # a rebuilt wheel under one version is otherwise served from uv's cache.
    sh([uv, "tool", "run", "--offline", "--refresh-package", "m0", "--python", python, "--from", str(whl),
        "m0", "new", "corner-dev"], work, env, "uvx m0 new")
    project = work / "corner-dev"
    sh(["uv", "sync", "--refresh-package", "m0"], project, env, "uv sync")
    check_installed_is_the_wheel(project, whl)

    phase("first")
    t0 = time.time()
    dev = Dev(project, env, port)
    try:
        dev.wait_for("the first build's server", lambda: OLD in (body(port) or ""))
        first_s = time.time() - t0
        if len(dev.pids()) != 1:
            fail("m0 dev named %s as serving after one build" % dev.pids())
        first = dev.pids()[0]
        one_listener(dev, first, "after the first build")
        print("first: pid %d serves %r, alone on the port, %.1f s from `uv run m0 dev`"
              % (first, OLD, first_s))

        phase("swap")
        edit(project, OLD, NEW)
        t0 = time.time()
        old_answers = 0
        end = time.time() + BUILD_DEADLINE
        while True:
            dev.must_live("during the rebuild")
            text = body(port)
            if text is not None and '%s<' % NEW in text:
                break
            if text is not None and '%s<' % OLD in text:
                old_answers += 1
            if "m0 dev: the server exited" in dev.said():
                # Its own sentence, apart from "never served": an old server
                # that was never stopped still holds the port, the new one
                # cannot bind beside it, and a watcher that saw nothing looks
                # the same from the port alone.
                fail("the swapped-in server exited on its own -- is the old one still "
                     "bound?\n" + dev.said()[-3000:])
            if time.time() > end:
                fail("the edited literal was never served:\n" + dev.said()[-3000:])
            time.sleep(0.5)
        swap_s = time.time() - t0
        if old_answers < 3:
            fail("the old server answered %d time(s) between the edit and the swap: it was "
                 "not serving while the build ran" % old_answers)
        if alive(first):
            fail("the old server, pid %d, is still running after the swap" % first)
        if "m0 dev: pid %d exited 0\n" % first not in dev.said():
            fail("m0 dev does not say the old server, pid %d, drained and exited 0:\n%s"
                 % (first, dev.said()[-2000:]))
        if len(dev.pids()) != 2 or dev.pids()[1] == first:
            fail("after one swap m0 dev has named %s" % dev.pids())
        second = dev.pids()[1]
        one_listener(dev, second, "after the swap")
        print("swap: %d old answers during the build, then pid %d -> %d, alone on the port, "
              "%.1f s from the save" % (old_answers, first, second, swap_s))
        emit("m0.dev_first_s", "%.1f" % first_s, "--unit", "s")
        emit("m0.dev_swap_s", "%.1f" % swap_s, "--unit", "s")

        phase("broken")
        entry = project / "src" / "server.mojo"
        good = entry.read_text()
        entry.write_text(good + "\ndef broken(:\n")
        dev.wait_for("the failed build's report", lambda: "m0 dev: the build failed" in dev.said())
        end = time.time() + 2
        while time.time() < end:
            dev.must_live("after a failed build")
            text = body(port)
            if text is None or '%s<' % NEW not in text:
                fail("after a failed build the port answers %r, not the last good build"
                     % (text or "nothing")[:200])
            time.sleep(0.25)
        if dev.pids() != [first, second] or not alive(second):
            fail("a failed build changed what serves: m0 dev names %s" % dev.pids())
        one_listener(dev, second, "after a failed build")
        print("broken: m0 dev alive, pid %d still serves %r" % (second, NEW))

        phase("mended")
        # The literal first: if a poll falls between the two writes, what it
        # builds is still broken, and no server is started for a half-mended tree.
        edit(project, NEW, NEWER)
        entry.write_text(good)
        dev.wait_for("the mended build's literal", lambda: '%s<' % NEWER in (body(port) or ""))
        if len(dev.pids()) != 3 or alive(second):
            fail("after the mended build m0 dev names %s and pid %d is %s"
                 % (dev.pids(), second, "alive" if alive(second) else "gone"))
        third = dev.pids()[2]
        one_listener(dev, third, "after the mended build")
        print("mended: pid %d serves %r" % (third, NEWER))

        phase("stop")
        # m0 dev is the server's parent; `uv run` is m0 dev's.
        parent = int(subprocess.run(["ps", "-o", "ppid=", "-p", str(third)],
                                    capture_output=True, text=True).stdout.strip() or 0)
        if parent in (0, 1, os.getpid()):
            fail("the server's parent is pid %d, which is not m0 dev" % parent)
        os.kill(parent, signal.SIGINT)
        try:
            code = dev.proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            fail("m0 dev did not exit inside 20 s of SIGINT:\n" + dev.said()[-2000:])
        if code != 0:
            fail("m0 dev exited %d on SIGINT, not 0:\n%s" % (code, dev.said()[-2000:]))
        if alive(third) or listeners(port):
            fail("after m0 dev exited, pid %d is %s and the port is listened on by %s"
                 % (third, "alive" if alive(third) else "gone", listeners(port)))
        if "sent SIGKILL" in dev.said():
            fail("a server was SIGKILLed; every stop here should have been a drain:\n"
                 + dev.said()[-2000:])
        print("stop: SIGINT to m0 dev alone; the server gone, the port free, exit 0")
    finally:
        dev.cleanup()


def main():
    if len(sys.argv) != 3:
        fail("usage: m0_scaffold_dev_smoke.py DIST_DIR PORT")
    wheels = sorted(Path(sys.argv[1]).glob("*.whl"))
    if len(wheels) != 1:
        fail("want exactly one wheel in %s, found %d" % (sys.argv[1], len(wheels)))
    whl = wheels[0].resolve()
    if "+" not in whl.name.split("-")[1]:
        fail("the wheel carries no local label (poe build-m0-wheel sets M0_WHEEL_LOCAL)")
    work = Path(tempfile.mkdtemp(prefix="m0-scaffold-dev-")).resolve()
    try:
        run(work, whl, int(sys.argv[2]))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("smoke-scaffold-dev OK")


if __name__ == "__main__":
    main()
