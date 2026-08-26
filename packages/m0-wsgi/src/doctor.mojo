"""`--doctor`: what this configuration would do, as JSON, starting nothing.

The launch checklist calls for a machine-readable startup diagnostic, and
the reason is narrower than "nice to have": every refusal this server makes
is already a one-line message that names its fix, but a caller has to
*attempt the run* to see one — and attempting the run binds a port, forks,
and imports the application. An agent choosing flags, or a human debugging
a container that exits 78 in a log it cannot scroll, wants the verdict
without the side effects.

So the contract is deliberately small and total:

    m0serve --doctor [OPTIONS] [MODULE[:ATTR]]

prints one JSON object and exits with **the code `m0serve` itself would
exit with for the same arguments** — 0 when it would serve, 2 for a usage
conflict, 1 when the application cannot be loaded, 78 when the interpreter
cannot run the requested mode. That equivalence is the whole value; a
diagnostic that reports "fine" where the server refuses is worse than no
diagnostic, which is why `checks` below is assembled from the same
predicates `main` branches on rather than from a second description of
them.

This module is the pure half: it holds facts and renders them. Everything
that touches the interpreter, the filesystem or the application lives in
`m0serve.mojo`, which gathers and calls `add_*`. That split is what keeps
`doctor.mojo` in `test-wsgi`, which runs with no Python at all.

Structure-of-arrays throughout, per the repo's Mojo 1.0 convention: a
`List[Struct]` needs `ImplicitlyCopyable` members and these are Strings.
"""

from m0_core import escape_json_string


comptime DOCTOR_OK = 0
"""The configuration would serve."""


struct Report(Copyable, Movable):
    """Facts and checks, in insertion order, rendered as one JSON object.

    Facts are grouped: `add_fact("python", "version", ...)` lands in a
    `"python": {...}` object. Groups appear in the order first named, keys
    in the order added — a stable shape is what makes the output diffable
    across runs, which is most of why anyone pipes it anywhere.
    """

    var groups: List[String]
    """Group name per fact, parallel to `keys`/`values`/`raws`."""
    var keys: List[String]
    var values: List[String]
    var raws: List[Bool]
    """True when the value is a bare JSON token (number, bool, array) and
    must not be quoted or escaped. Numbers rendered as strings are the
    classic way a machine-readable output stops being machine-readable."""

    var check_names: List[String]
    var check_ok: List[Bool]
    var check_details: List[String]
    var check_fixes: List[String]
    var check_codes: List[Int]
    """Exit code to report if this check failed. `DOCTOR_OK` on a passing
    check; the worst (first non-zero, in check order) becomes the process's."""

    var version: String
    """`M0SERVE_VERSION`, passed in so this module needs no import from
    `cli` and stays trivially constructible in tests."""

    def __init__(out self, var version: String):
        self.version = version^
        self.groups = List[String]()
        self.keys = List[String]()
        self.values = List[String]()
        self.raws = List[Bool]()
        self.check_names = List[String]()
        self.check_ok = List[Bool]()
        self.check_details = List[String]()
        self.check_fixes = List[String]()
        self.check_codes = List[Int]()

    def __init__(out self, *, copy: Self):
        self.version = copy.version
        self.groups = copy.groups.copy()
        self.keys = copy.keys.copy()
        self.values = copy.values.copy()
        self.raws = copy.raws.copy()
        self.check_names = copy.check_names.copy()
        self.check_ok = copy.check_ok.copy()
        self.check_details = copy.check_details.copy()
        self.check_fixes = copy.check_fixes.copy()
        self.check_codes = copy.check_codes.copy()

    def __init__(out self, *, deinit move: Self):
        self.version = move.version^
        self.groups = move.groups^
        self.keys = move.keys^
        self.values = move.values^
        self.raws = move.raws^
        self.check_names = move.check_names^
        self.check_ok = move.check_ok^
        self.check_details = move.check_details^
        self.check_fixes = move.check_fixes^
        self.check_codes = move.check_codes^

    def add_fact(mut self, group: String, key: String, value: String):
        """A string-valued fact; the value is JSON-escaped on render."""
        self.groups.append(group)
        self.keys.append(key)
        self.values.append(value)
        self.raws.append(False)

    def add_raw(mut self, group: String, key: String, token: String):
        """A fact already in JSON form — a number, `true`/`false`, an array."""
        self.groups.append(group)
        self.keys.append(key)
        self.values.append(token)
        self.raws.append(True)

    def add_int(mut self, group: String, key: String, value: Int):
        self.add_raw(group, key, String(value))

    def add_bool(mut self, group: String, key: String, value: Bool):
        self.add_raw(group, key, String("true") if value else String("false"))

    def pass_check(mut self, name: String, detail: String):
        self.check_names.append(name)
        self.check_ok.append(True)
        self.check_details.append(detail)
        self.check_fixes.append(String(""))
        self.check_codes.append(DOCTOR_OK)

    def fail_check(
        mut self, name: String, detail: String, fix: String, code: Int
    ):
        """Record a refusal, with the exit code the server would use for it.

        `fix` is not decoration. Every refusal in this server already names
        what to do about it, and a JSON consumer that gets only a message
        has to parse prose to act; keeping the remedy in its own field is
        the difference between a diagnostic an agent reads and one it has
        to guess at.
        """
        self.check_names.append(name)
        self.check_ok.append(False)
        self.check_details.append(detail)
        self.check_fixes.append(fix)
        self.check_codes.append(code)

    def ok(self) -> Bool:
        for i in range(len(self.check_ok)):
            if not self.check_ok[i]:
                return False
        return True

    def exit_code(self) -> Int:
        """The code `m0serve` would exit with, or 0.

        First failure in check order wins rather than the numerically
        largest: checks are added in the order `main` performs them, so the
        first one to fail is the one the server would actually hit. Ordering
        the list correctly is therefore load-bearing, and
        `test_doctor.mojo` pins it.
        """
        for i in range(len(self.check_codes)):
            if not self.check_ok[i]:
                return self.check_codes[i]
        return DOCTOR_OK

    def render(self) -> String:
        """The whole report as one JSON object, key order stable."""
        var out = String("{")
        out += '"m0serve":' + escape_json_string(self.version)
        out += ',"ok":' + (String("true") if self.ok() else String("false"))
        out += ',"exit":' + String(self.exit_code())

        # Groups in first-mention order. Quadratic in group count, which is
        # a handful — clarity is worth more than a set here.
        var seen = List[String]()
        for i in range(len(self.groups)):
            var group = self.groups[i]
            var already = False
            for s in range(len(seen)):
                if seen[s] == group:
                    already = True
                    break
            if already:
                continue
            seen.append(group)
            out += "," + escape_json_string(group) + ":{"
            var first = True
            for k in range(len(self.groups)):
                if self.groups[k] != group:
                    continue
                if not first:
                    out += ","
                first = False
                out += escape_json_string(self.keys[k]) + ":"
                if self.raws[k]:
                    out += self.values[k]
                else:
                    out += escape_json_string(self.values[k])
            out += "}"

        out += ',"checks":['
        for i in range(len(self.check_names)):
            if i > 0:
                out += ","
            out += '{"name":' + escape_json_string(self.check_names[i])
            out += ',"ok":' + (
                String("true") if self.check_ok[i] else String("false")
            )
            out += ',"detail":' + escape_json_string(self.check_details[i])
            if not self.check_ok[i]:
                out += ',"fix":' + escape_json_string(self.check_fixes[i])
                out += ',"exit":' + String(self.check_codes[i])
            out += "}"
        out += "]}"
        return out^
