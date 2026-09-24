#!/usr/bin/env python3
"""The Datastar SDK's own conformance cases, run against m0-datastar.

SPEC I27 and I28. The SDK specifies itself in `sdk/ADR.md` and tests itself
with fixtures: each `sdk/test/get-cases/<case>/` holds an `input.json` (the
events a server is asked to send) and an `output.txt` (the SSE it must
send), judged by `sdk/test/compare-sse.sh`, which lets `data:` lines of
DIFFERENT keys come in any order and nothing else. All of it is vendored in
`packages/m0-datastar/test/sdk/` -- a subset of upstream's `sdk/`, laid out
as it is there, byte for byte, from the tag MANIFEST names --
with each file's SHA-256 beside it -- a fixture edited here would be a test
rewritten to pass.

A run:

1. insists MANIFEST's tag is `v` + `consts.VERSION` -- a pin bumped over
   stale fixtures is a claim about a version nothing tested -- and that
   every vendored file matches its hash, with no file unlisted;
2. generates ONE Mojo program calling the package's frame builders once per
   case with that case's options, and handing `read_signals` each case's
   input as a GET and as a DELETE with `?datastar=` (the encoding
   `test-get.sh` sends, curl's `--data-urlencode`) and as a POST body (the
   post-case's shape) -- the ADR's ReadSignals table names GET and DELETE
   for the query, and the fixtures exercise only GET;
3. judges every frame with the vendored `compare-sse.sh` itself, and every
   `read_signals` result by byte equality with the input.

A fixture field this script does not map fails the run by name, so a new
option at a new tag cannot be dropped silently.

    python3 scripts/datastar_conformance.py                 # the gate
    python3 scripts/datastar_conformance.py --sabotage      # revert each rule; all must be caught
    python3 scripts/datastar_conformance.py --fetch v1.0.5  # re-vendor from a tag (network)

`--sabotage` copies the package, reverts one rule in the copy by an EXACT
source line, and runs the gate that rule answers to -- this harness, or a
unit test file for the rules the fixtures never reach (SPEC I29) -- which
must fail. An anchor that no longer matches is a failure too: re-point it
with the line.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PKG = REPO / "packages" / "m0-datastar"
SDK = PKG / "test" / "sdk"
MANIFEST = SDK / "MANIFEST"
UPSTREAM = "starfederation/datastar"

# What the vendored tree holds, relative to upstream's `sdk/`.
TOP_FILES = ("ADR.md", "test/compare-sse.sh")
CASE_KINDS = ("get-cases", "post-cases")
CASE_FILES = ("input.json", "output.txt")

# Every field a fixture may carry, per event type. An unknown one fails.
KNOWN = {
    "patchElements": {"type", "elements", "selector", "mode", "namespace",
                      "useViewTransition", "viewTransitionSelector",
                      "eventId", "retryDuration"},
    "patchSignals": {"type", "signals", "signals-raw", "onlyIfMissing",
                     "eventId", "retryDuration"},
    "executeScript": {"type", "script", "autoRemove", "attributes",
                      "eventId", "retryDuration"},
}

MARK = re.compile(r"\n@@(FRAME|GET|DELETE|POST|END)@@([^\n]*)\n")


# --- The vendored tree ------------------------------------------------------


def vendored_files():
    """Every vendored file as a path relative to SDK, MANIFEST excluded."""
    return sorted(
        p.relative_to(SDK).as_posix()
        for p in SDK.rglob("*")
        if p.is_file() and p != MANIFEST
    )


def read_manifest():
    tag, hashes = None, {}
    for line in MANIFEST.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        if line.startswith("tag "):
            tag = line[4:].strip()
            continue
        digest, rel = line.split("  ", 1)
        hashes[rel] = digest
    return tag, hashes


def pinned_version():
    text = (PKG / "src" / "consts.mojo").read_text()
    m = re.search(r'^comptime VERSION = "([^"]+)"', text, re.M)
    if not m:
        raise SystemExit("datastar-sdk: no `comptime VERSION` in consts.mojo")
    return m.group(1)


def vendored_problems():
    """The manifest's tag against the pin, and every file against its hash."""
    if not MANIFEST.exists():
        return [f"{MANIFEST.relative_to(REPO)} is missing; run --fetch"]
    tag, hashes = read_manifest()
    out = []
    want = "v" + pinned_version()
    if tag != want:
        out.append(
            f"the fixtures are from {tag} and consts.VERSION pins {want}: "
            f"re-vendor with --fetch {want}, or put the pin back"
        )
    on_disk = vendored_files()
    for rel in on_disk:
        if rel not in hashes:
            out.append(f"test/sdk/{rel} is not in MANIFEST: vendored files come from --fetch")
    for rel, digest in sorted(hashes.items()):
        path = SDK / rel
        if not path.exists():
            out.append(f"test/sdk/{rel} is in MANIFEST and missing")
        elif hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            out.append(f"test/sdk/{rel} differs from the {tag} file MANIFEST hashed")
    return out


def cases():
    """[(kind, name, dir)] for every vendored case, get-cases first."""
    out = []
    for kind in CASE_KINDS:
        root = SDK / "test" / kind
        if root.exists():
            for d in sorted(root.iterdir()):
                if d.is_dir():
                    out.append((kind, d.name, d))
    return out


# --- The program ------------------------------------------------------------


def lit(s):
    """`s` as a Mojo string literal."""
    for ch in s:
        if ord(ch) < 0x20 and ch not in "\n\r\t":
            raise SystemExit(f"datastar-sdk: control byte {ord(ch):#x} in a fixture")
    out = s.replace("\\", "\\\\").replace('"', '\\"')
    out = out.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    return '"' + out + '"'


def flag(v):
    return "True" if v else "False"


def event_call(case, e):
    """One builder call for one fixture event, as Mojo source."""
    t = e.get("type")
    if t not in KNOWN:
        raise SystemExit(f"datastar-sdk: {case}: event type {t!r} is not mapped")
    unknown = sorted(set(e) - KNOWN[t])
    if unknown:
        raise SystemExit(f"datastar-sdk: {case}: {t} field(s) {unknown} are not mapped")
    common = []
    if "eventId" in e:
        common.append(f"event_id={lit(e['eventId'])}")
    if "retryDuration" in e:
        common.append(f"retry_duration={int(e['retryDuration'])}")
    if t == "patchElements":
        args = [lit(e.get("elements", ""))]
        for key, param in (("selector", "selector"), ("mode", "mode"),
                           ("namespace", "namespace"),
                           ("viewTransitionSelector", "view_transition_selector")):
            if key in e:
                args.append(f"{param}={lit(e[key])}")
        if "useViewTransition" in e:
            args.append(f"use_view_transition={flag(e['useViewTransition'])}")
        return f"patch_elements({', '.join(args + common)})"
    if t == "patchSignals":
        # The SDK's test server serialises `signals` compactly, as Go's
        # json.Marshal does. Go also escapes <, > and & -- no case at
        # v1.0.4 has one; a pin move that adds one fails here, visibly.
        sig = e["signals-raw"] if "signals-raw" in e else json.dumps(
            e["signals"], separators=(",", ":"), ensure_ascii=False)
        args = [lit(sig)]
        if "onlyIfMissing" in e:
            args.append(f"only_if_missing={flag(e['onlyIfMissing'])}")
        return f"patch_signals({', '.join(args + common)})"
    args = [lit(e["script"])]
    if "autoRemove" in e:
        args.append(f"auto_remove={flag(e['autoRemove'])}")
    if "attributes" in e:
        # The test server turns the map into `name="value"` strings, the
        # SDK's `attributes` shape.
        pairs = [k + '="' + v + '"' for k, v in e["attributes"].items()]
        args.append("attributes=[" + ", ".join(f"String({lit(a)})" for a in pairs) + "]")
    return f"execute_script({', '.join(args + common)})"


def request_body(case_dir):
    """What the SDK's runners send: the file as `$(cat ...)` reads it."""
    return (case_dir / "input.json").read_text().rstrip("\n")


def program(all_cases):
    lines = [
        "from lightbug_http.http import HTTPRequest",
        "from lightbug_http.io.bytes import Bytes",
        "from lightbug_http.uri import URI",
        "from src.sse import execute_script, patch_elements, patch_signals",
        "from src.signals import read_signals",
        "",
        "",
        "def _query(method: String, url: String) raises -> HTTPRequest:",
        "    return HTTPRequest(URI.parse(url), method=method)",
        "",
        "",
        "def _post(body: String) raises -> HTTPRequest:",
        "    return HTTPRequest(",
        '        URI.parse("http://localhost/test"), body=Bytes(body.as_bytes()), method="POST"',
        "    )",
        "",
        "",
        "def main() raises:",
    ]
    for kind, name, d in all_cases:
        events = json.loads((d / "input.json").read_text())["events"]
        lines.append(f'    print("\\n@@FRAME@@{name}")')
        for e in events:
            lines.append(f"    print({event_call(name, e)}, end=\"\")")
        body = request_body(d)
        if kind == "post-cases":
            lines.append(f'    print("\\n@@POST@@{name}")')
            lines.append(f"    print(read_signals(_post({lit(body)})), end=\"\")")
        else:
            url = "http://localhost/test?datastar=" + urllib.parse.quote(body, safe="")
            for method in ("GET", "DELETE"):
                lines.append(f'    print("\\n@@{method}@@{name}")')
                lines.append(f'    print(read_signals(_query("{method}", {lit(url)})), end="")')
    lines.append('    print("\\n@@END@@")')
    return "\n".join(lines) + "\n"


def mojo():
    return shutil.which("mojo") or str(REPO / ".venv" / "bin" / "mojo")


def run_gate(pkg_root, quiet=False):
    """Build and run the program against `pkg_root`'s src; True if all pass."""
    all_cases = cases()
    if not all_cases:
        print("datastar-sdk: no vendored cases")
        return False
    work = Path(tempfile.mkdtemp(prefix="datastar-sdk-"))
    try:
        src = work / "conformance.mojo"
        src.write_text(program(all_cases))
        # `src.*` binds to the FIRST -I root that has one when the importing
        # file belongs to no package, so the package under test goes first.
        r = subprocess.run(
            [mojo(), "run", "-I", str(pkg_root), "-I", str(REPO / "packages" / "m0-core"),
             "-I", str(REPO / "packages" / "m0-http"), str(src)],
            capture_output=True, text=True, cwd=REPO,
        )
        if r.returncode != 0:
            if not quiet:
                print("datastar-sdk: the generated program failed to build or run:")
                print(r.stdout[-3000:])
                print(r.stderr[-3000:])
            return False
        parts = MARK.split("\n" + r.stdout)
        sections = {}
        for i in range(1, len(parts) - 1, 3):
            sections[(parts[i], parts[i + 1])] = parts[i + 2]
        failures = []
        for kind, name, d in all_cases:
            actual = work / f"{name}.txt"
            actual.write_text(sections.get(("FRAME", name), ""))
            cmp = subprocess.run(
                ["sh", str(SDK / "test" / "compare-sse.sh"), str(d / "output.txt"), str(actual)],
                capture_output=True, text=True, cwd=work,
            )
            if cmp.returncode != 0:
                failures.append(f"{name}: frames differ -- {cmp.stderr.strip().splitlines()[:1]}")
            methods = ("POST",) if kind == "post-cases" else ("GET", "DELETE")
            want = request_body(d)
            for method in methods:
                got = sections.get((method, name))
                if got != want:
                    failures.append(
                        f"{name}: read_signals on a {method} returned {got!r:.80} "
                        f"where the client sent {want!r:.80}"
                    )
        if not quiet:
            for f in failures:
                print("FAIL  " + f)
            n = len(all_cases)
            print(f"datastar-sdk: {n - len({f.split(':')[0] for f in failures})}/{n} "
                  f"cases pass (frames by compare-sse.sh, read_signals by bytes)")
        return not failures
    finally:
        shutil.rmtree(work, ignore_errors=True)


# --- Sabotage ---------------------------------------------------------------

# (what is reverted, file under src/, exact anchor, replacement, gate)
# A gate is "harness" or a unit test file under test/.
SABOTAGES = [
    ("patch_signals writes one dataline", "sse.mojo",
     "    var parts = split_data_lines(signals)\n"
     "    for i in range(len(parts)):\n"
     "        lines.append(DL_SIGNALS + parts[i])\n",
     "    lines.append(DL_SIGNALS + signals)\n", "harness"),
    ("an empty `elements` still emits a dataline", "sse.mojo",
     "    if elements.byte_length() > 0:\n        var parts = split_data_lines(elements)\n",
     "    if True:\n        var parts = split_data_lines(elements)\n", "harness"),
    ("execute_script drops its attributes", "sse.mojo",
     '        _buf_write(buf, " ")\n        _buf_write(buf, attributes[i])\n',
     "        pass\n", "harness"),
    ("read_signals reads a DELETE's body", "signals.mojo",
     '    if method == "GET" or method == "DELETE":\n',
     '    if method == "GET":\n', "harness"),
    ("a single-line field keeps its line break", "sse.mojo",
     '        if bytes[i] == UInt8(ord("\\r")) or bytes[i] == UInt8(ord("\\n")):\n',
     "        if False:\n", "test_frame_injection.mojo"),
    ("redirect pastes the location raw", "sse.mojo",
     "    _buf_write(buf, _js_string(location))\n",
     '    _buf_write(buf, String("\'", location, "\'"))\n', "test_frame_injection.mojo"),
    ("`<` is not escaped in the literal", "sse.mojo",
     '        elif c == UInt8(ord("<")) or c < UInt8(0x20) or c == UInt8(0x7F):\n',
     "        elif c < UInt8(0x20) or c == UInt8(0x7F):\n", "test_frame_injection.mojo"),
    ("U+2028 is not escaped in the literal", "sse.mojo",
     "            c == UInt8(0xE2)\n",
     "            False\n", "test_frame_injection.mojo"),
]


def sabotage():
    bad = 0
    for what, fname, anchor, replacement, gate in SABOTAGES:
        work = Path(tempfile.mkdtemp(prefix="datastar-sabotage-"))
        try:
            root = work / "m0-datastar"
            shutil.copytree(PKG / "src", root / "src")
            shutil.copytree(PKG / "test", root / "test", ignore=shutil.ignore_patterns("sdk"))
            target = root / "src" / fname
            text = target.read_text()
            if text.count(anchor) != 1:
                print(f"ANCHOR MISSING  {what} ({fname}; found {text.count(anchor)} times)")
                bad += 1
                continue
            target.write_text(text.replace(anchor, replacement))
            if gate == "harness":
                caught = not run_gate(root, quiet=True)
            else:
                r = subprocess.run(
                    [mojo(), "run", "-I", str(root), "-I", str(REPO / "packages" / "m0-core"),
                     "-I", str(REPO / "packages" / "m0-http"), str(root / "test" / gate)],
                    capture_output=True, text=True, cwd=REPO,
                )
                caught = r.returncode != 0
            print(f"{'caught' if caught else 'MISSED'}  {what}  (by {gate})")
            bad += 0 if caught else 1
        finally:
            shutil.rmtree(work, ignore_errors=True)
    print(f"datastar-sdk sabotage: {len(SABOTAGES) - bad}/{len(SABOTAGES)} caught")
    return bad == 0


# --- Re-vendoring -----------------------------------------------------------


def _get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "mojo-http datastar-sdk"})
    token = os.environ.get("GITHUB_TOKEN")
    if token and "api.github.com" in url:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def fetch(tag):
    raw = f"https://raw.githubusercontent.com/{UPSTREAM}/{tag}/sdk/"
    api = f"https://api.github.com/repos/{UPSTREAM}/contents/sdk/test/"
    files = {}
    for rel in TOP_FILES:
        files[rel] = _get(raw + rel)
    for kind in CASE_KINDS:
        listing = json.loads(_get(f"{api}{kind}?ref={tag}"))
        for entry in listing:
            if entry["type"] != "dir":
                continue
            for f in CASE_FILES:
                files[f"test/{kind}/{entry['name']}/{f}"] = _get(
                    f"{raw}test/{kind}/{entry['name']}/{f}")
    for kind in CASE_KINDS:
        shutil.rmtree(SDK / "test" / kind, ignore_errors=True)
    lines = [
        f"# The Datastar SDK's spec and conformance cases, vendored byte for byte",
        f"# from https://github.com/{UPSTREAM}/tree/{tag}/sdk by",
        f"# `python3 scripts/datastar_conformance.py --fetch {tag}`. Never edit a",
        f"# file here: the gate checks each against its hash.",
        f"tag {tag}",
    ]
    for rel in sorted(files):
        path = SDK / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(files[rel])
        lines.append(f"{hashlib.sha256(files[rel]).hexdigest()}  {rel}")
    MANIFEST.write_text("\n".join(lines) + "\n")
    n = sum(1 for r in files if r.endswith("input.json"))
    print(f"vendored {tag}: {n} cases, {len(files)} files into {SDK.relative_to(REPO)}")
    if "v" + pinned_version() != tag:
        print(f"consts.VERSION is {pinned_version()}: move the pin to {tag[1:]} too, "
              f"and read the ADR's diff before trusting a green run")


def main(argv):
    if argv[:1] == ["--fetch"] and len(argv) == 2:
        fetch(argv[1])
        return 0
    if argv == ["--sabotage"]:
        return 0 if sabotage() else 1
    if argv:
        print(__doc__)
        return 2
    problems = vendored_problems()
    for p in problems:
        print("FAIL  " + p)
    ok = run_gate(PKG)
    return 0 if ok and not problems else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
