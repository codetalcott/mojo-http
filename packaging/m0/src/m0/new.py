"""`m0 new NAME [--template views|live|board|auth]`: write an application.

`m0 new .` writes the current directory, which must be empty, and names
the application after it.

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

# One line per template, read by `m0 --help`, `m0 new --help` and what a
# bare `m0 new` prints, so the three cannot disagree. The top-level help is
# where the agent runs chose: every run without a skill ran `m0 --help`,
# then `m0 new .` before it knew a name, took `views`, and wrote again.
ABOUT = {
    "views": "a server-rendered list swapped by htmx 4",
    "live": "a producer pushing state to every tab over SSE, with Datastar",
    "board": "a list every tab shares, a message one tab posts reaching every open tab",
    "auth": "the views list behind a login, with a signed session and a CSRF token on every write",
}
TEMPLATES = tuple(ABOUT)
DEFAULT = "views"

# A letter first and a letter or digit last: a trailing hyphen is no
# PEP 508 project name, no image reference and no DNS label (the deploy's
# hostname), and `uv sync` was the first thing to say so, as a TOML parse
# error.
NAME = re.compile(r"[a-z](?:[a-z0-9-]*[a-z0-9])?\Z")
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
    "board": (
        "smoke.sh",
        "src/pages.mojo",
        "src/server.mojo",
        "src/views.mojo",
        "test/test_board.mojo",
    ),
    "auth": (
        "smoke.sh",
        "src/pages.mojo",
        "src/server.mojo",
        "src/views.mojo",
        "test/test_auth.mojo",
    ),
}

EXECUTABLE = ("smoke.sh",)

# The checks `new` can ask before a venv exists. It reads them from the one
# list (`checks.CHECKS`) by name; the other three describe an environment
# `uv sync` has not made yet.
EARLY_CHECKS = ("platform", "c-compiler")

# What a template needs in the environment before its binary will serve,
# printed with the next commands: `auth` refuses to start without them
# (exit 78, naming the variable), and the first minute should not be spent
# reading that refusal. `APP_SECURE=0` is this machine's http://localhost;
# `deploy/fly.toml` states 1 for the deploy behind HTTPS.
ENV_HINT = {
    "auth": "export APP_KEY=\"$(openssl rand -hex 32)\" APP_PASSWORD='choose one' APP_SECURE=0",
}


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


def listing(names, indent="    "):
    """A line per template, the name in a column: the help's and `new`'s."""
    width = max(len(n) for n in TEMPLATES)
    return "\n".join(
        f"{indent}{n:<{width}}  {ABOUT[n]}" + (" (the default)" if n == DEFAULT else "")
        for n in names
    )


def _usage(message):
    print(f"m0 new: {message}", file=sys.stderr)
    return 2


def run(args):
    # None when `--template` was not given: a default taken is said, with
    # the others, and a template chosen is not second-guessed.
    template = args.template or DEFAULT
    target = Path(args.name)
    # `.` names the directory it is: `m0 new .` writes the current directory
    # and takes its name, which the agent runs asked for -- every run wrote
    # `./NAME` and then moved the files up a level.
    here = target.resolve() == Path.cwd().resolve()
    app = target.name or target.resolve().name
    if not NAME.match(app) or len(app) > NAME_MAX:
        whose = "the current directory's name " if here else ""
        return _usage(
            f"{whose}'{app}' is not a usable name (lowercase letters, digits and "
            f"hyphens, starting with a letter and ending with a letter or digit, "
            f"at most {NAME_MAX})"
        )
    shown = args.name if os.path.isabs(args.name) else f"./{args.name}"
    if here and any(target.iterdir()):
        return _usage(
            "the current directory is not empty (empty it, or name a new directory)"
        )
    if target.exists() and (not target.is_dir() or any(target.iterdir())):
        return _usage(
            f"{shown} exists and is not empty (choose another name, or empty it)"
        )

    root = paths.PACKAGE / "templates"
    sources = [(root / "_common" / n, n) for n in COMMON]
    sources += [(root / template / n, n) for n in MANIFEST[template]]
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

    said = template + (", the default" if args.template is None else "")
    if here:
        print(f"m0: wrote the current directory as {app} (template: {said})")
    else:
        print(f"m0: wrote {shown} (template: {said})")
    print()
    if not here:
        print(f"    cd {args.name}")
    print("    uv sync")
    if template in ENV_HINT:
        print("    " + ENV_HINT[template])
    # This machine alone: without `--host` the server listens on every
    # interface.
    print("    uv run m0 build && bin/server --host 127.0.0.1 --port 8080")
    print()
    print("AGENTS.md is the page to read first; `uv run m0 test` is the fast loop.")
    if args.template is None:
        # Said while the directory is still a minute old: each run that took
        # the default found `board` only after it had written `views`.
        print()
        print(f"{DEFAULT} is the default; the others, for `m0 new NAME --template T` "
              "into an empty directory:")
        print(listing([t for t in TEMPLATES if t != DEFAULT]))

    early = [check(target) for name, check in checks.CHECKS if name in EARLY_CHECKS]
    failing = [r for r in early if not r.ok]
    if failing:
        print()
        print("before `m0 build`:")
        for r in failing:
            print(f"    {r.detail} ({r.fix})")
    return 0
