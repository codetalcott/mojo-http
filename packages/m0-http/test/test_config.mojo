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

from src.config import AppConfig


def _clear():
    """Empty every M0_ variable. The loader treats empty as unset."""
    for name in [
        String("M0_PORT"),
        String("M0_BASE_URL"),
        String("M0_API_KEY"),
        String("M0_WORKERS"),
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
    assert_equal(c.address(), "0.0.0.0:8081")


def test_config_is_copyable_and_movable() raises:
    """AppConfig is passed by value into handlers; both paths must hold."""
    var c = _with("M0_PORT", "4242")
    var copied = c.copy()
    assert_equal(copied.port, 4242)
    assert_equal(copied.base_url, "http://localhost:4242")
    var moved = copied^
    assert_equal(moved.port, 4242)
    _clear()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
