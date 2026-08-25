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


def _libpython():
    """The shared libpython of the interpreter running this shim, or None.

    Same recipe the repo's own free-threading probe uses (`poe py-thread-probe`):
    LIBDIR + INSTSONAME from sysconfig. Guarded twice, because both guards
    catch real configurations -- a statically built CPython has no shared
    library at all, and some distributions report a path that is not there.
    """
    if not sysconfig.get_config_var("Py_ENABLE_SHARED"):
        return None
    libdir = sysconfig.get_config_var("LIBDIR")
    soname = sysconfig.get_config_var("INSTSONAME") or sysconfig.get_config_var(
        "LDLIBRARY"
    )
    if not libdir or not soname:
        return None
    candidate = Path(libdir) / soname
    return candidate if candidate.exists() else None


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

    # argv[0] is the real path rather than "m0serve": it keeps m0serve's own
    # libm0core discovery meaningful and makes `ps` legible.
    try:
        os.execve(str(_EXE), [str(_EXE), *argv[1:]], build_env())
    except PermissionError:
        sys.exit(
            f"m0serve: {_EXE} is not executable. The wheel should ship it with "
            f"the execute bit set; `chmod +x {_EXE}` works around it."
        )
    except OSError as exc:
        sys.exit(f"m0serve: could not start {_EXE}: {exc}")


if __name__ == "__main__":
    main()
