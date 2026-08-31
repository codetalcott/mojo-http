#!/usr/bin/env python3
"""The probe phase stamp: every probe carries one, and it actually advances.

A probe's phases share their socket helpers -- `recv_exact`, `read_frame`,
`count_responses`, `attempt`. When one of them raises, the traceback names
the CALL that failed and never the PHASE that was being proven. The
2026-08-30 CI failure was an unhandled ConnectionResetError inside
`recv_exact`, and two investigations assumed the wrong phase before a stamp
named it on sight: the app-initiated close handshake, not the flood.

So the ~10-line stamp went into every probe. This is what stops it rotting,
and it checks two different things because two different things can rot:

  STATIC, over a CLOSED SET. Every `*probe*.py` under scripts/ and apps/ --
  plus EXTRA -- is either stamped or listed in EXCUSED with a reason. A new
  probe cannot arrive unstamped by simply not being noticed, and a probe
  that loses its excepthook, its traceback print or its `phase()` calls is
  named. The excuses are here rather than in a handoff note so that "this
  one does not need it, because X" is a result and not a thing to
  re-propose.

  One of the static rules is about ORDER rather than presence: a phase must
  be set before the first socket call in an executing body. It found a real
  one -- `apps/ws_echo/ws_probe.py` connected above its first `phase()`, so
  a refused connection, the failure where you can least guess the phase and
  most want to be told it, reported "startup".

  DYNAMIC, on one representative. Static text cannot tell a stamp that
  advances from one welded to "startup" -- drop `global PHASE` from the
  setter and every report still says startup, with all five structural
  pieces present. So `apps/ws_echo/ws_probe.py` is driven against a
  listener that hangs at two different points, and the two reports must
  name two different phases, neither of them "startup". That is the whole
  claim, and it is asserted without naming either phase, so renaming one is
  not a failure.

`--sabotage` reverts each rule and insists this catches it, INCLUDING the
closed set itself: `sabotage_coverage` drops an unstamped probe into
scripts/ and requires it to be refused, because every other sabotage
speaks about a file the checker already found. A sabotage that two layers
catch proves neither, so the harness reports MISATTRIBUTED rather than
passing -- which is how the list got its current members.

What it cannot do, and no checker of this shape could: notice that a probe
which grew a seventh phase did not grow a seventh `phase()` call. The stamp
is only ever as fine-grained as its call sites.

    python3 scripts/phase_stamp_check.py
    python3 scripts/phase_stamp_check.py --static     # skip the subprocesses
    python3 scripts/phase_stamp_check.py --sabotage   # revert each rule
"""

import ast
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Probes that are excused, and why. Each is a finding, not an oversight.
EXCUSED = {
    "scripts/hybrid_isolation.py":
        "already carries the pattern in a better form: `timed(path, timeout, "
        "what)` takes the phase as an ARGUMENT and prints it in the failure, "
        "so there is no global to go stale and no phase a call site can "
        "forget to set",
    "scripts/pool_spike_probe.py":
        "not an assertion probe -- it spawns servers, measures p50/p99 and "
        "prints a table, returning 0 whatever it finds. There is no failure "
        "for a phase to name; `probe-pool` reads the numbers",
}

# Probe-shaped files whose names do not contain "probe".
EXTRA = ("scripts/chunked_keepalive.py", "scripts/hybrid_isolation.py")

# The representative for the dynamic half, and the two hang points that must
# land it in two different phases.
DYNAMIC_PROBE = "apps/ws_echo/ws_probe.py"


def discover():
    found = []
    for base in ("scripts", "apps"):
        for p in sorted((ROOT / base).rglob("*.py")):
            if "probe" in p.name:
                found.append(str(p.relative_to(ROOT)))
    for extra in EXTRA:
        if (ROOT / extra).exists() and extra not in found:
            found.append(extra)
    return sorted(found)


# Network calls, by attribute name. A phase must be set before the first of
# them runs, or a failure to even CONNECT is reported as "startup".
_NET = frozenset(("create_connection", "urlopen", "connect", "sendall",
                  "recv", "request"))
_NESTED = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)


def _executing_calls(stmts):
    """(line, name) for calls these statements RUN.

    Nested definitions are skipped: a helper is defined here and called
    elsewhere, so its line number says nothing about execution order. That
    distinction is the whole rule -- every probe defines its socket helpers
    above the phases that use them.
    """
    for stmt in stmts:
        if isinstance(stmt, _NESTED):
            continue
        stack = [stmt]
        while stack:
            node = stack.pop()
            if isinstance(node, ast.Call):
                fn = node.func
                name = getattr(fn, "attr", None) or getattr(fn, "id", None)
                if name:
                    yield node.lineno, name
            for child in ast.iter_child_nodes(node):
                if not isinstance(child, _NESTED):
                    stack.append(child)


def _phase_precedes_network(text):
    """No executing body may reach a socket with PHASE still "startup".

    Found one: `apps/ws_echo/ws_probe.py` opened its connection ABOVE its
    first `phase()`, so a refused connection -- the most ordinary failure a
    probe has, and the one where the phase matters least to guess and most
    to be told -- was reported as "startup". An AST parse is still a pure
    function of the text, so --sabotage reverts this like any other rule.
    """
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return False
    bodies = [tree.body]
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == "main":
            bodies.append(node.body)
    for body in bodies:
        calls = sorted(_executing_calls(body))
        first_phase = next((ln for ln, n in calls if n == "phase"), None)
        first_net = next((ln for ln, n in calls if n in _NET), None)
        if first_net is None:
            continue
        if first_phase is None or first_phase > first_net:
            return False
    return True


# Each rule is a pure function of the file's text, which is what lets
# --sabotage revert one in memory and insist this catches it.
RULES = (
    ('PHASE = "startup"',
     lambda t: 'PHASE = "startup"' in t,
     "no `PHASE = \"startup\"` -- there is nothing for a failure to read"),
    ("a phase() setter that assigns the global",
     lambda t: re.search(r"def phase\(name\):\s*\n\s*global PHASE\s*\n\s*PHASE = name", t)
     is not None,
     "`phase()` does not `global PHASE; PHASE = name`, so every report would "
     "name whatever phase was set last -- usually `startup`"),
    ("a handler installed on the way out",
     lambda t: "sys.excepthook = " in t or re.search(r"except OSError as exc:", t)
     is not None,
     "no crash handler -- an unhandled error prints a bare traceback, which "
     "is the state this pattern exists to leave"),
    ("the handler names the phase",
     lambda t: re.search(r"print\([^\n]*PHASE", t) is not None
     or re.search(r'fail\("%s: %r" % \(PHASE', t) is not None,
     "the crash handler does not print PHASE"),
    ("the handler keeps the traceback too",
     lambda t: "traceback.print_exc" in t,
     "the crash handler drops the traceback. Both halves are load-bearing: "
     "the phase says what was being proven, the traceback says where"),
    ("a phase() before the first network call",
     _phase_precedes_network,
     "a socket is opened before any `phase()` runs, so a connection that is "
     "refused or reset outright is reported as `startup` -- the one failure "
     "where the stamp is the only thing that could name the phase"),
    ("at least two phase() call sites",
     lambda t: len(re.findall(r"^\s*phase\(", t, re.M)) >= 2,
     "fewer than two `phase(...)` calls -- a stamp with one phase reports "
     "the same string whatever fails"),
)


def check_static(read=None):
    read = read or (lambda rel: (ROOT / rel).read_text())
    failures = []
    probes = discover()

    for rel in sorted(EXCUSED):
        if rel not in probes:
            failures.append(
                f"{rel} is excused but no longer exists -- delete the excuse "
                "rather than leaving it to excuse a future file of that name"
            )
        elif not EXCUSED[rel] or len(EXCUSED[rel].split()) < 6:
            failures.append(f"{rel}: an excuse must give a reason in words")

    for rel in probes:
        if rel in EXCUSED:
            continue
        text = read(rel)
        for name, ok, why in RULES:
            if not ok(text):
                failures.append(f"{rel}: {why}  [rule: {name}]")
    return failures, probes


HANG_SERVER = r'''
import base64, hashlib, socket, sys, threading, time
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MODE = sys.argv[1]
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0)); srv.listen(8)
print(srv.getsockname()[1], flush=True)
def serve(c):
    if MODE == "handshake":
        req = b""
        while b"\r\n\r\n" not in req:
            d = c.recv(4096)
            if not d:
                return
            req += d
        key = ""
        for line in req.decode("latin-1").split("\r\n"):
            if line.lower().startswith("sec-websocket-key:"):
                key = line.split(":", 1)[1].strip()
        acc = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        c.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                   "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n"
                   % acc).encode())
    while True:                       # hang: the probe's own timeout ends it
        time.sleep(3600)
while True:
    c, _ = srv.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
'''


def _run_against_hang(mode, source_override=None):
    """Return the phase named in the probe's stamped FAIL line, or None.

    The listener accepts and then never speaks again, so the probe dies of
    its own socket timeout -- the SAME exception in the SAME helper in both
    modes. Only the stamp distinguishes them, which is the point.
    """
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        hang = pathlib.Path(tmp) / "hang.py"
        hang.write_text(HANG_SERVER)
        probe = ROOT / DYNAMIC_PROBE
        if source_override is not None:
            probe = pathlib.Path(tmp) / "probe.py"
            probe.write_text(source_override)

        srv = subprocess.Popen(
            [sys.executable, str(hang), mode],
            stdout=subprocess.PIPE, text=True,
        )
        try:
            port = srv.stdout.readline().strip()
            if not port:
                return None
            env = dict(os.environ, M0_PORT=port)
            env.pop("WS_EXPECT_PINGS", None)
            out = subprocess.run(
                [sys.executable, str(probe)],
                env=env, capture_output=True, text=True, timeout=90,
            )
        finally:
            srv.kill()
            srv.wait()

    for line in (out.stdout + out.stderr).splitlines():
        m = re.match(r"ws_probe FAIL: (.*): \w*(Timeout|OS|Connection)", line)
        if m:
            return m.group(1)
    return None


def check_dynamic(source_override=None):
    first = _run_against_hang("silent", source_override)
    second = _run_against_hang("handshake", source_override)
    failures = []
    if first is None or second is None:
        failures.append(
            f"{DYNAMIC_PROBE} did not report a stamped failure against a "
            f"hanging listener (silent={first!r}, handshake={second!r}) -- "
            "the crash handler never ran, or never named a phase"
        )
        return failures, (first, second)
    for label, got in (("silent", first), ("handshake", second)):
        if got == "startup":
            failures.append(
                f"{DYNAMIC_PROBE} reported phase 'startup' against the "
                f"{label} listener -- the stamp is never advanced, so it "
                "names the same thing whatever fails"
            )
    if first == second and not failures:
        failures.append(
            f"{DYNAMIC_PROBE} reported the same phase ({first!r}) for two "
            "failures at different points -- the stamp does not advance"
        )
    return failures, (first, second)


# Each sabotage reverts one rule and must be CAUGHT. A rule nothing catches
# is a rule nobody is keeping.
SABOTAGES = (
    ("the excepthook is unplugged", "static", DYNAMIC_PROBE,
     lambda t: t.replace("sys.excepthook = _stamped", "pass")),
    ("the handler stops printing the phase", "static", DYNAMIC_PROBE,
     lambda t: t.replace('print("ws_probe FAIL: %s: %r" % (PHASE, exc))',
                         'print("ws_probe FAIL: %r" % (exc,))')),
    ("the handler stops printing the traceback", "static", DYNAMIC_PROBE,
     lambda t: t.replace("    traceback.print_exception(kind, exc, tb)\n", "")),
    ("every phase() call site is removed", "static", DYNAMIC_PROBE,
     lambda t: re.sub(r"^phase\(.*\)\n", "", t, flags=re.M)),
    ("PHASE loses its initial value", "static", DYNAMIC_PROBE,
     lambda t: t.replace('PHASE = "startup"', 'PHASE = None', 1)),
    # The two static text cannot see. Every structural piece is present in
    # both, and the stamp is worthless in both. `phase() stops assigning the
    # global` is NOT here: static rule 2 already catches that shape, and a
    # sabotage two rules catch proves nothing about either -- the harness
    # reports MISATTRIBUTED rather than passing, which is how this list got
    # its current members.
    ("every phase names the same string", "dynamic", DYNAMIC_PROBE,
     lambda t: re.sub(r'^phase\("[^"]*"\)', 'phase("startup")', t, flags=re.M)),
    ("the handler is installed after the body that raises", "dynamic",
     DYNAMIC_PROBE,
     lambda t: t.replace("sys.excepthook = _stamped\n", "", 1).rstrip()
     + "\n\nsys.excepthook = _stamped\n"),
    # Restores the real defect: the connect ran above the first phase(), so
    # a refused connection said "startup". DELETING a phase call would not
    # prove this rule -- the next one still precedes the socket -- so the
    # sabotage puts the ORDER back.
    ("the connect runs before the first phase()", "static", DYNAMIC_PROBE,
     lambda t: t.replace(
         'phase("the opening handshake")\n'
         "sock = socket.create_connection((HOST, PORT), timeout=10)",
         "sock = socket.create_connection((HOST, PORT), timeout=10)\n"
         'phase("the opening handshake")')),
)

# The closed set is its own layer, and nothing above tests it: every rule
# so far speaks about a probe the checker already found. A probe that
# arrives unstamped is caught only by `discover()` reaching it, so the
# sabotage is a FILE rather than a mutation.
NEW_PROBE = "scripts/_sabotage_unstamped_probe.py"
NEW_PROBE_SOURCE = (
    '"""A probe that forgot the stamp."""\n'
    "import socket\n"
    'socket.create_connection(("127.0.0.1", 1), timeout=1)\n'
)


def sabotage_coverage():
    """A new, unstamped probe must be REFUSED rather than not noticed."""
    path = ROOT / NEW_PROBE
    path.write_text(NEW_PROBE_SOURCE)
    try:
        failures, _ = check_static()
    finally:
        path.unlink()
    if any(NEW_PROBE in f for f in failures):
        print("  caught          a new probe arrives with no stamp")
        return 0
    print("  NOT CAUGHT      a new probe arrives with no stamp")
    return 1


def sabotage():
    print("phase_stamp_check: reverting each rule in turn")
    original = (ROOT / DYNAMIC_PROBE).read_text()
    bad = 0
    for name, kind, target, mutate in SABOTAGES:
        mutated = mutate(original)
        if mutated == original:
            print(f"  NOT APPLICABLE  {name}")
            bad += 1
            continue
        if kind == "static":
            failures, _ = check_static(
                read=lambda rel, m=mutated: m if rel == target
                else (ROOT / rel).read_text()
            )
        else:
            # The static rules must ALSO pass on this mutation, or the
            # dynamic half is not what caught it.
            static_failures, _ = check_static(
                read=lambda rel, m=mutated: m if rel == target
                else (ROOT / rel).read_text()
            )
            if static_failures:
                print(f"  MISATTRIBUTED   {name} (static caught it: "
                      f"{static_failures[0]})")
                bad += 1
                continue
            failures, _ = check_dynamic(source_override=mutated)
        if failures:
            print(f"  caught          {name}")
        else:
            print(f"  NOT CAUGHT      {name}")
            bad += 1
    bad += sabotage_coverage()
    if bad:
        print(f"phase_stamp_check: {bad} sabotage(s) went unnoticed")
        return 1
    print(f"phase_stamp_check: all {len(SABOTAGES) + 1} sabotages caught")
    return 0


def main():
    if "--sabotage" in sys.argv:
        return sabotage()

    failures, probes = check_static()
    static_only = "--static" in sys.argv
    phases = None
    if not static_only:
        dyn, phases = check_dynamic()
        failures += dyn

    if failures:
        print("phase_stamp_check: FAIL")
        for f in failures:
            print("  -", f)
        return 1

    stamped = len(probes) - len(EXCUSED)
    print(f"phase_stamp_check: {stamped} probes stamped, "
          f"{len(EXCUSED)} excused with a reason")
    if phases:
        print(f"  and the stamp advances: {phases[0]!r} -> {phases[1]!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
