#!/usr/bin/env python3
"""Break each decoder invariant in turn and insist the fuzzer reports it.

A fuzzer that has never found a bug and a fuzzer that cannot find one look
identical from the outside: both print OK. `scripts/fuzz_request.mojo` swept
480,000 mutations across eight seeds without a single violation, which is a
believable result for a decoder with the unit suite this one has -- and is
worth nothing unless the harness can be shown to fail.

So each entry below reverts one property the fuzzer claims to check, in the
decoder itself, and the run must fail -- on THAT invariant: each entry names
the text the fuzzer must report, and a run that fails without it failed
elsewhere, which is a miss. So is a sabotage that does not compile: a build
error fails the run too, and proves nothing about the invariants. Same shape
as `pool_sabotage.py` and `trailer_sabotage.py`, on `sabotage_lib.py`; no
binary is built, so there is no stale-`.mojoc` hazard -- `mojo run`
compiles the package source directly.

    python3 scripts/fuzz_sabotage.py
    python3 scripts/fuzz_sabotage.py --only pending_bytes
"""

from __future__ import annotations

import sys
from pathlib import Path

from sabotage_lib import MojoRun, Ran, rule, run

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


RULES = [rule(label, path, old, new, expect=expect)
         for label, path, old, new, expect in SABOTAGES]


def fuzz_passed(ran: Ran) -> bool:
    """The fuzzer's pass: exit 0 AND its own OK line."""
    return ran.returncode == 0 and "fuzz-request OK" in ran.output


GATE = MojoRun(FUZZER, args=("--iterations", ITERATIONS), passed=fuzz_passed,
               timeout=900)


def main(argv: list[str]) -> int:
    return run("sabotage-fuzz", RULES, GATE, argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
