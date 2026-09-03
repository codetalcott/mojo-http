# Structured CI results

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

**The CI half shipped 2026-08-30.** `scripts/emit.py` appends each measurement
to `$M0_RESULTS` as one JSON line; the smoke job renders them into the run
summary with a headroom column and uploads `ci-results-<os>`. Five sites are
instrumented: the WSGI and ASGI RSS guards, the pool's fast-request latency in
both modes, and sendfile's RSS delta. The recorder never fails and is a no-op
without `$M0_RESULTS`, and `check_ci_measurements_are_collected` refuses the
four ways the wiring can lapse silently.

It paid for itself on the first run. `sendfile.rss_growth_kb` measures **48 KB
against a 16384 KB limit** -- a guard roughly 340x looser than the thing it
guards, which would pass a regression that buffered 8 MB. That is the blind
spot SPEC.md names in the abstract ("a gate runs, not that it is correct"),
now with a number on it. Deliberately NOT tightened yet: one sample from one
machine is not a basis for moving a CI threshold, and gathering the runs first
is the entire reason for recording them.

**The serving side landed too** (SPEC F5): `/__metrics` now renders a
request-latency histogram beside the counters — six log-spaced `le` bounds
(100µs to 1s, then +Inf), integer-only and O(1) on the loop thread, sampled
in `_after_send` from the same clock the access log reads. Per-loop like
every other metric; the scraper aggregates. The serve smoke's metrics phase
checks coherence (bounds, cumulative monotonicity, `+Inf` == `_count`, a
count covering its own requests) through `scripts/histogram_check.py`, whose
selftest runs in the same phase so its "OK" cannot mean "checks nothing".
