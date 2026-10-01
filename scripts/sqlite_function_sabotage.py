#!/usr/bin/env python3
"""Break each rule of m0-sqlite's scalar functions in turn (SPEC O19-O23),
and insist the test that claims it fails.

`function.mojo` makes a handful of promises a well-meaning simplification
removes without any other test noticing: that a registered function never
becomes part of the database file (DIRECTONLY), that the type's arity is
what SQLite holds, that an index past what a call passed is never read,
that a raise reaches the statement, that a refused registration is never
freed twice, that the global word every callback reads is one word, and
that the callbacks reach one libsqlite3 image. `lib.mojo` promises that
image is one per process however connections come and go. Each entry
below reverts one of them by an EXACT source line and runs the test file
that claims it; the run must fail, in that test's own words where the
failure can print any (a read past `argv` and a double free can take the
process down with its output, and the library counts a crash as a catch
only once the sabotaged source is shown to build).

Two rules are observable only where a second image of libsqlite3 can be
loaded. On Linux a copy of the system library is one. On macOS the system
library lives in the dyld shared cache, so a second image needs Homebrew's
build, and the reopen O23 is about needs a library backed by a file at all:
without Homebrew's SQLite those rules report SKIPPED, never caught.

What has no entry, and why: the `try` around `call` (an `abi("C")`
function cannot raise, so removing it does not compile, which proves
nothing -- the compiler holds it); the compare-and-swap that publishes the
word (no single-threaded test can tell it from a store); and the 3.30.0
floor (every library this runs against is newer).

    python3 scripts/sqlite_function_sabotage.py
    python3 scripts/sqlite_function_sabotage.py --only DIRECTONLY
"""

from __future__ import annotations

import os
import platform
import sys
from pathlib import Path

from sabotage_lib import MojoRun, rule, run

FUNCTION = Path("packages/m0-sqlite/src/function.mojo")
LIB = Path("packages/m0-sqlite/src/lib.mojo")
FUNCTION_TESTS = Path("packages/m0-sqlite/test/test_scalar_function.mojo")
LIB_TESTS = Path("packages/m0-sqlite/test/test_lib.mojo")

BREW = Path("/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib")
ON_MACOS = platform.system() == "Darwin"
# A second image: anywhere but macOS without Homebrew's SQLite.
SECOND_IMAGE = "" if (not ON_MACOS or BREW.exists()) else "Linux, or macOS with Homebrew's SQLite"
# A reopen that maps another image: macOS, with a library backed by a file.
REOPEN = "Darwin" if BREW.exists() else "macOS with Homebrew's SQLite"

RULES = [
    rule(
        "DIRECTONLY: a registered function stays out of the schema (O20)",
        FUNCTION,
        "    var flags = _SQLITE_UTF8 | _SQLITE_DIRECTONLY\n",
        "    var flags = _SQLITE_UTF8\n",
        gate="functions",
        expect="test_the_schema_cannot_call_a_registered_function",
    ),
    rule(
        "arity: the type's count is what SQLite holds (O19)",
        FUNCTION,
        "        db, as_cstr(cname), F.arity, flags, Int(box), _x_scalar[F], _x_destroy[F]\n",
        "        db, as_cstr(cname), -1, flags, Int(box), _x_scalar[F], _x_destroy[F]\n",
        gate="functions",
        expect="test_sqlite_holds_the_arity_and_args_holds_the_index",
    ),
    rule(
        "index: an argument past argc is refused, never read (O19)",
        FUNCTION,
        "        if i < 0 or i >= self._argc:\n",
        "        if i < 0:\n",
        gate="functions",
    ),
    rule(
        "blob: anything but a BLOB is refused, never converted (O19)",
        FUNCTION,
        "        if fns.value_type(v) != SQLITE_BLOB:\n",
        "        if False:\n",
        gate="functions",
        expect="test_sqlite_holds_the_arity_and_args_holds_the_index",
    ),
    rule(
        "deterministic: the flag is registered (O19)",
        FUNCTION,
        "        flags |= _SQLITE_DETERMINISTIC\n",
        "        pass\n",
        gate="functions",
        expect="test_a_deterministic_call_with_constant_arguments_runs_once",
    ),
    rule(
        "raise: what call raises is the statement's error (O19)",
        FUNCTION,
        "        fns.result_error(ctx, str_cstr(message), len(message.as_bytes()))\n",
        "        fns.result_null(ctx)\n",
        gate="functions",
        expect="test_a_raise_is_the_statements_error",
    ),
    rule(
        "ownership: a refused registration is not freed again (O21)",
        FUNCTION,
        "    _ = cname\n    if rc != SQLITE_OK:\n",
        "    _ = cname\n    if rc != SQLITE_OK:\n"
        "        _ = box.unsafe_take_pointee()\n        box.unsafe_free()\n",
        gate="functions",
    ),
    rule(
        "one word: @no_inline keeps the global a single word (O22)",
        FUNCTION,
        "@no_inline\ndef _fn_table_slot()",
        "def _fn_table_slot()",
        gate="functions",
        expect="did not read back",
    ),
    rule(
        "one image: a connection on another image may not register (O22)",
        FUNCTION,
        "    if published.image() != fns.image():\n",
        "    if False:\n",
        gate="functions",
        only_on=SECOND_IMAGE,
        expect="test_a_second_libsqlite3_image_is_refused",
    ),
    rule(
        "one image per process: the pin keeps a handle open (O23)",
        LIB,
        "    var kept = unsafe_alloc[OwnedDLHandle](count=1)\n    kept.unsafe_write(pin^)\n",
        "    _ = pin^\n",
        gate="loader",
        only_on=REOPEN,
        expect="test_one_image_however_connections_come_and_go",
    ),
]

GATES = {
    "functions": MojoRun(FUNCTION_TESTS, includes=("packages/m0-sqlite",)),
    "loader": MojoRun(LIB_TESTS, includes=("packages/m0-sqlite",)),
}


def main(argv: list[str]) -> int:
    # test-sqlite's setting, for the same reason (a signpost in Apple's
    # library); these two files do not fork, so it is belt and braces.
    os.environ.setdefault("OS_ACTIVITY_MODE", "disable")
    return run("sabotage-sqlite-function", RULES, GATES, argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
