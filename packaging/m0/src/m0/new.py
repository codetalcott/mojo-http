"""`m0 new NAME [--template views|live]`: write an application.

Needs no toolchain and no network, which is what lets it run as `uvx m0 new`
before anything is installed: it copies files this wheel carries and
replaces four tokens.

The templates are REAL files (`templates/`), compiled in place against the
tree by `poe check-templates`, so none of them can be broken without a gate
saying so. That works because the application's name appears only where a
compiler does not look -- inside string literals, TOML and Markdown -- as
the token `__M0_APP__`, and substitution is `str.replace`. There is no
template engine, and a file that needed one does not belong in a template.

`MANIFEST` is the closed list of what a template writes. A file in
`templates/` that is not named here is not written, and a name here with no
file is a broken wheel, said so; `smoke-scaffold` spells the list a second
time and requires the written tree to equal it.
"""

import os
import re
import sys
from pathlib import Path

from m0 import checks, paths

TEMPLATES = ("views", "live")

NAME = re.compile(r"[a-z][a-z0-9-]*\Z")
NAME_MAX = 40

# Written for every template, from `templates/_common/`. A leading `dot-`
# is a leading `.` in the project: a `.gitignore` or a `.github/` inside
# this package would be read by the tools that build it.
COMMON = (
    "AGENTS.md",
    "CLAUDE.md",
    "README.md",
    "pyproject.toml",
    "dot-gitignore",
    "dot-dockerignore",
    "dot-github/workflows/test.yml",
    "deploy/Dockerfile",
    "deploy/README.md",
    "deploy/fly.toml",
)

MANIFEST = {
    "views": (
        "smoke.sh",
        "src/pages.mojo",
        "src/server.mojo",
        "src/views.mojo",
        "test/test_views.mojo",
    ),
    "live": (
        "smoke.sh",
        "src/board.mojo",
        "src/pages.mojo",
        "src/server.mojo",
        "src/store.mojo",
        "src/views.mojo",
        "src/wave.mojo",
        "test/test_live.mojo",
    ),
}

EXECUTABLE = ("smoke.sh",)

# The checks `new` can ask before a venv exists. It reads them from the one
# list (`checks.CHECKS`) by name; the other three describe an environment
# `uv sync` has not made yet.
EARLY_CHECKS = ("platform", "c-compiler")


def target_path(relative):
    """Where a template file lands: `dot-x` is `.x`, at any depth."""
    parts = [("." + p[4:]) if p.startswith("dot-") else p for p in relative.split("/")]
    return Path(*parts)


def written_paths(template):
    """Every path `m0 new --template TEMPLATE` writes, sorted, as strings."""
    names = list(COMMON) + list(MANIFEST[template])
    return sorted(str(target_path(n)) for n in names)


def render(text, app, m0_version, mojo_version, max_version):
    return (
        text.replace("__M0_APP__", app)
        .replace("__M0_VERSION__", m0_version)
        .replace("__MOJO_VERSION__", mojo_version)
        .replace("__M0_MAX_VERSION__", max_version)
    )


def _usage(message):
    print(f"m0 new: {message}", file=sys.stderr)
    return 2


def run(args):
    target = Path(args.name)
    app = target.name
    if not NAME.match(app) or len(app) > NAME_MAX:
        return _usage(
            f"'{app}' is not a usable name (lowercase letters, digits and "
            f"hyphens, starting with a letter, at most {NAME_MAX})"
        )
    shown = args.name if os.path.isabs(args.name) else f"./{args.name}"
    if target.exists() and (not target.is_dir() or any(target.iterdir())):
        return _usage(
            f"{shown} exists and is not empty (choose another name, or empty it)"
        )

    root = paths.PACKAGE / "templates"
    sources = [(root / "_common" / n, n) for n in COMMON]
    sources += [(root / args.template / n, n) for n in MANIFEST[args.template]]
    missing = [str(src) for src, _ in sources if not src.is_file()]
    if missing:
        print(
            f"m0: this m0 is missing template files ({missing[0]}); reinstall it",
            file=sys.stderr,
        )
        return 1

    m0_version = checks.m0_version()
    info = paths.build_info()
    mojo_version, max_version = info["gated_mojo"][0], info["gated_max"][0]
    for src, name in sources:
        out = target / target_path(name)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(
            render(src.read_text(encoding="utf-8"), app, m0_version, mojo_version, max_version),
            encoding="utf-8",
        )
        if name in EXECUTABLE:
            out.chmod(0o755)

    print(f"m0: wrote {shown} (template: {args.template})")
    print()
    print(f"    cd {args.name}")
    print("    uv sync")
    print("    uv run m0 build && bin/server --port 8080")
    print()
    print("AGENTS.md is the page to read first; `uv run m0 test` is the fast loop.")

    early = [check(target) for name, check in checks.CHECKS if name in EARLY_CHECKS]
    failing = [r for r in early if not r.ok]
    if failing:
        print()
        print("before `m0 build`:")
        for r in failing:
            print(f"    {r.detail} ({r.fix})")
    return 0
