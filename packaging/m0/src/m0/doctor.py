"""`m0 doctor [--json] [-- HOST_ARGS]`.

Every check in `checks.CHECKS` -- all of them, where a command stops at the
first -- and then the application's own doctor: if `bin/server` exists it is
run as `bin/server HOST_ARGS --doctor` with the environment untouched, so
`M0_WORKERS=4 uv run m0 doctor` asks the deploy's question of the binary
that would be deployed. The host prints its report as the LAST line of
stdout (an app's banner may come first), and its first key is a FORMAT
number, `"m0_host":"1"`: a different number is a binary some other m0 built,
and is refused by name rather than half-read.

Exit: the first failed check's code, else the application's own, else 0.
No build is not a failure -- a missing binary is not a misconfiguration --
and a stale one (any `src/**/*.mojo` newer than it) is reported, never
failed. A binary that cannot be run, or does not finish within
`APP_SECONDS`, is the tool m0 ran failing: exit 1, said in one line, and
every process it started ended. The host's doctor stops before the bind,
so the bound is for a binary that SERVES instead of answering -- one whose
`main` never reaches `serve`.

Last, the files `m0 new` wrote that are still the scaffold's -- the
deploy files, the ignore files, the workflow, AGENTS.md and CLAUDE.md, but
not the README or pyproject.toml, which are the application's from the
first edit -- are compared with what THIS m0 writes for the project's
name. A difference is reported, never failed: it is an application's own
edit as often as an older m0's file, and only the application can tell
which. It is how an upgrade learns what the scaffold it came from lacks
(0.3.0's Dockerfile installs the libsqlite3 that 0.2.0's did not), because
nothing rewrites a project's files (docs/DECISIONS.md D52).

`--json` prints one object as the last line of stdout, the host's own rule.
`"m0":"1"` is its format number; the release is `versions.m0`.
"""

import json
import os
import platform
import re
import signal
import subprocess

from m0 import checks, new, paths

FORMAT = "1"
HOST_FORMAT = "1"
APP_SECONDS = 30

# What `m0 new` writes that stays the scaffold's; the README and the
# pyproject are the application's from its first edit.
SCAFFOLD_FILES = tuple(n for n in new.COMMON if n not in ("README.md", "pyproject.toml"))


def _app_name(project):
    """The name `m0 new` substituted: `[project].name`, else the directory's."""
    try:
        text = (project / "pyproject.toml").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        text = ""
    found = re.search(r'(?m)^name\s*=\s*"([^"]+)"', text)
    return found.group(1) if found else project.resolve().name


def scaffold_drift(project):
    """`(present, differ)`: the scaffold's files this project has, and those
    of them that are not what this m0 writes for its name, as the project
    spells their paths. A file that is absent is the application's choice
    and is neither."""
    root = paths.PACKAGE / "templates" / "_common"
    info = paths.build_info()
    app = _app_name(project)
    present, differ = [], []
    for name in SCAFFOLD_FILES:
        target = new.target_path(name)
        try:
            have = (project / target).read_text(encoding="utf-8")
        except UnicodeDecodeError:
            have = None
        except OSError:
            continue
        try:
            template = (root / name).read_text(encoding="utf-8")
        except OSError:
            continue  # a broken install; `m0 new` names that, not the doctor
        want = new.render(
            template, app, checks.m0_version(), info["gated_mojo"][0], info["gated_max"][0]
        )
        present.append(str(target))
        if have != want:
            differ.append(str(target))
    return present, differ


def _stale(project, binary):
    """Whether a source is newer than `binary`. A hidden file or directory
    is skipped, as `m0 dev`'s poll skips it: an editor's lock file
    (`.#views.mojo`) is a symlink to nothing, and not a source."""
    built = binary.stat().st_mtime
    src = project / "src"
    for path in src.rglob("*.mojo"):
        if any(part.startswith(".") for part in path.relative_to(src).parts):
            continue
        try:
            if path.stat().st_mtime > built:
                return True
        except OSError:
            continue
    return False


def _failed(detail, fix):
    """The application's binary could not answer: the tool m0 ran failed,
    which is exit 1 where a refusal is 78."""
    result = checks.Result("app", False, detail, fix)
    result.exit = 1
    return result


def _run_doctor(argv, cwd, seconds):
    """`argv` to completion: `(exit, stdout, stderr)`. In a session of its
    own, so a binary still running at `seconds` -- or when this process is
    interrupted -- is ended with every process it forked, then waited for
    and its pipes closed; `TimeoutExpired` is raised after that."""
    with subprocess.Popen(
        argv,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        errors="replace",
        start_new_session=True,
    ) as child:
        try:
            out, err = child.communicate(timeout=seconds)
        except BaseException:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except OSError:
                pass
            raise
    return child.returncode, out, err


def host_report(stdout):
    """The host's report out of a doctor run's stdout: `(report, error)`.

    `(None, None)` is an application whose own `main` refused before `serve`
    and so printed no JSON -- recorded by the caller, not an error of ours.
    """
    lines = [l for l in stdout.splitlines() if l.strip()]
    if not lines or not lines[-1].lstrip().startswith("{"):
        return None, None
    try:
        report = json.loads(lines[-1])
    except ValueError:
        return None, None
    if not isinstance(report, dict) or not report:
        return None, None
    first = next(iter(report))
    if first != "m0_host":
        return None, None
    if report["m0_host"] != HOST_FORMAT:
        return None, checks.Result(
            "app",
            False,
            f"{paths.BINARY} prints doctor format {report['m0_host']} and "
            f"this m0 reads {HOST_FORMAT}",
            "m0 build",
        )
    return report, None


def _run_app(project, host_args):
    binary = project / paths.BINARY
    if not binary.is_file():
        return None, None
    try:
        code, stdout, stderr = _run_doctor(
            [str(binary), *host_args, "--doctor"], project, APP_SECONDS
        )
    except subprocess.TimeoutExpired:
        return None, _failed(
            f"{paths.BINARY} --doctor did not finish within {APP_SECONDS} s and was "
            "stopped",
            "a main that reaches m0_host's serve answers at once; m0 build",
        )
    except OSError as e:
        return None, _failed(
            f"{paths.BINARY} could not be run: {e.strerror or e}", "m0 build"
        )
    report, error = host_report(stdout)
    lines = stdout.splitlines()
    # What the run said besides the report: a banner, or an app's own
    # refusal, which is all there is when it printed no report.
    if report is not None or error is not None:
        lines = [l for l in lines if l.strip()][:-1]
    output = "\n".join(lines + stderr.splitlines())
    app = {
        "exit": code,
        "stale": _stale(project, binary),
        "report": report,
        "output": output,
    }
    return app, error


def exit_code(results, app, app_error):
    for result in results:
        if not result.ok:
            return result.exit
    if app_error is not None:
        return app_error.exit
    if app is not None:
        return app["exit"]
    return 0


def run(args):
    project = args.project
    results = checks.run_all(project)
    app, app_error = _run_app(project, args.host_args)
    code = exit_code(results, app, app_error)
    info = paths.build_info()
    present, differ = scaffold_drift(project)

    if args.json:
        listed = [r.as_json() for r in results]
        if app_error is not None:
            listed.append(app_error.as_json())
        doc = {
            "m0": FORMAT,
            "ok": code == 0,
            "exit": code,
            "versions": {
                "m0": checks.m0_version(),
                "gated_mojo": info["gated_mojo"],
                "mojo": checks.installed_mojo(),
                "gated_max": info["gated_max"],
                "max": checks.installed_max(),
                "framework": info["framework"],
                "commit": info["commit"],
                "python": platform.python_version(),
            },
            "paths": {
                "include": str(paths.include_root()),
                "mojo": str(paths.mojo_bin()),
                "project": str(project),
                "binary": str(paths.BINARY),
            },
            "checks": listed,
            "app": app,
            "scaffold": {"present": present, "differ": differ},
        }
        print(json.dumps(doc))
        return code

    for result in results:
        mark = "ok  " if result.ok else "FAIL"
        line = f"{mark} {result.name}: {result.detail}"
        if not result.ok:
            line += f" ({result.fix})"
        print(line)
    if app_error is not None:
        print(f"FAIL app: {app_error.detail} ({app_error.fix})")
    elif app is None:
        print(f"     app: no {paths.BINARY} yet (m0 build)")
    else:
        _print_app(app)
    m0 = checks.m0_version()
    if differ:
        verb = "differs" if len(differ) == 1 else "differ"
        print(
            f"     scaffold: {', '.join(differ)} {verb} from what m0 {m0} writes "
            f"(an edit, or an older m0's file; `uv run m0 new /tmp/{_app_name(project)}` "
            "writes this m0's to compare)"
        )
    elif present:
        print(f"ok   scaffold: the files m0 new wrote match m0 {m0}")
    return code


def _print_app(app):
    stale = " -- older than src/, m0 build" if app["stale"] else ""
    report = app["report"]
    if report is None:
        print(f"     app: {paths.BINARY} exited {app['exit']} and printed no report{stale}")
        if app["output"]:
            print(app["output"])
        return
    cfg, topo = report.get("config", {}), report.get("topology", {})
    mark = "ok  " if app["exit"] == 0 else "FAIL"
    print(
        f"{mark} app: {cfg.get('host')}:{cfg.get('port')}, {topo.get('mode')}, "
        f"{topo.get('loops')} loops, {topo.get('handler_threads')} handler "
        f"threads{stale}"
    )
    for check in report.get("checks", []):
        if not check.get("ok"):
            print(f"FAIL app {check['name']}: {check['detail']} ({check.get('fix', '')})")
