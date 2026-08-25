"""Mach-O and ELF inspection, shared by the portability checker and the bundler.

Both `ffi_portability_check.py` and `bundle_artifact.py` need the same three
facts about a binary — what it searches, what it depends on, and what it calls
itself. They each had their own copy of the Mach-O parse, and **both copies
were wrong in the same way**, which is the reason this module exists rather
than a tidier pair of scripts.

The bug: `otool -L` prints a header line, then — *for a dylib only* — the
file's own `LC_ID_DYLIB` install name, then its dependencies. Both copies
dropped the first entry unconditionally. Applied to `bin/m0serve`, an
`MH_EXECUTE` with no `LC_ID_DYLIB` at all, that discards
`@rpath/libKGENCompilerRTShared.dylib` — the one dependency that matters — and
leaves `/usr/lib/libSystem.B.dylib`, which is a system library. The checker
then reported SELF-CONTAINED for a binary that resolves the Mojo runtime
through a build-machine `LC_RPATH` and cannot load anywhere else, and the
bundler would have copied zero runtime libraries and called the bundle
complete. Two tools agreeing with each other about an artifact neither could
see: the same shape as the defect that shipped for seven releases, one level
up. See docs/FFI_DISTRIBUTION.md.

The discriminator is **`LC_ID_DYLIB`'s presence**, not the header's filetype.
That is deliberate: an `MH_BUNDLE` may or may not carry one, so keying on the
load command answers the question actually being asked — *is the first
`otool -L` entry this file's own name?* — for every filetype at once.

ELF needs none of this. `DT_SONAME` is its own tag and `DT_NEEDED` entries are
collected separately, so `inspect_elf` was correct for executables all along;
it moved here unchanged so the bundler stops needing its own.

    python3 scripts/binfmt.py --selftest
"""

import re
import struct
import subprocess
import sys

# Prefixes a consumer can rely on existing: OS libraries, and paths the
# loader resolves relative to the artifact itself.
SELF_RELATIVE = ("@loader_path", "@executable_path", "$ORIGIN")
SYSTEM_PREFIXES = (
    "/usr/lib/",
    "/System/Library/",
    "/lib/",
    "/lib64/",
    "/usr/lib64/",
)

# ELF names its dependencies by bare soname (`libc.so.6`), not by path, so
# the SYSTEM_PREFIXES rule above cannot classify them -- it would file every
# one as "not resolvable" and call a perfectly ordinary Linux binary broken.
# These are the sonames any glibc system supplies; anything else has to
# travel with the artifact.
SYSTEM_SONAMES = (
    "libc.", "libm.", "libdl.", "libpthread.", "librt.", "libutil.",
    "libgcc_s.", "libstdc++.", "ld-linux", "libresolv.", "libnsl.",
    "libcrypt.", "libatomic.", "libanl.", "libthread_db.",
)


def is_system_soname(soname):
    """Is this an ELF dependency the platform is expected to provide?"""
    return soname.startswith(SYSTEM_SONAMES)


# Mach-O header magics, as they appear on disk. Fat archives are deliberately
# NOT here -- see `classify`.
_MACHO_LE = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe")
_MACHO_BE = (b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce")
_FAT = (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf")

MH_EXECUTE = 2
MH_DYLIB = 6
MH_BUNDLE = 8


class InspectError(Exception):
    """The file could not be inspected. Never resolve this to 'fine'."""


def _run(cmd):
    try:
        out = subprocess.run(
            cmd, capture_output=True, text=True, check=False, timeout=60
        )
    except FileNotFoundError:
        return None
    if out.returncode != 0:
        return None
    return out.stdout


def classify(path):
    """'macho' | 'elf', or raise InspectError.

    Fat archives raise rather than parse. `otool` reports every slice at once
    and the ELF branch cannot read them at all, so a fat file would be
    inspected as if it were one architecture and the answer silently
    attributed to all of them. Nothing in this repo emits one -- `mojo build`
    produces a thin binary for the host -- so refusing is free, and a guard
    that answers "fine" when it cannot read the file is worse than no guard.
    """
    with open(path, "rb") as fh:
        magic = fh.read(4)
    if magic in _FAT:
        raise InspectError(
            f"{path}: fat Mach-O archive; inspect a single-architecture slice "
            "(lipo -thin) instead"
        )
    if magic in _MACHO_LE or magic in _MACHO_BE:
        return "macho"
    if magic == b"\x7fELF":
        return "elf"
    raise InspectError(f"{path}: neither Mach-O nor ELF")


def macho_filetype(path):
    """The `filetype` field of a thin Mach-O header (MH_EXECUTE, MH_DYLIB...)."""
    with open(path, "rb") as fh:
        hdr = fh.read(16)
    end = "<" if hdr[:4] in _MACHO_LE else ">"
    return struct.unpack_from(end + "I", hdr, 12)[0]


def _macho_load_commands(path):
    load = _run(["otool", "-l", path])
    if load is None:
        raise InspectError(f"{path}: otool unavailable or failed")
    return load


def parse_macho_deps(deps_out, load_out):
    """(rpaths, dependencies, install_name) from raw `otool -L`/`otool -l` text.

    Split out from `macho_info` so `--selftest` can exercise the parse against
    canned output for both an executable and a dylib. That is the whole guard:
    the bug this module exists to fix lived in these four lines and was
    invisible to every test that ran on a dylib.
    """
    rpaths = re.findall(
        r"^\s*path\s+(.+?)\s+\(offset \d+\)\s*$", load_out, re.M
    )
    entries = [
        m.group(1)
        for m in (
            re.match(r"^\s*(\S+)\s+\(compatibility", ln)
            for ln in deps_out.splitlines()[1:]
        )
        if m
    ]
    # The load command, not the filetype: an MH_BUNDLE may carry one too, and
    # the question is only ever "is entries[0] this file's own name?".
    if "LC_ID_DYLIB" in load_out:
        return rpaths, entries[1:], (entries[0] if entries else None)
    return rpaths, entries, None


def macho_info(path):
    """(search_paths, dependencies, install_name) from a Mach-O file.

    `install_name` is None for a file with no `LC_ID_DYLIB` -- an executable,
    or a bundle that does not declare one. Callers must treat that as "this
    file has no install name", never as "the install name is the first
    dependency".
    """
    load = _macho_load_commands(path)
    deps = _run(["otool", "-L", path])
    if deps is None:
        raise InspectError(f"{path}: otool unavailable or failed")
    return parse_macho_deps(deps, load)


def parse_min_os(load_out):
    """The deployment target from `otool -l` text, as a string, or None.

    `LC_BUILD_VERSION` on anything current; `LC_VERSION_MIN_MACOSX` on older
    output. Worth reporting because it is the most literal form of "depends on
    the machine that built it" and the checker was blind to it: a Mojo binary
    inherits the build host's SDK, so one built on macOS 26 records
    `minos 26.0` and refuses to launch on macOS 15 -- regardless of the
    toolchain wheel being tagged `macosx_13_0`.
    """
    m = re.search(r"cmd LC_BUILD_VERSION\b.*?^\s*minos\s+(\S+)", load_out, re.M | re.S)
    if m:
        return m.group(1)
    m = re.search(
        r"cmd LC_VERSION_MIN_MACOSX\b.*?^\s*version\s+(\S+)", load_out, re.M | re.S
    )
    return m.group(1) if m else None


def min_os(path):
    """The Mach-O deployment target of `path`, as a string, or None."""
    return parse_min_os(_macho_load_commands(path))


def inspect_elf(path):
    """(search_paths, dependencies, soname) from a 64-bit ELF file.

    Parsed here rather than shelled out to `readelf`, for two reasons. The
    release workflow should not depend on binutils being installed — and
    more sharply, the shell-out version was **wrong in the dangerous
    direction**: `llvm-objdump` exists on macOS and prints ELF dynamic
    entries in a different format, so the regexes matched nothing, the
    function returned three empty lists, and the check reported a Linux
    artifact as *portable*. A guard that answers "fine" when it cannot read
    the file is worse than no guard.
    """
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:4] != b"\x7fELF" or data[4] != 2:
        raise ValueError(f"{path}: not a 64-bit ELF")

    end = "<" if data[5] == 1 else ">"
    (e_phoff,) = struct.unpack_from(end + "Q", data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from(end + "HH", data, 0x36)

    # PT_DYNAMIC (2) holds the entries; PT_LOAD (1) segments translate the
    # string table's virtual address into a file offset.
    dyn = None
    loads = []
    for i in range(e_phnum):
        base = e_phoff + i * e_phentsize
        (p_type,) = struct.unpack_from(end + "I", data, base)
        p_offset, p_vaddr = struct.unpack_from(end + "QQ", data, base + 8)
        (p_filesz,) = struct.unpack_from(end + "Q", data, base + 32)
        if p_type == 2:
            dyn = (p_offset, p_filesz)
        elif p_type == 1:
            loads.append((p_vaddr, p_filesz, p_offset))
    if dyn is None:
        raise ValueError(f"{path}: no PT_DYNAMIC segment")

    def vaddr_to_off(v):
        for p_vaddr, p_filesz, p_offset in loads:
            if p_vaddr <= v < p_vaddr + p_filesz:
                return p_offset + (v - p_vaddr)
        raise ValueError(f"{path}: address {v:#x} is in no PT_LOAD segment")

    DT_NEEDED, DT_STRTAB, DT_SONAME, DT_RPATH, DT_RUNPATH = 1, 5, 14, 15, 29
    dyn_off, dyn_size = dyn
    entries = []
    strtab_v = None
    for off in range(dyn_off, dyn_off + dyn_size, 16):
        d_tag, d_val = struct.unpack_from(end + "qQ", data, off)
        if d_tag == 0:
            break
        if d_tag == DT_STRTAB:
            strtab_v = d_val
        entries.append((d_tag, d_val))
    if strtab_v is None:
        raise ValueError(f"{path}: dynamic section has no DT_STRTAB")
    strtab = vaddr_to_off(strtab_v)

    def s_at(idx):
        stop = data.index(b"\x00", strtab + idx)
        return data[strtab + idx : stop].decode("utf-8", "replace")

    search, deps, soname = [], [], None
    for d_tag, d_val in entries:
        if d_tag == DT_NEEDED:
            deps.append(s_at(d_val))
        elif d_tag == DT_SONAME:
            soname = s_at(d_val)
        elif d_tag in (DT_RPATH, DT_RUNPATH):
            search.extend(q for q in s_at(d_val).split(":") if q)
    return search, deps, soname


def inspect(path):
    """(search_paths, dependencies, own_name) for either format."""
    if classify(path) == "macho":
        return macho_info(path)
    return inspect_elf(path)


# --------------------------------------------------------------------------
# Self-test. Guards the guard: this parser is only meaningful if it still
# tells an executable from a dylib, and that difference is invisible to any
# test that only ever looks at one of them.
# --------------------------------------------------------------------------

_DYLIB_L = """packages/m0-core/libm0core.dylib:
\t@rpath/libm0core.dylib (compatibility version 0.0.0, current version 0.0.0)
\t@rpath/libKGENCompilerRTShared.dylib (compatibility version 0.0.0, current version 0.0.0)
\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)
"""

_DYLIB_l = """Load command 3
          cmd LC_ID_DYLIB
      cmdsize 48
         name @rpath/libm0core.dylib (offset 24)
Load command 16
          cmd LC_RPATH
      cmdsize 32
         path @loader_path (offset 12)
Load command 17
          cmd LC_BUILD_VERSION
      cmdsize 32
     platform 1
        minos 26.0
          sdk 26.5
"""

_EXE_L = """bin/m0serve:
\t@rpath/libKGENCompilerRTShared.dylib (compatibility version 0.0.0, current version 0.0.0)
\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)
"""

_EXE_l = """Load command 16
          cmd LC_RPATH
      cmdsize 104
         path /Users/runner/work/mojo-http/mojo-http/.venv/lib/python3.13/site-packages/modular/lib (offset 12)
Load command 17
          cmd LC_BUILD_VERSION
      cmdsize 32
     platform 1
        minos 26.0
          sdk 26.5
"""

_OLD_l = """Load command 9
          cmd LC_VERSION_MIN_MACOSX
      cmdsize 16
      version 10.13
          sdk 10.13
"""


def _selftest():
    failures = []

    def check(label, got, want):
        if got != want:
            failures.append(f"{label}\n  got  {got!r}\n  want {want!r}")

    # A dylib: entries[0] IS its own install name, so it must not be reported
    # as a dependency.
    rpaths, deps, name = parse_macho_deps(_DYLIB_L, _DYLIB_l)
    check("dylib install_name", name, "@rpath/libm0core.dylib")
    check(
        "dylib deps",
        deps,
        ["@rpath/libKGENCompilerRTShared.dylib", "/usr/lib/libSystem.B.dylib"],
    )
    check("dylib rpaths", rpaths, ["@loader_path"])

    # An executable: no LC_ID_DYLIB, so entries[0] is a REAL dependency. This
    # is the case both previous copies got wrong, and dropping it is what made
    # a binary that cannot load anywhere report as self-contained.
    rpaths, deps, name = parse_macho_deps(_EXE_L, _EXE_l)
    check("exe install_name", name, None)
    check(
        "exe deps",
        deps,
        ["@rpath/libKGENCompilerRTShared.dylib", "/usr/lib/libSystem.B.dylib"],
    )
    check(
        "exe rpaths",
        rpaths,
        [
            "/Users/runner/work/mojo-http/mojo-http/.venv/lib/python3.13/"
            "site-packages/modular/lib"
        ],
    )
    # The regression this asserts in one line: the runtime dependency survives.
    if "@rpath/libKGENCompilerRTShared.dylib" not in deps:
        failures.append(
            "executable's runtime dependency was dropped -- this is the exact "
            "bug binfmt.py exists to prevent"
        )

    # ELF dependency classification. The Linux m0serve names the three Mojo
    # runtime .so files alongside plain glibc, and confusing the two in
    # either direction is a real failure: call libc ours and the bundle tries
    # to ship it; call the runtime the platform's and the bundle omits what
    # the binary cannot start without.
    for soname in ("libc.so.6", "libm.so.6", "libpthread.so.0", "ld-linux-x86-64.so.2",
                   "libgcc_s.so.1", "libdl.so.2"):
        if not is_system_soname(soname):
            failures.append(f"{soname} should be classified as a platform library")
    for soname in ("libKGENCompilerRTShared.so", "libMSupportGlobals.so",
                   "libAsyncRTRuntimeGlobals.so", "libm0core.so"):
        if is_system_soname(soname):
            failures.append(f"{soname} must NOT be classified as a platform library")

    check("minos LC_BUILD_VERSION", parse_min_os(_EXE_l), "26.0")
    check("minos LC_VERSION_MIN_MACOSX", parse_min_os(_OLD_l), "10.13")
    check("minos absent", parse_min_os("Load command 0\n"), None)

    if failures:
        print("binfmt selftest FAILED:", file=sys.stderr)
        for f in failures:
            print("  " + f, file=sys.stderr)
        return 1
    print("binfmt selftest: ok (dylib/executable discrimination, minos parse)")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    print(__doc__.strip().splitlines()[-1].strip(), file=sys.stderr)
    sys.exit(2)
