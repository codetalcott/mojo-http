#!/usr/bin/env python3
"""Break each rule the scaffold keeps, and insist its smoke fails.

Three smokes, one runner: `smoke-scaffold` (what `m0 new` writes, on the
wire), `smoke-scaffold-dev` (`m0 dev`'s build-then-swap) and
`smoke-scaffold-image` (`m0 image`, and the image). A rule names the one
that holds it.

`m0_wheel_sabotage.py`'s shape, from the TEMPLATE side: each entry replaces
one EXACT block in a template, in `new.py` or in the layer, rebuilds the
wheel from the edited source, runs the smoke for the one template the rule
belongs to, and restores the file. CAUGHT means the smoke failed AND said
the expected thing. MISSED and NOT APPLICABLE (an anchor that no longer
matches) both exit 1; re-point the anchor with the line.

Rules the WIRE holds run with `M0_SCAFFOLD_SKIP_TEST=1`. A template's own
`m0 test` comes first in the smoke and catches several of these by itself
-- which is the template doing its job, and not an answer to "does the wire
assertion fail when the behaviour is broken?" Rules marked TEST are the
other way round: the template's test is what must catch them.

(`check-templates` has rules of its own -- a template that does not compile
unsubstituted, a file in no manifest, a misspelled token. They run FIRST
here, against `scripts/check_templates.py` rather than the smoke, since
that gate fails before the smoke would and says so better.)

Not here, and why:

- `DatastarStream(capacity)` below the connection count, and `send_latest`:
  neither shows inside one connection and five seconds.
- `uv sync --frozen` in the Dockerfile. Dropping it changes nothing a gate
  can read: a lock that satisfies `--frozen` satisfies a plain sync too.
  What is held instead is that the Dockerfile is built AS WRITTEN (its hash
  before and after) against a lock `--frozen` accepts.
- `m0 dev` starting the new server before the old one is GONE. The old
  server drains in milliseconds with no connection open, so the overlap
  cannot be seen from outside; `dev.stop` returning only after the pid has
  exited is `test_m0.py`'s (`test_stop_waits_for_the_pid_to_be_gone`). What
  the wire holds is the rule's two neighbours: the old server is never
  stopped at all, and it is killed rather than drained.
- `m0 dev` watching `pyproject.toml`: `test_m0.py`'s snapshot test. On the
  wire it would be a fourth build for a line of `dev.py`.

    uv run poe sabotage-scaffold
    uv run poe sabotage-scaffold --only 422       one rule, by label substring
    uv run poe sabotage-scaffold --only dev:      one smoke's rules (dev:, image:)
"""

import datetime
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
M0 = "packaging/m0/src/m0/"
T = M0 + "templates/"
WIRE, TEST, NEW, DEV, IMAGE = "wire", "test", "new", "dev", "image"
PORT = "8971"
DEV_SMOKE = "scripts/m0_scaffold_dev_smoke.py"
IMAGE_SMOKE = "scripts/m0_scaffold_image_smoke.py"

# holder -> (the smoke's argv after `python3`, the prefix of its failure line)
SMOKES = {
    DEV: ([DEV_SMOKE, "dist/m0", "8972"], "smoke-scaffold-dev:"),
    IMAGE: ([IMAGE_SMOKE, "dist/m0", "18371"], "smoke-scaffold-image:"),
}

# (label, template, file, old, new, the smoke must say, what holds it)
RULES = [
    # --- m0 new ---------------------------------------------------------------
    ("new: any name is accepted", "views", M0 + "new.py",
     "    if not NAME.match(app) or len(app) > NAME_MAX:\n",
     "    if False:\n",
     "m0 new Not_A_Name exited 0, not 2", NEW),
    ("new: writes over what is there", "views", M0 + "new.py",
     "    if target.exists() and (not target.is_dir() or any(target.iterdir())):\n",
     "    if False:\n",
     "m0 new onto its own output exited 0, not 2", NEW),
    ("new: needs the toolchain", "views", M0 + "new.py",
     "    root = paths.PACKAGE / \"templates\"\n",
     "    if checks.installed_mojo() is None:\n        return 78\n"
     "    root = paths.PACKAGE / \"templates\"\n",
     "uvx --offline m0 new exited 78", NEW),
    ("new: a manifest file is not written", "views", M0 + "new.py",
     '        "src/views.mojo",\n        "test/test_views.mojo",\n',
     '        "src/views.mojo",\n',
     "and the manifest is", NEW),
    ("new: a token is left in place", "views", M0 + "new.py",
     '        text.replace("__M0_APP__", app)\n',
     '        text.replace("__M0_APP__X", app)\n',
     "still holds a template token", NEW),
    ("new: smoke.sh is not executable", "views", M0 + "new.py",
     "            out.chmod(0o755)\n",
     "            pass\n",
     "smoke.sh is not executable", NEW),
    ("new: mojo is not pinned exactly", "views", T + "_common/pyproject.toml",
     '    "mojo==__MOJO_VERSION__",\n',
     '    "mojo>=__MOJO_VERSION__",\n',
     "the scaffold's pyproject.toml lacks \"mojo==", NEW),
    ("new: m0 is not pinned exactly", "views", T + "_common/pyproject.toml",
     '    "m0==__M0_VERSION__",\n',
     '    "m0>=__M0_VERSION__",\n',
     "the scaffold's pyproject.toml lacks \"m0==", NEW),
    ("new: the next commands are not printed", "views", M0 + "new.py",
     '    print("    uv sync")\n',
     "",
     "did not print the next command 'uv sync'", NEW),
    # N34. Only the WRITTEN project can show this: check-templates compiles
    # the file unsubstituted, where `__M0_APP__` passes the summary lint.
    ("new: the app's name opens the entry file's docstring bare [views]", "views",
     T + "views/src/server.mojo",
     '"""`__M0_APP__` — a server-rendered list',
     '"""__M0_APP__ — a server-rendered list',
     "the first build of a fresh views scaffold warns", NEW),
    ("new: the app's name opens the entry file's docstring bare [live]", "live",
     T + "live/src/server.mojo",
     '"""`__M0_APP__` — one shared state',
     '"""__M0_APP__ — one shared state',
     "the first build of a fresh live scaffold warns", NEW),

    # --- views, on the wire ---------------------------------------------------
    ("views: a bad form is a 200", "views", T + "views/src/views.mojo",
     '            Site("__M0_APP__"),\n            status=422,\n',
     '            Site("__M0_APP__"),\n',
     "an empty title answered 200 OK", WIRE),
    ("views: a bad form is problem+json", "views", T + "views/src/views.mojo",
     "        return page_or_fragment(\n            req,\n"
     '            render_list(items.ids, items.titles, String("a title is required")),\n'
     '            Site("__M0_APP__"),\n            status=422,\n        )\n',
     '        return reply.problem(422, "Unprocessable Content", "a title is required", ITEMS)\n',
     "the 422 is application/problem+json", WIRE),
    ("views: the error carries no alert role", "views", T + "views/src/pages.mojo",
     '        f.raw(el("p", attr("role", "alert"), text(error)))\n',
     '        f.raw(el("p", "", text(error)))\n',
     "is not the fragment holding an alert", WIRE),
    ("layer: a status alone says OK", "views", "packages/m0-http/src/fragment.mojo",
     "        resp.status_text = reason_phrase(status)\n",
     '        resp.status_text = "OK"\n',
     "an empty title answered 422 OK", WIRE),
    ("views: htmx floats", "views", T + "views/src/pages.mojo",
     "htmx.org@4.0.0/dist", "htmx.org@latest/dist",
     "does not carry the pinned htmx 4 tag", WIRE),
    ("views: a title is rendered raw", "views", T + "views/src/pages.mojo",
     '            f.el("a", "get", url, attr("href", url), text(titles[i])),\n',
     '            f.el("a", "get", url, attr("href", url), titles[i]),\n',
     "create did not answer the list with the item escaped", WIRE),
    ("views: delete removes nothing", "views", T + "views/src/views.mojo",
     "    items.remove(i)\n",
     "    _ = i\n",
     "DELETE /items/1", WIRE),
    ("views: a missing item is a 200", "views", T + "views/src/views.mojo",
     '    if i < 0:\n        return page_or_fragment(\n'
     '            req, render_missing(), Site("not found"), status=404\n        )\n'
     "    return page_or_fragment(\n        req, render_item(",
     '    if i < 0:\n        return page_or_fragment(\n'
     '            req, render_missing(), Site("not found")\n        )\n'
     "    return page_or_fragment(\n        req, render_item(",
     "a missing item is not a 404 fragment", WIRE),
    ("views: the template's own test is what goes red", "views", T + "views/src/views.mojo",
     "    items.remove(i)\n",
     "    _ = i\n",
     "uv run m0 test exited 1, not 0", TEST),
    ("views: smoke.sh's status is read", "views", T + "views/smoke.sh",
     '[ "$code" = 422 ] ||', '[ "$code" = 400 ] ||',
     "the scaffold's own smoke.sh exited 1, not 0", WIRE),

    # --- live, on the wire ----------------------------------------------------
    ("live: the state never steps", "live", T + "live/src/server.mojo",
     "        self.wave.advance(kicks - self.kicks_seen)\n",
     "",
     "differing patch-elements frame(s)", WIRE),
    ("live: the frame patches another id", "live", T + "live/src/pages.mojo",
     "        elements=render_live(step, heights, viewers),\n",
     '        elements=render_live(step, heights, viewers).replace(\'id="live"\', \'id="other"\'),\n',
     "differing patch-elements frame(s)", WIRE),
    ("live: a kick is not counted", "live", T + "live/src/views.mojo",
     "    st.board.add(B_KICKS, 1)\n",
     "",
     "after one kick /stats says", WIRE),
    ("live: Datastar floats", "live", T + "live/src/pages.mojo",
     "datastar@v1.0.3/bundles", "datastar@main/bundles",
     "lacks the fragment or the pinned Datastar tag", WIRE),
    ("live: the document paints no fragment", "live", T + "live/src/pages.mojo",
     "        render_live(0, still, 0),\n",
     # `still` stays USED: dropping its one use makes the build warn, and
     # N34's no-warning check then fails first -- MISSED (failed elsewhere).
     '        String("<!-- ", len(still), " -->"),\n',
     "lacks the fragment or the pinned Datastar tag", WIRE),

    # --- m0 dev (smoke-scaffold-dev; the template slot is unused) -------------
    ("dev: the old server is stopped BEFORE the build", "-", M0 + "dev.py",
     '            say("change seen, building" + (\n',
     '            stop(server)\n            say("change seen, building" + (\n',
     "it was not serving while the build ran", DEV),
    ("dev: a failed build ends the old server", "-", M0 + "dev.py",
     "                continue\n            stop(server)\n",
     "                stop(server)\n                server = None\n"
     "                continue\n            stop(server)\n",
     "after a failed build the port answers", DEV),
    ("dev: a failed build ends m0 dev", "-", M0 + "dev.py",
     "                continue\n            stop(server)\n",
     "                return 1\n            stop(server)\n",
     "m0 dev exited 1", DEV),
    ("dev: the old server is never stopped", "-", M0 + "dev.py",
     "            stop(server)\n            server = start(project, args.host_args)\n",
     "            server = start(project, args.host_args)\n",
     "the swapped-in server exited on its own", DEV),
    ("dev: the old server is killed, not drained", "-", M0 + "dev.py",
     "    server.send_signal(signal.SIGTERM)\n    killed = False\n",
     "    server.kill()\n    killed = False\n",
     "does not say the old server", DEV),
    ("dev: Ctrl-C leaves the server running", "-", M0 + "dev.py",
     "    except (KeyboardInterrupt, _Stop):\n        stop(server)\n        return 0\n",
     "    except (KeyboardInterrupt, _Stop):\n        server = None\n        return 0\n",
     "after m0 dev exited, pid", DEV),
    ("dev: Ctrl-C is a failure", "-", M0 + "dev.py",
     "    except (KeyboardInterrupt, _Stop):\n        stop(server)\n        return 0\n",
     "    except (KeyboardInterrupt, _Stop):\n        stop(server)\n        return 130\n",
     "m0 dev exited 130 on SIGINT, not 0", DEV),
    ("dev: src/ is not watched", "-", M0 + "dev.py",
     'WATCHED_DIR = "src"\n', 'WATCHED_DIR = "source"\n',
     "the edited literal was never served", DEV),

    # --- m0 image (smoke-scaffold-image) --------------------------------------
    ("image: the whole toolchain is demanded", "-", M0 + "image.py",
     "    failed = checks.preflight(project, skip=others)\n",
     "    failed = checks.preflight(project)\n",
     "with no docker on PATH m0 image exited 78", IMAGE),
    # The exit docker RETURNED, apart from docker being absent (an OSError,
    # which has an arm of its own and comes first in the smoke).
    ("image: docker's failure is exit 0", "-", M0 + "image.py",
     "        return subprocess.run(argv, cwd=project).returncode\n",
     "        subprocess.run(argv, cwd=project)\n        return 0\n",
     "m0 image with a flag docker refuses exited 0, not 1", IMAGE),
    ("image: docker missing is a traceback", "-", M0 + "image.py",
     "    except OSError as exc:\n", "    except ZeroDivisionError as exc:\n",
     "with no docker on PATH m0 image exited 1 saying", IMAGE),
    ("image: --tag is ignored", "-", M0 + "image.py",
     "    tag = args.tag or project.name\n", "    tag = project.name\n",
     "`docker run -d --name", IMAGE),
    ("image: about.json is not printed", "-", M0 + "image.py",
     "    return 1 if _docker(about_argv(tag), project) != 0 else 0\n", "    return 0\n",
     "the last stdout line is not about.json", IMAGE),
    ("image: --target-cpu never reaches the builder", "-", M0 + "image.py",
     "    if target_cpu:\n", "    if False:\n",
     "did not reach the builder's m0 build", IMAGE),
    ("image: the release build is not for the baseline", "-", M0 + "build.py",
     '    return "generic" if machine == "aarch64" else "x86-64-v2"\n',
     '    return "neoverse-n1" if machine == "aarch64" else "x86-64-v3"\n',
     "about.json is", IMAGE),
    ("image: an interpreter, and the Dockerfile's own measurement refuses it", "-",
     T + "_common/deploy/Dockerfile",
     "ARG BASE\nRUN useradd",
     "ARG BASE\nRUN ln -s /bin/true /usr/local/bin/python3\nRUN useradd",
     "an interpreter is in the image", IMAGE),
    ("image: an interpreter added AFTER the image measured itself", "-",
     T + "_common/deploy/Dockerfile",
     "\nUSER app\n",
     "\nRUN ln -s /bin/true /usr/local/bin/python3\nUSER app\n",
     'about.json says "python":false and the image holds', IMAGE),
    ("image: the server is not PID 1", "-", T + "_common/deploy/Dockerfile",
     'ENTRYPOINT ["/app/server"]', 'ENTRYPOINT ["/bin/sh", "-c", "/app/server; exit $?"]',
     "PID 1 is", IMAGE),
    ("image: the builder holds another m0 than the wheel under test", "-", IMAGE_SMOKE,
     '    shutil.copytree(project / ".wheels", basedir / ".wheels")\n',
     '    shutil.copytree(project / ".wheels", basedir / ".wheels")\n'
     '    _stale = next((basedir / ".wheels").glob("*.whl"))\n'
     '    with zipfile.ZipFile(_stale) as _z:\n'
     '        _all = {n: _z.read(n) for n in _z.namelist()}\n'
     '    _all["m0/include.py"] += b"\\n# a stale layer\\n"\n'
     '    with zipfile.ZipFile(_stale, "w") as _z:\n'
     '        for _n, _b in _all.items():\n'
     '            _z.writestr(_n, _b)\n',
     "is not the wheel's", IMAGE),
]

# Held by check-templates, not by the smoke: (label, file, old, new, it must say).
# An `old` of None PLANTS the file instead.
TEMPLATE_RULES = [
    ("check-templates: a file in no manifest", T + "views/src/extra.mojo",
     None, "def f():\n    pass\n", "is in no manifest"),
    ("check-templates: a misspelled token", T + "_common/README.md",
     "# __M0_APP__\n", "# __M0_NAME__\n", "which m0 new does not replace"),
    ("check-templates: a version token outside pyproject", T + "_common/README.md",
     "# __M0_APP__\n", "# __M0_APP__\n\nm0 __M0_VERSION__\n", "only pyproject.toml may"),
    ("check-templates: the name outside a string literal", T + "views/src/server.mojo",
     "def main() raises:\n", "def main() raises:\n    __M0_APP__-main()\n",
     "build src/server.mojo failed"),
    ("check-templates: a template test that fails", T + "live/test/test_live.mojo",
     "    assert_equal(board.viewers(2), 5)\n", "    assert_equal(board.viewers(2), 6)\n",
     "run test_live.mojo failed"),
]


def prune_build_cache(since):
    """Drop the BuildKit records this run created, and only those.

    Every image rule is a cold build -- the wheel changes, so the base image
    does, so every layer after `FROM` does -- and leaves about 1.2 GB of
    build cache behind. Ten rules once filled the disk under a colima VM,
    whose journal aborted; `docker rmi` does not touch the cache, and
    `docker builder prune`'s time filter selects OLD records, the opposite of
    what is wanted. So records are picked by their creation time and pruned
    by id. (On colima the host gets the space back only after
    `colima ssh -- sudo fstrim -av`.)
    """
    # In passes: a record with a child is not reclaimable until the child is
    # gone, so one pass takes the leaves and leaves the gigabytes.
    pruned = 0
    for _ in range(12):
        out = subprocess.run(["docker", "buildx", "du", "--verbose"],
                             capture_output=True, text=True).stdout
        ids = []
        for block in out.split("\n\n"):
            rid = re.search(r"^ID:\s+(\S+)", block, re.M)
            made = re.search(r"^Created at:\s+(\S+ \S+)", block, re.M)
            if rid and made and re.search(r"^Reclaimable:\s+true", block, re.M) \
                    and made.group(1)[:19] >= since:
                ids.append(rid.group(1))
        if not ids:
            break
        for rid in ids:
            subprocess.run(["docker", "builder", "prune", "-f", "--filter", "id=" + rid],
                           capture_output=True)
        pruned += len(ids)
    return pruned


def run_template_rules(only):
    verdicts = []
    for label, rel, old, new, want in TEMPLATE_RULES:
        if only is not None and only not in label:
            continue
        path = ROOT / rel
        original = None if old is None else path.read_text()
        if old is None and path.exists():
            sys.exit("%s exists; it is this rule's to plant" % rel)
        if old is not None and original.count(old) != 1:
            print("NOT APPLICABLE  %s: the anchor matches %d times in %s"
                  % (label, original.count(old), rel), flush=True)
            verdicts.append(("NOT APPLICABLE", label))
            continue
        try:
            path.write_text(new if old is None else original.replace(old, new))
            done = subprocess.run(["uv", "run", "python3", "scripts/check_templates.py"],
                                  cwd=ROOT, capture_output=True, text=True)
        finally:
            if old is None:
                path.unlink(missing_ok=True)
            else:
                path.write_text(original)
        said = done.stdout + done.stderr
        verdict = ("MISSED" if done.returncode == 0
                   else "caught" if want in said else "MISSED (failed elsewhere)")
        print("%-26s %s" % (verdict, label), flush=True)
        verdicts.append((verdict, label))
    return verdicts


def main():
    only = None
    if "--only" in sys.argv:
        only = sys.argv[sys.argv.index("--only") + 1]
    rules = [r for r in RULES if only is None or only in r[0]]
    verdicts = run_template_rules(only)
    if not rules and not verdicts:
        sys.exit("no rule matches --only %r" % only)

    started = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    for label, template, rel, old, new, want, holder in rules:
        path = ROOT / rel
        original = path.read_text()
        if original.count(old) != 1:
            print("NOT APPLICABLE  %s: the anchor matches %d times in %s"
                  % (label, original.count(old), rel), flush=True)
            verdicts.append(("NOT APPLICABLE", label))
            continue
        env = dict(os.environ)
        env.pop("M0_SCAFFOLD_SKIP_TEST", None)
        if holder == WIRE:
            env["M0_SCAFFOLD_SKIP_TEST"] = "1"
        try:
            path.write_text(original.replace(old, new))
            built = subprocess.run(["uv", "run", "poe", "build-m0-wheel"], cwd=ROOT,
                                   capture_output=True, text=True)
            if built.returncode != 0:
                sys.exit("the wheel would not build under %r:\n%s" % (label, built.stderr[-2000:]))
            argv, prefix = SMOKES.get(
                holder, (["scripts/m0_scaffold_smoke.py", "dist/m0", PORT, template],
                         "smoke-scaffold:"))
            done = subprocess.run(["uv", "run", "python3", *argv],
                                  cwd=ROOT, env=env, capture_output=True, text=True)
        finally:
            path.write_text(original)
        said = done.stdout + done.stderr
        if done.returncode == 0:
            verdict = "MISSED"
        elif want not in said:
            verdict = "MISSED (failed elsewhere)"
        else:
            verdict = "caught"
        line = [l for l in said.splitlines() if l.startswith(prefix)]
        shown = line[-1][:200] if line else (
            "(the smoke passed)" if done.returncode == 0
            else "(exit %d with no line of the smoke's own)" % done.returncode)
        print("%-26s %s\n    %s" % (verdict, label, shown), flush=True)
        if verdict != "caught":
            # What it said instead, so a miss can be read without a rerun.
            print("    ... " + "\n    ... ".join(said.strip().splitlines()[-12:]), flush=True)
        verdicts.append((verdict, label))
        if holder == IMAGE:
            print("    (pruned %d build-cache records of this run's)" % prune_build_cache(started),
                  flush=True)

    subprocess.run(["uv", "run", "poe", "build-m0-wheel"], cwd=ROOT, capture_output=True)
    bad = [v for v in verdicts if v[0] != "caught"]
    print("\n%d rules, %d caught, %d not" % (len(verdicts), len(verdicts) - len(bad), len(bad)))
    for verdict, label in bad:
        print("  %s: %s" % (verdict, label))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
