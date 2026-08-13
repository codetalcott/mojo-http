"""S1: can Mojo hand SQLite a C-callable function pointer it calls back correctly?

Registers a Mojo function as a SQL scalar function via sqlite3_create_function_v2.
Pass/fail: SELECT mojo_double(21) returns 42.
"""

from std.ffi import external_call, c_int
from std.memory import UnsafePointer

from src import open_memory
from src.ffi import c_string

comptime SQLITE_UTF8: Int = 1

comptime ValuePtrArray = UnsafePointer[Int, MutAnyOrigin]

# void (*)(sqlite3_context*, int, sqlite3_value**)
comptime ScalarFn = def (Int, c_int, ValuePtrArray) thin abi("C") -> None


def mojo_double(ctx: Int, argc: c_int, argv: ValuePtrArray) abi("C") -> None:
    """SQL scalar: double the first integer argument."""
    var v = external_call["sqlite3_value_int64", Int64](argv[unsafe_offset=0])
    external_call["sqlite3_result_int64", NoneType](ctx, v * 2)


def main() raises:
    var db = open_memory()
    var name = c_string("mojo_double")
    var fp: ScalarFn = mojo_double

    var rc = Int(
        external_call["sqlite3_create_function_v2", c_int](
            db._handle,
            name.unsafe_ptr(),
            c_int(1),          # nArg
            c_int(SQLITE_UTF8),
            Int(0),            # pApp
            fp,                # xFunc
            Int(0),            # xStep
            Int(0),            # xFinal
            Int(0),            # xDestroy
        )
    )
    print("create_function_v2 rc =", rc)
    if rc != 0:
        raise Error("registration failed")

    var q = db.prepare("SELECT mojo_double(21)")
    if not q.step():
        raise Error("no row")
    var got = q.column_int(0)
    print("SELECT mojo_double(21) =", got)
    if got != 42:
        raise Error("WRONG: expected 42, got " + String(got))

    # Called once per row, with real data flowing through.
    db.execute("CREATE TABLE t (n INTEGER)")
    db.execute("INSERT INTO t VALUES (1), (2), (3), (100)")
    var q2 = db.prepare("SELECT sum(mojo_double(n)) FROM t")
    _ = q2.step()
    var total = q2.column_int(0)
    print("sum(mojo_double(n)) =", total, "(want 212)")
    if total != 212:
        raise Error("WRONG per-row result")

    print("S1 PASS")
