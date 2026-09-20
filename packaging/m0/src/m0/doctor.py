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
failed.

`--json` prints one object as the last line of stdout, the host's own rule.
`"m0":"1"` is its format number; the release is `versions.m0`.
"""

import json
import platform
import subprocess

from m0 import checks, paths

FORMAT = "1"
HOST_FORMAT = "1"


def _stale(project, binary):
    built = binary.stat().st_mtime
    return any(p.stat().st_mtime > built for p in (project / "src").rglob("*.mojo"))


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
    done = subprocess.run(
        [str(binary), *host_args, "--doctor"],
        cwd=project,
        capture_output=True,
        text=True,
    )
    report, error = host_report(done.stdout)
    lines = done.stdout.splitlines()
    # What the run said besides the report: a banner, or an app's own
    # refusal, which is all there is when it printed no report.
    if report is not None or error is not None:
        lines = [l for l in lines if l.strip()][:-1]
    output = "\n".join(lines + done.stderr.splitlines())
    app = {
        "exit": done.returncode,
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
