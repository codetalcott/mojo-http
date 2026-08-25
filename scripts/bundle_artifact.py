"""Assemble a self-contained, redistributable bundle around a built artifact.

The built artifact looks for the Mojo runtime beside itself (`@loader_path`,
set by `relocate.py`). This copies that runtime in, so the result loads with
nothing else present — which is what a consumer downloading a release asset,
or installing a wheel, needs.

**The closure is discovered, not hardcoded.** `libKGENCompilerRTShared`
itself needs `libMSupportGlobals` and `libAsyncRTRuntimeGlobals`; a first
attempt that shipped only the library named in the error message failed on
the second. Walking the dependency graph means a toolchain bump that adds a
fourth library is picked up rather than silently producing a broken bundle.

**Executables bundle the same way as dylibs, and used not to.** This script
had its own copy of the Mach-O parse which assumed `otool -L`'s first entry
was the file's own install name — so handed `bin/m0serve`, an `MH_EXECUTE`,
it discarded the one dependency that mattered, copied zero runtime libraries
and reported success. The parse now comes from `binfmt.py`. Two consequences
kept deliberately: `install_name_tool -id` is skipped for a file with no
`LC_ID_DYLIB` (it is meaningless there), and the ad-hoc `codesign` is NOT
skipped (arm64 invalidates the signature on any Mach-O edit, executables
included).

Two layouts, because the same artifact ships two ways:

    flat    everything in one directory, searched with `@loader_path`.
            The tarball release asset.
    wheel   artifact in `_bin/`, closure in `_lib/`, searched with
            `@loader_path/../_lib`. A fixed relative path independent of the
            Python version, which is what lets one wheel serve 3.10-3.14.

    python3 scripts/bundle_artifact.py [--layout flat|wheel] [--also PATH]... \
        <artifact> <outdir>
"""

import glob
import os
import shutil
import subprocess
import sys

from binfmt import (
    SELF_RELATIVE,
    SYSTEM_PREFIXES,
    InspectError,
    classify,
    inspect_elf,
    macho_info,
)


def sh(*cmd, check=True):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"{' '.join(cmd)}\n{r.stderr.strip()}")
    return r.stdout


def modular_lib_dir():
    """The venv's modular/lib, which is where the runtime lives."""
    hits = glob.glob(".venv/lib/python*/site-packages/modular/lib")
    if not hits:
        raise SystemExit("bundle-artifact: no modular/lib found under .venv")
    return hits[0]


def deps_of(path):
    """Non-system dependencies of a Mach-O or ELF file, as recorded names."""
    if classify(path) == "macho":
        _, deps, _ = macho_info(path)
        return [d for d in deps if not d.startswith(SYSTEM_PREFIXES)]
    _, deps, _ = inspect_elf(path)
    # ELF DT_NEEDED entries are bare sonames, so there is no path prefix to
    # filter on. Whether a name is ours is decided by the one question that
    # matters: is it in the toolchain's lib directory? Everything else is
    # expected from the system, which is exactly the manylinux contract.
    return deps


def ensure_self_relative(path, required):
    """Make one Mach-O self-describing: strip foreign search paths, add ours.

    Additive rather than replacing, which matters because an artifact may
    legitimately carry more than one self-relative path -- `bin/m0serve`
    records both `@loader_path` and `@loader_path/../_lib` so a single build
    output serves the flat and wheel layouts. Deleting "everything not in
    this layout's set" would quietly break the other shape. What is always
    removed is a path that is not self-relative at all, because that is the
    build machine.
    """
    _, _, install_name = macho_info(path)
    # Only a file that HAS an install name gets one rewritten. `-id` on an
    # executable is meaningless; this is the executable half of the bug that
    # made the checker and this script agree about an unloadable binary.
    if install_name is not None:
        sh("install_name_tool", "-id", f"@rpath/{os.path.basename(path)}", path)
    existing, _, _ = macho_info(path)
    for rp in existing:
        if not rp.startswith(SELF_RELATIVE):
            sh("install_name_tool", "-delete_rpath", rp, path, check=False)
    for rp in required:
        if rp not in existing:
            sh("install_name_tool", "-add_rpath", rp, path, check=False)
    # arm64 invalidates the signature on any Mach-O edit, and an unsigned
    # binary will not load at all. Executables included.
    sh("codesign", "-f", "-s", "-", path, check=False)


def main() -> int:
    argv = sys.argv[1:]
    layout = "flat"
    also = []
    rest = []
    i = 0
    while i < len(argv):
        if argv[i] == "--layout":
            layout = argv[i + 1]
            i += 2
        elif argv[i] == "--also":
            also.append(argv[i + 1])
            i += 2
        else:
            rest.append(argv[i])
            i += 1
    if len(rest) != 2 or layout not in ("flat", "wheel"):
        print(
            "usage: bundle_artifact.py [--layout flat|wheel] [--also PATH]... "
            "<artifact> <outdir>",
            file=sys.stderr,
        )
        return 2
    artifact, outdir = rest

    bindir = os.path.join(outdir, "_bin") if layout == "wheel" else outdir
    libdir = os.path.join(outdir, "_lib") if layout == "wheel" else outdir
    os.makedirs(bindir, exist_ok=True)
    os.makedirs(libdir, exist_ok=True)
    # Wheel: the binary sits one level down from its libraries, at a path that
    # does not contain the Python version. Flat: everything is siblings.
    art_rpaths = ["@loader_path", "@loader_path/../_lib"] if layout == "wheel" else [
        "@loader_path"
    ]

    staged = os.path.join(bindir, os.path.basename(artifact))
    # Completing a bundle in place (`bundle_artifact.py bin/m0serve bin`) is
    # how the development tree gets the same shape as the shipped artifact,
    # so the binary the smokes exercise is the binary users get.
    if os.path.abspath(artifact) != os.path.abspath(staged):
        shutil.copy2(artifact, staged)

    try:
        fmt = classify(staged)
    except InspectError as exc:
        print(f"bundle-artifact: {exc}", file=sys.stderr)
        return 2

    modlib = modular_lib_dir()
    seen = {os.path.basename(staged)}
    roots = [staged]

    # Extra artifacts ride into the library directory and are walked with the
    # same closure discovery -- `--also libm0core` is how the wheel carries
    # the shared library `M0_CORE_LIB` names.
    for extra in also:
        dst = os.path.join(libdir, os.path.basename(extra))
        if os.path.abspath(extra) != os.path.abspath(dst):
            shutil.copy2(extra, dst)
        seen.add(os.path.basename(dst))
        roots.append(dst)

    queue = list(roots)
    copied = []
    top_level_foreign = 0
    while queue:
        cur = queue.pop(0)
        try:
            cur_deps = deps_of(cur)
        except (InspectError, ValueError) as exc:
            print(f"bundle-artifact: {exc}", file=sys.stderr)
            return 2
        for dep in cur_deps:
            base = os.path.basename(dep)
            if cur in roots and not dep.startswith(SELF_RELATIVE):
                top_level_foreign += 1
            if base in seen:
                continue
            src = os.path.join(modlib, base)
            if not os.path.exists(src):
                if fmt == "macho" and (
                    dep.startswith(SELF_RELATIVE) or dep.startswith("@rpath/")
                ):
                    raise SystemExit(
                        f"bundle-artifact: {cur} needs {base}, which is not in {modlib}"
                    )
                # ELF: a soname absent from the toolchain's lib dir is a
                # system library, supplied by the platform.
                continue
            seen.add(base)
            dst = os.path.join(libdir, base)
            shutil.copy2(src, dst)
            copied.append(base)
            queue.append(dst)

    if fmt == "macho":
        # A parser regression would silently produce an empty bundle that the
        # checker then blesses. If the artifact names dependencies we are
        # meant to satisfy and we satisfied none, that is a build failure, not
        # a self-contained bundle.
        if top_level_foreign and not copied:
            raise SystemExit(
                f"bundle-artifact: {staged} records {top_level_foreign} non-system "
                "dependencies but nothing was copied — the dependency parse is "
                "broken (run: python3 scripts/binfmt.py --selftest)"
            )
        ensure_self_relative(staged, art_rpaths)
        for name in copied + [os.path.basename(p) for p in roots[1:]]:
            ensure_self_relative(os.path.join(libdir, name), ["@loader_path"])
    elif copied:
        # Every Linux artifact this repo produces is statically linked, so
        # nothing should ever be copied here. If that changes, the copies
        # need a $ORIGIN RUNPATH that this script does not set -- and a
        # bundle that is quietly missing one is exactly the class of defect
        # the whole file exists to prevent. Refuse rather than guess.
        raise SystemExit(
            f"bundle-artifact: {staged} needed {len(copied)} runtime "
            f"librar{'y' if len(copied) == 1 else 'ies'} ({', '.join(copied)}), "
            "but the ELF path assumes static linking and sets no RUNPATH on "
            "the copies. Teach relocate.py/patchelf to set $ORIGIN before "
            "shipping this."
        )

    total = os.path.getsize(staged) + sum(
        os.path.getsize(os.path.join(libdir, n))
        for n in copied + [os.path.basename(p) for p in roots[1:]]
    )
    print(f"bundled {staged}")
    for name in copied + [os.path.basename(p) for p in roots[1:]]:
        size = os.path.getsize(os.path.join(libdir, name)) / 1e6
        print(f"  + {name}  ({size:.2f} MB)")
    if not copied:
        print("  (no runtime libraries needed — statically linked)")
    print(f"  total {total / 1e6:.2f} MB across {len(copied) + len(roots)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
