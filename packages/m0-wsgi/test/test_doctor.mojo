"""Tests for `--doctor`'s report: the pure half, with no interpreter.

Same charter as `test_cli`. What is NOT reachable here is the property that
gives `--doctor` its value — that its exit code equals the one `m0serve`
itself would produce for the same arguments — because proving that means
running both. `smoke-doctor` does exactly that, over every refusal, and it
is the test that matters most; these pin the pieces it is built from.

The ordering test below is not hypothetical. `--workers 2 --threads 2` on a
GIL-enabled interpreter trips two refusals, and the first implementation
recorded the free-threading one first and so reported 78 where the server
exits 2.
"""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from src.doctor import Report, DOCTOR_OK
from src.cli import EXIT_USAGE, EXIT_STARTUP
from src.threaded import EXIT_NOT_FREE_THREADED


def _report() -> Report:
    return Report(String("9.9.9"))


# --- the verdict -------------------------------------------------------------


def test_empty_report_is_ok() raises:
    """No checks means nothing refused — the bare `m0serve --doctor` call."""
    var r = _report()
    assert_true(r.ok())
    assert_equal(r.exit_code(), DOCTOR_OK)


def test_passing_checks_stay_ok() raises:
    var r = _report()
    r.pass_check(String("app-dir"), String("exists"))
    r.pass_check(String("interpreter"), String("resolved"))
    assert_true(r.ok())
    assert_equal(r.exit_code(), 0)


def test_one_failure_sets_its_code() raises:
    var r = _report()
    r.pass_check(String("app-dir"), String("exists"))
    r.fail_check(
        String("free-threading"), String("GIL on"), String("use --workers"),
        EXIT_NOT_FREE_THREADED,
    )
    assert_false(r.ok())
    assert_equal(r.exit_code(), EXIT_NOT_FREE_THREADED)


def test_exit_code_is_the_first_failure_not_the_largest() raises:
    """The whole reason check order is load-bearing.

    A configuration that trips a usage conflict AND the free-threading
    refusal exits 2, because `main` never reaches the interpreter. Taking
    the largest code — or the last — would report 78 for a server that
    exits 2, which is precisely the mismatch `smoke-doctor` exists to catch.
    """
    var r = _report()
    r.fail_check(
        String("threads-vs-workers"), String("both given"), String("pick one"),
        EXIT_USAGE,
    )
    r.fail_check(
        String("free-threading"), String("GIL on"), String("use --workers"),
        EXIT_NOT_FREE_THREADED,
    )
    assert_equal(r.exit_code(), EXIT_USAGE)


def test_failure_after_a_pass_still_wins() raises:
    var r = _report()
    r.pass_check(String("app-dir"), String("exists"))
    r.fail_check(
        String("application"), String("no module"), String("check --app-dir"),
        EXIT_STARTUP,
    )
    assert_equal(r.exit_code(), EXIT_STARTUP)


# --- the rendering -----------------------------------------------------------


def test_render_carries_version_and_verdict() raises:
    var r = _report()
    var out = r.render()
    assert_true(out.find('"m0serve":"9.9.9"') >= 0, out)
    assert_true(out.find('"ok":true') >= 0, out)
    assert_true(out.find('"exit":0') >= 0, out)


def test_render_groups_facts_by_group() raises:
    """Facts land in the object named by their group, in insertion order."""
    var r = _report()
    r.add_fact(String("build"), String("os"), String("linux"))
    r.add_fact(String("python"), String("version"), String("3.13.7"))
    r.add_fact(String("build"), String("arch"), String("aarch64"))
    var out = r.render()
    assert_true(
        out.find('"build":{"os":"linux","arch":"aarch64"}') >= 0, out
    )
    assert_true(out.find('"python":{"version":"3.13.7"}') >= 0, out)


def test_numbers_and_bools_are_not_quoted() raises:
    """A number rendered as a string is how machine-readable output stops
    being machine-readable — `jq '.topology.workers > 1'` would break."""
    var r = _report()
    r.add_int(String("topology"), String("workers"), 4)
    r.add_bool(String("topology"), String("asgi_executor"), True)
    r.add_bool(String("topology"), String("resolved"), False)
    var out = r.render()
    assert_true(out.find('"workers":4') >= 0, out)
    assert_true(out.find('"asgi_executor":true') >= 0, out)
    assert_true(out.find('"resolved":false') >= 0, out)


def test_raw_values_pass_through_unescaped() raises:
    """`static` and `mounts` are pre-built JSON arrays, not strings."""
    var r = _report()
    r.add_raw(String("server"), String("static"), String('[{"prefix":"/s"}]'))
    var out = r.render()
    assert_true(out.find('"static":[{"prefix":"/s"}]') >= 0, out)


def test_failed_checks_carry_fix_and_code() raises:
    var r = _report()
    r.fail_check(
        String("application"),
        String("could not load app"),
        String("check --app-dir"),
        EXIT_STARTUP,
    )
    var out = r.render()
    assert_true(out.find('"name":"application"') >= 0, out)
    assert_true(out.find('"ok":false') >= 0, out)
    assert_true(out.find('"fix":"check --app-dir"') >= 0, out)
    assert_true(out.find('"exit":1') >= 0, out)


def test_passing_checks_omit_fix_and_code() raises:
    """A passing check has no remedy to name; emitting `"fix":""` would make
    a consumer test the string rather than the boolean."""
    var r = _report()
    r.pass_check(String("app-dir"), String("exists"))
    var out = r.render()
    assert_true(out.find('"name":"app-dir"') >= 0, out)
    assert_true(out.find('"fix"') < 0, out)


def test_detail_text_is_json_escaped() raises:
    """Refusal messages quote flags and paths; an unescaped one would emit
    a document no parser accepts, from the tool whose entire job is to be
    parsed."""
    var r = _report()
    r.fail_check(
        String("application"),
        String('no module named "nope"'),
        String("use \\ or quotes"),
        EXIT_STARTUP,
    )
    var out = r.render()
    assert_true(out.find('\\"nope\\"') >= 0, out)
    assert_true(out.find("\\\\") >= 0, out)


def test_report_is_copyable_and_movable() raises:
    var r = _report()
    r.add_int(String("topology"), String("workers"), 2)
    r.pass_check(String("app-dir"), String("exists"))
    var copied = r.copy()
    assert_equal(copied.render(), r.render())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
