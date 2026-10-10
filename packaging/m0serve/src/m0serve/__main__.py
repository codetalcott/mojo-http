"""Console-script shim: point the embedded interpreter at this environment, then exec.

`m0serve` is a compiled binary, not a Python program. It could have been
shipped straight into the wheel's `.data/scripts/` and put on PATH with no
Python involved — this thin shim exists for three reasons, in weight order.

**The Mojo runtime has to be findable.** From `.data/scripts` the binary lands
in `<prefix>/bin/` while its libraries live in site-packages, and the relative
path between those contains the Python minor version — so the rpath would
have to be baked per interpreter, and one wheel per platform would become one
per platform per version. Inside the package, `@loader_path/../_lib` is fixed.

**Console scripts are the one mechanism every installer agrees on.** pip,
`uv pip`, `uv tool`, `uvx` and pipx all materialise an entry point the same
way; loose files under `.data/scripts` they do not.

**And the interpreter has to be the right one.** m0serve `dlopen`s libpython
rather than linking it, resolving it from the `python3` it finds on PATH. Left
alone that is whatever `python3` happens to mean in the caller's shell, which
may be a different environment from the one holding the application. Here the
answer is known — this file is running inside the target interpreter — so the
shim states it rather than letting PATH decide.

`os.execve` replaces the process image, so the pid does not change: signal
handling, the supervisor's graceful drain and `docker stop` behave exactly as
they do against a directly-invoked binary.
"""

import os
import sys
import sysconfig
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_EXE = _HERE / "_bin" / ("m0serve.exe" if os.name == "nt" else "m0serve")
_LIB = _HERE / "_lib"


def _libpython_candidates(config=None, base_prefix=None, platform=None):
    """Every path the running interpreter's shared libpython may be at, in order.

    sysconfig reports where the library was INSTALLED, which is not always
    where it is: a relocatable build (python-build-standalone, so every
    interpreter uv installs) keeps the build machine's `LIBDIR`, and older
    ones report `/install/lib` (#612). So the search is the names sysconfig
    gives crossed with the directories it names, and `sys.base_prefix`'s
    `lib/` last, which is where a relocated interpreter's library went.

    It must include every path the Mojo runtime's own lookup tries --
    `libpython{py_version_short}{ABIFLAGS}.{dylib,so}` in `LIBPL` and then
    `LIBDIR` -- because `main` refuses when it finds nothing, and that
    refusal is only right if the runtime would have found nothing too.
    No static archive: `LDLIBRARY` names `libpython3.X.a` in a build without
    a shared library, and `dlopen` cannot load one. `Py_ENABLE_SHARED` is
    not asked: a macOS framework build (python.org's installer, Apple's
    command-line tools) reports 0 and keeps a `libpython3.X.dylib` in
    `LIBDIR` that the runtime loads, so asking would refuse it.

    The arguments exist for the tests (`scripts/wheel_shim.py`).
    """
    config = config or sysconfig.get_config_var
    base_prefix = sys.base_prefix if base_prefix is None else base_prefix
    platform = sys.platform if platform is None else platform
    ext = "dylib" if platform == "darwin" else "so"
    plain = "libpython%s%s.%s" % (
        config("py_version_short") or "",
        config("ABIFLAGS") or "",
        ext,
    )
    names = []
    for name in (config("INSTSONAME"), config("LDLIBRARY"), plain):
        if name and not name.endswith(".a") and name not in names:
            names.append(name)
    dirs = []
    for d in (
        config("LIBDIR"),
        config("LIBPL"),
        os.path.join(base_prefix, "lib") if base_prefix else None,
    ):
        if d and d not in dirs:
            dirs.append(d)
    return [Path(d) / name for d in dirs for name in names]


def _libpython(candidates=None):
    """The first candidate that exists, or None."""
    for candidate in _libpython_candidates() if candidates is None else candidates:
        if candidate.is_file():
            return candidate
    return None


# Flags m0serve answers before it starts the interpreter, so a missing
# libpython is no reason to refuse them.
_NO_PYTHON = ("--version", "-V", "--help", "-h")


def _core_lib():
    """The bundled libm0core, which m0serve cannot find on its own here.

    `_discover_core_lib` (packages/m0-wsgi/m0serve.mojo) looks beside argv[0]
    and then at `packages/m0-core/` relative to the working directory. In a
    wheel install the first is `_bin/` and the second does not exist, so
    without this the `--realtime` and ASGI `state["m0"]` paths lose their
    shared event ids -- and lose them silently, as duplicate suppression
    quietly not working rather than as an error.
    """
    for ext in (".dylib", ".so"):
        candidate = _LIB / f"libm0core{ext}"
        if candidate.exists():
            return candidate
    return None


def build_env(base=None):
    """The environment m0serve is exec'd with. Split out so tests can read it."""
    env = dict(os.environ if base is None else base)
    interpreter = Path(sys.executable)

    # PATH first, because it is the mechanism that actually works: Mojo finds
    # `python3`, and CPython's own path calculation then finds the pyvenv.cfg
    # beside it and adds that environment's site-packages. This is exactly
    # what the poe virtualenv executor does for every smoke in the repo.
    bindir = str(interpreter.parent)
    path = env.get("PATH", "")
    if path.split(os.pathsep)[:1] != [bindir]:
        env["PATH"] = bindir + (os.pathsep + path if path else "")

    # Belt and braces, and never over a value the user set deliberately.
    if "MOJO_PYTHON_LIBRARY" not in env:
        lib = _libpython()
        if lib is not None:
            env["MOJO_PYTHON_LIBRARY"] = str(lib)

    if "M0_CORE_LIB" not in env:
        core = _core_lib()
        if core is not None:
            env["M0_CORE_LIB"] = str(core)

    return env


def main(argv=None):
    argv = sys.argv if argv is None else argv

    if not _EXE.exists():
        sys.exit(
            f"m0serve: the server binary is missing from this install "
            f"({_EXE}).\nThis wheel was built without it — reinstall with "
            f"`pip install --force-reinstall m0serve`, and if that does not "
            f"fix it please report it."
        )

    # Without a libpython the server cannot start its interpreter, and the
    # Mojo runtime says so by aborting with a stack dump, `--doctor` included
    # (#612). The search above holds every path the runtime tries, so here
    # nothing would have been found: refuse, naming the fix. A user's own
    # MOJO_PYTHON points the runtime at another interpreter, which this
    # process cannot search for it, so that one is left to the runtime.
    env = build_env()
    if (
        "MOJO_PYTHON_LIBRARY" not in env
        and "MOJO_PYTHON" not in env
        and not any(arg in _NO_PYTHON for arg in argv[1:])
    ):
        looked = sorted({str(c.parent) for c in _libpython_candidates()})
        sys.stderr.write(
            f"m0serve: found no shared libpython for {sys.executable} "
            f"(looked in {', '.join(looked) or 'nothing sysconfig names'}).\n"
            f"Set MOJO_PYTHON_LIBRARY to the interpreter's libpython, or use "
            f"an interpreter built with --enable-shared.\n"
        )
        sys.exit(78)

    # argv[0] is the real path rather than "m0serve": it keeps m0serve's own
    # libm0core discovery meaningful and makes `ps` legible.
    try:
        os.execve(str(_EXE), [str(_EXE), *argv[1:]], env)
    except PermissionError:
        sys.exit(
            f"m0serve: {_EXE} is not executable. The wheel should ship it with "
            f"the execute bit set; `chmod +x {_EXE}` works around it."
        )
    except OSError as exc:
        sys.exit(f"m0serve: could not start {_EXE}: {exc}")


if __name__ == "__main__":
    main()
