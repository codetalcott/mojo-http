#!/usr/bin/env python3
"""Issue a fragment-notes session cookie, exactly as its verifier reads one.

The format is `v1.<kid>.<exp>.<subject>.<tag>`: `kid` is the first eight hex
characters of the key's SHA-256, `tag` is base64url (no padding) of
HMAC-SHA256 over everything before it, and the CSRF token a session stands
for is base64url of HMAC-SHA256 over `m0csrf1.` followed by that tag.

This is the OTHER side of `m0_http.session`, and it exists so that side is
never checked against itself. `poe smoke-fragment-notes` forges with it --
an expired cookie, one signed under a key the server does not hold, one
naming a subject the server never issued -- and `test_session.mojo`'s
vectors are what `--vectors` prints, so a change to either implementation
that the other does not match shows up as a failing test rather than as a
session nobody can use.

    python3 scripts/notes_session.py --key K --subject notes --exp 1800000600
    python3 scripts/notes_session.py --key K --csrf-for COOKIE
    python3 scripts/notes_session.py --vectors
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import sys

VERSION = "v1"
CSRF_PREFIX = b"m0csrf1."


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def key_id(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()[:8]


def issue(key: str, subject: str, exp: int) -> str:
    signed = "%s.%s.%d.%s" % (VERSION, key_id(key), exp, subject)
    tag = b64url(hmac.new(key.encode(), signed.encode(), hashlib.sha256).digest())
    return signed + "." + tag


def csrf_for(key: str, cookie: str) -> str:
    tag = cookie.rsplit(".", 1)[1].encode()
    return b64url(hmac.new(key.encode(), CSRF_PREFIX + tag, hashlib.sha256).digest())


# The unit vectors: one key, one clock, one subject, and every arm the
# verifier refuses on. `test_session.mojo` carries these as constants and
# `--vectors` reprints them, so regenerating is a diff rather than a
# transcription.
V_KEY = "notes-key-0123456789abcdef0123456789abcdef"
V_PREV = "notes-prev-fedcba9876543210fedcba9876543210"
V_NOW = 1800000000


def vectors() -> str:
    ok = issue(V_KEY, "notes", V_NOW + 600)
    lines = [
        'comptime KEY = "%s"' % V_KEY,
        'comptime PREV = "%s"' % V_PREV,
        "comptime NOW = %d" % V_NOW,
        'comptime KID = "%s"' % key_id(V_KEY),
        'comptime OK = "%s"' % ok,
        'comptime CSRF = "%s"' % csrf_for(V_KEY, ok),
        'comptime EXPIRED = "%s"' % issue(V_KEY, "notes", V_NOW - 1),
        'comptime PREV_SIGNED = "%s"' % issue(V_PREV, "notes", V_NOW + 600),
        'comptime OTHER_SUBJECT = "%s"' % issue(V_KEY, "someone_else", V_NOW + 600),
        'comptime TAMPERED = "%s"' % (ok[:-1] + ("A" if ok[-1] != "A" else "B")),
    ]
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--key")
    ap.add_argument("--subject", default="notes")
    ap.add_argument("--exp", type=int)
    ap.add_argument("--csrf-for")
    ap.add_argument("--vectors", action="store_true")
    args = ap.parse_args(argv)
    if args.vectors:
        print(vectors())
        return 0
    if not args.key:
        ap.error("--key is required")
    if args.csrf_for:
        print(csrf_for(args.key, args.csrf_for))
        return 0
    if args.exp is None:
        ap.error("--exp is required")
    print(issue(args.key, args.subject, args.exp))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
