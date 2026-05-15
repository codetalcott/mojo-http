"""Tests for m0-http health module."""

from m0_http.health import HealthRegistry
from std.testing import assert_true, assert_false, assert_equal, TestSuite


def test_health_empty_ready() raises:
    """Empty registry is ready."""
    var h = HealthRegistry()
    assert_true(h.is_ready())


def test_health_register_healthy() raises:
    """Registered healthy check passes."""
    var h = HealthRegistry()
    h.register("store", True)
    assert_true(h.is_ready())


def test_health_register_unhealthy() raises:
    """Registered unhealthy check fails readiness."""
    var h = HealthRegistry()
    h.register("store", False)
    assert_false(h.is_ready())


def test_health_set_update() raises:
    """set() updates an existing check."""
    var h = HealthRegistry()
    h.register("db", True)
    assert_true(h.is_ready())
    h.set("db", False)
    assert_false(h.is_ready())


def test_health_shutting_down() raises:
    """Shutting down overrides healthy checks."""
    var h = HealthRegistry()
    h.register("store", True)
    h.shutting_down = True
    assert_false(h.is_ready())


def test_health_ready_status_code_200() raises:
    """Ready returns 200."""
    var h = HealthRegistry()
    assert_equal(h.ready_status_code(), 200)


def test_health_ready_status_code_503() raises:
    """Not ready returns 503."""
    var h = HealthRegistry()
    h.shutting_down = True
    assert_equal(h.ready_status_code(), 503)


def test_health_to_json_ok() raises:
    """to_json with all healthy shows ok."""
    var h = HealthRegistry()
    h.register("store", True)
    var json = h.to_json()
    assert_true('"status":"ok"' in json)
    assert_true('"store":true' in json)


def test_health_to_json_degraded() raises:
    """to_json with unhealthy check shows degraded."""
    var h = HealthRegistry()
    h.register("store", True)
    h.register("cache", False)
    var json = h.to_json()
    assert_true('"status":"degraded"' in json)
    assert_true('"cache":false' in json)


def test_health_to_json_shutting_down() raises:
    """to_json during shutdown shows shutting_down."""
    var h = HealthRegistry()
    h.shutting_down = True
    var json = h.to_json()
    assert_true('"status":"shutting_down"' in json)

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
