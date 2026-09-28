"""The command line, read strictly: what `m0serve` and the Mojo host share.

`m0_wsgi.cli.parse_args` and `m0_host.flags.parse_host_flags` take the same
shape -- `--name value`, `--name=value`, a bare boolean -- and refuse the
same things with exit 2: an option neither list names, a value on a
boolean, a value-taking option with nothing after it, and a number that is
not one. Each caller keeps its own flag lists (`_takes_value` and
`_is_bool`, which `scripts/spec_sheet.py` reads as text), its own short
options and its own fields; reading an option and its value is here, once.
It was two copies until 2026-09-28, and they had drifted: `m0serve` cut
`--name=value` with a codepoint-checked slice, so an argument whose byte
after the `=` continues a UTF-8 sequence trapped the process, where the
host's copy read it.

A command line is bytes, not text: nothing obliges argv to be UTF-8, so
nothing here slices with `[byte=a:b]`, which asserts a codepoint boundary
at both ends (the rule CLAUDE.md states for request bytes, SPEC G14).
"""


comptime FlagList = def (String) thin -> Bool
"""A caller's flag list as a predicate: `_takes_value` or `_is_bool`."""


@fieldwise_init
struct LongFlag(Movable):
    """One `--name` option, read: its name, and a value-taking option's value."""

    var name: String
    """The option as given, up to any `=`: `--port`."""
    var value: String
    """What a value-taking option carries, inline after `=` or the argument
    after it; empty for a boolean."""


def is_long_flag(arg: String) -> Bool:
    """Whether `arg` is a long option: two dashes and a name after them."""
    return arg.startswith("--") and arg.byte_length() > 2


def read_long_flag(
    args: List[String], mut i: Int, takes_value: FlagList, is_bool: FlagList
) raises -> LongFlag:
    """The option at `args[i]` (`is_long_flag`), with its value.

    `--name=value` is cut at its first `=`, by bytes. A value-taking option
    given no `=` takes the NEXT argument, and `i` is left on that argument,
    so the caller's loop steps past both. Raises the one-line message the
    caller prints above its usage: `unknown option --x` for a name neither
    list holds, `--x takes no value` for a boolean given one, and
    `--x needs a value` for a value-taking option at the end of the line.
    """
    var name = args[i]
    var value = String("")
    var inline = False
    var eq = name.find("=")
    if eq >= 0:
        var arg = args[i].as_bytes()
        name = String(unsafe_from_utf8=arg[:eq])
        value = String(unsafe_from_utf8=arg[eq + 1 :])
        inline = True
    if is_bool(name):
        if inline:
            raise Error(name + " takes no value")
    elif takes_value(name):
        if not inline:
            if i + 1 >= len(args):
                raise Error(name + " needs a value")
            i += 1
            value = args[i]
    else:
        raise Error("unknown option " + name)
    return LongFlag(name^, value^)


def parse_int(text: String, what: String) raises -> Int:
    """Strict decimal parse; anything but digits is a usage error.

    Surrounding spaces are allowed, a sign is not, and neither is a number
    longer than 18 digits, which is the most an Int64 always holds.
    `M0_PORT=80eighty` is the default port -- the environment is lenient --
    and `--port 80eighty` is this error.
    """
    var digits = String(text.strip())
    var n = digits.byte_length()
    if n == 0 or n > 18:
        raise Error(what + " must be a number, got '" + text + "'")
    var bytes = digits.as_bytes()
    var value = 0
    for i in range(n):
        var c = Int(bytes[i])
        if c < ord("0") or c > ord("9"):
            raise Error(what + " must be a number, got '" + text + "'")
        value = value * 10 + (c - ord("0"))
    return value
