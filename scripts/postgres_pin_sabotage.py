#!/usr/bin/env python3
"""Break each rule of m0-postgres's library pin in turn (SPEC O16, O24), and
insist the test that claims it fails.

`lib.mojo`'s third rule is four promises a well-meaning simplification
removes without any other test noticing: that libpq is pinned at all, so a
table copied out of a `PgLib` answers after every handle has gone; that the
pin keeps a handle open, so a reopen finds the image it pinned; that every
image a process opens is pinned, not only the first; and that the word
naming them is one word. Each entry below reverts one of them by an EXACT
source line and runs `test_pin.mojo`; the run must fail, in that test's own
words where the failure can print any (a call through an unpinned table
takes the process down with its output, and the library counts a crash as
a catch only once the sabotaged source is shown to build).

One rule is observable on macOS alone, and reports SKIPPED, never caught,
elsewhere: the REOPEN maps another image only where the loader drops an
image whose last handle closed. glibc keeps a `RTLD_NODELETE` object
findable, so on Linux the kept handle can be removed and nothing changes
(measured on Ubuntu 24.04: the sabotaged tree passes). On macOS every libpq
shows it, none being in the dyld shared cache.

It needs libpq and no server. Without a library the baseline fails, and the
run says nothing is proven.

What has no entry, and why: the compare-and-swap that publishes the word
(no single-threaded test can tell one from a store).

    python3 scripts/postgres_pin_sabotage.py
    python3 scripts/postgres_pin_sabotage.py --only kept
"""

from __future__ import annotations

import sys
from pathlib import Path

from sabotage_lib import MojoRun, rule, run

LIB = Path("packages/m0-postgres/src/lib.mojo")
TESTS = Path("packages/m0-postgres/test/test_pin.mojo")

RULES = [
    rule(
        "pinned: a table outlives every handle of its library (O16)",
        LIB,
        "        pin_library(path, fns.image())\n",
        "",
    ),
    rule(
        "kept: the pin keeps a handle open, so a reopen finds its image (O24)",
        LIB,
        "            var kept = unsafe_alloc[OwnedDLHandle](count=1)\n"
        "            kept.unsafe_write(pin^)\n",
        "            _ = pin^\n",
        only_on="Darwin",
        expect="test_one_image_however_connections_come_and_go",
    ),
    rule(
        "every image: a second library is pinned like the first (O24)",
        LIB,
        "    if not _pinned_from(head, image):\n",
        "    if head == 0:\n",
        expect="test_a_second_library_is_pinned_like_the_first",
    ),
    rule(
        "one word: @no_inline keeps the pinned libraries' global a single word (O24)",
        LIB,
        "@no_inline\ndef _pinned_images_slot()",
        "def _pinned_images_slot()",
        expect="did not read back",
    ),
]


def main(argv: list[str]) -> int:
    return run(
        "sabotage-postgres-pin", RULES,
        MojoRun(TESTS, includes=("packages/m0-postgres",)), argv,
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
