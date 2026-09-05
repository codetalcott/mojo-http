"""Tests for Datastar SSE event generation."""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src.sse import (
    patch_elements,
    patch_signals,
    execute_script,
    redirect,
    split_data_lines,
)


def test_patch_elements_basic() raises:
    """Basic patch_elements should include event type and elements data."""
    var s = patch_elements("<div>Hello</div>")
    assert_true(s.find("event: datastar-patch-elements") >= 0)
    assert_true(s.find("data: elements <div>Hello</div>") >= 0)


def test_patch_elements_with_selector() raises:
    """`patch_elements` with selector should include selector dataline."""
    var s = patch_elements("<p>Hi</p>", selector="#content")
    assert_true(s.find("data: selector #content") >= 0)


def test_patch_elements_inner_mode() raises:
    """`patch_elements` with inner mode should include mode dataline."""
    var s = patch_elements("<span>X</span>", mode="inner")
    assert_true(s.find("data: mode inner") >= 0)


def test_patch_elements_default_mode_omitted() raises:
    """The default `outer` mode must not be emitted (SDK spec: non-defaults only)."""
    var s = patch_elements("<div>Merge</div>")
    assert_true(s.find("mode") == -1)


def test_patch_elements_default_namespace_omitted() raises:
    """The default `html` namespace must not be emitted."""
    var s = patch_elements("<div/>", namespace="html")
    assert_true(s.find("namespace") == -1)


def test_patch_elements_view_transition_selector() raises:
    """The viewTransitionSelector line is emitted when view transitions are on."""
    var s = patch_elements(
        "<div/>", use_view_transition=True, view_transition_selector="#main"
    )
    assert_true(s.find("data: useViewTransition true") >= 0)
    assert_true(s.find("data: viewTransitionSelector #main") >= 0)


def test_view_transition_selector_requires_view_transition() raises:
    """Without useViewTransition the selector is meaningless, so it is dropped."""
    var s = patch_elements("<div/>", view_transition_selector="#main")
    assert_true(s.find("viewTransitionSelector") == -1)


def test_patch_elements_with_namespace() raises:
    """`patch_elements` with SVG namespace should include namespace dataline."""
    var s = patch_elements("<circle/>", namespace="svg")
    assert_true(s.find("data: namespace svg") >= 0)


def test_patch_elements_with_view_transition() raises:
    """`patch_elements` with view transition should include the flag."""
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
    """`patch_signals` with only_if_missing should include the flag."""
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
    """`execute_script` should wrap in script element with auto-remove."""
    var s = execute_script("console.log('hi')")
    assert_true(s.find("event: datastar-patch-elements") >= 0)
    assert_true(s.find('data-effect="el.remove()"') >= 0)
    assert_true(s.find("console.log('hi')") >= 0)
    assert_true(s.find("</script>") >= 0)


def test_execute_script_targets_body() raises:
    """`execute_script` should target body with append mode."""
    var s = execute_script("alert(1)")
    assert_true(s.find("data: selector body") >= 0)
    assert_true(s.find("data: mode append") >= 0)


def test_redirect() raises:
    """`redirect` should generate a script with window.location."""
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


def test_field_order_event_before_id() raises:
    """The SDK spec mandates event, then id, then retry, then data lines."""
    var s = patch_signals("{}", event_id="e1", retry_duration=2000)
    var event_at = s.find("event: ")
    var id_at = s.find("id: ")
    var retry_at = s.find("retry: ")
    var data_at = s.find("data: ")
    assert_true(event_at < id_at)
    assert_true(id_at < retry_at)
    assert_true(retry_at < data_at)


# --- Conformance cases -------------------------------------------------------
# Byte-exact expectations copied from the official SDK test suite at v1.0.2:
# https://github.com/starfederation/datastar/tree/v1.0.2/sdk/test/get-cases


def test_conformance_patch_elements_with_defaults() raises:
    """Matches sdk/test/get-cases/patchElementsWithDefaults/output.txt."""
    var s = patch_elements("<div>Merge</div>", mode="outer", use_view_transition=False)
    assert_equal(
        s, "event: datastar-patch-elements\ndata: elements <div>Merge</div>\n\n"
    )


def test_conformance_patch_elements_with_all_options() raises:
    """Matches sdk/test/get-cases/patchElementsWithAllOptions/output.txt."""
    var s = patch_elements(
        "<div>Merge</div>",
        selector="div",
        mode="append",
        use_view_transition=True,
        event_id="event1",
        retry_duration=2000,
    )
    assert_equal(
        s,
        "event: datastar-patch-elements\n"
        "id: event1\n"
        "retry: 2000\n"
        "data: selector div\n"
        "data: mode append\n"
        "data: useViewTransition true\n"
        "data: elements <div>Merge</div>\n"
        "\n",
    )


def test_conformance_patch_signals_with_defaults() raises:
    """Matches sdk/test/get-cases/patchSignalsWithDefaults/output.txt."""
    var s = patch_signals('{"one":1,"two":2}', only_if_missing=False)
    assert_equal(
        s, 'event: datastar-patch-signals\ndata: signals {"one":1,"two":2}\n\n'
    )


def test_conformance_patch_signals_with_all_options() raises:
    """Matches sdk/test/get-cases/patchSignalsWithAllOptions/output.txt."""
    var s = patch_signals(
        '{"one":1,"two":2}',
        event_id="event1",
        only_if_missing=True,
        retry_duration=2000,
    )
    assert_equal(
        s,
        "event: datastar-patch-signals\n"
        "id: event1\n"
        "retry: 2000\n"
        "data: onlyIfMissing true\n"
        'data: signals {"one":1,"two":2}\n'
        "\n",
    )


def test_conformance_execute_script_with_defaults() raises:
    """Matches sdk/test/get-cases/executeScriptWithDefaults/output.txt.

    The reference fixture emits `mode` before `selector`; datalines are parsed
    into a key/value map client-side, so this asserts content, not byte order.
    """
    var s = execute_script("console.log('hello');")
    assert_true(s.find("event: datastar-patch-elements") >= 0)
    assert_true(s.find("data: mode append") >= 0)
    assert_true(s.find("data: selector body") >= 0)
    assert_true(
        s.find(
            "data: elements <script"
            ' data-effect="el.remove()">console.log(\'hello\');</script>'
        )
        >= 0
    )

def test_split_data_lines_handles_all_terminators() raises:
    """CRLF, bare CR, and LF all terminate a line per the SSE spec."""
    assert_equal(len(split_data_lines("a\r\nb")), 2)
    assert_equal(len(split_data_lines("a\rb")), 2)
    assert_equal(len(split_data_lines("a\nb")), 2)


def test_patch_elements_bare_cr_does_not_escape_data_field() raises:
    """A CR inside elements must not inject a raw break into the frame."""
    var s = patch_elements("<p>a</p>\r<p>b</p>")
    assert_true(s.find("data: elements <p>a</p>\n") >= 0)
    assert_true(s.find("data: elements <p>b</p>\n") >= 0)


def test_patch_elements_crlf_leaves_no_stray_cr() raises:
    """Windows-authored templates must not leak CR onto the wire."""
    var s = patch_elements("<div>\r\n  <p>hi</p>\r\n</div>")
    assert_false(s.find("\r") >= 0)
    assert_true(s.find("data: elements <div>\n") >= 0)
    assert_true(s.find("data: elements   <p>hi</p>\n") >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
