"""Tests for Datastar protocol constants."""

from std.testing import assert_equal, assert_true, TestSuite

from src.consts import (
    VERSION,
    DATASTAR_KEY,
    DEFAULT_SSE_RETRY_DURATION,
    DEFAULT_PATCH_MODE,
    PATCH_MODE_OUTER,
    PATCH_MODE_INNER,
    PATCH_MODE_REMOVE,
    PATCH_MODE_REPLACE,
    PATCH_MODE_PREPEND,
    PATCH_MODE_APPEND,
    PATCH_MODE_BEFORE,
    PATCH_MODE_AFTER,
    EVENT_PATCH_ELEMENTS,
    EVENT_PATCH_SIGNALS,
    DL_SELECTOR,
    DL_MODE,
    DL_ELEMENTS,
    DL_SIGNALS,
    DL_NAMESPACE,
    DL_ONLY_IF_MISSING,
    DL_USE_VIEW_TRANSITION,
    DL_VIEW_TRANSITION_SELECTOR,
    NS_SVG,
    NS_MATHML,
    js_bool,
)


def test_version() raises:
    """Version should be 1.0.2."""
    assert_equal(VERSION, "1.0.2")


def test_event_types() raises:
    """Event types should follow datastar- prefix convention."""
    assert_equal(EVENT_PATCH_ELEMENTS, "datastar-patch-elements")
    assert_equal(EVENT_PATCH_SIGNALS, "datastar-patch-signals")


def test_patch_modes() raises:
    """All 8 patch modes should be defined."""
    assert_equal(PATCH_MODE_OUTER, "outer")
    assert_equal(PATCH_MODE_INNER, "inner")
    assert_equal(PATCH_MODE_REMOVE, "remove")
    assert_equal(PATCH_MODE_REPLACE, "replace")
    assert_equal(PATCH_MODE_PREPEND, "prepend")
    assert_equal(PATCH_MODE_APPEND, "append")
    assert_equal(PATCH_MODE_BEFORE, "before")
    assert_equal(PATCH_MODE_AFTER, "after")
    assert_equal(DEFAULT_PATCH_MODE, "outer")


def test_dataline_literals_have_trailing_space() raises:
    """Dataline literals should include trailing space per protocol spec."""
    assert_true(DL_SELECTOR.endswith(" "))
    assert_true(DL_MODE.endswith(" "))
    assert_true(DL_ELEMENTS.endswith(" "))
    assert_true(DL_SIGNALS.endswith(" "))
    assert_true(DL_NAMESPACE.endswith(" "))
    assert_true(DL_ONLY_IF_MISSING.endswith(" "))
    assert_true(DL_USE_VIEW_TRANSITION.endswith(" "))
    assert_true(DL_VIEW_TRANSITION_SELECTOR.endswith(" "))


def test_view_transition_selector_literal() raises:
    """The viewTransitionSelector dataline was added to the protocol in v1.0.2."""
    assert_equal(DL_VIEW_TRANSITION_SELECTOR, "viewTransitionSelector ")


def test_namespaces() raises:
    """SVG and MathML namespaces should be defined."""
    assert_equal(NS_SVG, "svg")
    assert_equal(NS_MATHML, "mathml")


def test_js_bool() raises:
    """`js_bool` should convert Bool to JavaScript string."""
    assert_equal(js_bool(True), "true")
    assert_equal(js_bool(False), "false")


def test_retry_duration() raises:
    """Default retry duration should be 1000ms."""
    assert_equal(DEFAULT_SSE_RETRY_DURATION, 1000)

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
