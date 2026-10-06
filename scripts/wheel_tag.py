"""Derive a wheel's platform tag by MEASURING the staged binaries.

The tag is the promise `pip` enforces on the user's behalf, so it has to
describe what was actually built, not what the toolchain claims it could
build. Two ways that goes wrong here, both real:

**macOS.** The Mojo toolchain wheel is tagged `macosx_13_0_arm64`, but a
binary it emits inherits the BUILD HOST's SDK — `bin/m0serve` built on macOS
26 records `LC_BUILD_VERSION minos 26.0`. A wheel tagged 13.0 on that basis
installs cleanly on macOS 15 and then fails in dyld, which is a worse failure
than not installing at all.

**Linux.** `manylinux_2_34` is the toolchain's tag, and the binary m0serve
builds meets it; the runtime libraries the wheel bundles beside it do not.
Measured on the 1.11.0 wheels, `libAsyncRTRuntimeGlobals.so` needs
`GLIBC_2.35` and `libKGENCompilerRTShared.so` needs GCC 12's libstdc++
(docs/notes/the-floor-is-the-runtime.md), so the honest tag is
`manylinux_2_35` and a lower one is Modular's to give, not a container's.
The note printed beside the tag names the file that set it, so that the
floor is read off the build rather than attributed to the host.

**The ABI segment is always `py3-none`**, and that is not an oversight:
m0serve does not link libpython. `std.python` `dlopen`s the interpreter at run
time, so there is no CPython ABI inside the wheel to be compatible with, and
one build per platform serves 3.10 through 3.14 including free-threaded
builds. Confirmed by `otool -L bin/m0serve`, which names only the Mojo runtime
and libSystem.

    python3 scripts/wheel_tag.py packaging/m0serve/src/m0serve
    py3-none-macosx_26_0_arm64
"""

import os
import re
import struct
import sys

from binfmt import InspectError, classify, min_os

# The toolchain's own floor. A binary can require MORE than this (measured
# below); it cannot meaningfully promise less, because the toolchain that
# produced it does not run on older systems.
TOOLCHAIN_GLIBC = (2, 34)

_MACHO_ARCH = {0x0100000C: "arm64", 0x01000007: "x86_64"}
_ELF_ARCH = {0x3E: "x86_64", 0xB7: "aarch64"}


def macho_arch(path):
    with open(path, "rb") as fh:
        hdr = fh.read(8)
    end = "<" if hdr[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe") else ">"
    cputype = struct.unpack_from(end + "I", hdr, 4)[0]
    if cputype not in _MACHO_ARCH:
        raise InspectError(f"{path}: unknown Mach-O cputype {cputype:#x}")
    return _MACHO_ARCH[cputype]


def elf_arch(path):
    with open(path, "rb") as fh:
        hdr = fh.read(20)
    end = "<" if hdr[5] == 1 else ">"
    machine = struct.unpack_from(end + "H", hdr, 18)[0]
    if machine not in _ELF_ARCH:
        raise InspectError(f"{path}: unknown ELF e_machine {machine:#x}")
    return _ELF_ARCH[machine]


def elf_glibc_floor(path):
    """The highest versioned glibc symbol the file requires.

    Scanned over the whole file rather than walking `.gnu.version_r`
    specifically: the version strings live in `.dynstr` and a raw scan cannot
    miss one by mis-parsing a section header. It can only ever over-report by
    finding a string that is not a version reference, which errs toward
    declaring a HIGHER floor -- the safe direction, since a too-high floor
    refuses an install that might have worked, while a too-low one crashes.
    """
    with open(path, "rb") as fh:
        data = fh.read()
    found = [
        (int(m.group(1)), int(m.group(2)))
        for m in re.finditer(rb"GLIBC_(\d+)\.(\d+)", data)
    ]
    return max(found + [TOOLCHAIN_GLIBC])


def tag_for(path):
    """The platform tag one binary requires."""
    fmt = classify(path)
    if fmt == "macho":
        target = min_os(path)
        if not target:
            raise InspectError(f"{path}: no LC_BUILD_VERSION, cannot date the SDK")
        parts = target.split(".")
        major = int(parts[0])
        minor = int(parts[1]) if len(parts) > 1 else 0
        # macOS 11+ wheel tags use the major with a 0 minor; older ones are
        # 10_N. Both are what pip's own platform list contains.
        if major >= 11:
            minor = 0
        return f"macosx_{major}_{minor}_{macho_arch(path)}"
    major, minor = elf_glibc_floor(path)
    return f"manylinux_{major}_{minor}_{elf_arch(path)}"


def _rank(tag):
    """Sort key so the STRICTEST tag across the staged files wins."""
    m = re.match(r"(macosx|manylinux)_(\d+)_(\d+)_(.+)", tag)
    return (int(m.group(2)), int(m.group(3)))


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: wheel_tag.py <staged-package-dir>", file=sys.stderr)
        return 2
    root = sys.argv[1]

    tags = {}
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            path = os.path.join(dirpath, name)
            try:
                classify(path)
            except (InspectError, OSError, IsADirectoryError):
                continue  # not a binary; licences, .py files, metadata
            try:
                tags.setdefault(tag_for(path), []).append(path)
            except InspectError as exc:
                print(f"wheel-tag: {exc}", file=sys.stderr)
                return 2

    if not tags:
        print(
            f"wheel-tag: no Mach-O or ELF files under {root} — a platform "
            "wheel with no binary in it is a packaging bug, not a pure-Python "
            "wheel",
            file=sys.stderr,
        )
        return 2

    # Every file must be satisfiable, so the wheel promises the strictest.
    strictest = max(tags, key=_rank)
    arch = {t.rsplit("_", 1)[-1] for t in tags}
    if len(arch) != 1:
        print(
            f"wheel-tag: staged files disagree about architecture: {tags}",
            file=sys.stderr,
        )
        return 2
    # Always, not only when floors differ: the file that sets the floor is
    # the answer to "why this tag", and it was the runtime library, not the
    # build host, when the question was last asked.
    print(
        f"wheel-tag: floor {strictest} set by "
        f"{os.path.basename(tags[strictest][0])}"
        + (
            "; the others: "
            + ", ".join(
                f"{t} <- {os.path.basename(v[0])}"
                for t, v in tags.items() if t != strictest
            )
            if len(tags) > 1 else ""
        ),
        file=sys.stderr,
    )
    print(f"py3-none-{strictest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
