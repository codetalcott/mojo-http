"""
Test runner for m0-http.

Run from packages/m0-http/:
    mojo -I ../m0-core/ run_tests.mojo
"""

from test.test_router import (
    test_exact_match,
    test_param_extraction,
    test_multi_param,
    test_no_match_404,
    test_method_not_allowed_405,
    test_multiple_methods,
    test_segment_count_mismatch,
    test_trailing_slash,
)

from test.test_content_negotiation import (
    test_json_only,
    test_siren_bin,
    test_siren_bin_patch,
    test_html,
    test_links_json,
    test_event_stream,
    test_multiple_types,
    test_quality_zero_disables,
    test_quality_nonzero_enables,
    test_wildcard,
    test_empty_accept,
    test_convenience_wants_html,
    test_convenience_wants_event_stream,
    test_problem_json,
)

from test.test_etag import (
    test_etag_format,
    test_etag_consistency,
    test_etag_different_buffers,
    test_etag_matches_exact,
    test_etag_matches_wildcard,
    test_etag_matches_empty,
    test_etag_matches_in_list,
    test_etag_no_match,
    test_etag_no_partial_match,
    test_etag_matches_with_spaces,
)

from test.test_response_cache import (
    test_cache_miss,
    test_cache_put_get,
    test_cache_update,
    test_cache_invalidate,
    test_cache_invalidate_prefix,
    test_cache_lru_eviction,
    test_cache_lru_fills_to_max,
    test_cache_lru_access_pattern,
    test_cache_lru_put_resets_access,
)

from test.test_sse import (
    test_format_sse_event,
    test_format_sse_heartbeat,
    test_format_sse_multiline_data,
    test_registry_subscribe_notify,
    test_registry_filter_by_url,
    test_registry_unsubscribe,
    test_registry_active_count,
    test_registry_skips_old_events,
    test_registry_backpressure_preserves_last_id,
    test_backpressure_exact_boundary,
    test_backpressure_recovery_after_drain,
    test_backpressure_slots_independent,
    test_journal_append_since,
    test_journal_multiple_returns_snapshot,
    test_journal_no_events,
    test_journal_filters_by_url,
    test_journal_latest_id,
    test_journal_has_etag,
    test_journal_compact,
)


def _run[name: StringLiteral, f: def () raises -> None]() -> Bool:
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

    print("\n=== Router ===")
    if _run["exact_match", test_exact_match](): passed += 1
    else: failed += 1
    if _run["param_extraction", test_param_extraction](): passed += 1
    else: failed += 1
    if _run["multi_param", test_multi_param](): passed += 1
    else: failed += 1
    if _run["no_match_404", test_no_match_404](): passed += 1
    else: failed += 1
    if _run["method_not_allowed_405", test_method_not_allowed_405](): passed += 1
    else: failed += 1
    if _run["multiple_methods", test_multiple_methods](): passed += 1
    else: failed += 1
    if _run["segment_count_mismatch", test_segment_count_mismatch](): passed += 1
    else: failed += 1
    if _run["trailing_slash", test_trailing_slash](): passed += 1
    else: failed += 1

    print("\n=== Content Negotiation ===")
    if _run["json_only", test_json_only](): passed += 1
    else: failed += 1
    if _run["siren_bin", test_siren_bin](): passed += 1
    else: failed += 1
    if _run["siren_bin_patch", test_siren_bin_patch](): passed += 1
    else: failed += 1
    if _run["html", test_html](): passed += 1
    else: failed += 1
    if _run["links_json", test_links_json](): passed += 1
    else: failed += 1
    if _run["event_stream", test_event_stream](): passed += 1
    else: failed += 1
    if _run["multiple_types", test_multiple_types](): passed += 1
    else: failed += 1
    if _run["quality_zero_disables", test_quality_zero_disables](): passed += 1
    else: failed += 1
    if _run["quality_nonzero_enables", test_quality_nonzero_enables](): passed += 1
    else: failed += 1
    if _run["wildcard", test_wildcard](): passed += 1
    else: failed += 1
    if _run["empty_accept", test_empty_accept](): passed += 1
    else: failed += 1
    if _run["convenience_wants_html", test_convenience_wants_html](): passed += 1
    else: failed += 1
    if _run["convenience_wants_event_stream", test_convenience_wants_event_stream](): passed += 1
    else: failed += 1
    if _run["problem_json", test_problem_json](): passed += 1
    else: failed += 1

    print("\n=== ETag ===")
    if _run["etag_format", test_etag_format](): passed += 1
    else: failed += 1
    if _run["etag_consistency", test_etag_consistency](): passed += 1
    else: failed += 1
    if _run["etag_different_buffers", test_etag_different_buffers](): passed += 1
    else: failed += 1
    if _run["etag_matches_exact", test_etag_matches_exact](): passed += 1
    else: failed += 1
    if _run["etag_matches_wildcard", test_etag_matches_wildcard](): passed += 1
    else: failed += 1
    if _run["etag_matches_empty", test_etag_matches_empty](): passed += 1
    else: failed += 1
    if _run["etag_matches_in_list", test_etag_matches_in_list](): passed += 1
    else: failed += 1
    if _run["etag_no_match", test_etag_no_match](): passed += 1
    else: failed += 1
    if _run["etag_no_partial_match", test_etag_no_partial_match](): passed += 1
    else: failed += 1
    if _run["etag_matches_with_spaces", test_etag_matches_with_spaces](): passed += 1
    else: failed += 1

    print("\n=== Response Cache ===")
    if _run["cache_miss", test_cache_miss](): passed += 1
    else: failed += 1
    if _run["cache_put_get", test_cache_put_get](): passed += 1
    else: failed += 1
    if _run["cache_update", test_cache_update](): passed += 1
    else: failed += 1
    if _run["cache_invalidate", test_cache_invalidate](): passed += 1
    else: failed += 1
    if _run["cache_invalidate_prefix", test_cache_invalidate_prefix](): passed += 1
    else: failed += 1
    if _run["cache_lru_eviction", test_cache_lru_eviction](): passed += 1
    else: failed += 1
    if _run["cache_lru_fills_to_max", test_cache_lru_fills_to_max](): passed += 1
    else: failed += 1
    if _run["cache_lru_access_pattern", test_cache_lru_access_pattern](): passed += 1
    else: failed += 1
    if _run["cache_lru_put_resets_access", test_cache_lru_put_resets_access](): passed += 1
    else: failed += 1

    print("\n=== SSE ===")
    if _run["format_sse_event", test_format_sse_event](): passed += 1
    else: failed += 1
    if _run["format_sse_heartbeat", test_format_sse_heartbeat](): passed += 1
    else: failed += 1
    if _run["format_sse_multiline_data", test_format_sse_multiline_data](): passed += 1
    else: failed += 1
    if _run["registry_subscribe_notify", test_registry_subscribe_notify](): passed += 1
    else: failed += 1
    if _run["registry_filter_by_url", test_registry_filter_by_url](): passed += 1
    else: failed += 1
    if _run["registry_unsubscribe", test_registry_unsubscribe](): passed += 1
    else: failed += 1
    if _run["registry_active_count", test_registry_active_count](): passed += 1
    else: failed += 1
    if _run["registry_skips_old_events", test_registry_skips_old_events](): passed += 1
    else: failed += 1
    if _run["registry_backpressure_preserves_last_id", test_registry_backpressure_preserves_last_id](): passed += 1
    else: failed += 1
    if _run["backpressure_exact_boundary", test_backpressure_exact_boundary](): passed += 1
    else: failed += 1
    if _run["backpressure_recovery_after_drain", test_backpressure_recovery_after_drain](): passed += 1
    else: failed += 1
    if _run["backpressure_slots_independent", test_backpressure_slots_independent](): passed += 1
    else: failed += 1
    if _run["journal_append_since", test_journal_append_since](): passed += 1
    else: failed += 1
    if _run["journal_multiple_returns_snapshot", test_journal_multiple_returns_snapshot](): passed += 1
    else: failed += 1
    if _run["journal_no_events", test_journal_no_events](): passed += 1
    else: failed += 1
    if _run["journal_filters_by_url", test_journal_filters_by_url](): passed += 1
    else: failed += 1
    if _run["journal_latest_id", test_journal_latest_id](): passed += 1
    else: failed += 1
    if _run["journal_has_etag", test_journal_has_etag](): passed += 1
    else: failed += 1
    if _run["journal_compact", test_journal_compact](): passed += 1
    else: failed += 1

    var total = passed + failed
    print("\n" + "=" * 40)
    print("Results:", passed, "/", total, "passed")
    if failed > 0:
        print("FAILURES:", failed)
        raise Error(String(failed) + " test(s) failed")
    else:
        print("All tests passed!")
