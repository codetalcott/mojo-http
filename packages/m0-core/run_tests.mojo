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

from test.test_json_escape import (
    test_simple_string,
    test_empty_string,
    test_escape_quote,
    test_escape_backslash,
    test_escape_newline,
    test_escape_tab,
    test_no_escape_needed,
)

from test.test_json_parse import (
    test_parse_simple_field,
    test_parse_with_whitespace,
    test_parse_missing_field,
    test_parse_escaped_quotes,
    test_parse_escaped_backslash,
    test_parse_escaped_newline,
    test_parse_multiple_fields,
    test_parse_empty_value,
    test_parse_empty_body,
    test_parse_int_simple,
    test_parse_int_negative,
    test_parse_int_missing,
    test_parse_int_not_numeric,
    test_parse_number_integer,
    test_parse_number_decimal,
    test_parse_number_missing,
    test_parse_bool_true,
    test_parse_bool_false,
    test_parse_bool_missing,
)


def _run[name: StringLiteral, f: def () raises -> None]() -> Bool:
    """Run a single test, print result, return success."""
    try:
        f()
        print("  PASS:", name)
        return True
    except e:
        print("  FAIL:", name, "-", e)
        return False


def main() raises:
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

    # --- JSON Parse ---
    print("\n=== JSON Parse ===")
    if _run["parse_simple_field", test_parse_simple_field](): passed += 1
    else: failed += 1
    if _run["parse_with_whitespace", test_parse_with_whitespace](): passed += 1
    else: failed += 1
    if _run["parse_missing_field", test_parse_missing_field](): passed += 1
    else: failed += 1
    if _run["parse_escaped_quotes", test_parse_escaped_quotes](): passed += 1
    else: failed += 1
    if _run["parse_escaped_backslash", test_parse_escaped_backslash](): passed += 1
    else: failed += 1
    if _run["parse_escaped_newline", test_parse_escaped_newline](): passed += 1
    else: failed += 1
    if _run["parse_multiple_fields", test_parse_multiple_fields](): passed += 1
    else: failed += 1
    if _run["parse_empty_value", test_parse_empty_value](): passed += 1
    else: failed += 1
    if _run["parse_empty_body", test_parse_empty_body](): passed += 1
    else: failed += 1

    # --- JSON Parse: Typed Extractors ---
    print("\n=== JSON Parse: Typed ===")
    if _run["parse_int_simple", test_parse_int_simple](): passed += 1
    else: failed += 1
    if _run["parse_int_negative", test_parse_int_negative](): passed += 1
    else: failed += 1
    if _run["parse_int_missing", test_parse_int_missing](): passed += 1
    else: failed += 1
    if _run["parse_int_not_numeric", test_parse_int_not_numeric](): passed += 1
    else: failed += 1
    if _run["parse_number_integer", test_parse_number_integer](): passed += 1
    else: failed += 1
    if _run["parse_number_decimal", test_parse_number_decimal](): passed += 1
    else: failed += 1
    if _run["parse_number_missing", test_parse_number_missing](): passed += 1
    else: failed += 1
    if _run["parse_bool_true", test_parse_bool_true](): passed += 1
    else: failed += 1
    if _run["parse_bool_false", test_parse_bool_false](): passed += 1
    else: failed += 1
    if _run["parse_bool_missing", test_parse_bool_missing](): passed += 1
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
