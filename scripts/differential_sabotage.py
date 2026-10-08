#!/usr/bin/env python3
"""Revert each request rule the differential corpus holds, and insist
`smoke-differential` fails for it, naming the case (SPEC B26).

The corpus passes when nothing is wrong, which is the normal result; this
is the half that says it would notice. Each arm puts back one defect the
fork review's D0 run found, or one rule older than it, in the fork's request
parser or its loop, and the smoke must fail with the MISMATCH line of the
case that shows it: not elsewhere, and not by failing to build
(`sabotage_lib.py`, which owns everything around the table). The fork is
resolved from source, so the smoke's own build of `apps/request_echo` takes
each edit and nothing else needs rebuilding.

Pre-release: each arm builds the echo server again, cold, in a compile cache
of the run's own (docs/RELEASING.md). Each rule is also held by a gate of its
own on every pull request (B26 names them); this proves the corpus holds it
too.

    python3 scripts/differential_sabotage.py
    python3 scripts/differential_sabotage.py --only CONNECT
"""

from __future__ import annotations

import sys
from pathlib import Path

from sabotage_lib import POE, Command, rule, run

PARSING = Path("packages/m0-http/lightbug_http/http/parsing.mojo")
HEADER = Path("packages/m0-http/lightbug_http/header.mojo")
REQUEST = Path("packages/m0-http/lightbug_http/loop/request.mojo")

# (label, file, old, new, the case whose MISMATCH line must appear); a rule
# that takes two edits gives a tuple of each.
SABOTAGES = [
    (
        # SPEC B12, the review's P2: the parser ended a head at a bare-LF
        # empty line while the loop framed it by the first CRLFCRLF, so a
        # request pipelined behind it was answered once for two. Two edits:
        # the loop also refuses a head its two framers end at different
        # bytes, so with either rule still in place the case stays a 400
        # (measured, and the loop's comment says so).
        "a bare LF ends the head (B12)",
        (PARSING, REQUEST),
        ("""            buf.increment()
            return
        elif byte.value() == BytesConstant.LF:
            raise ParseError()""",
         """        if parsed.bytes_consumed != header_end_offset:
            _send_error_to_fd(fd_val, BadRequest())"""),
        ("""            buf.increment()
            return
        elif byte.value() == BytesConstant.LF:
            buf.increment()
            return""",
         """        if False:
            _send_error_to_fd(fd_val, BadRequest())"""),
        "lf_blank_then_request",
    ),
    (
        "a bare LF ends a field line (B12)",
        PARSING,
        """        length = buf.read_pos - 1 - token_start
        buf.increment()
    else:
        raise ParseError()""",
        """        length = buf.read_pos - 1 - token_start
        buf.increment()
    elif current_byte == BytesConstant.LF:
        length = buf.read_pos - token_start
        buf.increment()
    else:
        raise ParseError()""",
        "lf_field_line",
    ),
    (
        # SPEC B13: the continuation was a field named "" -- `HTTP_` in a
        # WSGI environ -- and the request was served.
        "an obs-fold line is a field with no name (B13)",
        PARSING,
        """            # continued.
            raise ParseError()""",
        """            # continued.
            headers[num_headers].name_start = 0
            headers[num_headers].name_len = 0""",
        "obs_fold",
    ),
    (
        "Content-Length beside Transfer-Encoding is served (B1)",
        HEADER,
        """    if seen_transfer_encoding and seen_content_length:
        raise RequestParseError(InvalidHTTPRequestError())""",
        """    if False:
        raise RequestParseError(InvalidHTTPRequestError())""",
        "te_and_cl",
    ),
    (
        "a second Host line is served (B10)",
        HEADER,
        """            if kid == KH_HOST:
                if host_len >= 0:
                    raise RequestParseError(InvalidHTTPRequestError())
                # A value that is not""",
        """            if kid == KH_HOST:
                # A value that is not""",
        "two_host",
    ),
    (
        # SPEC B27, review record LF64: `Host: a b` was served, as both
        # references serve it, where RFC 9112 §3.2 asks for 400.
        "a Host value that is no uri-host is served (B27)",
        HEADER,
        """                if len(value) > 0 and not host_value_is_valid(value):
                    raise RequestParseError(InvalidHTTPRequestError())""",
        """                if False:
                    raise RequestParseError(InvalidHTTPRequestError())""",
        "host_with_space",
    ),
    (
        # SPEC B21, review record LF39: `gzip, chunked` was de-chunked and
        # handed to the application still gzipped.
        "a coding before chunked is de-chunked and served (B21)",
        HEADER,
        """        if other_coding:
            raise RequestParseError(UnsupportedHTTPRequestError())""",
        """        if False:
            raise RequestParseError(UnsupportedHTTPRequestError())""",
        "te_gzip_chunked",
    ),
    (
        # SPEC B18, review record LF36: a front end forwarding CONNECT reads
        # the application's 2xx as an open tunnel.
        "CONNECT reaches the application (B18)",
        HEADER,
        """    if method == "CONNECT":
        raise RequestParseError(UnsupportedHTTPRequestError())""",
        """    if False:
        raise RequestParseError(UnsupportedHTTPRequestError())""",
        "connect",
    ),
    (
        # RFC 9110 §10.1.1: HTTP/1.0 has no 1xx, so its client reads a 100
        # as THE response. The outcome keeps interim responses for this.
        "100 Continue goes to an HTTP/1.0 client",
        REQUEST,
        """                if st.provision_pool.provisions[slot].parsed_headers.value().protocol != strHttp10:""",
        """                if True:""",
        "expect_http10",
    ),
]


def why(out: str) -> str:
    """The probe's own failure line, for the report."""
    for line in out.splitlines():
        if line.startswith("differential_probe: FAIL"):
            return line.strip()[:160]
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    return lines[-1][-160:] if lines else "(no output)"


RULES = [rule(label, path, old, new, expect="MISMATCH %s:" % case)
         for label, path, old, new, case in SABOTAGES]

# The smoke builds the echo server from source, so a sabotage that does not
# compile shows as the build's diagnostic: a miss, never a catch.
GATE = Command([POE, "smoke-differential"], passes="smoke-differential OK",
               builds=True, detail=why)


def main(argv: list[str]) -> int:
    return run("sabotage-differential", RULES, GATE, argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
