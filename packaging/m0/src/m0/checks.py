"""The ONE list of checks, read by every command that refuses.

`preflight()` stops at the first failure, before any command that runs the
toolchain; `m0 doctor` runs all of them. Both read `CHECKS`, in its order,
which is the host's `host_checks` rule for the host's reason: a doctor that
keeps a list of its own reports "fine" where the build refuses, and that is
worse than no doctor. Add a refusal HERE, never beside a command.

Every failure is exit 78 and one line, `m0: detail (fix)`. Nothing here
warns and runs.

Each check is split in two: a verdict that is a pure function of facts, and
the gathering of those facts from this machine. The verdicts are what
packaging/m0/tests/test_m0.py drives, the platform one in particular --
no CI leg runs on a machine it refuses.
"""

import importlib.metadata
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from m0 import paths

REFUSED = 78


class Result:
    def __init__(self, name, ok, detail, fix=""):
        self.name = name
        self.ok = ok
        self.detail = detail
        self.fix = fix
        self.exit = 0 if ok else REFUSED

    def sentence(self):
        return f"m0: {self.detail} ({self.fix})"

    def as_json(self):
        out = {"name": self.name, "ok": self.ok, "detail": self.detail}
        if not self.ok:
            out["fix"] = self.fix
            out["exit"] = self.exit
        return out


def m0_version():
    try:
        return importlib.metadata.version("m0")
    except importlib.metadata.PackageNotFoundError:
        from m0 import __version__

        return __version__


def installed_mojo():
    """The `mojo` distribution in m0's OWN environment, or None."""
    try:
        return importlib.metadata.version("mojo")
    except importlib.metadata.PackageNotFoundError:
        return None


def _pin_fix(gated):
    return f"uv add --dev 'mojo=={gated[0]}'"


# --- platform ---------------------------------------------------------------

SUPPORTED = "macOS arm64, and glibc Linux on x86-64 or aarch64"


def platform_verdict(system, machine, libc):
    if system == "darwin" and machine == "arm64":
        return Result("platform", True, "macos arm64")
    if system == "linux" and machine in ("x86_64", "aarch64") and libc == "glibc":
        return Result("platform", True, f"linux {machine} glibc")
    what = f"{system} {machine}" + (f" {libc}" if system == "linux" else "")
    return Result(
        "platform",
        False,
        f"Mojo has no toolchain for {what}; m0 builds on {SUPPORTED}",
        "there is no fix on this machine",
    )


def _libc():
    # confstr answers on glibc and raises (or is absent) on musl, which is
    # the distinction that matters; platform.libc_ver() guesses from the
    # interpreter's own binary and reports musl as ('', '').
    try:
        return "glibc" if os.confstr("CS_GNU_LIBC_VERSION") else "unknown"
    except (ValueError, OSError, AttributeError):
        return "not-glibc"


def check_platform(project):
    system = "darwin" if sys.platform == "darwin" else sys.platform
    machine = platform.machine()
    return platform_verdict(system, machine, _libc() if system == "linux" else "")


# --- mojo-installed ---------------------------------------------------------


def installed_verdict(prefix, project_venv_has_mojo, in_project_venv, installed,
                      binary_exists, gated):
    # The `uvx m0 build` mistake: the project has a toolchain of its own and
    # this m0 is running from somewhere else, so whatever it found (or did
    # not) is not the project's. Asked first, because the fix is different.
    if project_venv_has_mojo and not in_project_venv:
        return Result(
            "mojo-installed",
            False,
            f"this m0 runs from {prefix}, not this project's .venv",
            "uv run m0 <command>",
        )
    if installed is None or not binary_exists:
        return Result(
            "mojo-installed",
            False,
            "mojo is not installed in this environment",
            _pin_fix(gated),
        )
    return Result("mojo-installed", True, str(paths.mojo_bin()))


def check_mojo_installed(project):
    venv = project / ".venv"
    try:
        inside = venv.resolve() == paths.prefix().resolve()
    except OSError:
        inside = False
    return installed_verdict(
        paths.prefix(),
        (venv / "bin" / "mojo").exists(),
        inside,
        installed_mojo(),
        paths.mojo_bin().exists(),
        paths.build_info()["gated_mojo"],
    )


# --- mojo-gated -------------------------------------------------------------


def gated_verdict(m0, installed, gated):
    if installed is None:
        # Only the doctor gets here (preflight stopped a check earlier), and
        # it must not print the check above a second time under this name.
        return Result(
            "mojo-gated",
            False,
            f"no mojo to compare with the gated {gated[0]}",
            _pin_fix(gated),
        )
    # String equality against a list that is a singleton by rule: a second
    # entry needs a second CI leg, not a looser comparison (D39).
    if installed not in gated:
        return Result(
            "mojo-gated",
            False,
            f"m0 {m0} is gated on mojo {gated[0]} and this environment "
            f"has mojo {installed}",
            _pin_fix(gated),
        )
    return Result("mojo-gated", True, f"mojo {installed}")


def check_mojo_gated(project):
    return gated_verdict(
        m0_version(), installed_mojo(), paths.build_info()["gated_mojo"]
    )


# --- c-compiler -------------------------------------------------------------
#
# Two measured facts shape this (mojo 1.1.0). `mojo build` looks for the
# literal name `cc` and nothing else: with gcc installed and cc removed it
# still reports "unable to find suitable c compiler", and neither a clang on
# PATH nor CC= helps -- so accepting gcc or clang here would pass a machine
# mojo refuses. And a cc that exists but cannot link (gcc without libc6-dev)
# passes any PATH check and then dies AFTER the full compile with
# `ld: cannot find crti.o` -- so the check links a one-line program.

LINK_PROBE = "int main(void) { return 0; }\n"
XCODE_SELECT = "/usr/bin/xcode-select"


def _linux_fix():
    if shutil.which("apt-get"):
        return "apt-get install build-essential"
    if shutil.which("dnf"):
        return "dnf install gcc glibc-devel"
    return "install a C toolchain: apt-get install build-essential, or dnf install gcc glibc-devel"


def compiler_verdict(system, clt_ok, cc, other, link_error, linux_fix):
    if system == "darwin" and not clt_ok:
        return Result(
            "c-compiler",
            False,
            "mojo links with cc and the Xcode command line tools are not installed",
            "xcode-select --install",
        )
    if cc is None:
        if other:
            return Result(
                "c-compiler",
                False,
                f"mojo links with a compiler named cc and finds no other name; "
                f"{other} is installed and cc is not on PATH",
                f'ln -s "$(command -v {other})" /usr/local/bin/cc',
            )
        return Result(
            "c-compiler",
            False,
            "mojo links with cc and there is no cc on PATH",
            "add /usr/bin to PATH" if system == "darwin" else linux_fix,
        )
    if link_error:
        return Result(
            "c-compiler",
            False,
            f"{cc} cannot link a C program: {link_error}",
            "xcode-select --install" if system == "darwin" else linux_fix,
        )
    return Result("c-compiler", True, cc)


def _link_error(cc):
    """None if `cc` links a one-line program with -lm, else its last words."""
    with tempfile.TemporaryDirectory(prefix="m0-cc-") as tmp:
        src = Path(tmp) / "probe.c"
        src.write_text(LINK_PROBE)
        try:
            done = subprocess.run(
                [cc, str(src), "-o", str(Path(tmp) / "probe"), "-lm"],
                capture_output=True,
                text=True,
                timeout=60,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return str(exc)
        if done.returncode == 0:
            return None
        lines = [l for l in done.stderr.strip().splitlines() if l.strip()]
        return lines[-1].strip() if lines else f"exit {done.returncode}"


def check_c_compiler(project):
    system = "darwin" if sys.platform == "darwin" else "linux"
    clt_ok = True
    if system == "darwin":
        # Asked first and by absolute path: /usr/bin/cc is a shim that opens
        # an install dialog when the tools are absent.
        try:
            clt_ok = (
                subprocess.run(
                    [XCODE_SELECT, "-p"], capture_output=True, timeout=30
                ).returncode
                == 0
            )
        except (OSError, subprocess.TimeoutExpired):
            clt_ok = False
        if not clt_ok:
            return compiler_verdict(system, False, None, None, None, "")
    cc = shutil.which("cc")
    other = None
    if cc is None:
        other = next((n for n in ("gcc", "clang") if shutil.which(n)), None)
    return compiler_verdict(
        system, clt_ok, cc, other, _link_error(cc) if cc else None, _linux_fix()
    )


# --- project ----------------------------------------------------------------


def check_project(project):
    if (project / paths.ENTRY).is_file():
        return Result("project", True, str(paths.ENTRY))
    return Result(
        "project",
        False,
        f"there is no {paths.ENTRY} in {project}",
        "run m0 from the application's root",
    )


# --- the list ---------------------------------------------------------------

CHECKS = [
    ("platform", check_platform),
    ("mojo-installed", check_mojo_installed),
    ("mojo-gated", check_mojo_gated),
    ("c-compiler", check_c_compiler),
    ("project", check_project),
]


def run_all(project):
    return [check(project) for _, check in CHECKS]


def preflight(project, skip=()):
    """The first failing check, or None. `skip` names checks a command does
    not need -- `m0 test` links nothing, so it skips `c-compiler`."""
    for name, check in CHECKS:
        if name in skip:
            continue
        result = check(project)
        if not result.ok:
            return result
    return None


def refuse(result):
    print(result.sentence(), file=sys.stderr)
    return result.exit
