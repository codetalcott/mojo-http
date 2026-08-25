"""Assert a distributable artifact does not depend on the machine that built it.

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

**Executables are checked the same way, and used not to be.** The Mach-O
parse lived here and assumed `otool -L`'s first entry was the file's own
`LC_ID_DYLIB` — true of a dylib, false of `bin/m0serve` — so the CLI's one
real dependency was discarded and a binary that loads nowhere reported as
SELF-CONTAINED. The parse now lives in `binfmt.py`, which keys on the load
command's presence and self-tests both cases. See docs/FFI_DISTRIBUTION.md.

Exit 0 = portable. Exit 1 = depends on its build machine. Exit 2 = could not
inspect (missing tool, fat archive), which is reported rather than passed
silently.

    python3 scripts/ffi_portability_check.py packages/m0-core/libm0core.dylib
    python3 scripts/ffi_portability_check.py --require-self-contained bin/m0serve
"""

import os
import sys

from binfmt import (
    SELF_RELATIVE,
    SYSTEM_PREFIXES,
    InspectError,
    classify,
    inspect_elf,
    is_system_soname,
    macho_info,
    min_os,
)


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    require_self_contained = "--require-self-contained" in sys.argv
    require_min_os = None
    for a in sys.argv[1:]:
        if a.startswith("--require-min-os="):
            require_min_os = a.split("=", 1)[1]
    if len(args) != 1:
        print(
            "usage: ffi_portability_check.py [--require-self-contained] "
            "[--require-min-os=X.Y] <artifact>",
            file=sys.stderr,
        )
        return 2
    path = args[0]
    if not os.path.exists(path):
        print(f"ffi-portability: {path} does not exist", file=sys.stderr)
        return 2

    try:
        fmt = classify(path)
        if fmt == "macho":
            search, deps, install_name = macho_info(path)
            deployment_target = min_os(path)
        else:
            search, deps, install_name = inspect_elf(path)
            deployment_target = None
    except InspectError as exc:
        print(f"ffi-portability: {exc}", file=sys.stderr)
        return 2

    print(f"artifact      : {path}")
    # An executable has no install name. Saying so beats printing "(none)",
    # which reads like a defect rather than a property of the filetype.
    if install_name is None:
        print(
            "install name  : "
            + ("(not a dylib — no LC_ID_DYLIB)" if fmt == "macho" else "(no DT_SONAME)")
        )
    else:
        print(f"install name  : {install_name}")
    print(f"search paths  : {search or '(none)'}")
    print(f"dependencies  : {deps or '(none)'}")
    if deployment_target:
        print(f"min OS        : {deployment_target}")

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

    def resolves_locally(dep):
        """Is `dep` present along one of the artifact's own search paths?

        Not just beside the artifact: a self-relative path may point
        elsewhere, and the wheel layout depends on exactly that -- the binary
        lives in `_bin/` and searches `@loader_path/../_lib`. Checking only
        the artifact's own directory would report that arrangement as merely
        satisfiable when it is in fact complete.
        """
        base = os.path.basename(dep)
        for sp in self_relative_search or ["@loader_path"]:
            prefix = next((s for s in SELF_RELATIVE if sp.startswith(s)), None)
            if prefix is None:
                continue
            resolved = os.path.normpath(os.path.join(here, sp[len(prefix) :].lstrip("/")))
            if os.path.exists(os.path.join(resolved, base)):
                return True
        return False

    unresolved, missing_beside = [], []
    for d in deps:
        if d.startswith(SELF_RELATIVE) or d.startswith(SYSTEM_PREFIXES):
            continue
        # ELF names dependencies by bare soname, so the prefix rule above
        # never matches one. Without this a Linux binary is "broken" for
        # needing libc, which is not a finding. It went unnoticed because
        # libm0core.so has no DT_NEEDED at all -- the first ELF artifact with
        # real dependencies is bin/m0serve.
        if fmt == "elf" and is_system_soname(d):
            continue
        if d.startswith("@rpath/") or not os.path.isabs(d):
            if resolves_locally(d):
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

    if require_min_os and deployment_target:
        # The most literal form of "depends on the machine that built it": a
        # Mojo binary inherits the build host's SDK, so this is a property of
        # the runner, not a choice, unless something pins it.
        if _ver(deployment_target) > _ver(require_min_os):
            print(
                f"MIN-OS TOO HIGH — built against macOS {deployment_target}, "
                f"but {require_min_os} was required."
            )
            print("  The deployment target follows the build host's SDK.")
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


def _ver(s):
    return tuple(int(p) for p in s.split(".") if p.isdigit())


if __name__ == "__main__":
    sys.exit(main())
