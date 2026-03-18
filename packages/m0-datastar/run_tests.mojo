"""Test runner for m0-datastar (Datastar SSE protocol)."""

# --- Constants tests ---
from test.test_consts import (
    test_version,
    test_event_types,
    test_patch_modes,
    test_dataline_literals_have_trailing_space,
    test_namespaces,
    test_js_bool,
    test_retry_duration,
)

# --- SSE tests ---
from test.test_sse import (
    test_patch_elements_basic,
    test_patch_elements_with_selector,
    test_patch_elements_inner_mode,
    test_patch_elements_with_namespace,
    test_patch_elements_with_view_transition,
    test_patch_elements_no_view_transition_by_default,
    test_patch_elements_with_event_id,
    test_patch_elements_multiline,
    test_patch_signals_basic,
    test_patch_signals_only_if_missing,
    test_patch_signals_no_only_if_missing_by_default,
    test_patch_signals_with_event_id,
    test_execute_script_basic,
    test_execute_script_targets_body,
    test_redirect,
    test_custom_retry_duration,
    test_default_retry_duration_omitted,
    test_sse_ends_with_double_newline,
)


fn _run(name: String, func: fn () raises -> None, mut passed: Int, mut failed: Int):
    try:
        func()
        print("  PASS:", name)
        passed += 1
    except e:
        print("  FAIL:", name, "-", e)
        failed += 1


fn main() raises:
    var passed = 0
    var failed = 0

    print("\n=== Datastar Constants ===")
    _run("version", test_version, passed, failed)
    _run("event_types", test_event_types, passed, failed)
    _run("patch_modes", test_patch_modes, passed, failed)
    _run("dataline_literals_trailing_space", test_dataline_literals_have_trailing_space, passed, failed)
    _run("namespaces", test_namespaces, passed, failed)
    _run("js_bool", test_js_bool, passed, failed)
    _run("retry_duration", test_retry_duration, passed, failed)

    print("\n=== Datastar SSE ===")
    _run("patch_elements_basic", test_patch_elements_basic, passed, failed)
    _run("patch_elements_with_selector", test_patch_elements_with_selector, passed, failed)
    _run("patch_elements_inner_mode", test_patch_elements_inner_mode, passed, failed)
    _run("patch_elements_with_namespace", test_patch_elements_with_namespace, passed, failed)
    _run("patch_elements_with_view_transition", test_patch_elements_with_view_transition, passed, failed)
    _run("patch_elements_no_view_transition_by_default", test_patch_elements_no_view_transition_by_default, passed, failed)
    _run("patch_elements_with_event_id", test_patch_elements_with_event_id, passed, failed)
    _run("patch_elements_multiline", test_patch_elements_multiline, passed, failed)
    _run("patch_signals_basic", test_patch_signals_basic, passed, failed)
    _run("patch_signals_only_if_missing", test_patch_signals_only_if_missing, passed, failed)
    _run("patch_signals_no_only_if_missing_by_default", test_patch_signals_no_only_if_missing_by_default, passed, failed)
    _run("patch_signals_with_event_id", test_patch_signals_with_event_id, passed, failed)
    _run("execute_script_basic", test_execute_script_basic, passed, failed)
    _run("execute_script_targets_body", test_execute_script_targets_body, passed, failed)
    _run("redirect", test_redirect, passed, failed)
    _run("custom_retry_duration", test_custom_retry_duration, passed, failed)
    _run("default_retry_duration_omitted", test_default_retry_duration_omitted, passed, failed)
    _run("sse_ends_with_double_newline", test_sse_ends_with_double_newline, passed, failed)

    print("\n========================================")
    var total = passed + failed
    print("Results:", passed, "/", total, "passed")
    if failed > 0:
        print("FAILURES:", failed)
        raise Error(String(failed) + " test(s) failed")
    print("All tests passed!")
