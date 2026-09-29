#!/usr/bin/env python3
"""Every poe `shell` task parses under dash, and scripts/smoke/lib.sh keeps
its word.

poe runs a shell task by piping its body to `sh`: dash on the Linux runner,
bash's POSIX mode on macOS. Bash accepts arrays, here-strings and `function`
where dash stops with a syntax error, so a bashism written and run on a Mac
exits 2 on the ubuntu leg before its first assertion. `-n` reads a body
without running it; this runs it over every body under dash, and under
/bin/sh when that is another shell, after unindenting the body the way poe
does before it pipes it.

`-n` does not see everything. A bash parameter expansion is a RUN-TIME
error in dash ("Bad substitution"), which is how `${GOOD: -1}` reached the
Linux runner in smoke-fragment-notes, and `[[` is merely a command dash does
not have. So three rules also read each body's code, outside quotes,
comments and here-documents:

  - a bash parameter expansion (`${x:1}`, `${x: -1}`, `${x/a/b}`, `${x^^}`,
    `${x,,}`, `${!x}`) or a `[[` test;
  - a nested `uv run` without `--no-sync` or `--no-project`, which re-syncs
    the venv the task is running in: it swaps packages under anyone sharing
    that venv, and puts a canary's nightly toolchain back to the pin;
  - an assignment in front of a scripts/smoke/lib.sh function (`X=1 spawn
    ...`), which bash's POSIX mode keeps after the call returns, so every
    later command inherits it on macOS alone.

`--selftest` proves each rule can fail, then runs the lib under every shell
found: `fail`'s output as both sabotage harnesses parse it, `wait_ready`
failing fast on a server that died, `stop` and the exit trap reaping a whole
process group, an interrupted task killing its servers well inside the
1.6 s poe allows before it SIGKILLs the task, and `free_port` finding a run
of free ports.

    python3 scripts/check_task_shells.py              # every task body
    python3 scripts/check_task_shells.py --selftest   # the rules, and the lib
"""

from __future__ import annotations

import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = "scripts/smoke/lib.sh"
LIB_FUNCTIONS = ("spawn", "stop", "wait_ready", "free_port", "fail")


def shells() -> list[str]:
    """dash, then /bin/sh when it is a different shell. dash is what the
    Linux runner's `sh` is, and macOS ships it too."""
    found = []
    for name in ("dash", "/bin/sh"):
        path = shutil.which(name)
        if path and os.path.realpath(path) not in {os.path.realpath(p) for p in found}:
            found.append(path)
    return found


def unindent(body: str) -> str:
    """What poe pipes to the shell: `_unindent_code(content).rstrip()`."""
    if body.startswith(" "):
        indent = len(body) - len(body.lstrip(" "))
        prefix = " " * indent
        body = "\n".join(
            line[indent:] if line.startswith(prefix) else line
            for line in re.split(r"\r\n|\r|\n", body))
    return body.rstrip()


def shell_tasks(pyproject_text: str) -> dict[str, str]:
    """Task name -> the body poe pipes to `sh`, for every shell task (and
    every shell item of a sequence) that runs under a POSIX shell."""
    import tomllib  # 3.11+

    tasks = tomllib.loads(pyproject_text).get("tool", {}).get("poe", {}).get("tasks", {})
    out = {}
    for name, spec in tasks.items():
        items = [spec] if isinstance(spec, dict) else []
        if isinstance(spec, dict):
            items += [i for i in spec.get("sequence") or [] if isinstance(i, dict)]
        for n, item in enumerate(items):
            body = item.get("shell")
            interpreter = item.get("interpreter", "posix")
            if isinstance(interpreter, list):
                interpreter = interpreter[0] if interpreter else "posix"
            if isinstance(body, str) and interpreter in ("posix", "sh"):
                out[name if n == 0 else f"{name}[{n}]"] = unindent(body)
    return out


def parse_errors(body: str, shell: str) -> str:
    """The shell's complaint about `body` under `-n`, or '' if it parses."""
    p = subprocess.run([shell, "-n"], input=body, capture_output=True, text=True, timeout=60)
    if p.returncode == 0:
        return ""
    return (p.stderr or p.stdout).strip() or f"exit {p.returncode}"


def code_only(body: str, keep_double_quoted: bool = False) -> str:
    """`body` with its comments, quoted strings and here-document bodies
    blanked, so a rule reads what the shell would execute and not what it
    would print or pipe to Python. Line structure is kept. A double-quoted
    string still expands its parameters, so the expansion rule keeps those."""
    out, i, n = [], 0, len(body)
    heredocs: list[str] = []
    while i < n:
        c = body[i]
        if c == "\n":
            out.append(c)
            i += 1
            while heredocs:  # skip each pending here-document's body
                delim = heredocs.pop(0)
                while i < n:
                    end = body.find("\n", i)
                    end = n if end < 0 else end
                    line = body[i:end]
                    i = min(end + 1, n)
                    out.append("\n")
                    if line.lstrip("\t") == delim:
                        break
            continue
        if c == "\\" and i + 1 < n:
            out.append("  " if body[i + 1] != "\n" else " \n")
            i += 2
            continue
        if c == "'":
            end = body.find("'", i + 1)
            end = n - 1 if end < 0 else end
            out.append("''" + "\n" * body[i:end + 1].count("\n"))
            i = end + 1
            continue
        if c == '"':
            j = i + 1
            while j < n and body[j] != '"':
                j += 2 if body[j] == "\\" else 1
            if keep_double_quoted:
                out.append(body[i:j + 1])
            else:
                out.append('""' + "\n" * body[i:j + 1].count("\n"))
            i = j + 1
            continue
        if c == "#" and (i == 0 or body[i - 1] in " \t\n;&|()"):
            end = body.find("\n", i)
            i = n if end < 0 else end
            continue
        m = re.match(r"<<-?[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", body[i:])
        if m:
            heredocs.append(m.group(2))
            out.append(" " * len(m.group(0)))
            i += len(m.group(0))
            continue
        out.append(c)
        i += 1
    return "".join(out)


BASH_EXPANSION = re.compile(r"\$\{(?:!|[A-Za-z_][A-Za-z0-9_]*(?::(?![-=?+])|/|\^|,))")
DOUBLE_BRACKET = re.compile(r"(?:^|[\s;&|(!])\[\[\s")
NESTED_UV_RUN = re.compile(r"(?<![\w./-])uv\s+run\b([^\n]*)")
ASSIGN_BEFORE_LIB = re.compile(
    r"(?:^|[;&|{(]|\b(?:then|do|else)\b)[ \t]*(?:[A-Za-z_][A-Za-z0-9_]*=\S*[ \t]+)+"
    r"(" + "|".join(LIB_FUNCTIONS) + r")\b", re.M)


def lint(body: str) -> list[str]:
    """What `-n` cannot see, read from the body's code alone."""
    code = code_only(body)
    expanded = code_only(body, keep_double_quoted=True)
    problems = []
    for m in BASH_EXPANSION.finditer(expanded):
        line = expanded.count("\n", 0, m.start()) + 1
        problems.append(f"line {line}: `{m.group(0)}...` is a bash parameter "
                        "expansion; dash stops there with 'Bad substitution'")
    for m in DOUBLE_BRACKET.finditer(code):
        line = code.count("\n", 0, m.start()) + 1
        problems.append(f"line {line}: `[[` is bash's; dash has no such command")
    for m in NESTED_UV_RUN.finditer(code):
        if not re.search(r"--no-sync|--no-project", m.group(1)):
            line = code.count("\n", 0, m.start()) + 1
            problems.append(f"line {line}: a nested `uv run` without --no-sync "
                            "re-syncs the venv this task is running in")
    for m in ASSIGN_BEFORE_LIB.finditer(code):
        line = code.count("\n", 0, m.start()) + 1
        problems.append(f"line {line}: an assignment in front of `{m.group(1)}` "
                        "outlives the call under bash's POSIX mode; put it in the "
                        "command (`spawn x.log env A=1 cmd`)")
    return problems


def check(pyproject_text: str, use: list[str]) -> list[str]:
    failures = []
    bodies = shell_tasks(pyproject_text)
    if not bodies:
        return ["no shell task found in pyproject.toml -- the reader is broken"]
    for name, body in bodies.items():
        for sh in use:
            err = parse_errors(body, sh)
            if err:
                failures.append(f"{name}: does not parse under {sh}: {err}")
        failures += [f"{name}: {p}" for p in lint(body)]
    return failures


# --- selftest ----------------------------------------------------------------

_SCRATCH = ""
"""Where the lib makes its directories during the selftest, so the ones a
deliberately failing case keeps are removed with it."""


def _lib_env() -> dict:
    env = {k: v for k, v in os.environ.items() if k != "RUNNER_TEMP"}
    env["TMPDIR"] = _SCRATCH
    return env


def _run_lib(shell: str, script: str, timeout: float = 60) -> subprocess.CompletedProcess:
    """Run `script` under `shell` from the repo root, the lib sourced first.
    A run that outlives `timeout` comes back as exit None, so the case that
    asked reports it rather than the selftest dying of it."""
    try:
        return subprocess.run(
            [shell, "-c", f". {LIB}\n{script}"], cwd=ROOT, capture_output=True,
            text=True, timeout=timeout, env=_lib_env())
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        return subprocess.CompletedProcess(e.cmd, None, out, f"(still running at {timeout}s)")


def _gone(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def _wait_gone(pgid: int, seconds: float) -> bool:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if _gone(pgid):
            return True
        time.sleep(0.05)
    return _gone(pgid)


def _kill_group(pgid) -> None:
    """Whatever a case left running, whether or not the lib reaped it: a
    sabotaged lib is exactly the one that leaves a group behind."""
    try:
        os.killpg(int(pgid), signal.SIGKILL)
    except (ValueError, OSError):
        pass


_READY = ("until grep -q ready \"$SMOKE_DIR/{log}\" 2>/dev/null; do sleep 0.05; done\n")
"""Wait for a spawned command to say it is running. Until spawn's shim has
exec'd it, a signal reaches the shim instead, and the case tests nothing."""


def _interrupt(shell: str, then: str, delay: float, env: dict | None = None) -> tuple:
    """Spawn a server that ignores TERM, run `then` (which prints $pid), and
    SIGINT the task's own group `delay` seconds later, as poe does. Returns
    (exit status or None, seconds from the SIGINT to the exit, server pid);
    the caller judges the server, then `_kill_group`s it whatever it found."""
    # `ready` once the trap is set: until spawn's shim has exec'd the
    # command, a TERM reaches the shim and kills it, and there is no
    # TERM-ignoring server to test against.
    proc = subprocess.Popen(
        [shell, "-c", f". {LIB}\nspawn stubborn.log sh -c 'trap \"\" TERM; echo ready; exec sleep 60'\n"
                      + _READY.format(log="stubborn.log") + then],
        cwd=ROOT, stdout=subprocess.PIPE, text=True, start_new_session=True,
        env=env or _lib_env())
    child, rc, took, running = "", None, 0.0, False
    try:
        child = proc.stdout.readline().strip()
        time.sleep(delay)
        running = proc.poll() is None
        t0 = time.monotonic()
        try:
            os.killpg(proc.pid, signal.SIGINT)
        except OSError:
            pass  # the task had already exited: `running` says so
        try:
            rc = proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            rc = None
        took = time.monotonic() - t0
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
        proc.stdout.close()
    return rc, took, child, running


def _lib_cases(shell: str) -> list[str]:
    """Each claim scripts/smoke/lib.sh makes, run under `shell`."""
    sys.path.insert(0, str(ROOT / "scripts"))
    import host_sabotage
    import notes_login_sabotage

    bad = []

    # fail: the message, then each log under its header, in the shape both
    # sabotage harnesses read -- the line before the first header.
    p = _run_lib(shell, "printf 'booted\\n' > \"$SMOKE_DIR/fragment.log\"\n"
                        "printf 'no newline' > \"$SMOKE_DIR/refusal.log\"\n"
                        "printf 'x' > \"$SMOKE_DIR/notes.bin\"\n"
                        "echo \"$SMOKE_DIR\" >&2\n"
                        "fail 'expected 303 from a good login, got 200'")
    want = ("expected 303 from a good login, got 200\n=== fragment.log ===\nbooted\n"
            "=== refusal.log ===\nno newline\n")
    if p.returncode != 1 or p.stdout != want:
        bad.append(f"fail printed {p.stdout!r} and exited {p.returncode}; want {want!r}, 1")
    if host_sabotage.why(p.stdout) != "expected 303 from a good login, got 200":
        bad.append(f"host_sabotage.why read {host_sabotage.why(p.stdout)!r} from fail")
    if notes_login_sabotage._detail(p.stdout) != "  (expected 303 from a good login, got 200)":
        bad.append(f"notes_login_sabotage read {notes_login_sabotage._detail(p.stdout)!r}")
    kept = Path(p.stderr.strip().splitlines()[-1]) if p.stderr.strip() else None
    names = sorted(f.name for f in kept.iterdir()) if kept and kept.is_dir() else None
    if names != ["fragment.log", "refusal.log"]:
        bad.append(f"a failed task did not keep its logs, and only its logs: {names}")
    if kept:
        shutil.rmtree(kept, ignore_errors=True)
    # `probe || fail`: no message of fail's own, so the probe's reason is the
    # line the harnesses read.
    p = _run_lib(shell, "echo booted > \"$SMOKE_DIR/ht.log\"; echo \"$SMOKE_DIR\" >&2\n"
                        "sh -c 'echo \"FAIL: no 408 for a silent connection\"; exit 1' || fail")
    want = "FAIL: no 408 for a silent connection\n=== ht.log ===\nbooted\n"
    if p.returncode != 1 or p.stdout != want:
        bad.append(f"a bare fail printed {p.stdout!r}; want {want!r}")
    if host_sabotage.why(p.stdout) != "FAIL: no 408 for a silent connection":
        bad.append(f"host_sabotage.why read {host_sabotage.why(p.stdout)!r} after a bare fail")
    if p.stderr.strip():
        shutil.rmtree(p.stderr.strip().splitlines()[-1], ignore_errors=True)

    # A passing task leaves nothing behind.
    p = _run_lib(shell, "echo \"$SMOKE_DIR\"; echo x > \"$SMOKE_DIR/a.log\"")
    if p.returncode != 0 or Path(p.stdout.strip()).exists():
        bad.append(f"a passing task left {p.stdout.strip()} behind (exit {p.returncode})")

    # wait_ready answers as soon as the server does ...
    p = _run_lib(shell, "port=$(free_port)\n"
                        "spawn http.log python3 -m http.server --bind 127.0.0.1 $port\n"
                        "wait_ready http://127.0.0.1:$port/ $pid 30 && echo READY")
    if p.returncode != 0 or "READY" not in p.stdout:
        bad.append(f"wait_ready never saw a live server: {p.stdout[-300:]}")
    # ... and fails at once, with the log, when the server has died.
    t0 = time.monotonic()
    p = _run_lib(shell, "spawn dead.log sh -c 'echo cannot bind; exit 3'\n"
                        "wait_ready http://127.0.0.1:$(free_port)/ $pid 20")
    took = time.monotonic() - t0
    first = p.stdout.split("\n", 1)[0]
    if (p.returncode != 1 or not first.startswith("the server logging to dead.log")
            or "exited before" not in first or "cannot bind" not in p.stdout):
        bad.append(f"wait_ready on a dead server: exit {p.returncode}, {p.stdout[-300:]!r}")
    if took > 15:
        bad.append(f"wait_ready took {took:.0f}s to notice a dead server; it spun to the timeout")

    # stop: TERM to the whole group, and the grace lasts until the GROUP has
    # gone. The leader dies of TERM at once, as a supervisor may, while a
    # worker takes half a second to drain: it must be let finish, which
    # neither a TERM to the leader alone nor a wait on the leader alone does.
    t0 = time.monotonic()
    p = _run_lib(shell, "spawn drain.log sh -c 'sh -c \"trap \\\"sleep 0.5; echo drained; "
                        "exit 0\\\" TERM; echo ready; while :; do sleep 0.1; done\" & sleep 60'\n"
                        + _READY.format(log="drain.log") +
                        "echo $pid; _smoke_grace=5; stop $pid; echo \"status $?\"; "
                        "grep -v ready \"$SMOKE_DIR/drain.log\"")
    took = time.monotonic() - t0
    lines = p.stdout.split("\n")
    if not lines[0].isdigit() or not _wait_gone(int(lines[0]), 2):
        bad.append(f"stop left a draining group standing: {p.stdout!r}")
    elif "status 143" not in lines or "drained" not in lines:
        bad.append(f"stop did not let a group member drain on TERM: {p.stdout!r}")
    elif took > 4.5:
        bad.append(f"stop waited {took:.1f}s for a group that drained in 0.5s")
    _kill_group(lines[0])
    # A member that ignores TERM is KILLed once the grace is spent.
    p = _run_lib(shell, "spawn tree.log sh -c 'sh -c \"trap \\\"\\\" TERM; echo ready; sleep 60\" & sleep 60'\n"
                        + _READY.format(log="tree.log") +
                        "echo $pid; _smoke_grace=1; stop $pid; echo \"status $?\"")
    lines = p.stdout.split()
    if len(lines) < 3 or not lines[0].isdigit() or not _wait_gone(int(lines[0]), 2):
        bad.append(f"stop left the group standing: {p.stdout!r} {p.stderr[-200:]!r}")
    elif lines[-1] != "143":
        bad.append(f"stop returned {lines[-1]}; the leader died of TERM, so want 143")
    _kill_group(lines[0] if lines else "")

    # The exit trap reaps a group whose leader is already gone: a supervisor
    # that crashed and left a worker, which `kill $pid` cannot reach.
    p = _run_lib(shell, "spawn orphan.log sh -c 'sleep 60 & echo ready; exit 0'\n"
                        + _READY.format(log="orphan.log") + "echo $pid")
    if not p.stdout.strip().isdigit() or not _wait_gone(int(p.stdout.strip()), 2):
        bad.append("the exit trap left an orphaned group member running")
    _kill_group(p.stdout.strip())

    # Interrupted as poe interrupts it -- SIGINT to the task's own group,
    # which holds nothing spawn started -- the servers die at once: poe
    # SIGKILLs the task 1.6 s later, and a graceful wait would be cut off.
    rc, took, child, running = _interrupt(shell, "echo $pid; sleep 60", 0.3)
    if not running or rc != 130:
        bad.append(f"an interrupted task exited {rc}, not 130 (running when signalled: "
                   f"{running}; None: still running at 10s)")
    elif took > 1.2 or not child.isdigit() or not _wait_gone(int(child), 0.2):
        bad.append(f"an interrupted task took {took:.1f}s to stop its server "
                   f"({child or 'no pid'}); poe SIGKILLs the task at 1.6s")
    _kill_group(child)
    # The same interrupt arriving while the exit trap is already waiting out
    # the grace for that server: it ends the grace, and the server still dies.
    rc, took, child, running = _interrupt(shell, "echo $pid; exit 0", 1.0)
    gone = child.isdigit() and _wait_gone(int(child), 0.2)
    if not running:
        bad.append("the exit trap did not wait out the grace for a server ignoring TERM")
    elif rc is None or took > 1.2 or not gone:
        bad.append(f"an interrupt during cleanup: exit {rc} after {took:.1f}s, and the "
                   f"server {'gone' if gone else 'LEFT RUNNING'}")
    _kill_group(child)
    # The same again, landing while the reap is asking `ps` whether the server
    # is alive -- the likeliest moment, since that is most of each pass. The
    # interrupt reaches the task's whole group, `ps` included, and a `ps`
    # killed before it answered says nothing: read as "exited", it sent the
    # reap to `wait` on a server that ignores TERM, for as long as it lived.
    # A `ps` slowed to seconds puts the interrupt there every time.
    real_ps = shutil.which("ps")
    if real_ps:
        shim = Path(_SCRATCH) / "slow-ps"
        shim.mkdir(exist_ok=True)
        (shim / "ps").write_text(f'#!/bin/sh\nsleep 5\nexec {real_ps} "$@"\n')
        (shim / "ps").chmod(0o755)
        env = _lib_env()
        env["PATH"] = f"{shim}{os.pathsep}{env.get('PATH', '')}"
        rc, took, child, running = _interrupt(shell, "echo $pid; exit 0", 1.0, env)
        gone = child.isdigit() and _wait_gone(int(child), 0.2)
        if not running:
            bad.append("with a slow ps, the exit trap did not wait out the grace")
        elif rc is None or took > 1.2 or not gone:
            bad.append(f"an interrupt that killed the reap's ps: exit {rc} after {took:.1f}s, "
                       f"and the server {'gone' if gone else 'LEFT RUNNING'}")
        _kill_group(child)

    # free_port: free on every IPv4 and IPv6 address, as a server binds it.
    p = _run_lib(shell, "free_port")
    port = int(p.stdout.strip()) if p.stdout.strip().isdigit() else 0
    try:
        for family, addr in ((socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")):
            s = socket.socket(family, socket.SOCK_STREAM)
            try:
                if family == socket.AF_INET6:
                    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                s.bind((addr, port))
            finally:
                s.close()
    except OSError as e:
        bad.append(f"free_port printed {p.stdout.strip()!r}, which does not bind: {e}")

    # free_port N: the first of N consecutive ports, every one of them free
    # on both families, for a probe that takes one port per shape upward from
    # the one it is given. Where bind(0) counts up, as macOS's does, the port
    # free_port starts from is the one after `q`, so a listener one past THAT
    # sits where a free_port that checked its first port alone would put its
    # second -- and, held through the check, fails that answer. Where the
    # kernel picks at random (Linux) the listener is only in the way by luck.
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.bind(("", 0))
    q = probe.getsockname()[1]
    probe.close()
    trap = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        trap.bind(("", q + 2))
        trap.listen(1)
    except OSError:
        trap.close()
        trap = None
    try:
        p = _run_lib(shell, "free_port 3")
        base = int(p.stdout.strip()) if p.stdout.strip().isdigit() else 0
        try:
            for port in range(base, base + 3):
                for family, addr in ((socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")):
                    s = socket.socket(family, socket.SOCK_STREAM)
                    try:
                        if family == socket.AF_INET6:
                            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                        s.bind((addr, port))
                    finally:
                        s.close()
        except OSError as e:
            bad.append(f"free_port 3 printed {p.stdout.strip()!r}, and port {port} of its "
                       f"run does not bind: {e}")
    finally:
        if trap is not None:
            trap.close()
    p = _run_lib(shell, "free_port 0")
    if p.returncode == 0 or "usage" not in p.stdout + p.stderr:
        bad.append(f"free_port 0 exited {p.returncode}, printing {p.stdout.strip()!r}: "
                   "a count below 1 must be refused")
    return [f"{shell}: {b}" for b in bad]


def selftest() -> int:
    use = shells()
    failures = []
    dash = next((s for s in use if os.path.basename(os.path.realpath(s)) == "dash"), None)

    # Each rule must fail on its defect and pass its control.
    cases = [
        ("a syntax error", "if true; then echo", True),
        ("(control) a complete if", "if true; then echo; fi", False),
        ("a bash substring", 'x=abc; echo "${x: -1}"', True),
        ("(control) POSIX defaults", 'echo "${x:-a}${x:=b}${x:+c}${x%?}${x#?}"', False),
        ("(control) a substring in single quotes", "awk '{ print \"${x: -1}\" }' f", False),
        ("(control) a template literal in a heredoc", "node - <<'JS'\nconsole.log(`${a/b}`)\nJS", False),
        ("a pattern substitution", "echo ${x/a/b}", True),
        ("a [[ test", "[[ -n x ]] && echo y", True),
        ("(control) a bracket class in a quoted grep", "grep -q '[[:alpha:]]' f", False),
        ("a syncing nested uv run", "uv run poe build-serve || exit 1", True),
        ("a syncing nested uv run after ||", "[ -f x ] || uv run poe build-ffi || exit 1", True),
        ("(control) uv run --no-sync", "uv run --no-sync poe build-serve", False),
        ("(control) uv run --no-project", "uv run --no-project --with playwright python3 x.py", False),
        ("(control) uv run in a message", 'echo "rerun it with uv run poe x"', False),
        ("(control) uv run in a comment", "# uv run poe build-serve", False),
        ("(control) uv run in a heredoc", "python3 - <<'PY'\nprint('uv run poe x')\nPY", False),
        ("an assignment before spawn", "M0_WORKERS=2 spawn a.log mojo run x", True),
        ("an assignment before stop, after &&", "true && X=1 stop $pid", True),
        ("(control) env inside spawn", "spawn a.log env M0_WORKERS=2 mojo run x", False),
    ]
    for label, body, want in cases:
        got = bool(lint(body)) or (dash is not None and bool(parse_errors(body, dash)))
        if got != want:
            failures.append(f"rule case {label!r}: flagged={got}, want {want}")
    if dash is None:
        print("check_task_shells: SKIP the dash cases (no dash on PATH)")
    if not shell_tasks('[tool.poe.tasks.x]\nshell = """\n  echo a\n  echo b\n"""\n') == {"x": "echo a\necho b"}:
        failures.append("the reader does not unindent a body the way poe does")

    global _SCRATCH
    _SCRATCH = tempfile.mkdtemp(prefix="check-task-shells.")
    try:
        for sh in use:
            failures += _lib_cases(sh)
    finally:
        shutil.rmtree(_SCRATCH, ignore_errors=True)

    for f in failures:
        print(f"  FAIL  {f}")
    print(f"check_task_shells --selftest: {len(cases)} rule cases, lib under "
          f"{', '.join(use) or 'no shell'}: {'FAILED' if failures else 'ok'}")
    return 1 if failures else 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    use = shells()
    if not use:
        print("check_task_shells: no POSIX shell found")
        return 1
    failures = check((ROOT / "pyproject.toml").read_text(), use)
    for f in failures:
        print(f"  FAIL  {f}")
    n = len(shell_tasks((ROOT / "pyproject.toml").read_text()))
    print(f"check_task_shells: {n} shell tasks under {', '.join(use)}: "
          f"{'FAILED' if failures else 'ok'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
