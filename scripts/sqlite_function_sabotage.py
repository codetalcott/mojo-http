#!/usr/bin/env python3
"""Break each rule of m0-sqlite's scalar functions in turn (SPEC O19-O23),
and insist the test that claims it fails.

`function.mojo` makes a handful of promises a well-meaning simplification
removes without any other test noticing: that the schema never computes
with a registered function (DIRECTONLY), that the type's arity is what
SQLite holds, that an index past what a call passed is never read, that a
span from `blob` is never left dangling by `text`, that an empty blob is
answered as a blob, that a raise reaches the statement, that a refusal is
told in its own words and a refused registration is never freed twice, that
the global word every callback reads is one word, and that the callbacks
reach one libsqlite3 image. `lib.mojo` promises that image is one per
process: however connections come and go, whatever library a later open
names, and without capturing another copy's calls. Each entry below reverts
one of them by an EXACT source line and runs the test file that claims it;
the run must fail, in that test's own words where the failure can print any
(a read past `argv` and a double free can take the process down with its
output, and the library counts a crash as a catch only once the sabotaged
source is shown to build).

Four kinds of rule are observable only on some hosts, and report SKIPPED,
never caught, elsewhere:

  - A SECOND IMAGE of libsqlite3 must be loadable. On Linux a copy of the
    system library is one. On macOS the system library lives in the dyld
    shared cache, so a second image needs Homebrew's build. That a refused
    one is not left pinned is asked of the loader, on Linux alone.
    CI's macOS job installs Homebrew's SQLite for this, and under `CI`
    `test_one_image.mojo` fails without it, so there a missing library is
    a failed baseline here, never a SKIPPED line.
  - The REOPEN O23 was found by maps another image only on macOS, and only
    for a library backed by a file: Homebrew's again.
  - A copy BINDS INTO the first image only where the distribution's build
    resolves its internal calls through the loader's global scope: Ubuntu's
    does, Debian's does not, macOS's two-level namespaces never do. Asked
    of the host by `_global_scope_binds`, since nothing else can say.
  - The floor for a function that is NOT deterministic refuses only on a
    libsqlite3 older than 3.50.0; on a newer one the registration it guards
    is legitimate, and the test's other half runs. Asked of the library the
    tests will open, by `_library_version`.

What has no entry, and why: the `try` around `call` (an `abi("C")`
function cannot raise, so removing it does not compile, which proves
nothing -- the compiler holds it); the bound on `arity` (the same: a type
outside it does not compile); the instance `call` writes being the one
SQLite holds (the same again: a `ScalarFunction` is not `Copyable`, so a
trampoline that took a copy does not compile); the compare-and-swaps that publish the two
words (no single-threaded test can tell one from a store); the 3.31.0
floor (every library this runs against is newer); and the order that asks
a library everything before a branch that closes it (it takes a library
the package refuses for its version, which no host here has).

    python3 scripts/sqlite_function_sabotage.py
    python3 scripts/sqlite_function_sabotage.py --only DIRECTONLY
"""

from __future__ import annotations

import os
import platform
import subprocess
import sys
from pathlib import Path

from sabotage_lib import MojoRun, rule, run

FUNCTION = Path("packages/m0-sqlite/src/function.mojo")
CONN = Path("packages/m0-sqlite/src/conn.mojo")
LIB = Path("packages/m0-sqlite/src/lib.mojo")
FUNCTION_TESTS = Path("packages/m0-sqlite/test/test_scalar_function.mojo")
IMAGE_TESTS = Path("packages/m0-sqlite/test/test_one_image.mojo")

BREW = Path("/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib")
ON_MACOS = platform.system() == "Darwin"

_BINDS_PROBE = r"""
import ctypes, glob, os, shutil, sys, tempfile
paths = sorted(glob.glob("/usr/lib/*-linux-gnu/libsqlite3.so.0")
               + glob.glob("/usr/lib64/libsqlite3.so.0")
               + glob.glob("/usr/local/lib/libsqlite3.so.0"))
if not paths:
    sys.exit(2)
first = ctypes.CDLL(paths[0], mode=2 | 0x100)          # RTLD_NOW | RTLD_GLOBAL
db = ctypes.c_void_p()
if first.sqlite3_open_v2(b":memory:", ctypes.byref(db), 6, None) != 0:
    sys.exit(2)
with tempfile.TemporaryDirectory() as d:
    copy = os.path.join(d, "copy.so")
    shutil.copy(os.path.realpath(paths[0]), copy)
    second = ctypes.CDLL(copy, mode=2)                 # RTLD_NOW | RTLD_LOCAL
    db2 = ctypes.c_void_p()
    rc = second.sqlite3_open_v2(b":memory:", ctypes.byref(db2), 6, None)
sys.exit(0 if rc != 0 else 1)
"""


def _global_scope_binds() -> bool:
    """Whether a copy of this host's libsqlite3, loaded beside a first image
    that sits in the loader's GLOBAL scope, fails to open a database: the
    breakage the two RTLD_LOCAL rules guard against. In a child process, so
    the two images it loads are nobody else's."""
    if ON_MACOS:
        return False
    try:
        done = subprocess.run([sys.executable, "-c", _BINDS_PROBE],
                              capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return done.returncode == 0


def _library_version() -> int:
    """`sqlite3_libversion_number` of the library m0-sqlite will open here:
    `M0_LIBSQLITE3`, else the loader's own by its bare name. 0 if it cannot
    be asked, which skips the rule that needs it."""
    name = os.environ.get("M0_LIBSQLITE3") or (
        "libsqlite3.dylib" if ON_MACOS else "libsqlite3.so.0")
    try:
        import ctypes
        return int(ctypes.CDLL(name).sqlite3_libversion_number())
    except (OSError, AttributeError):
        return 0


# What each host-dependent rule needs, as the SKIPPED line will print it.
# `only_on` is compared with platform.system(), so "" and the host's own
# name both mean "runs here"; any other text means "not here, because".
HERE = platform.system()
SECOND_IMAGE = HERE if (not ON_MACOS or BREW.exists()) else (
    "a host with a second libsqlite3 image (macOS needs Homebrew's SQLite)")
REOPEN = HERE if (ON_MACOS and BREW.exists()) else (
    "macOS with Homebrew's SQLite (a library the loader can drop)")
BINDS = HERE if _global_scope_binds() else (
    "a Linux whose libsqlite3 resolves its own calls through the global"
    " scope (Ubuntu's does, Debian's does not)")

VERSION = _library_version()
MOVING_FLOOR = HERE if 0 < VERSION < 3_050_000 else (
    f"a libsqlite3 older than 3.50.0 (this one answers {VERSION})")

RULES = [
    rule(
        "DIRECTONLY: the schema never computes with a registered function (O20)",
        FUNCTION,
        "    var flags = _SQLITE_UTF8 | _SQLITE_DIRECTONLY\n",
        "    var flags = _SQLITE_UTF8\n",
        gate="functions",
        expect="test_the_schema_cannot_call_a_registered_function",
    ),
    rule(
        "moving: a function that is not deterministic needs 3.50.0 (O20)",
        CONN,
        "            if have < SQLITE_MIN_MOVING_FUNCTION_VERSION:\n",
        "            if False:\n",
        gate="functions",
        only_on=MOVING_FLOOR,
        expect="test_a_function_that_moves_needs_a_library_that_keeps_it_out_of_a_check",
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
        "text: a BLOB is refused, so a span from blob never dangles (O19)",
        FUNCTION,
        "        if fns.value_type(v) == SQLITE_BLOB:\n",
        "        if False:\n",
        gate="functions",
        expect="test_a_blob_span_stays_good_because_text_refuses_a_blob",
    ),
    rule(
        "empty blob: its span never carries SQLite's NULL pointer (O19)",
        FUNCTION,
        "        if n <= 0:\n",
        "        if False:\n",
        gate="functions",
        expect="test_an_empty_blob_is_answered_as_a_blob",
    ),
    rule(
        "empty blob: an answer of no bytes never hands SQLite a NULL pointer (O19)",
        LIB,
        "        if length == 0:\n            var none = UInt8(0)\n            self._result_blob(\n",
        "        if False:\n            var none = UInt8(0)\n            self._result_blob(\n",
        gate="functions",
        expect="test_an_empty_blob_is_answered_as_a_blob",
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
        "        fns.result_error(ctx, str_cstr(message), min(len(message.as_bytes()), MAX_C_INT))\n",
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
        "name: a NUL byte is refused before SQLite sees the name (O21)",
        FUNCTION,
        "        if name_bytes[i] == 0:\n",
        "        if False:\n",
        gate="functions",
        expect="test_a_refusal_before_sqlite_and_a_refusal_in_its_own_words",
    ),
    rule(
        "name: an empty one is refused before SQLite sees it (O21)",
        FUNCTION,
        "    if len(name_bytes) == 0:\n",
        "    if False:\n",
        gate="functions",
        expect="test_a_refusal_before_sqlite_and_a_refusal_in_its_own_words",
    ),
    rule(
        "message: the connection's text only when its code agrees (O21)",
        FUNCTION,
        "        if fns.errcode(db) == rc:\n",
        "        if True:\n",
        gate="functions",
        expect="test_a_refusal_before_sqlite_and_a_refusal_in_its_own_words",
    ),
    rule(
        "one word: @no_inline keeps the functions' global a single word (O22)",
        FUNCTION,
        "@no_inline\ndef _fn_table_slot()",
        "def _fn_table_slot()",
        gate="functions",
        expect="did not read back",
    ),
    rule(
        "one image: a table of another image may not register (O22)",
        FUNCTION,
        "    if published.fns.image() != fns.image():\n",
        "    if False:\n",
        gate="image",
        only_on=SECOND_IMAGE,
        expect="test_a_table_of_another_image_may_not_register",
    ),
    rule(
        "one image per process: a second image is refused at open (O23)",
        LIB,
        "    if pinned.image != image:\n",
        "    if False:\n",
        gate="image",
        only_on=SECOND_IMAGE,
        expect="test_a_second_image_is_refused_at_open",
    ),
    rule(
        "one image per process: a refused library is never pinned (O23)",
        LIB,
        "    if current == 0:\n        var pin: OwnedDLHandle\n",
        "    if True:\n        var pin: OwnedDLHandle\n",
        gate="image",
        # The test asks the loader whether the refused copy is still mapped
        # (RTLD_NOLOAD), which it does on Linux alone: macOS's second image
        # may be Apple's, which the dyld shared cache never unmaps.
        only_on="Linux",
        expect="test_a_second_image_is_refused_at_open",
    ),
    rule(
        "one image per process: the pin keeps a handle open (O23)",
        LIB,
        "            var kept = unsafe_alloc[OwnedDLHandle](count=1)\n"
        "            kept.unsafe_write(pin^)\n",
        "            _ = pin^\n",
        gate="image",
        only_on=REOPEN,
        expect="test_one_image_however_connections_come_and_go",
    ),
    rule(
        "one image per process: @no_inline keeps the pin a single word (O23)",
        LIB,
        "@no_inline\ndef _pinned_image_slot()",
        "def _pinned_image_slot()",
        gate="image",
        expect="did not read back",
    ),
    rule(
        "local scope: a connection's handle does not capture another copy (O23)",
        LIB,
        "    else:\n        return 2\n",
        "    else:\n        return 2 | 256\n",
        gate="image",
        only_on=BINDS,
        expect="test_another_copy_of_sqlite_is_not_bound_into_this_one",
    ),
    rule(
        "local scope: the pin does not promote the image to the global scope (O23)",
        LIB,
        "    else:\n        return 1 | 0x1000\n",
        "    else:\n        return 1 | 256 | 0x1000\n",
        gate="image",
        only_on=BINDS,
        expect="test_another_copy_of_sqlite_is_not_bound_into_this_one",
    ),
]

GATES = {
    "functions": MojoRun(FUNCTION_TESTS, includes=("packages/m0-sqlite",)),
    "image": MojoRun(IMAGE_TESTS, includes=("packages/m0-sqlite",)),
}


def main(argv: list[str]) -> int:
    # test-sqlite's setting, for the same reason (a signpost in Apple's
    # library); neither file forks, so it is belt and braces.
    os.environ.setdefault("OS_ACTIVITY_MODE", "disable")
    return run("sabotage-sqlite-function", RULES, GATES, argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
