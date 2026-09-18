#!/usr/bin/env python3
"""An application defines a frontend vocabulary of its own (DECISIONS D7, SPEC N21).

`Fragment[V: Vocabulary]` shipped with two conformances, both inside
`html.mojo`, because on Mojo 1.0 an app could not conform to a trait behind
a `.mojoc`. This builds the third one where an application would write it:
a source file in a directory OUTSIDE this repository, compiled against the
built `.mojoc`s and nothing else.

The vocabulary is **htmx 4**, which the layer itself does not speak (its
`Htmx` is gated against 2.0.4, D6). `Htmx4` differs from `Htmx` in exactly
two places, and both are asserted by exact string, because with `outerHTML`
the two spell identical attributes and a green gate would prove only that a
conformance compiles:

    hx-swap="outerMorph"   htmx 4's built-in morph-by-id, which is what
                           Datastar does with the same fragment
    hx-query               htmx 4's sixth verb, allowed through `verbs()`

What is checked, in order:

1. the app's source has no underscore-led name in it -- the surface an
   application may rely on is the one spelled without one;
2. it compiles and runs from outside the repository root;
3. both tiers (`Fragment.swap`, `Fragment.el`) and `Html.swap[V]` emit the
   attributes above, and the five-verb `Htmx` still refuses `query`;
4. a typo is refused by the LAYER, `Htmx4.swap` having checked nothing;
5. the rendered document is read by `hxlint`, vendored from hx-flask and
   generated from htmx 4's own source tree: a second implementation, so the
   vocabulary is not checked against itself. The linter is null-cased here
   -- a page with a broken target and one with a miscased swap style must
   each be REPORTED, or its silence on the real page says nothing.

**What `Htmx4` does not prove.** htmx picks its own event, so `Htmx4.swap`
never asks which element it is on. `KindEcho` below is synthetic and exists
only to read `Html.open_kind()` from outside the package, in both tiers,
for all four answers; `Datastar`, inside the package, is the real consumer
of that surface and is written against the same accessor.
"""

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import hxlint  # noqa: E402

_SIBLING = Path(sys.executable).with_name("mojo")
MOJO = str(_SIBLING) if _SIBLING.exists() else (shutil.which("mojo") or "mojo")

APP = '''
from m0_http import ElementKind, Fragment, Html, Htmx, Vocabulary, attr, text


struct Htmx4(Vocabulary):
    """The htmx 4 spelling: six verbs, and the morph swap that matches by id."""

    @staticmethod
    def swap(mut h: Html, verb: String, url: String, target: String) raises:
        h.attr(String("hx-", verb), url)
        h.attr("hx-target", target)
        h.attr("hx-swap", "outerMorph")

    @staticmethod
    def verbs() -> String:
        return "get post put patch delete query"


struct KindEcho(Vocabulary):
    """Synthetic: says which element it was opened on."""

    @staticmethod
    def swap(mut h: Html, verb: String, url: String, target: String) raises:
        var kind: ElementKind = h.open_kind()
        var name = "other"
        if kind.is_form():
            name = "form"
        elif kind.is_field():
            name = "field"
        elif kind.is_link():
            name = "link"
        h.attr("data-kind", name)


def refused[V: Vocabulary](verb: String) raises -> String:
    var f = Fragment[V]("probe")
    var said = String("ALLOWED")
    try:
        f.open("a")
        f.swap(verb, "/x")
    except e:
        said = String(e)
    return said


def main() raises:
    var f = Fragment[Htmx4]("notes")
    f.open("form")
    f.swap("post", "/notes")
    f.open("input")
    f.attr("name", "title")
    f.close("form")
    f.raw(f.el("button", "delete", "/notes/7", attr("class", "x"), text("<gone>")))
    f.raw(f.el("button", "query", "/notes", attr("class", "q"), text("find")))
    var selector = f.selector()
    var h = Html()
    h.raw("<!doctype html><html><head><title>t</title></head><body>")
    h.open("a")
    h.attr("href", "/notes")
    h.swap[Htmx4]("get", "/notes", selector)
    h.text("reload")
    h.close("a")
    h.raw(f^.finish())
    h.raw("</body></html>")
    print("DOC", h^.finish())

    var k = Fragment[KindEcho]("kinds")
    k.open("form")
    k.swap("post", "/k")
    k.close("form")
    k.raw(k.el("select", "get", "/k", ""))
    k.raw(k.el("button", "get", "/k", ""))
    k.raw(k.el("div", "get", "/k", ""))
    print("KINDS", k^.finish())

    print("TYPO", refused[Htmx4]("psot"))
    print("QUERY4", refused[Htmx4]("query"))
    print("QUERY2", refused[Htmx]("query"))
'''

DOC = (
    '<!doctype html><html><head><title>t</title></head><body>'
    '<a href="/notes" hx-get="/notes" hx-target="#notes" hx-swap="outerMorph">reload</a>'
    '<section id="notes">'
    '<form hx-post="/notes" hx-target="#notes" hx-swap="outerMorph"><input name="title"></form>'
    '<button class="x" hx-delete="/notes/7" hx-target="#notes" hx-swap="outerMorph">&lt;gone&gt;</button>'
    '<button class="q" hx-query="/notes" hx-target="#notes" hx-swap="outerMorph">find</button>'
    '</section></body></html>'
)

KINDS = (
    '<section id="kinds"><form data-kind="form"></form>'
    '<select data-kind="field"></select>'
    '<button data-kind="link"></button>'
    '<div data-kind="other"></div></section>'
)

# A name an application may not lean on: `h._open_kind`, `_check_verb`,
# `_KIND_FORM`. Dunder-free by construction -- the app defines no `__init__`.
_UNDERSCORE = re.compile(r"(?<![A-Za-z0-9_])_[A-Za-z_]|\._")


def fail(msg: str) -> int:
    print(f"app-vocabulary: {msg}")
    return 1


def findings(html: str) -> list[str]:
    return [str(f) for f in hxlint.lint_html(html, is_document=True)]


def main() -> int:
    hit = _UNDERSCORE.search(APP)
    if hit:
        return fail(f"the app's source reaches an underscore-led name at "
                    f"{APP[hit.start():hit.start() + 24]!r} -- the blessed surface "
                    "is the one spelled without one")

    with tempfile.TemporaryDirectory() as td:
        out = Path(td).resolve()
        if out == ROOT or ROOT in out.parents:
            return fail(f"the temporary directory {out} is inside the repository; "
                        "the gate's claim is an app OUTSIDE it")
        (out / "app.mojo").write_text(APP)
        build = subprocess.run(
            [MOJO, "build",
             "-I", str(ROOT / "packages/m0-core"), "-I", str(ROOT / "packages/m0-http"),
             "app.mojo", "-o", "app"],
            cwd=out, capture_output=True, text=True,
        )
        if build.returncode != 0:
            lines = [l for l in build.stderr.splitlines() if "error:" in l]
            return fail("an app-defined `Vocabulary` did not compile against m0_http.mojoc "
                        f"(stale .mojoc? run build-http): {lines[:3]}")
        if "warning:" in build.stderr:
            return fail("the app compiles with a warning, and the tree's floor is 0: "
                        + next(l for l in build.stderr.splitlines() if "warning:" in l))
        run = subprocess.run([str(out / "app")], cwd=out, capture_output=True, text=True)
        if run.returncode != 0:
            return fail(f"the app exited {run.returncode}: {run.stderr.strip()[:300]}")

    got = {}
    for line in run.stdout.splitlines():
        key, _, rest = line.partition(" ")
        got[key] = rest

    if got.get("DOC") != DOC:
        return fail(f"Fragment[Htmx4] rendered\n  {got.get('DOC')}\nnot\n  {DOC}")
    for needle in ('hx-swap="outerMorph"', 'hx-query="/notes"'):
        if needle not in got["DOC"]:
            return fail(f"{needle} is missing: that attribute is what differs from `Htmx`")
    if 'outerHTML' in got["DOC"]:
        return fail("`outerHTML` is in the output: that is `Htmx`'s spelling, not the app's")
    if got.get("KINDS") != KINDS:
        return fail(f"open_kind() read from an app answered\n  {got.get('KINDS')}\nnot\n  {KINDS}")
    typo = got.get("TYPO", "")
    if "must be one of get, post, put, patch, delete, query" not in typo:
        return fail(f"a typo was not refused by the layer with the app's own verb list: {typo!r}")
    if got.get("QUERY4") != "ALLOWED":
        return fail(f"`query` was refused for a vocabulary that names it: {got.get('QUERY4')!r}")
    if "must be one of get, post, put, patch, delete" not in got.get("QUERY2", ""):
        return fail(f"the five-verb `Htmx` allowed `query`: {got.get('QUERY2')!r}")

    # The outside reader. First prove it can say no.
    for label, broken, rule in (
        ("a target naming no id", DOC.replace('hx-target="#notes"', 'hx-target="#nots"'), "missing-target"),
        ("a miscased swap style", DOC.replace("outerMorph", "outermorph"), "swap-style-case"),
        ("a verb htmx 4 does not have", DOC.replace("hx-query=", "hx-qeury="), "unknown-attribute"),
    ):
        if broken == DOC:
            return fail(f"null case `{label}` changed nothing; re-point it")
        if not any(rule in f for f in findings(broken)):
            return fail(f"hxlint did not report {label} ({rule}); its silence on the "
                        f"real page proves nothing. It said: {findings(broken)}")
    found = findings(DOC)
    if found:
        return fail("hxlint reads the app's htmx 4 output and objects:\n  " + "\n  ".join(found))

    print("app-vocabulary: an app outside the repository conforms to `Vocabulary` "
          "with no underscore in it; Fragment[Htmx4] emits hx-swap=\"outerMorph\" and "
          "hx-query in both tiers, the layer refuses a typo the conformance never "
          "checked, open_kind() answers all four kinds, and hxlint (htmx "
          f"{hxlint.V.VERSION}, null-cased three ways) finds nothing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
