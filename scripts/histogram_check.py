"""Assert the `/__metrics` latency histogram is present and coherent.

Reads one Prometheus text exposition from stdin (SPEC F5). The status-200
half of the metrics phase cannot see a histogram that records nothing — a
`_count` of 0 renders as perfectly valid exposition — so this checks the
properties a scraper actually depends on:

- the bucket bounds are exactly the documented ones, in `le` order;
- cumulative counts never decrease (`le` buckets are running totals);
- `le="+Inf"` equals `_count`;
- `_count` covers at least the requests the smoke has already made, which
  is the assertion that fails when recording is never called;
- `_sum` exists and is non-zero once real requests are in it.

`--selftest` proves the checker can report each failure, the repo's rule
for anything whose pass looks like "nothing found": a doctored exposition
with decreasing buckets, a `+Inf`/`_count` mismatch, a zero count and a
missing family must each be flagged, or the check is green having tested
nothing. The smoke task runs the selftest immediately before the check.
"""

import argparse
import re
import sys

EXPECTED_BOUNDS = ["100", "1000", "10000", "100000", "1000000", "+Inf"]
FAMILY = "http_request_duration_us"


def check(text, min_count):
    """Every defect found in one exposition, as a list of messages."""
    errors = []
    buckets = re.findall(
        r'^%s_bucket\{le="([^"]+)"\} (\d+)$' % FAMILY, text, re.M
    )
    if not buckets:
        return [f"no {FAMILY}_bucket samples in the exposition"]
    labels = [b[0] for b in buckets]
    counts = [int(b[1]) for b in buckets]
    if labels != EXPECTED_BOUNDS:
        errors.append(f"bucket bounds {labels} != {EXPECTED_BOUNDS}")
    if any(a > b for a, b in zip(counts, counts[1:])):
        errors.append(f"cumulative bucket counts decrease: {counts}")

    m = re.search(r"^%s_count (\d+)$" % FAMILY, text, re.M)
    if not m:
        errors.append(f"no {FAMILY}_count sample")
        return errors
    count = int(m.group(1))
    if counts[-1] != count:
        errors.append(f'le="+Inf" is {counts[-1]} but _count is {count}')
    if count < min_count:
        errors.append(
            f"_count is {count} after at least {min_count} requests — "
            f"the histogram records nothing"
        )
    s = re.search(r"^%s_sum (\d+)$" % FAMILY, text, re.M)
    if not s:
        errors.append(f"no {FAMILY}_sum sample")
    elif count >= min_count and int(s.group(1)) == 0:
        errors.append("_sum is 0 across real requests")
    return errors


def _render(bucket_counts, total, sum_us):
    lines = [f"# TYPE {FAMILY} histogram"]
    for label, n in zip(EXPECTED_BOUNDS, bucket_counts):
        lines.append('%s_bucket{le="%s"} %d' % (FAMILY, label, n))
    lines.append(f"{FAMILY}_sum {sum_us}")
    lines.append(f"{FAMILY}_count {total}")
    return "\n".join(lines) + "\n"


def selftest():
    """The checker must be able to fail, one doctored exposition per rule."""
    good = _render([1, 2, 3, 4, 5, 6], 6, 12345)
    if check(good, 5):
        return f"selftest: a well-formed exposition was flagged: {check(good, 5)}"
    cases = [
        ("decreasing buckets", _render([3, 2, 3, 4, 5, 6], 6, 1), "decrease"),
        ("+Inf != _count", _render([1, 2, 3, 4, 5, 6], 9, 1), "_count is 9"),
        ("zero count", _render([0, 0, 0, 0, 0, 0], 0, 0), "records nothing"),
        ("no histogram at all", "http_requests_total 5\n", "no "),
        ("wrong bounds", good.replace('le="100"', 'le="50"'), "bounds"),
        ("zero sum", _render([1, 2, 3, 4, 5, 6], 6, 0), "_sum is 0"),
    ]
    for name, doc, expect in cases:
        errors = check(doc, 5)
        if not any(expect in e for e in errors):
            return (
                f"selftest: {name} was not flagged by the rule that names it "
                f"(got: {errors})"
            )
    print("histogram_check selftest OK")
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--min-count", type=int, default=1)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        failure = selftest()
        if failure:
            sys.exit(failure)
        return

    errors = check(sys.stdin.read(), args.min_count)
    for e in errors:
        print(f"histogram_check: {e}", file=sys.stderr)
    if errors:
        sys.exit(1)
    print("histogram_check OK")


if __name__ == "__main__":
    main()
