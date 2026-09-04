"""Read-out benchmarks for m0-sqlite.

Measures the two things the bulk read-out API changed: the `unsafe_memcpy`
rewrite of `column_blob`, and the SoA `fetch_*` loops against the per-row
`while stmt.step():` idiom they are shorthand for.

Deliberately hand-timed rather than built on `std.benchmark` like
`m0-core/run_benchmarks.mojo`: these are millisecond-scale scans over a fixed
row count, so a wall-clock total per scan is the number worth reading, and an
autotuned per-op figure would hide how much of it is SQLite's own floor.

Usage:  uv run poe bench-sqlite
"""

from std.collections.span import Span
from std.ffi import external_call, c_int
from std.memory import Pointer
from std.time import perf_counter_ns

from src import Connection, Statement, open_memory, stats_ints
from src.ffi import CharPtr

comptime ROWS: Int = 100_000
comptime REPS: Int = 5


# --- The pre-memcpy implementation, kept here for the A/B ---------------------


def _column_blob_byteloop(stmt: Statement, index: Int) -> List[UInt8]:
    """`column_blob` as it was written before the memcpy rewrite."""
    var n = Int(
        external_call["sqlite3_column_bytes", c_int](stmt._handle, c_int(index))
    )
    var out = List[UInt8](capacity=n if n > 0 else 1)
    if n <= 0:
        return out^
    var p = external_call["sqlite3_column_blob", CharPtr](
        stmt._handle, c_int(index)
    )
    for i in range(n):
        out.append(p[unsafe_offset=i])
    return out^


# --- A borrowed read, kept bench-local: the design is recorded, not shipped ---


def _column_bytes_span(
    stmt: Statement, index: Int
) raises -> Span[Byte, origin_of(stmt)]:
    """The bytes where SQLite holds them, borrowed from `stmt`; no copy.

    `column_blob_into` minus its memcpy. Pointer before length, as everywhere
    in stmt.mojo. The span's origin is the statement's, so a `step`, `reset`
    or `finalize` (all `mut self`) while it is alive is a compile error --
    which is the property that would make this an API, and what
    `docs/SQLITE_PERFORMANCE.md` records instead of shipping it.
    """
    stmt._check_column(index)
    var p = external_call["sqlite3_column_blob", CharPtr](
        stmt._handle, c_int(index)
    )
    var n = Int(
        external_call["sqlite3_column_bytes", c_int](
            stmt._handle, c_int(index)
        )
    )
    if n <= 0:
        return Span[Byte, origin_of(stmt)]()
    return Span[Byte, origin_of(stmt)](
        unsafe_ptr=Pointer[UInt8, origin_of(stmt)](unsafe_from_address=Int(p)),
        length=n,
    )


# --- Fixtures -----------------------------------------------------------------


def _seed(mut db: Connection, blob_size: Int) raises:
    db.execute(
        "CREATE TABLE t"
        " (id INTEGER PRIMARY KEY, n INTEGER, f REAL, v BLOB, s TEXT)"
    )
    var payload = List[UInt8](capacity=blob_size)
    for i in range(blob_size):
        payload.append(UInt8(i & 0xFF))
    # Text payload of the same size, printable so it is honest TEXT.
    var text = String()
    for i in range(blob_size):
        text += String(chr(ord("a") + (i % 26)))

    db.begin()
    var ins = db.prepare(
        "INSERT INTO t (id, n, f, v, s) VALUES (?, ?, ?, ?, ?)"
    )
    for i in range(ROWS):
        ins.reset()
        ins.bind_int(1, i)
        ins.bind_int(2, i * 3)
        ins.bind_float(3, Float64(i) * 1.5)
        ins.bind_blob(4, payload)
        ins.bind_text(5, text)
        _ = ins.step()
    _ = ins^
    db.commit()


def _report(label: String, ns: Int):
    var ms = Float64(ns) / 1.0e6
    var per_row = Float64(ns) / Float64(ROWS)
    print(label, "\t", ms, "ms\t", per_row, "ns/row")


# --- Benchmarks ---------------------------------------------------------------


def bench_int_scan(mut db: Connection) raises:
    print("\n--- 1 INTEGER column,", ROWS, "rows ---")

    var best_manual = 0
    for r in range(REPS):
        var q = db.prepare("SELECT n FROM t")
        var out = List[Int](capacity=ROWS)
        var t0 = perf_counter_ns()
        while q.step():
            out.append(q.column_int(0))
        var dt = perf_counter_ns() - t0
        if r == 0 or dt < best_manual:
            best_manual = dt
    _report("while step() + column_int ", best_manual)

    var best_bulk = 0
    for r in range(REPS):
        var q = db.prepare("SELECT n FROM t")
        var out = List[Int](capacity=ROWS)
        var t0 = perf_counter_ns()
        _ = q.fetch_ints(0, out)
        var dt = perf_counter_ns() - t0
        if r == 0 or dt < best_bulk:
            best_bulk = dt
    _report("fetch_ints                ", best_bulk)


def bench_float_scan(mut db: Connection) raises:
    print("\n--- 1 REAL column,", ROWS, "rows ---")

    var best_manual = 0
    for r in range(REPS):
        var q = db.prepare("SELECT f FROM t")
        var out = List[Float64](capacity=ROWS)
        var t0 = perf_counter_ns()
        while q.step():
            out.append(q.column_float(0))
        var dt = perf_counter_ns() - t0
        if r == 0 or dt < best_manual:
            best_manual = dt
    _report("while step() + column_float", best_manual)

    var best_bulk = 0
    for r in range(REPS):
        var q = db.prepare("SELECT f FROM t")
        var out = List[Float64](capacity=ROWS)
        var t0 = perf_counter_ns()
        _ = q.fetch_floats(0, out)
        var dt = perf_counter_ns() - t0
        if r == 0 or dt < best_bulk:
            best_bulk = dt
    _report("fetch_floats               ", best_bulk)


def bench_blob_scan(mut db: Connection, size: Int) raises:
    print("\n---", size, "-byte BLOB column,", ROWS, "rows ---")

    var best_old = 0
    for r in range(REPS):
        var q = db.prepare("SELECT v FROM t")
        var t0 = perf_counter_ns()
        var acc = 0
        while q.step():
            var b = _column_blob_byteloop(q, 0)
            acc += len(b)
        var dt = perf_counter_ns() - t0
        if r == 0 or dt < best_old:
            best_old = dt
    _report("column_blob (per-byte loop)", best_old)

    var best_new = 0
    for r in range(REPS):
        var q = db.prepare("SELECT v FROM t")
        var t0 = perf_counter_ns()
        var acc = 0
        while q.step():
            var b = q.column_blob(0)
            acc += len(b)
        var dt = perf_counter_ns() - t0
        if r == 0 or dt < best_new:
            best_new = dt
    _report("column_blob (memcpy)       ", best_new)

    var best_into = 0
    for r in range(REPS):
        var q = db.prepare("SELECT v FROM t")
        var buf = List[UInt8]()
        var t0 = perf_counter_ns()
        var acc = 0
        while q.step():
            acc += q.column_blob_into(0, buf)
        var dt = perf_counter_ns() - t0
        if r == 0 or dt < best_into:
            best_into = dt
    _report("column_blob_into (reused)  ", best_into)

    var best_span = 0
    for r in range(REPS):
        var q = db.prepare("SELECT v FROM t")
        var t0 = perf_counter_ns()
        var acc = 0
        while q.step():
            var s = _column_bytes_span(q, 0)
            acc += len(s)
        var dt = perf_counter_ns() - t0
        if r == 0 or dt < best_span:
            best_span = dt
    _report("borrowed span (no copy)    ", best_span)


def bench_text_scan(mut db: Connection, size: Int) raises:
    """What the per-row String allocation in a text scan costs.

    The third row is the zero-allocation read that ALREADY exists:
    `column_blob_into` on a TEXT column hands back the UTF-8 bytes into a
    reused buffer — SQLite converts TEXT to blob bytes on request, and for
    TEXT stored as UTF-8 that conversion is a pointer handoff. The delta
    between rows one and three is therefore pure String alloc/free.
    """
    print("\n---", size, "-byte TEXT column,", ROWS, "rows ---")

    var best_text = 0
    for r in range(REPS):
        var q = db.prepare("SELECT s FROM t")
        var t0 = perf_counter_ns()
        var acc = 0
        while q.step():
            var v = q.column_text(0)
            acc += v.byte_length()
        var dt = perf_counter_ns() - t0
        if r == 0 or dt < best_text:
            best_text = dt
    _report("column_text (String/row)   ", best_text)

    var best_bulk = 0
    for r in range(REPS):
        var q = db.prepare("SELECT s FROM t")
        var out = List[String](capacity=ROWS)
        var t0 = perf_counter_ns()
        _ = q.fetch_texts(0, out)
        var dt = perf_counter_ns() - t0
        if r == 0 or dt < best_bulk:
            best_bulk = dt
    _report("fetch_texts                ", best_bulk)

    var best_into = 0
    for r in range(REPS):
        var q = db.prepare("SELECT s FROM t")
        var buf = List[UInt8]()
        var t0 = perf_counter_ns()
        var acc = 0
        while q.step():
            acc += q.column_blob_into(0, buf)
        var dt = perf_counter_ns() - t0
        if r == 0 or dt < best_into:
            best_into = dt
    _report("column_blob_into on TEXT   ", best_into)

    var best_span = 0
    for r in range(REPS):
        var q = db.prepare("SELECT s FROM t")
        var t0 = perf_counter_ns()
        var acc = 0
        while q.step():
            var s = _column_bytes_span(q, 0)
            acc += len(s)
        var dt = perf_counter_ns() - t0
        if r == 0 or dt < best_span:
            best_span = dt
    _report("borrowed span on TEXT      ", best_span)


def bench_ingest(n: Int) raises:
    """The per-row loop against one `INSERT ... SELECT` over `m0_array`."""
    print("\n--- bulk ingest,", n, "rows ---")
    var data = List[Int](length=n, fill=0)
    for i in range(n):
        data[i] = i * 3

    var best_loop = 0
    for r in range(5):
        var db = open_memory()
        db.execute("CREATE TABLE t (v INTEGER)")
        var t0 = perf_counter_ns()
        db.begin()
        var ins = db.prepare("INSERT INTO t VALUES (?)")
        for i in range(n):
            ins.reset()
            ins.bind_int(1, data[i])
            _ = ins.step()
        _ = ins^
        db.commit()
        var dt = perf_counter_ns() - t0
        if r == 0 or dt < best_loop:
            best_loop = dt
    print("  bind/step/reset loop      ", Float64(best_loop) / 1.0e6, "ms")

    var best_vt = 0
    for r in range(5):
        var db = open_memory()
        db.register_array_module()
        db.execute("CREATE TABLE t (v INTEGER)")
        var t0 = perf_counter_ns()
        var ins = db.prepare("INSERT INTO t SELECT value FROM m0_array(?1)")
        ins.execute_over(1, data)
        var dt = perf_counter_ns() - t0
        if r == 0 or dt < best_vt:
            best_vt = dt
    print("  INSERT..SELECT m0_array   ", Float64(best_vt) / 1.0e6, "ms")
    print("  speedup                   ", Float64(best_loop) / Float64(best_vt), "x")


def bench_reduce(rows: Int) raises:
    """Aggregate a column: SQLite's own aggregate, versus reading the column
    out and reducing it here. Values are checked against SQLite before timing."""
    print("--- aggregate", rows, "integer rows (sum+min+max) ---")
    var db = open_memory()
    db.execute("CREATE TABLE agg (v INTEGER)")
    db.begin()
    var ins = db.prepare("INSERT INTO agg (v) VALUES (?)")
    for i in range(rows):
        ins.bind_int(1, ((i * 2654435761) % 100003) - 50000)
        _ = ins.step()
        ins.reset()
    ins.finalize()
    db.commit()

    # Byte-parity before timing, as everywhere else in this file.
    var chk = db.prepare("SELECT v FROM agg")
    var col = List[Int](capacity=rows)
    _ = chk.fetch_ints(0, col)
    chk.finalize()
    var agg = db.prepare("SELECT sum(v), min(v), max(v) FROM agg")
    _ = agg.step()
    var want_sum = agg.column_int(0)
    var want_min = agg.column_int(1)
    var want_max = agg.column_int(2)
    agg.finalize()
    var got = stats_ints(Span(col))
    if got.sum != want_sum or got.min != want_min or got.max != want_max:
        raise Error("stats_ints disagrees with SQLite; refusing to time it")

    var best_sql = 0
    for r in range(REPS):
        var t0 = perf_counter_ns()
        var q = db.prepare("SELECT sum(v), min(v), max(v) FROM agg")
        _ = q.step()
        _ = q.column_int(0)
        q.finalize()
        var dt = Int(perf_counter_ns() - t0)
        if r == 0 or dt < best_sql:
            best_sql = dt

    var best_fetch = 0
    for r in range(REPS):
        var t0 = perf_counter_ns()
        var q = db.prepare("SELECT v FROM agg")
        var c = List[Int](capacity=rows)
        _ = q.fetch_ints(0, c)
        q.finalize()
        var s = stats_ints(Span(c))
        _ = s.sum
        var dt = Int(perf_counter_ns() - t0)
        if r == 0 or dt < best_fetch:
            best_fetch = dt

    var best_red = 0
    for r in range(REPS):
        var t0 = perf_counter_ns()
        var s = stats_ints(Span(col))
        _ = s.sum
        var dt = Int(perf_counter_ns() - t0)
        if r == 0 or dt < best_red:
            best_red = dt

    print("  SQLite aggregate           ", Float64(best_sql) / 1.0e6, "ms")
    print("  fetch_ints + stats_ints    ", Float64(best_fetch) / 1.0e6, "ms")
    print("  speedup                    ", Float64(best_sql) / Float64(best_fetch), "x")
    print("  (reduction alone           ", Float64(best_red) / 1.0e6, "ms of that)")


def main() raises:
    print("=== m0-sqlite benchmarks (best of", REPS, ") ===")

    for size in [64, 4096]:
        var db = open_memory()
        _seed(db, size)
        if size == 64:
            bench_int_scan(db)
            bench_float_scan(db)
        bench_blob_scan(db, size)
        bench_text_scan(db, size)

    bench_ingest(10_000)
    bench_ingest(200_000)

    bench_reduce(200_000)
