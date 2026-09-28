#!/usr/bin/env python3
"""Revert each trailer rule in `chunked.mojo` and insist a test fails for it.

Same idea as `scripts/pool_sabotage.py` and `shim_ownership.py --sabotage`: a
guard nobody has broken on purpose is a guard nobody knows works.

The trailer states were the decoder's genuinely untested region -- the
round-trip tests set `consume_trailer = True` but their wire carried no
trailer section, so every state below `IN_TRAILERS_LINE_HEAD` was reached by
no test at all (SPEC A10). Each entry here is one rule those states implement,
and every one must be caught by `test_parsing.mojo` -- at run time: a
sabotage that does not compile is a miss (`sabotage_lib.py`, which owns
everything around the table).

    python3 scripts/trailer_sabotage.py
    python3 scripts/trailer_sabotage.py --only "abuse ratio"
"""

from __future__ import annotations

import sys
from pathlib import Path

from sabotage_lib import MojoRun, rule, run

CHUNKED = Path("packages/m0-http/lightbug_http/http/chunked.mojo")
TEST = Path("packages/m0-http/test/test_parsing.mojo")

# (label, old, new) — each reverts one load-bearing rule.
SABOTAGES = [
    (
        "consume_trailer ignored: the body ends at the zero chunk",
        """                if self.bytes_left_in_chunk == 0:
                    if self.consume_trailer:
                        self._state = DecoderState.IN_TRAILERS_LINE_HEAD
                        continue
                    else:
                        ret = buffer_len - src
                        break""",
        """                if self.bytes_left_in_chunk == 0:
                    ret = buffer_len - src
                    break""",
    ),
    (
        "consume_trailer forced on: a caller framing its own trailers loses them",
        """                if self.bytes_left_in_chunk == 0:
                    if self.consume_trailer:""",
        """                if self.bytes_left_in_chunk == 0:
                    if True:""",
    ),
    (
        "the trailer's terminating CRLF is left behind",
        """                if buf[src] == BytesConstant.LF:
                    src += 1
                    ret = buffer_len - src
                    break""",
        """                if buf[src] == BytesConstant.LF:
                    ret = buffer_len - src
                    break""",
    ),
    (
        "a trailer line is copied into the body instead of discarded",
        """            elif self._state == DecoderState.IN_TRAILERS_LINE_MIDDLE:
                while src < buffer_len:
                    if buf[src] == BytesConstant.LF:
                        break
                    src += 1""",
        """            elif self._state == DecoderState.IN_TRAILERS_LINE_MIDDLE:
                while src < buffer_len:
                    if buf[src] == BytesConstant.LF:
                        break
                    var _bp = buf.unsafe_ptr()
                    _bp[unsafe_offset = dst] = _bp[unsafe_offset = src]
                    dst += 1
                    src += 1""",
    ),
    (
        "the abuse ratio no longer bounds the trailer section",
        "            if self._total_overhead >= 100 * 1024 and self._total_read - self._total_overhead < self._total_read // 4:\n                ret = -1",
        "            if False:\n                ret = -1",
    ),
    (
        "the abuse ratio fires on every trailer",
        "            if self._total_overhead >= 100 * 1024 and self._total_read - self._total_overhead < self._total_read // 4:\n                ret = -1",
        "            if self._total_overhead > 0:\n                ret = -1",
    ),
]


RULES = [rule(label, CHUNKED, old, new) for label, old, new in SABOTAGES]

GATE = MojoRun(TEST, timeout=600)


def main(argv: list[str]) -> int:
    return run("sabotage-trailers", RULES, GATE, argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
