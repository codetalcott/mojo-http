"""Assert the C-ABI artifact does not depend on the machine that built it.

`smoke-ffi` builds `libm0core` and `dlopen`s it **in the build tree**, where
the venv it was linked against is still present — so it passes on exactly
the machine where the defect cannot manifest. It has therefore never been
able to catch the thing that actually matters to someone downloading a
release: whether the artifact loads anywhere else.

It does not. A Mojo shared library records an `LC_RPATH` (Mach-O) or
`DT_RUNPATH` (ELF) pointing at the *absolute path of the venv it was built
in*, and resolves `libKGENCompilerRTShared` — the Mojo runtime — through it.
On the build machine that path exists. On a consumer's machine it does not,
and `dlopen` fails with:

    Library not loaded: @rpath/libKGENCompilerRTShared.dylib
      tried: '/Users/runner/work/mojo-http/mojo-http/.venv/.../modular/lib/...'

which is the CI runner's directory, baked into a published release asset.

This checks the property `smoke-ffi` cannot: **every recorded search path is
relative to the artifact itself, and every dependency is either a system
library or one shipped beside it.** Static inspection rather than a load
attempt, because a load attempt on the build machine succeeds by definition.

Exit 0 = portable. Exit 1 = depends on its build machine. Exit 2 = could not
inspect (missing tool), which is reported rather than passed silently.

    python3 scripts/ffi_portability_check.py packages/m0-core/libm0core.dylib
"""

import os
import re
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


def inspect_macho(path):
    """(search_paths, dependencies, install_name) from a Mach-O file."""
    load = _run(["otool", "-l", path])
    deps = _run(["otool", "-L", path])
    if load is None or deps is None:
        print("ffi-portability: otool unavailable or failed", file=sys.stderr)
        sys.exit(2)

    rpaths = re.findall(r"^\s*path\s+(.+?)\s+\(offset \d+\)\s*$", load, re.M)
    # `otool -L` prints a header line, then the library's OWN install name
    # (LC_ID_DYLIB), then its dependencies. The install name is not a
    # dependency and must not be reported as one -- but it is worth checking
    # separately, because a relative one is recorded into anything that later
    # links against this library.
    entries = [
        m.group(1)
        for m in (
            re.match(r"^\s*(\S+)\s+\(compatibility", ln)
            for ln in deps.splitlines()[1:]
        )
        if m
    ]
    install_name = entries[0] if entries else None
    return rpaths, entries[1:], install_name


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
    import struct

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


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    require_self_contained = "--require-self-contained" in sys.argv
    if len(args) != 1:
        print(
            "usage: ffi_portability_check.py [--require-self-contained] <library>",
            file=sys.stderr,
        )
        return 2
    path = args[0]
    if not os.path.exists(path):
        print(f"ffi-portability: {path} does not exist", file=sys.stderr)
        return 2

    with open(path, "rb") as fh:
        magic = fh.read(4)
    is_macho = magic in (
        b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
        b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
        b"\xca\xfe\xba\xbe",
    )
    is_elf = magic == b"\x7fELF"
    if is_macho:
        search, deps, install_name = inspect_macho(path)
    elif is_elf:
        search, deps, install_name = inspect_elf(path)
    else:
        print(f"ffi-portability: {path} is neither Mach-O nor ELF", file=sys.stderr)
        return 2

    print(f"artifact      : {path}")
    print(f"install name  : {install_name or '(none)'}")
    print(f"search paths  : {search or '(none)'}")
    print(f"dependencies  : {deps or '(none)'}")

    # Three honest states, because "portable" is not one bit of information:
    #
    #   broken         only loads on the machine that built it
    #   satisfiable    loads once the named files are placed beside it
    #   self-contained loads with nothing else present
    #
    # The distinction is what makes this gateable. A build can be fixed to
    # `satisfiable` without anyone's permission; reaching `self-contained`
    # means redistributing the Mojo runtime, which is a licensing question
    # (see docs/FFI_DISTRIBUTION.md). Failing the build for not having
    # answered that would just block releases.
    self_relative_search = [p for p in search if p.startswith(SELF_RELATIVE)]
    foreign_search = [p for p in search if not p.startswith(SELF_RELATIVE)]

    here = os.path.dirname(os.path.abspath(path)) or "."
    unresolved, missing_beside = [], []
    for d in deps:
        if d.startswith(SELF_RELATIVE) or d.startswith(SYSTEM_PREFIXES):
            continue
        if d.startswith("@rpath/") or not os.path.isabs(d):
            if os.path.exists(os.path.join(here, os.path.basename(d))):
                continue
            # Resolvable by the consumer only if the artifact looks beside
            # itself; otherwise it can only ever find it on the build box.
            (missing_beside if self_relative_search else unresolved).append(d)
        else:
            unresolved.append(d)

    bad_install_name = bool(
        install_name
        and not (
            install_name.startswith(SELF_RELATIVE)
            or install_name.startswith("@rpath/")
            or install_name.startswith(SYSTEM_PREFIXES)
            or "/" not in install_name
        )
    )

    # `dlopen` ignores the install name, so it cannot break loading — but it
    # is recorded into anything that LINKS against this library, which then
    # inherits the same defect.
    broken = bool(unresolved) or bad_install_name
    print("")

    if broken:
        print("BROKEN — this artifact only works on the machine that built it:")
        for d in unresolved:
            print(
                f"  - dependency {d!r} resolves only through {foreign_search or '(no search path)'},"
                " which is the build machine's own directory"
            )
        if bad_install_name:
            print(
                f"  - install name is a build-tree path: {install_name!r} —"
                " dlopen ignores it, but anything that LINKS against this"
                " library records it and then cannot find it"
            )
        if foreign_search and not unresolved:
            for p in foreign_search:
                print(f"  - build-machine search path recorded: {p!r}")
        print("")
        print("A consumer who downloads this from a GitHub release cannot use it.")
        return 1

    if missing_beside:
        print("SATISFIABLE — loads once these are placed beside it:")
        for d in missing_beside:
            print(f"  - {os.path.basename(d)}")
        print(f"  (search path is {self_relative_search}, so the consumer can supply them)")
        if foreign_search:
            print("")
            print("  note: a build-machine path is also recorded and is inert here,")
            print(f"  but leaks the build directory: {foreign_search}")
        if require_self_contained:
            print("")
            print("--require-self-contained was given: this is not self-contained.")
            return 1
        return 0

    if foreign_search:
        # Nothing resolves through it, so it cannot cause a load failure —
        # a statically linked ELF with a leftover RUNPATH looks like this.
        print("SELF-CONTAINED — nothing is resolved at load time.")
        print(f"  note: an inert build-machine path is recorded: {foreign_search}")
        return 0

    print("SELF-CONTAINED — every search path is self-relative and every"
          " dependency is a system library or shipped alongside.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
