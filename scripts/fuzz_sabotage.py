#!/usr/bin/env python3
"""Break each decoder invariant in turn and insist the fuzzer reports it.

A fuzzer that has never found a bug and a fuzzer that cannot find one look
identical from the outside: both print OK. `scripts/fuzz_request.mojo` swept
480,000 mutations across eight seeds without a single violation, which is a
believable result for a decoder with the unit suite this one has -- and is
worth nothing unless the harness can be shown to fail.

So each entry below reverts one property the fuzzer claims to check, in the
decoder, the parser or the loop's framing decision (SPEC B29, B30), and the
run must fail -- on THAT invariant: each entry names
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
PARSING = Path("packages/m0-http/lightbug_http/http/parsing.mojo")
FRAMING = Path("packages/m0-http/lightbug_http/framing.mojo")
CHUNKED = Path("packages/m0-http/lightbug_http/http/chunked.mojo")
FUZZER = Path("scripts/fuzz_request.mojo")

# Fewer iterations than a real run: a broken invariant shows up in the first
# few hundred mutations, and this runs one build per entry.
ITERATIONS = "4000"

# The request parser's refusal of a bare-LF empty line (SPEC B12), and the
# revert that puts LF2 back: the empty line ends the head at its LF.
STRICT_EMPTY_LINE = (
    "            buf.increment()\n            return\n"
    "        elif byte.value() == BytesConstant.LF:\n"
    "            raise ParseError()"
)
LENIENT_EMPTY_LINE = (
    "            buf.increment()\n            return\n"
    "        elif byte.value() == BytesConstant.LF:\n"
    "            buf.increment()\n            return"
)

# (label, path, old, new, invariant the fuzzer should name)
SABOTAGES = [
    (
        "bytes_consumed reports the whole buffer, not the header block",
        HEADER,
        # Anchored on the REQUEST constructor: the response parser, deleted
        # since, ended with a byte-identical `cookies=... bytes_consumed=ret,`
        # tail the fuzzer never called, so the short anchor sabotaged code
        # under no test and reported the invariant unguarded.
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
    # The invariants that span the parser and the loop (SPEC B29).
    (
        "LF2's revert: the parser ends a head at a bare-LF empty line, the "
        "framer keeps CRLFCRLF",
        PARSING,
        STRICT_EMPTY_LINE,
        LENIENT_EMPTY_LINE,
        "the parser ended a head on something other than CRLF CRLF",
    ),
    (
        # The framing decision's backstop refuses the head the lenient
        # parser ends early, so with the parser alone reverted the decision
        # stays safe and only the parser's own invariant fails (above). This
        # is the defect as it shipped, with no backstop: the request is
        # framed by a head end the parser did not stop at.
        "LF2 as it shipped: that, and the framers' backstop removed",
        (PARSING, FRAMING),
        (STRICT_EMPTY_LINE, "    if parsed.bytes_consumed != head_end:"),
        (LENIENT_EMPTY_LINE, "    if parsed.bytes_consumed < 0:"),
        "a framed request's head end is not where the parser stopped",
    ),
    (
        # The first defect this harness found (LF66): with one to three
        # bytes scanned the search began AT them, and a CRLFCRLF opening the
        # buffer was missed by a split read (two empty lines, then a
        # request). The clamp lives in `find_header_end`.
        "the terminator search starts at what an earlier read scanned",
        HEADER,
        "    var actual_start = max(search_start - 3, 0)",
        "    var actual_start = search_start - 3 if search_start > 3 else search_start",
        "a head split across reads was framed differently from the same bytes whole",
    ),
    # The second defect it found (LF67), a bare CR before the request line
    # skipped with the empty lines, has no arm here: the split invariant
    # saw its revert only through `is_complete`, a rescan of a head already
    # framed, which review record LF61 deleted. With it gone a split read
    # and a whole one take the same path, the revert serves both alike, and
    # the fix is held by `test_parsing.mojo:test_a_bare_cr_before_the_request_line_is_rejected`
    # (SPEC B29).
    (
        "a bare LF is asked of a read's new bytes without the byte before them",
        FRAMING,
        "        if holds_bare_lf(buffer, scanned):",
        "        if holds_bare_lf(buffer[scanned:], 0):",
        "a head split across reads was framed differently from the same bytes whole",
    ),
    # A chunked body as the loop reads it (SPEC B30).
    (
        "the chunked decoder ends a body at a bare-LF empty trailer line",
        CHUNKED,
        "                if buf[src] == BytesConstant.CR:\n"
        "                    src += 1\n"
        "                    self._state = DecoderState.IN_TRAILERS_END_EXPECT_LF\n"
        "                    continue",
        "                if buf[src] == BytesConstant.LF:\n"
        "                    src += 1\n"
        "                    ret = buffer_len - src\n"
        "                    break\n"
        "                if buf[src] == BytesConstant.CR:\n"
        "                    src += 1\n"
        "                    self._state = DecoderState.IN_TRAILERS_END_EXPECT_LF\n"
        "                    continue",
        "a completed chunked body has a framing line that does not end in CRLF",
    ),
    (
        "a read that ends just after a chunk's data is refused, not awaited",
        CHUNKED,
        "            elif self._state == DecoderState.IN_CHUNK_DATA_EXPECT_CR:\n"
        "                if src >= buffer_len:\n"
        "                    break",
        "            elif self._state == DecoderState.IN_CHUNK_DATA_EXPECT_CR:\n"
        "                if src >= buffer_len:\n"
        "                    return (-1, dst)",
        "a chunked body fed in pieces decoded differently from the same bytes whole",
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
