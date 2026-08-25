"""Rewrite a freshly linked artifact so it does not name the machine that built it.

`mojo build` records two things that are the BUILD MACHINE's and meaningless
to anyone else: the venv it was built in becomes a search path (`LC_RPATH` /
`DT_RUNPATH`), and the output path becomes the install name. Neither can be
suppressed with a linker flag, because the compiler adds them itself — so
they are rewritten after the link.

This lived as ~25 lines of inline shell inside the `build-ffi` poe task.
`build-serve` needed the same treatment and had none, which is why
`bin/m0serve` shipped with a search path pointing into a developer's
`.venv`. Rather than copy the shell, both tasks call this.

    relocate.py --id libm0core.dylib --rpath '@loader_path' <artifact>
    relocate.py --no-id --rpath '@loader_path' --rpath '@loader_path/../_lib' <artifact>

`--no-id` is not the same as omitting `--id`: it is an assertion that the
caller knows this artifact has no install name to set (an executable), so a
file that unexpectedly has one is a mistake worth reporting rather than
silently leaving wrong.
"""

import os
import subprocess
import sys

from binfmt import InspectError, classify, inspect_elf, is_system_soname, macho_info


def sh(*cmd, check=True):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"relocate: {' '.join(cmd)}\n{r.stderr.strip()}")
    return r.stdout


def relocate_macho(path, set_id, rpaths):
    existing, _, install_name = macho_info(path)

    if set_id is not None:
        if install_name is None:
            raise SystemExit(
                f"relocate: --id {set_id} was given but {path} has no LC_ID_DYLIB "
                "(it is not a dylib)"
            )
        sh("install_name_tool", "-id", f"@rpath/{set_id}", path)
    elif install_name is not None:
        raise SystemExit(
            f"relocate: --no-id was given but {path} HAS an install name "
            f"({install_name!r}) — it would be left naming the build tree"
        )

    # Delete before adding: load commands live in a fixed-size header region,
    # and freeing the long build-tree path first is what makes room for the
    # short self-relative ones.
    for rp in existing:
        if rp not in rpaths:
            sh("install_name_tool", "-delete_rpath", rp, path, check=False)
    for rp in rpaths:
        if rp not in existing:
            sh("install_name_tool", "-add_rpath", rp, path, check=False)

    # arm64 macOS invalidates the signature on any Mach-O edit, and an
    # unsigned binary will not load at all. Executables included.
    sh("codesign", "-f", "-s", "-", path, check=False)

    after, _, _ = macho_info(path)
    leftover = [p for p in after if p not in rpaths]
    if leftover:
        raise SystemExit(
            f"relocate: {path} still records build-machine search paths after "
            f"rewriting: {leftover}"
        )
    return after


def elf_spelling(rpaths):
    """Translate self-relative search paths into ELF's spelling.

    Call sites name `@loader_path` because that is what the Mach-O side uses
    and because one call should not have to know which platform it is on.
    ELF spells the same idea `$ORIGIN`.
    """
    out = []
    for rp in rpaths:
        out.append(rp.replace("@loader_path", "$ORIGIN").replace("@executable_path", "$ORIGIN"))
    return out


def relocate_elf(path, rpaths):
    """Set DT_RUNPATH, and refuse to skip it when something actually needs it.

    This used to be best-effort, on the documented grounds that "the Linux
    artifacts are statically linked, so DT_RUNPATH resolves nothing". That is
    true of `libm0core.so` and **false of `bin/m0serve`**, which carries real
    DT_NEEDED entries for the Mojo runtime — the CI run that first bundled it
    on Linux is what established that. So the distinction is drawn from the
    file rather than assumed: if nothing non-system is needed, a missing
    patchelf is fine and the RUNPATH is only cosmetic debris; if something is,
    building without patchelf would produce a binary that cannot find its own
    runtime, and that is a hard failure.
    """
    _, deps, _ = inspect_elf(path)
    needs_runpath = bool([d for d in deps if not is_system_soname(d)])

    if not shutil_which("patchelf"):
        if needs_runpath and rpaths:
            raise SystemExit(
                f"relocate: {path} needs {deps} at load time and patchelf is "
                "not installed, so DT_RUNPATH cannot be set. Install patchelf "
                "(apt-get install patchelf) — on Linux it is a build "
                "requirement for this artifact, not an optional cleanup."
            )
        print(f"relocate: patchelf not found; leaving {path} unchanged")
        return []

    spelled = elf_spelling(rpaths)
    if spelled:
        sh("patchelf", "--set-rpath", ":".join(spelled), path)
    else:
        sh("patchelf", "--remove-rpath", path, check=False)
    return spelled



def shutil_which(name):
    from shutil import which

    return which(name)


def main() -> int:
    argv = sys.argv[1:]
    set_id = None
    no_id = False
    rpaths = []
    rest = []
    i = 0
    while i < len(argv):
        if argv[i] == "--id":
            set_id = argv[i + 1]
            i += 2
        elif argv[i] == "--no-id":
            no_id = True
            i += 1
        elif argv[i] == "--rpath":
            rpaths.append(argv[i + 1])
            i += 2
        else:
            rest.append(argv[i])
            i += 1

    if len(rest) != 1 or (set_id is None and not no_id):
        print(
            "usage: relocate.py (--id NAME | --no-id) [--rpath PATH]... <artifact>",
            file=sys.stderr,
        )
        return 2
    path = rest[0]
    if not os.path.exists(path):
        print(f"relocate: {path} does not exist", file=sys.stderr)
        return 2

    try:
        fmt = classify(path)
    except InspectError as exc:
        print(f"relocate: {exc}", file=sys.stderr)
        return 2

    if fmt == "macho":
        final = relocate_macho(path, set_id, rpaths)
    else:
        final = relocate_elf(path, rpaths)
    print(f"relocated {path} (search paths: {final or '(none)'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
