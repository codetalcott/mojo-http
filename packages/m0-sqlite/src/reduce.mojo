"""Vector reductions over a fetched column.

`Statement.fetch_ints` exists to hand back "a caller-owned `List` per column,
sized once up front, which is what a SIMD pass over the results wants" — its
own words. This is that pass.

Scope is deliberately narrow, and the reason is arithmetic rather than taste:

- **Integers only.** A vector sum reassociates the additions, and floating
  point is not associative, so a `Float64` version would disagree with the
  scalar loop in the last ulp and there would be no single right answer to
  test against. Integer addition reassociates exactly, so these agree with a
  scalar loop bit for bit, on every input.
- **Wrapping, like the scalar loop.** `sum` accumulates in `Int64` and wraps
  on overflow. SQLite's own `sum()` instead raises "integer overflow", so the
  two diverge past 2^63; if that range is reachable, aggregate in SQL or
  widen before summing.

Whether to reduce here or in SQL is a real question with a measured answer —
see `docs/SQLITE_PERFORMANCE.md`. The short version: the reduction is a
rounding error next to the read-out that feeds it, so this is worth reaching
for when the column is already materialised, not as a reason to fetch one.
"""

from std.math import min as vmin, max as vmax


# Eight lanes is wider than any one vector register on the targets here; the
# compiler splits it and the extra independent accumulators hide the add
# latency, which is where most of the win comes from.
comptime _W = 8


struct ColumnStats(Copyable, Movable):
    """Sum, minimum and maximum of a column, from one pass."""

    var count: Int
    var sum: Int
    var min: Int
    var max: Int

    def __init__(out self, count: Int, sum: Int, min: Int, max: Int):
        self.count = count
        self.sum = sum
        self.min = min
        self.max = max


def sum_ints(data: Span[Int, _]) -> Int:
    """Sum of `data`. Empty sums to 0. Wraps on overflow — see the module doc."""
    var n = len(data)
    if n == 0:
        return 0
    var p = data.unsafe_ptr().bitcast[Int64]()
    var acc = SIMD[DType.int64, _W](0)
    var i = 0
    while i + _W <= n:
        acc += p.unsafe_offset(i).unsafe_load[width=_W]()
        i += _W
    var total = Int(acc.reduce_add())
    while i < n:
        total += data[i]
        i += 1
    return total


def min_ints(data: Span[Int, _]) raises -> Int:
    """Smallest element. Raises on an empty column — there is no answer."""
    var n = len(data)
    if n == 0:
        raise Error("min_ints: empty column has no minimum")
    var p = data.unsafe_ptr().bitcast[Int64]()
    var i = 0
    var best: Int
    if n >= _W:
        var acc = p.unsafe_load[width=_W]()
        i = _W
        while i + _W <= n:
            acc = vmin(acc, p.unsafe_offset(i).unsafe_load[width=_W]())
            i += _W
        best = Int(acc.reduce_min())
    else:
        best = data[0]
        i = 1
    while i < n:
        if data[i] < best:
            best = data[i]
        i += 1
    return best


def max_ints(data: Span[Int, _]) raises -> Int:
    """Largest element. Raises on an empty column — there is no answer."""
    var n = len(data)
    if n == 0:
        raise Error("max_ints: empty column has no maximum")
    var p = data.unsafe_ptr().bitcast[Int64]()
    var i = 0
    var best: Int
    if n >= _W:
        var acc = p.unsafe_load[width=_W]()
        i = _W
        while i + _W <= n:
            acc = vmax(acc, p.unsafe_offset(i).unsafe_load[width=_W]())
            i += _W
        best = Int(acc.reduce_max())
    else:
        best = data[0]
        i = 1
    while i < n:
        if data[i] > best:
            best = data[i]
        i += 1
    return best


def stats_ints(data: Span[Int, _]) raises -> ColumnStats:
    """Sum, min and max in one pass — the shape `SELECT sum(v), min(v), max(v)`
    returns, computed here instead. Raises on an empty column."""
    var n = len(data)
    if n == 0:
        raise Error("stats_ints: empty column has no minimum or maximum")
    var p = data.unsafe_ptr().bitcast[Int64]()
    var total: Int
    var lo: Int
    var hi: Int
    var i = 0
    if n >= _W:
        var first = p.unsafe_load[width=_W]()
        var acc = first
        var vlo = first
        var vhi = first
        i = _W
        while i + _W <= n:
            var c = p.unsafe_offset(i).unsafe_load[width=_W]()
            acc += c
            vlo = vmin(vlo, c)
            vhi = vmax(vhi, c)
            i += _W
        total = Int(acc.reduce_add())
        lo = Int(vlo.reduce_min())
        hi = Int(vhi.reduce_max())
    else:
        total = data[0]
        lo = data[0]
        hi = data[0]
        i = 1
    while i < n:
        var v = data[i]
        total += v
        if v < lo:
            lo = v
        if v > hi:
            hi = v
        i += 1
    return ColumnStats(n, total, lo, hi)
