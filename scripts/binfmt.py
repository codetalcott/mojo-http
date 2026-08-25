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

Both formats are parsed directly rather than shelled out to `otool` /
`readelf`, and for the same reason in both cases: a tool that exists on only
one platform cannot inspect the other's artifacts. `otool` is macOS-only, so
the release workflow's inspect job -- one Linux runner checking BOTH wheels
-- died with "otool unavailable or failed" on the macOS one. Native parsing
means any machine can inspect any artifact, which is what `inspect_elf`
already gave in the other direction.

    python3 scripts/binfmt.py --selftest
"""

import re
import struct
import subprocess
import sys
from shutil import which as _which

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


# Load commands. LC_REQ_DYLD (0x80000000) is set on commands the loader must
# understand, which is why LC_RPATH and the weak/reexport dylib variants have
# the high bit.
LC_ID_DYLIB = 0x0D
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_RPATH = 0x8000001C
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24

_DYLIB_LOADS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB)


def _macho_header(data):
    """(endian prefix, filetype, ncmds, offset of first load command)."""
    magic = data[:4]
    if magic in _FAT:
        raise InspectError("fat Mach-O archive; inspect a single-architecture slice")
    if magic not in _MACHO_LE and magic not in _MACHO_BE:
        raise InspectError("not a Mach-O file")
    end = "<" if magic in _MACHO_LE else ">"
    is64 = magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf")
    filetype, ncmds = struct.unpack_from(end + "II", data, 12)
    return end, filetype, ncmds, (32 if is64 else 28)


def _lc_str(data, cmd_off, cmdsize, str_off):
    """A load command's inline string: an offset from the command's own start."""
    if not (0 < str_off < cmdsize):
        raise InspectError(f"load command string offset {str_off} outside the command")
    start = cmd_off + str_off
    stop = data.index(b"\x00", start, cmd_off + cmdsize)
    return data[start:stop].decode("utf-8", "replace")


def parse_macho(data):
    """(rpaths, dependencies, install_name, min_os) from Mach-O bytes.

    Parsed here rather than shelled out to `otool`, for exactly the reason
    `inspect_elf` gives for the same choice: shelling out was wrong in the
    dangerous direction. `otool` exists only on macOS, so the release
    workflow's inspect job -- which runs on Linux and checks BOTH wheels --
    could not read the macOS one at all and died with "otool unavailable or
    failed". Parsing the load commands directly means any platform can
    inspect any artifact, which is the property that made `inspect_elf`
    readable from a macOS checkout.
    """
    end, _filetype, ncmds, off = _macho_header(data)
    rpaths, deps, install_name, min_os_str = [], [], None, None

    for _ in range(ncmds):
        if off + 8 > len(data):
            raise InspectError("load commands run past end of file")
        cmd, cmdsize = struct.unpack_from(end + "II", data, off)
        if cmdsize < 8 or off + cmdsize > len(data):
            raise InspectError(f"load command {cmd:#x} has implausible size {cmdsize}")

        if cmd == LC_RPATH:
            (str_off,) = struct.unpack_from(end + "I", data, off + 8)
            rpaths.append(_lc_str(data, off, cmdsize, str_off))
        elif cmd == LC_ID_DYLIB:
            (str_off,) = struct.unpack_from(end + "I", data, off + 8)
            install_name = _lc_str(data, off, cmdsize, str_off)
        elif cmd in _DYLIB_LOADS:
            (str_off,) = struct.unpack_from(end + "I", data, off + 8)
            deps.append(_lc_str(data, off, cmdsize, str_off))
        elif cmd == LC_BUILD_VERSION:
            (minos,) = struct.unpack_from(end + "I", data, off + 12)
            min_os_str = _decode_version(minos)
        elif cmd == LC_VERSION_MIN_MACOSX and min_os_str is None:
            (version,) = struct.unpack_from(end + "I", data, off + 8)
            min_os_str = _decode_version(version)
        off += cmdsize

    return rpaths, deps, install_name, min_os_str


def _decode_version(packed):
    """Mach-O packs X.Y.Z into 16.8.8 bits. Trailing zero patch is dropped."""
    major, minor, patch = packed >> 16, (packed >> 8) & 0xFF, packed & 0xFF
    return f"{major}.{minor}.{patch}" if patch else f"{major}.{minor}"


def macho_info(path):
    """(search_paths, dependencies, install_name) from a Mach-O file.

    `install_name` is None for a file with no `LC_ID_DYLIB` -- an executable,
    or a bundle that does not declare one. Callers must treat that as "this
    file has no install name", never as "the install name is the first
    dependency". That confusion is the bug this module was extracted for:
    `otool -L` prints the install name FIRST and only for a dylib, so
    dropping entry zero unconditionally discarded a real dependency from
    every executable.
    """
    with open(path, "rb") as fh:
        data = fh.read()
    try:
        rpaths, deps, install_name, _ = parse_macho(data)
    except InspectError as exc:
        raise InspectError(f"{path}: {exc}") from None
    return rpaths, deps, install_name


def min_os(path):
    """The Mach-O deployment target of `path`, as a string, or None."""
    with open(path, "rb") as fh:
        data = fh.read()
    try:
        return parse_macho(data)[3]
    except InspectError as exc:
        raise InspectError(f"{path}: {exc}") from None


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

def _macho(filetype, commands):
    """Assemble a minimal but structurally real 64-bit Mach-O for the tests.

    Synthesised rather than checked in as a fixture so the parser is tested
    on EVERY platform. The bug being guarded against -- confusing an
    executable for a dylib -- is invisible to any test that only ever sees
    one of them, and a macOS-only fixture would leave Linux CI testing
    nothing.
    """
    body = b"".join(commands)
    header = struct.pack(
        "<IiiIIII",
        0xFEEDFACF,          # MH_MAGIC_64, little-endian on disk
        0x0100000C,          # CPU_TYPE_ARM64
        0,                   # cpusubtype
        filetype,
        len(commands),
        len(body),
        0,                   # flags
    ) + b"\x00\x00\x00\x00"   # reserved
    return header + body


def _lc_dylib(cmd, name):
    raw = name.encode() + b"\x00"
    pad = (-(24 + len(raw))) % 8
    size = 24 + len(raw) + pad
    return struct.pack("<IIIIII", cmd, size, 24, 0, 0, 0) + raw + b"\x00" * pad


def _lc_rpath(path):
    raw = path.encode() + b"\x00"
    pad = (-(12 + len(raw))) % 8
    size = 12 + len(raw) + pad
    return struct.pack("<III", LC_RPATH, size, 12) + raw + b"\x00" * pad


def _lc_build_version(major, minor):
    return struct.pack(
        "<IIIIII", LC_BUILD_VERSION, 24, 1, (major << 16) | (minor << 8), 0, 0
    )


def _selftest():
    failures = []

    def check(label, got, want):
        if got != want:
            failures.append(f"{label}\n  got  {got!r}\n  want {want!r}")

    # A DYLIB: has LC_ID_DYLIB, so its own name must not be reported as a
    # dependency.
    dylib = _macho(MH_DYLIB, [
        _lc_dylib(LC_ID_DYLIB, "@rpath/libm0core.dylib"),
        _lc_dylib(LC_LOAD_DYLIB, "@rpath/libKGENCompilerRTShared.dylib"),
        _lc_dylib(LC_LOAD_DYLIB, "/usr/lib/libSystem.B.dylib"),
        _lc_rpath("@loader_path"),
        _lc_build_version(13, 0),
    ])
    rpaths, deps, name, mos = parse_macho(dylib)
    check("dylib install_name", name, "@rpath/libm0core.dylib")
    check("dylib deps", deps,
          ["@rpath/libKGENCompilerRTShared.dylib", "/usr/lib/libSystem.B.dylib"])
    check("dylib rpaths", rpaths, ["@loader_path"])
    check("dylib min_os", mos, "13.0")

    # An EXECUTABLE: no LC_ID_DYLIB at all. Every dependency is a real one.
    # This is the case both previous copies of the parse got wrong, turning a
    # binary that loads nowhere into a "SELF-CONTAINED" verdict.
    exe = _macho(MH_EXECUTE, [
        _lc_dylib(LC_LOAD_DYLIB, "@rpath/libKGENCompilerRTShared.dylib"),
        _lc_dylib(LC_LOAD_DYLIB, "/usr/lib/libSystem.B.dylib"),
        _lc_rpath("@loader_path"),
        _lc_rpath("@loader_path/../_lib"),
        _lc_build_version(26, 0),
    ])
    rpaths, deps, name, mos = parse_macho(exe)
    check("exe install_name", name, None)
    check("exe deps", deps,
          ["@rpath/libKGENCompilerRTShared.dylib", "/usr/lib/libSystem.B.dylib"])
    check("exe rpaths", rpaths, ["@loader_path", "@loader_path/../_lib"])
    check("exe min_os", mos, "26.0")
    if "@rpath/libKGENCompilerRTShared.dylib" not in deps:
        failures.append(
            "executable's runtime dependency was dropped -- this is the exact "
            "bug binfmt.py exists to prevent"
        )

    # Weak and reexported dylibs are dependencies too.
    weak = _macho(MH_EXECUTE, [
        _lc_dylib(LC_LOAD_WEAK_DYLIB, "@rpath/libWeak.dylib"),
        _lc_dylib(LC_REEXPORT_DYLIB, "@rpath/libRe.dylib"),
    ])
    check("weak/reexport deps", parse_macho(weak)[1],
          ["@rpath/libWeak.dylib", "@rpath/libRe.dylib"])

    # Fat archives must refuse rather than be read as one arbitrary slice.
    try:
        parse_macho(b"\xca\xfe\xba\xbe" + b"\x00" * 60)
        failures.append("a fat archive was parsed instead of refused")
    except InspectError:
        pass

    # ELF dependency classification. Confusing the two directions is a real
    # failure: call libc ours and the bundle tries to ship it; call the Mojo
    # runtime the platform's and the bundle omits what the binary needs.
    for soname in ("libc.so.6", "libm.so.6", "libpthread.so.0",
                   "ld-linux-x86-64.so.2", "libgcc_s.so.1", "libdl.so.2"):
        if not is_system_soname(soname):
            failures.append(f"{soname} should be classified as a platform library")
    for soname in ("libKGENCompilerRTShared.so", "libMSupportGlobals.so",
                   "libAsyncRTRuntimeGlobals.so", "libm0core.so"):
        if is_system_soname(soname):
            failures.append(f"{soname} must NOT be classified as a platform library")

    # Where otool EXISTS, assert the native parse agrees with it on real
    # artifacts. This is the strongest check available and it is why the
    # shell-out is worth keeping around as a test oracle even though it is no
    # longer on the code path.
    import glob
    import os

    oracle_checked = 0
    if _which("otool"):
        for path in glob.glob("bin/m0serve") + glob.glob("packages/m0-core/libm0core.dylib"):
            if not os.path.exists(path):
                continue
            out = subprocess.run(["otool", "-l", path], capture_output=True, text=True)
            if out.returncode != 0:
                continue
            oracle_checked += 1
            native_rpaths, native_deps, native_name = macho_info(path)
            otool_rpaths = re.findall(
                r"^\s*path\s+(.+?)\s+\(offset \d+\)\s*$", out.stdout, re.M
            )
            check(f"{path}: rpaths vs otool", native_rpaths, otool_rpaths)
            has_id = "LC_ID_DYLIB" in out.stdout
            check(f"{path}: install_name presence vs otool",
                  native_name is not None, has_id)
            # `otool -L`, not the `name` fields of `otool -l`: LC_LOAD_DYLINKER
            # also carries a `name` (/usr/lib/dyld), and the dynamic linker is
            # not a dependency. The native parser excludes it by keying on the
            # dylib load commands; a naive grep over `otool -l` does not.
            listing = subprocess.run(
                ["otool", "-L", path], capture_output=True, text=True
            ).stdout
            entries = [
                m.group(1)
                for m in (
                    re.match(r"^\s*(\S+)\s+\(compatibility", ln)
                    for ln in listing.splitlines()[1:]
                )
                if m
            ]
            # otool -L prints LC_ID_DYLIB's name first, and only for a dylib.
            expected_deps = entries[1:] if has_id else entries
            check(f"{path}: deps vs otool -L", native_deps, expected_deps)

    if failures:
        print("binfmt selftest FAILED:", file=sys.stderr)
        for f in failures:
            print("  " + f, file=sys.stderr)
        return 1
    oracle = f", cross-checked against otool on {oracle_checked} real artifact(s)" if oracle_checked else ""
    print(f"binfmt selftest: ok (synthetic Mach-O dylib/executable, ELF sonames{oracle})")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    print(__doc__.strip().splitlines()[-1].strip(), file=sys.stderr)
    sys.exit(2)
