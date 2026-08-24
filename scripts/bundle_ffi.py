"""Assemble a self-contained, redistributable `libm0core` bundle.

The built artifact looks for the Mojo runtime beside itself (`@loader_path`,
set by `build-ffi`). This copies that runtime in, so the result loads with
nothing else present — which is what a consumer downloading a release asset
needs.

**The closure is discovered, not hardcoded.** `libKGENCompilerRTShared`
itself needs `libMSupportGlobals` and `libAsyncRTRuntimeGlobals`; a first
attempt that shipped only the library named in the error message failed on
the second. Walking the dependency graph means a toolchain bump that adds a
fourth library is picked up rather than silently producing a broken bundle.

Linux needs none of this: that `.so` has no `DT_NEEDED` entries at all and is
statically linked, so the bundle is the artifact plus its licences.

    python3 scripts/bundle_ffi.py <artifact> <outdir>
"""

import os
import re
import shutil
import subprocess
import sys


SELF_RELATIVE = ("@loader_path", "@executable_path", "$ORIGIN")
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/", "/lib/", "/lib64/")


def sh(*cmd, check=True):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"{' '.join(cmd)}\n{r.stderr.strip()}")
    return r.stdout


def macho_deps(path):
    """Dependencies of a Mach-O file, excluding its own install name."""
    out = sh("otool", "-L", path)
    entries = [
        m.group(1)
        for m in (
            re.match(r"^\s*(\S+)\s+\(compatibility", ln)
            for ln in out.splitlines()[1:]
        )
        if m
    ]
    return entries[1:] if entries else []


def modular_lib_dir():
    """The venv's modular/lib, which is where the runtime lives."""
    import glob

    hits = glob.glob(".venv/lib/python*/site-packages/modular/lib")
    if not hits:
        raise SystemExit("bundle-ffi: no modular/lib found under .venv")
    return hits[0]


def make_self_relative(path):
    """Rewrite one Mach-O so it names itself and searches beside itself."""
    name = os.path.basename(path)
    sh("install_name_tool", "-id", f"@rpath/{name}", path)
    rpaths = re.findall(
        r"^\s*path\s+(.+?)\s+\(offset \d+\)\s*$", sh("otool", "-l", path), re.M
    )
    for rp in rpaths:
        if rp != "@loader_path":
            sh("install_name_tool", "-delete_rpath", rp, path, check=False)
    if "@loader_path" not in rpaths:
        sh("install_name_tool", "-add_rpath", "@loader_path", path, check=False)
    # arm64 invalidates the signature on any Mach-O edit, and an unsigned
    # dylib will not load at all.
    sh("codesign", "-f", "-s", "-", path, check=False)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: bundle_ffi.py <artifact> <outdir>", file=sys.stderr)
        return 2
    artifact, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)

    staged = os.path.join(outdir, os.path.basename(artifact))
    shutil.copy2(artifact, staged)

    with open(artifact, "rb") as fh:
        is_macho = fh.read(4) != b"\x7fELF"

    if not is_macho:
        print(f"bundled (statically linked, no runtime needed): {staged}")
        return 0

    modlib = modular_lib_dir()
    seen = {os.path.basename(staged)}
    queue = [staged]
    copied = []
    while queue:
        cur = queue.pop(0)
        for dep in macho_deps(cur):
            if dep.startswith(SYSTEM_PREFIXES):
                continue
            base = os.path.basename(dep)
            if base in seen:
                continue
            src = os.path.join(modlib, base)
            if not os.path.exists(src):
                if dep.startswith(SELF_RELATIVE) or dep.startswith("@rpath/"):
                    raise SystemExit(
                        f"bundle-ffi: {cur} needs {base}, which is not in {modlib}"
                    )
                continue
            seen.add(base)
            dst = os.path.join(outdir, base)
            shutil.copy2(src, dst)
            copied.append(base)
            queue.append(dst)

    for name in [os.path.basename(staged)] + copied:
        make_self_relative(os.path.join(outdir, name))

    total = sum(
        os.path.getsize(os.path.join(outdir, n))
        for n in [os.path.basename(staged)] + copied
    )
    print(f"bundled {staged}")
    for name in copied:
        print(f"  + {name}  ({os.path.getsize(os.path.join(outdir, name)) / 1e6:.2f} MB)")
    print(f"  total {total / 1e6:.2f} MB across {len(copied) + 1} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
