#!/usr/bin/env python3
"""Break each rule the scaffold keeps, and insist smoke-scaffold fails.

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
- The deploy files. Nothing here builds an image; `smoke-scaffold-image`
  is the next pull request's, and until it lands `deploy/` is ungated.

    uv run poe sabotage-scaffold
    uv run poe sabotage-scaffold --only 422       one rule, by label substring
"""

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
M0 = "packaging/m0/src/m0/"
T = M0 + "templates/"
WIRE, TEST, NEW = "wire", "test", "new"
PORT = "8971"

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
     '        "",\n',
     "lacks the fragment or the pinned Datastar tag", WIRE),
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
            done = subprocess.run(
                ["python3", "scripts/m0_scaffold_smoke.py", "dist/m0", PORT, template],
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
        line = [l for l in said.splitlines() if l.startswith("smoke-scaffold:")]
        print("%-26s %s\n    %s" % (verdict, label, line[-1][:200] if line else "(the smoke passed)"),
              flush=True)
        verdicts.append((verdict, label))

    subprocess.run(["uv", "run", "poe", "build-m0-wheel"], cwd=ROOT, capture_output=True)
    bad = [v for v in verdicts if v[0] != "caught"]
    print("\n%d rules, %d caught, %d not" % (len(verdicts), len(verdicts) - len(bad), len(bad)))
    for verdict, label in bad:
        print("  %s: %s" % (verdict, label))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
