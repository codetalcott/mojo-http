#!/usr/bin/env python3
"""Revert each trailer rule in `chunked.mojo` and insist a test fails for it.

Same idea as `scripts/pool_sabotage.py` and `shim_ownership.py --sabotage`: a
guard nobody has broken on purpose is a guard nobody knows works.

The trailer states were the decoder's genuinely untested region -- the
round-trip tests set `consume_trailer = True` but their wire carried no
trailer section, so every state below `IN_TRAILERS_LINE_HEAD` was reached by
no test at all (SPEC A10). Each entry here is one rule those states implement
-- consuming the section whole, and since SPEC B14 holding every line of it
to a field line ending in CRLF -- and every one must be caught by
`test_parsing.mojo` -- at run time: a sabotage that does not compile is a
miss (`sabotage_lib.py`, which owns everything around the table).

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
        """                src += 1
                ret = buffer_len - src
                break""",
        """                ret = buffer_len - src
                break""",
    ),
    (
        "a trailer line is copied into the body instead of discarded",
        """                    if buf[src] == BytesConstant.LF:
                        return (-1, dst)
                    src += 1

                if src >= buffer_len:
                    break

                src += 1
                self._state = DecoderState.IN_TRAILERS_LINE_EXPECT_LF""",
        """                    if buf[src] == BytesConstant.LF:
                        return (-1, dst)
                    var _bp = buf.unsafe_ptr()
                    _bp[unsafe_offset = dst] = _bp[unsafe_offset = src]
                    dst += 1
                    src += 1

                if src >= buffer_len:
                    break

                src += 1
                self._state = DecoderState.IN_TRAILERS_LINE_EXPECT_LF""",
    ),
    # SPEC B24: a trailer value holds field content, as a head's does.
    (
        "a control byte in a trailer value is taken as content",
        """                    if (
                        buf[src] < 0x20
                        and buf[src] != BytesConstant.TAB
                        and buf[src] != BytesConstant.LF
                    ) or buf[src] == 0x7F:
                        return (-1, dst)
""",
        "",
    ),
    # The CRLF and field-line rules (SPEC B14). Each puts back one thing
    # the trailer states used to accept.
    (
        "a bare LF ends the trailer section",
        """                if buf[src] == BytesConstant.CR:
                    src += 1
                    self._state = DecoderState.IN_TRAILERS_END_EXPECT_LF
                    continue""",
        """                if buf[src] == BytesConstant.LF:
                    src += 1
                    ret = buffer_len - src
                    break
                if buf[src] == BytesConstant.CR:
                    src += 1
                    self._state = DecoderState.IN_TRAILERS_END_EXPECT_LF
                    continue""",
    ),
    (
        "a bare LF ends a trailer field line",
        """                    if buf[src] == BytesConstant.LF:
                        return (-1, dst)
                    src += 1""",
        """                    if buf[src] == BytesConstant.LF:
                        src -= 1
                        break
                    src += 1""",
    ),
    (
        "a run of CR before the section's last LF is skipped",
        """                if buf[src] != BytesConstant.LF:
                    return (-1, dst)

                src += 1
                ret = buffer_len - src""",
        """                if buf[src] == BytesConstant.CR:
                    src += 1
                    continue
                if buf[src] != BytesConstant.LF:
                    return (-1, dst)

                src += 1
                ret = buffer_len - src""",
    ),
    (
        "a run of CR before a field line's LF is skipped",
        """                if buf[src] != BytesConstant.LF:
                    return (-1, dst)

                src += 1
                self._state = DecoderState.IN_TRAILERS_LINE_HEAD""",
        """                if buf[src] == BytesConstant.CR:
                    src += 1
                    continue
                if buf[src] != BytesConstant.LF:
                    return (-1, dst)

                src += 1
                self._state = DecoderState.IN_TRAILERS_LINE_HEAD""",
    ),
    (
        "a trailer line need not open with a name",
        """                if not is_token_char(buf[src]):
                    return (-1, dst)
                src += 1
                self._state = DecoderState.IN_TRAILERS_LINE_NAME""",
        """                self._state = DecoderState.IN_TRAILERS_LINE_MIDDLE""",
    ),
    (
        "a trailer line need not have a colon",
        """                    if not is_token_char(buf[src]):
                        return (-1, dst)
                    src += 1""",
        """                    if not is_token_char(buf[src]):
                        src -= 1
                        break
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
