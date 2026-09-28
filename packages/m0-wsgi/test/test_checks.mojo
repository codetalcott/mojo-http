"""Tests for `m0serve`'s check list: the one description of every refusal.

`main` stops at the list's first failure and `--doctor` renders all of it,
so what these pin -- which rules a configuration trips, in what order, with
what code and what line -- is what both of them do. Same charter as
`test_cli`: no interpreter, no libpq, no MAX. Every fact the list needs
arrives as a value (`CheckFacts`, the interpreter's report, the import's
outcome), which is what lets each be supplied by hand; `smoke-doctor` holds
the built binary to the same answers from the outside.

The order tests are the point. A configuration that trips two rules exits
with the FIRST one's code, which the two descriptions this replaced kept in
agreement by hand.
"""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from src.checks import (
    ServeCheck,
    CheckFacts,
    flag_checks,
    interpreter_checks,
    app_checks,
    first_refusal,
    pg_listen_needs_libpq,
    realtime_without_wsgi,
    HOLD_MOUNT_NEEDS_KEY,
    HOLD_MOUNT_NEEDS_REALTIME,
    MOUNTS_WITHOUT_PYTHON,
    COMPILED_MOUNT_UNDER_THREADS,
    PARALLEL_RUNTIME_FORKED,
    PG_LISTEN_NEEDS_REALTIME,
    PG_LISTEN_FORKED_ON_MACOS,
    REALTIME_ASGI_CONFLICT,
)
from src.cli import (
    ServeOptions,
    parse_args,
    EXIT_CONFIG,
    EXIT_STARTUP,
    EXIT_USAGE,
)
from src.threaded import (
    FreeThreadingReport,
    refusal_message,
    EXIT_NOT_FREE_THREADED,
)


comptime MISSING = "/no/such/m0serve/dir"


def _opts(args: List[String]) raises -> ServeOptions:
    """A parsed command line over the hard defaults: the environment is
    never consulted, and `--app-dir` defaults to `.`, which exists."""
    return parse_args(args, ServeOptions())


def _facts(
    macos: Bool = False, parallel_runtime: Bool = False, grant_key: Bool = True
) -> CheckFacts:
    """Facts by hand. The libpq probe, when a test wants one, is recorded on
    top (`CheckFacts.libpq`), as `m0serve`'s `_check_facts` records it."""
    return CheckFacts(macos, parallel_runtime, grant_key)


def _names(checks: List[ServeCheck]) -> String:
    var out = String("")
    for i in range(len(checks)):
        if i > 0:
            out += ","
        out += checks[i].name
    return out^


def _failed(checks: List[ServeCheck]) -> String:
    var out = String("")
    for i in range(len(checks)):
        if not checks[i].ok:
            if out.byte_length() > 0:
                out += ","
            out += checks[i].name
    return out^


def _first(checks: List[ServeCheck]) raises -> ServeCheck:
    var refused = first_refusal(checks)
    assert_true(Bool(refused), "expected a refusal in " + _names(checks))
    return refused.value().copy()


def _mounts(n: Int) raises -> ServeOptions:
    """`n` WSGI mounts, as `--mount /aN=app.wsgi` would give them."""
    var args = List[String]()
    for i in range(n):
        args.append(String("--mount"))
        args.append("/a" + String(i) + "=app.wsgi")
    return _opts(args)


def _report(free_threaded_build: Bool, gil_enabled: Bool) -> FreeThreadingReport:
    return FreeThreadingReport(String("3.14.7"), free_threaded_build, gil_enabled)


# --- the flags: before the bind ---------------------------------------------


def test_a_plain_configuration_passes_every_rule_it_meets() raises:
    """The positional spec with nothing else: the three rules that always
    apply, all passing, and nothing for the server to refuse."""
    var checks = flag_checks(_opts([String("app.wsgi")]), _facts())
    assert_equal(_names(checks), "app-dir,threads-vs-workers,workers-vs-parallel-runtime")
    assert_false(Bool(first_refusal(checks)))
    for i in range(len(checks)):
        assert_true(checks[i].ok)
        assert_equal(checks[i].code, 0)
        assert_equal(checks[i].fix, "")


def test_the_flag_rules_are_in_the_order_the_server_applies_them() raises:
    """Every rule the flags can meet, at once, in `main`'s order. A rule
    moved in the list moves for the server and the doctor together, so this
    is the gate that sees a reorder: the first failure decides the code."""
    var opts = _opts([
        String("--mount"), String("/=app.wsgi"),
        String("--mount"), String("/n=mojo"),
        String("--mount"), String("/h=hold"),
        String("--realtime"),
        String("--pg-listen"), String("postgres://db/x"),
        String("--static"), String("/s=."),
        String("--reload-dir"), String("."),
    ])
    var facts = _facts()
    facts.libpq(String(""), String("libpq 16.4 at /usr/lib/libpq.so"))
    var checks = flag_checks(opts, facts)
    assert_equal(
        _names(checks),
        "app-dir,static-dir,reload-dir,threads-vs-workers,protocol-vs-realtime,"
        + "pg-listen,mounts-without-python,hold-mount-vs-realtime,hold-mount-key,"
        + "compiled-mount-vs-threads,compiled-mount-threads,"
        + "workers-vs-parallel-runtime",
    )
    assert_false(Bool(first_refusal(checks)), _failed(checks))
    assert_equal(checks[5].detail, "libpq 16.4 at /usr/lib/libpq.so")


def test_the_directories_refuse_with_1_and_name_what_is_missing() raises:
    var checks = flag_checks(
        _opts([String("app.wsgi"), String("--app-dir"), String(MISSING)]), _facts()
    )
    var c = _first(checks)
    assert_equal(c.name, "app-dir")
    assert_equal(c.code, EXIT_STARTUP)
    assert_equal(c.detail, "app dir does not exist: " + String(MISSING))
    assert_true(c.fix.find("app.wsgi") >= 0, c.fix)
    assert_false(c.usage)
    assert_true(c.prefixed)

    c = _first(flag_checks(
        _opts([String("app.wsgi"), String("--static"), "/s=" + String(MISSING)]), _facts()
    ))
    assert_equal(c.name, "static-dir")
    assert_equal(c.code, EXIT_STARTUP)
    assert_equal(c.detail, "static dir does not exist: " + String(MISSING))

    c = _first(flag_checks(
        _opts([String("app.wsgi"), String("--reload"), String("--reload-dir"), String(MISSING)]),
        _facts(),
    ))
    assert_equal(c.name, "reload-dir")
    assert_equal(c.code, EXIT_STARTUP)
    assert_equal(c.detail, "reload dir does not exist: " + String(MISSING))


def test_two_missing_static_dirs_are_two_entries_and_the_first_is_refused() raises:
    """The server names the first; the doctor lists both."""
    var checks = flag_checks(
        _opts([
            String("app.wsgi"),
            String("--static"), String("/s=/no/such/one"),
            String("--static"), String("/t=/no/such/two"),
        ]),
        _facts(),
    )
    assert_equal(_failed(checks), "static-dir,static-dir")
    assert_equal(_first(checks).detail, "static dir does not exist: /no/such/one")


def test_the_usage_conflicts_refuse_with_2_after_printing_the_usage() raises:
    var c = _first(flag_checks(
        _opts([String("app.wsgi"), String("--workers"), String("2"), String("--threads"), String("2")]),
        _facts(),
    ))
    assert_equal(c.name, "threads-vs-workers")
    assert_equal(c.code, EXIT_USAGE)
    assert_true(c.usage)
    assert_true(c.detail.find("mutually exclusive") >= 0, c.detail)

    c = _first(flag_checks(
        _opts([String("app.wsgi"), String("--protocol"), String("asgi"), String("--realtime")]),
        _facts(),
    ))
    assert_equal(c.name, "protocol-vs-realtime")
    assert_equal(c.code, EXIT_USAGE)
    assert_true(c.usage)
    assert_equal(c.detail, String(REALTIME_ASGI_CONFLICT))


def test_pg_listen_is_one_rule_named_by_what_stops_it() raises:
    var base: List[String] = [String("app.wsgi"), String("--pg-listen"), String("postgres://db/x")]
    # Without --realtime, whatever else.
    var c = _first(flag_checks(_opts(base.copy()), _facts()))
    assert_equal(c.name, "pg-listen-vs-realtime")
    assert_equal(c.code, EXIT_USAGE)
    assert_equal(c.detail, String(PG_LISTEN_NEEDS_REALTIME))

    # A forked worker on macOS, by --workers or by --reload; not on Linux,
    # and not with --spawn-workers.
    var forked = base.copy()
    forked.append(String("--realtime"))
    forked.append(String("--workers"))
    forked.append(String("2"))
    c = _first(flag_checks(_opts(forked.copy()), _facts(macos=True)))
    assert_equal(c.name, "pg-listen-vs-fork")
    assert_equal(c.code, EXIT_USAGE)
    assert_equal(c.detail, String(PG_LISTEN_FORKED_ON_MACOS))
    var reload = base.copy()
    reload.append(String("--realtime"))
    reload.append(String("--reload"))
    assert_equal(_first(flag_checks(_opts(reload.copy()), _facts(macos=True))).name, "pg-listen-vs-fork")
    var spawned = forked.copy()
    spawned.append(String("--spawn-workers"))
    var facts = _facts(macos=True)
    assert_true(pg_listen_needs_libpq(_opts(spawned.copy()), facts))
    facts.libpq(String(""), String("libpq 16.4 at /x"))
    assert_false(Bool(first_refusal(flag_checks(_opts(spawned.copy()), facts))))
    var linux = _facts(macos=False)
    assert_true(pg_listen_needs_libpq(_opts(forked.copy()), linux))

    # The library, which the caller probes where the list reaches it.
    var fine = base.copy()
    fine.append(String("--realtime"))
    var missing = _facts()
    missing.libpq(String("libpq not found (tried /a, /b)"), String(""))
    c = _first(flag_checks(_opts(fine.copy()), missing))
    assert_equal(c.name, "pg-listen-libpq")
    assert_equal(c.code, EXIT_CONFIG)
    assert_equal(c.detail, "libpq not found (tried /a, /b)")
    # A caller that skipped the probe is refused, never passed: a listener
    # whose library was never looked for is the silent listener this is for.
    c = _first(flag_checks(_opts(fine.copy()), _facts()))
    assert_equal(c.name, "pg-listen-libpq")
    assert_equal(c.code, EXIT_CONFIG)


def test_pg_listen_needs_libpq_only_where_the_list_reaches_it() raises:
    """The server opened the library only after the two usage refusals
    passed; the caller asks this and nothing else."""
    assert_false(pg_listen_needs_libpq(_opts([String("app.wsgi")]), _facts()))
    assert_false(pg_listen_needs_libpq(
        _opts([String("app.wsgi"), String("--pg-listen"), String("x")]), _facts()
    ))
    assert_false(pg_listen_needs_libpq(
        _opts([String("app.wsgi"), String("--pg-listen"), String("x"), String("--realtime"), String("--reload")]),
        _facts(macos=True),
    ))
    assert_true(pg_listen_needs_libpq(
        _opts([String("app.wsgi"), String("--pg-listen"), String("x"), String("--realtime")]),
        _facts(macos=True),
    ))


def test_the_mount_rules_refuse_with_2() raises:
    var c = _first(flag_checks(_opts([String("--mount"), String("/native=mojo")]), _facts()))
    assert_equal(c.name, "mounts-without-python")
    assert_equal(c.code, EXIT_USAGE)
    assert_equal(c.detail, String(MOUNTS_WITHOUT_PYTHON))

    var hold: List[String] = [String("--mount"), String("/=app.wsgi"), String("--mount"), String("/s=hold")]
    c = _first(flag_checks(_opts(hold.copy()), _facts()))
    assert_equal(c.name, "hold-mount-vs-realtime")
    assert_equal(c.detail, String(HOLD_MOUNT_NEEDS_REALTIME))
    var hold_rt = hold.copy()
    hold_rt.append(String("--realtime"))
    c = _first(flag_checks(_opts(hold_rt.copy()), _facts(grant_key=False)))
    assert_equal(c.name, "hold-mount-key")
    assert_equal(c.code, EXIT_USAGE)
    assert_equal(c.detail, String(HOLD_MOUNT_NEEDS_KEY))
    assert_false(Bool(first_refusal(flag_checks(_opts(hold_rt.copy()), _facts(grant_key=True)))))

    var mojo: List[String] = [String("--mount"), String("/=app.wsgi"), String("--mount"), String("/n=mojo")]
    var threads = mojo.copy()
    threads.append(String("--threads"))
    threads.append(String("2"))
    c = _first(flag_checks(_opts(threads.copy()), _facts()))
    assert_equal(c.name, "compiled-mount-vs-threads")
    assert_equal(c.code, EXIT_USAGE)
    assert_equal(c.detail, String(COMPILED_MOUNT_UNDER_THREADS))

    var two = mojo.copy()
    two.append(String("--mount"))
    two.append(String("/m=mojo"))
    two.append(String("--blocking-threads"))
    two.append(String("1"))
    c = _first(flag_checks(_opts(two.copy()), _facts()))
    assert_equal(c.name, "compiled-mount-threads")
    assert_equal(c.code, EXIT_USAGE)
    assert_true(c.detail.find("need 2") >= 0, c.detail)
    assert_equal(c.fix, "add --blocking-threads 2 or more")
    # `--workers N` alone is not refused: the pool is the server's to size.
    var prefork = mojo.copy()
    prefork.append(String("--workers"))
    prefork.append(String("2"))
    assert_false(Bool(first_refusal(flag_checks(_opts(prefork.copy()), _facts()))))


def test_a_forked_worker_beside_the_parallel_runtime_is_refused_with_2() raises:
    var opts = _opts([String("app.wsgi"), String("--workers"), String("2")])
    var c = _first(flag_checks(opts, _facts(parallel_runtime=True)))
    assert_equal(c.name, "workers-vs-parallel-runtime")
    assert_equal(c.code, EXIT_USAGE)
    assert_equal(c.detail, String(PARALLEL_RUNTIME_FORKED))
    assert_false(Bool(first_refusal(flag_checks(opts, _facts(parallel_runtime=False)))))
    # The passing detail says why it passes: smoke-serve-parallel-runtime
    # reads "exec" out of it under --spawn-workers.
    var spawned = _opts([
        String("app.wsgi"), String("--workers"), String("2"), String("--spawn-workers"),
    ])
    var checks = flag_checks(spawned, _facts(parallel_runtime=True))
    assert_false(Bool(first_refusal(checks)))
    assert_true(checks[len(checks) - 1].detail.find("exec") >= 0, checks[len(checks) - 1].detail)


def test_the_first_failure_is_the_earliest_rule_not_the_largest_code() raises:
    """Two pairs where the codes differ, so a reorder changes the exit."""
    # A missing directory (1) before a usage conflict (2).
    var c = _first(flag_checks(
        _opts([
            String("app.wsgi"), String("--app-dir"), String(MISSING),
            String("--workers"), String("2"), String("--threads"), String("2"),
        ]),
        _facts(),
    ))
    assert_equal(c.name, "app-dir")
    assert_equal(c.code, EXIT_STARTUP)
    # An absent libpq (78) before the mount rules (2).
    var pg = _opts([
        String("--mount"), String("/native=mojo"),
        String("--realtime"), String("--pg-listen"), String("x"),
    ])
    var facts = _facts()
    facts.libpq(String("no libpq"), String(""))
    var checks = flag_checks(pg, facts)
    assert_equal(_failed(checks), "pg-listen-libpq,mounts-without-python")
    assert_equal(_first(checks).code, EXIT_CONFIG)


# --- the interpreter: before the import -------------------------------------


def test_the_threaded_guard_is_the_interpreters_one_rule() raises:
    """Empty without --threads; under it, 78 on a GIL-enabled interpreter,
    printed as `require_free_threading` always printed it -- the line names
    its package, so the server does not prefix it."""
    var single = _opts([String("app.wsgi")])
    assert_equal(len(interpreter_checks(single, _report(False, True))), 0)
    var threads = _opts([String("app.wsgi"), String("--threads"), String("4")])
    var gil = _report(False, True)
    var checks = interpreter_checks(threads, gil)
    var c = _first(checks)
    assert_equal(c.name, "free-threading")
    assert_equal(c.code, EXIT_NOT_FREE_THREADED)
    assert_equal(c.detail, refusal_message(4, gil))
    assert_false(c.prefixed)
    assert_true(c.fix.find("--workers") >= 0, c.fix)
    var ft = interpreter_checks(threads, _report(True, False))
    assert_equal(_names(ft), "free-threading")
    assert_false(Bool(first_refusal(ft)))


# --- the application: after the import --------------------------------------


def test_an_import_that_failed_is_the_whole_list() raises:
    """Every later rule would be judged against an application that is not
    there, so the doctor stops where the server does."""
    var opts = _opts([String("nosuch.wsgi"), String("--realtime")])
    var checks = app_checks(opts, String("No module named 'nosuch'"), False, None)
    assert_equal(_names(checks), "application")
    var c = _first(checks)
    assert_equal(c.code, EXIT_STARTUP)
    assert_equal(
        c.detail,
        "could not load nosuch.wsgi:application from .: No module named 'nosuch'",
    )


def test_the_application_rules_are_in_the_order_the_server_applies_them() raises:
    """All four at once: a mounted server with realtime, an ASGI mount (so
    the executor runs) and a WSGI mount the explicit pool leaves unserved,
    on a free-threaded build."""
    var opts = _opts([
        String("--mount"), String("/=app.wsgi"),
        String("--mount"), String("/b=b.wsgi"),
        String("--mount"), String("/feed=feed.asgi"),
        String("--realtime"), String("--blocking-threads"), String("1"),
    ])
    opts.asgi_mounts.append(2)
    var checks = app_checks(opts, None, True, _report(True, False))
    assert_equal(
        _names(checks),
        "application,realtime-vs-asgi,asgi-vs-free-threading,wsgi-mount-threads",
    )
    assert_equal(_failed(checks), "asgi-vs-free-threading,wsgi-mount-threads")
    var c = _first(checks)
    assert_equal(c.code, EXIT_NOT_FREE_THREADED)
    assert_true(c.detail.find("modular/modular#5726") >= 0, c.detail)
    var last = checks[len(checks) - 1].copy()
    assert_equal(last.code, EXIT_CONFIG)
    assert_true(last.detail.find("1 WSGI mount(s) would have no handler thread") >= 0, last.detail)
    assert_equal(last.fix, "add --blocking-threads 2 or more")
    # No report, no executor rule: a doctor whose probe failed invents none.
    assert_equal(
        _names(app_checks(opts, None, True, None)),
        "application,realtime-vs-asgi,wsgi-mount-threads",
    )


def test_realtime_over_an_asgi_application_is_refused_with_1() raises:
    """The detected half of `protocol-vs-realtime`, with its line, and a
    different code: the import has already run."""
    var opts = _opts([String("app.asgi"), String("--realtime")])
    var c = _first(app_checks(opts, None, True, _report(False, True)))
    assert_equal(c.name, "realtime-vs-asgi")
    assert_equal(c.code, EXIT_STARTUP)
    assert_equal(c.detail, String(REALTIME_ASGI_CONFLICT))
    assert_false(Bool(first_refusal(app_checks(opts, None, False, _report(False, True)))))


def test_realtime_without_wsgi_asks_what_a_mount_is() raises:
    assert_true(realtime_without_wsgi(_opts([String("app.asgi")]), True))
    assert_false(realtime_without_wsgi(_opts([String("app.wsgi")]), False))
    var mixed = _opts([
        String("--mount"), String("/=app.wsgi"), String("--mount"), String("/feed=feed.asgi"),
    ])
    mixed.asgi_mounts.append(1)
    assert_false(realtime_without_wsgi(mixed, True))
    # One Mojo mount and one ASGI mount: nothing could ever take a hold.
    var none = _opts([
        String("--mount"), String("/n=mojo"), String("--mount"), String("/feed=feed.asgi"),
    ])
    none.asgi_mounts.append(1)
    assert_true(realtime_without_wsgi(none, True))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
