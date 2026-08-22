"""Can `std.python`'s own bindings drive threads — with no link-line change?

`py_thread_probe.mojo` proved Mojo-spawned pthreads can attach to embedded
CPython and, on a free-threaded build, run Python in parallel. It reaches
`PyGILState_Ensure` / `PyEval_SaveThread` through `external_call`, which the
JIT cannot resolve before `std.python`'s lazy `dlopen` — so it has to be
built with `-lpython`. A threaded server cannot carry that: `m0-wsgi`'s rule
is that libpython lands on no link line in this repo.

This probe asks the three questions the threaded execution mode
(docs/WSGI_VS_ASGI.md §5; the approved plan's Stage A) needs answered
BEFORE any product code, and answers them under plain `mojo run`:

1. **The pinned stdlib exposes the thread-state API.** `Python().cpython()`
   has `PyEval_SaveThread`, `PyEval_RestoreThread`, `PyGILState_Ensure` and
   `PyGILState_Release` as methods on the dlopen'd handle. If this file
   compiles, the bindings exist on the 1.0.0 toolchain; if it runs, they
   work from a foreign thread.
2. **`print` from a pthread is fine.** The original probe avoided it on
   purpose; a server thread will log. Every worker prints one line here.
3. **A parametric `def` can be a thread body.** The plan spawns a
   `_thread_body[T: HTTPService, make: ...]`; this takes the address of an
   instantiation of a parametric function and runs it as the start routine.

Same discipline as the original: main initializes the interpreter and binds
the work, detaches with `PyEval_SaveThread` BEFORE spawning, every worker
attaches once with `PyGILState_Ensure` and releases at the end, main
reattaches after `pthread_join` and proves the interpreter survived.

    uv run mojo run scripts/py_thread_stdpy_probe.mojo
    M0_PROBE_THREADS=8 M0_PROBE_N=2000000 uv run mojo run scripts/py_thread_stdpy_probe.mojo
"""

from std.ffi import c_int, external_call
from std.os import getenv
from std.python import Python, PythonObject
from std.time import perf_counter_ns


comptime SHIM_SOURCE = """
import sys, sysconfig


def info():
    build_ft = sysconfig.get_config_var('Py_GIL_DISABLED') or 0
    gil_on = getattr(sys, '_is_gil_enabled', lambda: True)()
    return ('%d.%d.%d' % sys.version_info[:3],
            str(int(bool(build_ft))),
            'True' if gil_on else 'False')


def work(n):
    s = 0
    for i in range(n):
        s += i * i
    return s
"""

# Per-thread argument block: 8 Int64 slots in malloc'd memory, reached through
# one void*. Result fields are written only by their own thread and read only
# after pthread_join, which is the synchronization.
comptime _BLK_INDEX = 0
comptime _BLK_WORK_ADDR = 1  # address of main's `var` holding the bound callable
comptime _BLK_EXPECT_ADDR = 2  # address of main's expected-result String
comptime _BLK_STATUS = 3  # 1 ok, -1 python error, -2 wrong result, -3 never ran
comptime _BLK_ELAPSED = 4
comptime _BLK_INTS = 8


def _slot(addr: Int) -> Pointer[Int, MutUntrackedOrigin]:
    return Pointer[Int, MutUntrackedOrigin](unsafe_from_address=addr)


def _thread_body[T: AnyType](arg: Int) -> Int:
    """pthread start routine — deliberately parametric (question 3).

    Attaches through the stdlib's bindings, not `external_call` (question 1),
    and prints from the thread (question 2). Kept free of uncaught raises.
    """
    var t0 = perf_counter_ns()
    var index = _slot(arg + _BLK_INDEX * 8)[]
    var status: Int

    ref cpy = Python().cpython()
    var gs = cpy.PyGILState_Ensure()
    try:
        var work = Pointer[PythonObject, MutUntrackedOrigin](
            unsafe_from_address=_slot(arg + _BLK_WORK_ADDR * 8)[]
        )
        var expect = Pointer[String, MutUntrackedOrigin](
            unsafe_from_address=_slot(arg + _BLK_EXPECT_ADDR * 8)[]
        )
        # Zero-argument call + String(py=...) — the bridge's two clean ops.
        var got = String(py=work[]())
        status = 1 if got == expect[] else -2
        print("thread[" + String(index) + "] attached, result ok=" + String(status == 1))
    except:
        status = -1
        print("thread[" + String(index) + "] python error")
    cpy.PyGILState_Release(gs)

    _slot(arg + _BLK_STATUS * 8)[] = status
    _slot(arg + _BLK_ELAPSED * 8)[] = perf_counter_ns() - t0
    return 0


def _int_env(name: String, default: Int) -> Int:
    var raw = getenv(name, "")
    if raw == "":
        return default
    try:
        return Int(raw)
    except:
        return default


def main() raises:
    var threads = _int_env("M0_PROBE_THREADS", 4)
    var n = _int_env("M0_PROBE_N", 4_000_000)

    # --- Interpreter up, on the main thread, exactly like the bridge -------
    var builtins = Python.import_module("builtins")
    var ns = Python.dict()
    builtins.exec(PythonObject(SHIM_SOURCE), ns)
    var info = ns["info"]()
    print("python_version=" + String(py=info[0]))
    print("free_threaded_build=" + String(py=info[1]))
    print("gil_enabled=" + String(py=info[2]))
    print("threads=" + String(threads) + " n=" + String(n))

    # Bind n once, startup-only, so worker calls carry no arguments.
    _ = builtins.exec(
        PythonObject("_bound = (lambda m: (lambda: str(work(m))))(" + String(n) + ")"),
        ns,
    )
    var work_obj = ns["_bound"]
    _ = work_obj()  # warmup: bytecode specialization is not the baseline
    var t0 = perf_counter_ns()
    var expect_str = String(py=work_obj())
    var baseline_ns = perf_counter_ns() - t0
    print("baseline_ms=" + String(baseline_ns // 1_000_000))

    var work_ptr = Pointer(to=work_obj)
    var work_addr = Pointer(to=work_ptr).unsafe_bitcast[Int]()[]
    var expect_ptr = Pointer(to=expect_str)
    var expect_addr = Pointer(to=expect_ptr).unsafe_bitcast[Int]()[]

    # --- Detach main through the stdlib's binding (question 1) ------------
    ref cpy = Python().cpython()
    var main_ts = cpy.PyEval_SaveThread()

    # --- Spawn, the start routine being a parametric instantiation --------
    var blocks = external_call["malloc", Int, Int](threads * _BLK_INTS * 8)
    var tids = external_call["malloc", Int, Int](threads * 8)
    var body = _thread_body[Int]
    var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]

    var wall0 = perf_counter_ns()
    for i in range(threads):
        var blk = blocks + i * _BLK_INTS * 8
        _slot(blk + _BLK_INDEX * 8)[] = i
        _slot(blk + _BLK_WORK_ADDR * 8)[] = work_addr
        _slot(blk + _BLK_EXPECT_ADDR * 8)[] = expect_addr
        _slot(blk + _BLK_STATUS * 8)[] = -3
        _slot(blk + _BLK_ELAPSED * 8)[] = 0
        var rc = external_call["pthread_create", c_int, Int, Int, Int, Int](
            tids + i * 8, 0, body_addr, blk
        )
        if rc != c_int(0):
            raise Error("pthread_create failed for thread ", i)
    for i in range(threads):
        _ = external_call["pthread_join", c_int, Int, Int](_slot(tids + i * 8)[], 0)
    var wall_ns = perf_counter_ns() - wall0

    # --- Reattach and prove the interpreter survived ------------------------
    cpy.PyEval_RestoreThread(main_ts)
    var alive = String(py=ns["info"]()[0])

    var ok = 0
    for i in range(threads):
        var blk = blocks + i * _BLK_INTS * 8
        var status = _slot(blk + _BLK_STATUS * 8)[]
        if status == 1:
            ok += 1
        print(
            "thread[" + String(i) + "]: status=" + String(status)
            + " elapsed_ms=" + String(_slot(blk + _BLK_ELAPSED * 8)[] // 1_000_000)
        )
    print("wall_ms=" + String(wall_ns // 1_000_000))
    var speedup_x100 = threads * baseline_ns * 100 // wall_ns if wall_ns > 0 else 0
    var frac = speedup_x100 % 100
    print(
        "parallel_speedup=" + String(speedup_x100 // 100) + "."
        + ("0" if frac < 10 else "") + String(frac)
    )
    print("threads_ok=" + String(ok) + "/" + String(threads))
    print("interpreter_alive=" + alive)
    print("stdpy_bindings=ok")
    if ok != threads:
        raise Error("not every thread completed cleanly")
