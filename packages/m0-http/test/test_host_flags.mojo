"""The Mojo host's command line and its `--doctor` report, without a server.

What `smoke-host-doctor` proves on the wire is the contract -- the doctor
leaves with the code the server leaves with. What is proven here is what
makes that true and what the smoke would only see as a symptom: that a flag
outranks its variable, that the overlay is idempotent (it runs twice in an
application that takes `host_config()`), that only what cannot be READ is a
usage error while a count that cannot be SERVED is a refusal whichever way it
arrived, and that the report's exit code is `host_refusal`'s verdict.
"""

from std.os import setenv, unsetenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.http import HTTPRequest, HTTPResponse, OK
from m0_host.flags import HostFlags, host_usage, parse_host_flags
from m0_host.host import (
    AppHandler, HostContext, host_checks, host_refusal, host_report,
)
from m0_http.config import AppConfig
from m0_http.parallel_runtime import parallel_runtime_linked
from m0_http.multiworker import EX_CONFIG


struct Plain(AppHandler):
    def __init__(out self):
        pass

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return Plain()

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return OK("plain")


struct OneProcess(AppHandler):
    def __init__(out self):
        pass

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return OneProcess()

    @staticmethod
    def max_workers() -> Int:
        return 1

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return OK("one")


def _args(*words: String) -> List[String]:
    var out = List[String]()
    for w in words:
        out.append(String(w))
    return out^


def _parse(*words: String) raises -> HostFlags:
    var out = List[String]()
    for w in words:
        out.append(String(w))
    return parse_host_flags(out, AppConfig())


def _refused(*words: String) -> String:
    """The usage error a command line earns, or empty if it was read."""
    var out = List[String]()
    for w in words:
        out.append(String(w))
    try:
        _ = parse_host_flags(out, AppConfig())
    except e:
        return String(e)
    return String("")


def test_a_flag_outranks_its_variable_which_outranks_the_default() raises:
    """Flag > env > default, m0serve's precedence.

    covers: E30
    """
    assert_equal(_parse().config.port, 8080)
    _ = setenv("M0_PORT", "9001", True)
    _ = setenv("M0_WORKERS", "3", True)
    var env_only = _parse()
    var both = _parse("--port", "9002")
    _ = unsetenv("M0_PORT")
    _ = unsetenv("M0_WORKERS")
    assert_equal(env_only.config.port, 9001)
    assert_equal(both.config.port, 9002)
    # A variable no flag named is still read.
    assert_equal(both.config.workers, 3)


def test_both_spellings_of_a_value_are_read() raises:
    var spaced = _parse("--workers", "4", "--host", "localhost")
    var inline = _parse("--workers=4", "--host=localhost")
    assert_equal(spaced.config.workers, 4)
    assert_equal(inline.config.workers, 4)
    # `localhost` is the loopback literal, as `M0_HOST=localhost` is.
    assert_equal(spaced.config.host, "127.0.0.1")
    assert_equal(inline.config.host, "127.0.0.1")


def test_a_flag_is_as_explicit_as_its_variable() raises:
    """`--workers 1` is "one worker, and I chose that": the `*_set` word a
    zero-config default would consult is set by the flag as by the env."""
    var bare = _parse()
    assert_false(bare.config.workers_set)
    assert_false(bare.config.threads_set)
    assert_false(bare.config.blocking_threads_set)
    var said = _parse("--workers", "1", "--threads", "1", "--blocking-threads", "0")
    assert_true(said.config.workers_set)
    assert_true(said.config.threads_set)
    assert_true(said.config.blocking_threads_set)


def test_every_flag_reaches_its_field() raises:
    var f = _parse(
        "--host", "10.0.0.7", "--port", "81", "--workers", "2", "--threads", "1",
        "--blocking-threads", "3", "--sse-heartbeat-ms", "25000",
        "--app-tick-ms", "40", "--max-keepalive-requests", "0",
        "--access-log", "--qos", "--spawn-workers", "--doctor",
    )
    assert_equal(f.config.host, "10.0.0.7")
    assert_equal(f.config.port, 81)
    assert_equal(f.config.address(), "10.0.0.7:81")
    assert_equal(f.config.workers, 2)
    assert_equal(f.config.threads, 1)
    assert_equal(f.config.blocking_threads, 3)
    assert_equal(f.config.sse_heartbeat_ms, 25000)
    assert_equal(f.config.app_tick_ms, 40)
    assert_equal(f.config.max_keepalive_requests, 0)
    assert_true(f.config.access_log)
    assert_true(f.config.qos)
    assert_true(f.config.spawn_workers)
    assert_true(f.doctor)
    assert_false(f.help)
    assert_true(_parse("-h").help)
    assert_true(_parse("--help").help)


def test_a_moved_port_moves_the_base_url_unless_it_was_given() raises:
    """An application's banner prints `base_url`; it names the port bound."""
    assert_equal(_parse("--port", "9100").config.base_url, "http://localhost:9100")
    _ = setenv("M0_BASE_URL", "https://example.test", True)
    var given = _parse("--port", "9100")
    _ = unsetenv("M0_BASE_URL")
    assert_equal(given.config.base_url, "https://example.test")


def test_what_cannot_be_read_is_a_usage_error() raises:
    """Strict where the environment is lenient: each of these raises, and
    the caller answers 2 with the usage.

    covers: E30
    """
    assert_true("unknown option --prot" in _refused("--prot", "9"))
    assert_true("unknown option -p" in _refused("-p", "9"))
    assert_true("--port needs a value" in _refused("--port"))
    assert_true("must be a number" in _refused("--port", "abc"))
    assert_true("must be a number" in _refused("--workers", "2x"))
    assert_true("must be a number" in _refused("--workers", "-1"))
    assert_true("must be a number" in _refused("--workers="))
    assert_true("1-65535" in _refused("--port", "0"))
    assert_true("1-65535" in _refused("--port", "70000"))
    assert_true("--host must not be empty" in _refused("--host", " "))
    assert_true("--qos takes no value" in _refused("--qos=1"))
    assert_true("--doctor takes no value" in _refused("--doctor=json"))
    # No positionals: an application's own settings are its own variables.
    assert_true("unexpected argument 'notes.db'" in _refused("notes.db"))
    # M0_PORT=abc, by contrast, is the default port and no error.
    _ = setenv("M0_PORT", "abc", True)
    var lenient = _parse()
    _ = unsetenv("M0_PORT")
    assert_equal(lenient.config.port, 8080)


def test_a_count_that_cannot_be_served_is_a_refusal_not_a_usage_error() raises:
    """`--threads 0` is READ, then refused by the same rule `M0_THREADS=0`
    is: one path, so the two cannot be answered differently.

    covers: E31
    """
    assert_equal(_refused("--threads", "0"), "")
    assert_equal(_refused("--workers", "0"), "")
    var by_flag = host_refusal(_parse("--threads", "0").config)
    _ = setenv("M0_THREADS", "0", True)
    var by_env = host_refusal(AppConfig())
    _ = unsetenv("M0_THREADS")
    assert_true(Bool(by_flag), "--threads 0 was served")
    assert_true(Bool(by_env), "M0_THREADS=0 was served")
    assert_equal(by_flag.value(), by_env.value())
    # Every refusal names its fix, and the fix names both spellings.
    assert_true("--threads (M0_THREADS)" in by_flag.value())
    var both = host_refusal(_parse("--workers", "2", "--threads", "2").config)
    assert_true("mutually exclusive" in both.value())
    assert_true(Bool(host_refusal(_parse("--spawn-workers").config)))


def test_prefork_is_refused_when_the_parallel_runtime_is_linked() raises:
    """The verdict with the fact supplied, and the gathered fact only
    checked for consistency: under `mojo run` this test runs inside the
    compiler's process, which maps the runtime once MAX is installed
    beside the toolchain, so what `host_checks` gathers here depends on
    the venv and not on this source (SPEC E32's smoke proves the gathered
    fact on a binary that links it)."""
    var two = _parse("--workers", "2").config.copy()
    var refused = host_refusal(two, parallel_runtime=True)
    assert_true(Bool(refused), "M0_WORKERS=2 beside the parallel runtime was served")
    assert_true("--threads (M0_THREADS)" in refused.value())
    assert_true("fork" in refused.value())
    assert_false(Bool(host_refusal(two, parallel_runtime=False)))
    assert_false(Bool(host_refusal(_parse("--threads", "2").config, parallel_runtime=True)))
    assert_false(Bool(host_refusal(_parse("--workers", "1").config, parallel_runtime=True)))
    # Gathered for itself: the verdict must follow the fact this process
    # reads, whichever way the venv makes it read. The check is present
    # either way, which is what --doctor lists.
    var linked = parallel_runtime_linked()
    var checks = host_checks(two)
    var found = False
    for i in range(len(checks)):
        if checks[i].name == "workers-vs-parallel-runtime":
            found = True
            assert_equal(checks[i].ok, not linked)
            assert_true(("not linked" in checks[i].detail) == (not linked))
    assert_true(found, "workers-vs-parallel-runtime is not among host_checks")


def test_the_overlay_is_idempotent() raises:
    """`host_config()` applies the command line and `serve` applies it again."""
    var args = _args("--port", "9200", "--workers", "2", "--access-log")
    var once = parse_host_flags(args, AppConfig())
    var twice = parse_host_flags(args, once.config)
    assert_equal(twice.config.port, once.config.port)
    assert_equal(twice.config.base_url, once.config.base_url)
    assert_equal(twice.config.workers, once.config.workers)
    assert_equal(twice.config.workers_set, once.config.workers_set)
    assert_equal(twice.config.access_log, once.config.access_log)


def test_only_a_given_flag_outranks_tuning_the_application_set_in_code() raises:
    """`serve(config, server_config)`: `apps/sim_loop` sets its own tick."""
    var quiet = _parse("--port", "9300")
    var sc = quiet.config.server_config()
    sc.app_tick_ms = 50
    sc.sse_heartbeat_ms = 1234
    quiet.apply_to(sc)
    assert_equal(sc.app_tick_ms, 50)
    assert_equal(sc.sse_heartbeat_ms, 1234)
    var said = _parse("--app-tick-ms", "10", "--access-log", "--max-keepalive-requests", "7")
    said.apply_to(sc)
    assert_equal(sc.app_tick_ms, 10)
    assert_equal(sc.sse_heartbeat_ms, 1234)
    assert_true(sc.access_log)
    assert_equal(sc.max_keepalive_requests, 7)


def test_the_report_says_where_each_value_came_from() raises:
    _ = setenv("M0_WORKERS", "2", True)
    var f = _parse("--port", "9400")
    var port = f.source("--port")
    var workers = f.source("--workers")
    var threads = f.source("--threads")
    _ = unsetenv("M0_WORKERS")
    assert_equal(port, "flag")
    assert_equal(workers, "env")
    assert_equal(threads, "default")


def test_the_checks_are_whole_and_in_the_order_serve_refuses() raises:
    """`host_refusal` is the FIRST failed check, so a configuration that
    trips two is reported by the doctor as the one the server would hit.

    covers: E31
    """
    var clean = host_checks(AppConfig())
    assert_equal(len(clean), 8)
    for i in range(len(clean)):
        assert_true(clean[i].ok, clean[i].name + " failed on a default config")
        assert_equal(clean[i].fix, "")
    assert_equal(clean[0].name, "workers-count")
    assert_equal(clean[3].name, "workers-vs-threads")
    # Two failures: too many workers for the app, and both modes at once.
    var two = host_checks(_parse("--workers", "2", "--threads", "2").config, 1)
    assert_equal(len(two), 8)
    assert_false(two[1].ok)
    assert_false(two[3].ok)
    var first = host_refusal(_parse("--workers", "2", "--threads", "2").config, 1)
    assert_true(two[1].detail in first.value())
    assert_true("M0_WORKERS=2" in first.value())


def test_the_doctor_leaves_with_the_servers_code() raises:
    """0 where `serve` would bind, 78 where it would refuse -- from the same
    checks -- and the application's own limit is part of it. The parallel
    runtime's fact is pinned to "not linked", since under `mojo run` the
    process may map it whatever this source imports.

    covers: E31
    """
    var ok = _parse("--workers", "2", "--blocking-threads", "3")
    var served = host_report[Plain](ok, ok.config.server_config(), parallel_runtime=False)
    assert_equal(served.exit_code(), 0)
    assert_true(served.ok())
    var text = served.render()
    assert_true(text.startswith('{"m0_host":"1","ok":true,"exit":0'), text)
    assert_true('"mode":"prefork"' in text, text)
    assert_true('"loops":2' in text, text)
    assert_true('"handler_threads":6' in text, text)
    assert_true('"workers":"flag"' in text, text)
    assert_true('"threads":"default"' in text, text)

    # The same line against an application whose state is one process's.
    var refused = host_report[OneProcess](ok, ok.config.server_config())
    assert_equal(refused.exit_code(), EX_CONFIG)
    var why = refused.render()
    assert_true('"ok":false,"exit":78' in why, why)
    assert_true('"name":"workers-vs-application","ok":false' in why, why)
    assert_true('"fix":"set --workers (M0_WORKERS) to 1 or fewer"' in why, why)
    assert_true('"max_workers":1' in why, why)

    var threads = _parse("--threads", "4")
    var t = host_report[Plain](threads, threads.config.server_config(), parallel_runtime=False).render()
    assert_true('"mode":"threads"' in t, t)
    assert_true('"loops":4' in t, t)
    var one = _parse()
    assert_true(
        '"mode":"single"' in host_report[Plain](one, one.config.server_config(), parallel_runtime=False).render()
    )


def test_the_doctor_never_prints_the_api_key() raises:
    _ = setenv("M0_API_KEY", "hunter2-do-not-print", True)
    var f = _parse()
    _ = unsetenv("M0_API_KEY")
    assert_equal(f.config.api_key, "hunter2-do-not-print")
    var text = host_report[Plain](f, f.config.server_config()).render()
    assert_false("hunter2" in text, text)


def test_the_usage_names_every_flag_and_its_variable() raises:
    var text = host_usage("server")
    var flags = _args(
        "--host", "--port", "--workers", "--threads", "--blocking-threads",
        "--access-log", "--sse-heartbeat-ms", "--app-tick-ms",
        "--max-keepalive-requests", "--qos", "--spawn-workers", "--doctor",
        "--help",
    )
    for i in range(len(flags)):
        assert_true(flags[i] in text, flags[i] + " is missing from the usage")
        # ...and every one of them parses: the usage and the parser agree.
        if flags[i] != "--help" and flags[i] != "--doctor":
            assert_true(
                "unknown option" not in _refused(flags[i], "1"),
                flags[i] + " is in the usage and unknown to the parser",
            )
    assert_true("M0_MAX_KEEPALIVE_REQUESTS" in text)
    assert_true(text.startswith("usage: server [OPTIONS]"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
