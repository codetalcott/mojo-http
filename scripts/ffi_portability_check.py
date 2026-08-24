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
    """(search_paths, dependencies, soname) from an ELF file."""
    out = _run(["readelf", "-d", path]) or _run(["objdump", "-p", path])
    if out is None:
        print(
            "ffi-portability: neither readelf nor objdump is available",
            file=sys.stderr,
        )
        sys.exit(2)
    search = []
    for key in ("RUNPATH", "RPATH"):
        for m in re.finditer(key + r"\)?\s*.*?\[(.*?)\]", out):
            search.extend(p for p in m.group(1).split(":") if p)
    deps = re.findall(r"NEEDED\)?\s*.*?\[(.*?)\]", out)
    soname_m = re.search(r"SONAME\)?\s*.*?\[(.*?)\]", out)
    return search, deps, (soname_m.group(1) if soname_m else None)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    path = sys.argv[1]
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

    problems = []

    # A search path that names an absolute location on the build machine is
    # the defect itself: it is meaningless anywhere else.
    for p in search:
        if not p.startswith(SELF_RELATIVE):
            problems.append(
                f"search path is not relative to the artifact: {p!r}"
                " — this is the build machine's own directory, and nothing"
                " resolves through it on a consumer's machine"
            )

    # A dependency must be a system library, self-relative, or shipped beside
    # the artifact. Anything else cannot be satisfied by the release.
    here = os.path.dirname(os.path.abspath(path)) or "."
    for d in deps:
        if d.startswith(SELF_RELATIVE) or d.startswith(SYSTEM_PREFIXES):
            continue
        if d.startswith("@rpath/") or not os.path.isabs(d):
            beside = os.path.join(here, os.path.basename(d))
            if os.path.exists(beside):
                continue
            problems.append(
                f"dependency {d!r} is resolved through the search path above"
                f" and is not shipped beside the artifact"
                f" ({os.path.basename(d)} is absent from {here})"
            )
        else:
            problems.append(f"dependency names an absolute non-system path: {d!r}")

    # Not a load-time failure -- `dlopen` ignores the install name -- but it is
    # recorded into anything that LINKS against this library, so a relative
    # build path here hands the same defect to the next consumer along.
    # `@rpath/libfoo.dylib` is the idiomatic install name for a
    # redistributable library — the consumer's rpath resolves it — so it is
    # correct, not a defect. A bare filename is fine too. What is wrong is a
    # path from the build tree.
    if install_name and not (
        install_name.startswith(SELF_RELATIVE)
        or install_name.startswith("@rpath/")
        or install_name.startswith(SYSTEM_PREFIXES)
        or "/" not in install_name
    ):
        problems.append(
            f"install name is a build-tree path: {install_name!r} — dlopen"
            " ignores it, but anything that LINKS against this library"
            " records it and then fails to find it"
        )

    if problems:
        print("")
        print("NOT PORTABLE — this artifact only loads on the machine that built it:")
        for p in problems:
            print(f"  - {p}")
        print("")
        print("A consumer who downloads this from a GitHub release cannot dlopen it.")
        return 1

    print("")
    print("portable: every search path is self-relative and every dependency"
          " is a system library or shipped alongside")
    return 0


if __name__ == "__main__":
    sys.exit(main())
