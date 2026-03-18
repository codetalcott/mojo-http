"""
Test runner for m0-core.

Calls all test_* functions and reports results.
"""

from test.test_hashing import (
    test_fnv1a_empty_string,
    test_fnv1a_hello,
    test_fnv1a_different_inputs,
    test_fnv1a_dom_path,
    test_format_hash_zero,
    test_format_hash_max,
    test_format_hash_length,
    test_xxhash32_empty,
    test_xxhash32_consistency,
    test_xxhash32_different_inputs,
    test_xxhash32_seed,
    test_xxhash32_long_string,
    test_xxhash32_effect_like,
    test_format_xxhash,
    test_format_hash64,
    test_wyhash64_consistency,
    test_wyhash64_different_inputs,
    test_wyhash64_long_string,
)

from test.test_result import (
    test_ok_creation,
    test_err_creation,
    test_value_or_on_ok,
    test_value_or_on_err,
    test_map_result_ok,
    test_map_result_err,
    test_result_copy,
)

from test.test_pipeline import (
    test_compose_two,
    test_compose3,
    test_pipe_2,
    test_pipe_3,
    test_pipe_4,
    test_pipeline_context_basic,
    test_pipe_ctx_2_normal,
    test_pipe_ctx_2_early_exit,
    test_pipe_ctx_3_normal,
)

from test.test_aop import (
    test_identity,
    test_constant,
    test_fork,
    test_hook,
    test_atop,
    test_atop_same_type,
    test_over,
    test_under,
)

from test.test_json_escape import (
    test_simple_string,
    test_empty_string,
    test_escape_quote,
    test_escape_backslash,
    test_escape_newline,
    test_escape_tab,
    test_no_escape_needed,
)


fn _run[name: StringLiteral, f: fn () raises -> None]() -> Bool:
    """Run a single test, print result, return success."""
    try:
        f()
        print("  PASS:", name)
        return True
    except e:
        print("  FAIL:", name, "-", e)
        return False


fn main() raises:
    var passed = 0
    var failed = 0

    # --- Hashing ---
    print("\n=== Hashing ===")
    if _run["fnv1a_empty_string", test_fnv1a_empty_string](): passed += 1
    else: failed += 1
    if _run["fnv1a_hello", test_fnv1a_hello](): passed += 1
    else: failed += 1
    if _run["fnv1a_different_inputs", test_fnv1a_different_inputs](): passed += 1
    else: failed += 1
    if _run["fnv1a_dom_path", test_fnv1a_dom_path](): passed += 1
    else: failed += 1
    if _run["format_hash_zero", test_format_hash_zero](): passed += 1
    else: failed += 1
    if _run["format_hash_max", test_format_hash_max](): passed += 1
    else: failed += 1
    if _run["format_hash_length", test_format_hash_length](): passed += 1
    else: failed += 1
    if _run["xxhash32_empty", test_xxhash32_empty](): passed += 1
    else: failed += 1
    if _run["xxhash32_consistency", test_xxhash32_consistency](): passed += 1
    else: failed += 1
    if _run["xxhash32_different_inputs", test_xxhash32_different_inputs](): passed += 1
    else: failed += 1
    if _run["xxhash32_seed", test_xxhash32_seed](): passed += 1
    else: failed += 1
    if _run["xxhash32_long_string", test_xxhash32_long_string](): passed += 1
    else: failed += 1
    if _run["xxhash32_effect_like", test_xxhash32_effect_like](): passed += 1
    else: failed += 1
    if _run["format_xxhash", test_format_xxhash](): passed += 1
    else: failed += 1
    if _run["format_hash64", test_format_hash64](): passed += 1
    else: failed += 1
    if _run["wyhash64_consistency", test_wyhash64_consistency](): passed += 1
    else: failed += 1
    if _run["wyhash64_different_inputs", test_wyhash64_different_inputs](): passed += 1
    else: failed += 1
    if _run["wyhash64_long_string", test_wyhash64_long_string](): passed += 1
    else: failed += 1

    # --- Result ---
    print("\n=== Result ===")
    if _run["ok_creation", test_ok_creation](): passed += 1
    else: failed += 1
    if _run["err_creation", test_err_creation](): passed += 1
    else: failed += 1
    if _run["value_or_on_ok", test_value_or_on_ok](): passed += 1
    else: failed += 1
    if _run["value_or_on_err", test_value_or_on_err](): passed += 1
    else: failed += 1
    if _run["map_result_ok", test_map_result_ok](): passed += 1
    else: failed += 1
    if _run["map_result_err", test_map_result_err](): passed += 1
    else: failed += 1
    if _run["result_copy", test_result_copy](): passed += 1
    else: failed += 1

    # --- Pipeline ---
    print("\n=== Pipeline ===")
    if _run["compose_two", test_compose_two](): passed += 1
    else: failed += 1
    if _run["compose3", test_compose3](): passed += 1
    else: failed += 1
    if _run["pipe_2", test_pipe_2](): passed += 1
    else: failed += 1
    if _run["pipe_3", test_pipe_3](): passed += 1
    else: failed += 1
    if _run["pipe_4", test_pipe_4](): passed += 1
    else: failed += 1
    if _run["pipeline_context_basic", test_pipeline_context_basic](): passed += 1
    else: failed += 1
    if _run["pipe_ctx_2_normal", test_pipe_ctx_2_normal](): passed += 1
    else: failed += 1
    if _run["pipe_ctx_2_early_exit", test_pipe_ctx_2_early_exit](): passed += 1
    else: failed += 1
    if _run["pipe_ctx_3_normal", test_pipe_ctx_3_normal](): passed += 1
    else: failed += 1

    # --- AOP ---
    print("\n=== AOP ===")
    if _run["identity", test_identity](): passed += 1
    else: failed += 1
    if _run["constant", test_constant](): passed += 1
    else: failed += 1
    if _run["fork", test_fork](): passed += 1
    else: failed += 1
    if _run["hook", test_hook](): passed += 1
    else: failed += 1
    if _run["atop", test_atop](): passed += 1
    else: failed += 1
    if _run["atop_same_type", test_atop_same_type](): passed += 1
    else: failed += 1
    if _run["over", test_over](): passed += 1
    else: failed += 1
    if _run["under", test_under](): passed += 1
    else: failed += 1

    # --- JSON Escape ---
    print("\n=== JSON Escape ===")
    if _run["simple_string", test_simple_string](): passed += 1
    else: failed += 1
    if _run["empty_string", test_empty_string](): passed += 1
    else: failed += 1
    if _run["escape_quote", test_escape_quote](): passed += 1
    else: failed += 1
    if _run["escape_backslash", test_escape_backslash](): passed += 1
    else: failed += 1
    if _run["escape_newline", test_escape_newline](): passed += 1
    else: failed += 1
    if _run["escape_tab", test_escape_tab](): passed += 1
    else: failed += 1
    if _run["no_escape_needed", test_no_escape_needed](): passed += 1
    else: failed += 1

    # --- Summary ---
    var total = passed + failed
    print("\n" + "=" * 40)
    print("Results:", passed, "/", total, "passed")
    if failed > 0:
        print("FAILURES:", failed)
        raise Error(String(failed) + " test(s) failed")
    else:
        print("All tests passed!")
