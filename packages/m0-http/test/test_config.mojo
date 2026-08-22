"""Tests for M0_-prefixed environment configuration.

These run in one process and mutate the environment, so every test sets the
variables it cares about *and* clears the rest — otherwise a value set by an
earlier test decides a later one, and the order the runner happens to pick
becomes part of the contract.

The behaviour worth pinning is what happens to bad input. A server reads these
at startup and cannot ask again, so `_parse_int_env` swallows anything
unparseable and returns the default. That is a defensible choice and a
surprising one: `M0_PORT=80eighty` silently serves on 8080 rather than
refusing to start.
"""

from std.os import setenv
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src.config import AppConfig, threads_conflict
from lightbug_http.server_config import ServerConfig


def _clear():
    """Empty every M0_ variable. The loader treats empty as unset."""
    for name in [
        String("M0_HOST"),
        String("M0_PORT"),
        String("M0_BASE_URL"),
        String("M0_API_KEY"),
        String("M0_WORKERS"),
        String("M0_THREADS"),
        String("M0_ACCESS_LOG"),
        String("M0_SSE_HEARTBEAT_MS"),
        String("M0_APP_TICK_MS"),
    ]:
        _ = setenv(name, "", True)


def _with(name: String, value: String) raises -> AppConfig:
    _clear()
    _ = setenv(name, value, True)
    return AppConfig()


def test_defaults_when_nothing_is_set() raises:
    _clear()
    var c = AppConfig()
    assert_equal(c.port, 8080)
    assert_equal(c.workers, 1)
    assert_equal(c.api_key, "")
    assert_false(c.access_log)
    assert_equal(c.base_url, "http://localhost:8080")


def test_default_port_argument_is_honoured() raises:
    _clear()
    var c = AppConfig(9999)
    assert_equal(c.port, 9999)
    assert_equal(c.base_url, "http://localhost:9999")


def test_port_is_read_from_the_environment() raises:
    var c = _with("M0_PORT", "3000")
    assert_equal(c.port, 3000)
    assert_equal(c.base_url, "http://localhost:3000")


def test_a_non_numeric_port_falls_back_to_the_default() raises:
    var c = _with("M0_PORT", "80eighty")
    assert_equal(c.port, 8080)


def test_a_negative_port_falls_back_to_the_default() raises:
    """The '-' is not a digit, so this takes the same path as any junk."""
    var c = _with("M0_PORT", "-1")
    assert_equal(c.port, 8080)


def test_workers_is_read_from_the_environment() raises:
    var c = _with("M0_WORKERS", "4")
    assert_equal(c.workers, 4)


def test_threads_defaults_to_one() raises:
    _clear()
    assert_equal(AppConfig().threads, 1)


def test_threads_is_read_from_the_environment() raises:
    assert_equal(_with("M0_THREADS", "4").threads, 4)


def test_a_non_numeric_threads_falls_back_to_one() raises:
    assert_equal(_with("M0_THREADS", "four").threads, 1)


def test_threads_and_workers_conflict_only_when_both_exceed_one() raises:
    """One of each mode is the default and fine; asking for both is not."""
    assert_true(threads_conflict(2, 2))
    assert_true(threads_conflict(4, 2))
    assert_false(threads_conflict(1, 4))
    assert_false(threads_conflict(4, 1))
    assert_false(threads_conflict(1, 1))
    var msg = threads_conflict(2, 3)
    assert_true(msg.value().find("mutually exclusive") >= 0)
    assert_true(msg.value().find("workers=2") >= 0)
    assert_true(msg.value().find("threads=3") >= 0)


def test_api_key_is_taken_verbatim() raises:
    var c = _with("M0_API_KEY", "  sk-with-spaces  ")
    assert_equal(c.api_key, "  sk-with-spaces  ")


def test_base_url_overrides_the_derived_default() raises:
    var c = _with("M0_BASE_URL", "https://api.example.com")
    assert_equal(c.base_url, "https://api.example.com")


def test_base_url_is_derived_from_the_configured_port() raises:
    _clear()
    _ = setenv("M0_PORT", "1234", True)
    var c = AppConfig()
    assert_equal(c.base_url, "http://localhost:1234")


def test_access_log_accepts_true_and_one() raises:
    assert_true(_with("M0_ACCESS_LOG", "true").access_log)
    assert_true(_with("M0_ACCESS_LOG", "1").access_log)


def test_access_log_is_case_sensitive() raises:
    """Documents a sharp edge: "TRUE" and "yes" both leave logging off."""
    assert_false(_with("M0_ACCESS_LOG", "TRUE").access_log)
    assert_false(_with("M0_ACCESS_LOG", "yes").access_log)
    assert_false(_with("M0_ACCESS_LOG", "0").access_log)


def test_sse_heartbeat_defaults_to_fifteen_seconds() raises:
    _clear()
    assert_equal(AppConfig().sse_heartbeat_ms, 15000)


def test_sse_heartbeat_is_read_from_the_environment() raises:
    assert_equal(_with("M0_SSE_HEARTBEAT_MS", "500").sse_heartbeat_ms, 500)


def test_sse_heartbeat_zero_disables() raises:
    """0 is a valid value, not junk: it turns heartbeats off entirely."""
    assert_equal(_with("M0_SSE_HEARTBEAT_MS", "0").sse_heartbeat_ms, 0)


def test_app_tick_defaults_to_off() raises:
    """The tick is opt-in: 0 means the hook never fires."""
    _clear()
    assert_equal(AppConfig().app_tick_ms, 0)


def test_app_tick_is_read_from_the_environment() raises:
    assert_equal(_with("M0_APP_TICK_MS", "1000").app_tick_ms, 1000)


def test_address_binds_all_interfaces() raises:
    var c = _with("M0_PORT", "8081")
    assert_equal(c.host, "0.0.0.0")
    assert_equal(c.address(), "0.0.0.0:8081")


def test_host_is_read_from_the_environment() raises:
    _clear()
    _ = setenv("M0_HOST", "127.0.0.1", True)
    _ = setenv("M0_PORT", "8081", True)
    var c = AppConfig()
    assert_equal(c.host, "127.0.0.1")
    assert_equal(c.address(), "127.0.0.1:8081")
    _clear()


def test_host_localhost_means_loopback() raises:
    """The listener is IPv4-only and resolves nothing; the one name everyone
    types is mapped by hand so it binds rather than fails."""
    var c = _with("M0_HOST", "localhost")
    assert_equal(c.host, "127.0.0.1")


def test_host_is_trimmed_and_otherwise_verbatim() raises:
    assert_equal(_with("M0_HOST", " 10.0.0.5 ").host, "10.0.0.5")
    assert_equal(_with("M0_HOST", "   ").host, "0.0.0.0")


def test_config_is_copyable_and_movable() raises:
    """AppConfig is passed by value into handlers; both paths must hold."""
    _clear()
    _ = setenv("M0_HOST", "127.0.0.1", True)
    _ = setenv("M0_PORT", "4242", True)
    var c = AppConfig()
    var copied = c.copy()
    assert_equal(copied.port, 4242)
    assert_equal(copied.host, "127.0.0.1")
    assert_equal(copied.base_url, "http://localhost:4242")
    var moved = copied^
    assert_equal(moved.port, 4242)
    assert_equal(moved.address(), "127.0.0.1:4242")
    assert_equal(moved.threads, 1)
    _clear()


# --- the AppConfig -> ServerConfig mapping ---------------------------------
#
# Every app used to copy these fields across by hand, each a different subset,
# and two copied none — so M0_ACCESS_LOG silently did nothing in notes_api and
# hello. `server_config()` is the single mapping; these are what stop it
# drifting back.


def test_server_config_carries_every_shared_field() raises:
    _clear()
    _ = setenv("M0_ACCESS_LOG", "1", True)
    _ = setenv("M0_SSE_HEARTBEAT_MS", "700", True)
    _ = setenv("M0_APP_TICK_MS", "250", True)
    var config = AppConfig()
    var sc = config.server_config()
    assert_true(sc.access_log)
    assert_equal(sc.sse_heartbeat_ms, 700)
    assert_equal(sc.app_tick_ms, 250)
    _clear()


def test_server_config_reflects_the_off_settings_too() raises:
    # A mapping that only ever ORs values in would pass the test above while
    # ignoring a deliberate "off".
    _clear()
    _ = setenv("M0_SSE_HEARTBEAT_MS", "0", True)
    var config = AppConfig()
    var sc = config.server_config()
    assert_false(sc.access_log)
    assert_equal(sc.sse_heartbeat_ms, 0)
    assert_equal(sc.app_tick_ms, 0)
    _clear()


def test_server_config_leaves_server_only_tuning_at_defaults() raises:
    # The environment is not allowed to reach connection limits or body caps;
    # those stay wherever ServerConfig() puts them.
    _clear()
    _ = setenv("M0_ACCESS_LOG", "true", True)
    var mapped = AppConfig().server_config()
    var plain = ServerConfig()
    assert_equal(mapped.max_connections, plain.max_connections)
    assert_equal(mapped.max_keepalive_requests, plain.max_keepalive_requests)
    assert_equal(mapped.socket_buffer_size, plain.socket_buffer_size)
    assert_equal(mapped.max_request_body_size, plain.max_request_body_size)
    assert_equal(mapped.header_read_timeout, plain.header_read_timeout)
    assert_equal(mapped.idle_timeout, plain.idle_timeout)
    _clear()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
