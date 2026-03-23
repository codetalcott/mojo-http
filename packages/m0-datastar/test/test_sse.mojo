"""Tests for Datastar SSE event generation."""

from std.testing import assert_equal, assert_true, assert_false

from src.sse import patch_elements, patch_signals, execute_script, redirect


def test_patch_elements_basic() raises:
    """Basic patch_elements should include event type and elements data."""
    var s = patch_elements("<div>Hello</div>")
    assert_true(s.find("event: datastar-patch-elements") >= 0)
    assert_true(s.find("data: elements <div>Hello</div>") >= 0)


def test_patch_elements_with_selector() raises:
    """patch_elements with selector should include selector dataline."""
    var s = patch_elements("<p>Hi</p>", selector="#content")
    assert_true(s.find("data: selector #content") >= 0)


def test_patch_elements_inner_mode() raises:
    """patch_elements with inner mode should include mode dataline."""
    var s = patch_elements("<span>X</span>", mode="inner")
    assert_true(s.find("data: mode inner") >= 0)


def test_patch_elements_with_namespace() raises:
    """patch_elements with SVG namespace should include namespace dataline."""
    var s = patch_elements("<circle/>", namespace="svg")
    assert_true(s.find("data: namespace svg") >= 0)


def test_patch_elements_with_view_transition() raises:
    """patch_elements with view transition should include the flag."""
    var s = patch_elements("<div/>", use_view_transition=True)
    assert_true(s.find("data: useViewTransition true") >= 0)


def test_patch_elements_no_view_transition_by_default() raises:
    """Default patch_elements should not include useViewTransition."""
    var s = patch_elements("<div/>")
    assert_true(s.find("useViewTransition") == -1)


def test_patch_elements_with_event_id() raises:
    """Event ID should appear in SSE output."""
    var s = patch_elements("<div/>", event_id="evt-1")
    assert_true(s.find("id: evt-1") >= 0)


def test_patch_elements_multiline() raises:
    """Multi-line HTML should produce multiple elements data lines."""
    var s = patch_elements("<div>\n  <p>Hi</p>\n</div>")
    # Each line gets its own data: elements line
    assert_true(s.find("data: elements <div>") >= 0)
    assert_true(s.find("data: elements   <p>Hi</p>") >= 0)
    assert_true(s.find("data: elements </div>") >= 0)


def test_patch_signals_basic() raises:
    """Basic patch_signals should include event type and signals data."""
    var s = patch_signals('{"count": 1}')
    assert_true(s.find("event: datastar-patch-signals") >= 0)
    assert_true(s.find('data: signals {"count": 1}') >= 0)


def test_patch_signals_only_if_missing() raises:
    """patch_signals with only_if_missing should include the flag."""
    var s = patch_signals('{"x": 1}', only_if_missing=True)
    assert_true(s.find("data: onlyIfMissing true") >= 0)


def test_patch_signals_no_only_if_missing_by_default() raises:
    """Default patch_signals should not include onlyIfMissing."""
    var s = patch_signals('{"x": 1}')
    assert_true(s.find("onlyIfMissing") == -1)


def test_patch_signals_with_event_id() raises:
    """Event ID should appear in patch_signals output."""
    var s = patch_signals('{}', event_id="sig-1")
    assert_true(s.find("id: sig-1") >= 0)


def test_execute_script_basic() raises:
    """execute_script should wrap in script element with auto-remove."""
    var s = execute_script("console.log('hi')")
    assert_true(s.find("event: datastar-patch-elements") >= 0)
    assert_true(s.find("data-effect='el.remove()'") >= 0)
    assert_true(s.find("console.log('hi')") >= 0)
    assert_true(s.find("</script>") >= 0)


def test_execute_script_targets_body() raises:
    """execute_script should target body with append mode."""
    var s = execute_script("alert(1)")
    assert_true(s.find("data: selector body") >= 0)
    assert_true(s.find("data: mode append") >= 0)


def test_redirect() raises:
    """redirect should generate a script with window.location."""
    var s = redirect("/new-page")
    assert_true(s.find("window.location = '/new-page'") >= 0)
    assert_true(s.find("setTimeout") >= 0)


def test_custom_retry_duration() raises:
    """Non-default retry duration should appear in SSE output."""
    var s = patch_signals('{}', retry_duration=5000)
    assert_true(s.find("retry: 5000") >= 0)


def test_default_retry_duration_omitted() raises:
    """Default retry duration (1000) should not appear in output."""
    var s = patch_signals('{}', retry_duration=1000)
    assert_true(s.find("retry:") == -1)


def test_sse_ends_with_double_newline() raises:
    """SSE events must end with double newline."""
    var s = patch_elements("<div/>")
    assert_true(s.endswith("\n\n"))
