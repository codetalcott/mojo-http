#!/usr/bin/env python3
"""Break each rule that keeps CR, LF and NUL out of a head and insist the
header-bytes property fails for it (SPEC G24).

`test_header_bytes.mojo` holds the claim over seeded random bytes; this is
the half that matters when it passes, which is the normal result. Each arm
puts back one defect the property exists to find -- LF1's decoding of
three- and four-byte sequences with and without the second look that turns
its split into a dropped header, G2's refusals in each writer, the
redirect's percent-encoding, the emptied reason phrase -- and the gate must
fail in the property's own test, not elsewhere and not by failing to build
(`sabotage_lib.py`, which owns everything around the table).

    python3 scripts/header_bytes_sabotage.py
    python3 scripts/header_bytes_sabotage.py --only "backstops"
"""

from __future__ import annotations

import sys
from pathlib import Path

from sabotage_lib import MojoRun, rule, run

HEADER = Path("packages/m0-http/lightbug_http/header.mojo")
JAR = Path("packages/m0-http/lightbug_http/cookie/response_cookie_jar.mojo")
RESPONSE = Path("packages/m0-http/lightbug_http/http/response.mojo")
REPLY = Path("packages/m0-http/src/reply.mojo")
TEST = Path("packages/m0-http/test/test_header_bytes.mojo")
PROPERTY = "test_random_bytes_never_put_a_line_break_in_a_head"

# The transcoder as it was before LF1: it decoded every well formed sequence,
# overlong ones included, and kept the bytes of those above U+00FF.
TRANSCODER = """    while i < n:
        var b = utf8[i]
        if (b == 0xC2 or b == 0xC3) and i + 1 < n:
            var b2 = utf8[i + 1]
            if b2 >= 0x80 and b2 <= 0xBF:
                out.append(((b & 0x03) << 6) | (b2 & 0x3F))
                i += 2
                continue
        out.append(b)
        i += 1
    return out^"""
OLD_TRANSCODER = """    while i < n:
        var b = utf8[i]
        var seq_len = 0
        var codepoint = 0
        if b >= 0xC2 and b <= 0xDF and i + 1 < n:
            var b2 = utf8[i + 1]
            if b2 >= 0x80 and b2 <= 0xBF:
                seq_len = 2
                codepoint = ((Int(b) & 0x1F) << 6) | (Int(b2) & 0x3F)
        elif b >= 0xE0 and b <= 0xEF and i + 2 < n:
            var b2 = utf8[i + 1]
            var b3 = utf8[i + 2]
            if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF:
                seq_len = 3
                codepoint = ((Int(b) & 0x0F) << 12) | ((Int(b2) & 0x3F) << 6) | (Int(b3) & 0x3F)
        elif b >= 0xF0 and b <= 0xF7 and i + 3 < n:
            var b2 = utf8[i + 1]
            var b3 = utf8[i + 2]
            var b4 = utf8[i + 3]
            if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF:
                seq_len = 4
                codepoint = ((Int(b) & 0x07) << 18) | ((Int(b2) & 0x3F) << 12) | ((Int(b3) & 0x3F) << 6) | (Int(b4) & 0x3F)
        if seq_len > 0 and codepoint <= 0xFF:
            out.append(UInt8(codepoint))
            i += seq_len
        elif seq_len > 0:
            for j in range(seq_len):
                out.append(utf8[i + j])
            i += seq_len
        else:
            out.append(b)
            i += 1
    return out^"""

HEADER_BACKSTOP = """                if span_breaks_header_line(Span(latin1)):
                    continue
"""
JAR_BACKSTOP = """        if span_breaks_header_line(Span(latin1)):
            return
"""
HEADER_REFUSAL = "            if kind == HEADER_VALUE_BREAKS or span_breaks_header_line(name):\n                continue\n"
JAR_REFUSAL = "    if kind == HEADER_VALUE_BREAKS:\n        return\n"

# (label, path, old, new) -- or tuples of each for an arm of several edits.
SABOTAGES = [
    (
        "LF1 reverted: the transcoder decodes three- and four-byte sequences (the backstops turn the split into a dropped header)",
        HEADER, TRANSCODER, OLD_TRANSCODER,
    ),
    (
        "LF1 reverted with the backstops gone: an overlong CRLF reaches the wire",
        (HEADER, HEADER, JAR),
        (TRANSCODER, HEADER_BACKSTOP, JAR_BACKSTOP),
        (OLD_TRANSCODER, "", ""),
    ),
    (
        "a header NAME holding CR, LF or NUL is written",
        HEADER, HEADER_REFUSAL,
        "            if kind == HEADER_VALUE_BREAKS:\n                continue\n",
    ),
    (
        "a header VALUE holding CR, LF or NUL is written (the backstop gone too)",
        (HEADER, HEADER),
        (HEADER_REFUSAL, HEADER_BACKSTOP),
        ("            if span_breaks_header_line(name):\n                continue\n", ""),
    ),
    (
        "the printed form writes a header holding CR, LF or NUL",
        HEADER,
        "            if span_breaks_header_line(value) or span_breaks_header_line(name):\n                continue\n",
        "",
    ),
    (
        "a Set-Cookie line holding CR, LF or NUL is written (the backstop gone too)",
        (JAR, JAR),
        (JAR_REFUSAL, JAR_BACKSTOP),
        ("", ""),
    ),
    (
        "the printed form writes a Set-Cookie line holding CR, LF or NUL",
        (JAR, JAR),
        (
            "            if not span_breaks_header_line(v.as_bytes()):\n",
            "            if not span_breaks_header_line(line.as_bytes()):\n",
        ),
        ("            if True:\n", "            if True:\n"),
    ),
    (
        "reply.redirect leaves a control byte in the target",
        REPLY,
        "        if ch >= 0x20 and ch != 0x7F:\n            continue\n",
        "        if True:\n            continue\n",
    ),
    (
        "encode writes a reason phrase holding CR, LF or NUL",
        RESPONSE,
        """        \"\"\"
        var writer = ByteWriter()
        writer.write(self.protocol, whitespace, self.status_code, whitespace)
        if not span_breaks_header_line(self.status_text.as_bytes()):""",
        """        \"\"\"
        var writer = ByteWriter()
        writer.write(self.protocol, whitespace, self.status_code, whitespace)
        if True:""",
    ),
    (
        "encode_into writes a reason phrase holding CR, LF or NUL",
        RESPONSE,
        """        # emptied, an injected header or `Set-Cookie` line dropped.
        writer.write(self.protocol, whitespace, self.status_code, whitespace)
        if not span_breaks_header_line(self.status_text.as_bytes()):""",
        """        # emptied, an injected header or `Set-Cookie` line dropped.
        writer.write(self.protocol, whitespace, self.status_code, whitespace)
        if True:""",
    ),
]


RULES = [rule(label, path, old, new, expect=PROPERTY) for label, path, old, new in SABOTAGES]

GATE = MojoRun(TEST, timeout=600)


def main(argv: list[str]) -> int:
    return run("sabotage-header-bytes", RULES, GATE, argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
