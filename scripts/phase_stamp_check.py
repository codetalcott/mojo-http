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

  DYNAMIC, on one representative of each form. Static text cannot tell a
  stamp that advances from one welded to "startup" -- drop `global PHASE`
  from the setter and every report still says startup, with all five
  structural pieces present. So each representative is driven against a
  listener that hangs at two different points, and the two reports must
  name two different phases, neither of them "startup". That is the whole
  claim, and it is asserted without naming either phase, so renaming one is
  not a failure.

TWO FORMS. A probe carries the stamp inline -- the form the first fifty-odd
were written in -- or takes it from scripts/probelib.py (`from probelib
import phase, stamp`, then `stamp("<label>")` at module level). The library
form puts the handler in ONE file, which is held to the inline form's
structural rules itself; a probe on it must import `phase` and `stamp`,
call `stamp()` at module level, keep no stamp of its own beside it (its own
`phase()` would set a global the library's handler never reads), never
import PHASE by name (a copy that says "startup" for ever), and still set a
phase before its first socket call. A probe that imports anything from the
library takes its stamp from there too: one stamp per probe.

`--sabotage` judges the unsabotaged tree first -- a sabotage judged against
a tree that already fails is "caught" whatever it did -- then reverts each
rule and insists this catches it BY THAT RULE, and that every rule of each
form has a sabotage: a rule nothing catches is a rule nobody is keeping.
That includes the closed set itself: `sabotage_coverage` drops an unstamped
probe into scripts/ and requires it to be refused, because every other
sabotage speaks about a file the checker already found, and
`sabotage_library_order` drops one on the library that connects before its
first phase. A dynamic sabotage that the static rules catch proves nothing
about the dynamic half, so the harness reports MISATTRIBUTED rather than
passing -- which is how the dynamic list got its current members.

What it cannot do, and no checker of this shape could: notice that a probe
which grew a seventh phase did not grow a seventh `phase()` call. The stamp
is only ever as fine-grained as its call sites.

    python3 scripts/phase_stamp_check.py
    python3 scripts/phase_stamp_check.py --static     # skip the subprocesses
    python3 scripts/phase_stamp_check.py --sabotage   # revert each rule
"""

import ast
import concurrent.futures
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

# The library the second form takes its stamp from. Its name contains
# "probe", so the closed set finds it; it is held to the structural rules
# rather than to a probe's.
LIBRARY = "scripts/probelib.py"

# The representatives for the dynamic half, one per form, each with the
# label its stamped line opens with; and the two hang points that must land
# each in two different phases.
DYNAMIC = (
    ("apps/ws_echo/ws_probe.py", "ws_probe FAIL"),
    ("apps/fastapi_demo/ws_probe.py", "fastapi ws_probe FAIL"),
)
DYNAMIC_PROBE = DYNAMIC[0][0]
LIBRARY_PROBE = DYNAMIC[1][0]


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
# them runs, or a failure to even CONNECT is reported as "startup". `server`
# and `wait_healthy` are the library's: each starts talking to a port.
_NET = frozenset(("create_connection", "urlopen", "connect", "sendall",
                  "recv", "request", "server", "wait_healthy"))
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


def uses_library(text):
    """A probe on scripts/probelib.py: it imports from it at all."""
    return re.search(r"^from probelib import", text, re.M) is not None


def _library_names(text):
    """The names a probe imports from probelib at module level, as the
    library spells them (`PHASE as copied` is PHASE)."""
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return set()
    return {alias.name for node in tree.body
            if isinstance(node, ast.ImportFrom) and node.module == "probelib"
            for alias in node.names}


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

# The library holds the handler for every probe on it, so it is held to
# the handler's rules; it has no phases of its own.
LIBRARY_RULES = RULES[:5]

LIBRARY_PROBE_RULES = (
    ("imports phase and stamp from probelib",
     lambda t: {"phase", "stamp"} <= _library_names(t),
     "a probe on scripts/probelib.py does not import both `phase` and "
     "`stamp` from it, so its phases or its handler come from somewhere else"),
    ("never imports PHASE by name",
     lambda t: "PHASE" not in _library_names(t),
     "`from probelib import PHASE` binds a copy that says `startup` for "
     "ever -- read `probelib.PHASE`"),
    ("calls stamp() at module level",
     lambda t: re.search(r"^stamp\(", t, re.M) is not None,
     "no `stamp(...)` at module level, so nothing installs the library's "
     "crash handler before the body runs"),
    ("keeps no stamp of its own",
     lambda t: re.search(r"^\s*def phase\(|^\s*PHASE\s*=|sys\.excepthook\s*=", t, re.M)
     is None,
     "a probe on the library keeps a stamp of its own: its `phase()` sets a "
     "global the library's handler never reads, so every report says "
     "`startup`, or its handler replaces the library's"),
    RULES[5],
    RULES[6],
)

FORMS = {"inline": RULES, "library": LIBRARY_RULES, "on the library": LIBRARY_PROBE_RULES}


def form_of(rel, text):
    if rel == LIBRARY:
        return "library"
    return "on the library" if uses_library(text) else "inline"


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
    if LIBRARY not in probes:
        failures.append(f"{LIBRARY} is not where the closed set looks, so the "
                        "handler every probe on it relies on is checked by nothing")

    for rel in probes:
        if rel in EXCUSED:
            continue
        text = read(rel)
        for name, ok, why in FORMS[form_of(rel, text)]:
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


def _run_against_hang(mode, probe_rel, label, source_override=None):
    """Return the phase named in the probe's stamped FAIL line, or None.

    The listener accepts and then never speaks again, so the probe dies of
    its own socket timeout -- the SAME exception in the SAME helper in both
    modes. Only the stamp distinguishes them, which is the point.
    """
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        hang = pathlib.Path(tmp) / "hang.py"
        hang.write_text(HANG_SERVER)
        probe = ROOT / probe_rel
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
            # A copy run from the temp directory still finds the library.
            path = [str(ROOT / "scripts")] + [p for p in [os.environ.get("PYTHONPATH")] if p]
            env = dict(os.environ, M0_PORT=port, PYTHONPATH=os.pathsep.join(path))
            env.pop("WS_EXPECT_PINGS", None)
            try:
                out = subprocess.run(
                    [sys.executable, str(probe)],
                    env=env, capture_output=True, text=True, timeout=90,
                )
            except subprocess.TimeoutExpired:
                return None
        finally:
            srv.kill()
            srv.wait()

    stamped = re.compile(re.escape(label) + r": (.*): \w*(Timeout|OS|Connection)")
    for line in (out.stdout + out.stderr).splitlines():
        m = stamped.match(line)
        if m:
            return m.group(1)
    return None


def check_dynamic(only=None, source_override=None):
    """Drive each representative (or `only`, from `source_override`) against
    both hang points at once: each run waits out its probe's own socket
    timeout, so they cost one timeout together, not one each."""
    reps = [(rel, label) for rel, label in DYNAMIC if only is None or rel == only]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2 * len(reps)) as pool:
        runs = {(rel, mode): pool.submit(_run_against_hang, mode, rel, label, source_override)
                for rel, label in reps for mode in ("silent", "handshake")}
        got = {key: fut.result() for key, fut in runs.items()}

    failures, phases = [], {}
    for rel, _ in reps:
        first, second = got[(rel, "silent")], got[(rel, "handshake")]
        phases[rel] = (first, second)
        if first is None or second is None:
            failures.append(
                f"{rel} did not report a stamped failure against a "
                f"hanging listener (silent={first!r}, handshake={second!r}) -- "
                "the crash handler never ran, or never named a phase"
            )
            continue
        stuck = False
        for mode, phase in (("silent", first), ("handshake", second)):
            if phase == "startup":
                stuck = True
                failures.append(
                    f"{rel} reported phase 'startup' against the "
                    f"{mode} listener -- the stamp is never advanced, so it "
                    "names the same thing whatever fails"
                )
        if first == second and not stuck:
            failures.append(
                f"{rel} reported the same phase ({first!r}) for two "
                "failures at different points -- the stamp does not advance"
            )
    return failures, phases


# The anchors the library-form sabotages edit. Each must match exactly
# once, or the sabotage is NOT APPLICABLE and the run fails.
LIBRARY_IMPORT = "from probelib import CLOSE, TEXT, WebSocket, fail, phase, stamp"
LIBRARY_STAMP = 'stamp("fastapi ws_probe FAIL")\n'

# Each sabotage reverts one rule and must be CAUGHT -- a static one by the
# rule it names, on the file it edits. (name, kind, target, mutate, rule)
SABOTAGES = (
    # The inline form, on apps/ws_echo/ws_probe.py.
    ("the excepthook is unplugged", "static", DYNAMIC_PROBE,
     lambda t: t.replace("sys.excepthook = _stamped", "pass"),
     "a handler installed on the way out"),
    ("the handler stops printing the phase", "static", DYNAMIC_PROBE,
     lambda t: t.replace('print("ws_probe FAIL: %s: %r" % (PHASE, exc))',
                         'print("ws_probe FAIL: %r" % (exc,))'),
     "the handler names the phase"),
    ("the handler stops printing the traceback", "static", DYNAMIC_PROBE,
     lambda t: t.replace("    traceback.print_exception(kind, exc, tb)\n", ""),
     "the handler keeps the traceback too"),
    ("every phase() call site is removed", "static", DYNAMIC_PROBE,
     lambda t: re.sub(r"^phase\(.*\)\n", "", t, flags=re.M),
     "at least two phase() call sites"),
    ("PHASE loses its initial value", "static", DYNAMIC_PROBE,
     lambda t: t.replace('PHASE = "startup"', 'PHASE = None', 1),
     'PHASE = "startup"'),
    # As a STATIC sabotage, attributed to rule 2. It is not in the dynamic
    # list below for the reason given there.
    ("phase() stops assigning the global", "static", DYNAMIC_PROBE,
     lambda t: t.replace("    global PHASE\n    PHASE = name\n", "    pass\n", 1),
     "a phase() setter that assigns the global"),
    # Restores the real defect: the connect ran above the first phase(), so
    # a refused connection said "startup". DELETING a phase call would not
    # prove this rule -- the next one still precedes the socket -- so the
    # sabotage puts the ORDER back.
    ("the connect runs before the first phase()", "static", DYNAMIC_PROBE,
     lambda t: t.replace(
         'phase("the opening handshake")\n'
         "sock = socket.create_connection((HOST, PORT), timeout=10)",
         "sock = socket.create_connection((HOST, PORT), timeout=10)\n"
         'phase("the opening handshake")'),
     "a phase() before the first network call"),
    # The two static text cannot see. Every structural piece is present in
    # both, and the stamp is worthless in both. `phase() stops assigning the
    # global` is NOT here: static rule 2 already catches that shape, and a
    # sabotage two layers catch proves nothing about either -- the harness
    # reports MISATTRIBUTED rather than passing, which is how this list got
    # its current members.
    ("every phase names the same string", "dynamic", DYNAMIC_PROBE,
     lambda t: re.sub(r'^phase\("[^"]*"\)', 'phase("startup")', t, flags=re.M), None),
    ("the handler is installed after the body that raises", "dynamic",
     DYNAMIC_PROBE,
     lambda t: t.replace("sys.excepthook = _stamped\n", "", 1).rstrip()
     + "\n\nsys.excepthook = _stamped\n", None),

    # The library, scripts/probelib.py: the handler every probe on it uses.
    ("the library's handler is unplugged", "static", LIBRARY,
     lambda t: t.replace("    sys.excepthook = _stamped\n", ""),
     "a handler installed on the way out"),
    ("the library's handler stops printing the phase", "static", LIBRARY,
     lambda t: t.replace('    print("%s: %s: %r" % (_LABEL, PHASE, exc), file=_STREAM or sys.stdout)',
                         '    print("%s: %r" % (_LABEL, exc), file=_STREAM or sys.stdout)'),
     "the handler names the phase"),
    ("the library's handler stops printing the traceback", "static", LIBRARY,
     lambda t: t.replace("    traceback.print_exception(kind, exc, tb)\n", ""),
     "the handler keeps the traceback too"),
    ("the library's PHASE loses its initial value", "static", LIBRARY,
     lambda t: t.replace('PHASE = "startup"', "PHASE = None", 1),
     'PHASE = "startup"'),
    ("the library's phase() stops assigning the global", "static", LIBRARY,
     lambda t: t.replace("    global PHASE\n    PHASE = name\n", "    pass\n", 1),
     "a phase() setter that assigns the global"),

    # A probe on the library, apps/fastapi_demo/ws_probe.py.
    ("a library probe stops importing stamp", "static", LIBRARY_PROBE,
     lambda t: t.replace(LIBRARY_IMPORT, LIBRARY_IMPORT[:-len(", stamp")], 1),
     "imports phase and stamp from probelib"),
    ("a library probe imports PHASE by name", "static", LIBRARY_PROBE,
     lambda t: t.replace(LIBRARY_IMPORT, LIBRARY_IMPORT + ", PHASE", 1),
     "never imports PHASE by name"),
    ("a library probe never calls stamp()", "static", LIBRARY_PROBE,
     lambda t: t.replace(LIBRARY_STAMP, "", 1),
     "calls stamp() at module level"),
    ("a library probe keeps a phase() of its own", "static", LIBRARY_PROBE,
     lambda t: t.replace(LIBRARY_STAMP, LIBRARY_STAMP
                         + "\n\ndef phase(name):\n    global PHASE\n    PHASE = name\n", 1),
     "keeps no stamp of its own"),
    ("a library probe's phase() call sites are removed", "static", LIBRARY_PROBE,
     lambda t: re.sub(r"^\s*phase\(.*\)\n", "", t, flags=re.M),
     "at least two phase() call sites"),
    ("every phase names the same string, on the library", "dynamic", LIBRARY_PROBE,
     lambda t: re.sub(r'^(\s*)phase\("[^"]*"\)', r'\1phase("startup")', t, flags=re.M),
     None),
    ("stamp() runs after the body that raises", "dynamic", LIBRARY_PROBE,
     lambda t: t.replace(LIBRARY_STAMP, "", 1).rstrip() + "\n\n" + LIBRARY_STAMP
     if t.count(LIBRARY_STAMP) == 1 else t, None),
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

# The same for the library form: a new probe complete in every other way
# that connects before its first phase. The order rule, and ONLY it, must
# refuse it -- which proves the closed set reaches a probe on the library
# and that the library form is not excused from the rule.
NEW_LIBRARY_PROBE = "scripts/_sabotage_library_probe.py"
NEW_LIBRARY_PROBE_SOURCE = (
    '"""A probe on the library that connects before its first phase."""\n'
    "import socket\n"
    "from probelib import phase, stamp\n"
    'stamp("_sabotage_library_probe FAIL")\n'
    'socket.create_connection(("127.0.0.1", 1), timeout=1)\n'
    'phase("connected")\n'
    'phase("done")\n'
)
NEW_LIBRARY_PROBE_RULE = "a phase() before the first network call"


def _with_file(rel, source):
    path = ROOT / rel
    path.write_text(source)
    try:
        failures, _ = check_static()
    finally:
        path.unlink()
    return [f for f in failures if f.startswith(rel + ":")]


def sabotage_coverage():
    """A new, unstamped probe must be REFUSED rather than not noticed."""
    if _with_file(NEW_PROBE, NEW_PROBE_SOURCE):
        print("  caught          a new probe arrives with no stamp")
        return 0
    print("  NOT CAUGHT      a new probe arrives with no stamp")
    return 1


def sabotage_library_order():
    """A new probe on the library that connects before its first phase must
    be refused, by the order rule alone."""
    got = _with_file(NEW_LIBRARY_PROBE, NEW_LIBRARY_PROBE_SOURCE)
    name = "a new probe on the library connects before its first phase()"
    if not got:
        print("  NOT CAUGHT      " + name)
        return 1
    if got != [f for f in got if f.endswith("[rule: %s]" % NEW_LIBRARY_PROBE_RULE)]:
        print("  MISATTRIBUTED   %s (caught by another rule: %s)" % (name, got[0]))
        return 1
    print("  caught          " + name)
    return 0


def unsabotaged_rules():
    """(form, rule) pairs no sabotage names: a rule nothing catches is a rule
    nobody is keeping."""
    covered = {("on the library", NEW_LIBRARY_PROBE_RULE)}
    for _name, kind, target, mutate, rule in SABOTAGES:
        if kind == "static":
            covered.add((form_of(target, (ROOT / target).read_text()), rule))
    return [(form, name) for form, rules in FORMS.items() for name, _, _ in rules
            if (form, name) not in covered]


def sabotage():
    print("phase_stamp_check: reverting each rule in turn")
    static_failures, _ = check_static()
    dynamic_failures, _ = check_dynamic()
    if static_failures or dynamic_failures:
        print("phase_stamp_check: the unsabotaged tree already fails, so no "
              "sabotage can be judged against it:")
        for f in static_failures + dynamic_failures:
            print("  -", f)
        return 1

    originals, results, dynamic = {}, {}, []
    for i, (name, kind, target, mutate, rule) in enumerate(SABOTAGES):
        if target not in originals:
            originals[target] = (ROOT / target).read_text()
        original = originals[target]
        mutated = mutate(original)
        if mutated == original:
            results[i] = ("NOT APPLICABLE", "")
            continue
        failures, _ = check_static(
            read=lambda rel, m=mutated, tg=target: m if rel == tg
            else (ROOT / rel).read_text()
        )
        if kind == "static":
            if any(f.startswith(target + ":") and f.endswith("[rule: %s]" % rule)
                   for f in failures):
                results[i] = ("caught", "")
            elif failures:
                results[i] = ("MISATTRIBUTED", "(not by [rule: %s]: %s)" % (rule, failures[0]))
            else:
                results[i] = ("NOT CAUGHT", "")
        elif failures:
            # The static rules must ALSO pass on this mutation, or the
            # dynamic half is not what caught it.
            results[i] = ("MISATTRIBUTED", "(static caught it: %s)" % failures[0])
        else:
            dynamic.append((i, target, mutated))

    # Each dynamic run waits out its probe's socket timeout: all at once.
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(dynamic))) as pool:
        runs = {i: pool.submit(check_dynamic, target, mutated) for i, target, mutated in dynamic}
        for i, fut in runs.items():
            failures, _ = fut.result()
            results[i] = ("caught", "") if failures else ("NOT CAUGHT", "")

    bad = 0
    for i, (name, *_rest) in enumerate(SABOTAGES):
        verdict, detail = results[i]
        print(f"  {verdict:<15} {name}" + (f" {detail}" if detail else ""))
        bad += verdict != "caught"
    bad += sabotage_coverage()
    bad += sabotage_library_order()
    for form, name in unsabotaged_rules():
        print(f"  NO SABOTAGE     [{form}] {name}")
        bad += 1
    if bad:
        print(f"phase_stamp_check: {bad} sabotage(s) went unnoticed")
        return 1
    print(f"phase_stamp_check: all {len(SABOTAGES) + 2} sabotages caught, "
          "every rule of both forms among them")
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

    stamped = [p for p in probes if p not in EXCUSED and p != LIBRARY]
    on_library = [p for p in stamped if uses_library((ROOT / p).read_text())]
    print(f"phase_stamp_check: {len(stamped)} probes stamped ({len(on_library)} "
          f"through {LIBRARY}), {len(EXCUSED)} excused with a reason")
    for rel, (first, second) in (phases or {}).items():
        print(f"  and the stamp advances in {rel}: {first!r} -> {second!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
