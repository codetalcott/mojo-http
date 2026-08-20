"""Tests for vector reductions over a fetched column.

The reductions are checked two ways: against a plain scalar loop (they must
agree bit for bit, at every length, because integer addition reassociates
exactly), and against SQLite's own `sum`/`min`/`max` over the same rows —
which is the comparison that matters, since the point of the module is to
answer the question SQL would otherwise answer.
"""

from std.testing import assert_equal, assert_true, TestSuite

from src import (
    open_memory,
    sum_ints,
    min_ints,
    max_ints,
    stats_ints,
    ColumnStats,
)


def _scalar_sum(data: List[Int]) -> Int:
    var acc = 0
    for i in range(len(data)):
        acc += data[i]
    return acc


def _values(n: Int) -> List[Int]:
    """Deterministic, both signs, and not monotonic — so a min/max bug in any
    single lane shows up rather than being masked by ordering."""
    var out = List[Int](capacity=n if n > 0 else 1)
    for i in range(n):
        var v = ((i * 2654435761) % 100003) - 50000
        out.append(v)
    return out^


def test_agrees_with_a_scalar_loop_at_every_length() raises:
    # 0..80 crosses the 8-lane width ten times, including every remainder.
    for n in range(0, 81):
        var v = _values(n)
        assert_equal(sum_ints(Span(v)), _scalar_sum(v))
        if n == 0:
            continue
        var lo = v[0]
        var hi = v[0]
        for i in range(n):
            if v[i] < lo:
                lo = v[i]
            if v[i] > hi:
                hi = v[i]
        assert_equal(min_ints(Span(v)), lo)
        assert_equal(max_ints(Span(v)), hi)
        var s = stats_ints(Span(v))
        assert_equal(s.count, n)
        assert_equal(s.sum, _scalar_sum(v))
        assert_equal(s.min, lo)
        assert_equal(s.max, hi)


def test_empty_column_sums_to_zero() raises:
    var empty = List[Int]()
    assert_equal(sum_ints(Span(empty)), 0)


def test_empty_column_has_no_min_or_max() raises:
    var empty = List[Int]()
    var raised = False
    try:
        _ = min_ints(Span(empty))
    except:
        raised = True
    assert_true(raised)

    raised = False
    try:
        _ = max_ints(Span(empty))
    except:
        raised = True
    assert_true(raised)

    raised = False
    try:
        _ = stats_ints(Span(empty))
    except:
        raised = True
    assert_true(raised)


def test_single_element_column() raises:
    var one = List[Int]()
    one.append(-7)
    assert_equal(sum_ints(Span(one)), -7)
    assert_equal(min_ints(Span(one)), -7)
    assert_equal(max_ints(Span(one)), -7)
    var s = stats_ints(Span(one))
    assert_equal(s.count, 1)
    assert_equal(s.sum, -7)
    assert_equal(s.min, -7)
    assert_equal(s.max, -7)


def test_extreme_values_survive_min_and_max() raises:
    var v = List[Int]()
    for _ in range(20):
        v.append(0)
    v[5] = -9223372036854775808   # Int64 min
    v[17] = 9223372036854775807   # Int64 max
    assert_equal(min_ints(Span(v)), -9223372036854775808)
    assert_equal(max_ints(Span(v)), 9223372036854775807)


def test_sum_wraps_exactly_like_the_scalar_loop() raises:
    # Documented behaviour: Int64 wrapping, matching a scalar accumulator.
    # SQLite's own sum() raises past this range instead; the module doc says so.
    var v = List[Int]()
    v.append(9223372036854775807)
    v.append(1)
    for _ in range(30):
        v.append(0)
    assert_equal(sum_ints(Span(v)), _scalar_sum(v))


def test_matches_sqlite_aggregates_over_the_same_rows() raises:
    var db = open_memory()
    db.execute("CREATE TABLE m (v INTEGER)")
    db.begin()
    var ins = db.prepare("INSERT INTO m (v) VALUES (?)")
    var vals = _values(1000)
    for i in range(len(vals)):
        ins.bind_int(1, vals[i])
        _ = ins.step()
        ins.reset()
    ins.finalize()
    db.commit()

    var q = db.prepare("SELECT v FROM m")
    var col = List[Int](capacity=1000)
    var rows = q.fetch_ints(0, col)
    q.finalize()
    assert_equal(rows, 1000)

    var agg = db.prepare("SELECT sum(v), min(v), max(v), count(v) FROM m")
    assert_true(agg.step())
    var sql_sum = agg.column_int(0)
    var sql_min = agg.column_int(1)
    var sql_max = agg.column_int(2)
    var sql_count = agg.column_int(3)
    agg.finalize()

    var s = stats_ints(Span(col))
    assert_equal(s.count, sql_count)
    assert_equal(s.sum, sql_sum)
    assert_equal(s.min, sql_min)
    assert_equal(s.max, sql_max)
    assert_equal(sum_ints(Span(col)), sql_sum)
    assert_equal(min_ints(Span(col)), sql_min)
    assert_equal(max_ints(Span(col)), sql_max)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
