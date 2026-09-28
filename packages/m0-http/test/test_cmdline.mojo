"""The command-line reader `m0serve` and the Mojo host share (`src/cmdline.mojo`).

Each caller's own suite -- `test_cli.mojo` in m0-wsgi, `test_host_flags.mojo`
here -- holds its flags to its fields, through the `.mojoc`. This holds the
reading itself, compiled from source, so a change to `cmdline.mojo` is seen
here before any rebuild; `sabotage-host`'s reader rule runs this file.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from src.cmdline import LongFlag, is_long_flag, parse_int, read_long_flag


def _value_flag(name: String) -> Bool:
    return name == "--port" or name == "--dir"


def _bool_flag(name: String) -> Bool:
    return name == "--qos"


def _args(*words: String) -> List[String]:
    var out = List[String]()
    for w in words:
        out.append(String(w))
    return out^


def _read(args: List[String], mut i: Int) raises -> LongFlag:
    return read_long_flag(args, i, _value_flag, _bool_flag)


def _refused(*words: String) -> String:
    """The message the first word earns, or empty if it was read."""
    var args = List[String]()
    for w in words:
        args.append(String(w))
    var i = 0
    try:
        _ = _read(args, i)
    except e:
        return String(e)
    return String("")


def _with_byte(before: String, byte: Int, after: String) -> String:
    """`before`, one raw byte, then `after`: an argument that is not UTF-8."""
    var b = List[UInt8]()
    for c in before.as_bytes():
        b.append(c)
    b.append(UInt8(byte))
    for c in after.as_bytes():
        b.append(c)
    return String(unsafe_from_utf8=Span(b))


def test_both_spellings_of_a_value_are_read() raises:
    """`--port 9000` leaves `i` on the value, which the caller's loop steps
    past; `--port=9000` consumes nothing after it, and neither does a
    boolean. `=` is cut at the FIRST one, so a value may hold its own."""
    var i = 0
    var spaced = _read(_args("--port", "9000", "m.wsgi"), i)
    assert_equal(spaced.name, "--port")
    assert_equal(spaced.value, "9000")
    assert_equal(i, 1)
    var j = 0
    var inline = _read(_args("--port=9000", "m.wsgi"), j)
    assert_equal(inline.name, "--port")
    assert_equal(inline.value, "9000")
    assert_equal(j, 0)
    var k = 0
    assert_equal(_read(_args("--dir=a=b"), k).value, "a=b")
    var b = 0
    var flag = _read(_args("--qos", "m.wsgi"), b)
    assert_equal(flag.name, "--qos")
    assert_equal(flag.value, "")
    assert_equal(b, 0)


def test_what_cannot_be_read_is_refused_by_name() raises:
    """The four one-line refusals both command lines print above their
    usage, exit 2."""
    assert_equal(_refused("--prot", "9"), "unknown option --prot")
    assert_equal(_refused("--prot=9"), "unknown option --prot")
    assert_equal(_refused("--qos=1"), "--qos takes no value")
    assert_equal(_refused("--port"), "--port needs a value")
    assert_equal(_refused("--port", "9"), "")


def test_an_argument_that_is_not_utf8_is_cut_by_bytes() raises:
    """A command line is bytes. m0serve's copy of this reader cut
    `--name=value` with a codepoint-checked slice, and a value opening with
    a byte that continues a UTF-8 sequence trapped the process; cut by
    bytes, the value arrives as it was given."""
    var odd = _with_byte("", 0x80, "x")
    var i = 0
    var flag = _read(_args(String("--dir=") + odd), i)
    assert_equal(flag.name, "--dir")
    assert_equal(len(flag.value.as_bytes()), 2)
    assert_equal(Int(flag.value.as_bytes()[0]), 0x80)
    # A name that is not UTF-8 is an unknown option, named as given.
    var named = _refused(String("--") + odd + String("=1"))
    assert_true(named.startswith("unknown option --"))


def test_a_long_flag_is_two_dashes_and_a_name() raises:
    assert_true(is_long_flag("--x"))
    assert_false(is_long_flag("--"))
    assert_false(is_long_flag("-x"))
    assert_false(is_long_flag("m.wsgi"))


def test_parse_int_is_strict() raises:
    assert_equal(parse_int(" 42 ", "n"), 42)
    assert_equal(parse_int("123456789012345678", "n"), 123456789012345678)
    for bad in [
        String("4 2"), String("-1"), String("+1"), String(""), String("0x10"),
        String("1234567890123456789"),
    ]:
        var said = String("")
        try:
            _ = parse_int(bad, "--n")
        except e:
            said = String(e)
        assert_true(said.startswith("--n must be a number"), "read '" + bad + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
