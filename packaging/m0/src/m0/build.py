"""`m0 build [--release] [--target-cpu CPU]`.

Two rules here are load-bearing:

- **A build is written beside its destination and RENAMED into place**,
  never `-o` onto `bin/server`: that binary may be running. Writing over a
  running executable is ETXTBSY on Linux and a killed process on macOS; a
  rename replaces the directory entry and leaves the running inode alone.
  A build that fails leaves the old binary exactly where it was.
- **`--release` never compiles for the machine that builds.** `mojo build`
  defaults `--target-cpu` to the host, so the artifact works where it was
  made and dies with SIGILL anywhere older. The baseline table is
  `build-serve`'s, and `native` with `--release` is refused at the command
  line (exit 2).

`--release` is the image's recipe, from the wheel: compile for the baseline,
strip the build venv out of the binary's search path (`relocate.py`), and
copy the Mojo runtime beside it (`bundle_artifact.py`), so `dist/` is what a
runtime stage copies and nothing else. The two tools ride in the wheel
unedited and run as subprocesses; `bundle_artifact.py` finds the runtime
under `./.venv`, which is where `uv run m0 build` has it.
"""

import os
import platform
import shutil
import subprocess
import sys

from m0 import checks, paths


def baseline_cpu(system=None, machine=None):
    """The oldest CPU each platform must support -- build-serve's table."""
    system = system or ("darwin" if sys.platform == "darwin" else "linux")
    machine = machine or platform.machine()
    if system == "darwin":
        return "apple-m1" if machine == "arm64" else "x86-64-v2"
    return "generic" if machine == "aarch64" else "x86-64-v2"


def _mojo_build(project, out, target_cpu, extra_env=None):
    cmd = [str(paths.mojo_bin()), "build"]
    if target_cpu:
        cmd += ["--target-cpu", target_cpu]
    cmd += ["-I", str(paths.include_root()), str(paths.ENTRY), "-o", str(out)]
    env = paths.toolchain_env(extra_env)
    return subprocess.run(cmd, cwd=project, env=env).returncode


def _tool(project, name, *args):
    script = paths.tools_dir() / name
    return subprocess.run([sys.executable, str(script), *args], cwd=project).returncode


def run(args):
    project = args.project
    failed = checks.preflight(project)
    if failed is not None:
        return checks.refuse(failed)
    if args.release:
        return _release(project, args.target_cpu or baseline_cpu())

    nxt = project / paths.BINARY_NEXT
    nxt.parent.mkdir(exist_ok=True)
    if _mojo_build(project, paths.BINARY_NEXT, args.target_cpu) != 0:
        nxt.unlink(missing_ok=True)
        return 1
    os.replace(nxt, project / paths.BINARY)
    print(f"built {paths.BINARY}")
    return 0


def _release(project, target_cpu):
    final = project / paths.RELEASE_DIR
    stage = project / ".dist.next"
    shutil.rmtree(stage, ignore_errors=True)
    work = stage / ".build"
    work.mkdir(parents=True)
    env = {}
    if sys.platform == "darwin":
        # A Mojo binary otherwise inherits the BUILD HOST's SDK as its
        # deployment target; 13.0 is the floor the toolchain's own wheel is
        # tagged for, as build-serve sets it.
        env["MACOSX_DEPLOYMENT_TARGET"] = "13.0"
    try:
        artifact = work / "server"
        rel = artifact.relative_to(project)
        if _mojo_build(project, rel, target_cpu, env) != 0:
            return 1
        if _tool(project, "relocate.py", "--no-id", "--rpath", "@loader_path",
                 str(rel)) != 0:
            return 1
        if _tool(project, "bundle_artifact.py", "--layout", "flat", str(rel),
                 str(stage.relative_to(project))) != 0:
            return 1
        shutil.rmtree(work)
        shutil.rmtree(final, ignore_errors=True)
        os.replace(stage, final)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    print(f"built {paths.RELEASE_DIR}/ for {target_cpu}")
    return 0
