#!/usr/bin/env python3
"""Break each decoder invariant in turn and insist the fuzzer reports it.

A fuzzer that has never found a bug and a fuzzer that cannot find one look
identical from the outside: both print OK. `scripts/fuzz_request.mojo` swept
480,000 mutations across eight seeds without a single violation, which is a
believable result for a decoder with the unit suite this one has -- and is
worth nothing unless the harness can be shown to fail.

So each entry below reverts one property the fuzzer claims to check, in the
decoder itself, and the run must fail. Same shape as `pool_sabotage.py` and
`trailer_sabotage.py`; no binary is built, so there is no stale-`.mojoc`
hazard -- `mojo run` compiles the package source directly.

    python3 scripts/fuzz_sabotage.py
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HEADER = Path("packages/m0-http/lightbug_http/header.mojo")
CHUNKED = Path("packages/m0-http/lightbug_http/http/chunked.mojo")
FUZZER = Path("scripts/fuzz_request.mojo")

# Fewer iterations than a real run: a broken invariant shows up in the first
# few hundred mutations, and this runs six builds.
ITERATIONS = "4000"

# (label, path, old, new, invariant the fuzzer should name)
SABOTAGES = [
    (
        "bytes_consumed reports the whole buffer, not the header block",
        HEADER,
        # Anchored on the REQUEST constructor: the response parser ends with
        # a byte-identical `cookies=... bytes_consumed=ret,` tail, and the
        # fuzzer never calls it, so the short anchor would sabotage code
        # under no test and report the invariant unguarded.
        "    return ParsedRequestHeaders(\n        method=method^,\n"
        "        path=path^,\n        protocol=protocol^,\n"
        "        headers=headers^,\n        cookies=cookies^,\n"
        "        bytes_consumed=ret,",
        "    return ParsedRequestHeaders(\n        method=method^,\n"
        "        path=path^,\n        protocol=protocol^,\n"
        "        headers=headers^,\n        cookies=cookies^,\n"
        "        bytes_consumed=len(buffer),",
        "a parsed request changed when bytes were appended",
    ),
    (
        "the chunked decoder reports more bytes left than it was given",
        CHUNKED,
        # `ret + 1` is not enough: `ret` is normally well below the buffer
        # length, so the off-by-one stays in range and the bound never fires.
        "        return (ret, new_bufsz)",
        "        return (ret + buffer_len + 1 if ret >= 0 else ret, new_bufsz)",
        "chunked ret is outside [-2, len]",
    ),
    (
        "the chunked decoder reports more decoded output than input",
        CHUNKED,
        "        var new_bufsz = dst",
        "        var new_bufsz = dst + 1",
        "chunked decoded length is outside the buffer",
    ),
    (
        "pending_bytes is computed from the wrong end of the buffer",
        CHUNKED,
        "        self.pending_bytes = buffer_len - src",
        "        self.pending_bytes = buffer_len + src + 1",
        "chunked pending_bytes is outside the buffer",
    ),
]


def run_fuzzer() -> tuple[bool, str]:
    p = subprocess.run(
        ["uv", "run", "mojo", "run", "-I", "packages/m0-http", "-I",
         "packages/m0-core", str(FUZZER), "--iterations", ITERATIONS],
        capture_output=True, text=True, timeout=900,
    )
    out = p.stdout + p.stderr
    return (p.returncode == 0 and "fuzz-request OK" in out), out


def main() -> int:
    originals = {p: p.read_text() for p in (HEADER, CHUNKED)}
    tmp = Path(tempfile.mkdtemp())
    for p, text in originals.items():
        (tmp / p.name).write_text(text)

    print("baseline (unsabotaged) must PASS:")
    ok, out = run_fuzzer()
    print(f"  {'ok' if ok else 'FAIL'}  baseline")
    if not ok:
        print(out[-1500:])
        return 1

    failures = []
    for label, path, old, new, expect in SABOTAGES:
        original = originals[path]
        if old not in original:
            print(f"  FAIL  anchor missing: {label}")
            failures.append(label)
            continue
        path.write_text(original.replace(old, new, 1))
        try:
            ok, out = run_fuzzer()
        except subprocess.TimeoutExpired:
            ok, out = False, "(timed out — itself a failure)"
        path.write_text(original)

        if ok:
            print(f"  BAD   {label} (the fuzzer passed on a broken decoder)")
            failures.append(label)
            continue

        # It failed -- but for the RIGHT reason? A build error also fails, and
        # would make every sabotage here look caught while proving nothing
        # about the invariants.
        named = expect in out
        if not named:
            if "error:" in out:
                print(f"  SKIP  {label} (does not compile, so proves nothing)")
                continue
            print(f"  BAD   {label} (failed, but not on its invariant)")
            failures.append(label)
            continue
        print(f"  ok    {label}")
        print(f"          reported: {expect}")

    for p in originals:
        shutil.copy(tmp / p.name, p)

    print()
    if failures:
        print(f"{len(failures)} invariant(s) the fuzzer does not actually check:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"all {len(SABOTAGES)} decoder invariant(s) are really checked")
    return 0


if __name__ == "__main__":
    sys.exit(main())
