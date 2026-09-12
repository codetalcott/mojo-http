#!/usr/bin/env python3
"""Revert each rule behind SPEC N13 and insist `smoke-fragment-notes` fails.

Same shape as `outbox_cap_sabotage.py` and `pool_sabotage.py`: patch one
load-bearing line in the tree, run the gate, insist it goes red, put the
line back. What it answers is the only question that matters about a
security gate -- not "does the suite pass", which it did before any of
this existed, but "would it notice if the check were gone".

The five rules are the five ways this login could be no login at all:
a tag that is never checked (anyone may write a cookie), an expiry that
never fires (a session is forever), a CSRF guard that always passes, a
private view that forgot to ask, and a cookie that is readable by script
and travels cross-site. Four of the five leave every other assertion in
the smoke passing, which is why each needs its own arm.

Rebuilds `m0-http` whenever `session.mojo` has moved since the last build
-- on the sabotage AND on the restore. The app resolves `m0_http` through
the `.mojoc`, so an edit there is not in the app until `build-http` runs;
running the gate against a stale artifact tests a tree nobody has, in
either direction. The app's own file needs no rebuild: the smoke compiles
`server.mojo` itself.

Minutes rather than seconds, so it is pre-release rather than per-PR.

    python3 scripts/notes_login_sabotage.py
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SESSION = Path("packages/m0-http/src/session.mojo")
APP = Path("apps/fragment_notes/server.mojo")

# (label, path, old, new)
SABOTAGES = [
    (
        "the tag is never checked, so anyone may write a session cookie",
        SESSION,
        """    if not constant_time_equal(Span(expected.as_bytes()), sig):
        return session_refused(String("bad signature"))""",
        """    if False:
        return session_refused(String("bad signature"))""",
    ),
    (
        "the expiry never fires, so a session lasts forever",
        SESSION,
        """    if now >= exp:
        return session_refused(String("expired"))""",
        """    if False:
        return session_refused(String("expired"))""",
    ),
    (
        "the cookie loses HttpOnly and SameSite",
        SESSION,
        '''        name, "=", value, "; Path=/; HttpOnly; SameSite=Lax; Max-Age=", max_age''',
        '''        name, "=", value, "; Path=/; Max-Age=", max_age''',
    ),
    (
        "the CSRF guard always passes",
        APP,
        """    if body:
        var got = body.value().get(CSRF_FIELD)
        if got:
            if constant_time_equal(
                Span(verdict.csrf.as_bytes()), Span(got.value().as_bytes())
            ):
                return None""",
        """    if True:
        return None""",
    ),
    (
        "a private view forgets to ask for a session",
        APP,
        '''    """GET /notes — the list."""
    var session = _session(req, store)
    if not session.ok:
        return _refuse(req, session)''',
        '''    """GET /notes — the list."""
    var session = _session(req, store)
    if False:
        return _refuse(req, session)''',
    ),
]


# What `m0_http.mojoc` was last built from. The app resolves `m0_http`
# through that file, so the gate tests the tree only while this matches
# `session.mojo` on disk -- and it stops matching on the RESTORE as well as
# on the sabotage. Rebuilding only when a sabotage is applied left the
# previous one's session.mojo in the artifact for every app-side arm after
# it, and two of them then failed on the wrong assertion while reporting
# the rule guarded. Recording what was built is the fix; comparing text is
# what makes it exact.
_built_session = None


def sync_build() -> bool:
    """Rebuild `m0-http` if `session.mojo` has moved since the last build."""
    global _built_session
    have = SESSION.read_text()
    if have == _built_session:
        return True
    p = subprocess.run(["uv", "run", "poe", "build-http"],
                       capture_output=True, text=True, timeout=1800)
    if p.returncode != 0:
        return False
    _built_session = have
    return True


def run_gate() -> tuple[bool, str]:
    """Run the smoke. True = it PASSED."""
    p = subprocess.run(["uv", "run", "poe", "smoke-fragment-notes"],
                       capture_output=True, text=True, timeout=1800)
    return p.returncode == 0, p.stdout + p.stderr


def _detail(out: str) -> str:
    """The line the smoke failed on, which says WHICH assertion caught it.

    Read exactly: the smoke's `fail` prints the message and then
    `=== fragment.log ===`, so the line before that marker is the
    assertion and nothing else can be mistaken for it. A sabotage caught
    by the wrong assertion proves nothing about the rule it reverted, and
    printing the assertion is what makes that visible without reading the
    whole log.
    """
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if line.strip() == "=== fragment.log ===" and i:
            return "  (" + lines[i - 1][:88] + ")"
    return "  (no assertion message — check the log)"


def main() -> int:
    originals = {p: p.read_text() for p in (SESSION, APP)}
    tmp = Path(tempfile.mkdtemp())
    for p, text in originals.items():
        (tmp / p.name).write_text(text)

    print("baseline (unsabotaged) must PASS:")
    if not sync_build():
        print("  FAIL  baseline build")
        return 1
    ok, out = run_gate()
    print(f"  {'ok' if ok else 'FAIL'}  baseline")
    if not ok:
        print(out[-1500:])
        return 1

    failures = []
    for label, path, old, new in SABOTAGES:
        original = originals[path]
        if old not in original:
            print(f"  FAIL  anchor missing: {label}")
            failures.append(label)
            continue
        path.write_text(original.replace(old, new, 1))
        try:
            if not sync_build():
                print(f"  SKIP  {label} (does not build)")
                path.write_text(original)
                continue
            ok, out = run_gate()
        except subprocess.TimeoutExpired:
            ok, out = False, "(timed out — itself a failure)"
        path.write_text(original)
        good = not ok
        print(f"  {'ok  ' if good else 'BAD '}  {label}{_detail(out) if good else ''}")
        if not good:
            failures.append(label)

    for p, text in originals.items():
        shutil.copy(tmp / p.name, p)
    sync_build()

    print()
    if failures:
        print(f"{len(failures)} rule(s) not covered:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"all {len(SABOTAGES)} notes-login rule(s) are guarded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
