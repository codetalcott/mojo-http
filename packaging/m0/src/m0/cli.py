"""The `m0` command line: a closed set of commands and of exit codes.

    0    done
    1    the tool m0 ran failed (a compiler error, a failing test), with its
         output untouched
    2    the command line cannot be accepted (argparse's own code)
    78   m0 refused before running anything: one `m0: detail (fix)` line on
         stderr, from `checks.py`

`m0 doctor` adds the application's own exit, passed through.

Stdlib only, on purpose (docs/DECISIONS.md D40): the build toolchain is a
PyPI wheel inside a venv whatever this is written in, so Python adds nothing
to what building already needs, and the shipped application still has no
interpreter in it.
"""

import argparse
from pathlib import Path

from m0 import build, checks, doctor, include, new, test


def _parser():
    parser = argparse.ArgumentParser(
        prog="m0",
        allow_abbrev=False,
        description="Write, build, test and check a Mojo web application "
        "against the framework source this wheel carries.",
    )
    parser.add_argument("--version", action="version", version=f"m0 {checks.m0_version()}")
    sub = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")

    p = sub.add_parser(
        "new", allow_abbrev=False,
        help="write an application into ./NAME; needs no toolchain and no network",
    )
    p.add_argument("name", metavar="NAME",
                   help="the directory, the project and the deploy's app name at once")
    # A closed set of what exists and is gated on the wire; it grows by a
    # value, never by a flag per feature (docs/DECISIONS.md D44).
    p.add_argument("--template", choices=new.TEMPLATES, default="views",
                   help="views: a server-rendered list swapped by htmx 4 (default); "
                   "live: a producer pushing state to every tab over SSE, with Datastar")
    p.set_defaults(run=new.run)

    p = sub.add_parser(
        "include", allow_abbrev=False,
        help="print the include root: the framework's source, for an editor or a reader",
    )
    p.set_defaults(run=include.run)

    p = sub.add_parser(
        "build", allow_abbrev=False,
        help="compile src/server.mojo to bin/server (--release: a relocated bundle in dist/)",
    )
    p.add_argument("--release", action="store_true",
                   help="compile for the platform's baseline CPU, relocate, and bundle the Mojo runtime into dist/")
    p.add_argument("--target-cpu", metavar="CPU",
                   help="the CPU to compile for (default: this machine's; with --release, the platform's baseline)")
    p.set_defaults(run=build.run)

    p = sub.add_parser(
        "test", allow_abbrev=False,
        help="mojo run each test file (default: test/test_*.mojo); needs no C compiler",
    )
    p.add_argument("files", nargs="*", metavar="FILE")
    p.set_defaults(run=test.run)

    p = sub.add_parser(
        "doctor", allow_abbrev=False,
        help="every toolchain check, then bin/server's own --doctor; arguments after -- go to the binary",
    )
    p.add_argument("--json", action="store_true",
                   help="one JSON object as the last line of stdout")
    p.set_defaults(run=doctor.run)
    return parser


def main(argv=None):
    import sys

    argv = list(sys.argv[1:] if argv is None else argv)
    # Everything after `--` is the application's, and only `doctor` has an
    # application to hand it to. Split before argparse sees it, so a host
    # flag can never be read as one of ours.
    host_args = []
    if "--" in argv:
        at = argv.index("--")
        argv, host_args = argv[:at], argv[at + 1:]

    parser = _parser()
    args = parser.parse_args(argv)
    if host_args and args.command != "doctor":
        parser.error(f"m0 {args.command} takes no arguments after --")
    if args.command == "build" and args.release and args.target_cpu == "native":
        parser.error(
            "--release never compiles for the machine that builds; the "
            f"baseline here is {build.baseline_cpu()} (omit --target-cpu, or name a CPU)"
        )
    args.host_args = host_args
    args.project = Path.cwd()
    return args.run(args)
