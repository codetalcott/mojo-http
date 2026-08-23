"""Tests for `m0serve`'s argument parsing.

Deliberately no interpreter here, same charter as `test_environ`: the parser
is a pure function from a list of strings to `ServeOptions`, and keeping it
that way is what lets a typo in a flag be caught without starting Python.
What is NOT reachable here is what `m0serve` does with the result — binding,
forking, loading the application — which `smoke-serve` pins.
"""

from std.os import setenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from src.cli import (
    ServeOptions,
    parse_args,
    parse_app_spec,
    parse_size,
    parse_int,
    usage,
    DEFAULT_PORT,
    M0SERVE_VERSION,
)
from m0_http.config import AppConfig


def _seed() -> ServeOptions:
    """Hard defaults only; the environment is never consulted by these tests."""
    return ServeOptions()


def _parse(args: List[String]) raises -> ServeOptions:
    return parse_args(args, _seed())


def _fails(args: List[String]) -> Bool:
    """Whether the parser rejects `args` — the usage-error path."""
    try:
        _ = parse_args(args, _seed())
        return False
    except:
        return True


# --- the positional ----------------------------------------------------------


def test_positional_module_and_attribute() raises:
    var opts = _parse([String("myproject.wsgi:app")])
    assert_equal(opts.module, "myproject.wsgi")
    assert_equal(opts.attribute, "app")
    assert_equal(opts.spec(), "myproject.wsgi:app")


def test_attribute_defaults_to_application() raises:
    """`myproject.wsgi` alone means `myproject.wsgi:application`, as gunicorn."""
    var opts = _parse([String("myproject.wsgi")])
    assert_equal(opts.module, "myproject.wsgi")
    assert_equal(opts.attribute, "application")


def test_missing_positional_is_an_error() raises:
    assert_true(_fails(List[String]()))
    assert_true(_fails([String("--port"), String("8080")]))


def test_two_positionals_is_an_error() raises:
    assert_true(_fails([String("a.wsgi"), String("b.wsgi")]))


def test_app_spec_rejects_empty_halves() raises:
    for bad in [String(""), String(":application"), String("mod:"), String("  ")]:
        var rejected = False
        try:
            _ = parse_app_spec(bad)
        except:
            rejected = True
        assert_true(rejected, "accepted '" + bad + "'")


def test_help_and_version_need_no_positional() raises:
    assert_true(_parse([String("--help")]).show_help)
    assert_true(_parse([String("-h")]).show_help)
    assert_true(_parse([String("--version")]).show_version)
    assert_true(_parse([String("-V")]).show_version)


# --- precedence: flag over seed ----------------------------------------------


def test_port_flag_overrides_seed() raises:
    var seed = _seed()
    seed.port = 8080
    var opts = parse_args([String("m.wsgi"), String("--port"), String("9000")], seed)
    assert_equal(opts.port, 9000)


def test_seed_is_kept_when_no_flag_names_it() raises:
    var seed = _seed()
    seed.port = 8080
    seed.host = String("10.0.0.1")
    seed.workers = 3
    seed.access_log = True
    var opts = parse_args([String("m.wsgi")], seed)
    assert_equal(opts.port, 8080)
    assert_equal(opts.host, "10.0.0.1")
    assert_equal(opts.workers, 3)
    assert_true(opts.access_log)


def test_equals_form_is_accepted() raises:
    var opts = _parse([String("m.wsgi"), String("--port=9000"), String("--host=127.0.0.1")])
    assert_equal(opts.port, 9000)
    assert_equal(opts.host, "127.0.0.1")


# --- strictness: a typed flag is told, not defaulted -------------------------


def test_non_numeric_port_is_an_error() raises:
    """Unlike `M0_PORT=80eighty`, which `_parse_int_env` silently defaults."""
    assert_true(_fails([String("m.wsgi"), String("--port"), String("80eighty")]))


def test_port_out_of_range_is_an_error() raises:
    assert_true(_fails([String("m.wsgi"), String("--port"), String("0")]))
    assert_true(_fails([String("m.wsgi"), String("--port"), String("65536")]))
    assert_equal(_parse([String("m.wsgi"), String("--port"), String("65535")]).port, 65535)


def test_workers_below_one_is_an_error() raises:
    assert_true(_fails([String("m.wsgi"), String("--workers"), String("0")]))
    assert_equal(_parse([String("m.wsgi"), String("--workers"), String("4")]).workers, 4)


def test_threads_flag_and_its_floor() raises:
    assert_equal(_parse([String("m.wsgi")]).threads, 1)
    assert_equal(_parse([String("m.wsgi"), String("--threads"), String("4")]).threads, 4)
    assert_true(_fails([String("m.wsgi"), String("--threads"), String("0")]))
    assert_true(_fails([String("m.wsgi"), String("--threads"), String("four")]))


def test_unknown_option_is_an_error() raises:
    assert_true(_fails([String("m.wsgi"), String("--bogus")]))
    assert_true(_fails([String("m.wsgi"), String("-x")]))


def test_missing_value_at_the_end_is_an_error() raises:
    assert_true(_fails([String("m.wsgi"), String("--port")]))


def test_boolean_flag_refuses_a_value() raises:
    assert_true(_fails([String("m.wsgi"), String("--metrics=yes")]))


# --- host, app-dir -----------------------------------------------------------


def test_host_flag_and_address() raises:
    var opts = _parse([String("m.wsgi"), String("--host"), String("127.0.0.1"), String("--port"), String("81")])
    assert_equal(opts.address(), "127.0.0.1:81")


def test_host_localhost_means_loopback() raises:
    assert_equal(_parse([String("m.wsgi"), String("--host"), String("localhost")]).host, "127.0.0.1")


def test_app_dir_defaults_to_dot() raises:
    """The default uvicorn uses, and a necessary one: an embedded interpreter
    has no '' on sys.path, so without it `m0serve myproject.wsgi` from the
    project directory could not import the module."""
    assert_equal(_parse([String("m.wsgi")]).app_dir, ".")


def test_app_dir_flag() raises:
    assert_equal(
        _parse([String("m.wsgi"), String("--app-dir"), String("/srv/app")]).app_dir,
        "/srv/app",
    )


# --- static mounts -----------------------------------------------------------


def test_static_mount_splits_on_the_first_equals() raises:
    """A directory may contain '='; only the first one is the separator."""
    var opts = _parse([String("m.wsgi"), String("--static"), String("/s/=a=b")])
    assert_equal(len(opts.static_prefixes), 1)
    assert_equal(opts.static_prefixes[0], "/s/")
    assert_equal(opts.static_dirs[0], "a=b")


def test_static_mounts_accumulate() raises:
    var opts = _parse([
        String("m.wsgi"),
        String("--static"), String("/static/=./static"),
        String("--static=/media/=./media"),
    ])
    assert_equal(len(opts.static_prefixes), 2)
    assert_equal(opts.static_prefixes[1], "/media/")
    assert_equal(opts.static_dirs[1], "./media")


def test_static_prefix_must_start_with_a_slash() raises:
    assert_true(_fails([String("m.wsgi"), String("--static"), String("static=./static")]))


def test_static_without_equals_or_dir_is_an_error() raises:
    assert_true(_fails([String("m.wsgi"), String("--static"), String("/static/")]))
    assert_true(_fails([String("m.wsgi"), String("--static"), String("/static/=")]))


def test_static_cache_control_flag() raises:
    var opts = _parse([String("m.wsgi"), String("--static-cache-control"), String("public, max-age=60")])
    assert_equal(opts.static_cache_control, "public, max-age=60")


# --- booleans and sizes ------------------------------------------------------


def test_access_log_and_metrics_are_boolean_flags() raises:
    var opts = _parse([String("m.wsgi"), String("--access-log"), String("--metrics")])
    assert_true(opts.access_log)
    assert_true(opts.metrics)
    var plain = _parse([String("m.wsgi")])
    assert_false(plain.access_log)
    assert_false(plain.metrics)


def test_realtime_is_off_by_default() raises:
    """The hold machinery costs two slot arrays; nobody gets it unasked."""
    assert_false(_parse([String("m.wsgi")]).realtime)
    assert_true(_parse([String("m.wsgi"), String("--realtime")]).realtime)


def test_health_path_is_empty_until_asked_for() raises:
    """Empty means the application owns every path, `/health` included."""
    assert_equal(_parse([String("m.wsgi")]).health_path, String(""))
    var opts = _parse(
        [String("m.wsgi"), String("--health-path"), String("/healthz")]
    )
    assert_equal(opts.health_path, String("/healthz"))


def test_health_path_must_be_a_path() raises:
    """A value that is not rooted would never match a request target."""
    assert_true(
        _fails([String("m.wsgi"), String("--health-path"), String("health")])
    )
    assert_true(_fails([String("m.wsgi"), String("--health-path")]))


def test_max_body_default_is_minus_one() raises:
    """-1 means "leave ServerConfig's default alone", not "no limit"."""
    assert_equal(_parse([String("m.wsgi")]).max_body, -1)


def test_max_body_accepts_suffixes() raises:
    assert_equal(parse_size(String("4194304")), 4194304)
    assert_equal(parse_size(String("512k")), 512 * 1024)
    assert_equal(parse_size(String("64M")), 64 * 1024 * 1024)
    assert_equal(parse_size(String("1g")), 1024 * 1024 * 1024)
    assert_equal(parse_size(String(" 2k ")), 2048)
    assert_equal(_parse([String("m.wsgi"), String("--max-body"), String("1k")]).max_body, 1024)


def test_max_body_junk_is_an_error() raises:
    for bad in [String(""), String("k"), String("12x"), String("-1"), String("1.5m")]:
        var rejected = False
        try:
            _ = parse_size(bad)
        except:
            rejected = True
        assert_true(rejected, "accepted '" + bad + "'")


def test_parse_int_is_strict() raises:
    assert_equal(parse_int(String(" 42 "), "n"), 42)
    var rejected = False
    try:
        _ = parse_int(String("4 2"), "n")
    except:
        rejected = True
    assert_true(rejected)


# --- the ServerConfig mapping ------------------------------------------------


def _clear_env():
    for name in [
        String("M0_HOST"), String("M0_PORT"), String("M0_WORKERS"), String("M0_THREADS"),
        String("M0_ACCESS_LOG"), String("M0_SSE_HEARTBEAT_MS"), String("M0_APP_TICK_MS"),
    ]:
        _ = setenv(name, "", True)


def test_server_config_leaves_body_cap_alone_when_unset() raises:
    _clear_env()
    var opts = _parse([String("m.wsgi")])
    var sc = opts.server_config(AppConfig())
    var plain = AppConfig().server_config()
    assert_equal(sc.max_request_body_size, plain.max_request_body_size)
    assert_false(sc.enable_metrics)


def test_server_config_applies_max_body_and_metrics() raises:
    _clear_env()
    var opts = _parse([String("m.wsgi"), String("--max-body"), String("1k"), String("--metrics")])
    var sc = opts.server_config(AppConfig())
    assert_equal(sc.max_request_body_size, 1024)
    assert_true(sc.enable_metrics)


def test_server_config_keeps_env_access_log_when_flag_absent() raises:
    """The flag can only turn logging on; it must not turn M0_ACCESS_LOG off."""
    _clear_env()
    _ = setenv("M0_ACCESS_LOG", "1", True)
    var opts = _parse([String("m.wsgi")])
    assert_true(opts.server_config(AppConfig()).access_log)
    _clear_env()


# --- the environment seed ----------------------------------------------------


def test_from_env_reads_host_port_workers() raises:
    _clear_env()
    _ = setenv("M0_HOST", "127.0.0.1", True)
    _ = setenv("M0_PORT", "8123", True)
    _ = setenv("M0_WORKERS", "2", True)
    var seed = ServeOptions.from_env()
    assert_equal(seed.host, "127.0.0.1")
    assert_equal(seed.port, 8123)
    assert_equal(seed.workers, 2)
    _ = setenv("M0_THREADS", "3", True)
    assert_equal(ServeOptions.from_env().threads, 3)
    # And a flag still wins over it.
    var opts = parse_args([String("m.wsgi"), String("--port"), String("9")], seed)
    assert_equal(opts.port, 9)
    assert_equal(opts.host, "127.0.0.1")
    _clear_env()


def test_from_env_default_port_is_8000() raises:
    _clear_env()
    assert_equal(ServeOptions.from_env().port, DEFAULT_PORT)
    assert_equal(DEFAULT_PORT, 8000)


# --- usage -------------------------------------------------------------------


def test_usage_mentions_every_flag() raises:
    var text = usage()
    for flag in [
        String("--host"), String("--port"), String("--workers"), String("--threads"), String("--app-dir"),
        String("--static"), String("--static-cache-control"), String("--access-log"),
        String("--max-body"), String("--metrics"), String("--realtime"),
        String("--health-path"), String("--help"), String("--version"),
        String("-h"), String("-V"), String("MODULE[:ATTR]"),
    ]:
        assert_true(text.find(flag) >= 0, "usage() does not mention " + flag)


def test_version_is_a_dotted_triple() raises:
    var parts = M0SERVE_VERSION.split(".")
    assert_equal(len(parts), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
