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
    zero_config_topology,
    default_blocking_threads,
    resolve_blocking_threads,
    use_asgi_executor,
    effective_cpus,
    discovery_specs,
    match_mount,
    DEFAULT_PORT,
    M0SERVE_VERSION,
    MAX_AUTO_BLOCKING_THREADS,
)
from m0_http.config import AppConfig


def _seed() -> ServeOptions:
    """Hard defaults only; the environment is never consulted by these tests."""
    return ServeOptions()


def _prefixes(a: String, b: String = String("\x00none")) -> List[String]:
    """Mount-prefix lists for the matcher tests. Built by append: an
    `Array[String, N]` cannot be materialised at run time on this toolchain
    (see the note above `_takes_value` in cli.mojo)."""
    var out = List[String]()
    out.append(a)
    if b != String("\x00none"):
        out.append(b)
    return out^


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


def test_reload_is_off_by_default() raises:
    """A development flag: nobody gets a file watcher unasked."""
    assert_false(_parse([String("m.wsgi")]).reload)
    assert_true(_parse([String("m.wsgi"), String("--reload")]).reload)


def test_reload_dirs_default_to_empty() raises:
    """Empty means `--app-dir`; the entry point resolves that, not the parser.

    The parser never reads the environment or the filesystem, so it cannot
    substitute the default here without becoming impure.
    """
    assert_equal(len(_parse([String("m.wsgi")]).reload_dirs), 0)


def test_reload_dirs_accumulate() raises:
    var opts = _parse([
        String("m.wsgi"),
        String("--reload-dir"), String("/one"),
        String("--reload-dir=/two"),
    ])
    assert_equal(len(opts.reload_dirs), 2)
    assert_equal(opts.reload_dirs[0], String("/one"))
    assert_equal(opts.reload_dirs[1], String("/two"))


def test_reload_dir_rejects_an_empty_value() raises:
    assert_true(_fails([String("m.wsgi"), String("--reload-dir"), String("")]))
    assert_true(_fails([String("m.wsgi"), String("--reload-dir")]))


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


def test_doctor_needs_no_positional() raises:
    """`m0serve --doctor` alone is the "is this environment sane" call.

    It shares that exemption with --help and --version; without it the
    parser would demand a MODULE for the one invocation that deliberately
    names no application.
    """
    var opts = _parse([String("--doctor")])
    assert_true(opts.show_doctor)
    assert_equal(opts.module, "")


def test_doctor_takes_an_app_when_given_one() raises:
    var opts = _parse([String("--doctor"), String("myproject.wsgi")])
    assert_true(opts.show_doctor)
    assert_equal(opts.module, "myproject.wsgi")


def test_doctor_does_not_turn_on_metrics() raises:
    """Guards a trap the boolean dispatch used to hold.

    Its final `else` was `opts.metrics = True`, so any boolean flag added to
    `_is_bool` and forgotten in the dispatch silently enabled Prometheus
    metrics instead of doing its job. The else now raises; this is the test
    that would have caught it.
    """
    var opts = _parse([String("--doctor"), String("x.wsgi")])
    assert_true(opts.show_doctor)
    assert_false(opts.metrics)
    assert_false(opts.realtime)
    assert_false(opts.reload)
    assert_false(opts.access_log)


def test_every_boolean_flag_sets_only_itself() raises:
    """The same trap, from the other side: --metrics must still work, and
    must not set anything else."""
    var m = _parse([String("--metrics"), String("x.wsgi")])
    assert_true(m.metrics)
    assert_false(m.show_doctor)
    var r = _parse([String("--realtime"), String("x.wsgi")])
    assert_true(r.realtime)
    assert_false(r.metrics)
    assert_false(r.show_doctor)


def test_doctor_takes_no_value() raises:
    assert_true(_fails([String("--doctor=1"), String("x.wsgi")]))


def test_usage_mentions_every_flag() raises:
    var text = usage()
    for flag in [
        String("--host"), String("--port"), String("--workers"), String("--threads"), String("--app-dir"),
        String("--static"), String("--static-cache-control"), String("--access-log"),
        String("--max-body"), String("--metrics"), String("--realtime"),
        String("--health-path"), String("--reload"), String("--reload-dir"),
        String("--protocol"), String("--blocking-threads"), String("--mount"),
        String("--help"), String("--version"), String("--doctor"),
        String("-h"), String("-V"), String("MODULE[:ATTR]"),
    ]:
        assert_true(text.find(flag) >= 0, "usage() does not mention " + flag)


# --- the protocol flag -------------------------------------------------------


def test_protocol_defaults_to_auto() raises:
    var opts = _parse([String("x.wsgi")])
    assert_equal(opts.protocol, "auto")


def test_protocol_accepts_the_three_values() raises:
    for value in [String("auto"), String("wsgi"), String("asgi")]:
        var opts = _parse([String("x.wsgi"), String("--protocol"), value])
        assert_equal(opts.protocol, value)


def test_protocol_rejects_anything_else() raises:
    assert_true(_fails([String("x.wsgi"), String("--protocol"), String("http3")]))
    assert_true(_fails([String("x.wsgi"), String("--protocol"), String("")]))


def test_attribute_explicit_tracks_the_colon() raises:
    """Discovery may only run for a bare MODULE — an explicit `:ATTR` never
    falls back to conventions, even when it names the default attribute."""
    assert_false(_parse([String("myproject")]).attribute_explicit)
    assert_true(_parse([String("myproject:application")]).attribute_explicit)
    assert_true(_parse([String("myproject:app")]).attribute_explicit)


# --- zero-config topology ----------------------------------------------------


def test_zero_config_true_only_when_nothing_was_said() raises:
    assert_true(zero_config_topology(_parse([String("x.wsgi")])))


def test_any_topology_flag_disables_zero_config() raises:
    """Even at the default value: `--workers 1` is a choice."""
    assert_false(zero_config_topology(_parse([String("x.wsgi"), String("--workers"), String("1")])))
    assert_false(zero_config_topology(_parse([String("x.wsgi"), String("--threads"), String("1")])))
    assert_false(zero_config_topology(_parse([String("x.wsgi"), String("--blocking-threads"), String("0")])))


def test_env_topology_disables_zero_config() raises:
    """An `M0_*` topology variable counts as explicit, through `from_env`."""
    _ = setenv("M0_BLOCKING_THREADS", "0", True)
    var opts = parse_args([String("x.wsgi")], ServeOptions.from_env())
    _ = setenv("M0_BLOCKING_THREADS", "", True)
    assert_false(zero_config_topology(opts))
    assert_equal(opts.blocking_threads, 0)


def test_non_topology_flags_keep_zero_config() raises:
    var opts = _parse([String("x.wsgi"), String("--port"), String("9000"), String("--access-log")])
    assert_true(zero_config_topology(opts))


def test_default_blocking_threads_floor_and_cap() raises:
    assert_equal(default_blocking_threads(0), 1)
    assert_equal(default_blocking_threads(-3), 1)
    assert_equal(default_blocking_threads(1), 1)
    assert_equal(default_blocking_threads(4), 4)
    assert_equal(default_blocking_threads(8), MAX_AUTO_BLOCKING_THREADS)
    assert_equal(default_blocking_threads(128), MAX_AUTO_BLOCKING_THREADS)


def test_resolve_blocking_threads_zero_config_picks_a_pool() raises:
    var opts = _parse([String("x.wsgi")])
    assert_equal(resolve_blocking_threads(opts, False, 4), 4)
    # ASGI gets NO pool: its zero-config concurrency is the asyncio
    # executor (`use_asgi_executor`), not handler threads.
    assert_equal(resolve_blocking_threads(opts, True, 4), 0)


def test_use_asgi_executor_truth_table() raises:
    var zero = _parse([String("x")])
    zero.blocking_threads = resolve_blocking_threads(zero, True, 4)
    assert_true(use_asgi_executor(zero, True))
    assert_false(use_asgi_executor(zero, False))
    # The escape hatch: an explicit pool keeps the buffered bridge.
    var pooled = _parse([String("x"), String("--blocking-threads"), String("3")])
    assert_false(use_asgi_executor(pooled, True))
    # An explicit zero still means the executor for ASGI — "no pool", not
    # "no concurrency".
    var bare = _parse([String("x"), String("--blocking-threads"), String("0")])
    assert_true(use_asgi_executor(bare, True))
    # Explicit workers compose: the executor runs per worker process.
    var workers = _parse([String("x"), String("--workers"), String("2")])
    assert_true(use_asgi_executor(workers, True))


def test_resolve_blocking_threads_explicit_wins() raises:
    var opts = _parse([String("x.wsgi"), String("--blocking-threads"), String("0")])
    assert_equal(resolve_blocking_threads(opts, False, 4), 0)
    var opts2 = _parse([String("x.wsgi"), String("--workers"), String("2")])
    assert_equal(resolve_blocking_threads(opts2, False, 4), 0)
    var opts3 = _parse([String("x.wsgi"), String("--blocking-threads"), String("3"), String("--realtime")])
    # An explicit pool with --realtime is refused later by m0serve, not
    # silently zeroed here: the resolver only decides DEFAULTS.
    assert_equal(resolve_blocking_threads(opts3, False, 4), 3)


def test_resolve_blocking_threads_realtime_keeps_the_single_loop() raises:
    var opts = _parse([String("x.wsgi"), String("--realtime")])
    assert_equal(resolve_blocking_threads(opts, False, 4), 0)


def test_effective_cpus_is_at_least_one() raises:
    assert_true(effective_cpus() >= 1)


# --- discovery ---------------------------------------------------------------


def test_discovery_specs_order_and_shape() raises:
    var specs = discovery_specs(String("myproject"))
    assert_equal(len(specs), 5)
    assert_equal(specs[0], "myproject:application")
    assert_equal(specs[1], "myproject.asgi:application")
    assert_equal(specs[2], "myproject.wsgi:application")
    assert_equal(specs[3], "myproject:app")
    assert_equal(specs[4], "myproject.main:app")


def test_discovery_specs_all_parse() raises:
    """Every convention the list emits must survive `parse_app_spec`."""
    var specs = discovery_specs(String("m"))
    for i in range(len(specs)):
        var pair = parse_app_spec(specs[i])
        assert_true(pair[0].byte_length() > 0)
        assert_true(pair[1].byte_length() > 0)


def test_version_is_a_dotted_triple() raises:
    var parts = M0SERVE_VERSION.split(".")
    assert_equal(len(parts), 3)


def test_mount_parses_prefix_and_spec() raises:
    var opts = _parse([String("--mount"), String("/app=main:app")])
    assert_equal(len(opts.mount_prefixes), 1)
    assert_equal(opts.mount_prefixes[0], String("/app"))
    assert_equal(opts.mount_modules[0], String("main"))
    assert_equal(opts.mount_attributes[0], String("app"))
    assert_true(opts.mount_explicit[0])


def test_mount_bare_module_keeps_discovery() raises:
    """A mount without `:ATTR` falls back exactly as a positional spec does."""
    var opts = _parse([String("--mount=/app=djangoproj")])
    assert_equal(opts.mount_modules[0], String("djangoproj"))
    assert_equal(opts.mount_attributes[0], String("application"))
    assert_false(opts.mount_explicit[0])


def test_mount_root_prefix_is_empty_string() raises:
    """`/` is stored as '', which is SCRIPT_NAME and root_path for an app at
    the root -- so the matcher and both protocols see one shape."""
    var opts = _parse([String("--mount"), String("/=djangoproj.wsgi")])
    assert_equal(len(opts.mount_prefixes), 1)
    assert_equal(opts.mount_prefixes[0], String(""))


def test_mount_strips_trailing_slash() raises:
    var opts = _parse([String("--mount"), String("/app/=main:app")])
    assert_equal(opts.mount_prefixes[0], String("/app"))


def test_mount_is_repeatable() raises:
    var opts = _parse(
        [
            String("--mount"),
            String("/=djangoproj.wsgi"),
            String("--mount"),
            String("/app=main:app"),
        ]
    )
    assert_equal(len(opts.mount_prefixes), 2)
    assert_equal(opts.mount_prefixes[0], String(""))
    assert_equal(opts.mount_prefixes[1], String("/app"))


def test_mount_prefix_must_be_absolute() raises:
    var failed = False
    try:
        _ = _parse([String("--mount"), String("app=main:app")])
    except:
        failed = True
    assert_true(failed)


def test_mount_needs_a_spec() raises:
    var failed = False
    try:
        _ = _parse([String("--mount"), String("/app")])
    except:
        failed = True
    assert_true(failed)


def test_mount_refuses_a_duplicate_prefix() raises:
    """Two apps on one prefix is a typo with no defensible reading; '/app/'
    and '/app' are the same mount after normalisation."""
    var failed = False
    try:
        _ = _parse(
            [
                String("--mount"),
                String("/app=main:app"),
                String("--mount"),
                String("/app/=other:app"),
            ]
        )
    except:
        failed = True
    assert_true(failed)


def test_mount_and_positional_are_exclusive() raises:
    var failed = False
    try:
        _ = _parse([String("--mount"), String("/app=main:app"), String("djangoproj.wsgi")])
    except:
        failed = True
    assert_true(failed)


def test_mount_alone_satisfies_the_missing_spec_rule() raises:
    """--mount IS the application spec, so no positional is required."""
    var opts = _parse([String("--mount"), String("/app=main:app")])
    assert_equal(opts.module, String(""))
    assert_equal(len(opts.mount_prefixes), 1)


def test_no_mounts_and_no_positional_still_fails() raises:
    var failed = False
    try:
        _ = _parse([String("--port"), String("8080")])
    except:
        failed = True
    assert_true(failed)


def test_match_mount_longest_prefix_wins() raises:
    var prefixes = _prefixes(String(""), String("/app"))
    assert_equal(match_mount(prefixes, String("/app/page")), 1)
    assert_equal(match_mount(prefixes, String("/app")), 1)
    assert_equal(match_mount(prefixes, String("/admin")), 0)
    assert_equal(match_mount(prefixes, String("/")), 0)


def test_match_mount_respects_segment_boundaries() raises:
    """The bug this exists to prevent: /app must not swallow /application."""
    var prefixes = _prefixes(String("/app"))
    assert_equal(match_mount(prefixes, String("/application")), -1)
    assert_equal(match_mount(prefixes, String("/app")), 0)
    assert_equal(match_mount(prefixes, String("/app/")), 0)


def test_match_mount_reports_a_miss() raises:
    var prefixes = _prefixes(String("/app"), String("/api"))
    assert_equal(match_mount(prefixes, String("/other")), -1)


def test_match_mount_order_does_not_matter() raises:
    """Longest-wins must not degrade into first-wins when the deeper mount
    is declared first."""
    var prefixes = _prefixes(String("/app"), String(""))
    assert_equal(match_mount(prefixes, String("/app/x")), 0)
    assert_equal(match_mount(prefixes, String("/elsewhere")), 1)


def test_mounted_executor_follows_detected_asgi_mounts() raises:
    """A mounted server runs executors exactly when detection found ASGI
    mounts (`asgi_mounts`, written by m0serve's resolve pass) — one per
    lane. Before detection the list is empty and no executor runs, which
    is also why `is_asgi` alone must not decide: for a mounted server it
    answers a different question."""
    var opts = _parse([String("--mount"), String("/app=main:app")])
    opts.blocking_threads = 0
    assert_false(use_asgi_executor(opts, True))
    opts.asgi_mounts.append(0)
    assert_true(use_asgi_executor(opts, True))


def test_mounted_executor_allows_several_asgi_mounts() raises:
    var opts = _parse(
        [
            String("--mount"),
            String("/a=main:app"),
            String("--mount"),
            String("/b=other:app"),
        ]
    )
    opts.blocking_threads = 0
    opts.asgi_mounts.append(0)
    opts.asgi_mounts.append(1)
    assert_true(use_asgi_executor(opts, True))


def test_unmounted_asgi_still_takes_the_executor() raises:
    var opts = _parse([String("main:app")])
    opts.blocking_threads = 0
    assert_true(use_asgi_executor(opts, True))


def test_served_names_every_mount() raises:
    var opts = _parse(
        [
            String("--mount"),
            String("/=djangoproj.wsgi"),
            String("--mount"),
            String("/app=main:app"),
        ]
    )
    assert_equal(
        opts.served(),
        String("/=djangoproj.wsgi:application,/app=main:app"),
    )


def test_served_falls_back_to_the_positional_spec() raises:
    var opts = _parse([String("djangoproj.wsgi")])
    assert_equal(opts.served(), String("djangoproj.wsgi:application"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
