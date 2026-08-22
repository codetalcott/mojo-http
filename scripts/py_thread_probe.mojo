"""Can Mojo threads call into embedded CPython concurrently?

The question that gates the thread-pool successor to `M0_WORKERS` forking
(docs/WSGI_VS_ASGI.md §5). `py_canary_probe.mojo` proved single-threaded
embedding works on free-threaded 3.14t; this probe answers the next one:
what happens when threads the Mojo program spawned itself — raw pthreads,
the shape a thread-per-request server would use — attach to the interpreter
and run Python simultaneously.

Three claims, one exit code:

1. **Foreign threads can attach.** Each worker wraps its Python work in
   `PyGILState_Ensure`/`Release` — required embedding etiquette on every
   CPython, free-threaded or not (free-threading removes the mutual
   exclusion, not the thread-state discipline). The main thread releases its
   own state with `PyEval_SaveThread` first; without that, workers on a
   GIL build would block forever against the state `Py_Initialize` left
   attached (the bridge's documented invariant).
2. **The work is correct.** Every thread computes the same pure-Python sum
   and the result is checked against the value the main thread computed.
3. **On 3.14t it actually parallelizes.** Wall clock for T threads vs the
   single-thread baseline. A GIL build serializes (speedup ~1x); a
   free-threaded build should approach Tx.

Modes (`M0_PROBE_MODE`):

- `interop` (default): worker threads call a `PythonObject` through Mojo's
  `std.python` — the layer `m0-wsgi`'s bridge is built on, and therefore the
  layer whose thread-safety actually decides the thread-pool question.
- `raw`: worker threads use only `PyRun_SimpleString` — pure C API, no Mojo
  interop involvement. If `interop` fails and `raw` passes, the blocker is
  Mojo's interop layer, not CPython embedding.
- `naive`: workers skip `PyGILState_Ensure`. Expected to crash the process —
  run it only to demonstrate the discipline is load-bearing.

Knobs: `M0_PROBE_THREADS` (default 4), `M0_PROBE_N` (loop iterations,
default 4,000,000 — sized so the Python work dominates thread plumbing).

    uv run mojo run scripts/py_thread_probe.mojo          # pinned 3.13
    # after `poe py314t-try`: .venv/bin/mojo run scripts/py_thread_probe.mojo
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


# Per-thread argument block, laid out as 8 Int64 slots in malloc'd memory so
# a raw pthread can reach it through one void* with no Mojo collections
# involved. Written fields [5..7] are each written only by their own thread
# and read only after pthread_join, which is the synchronization.
comptime _BLK_WORK_ADDR = 0  # address of the main thread's `var` holding work PythonObject
comptime _BLK_USE_ENSURE = 1  # 1 = wrap in PyGILState_Ensure/Release
comptime _BLK_EXPECT = 2  # address of the main thread's expected-result String
comptime _BLK_RAW_MODE = 3  # 1 = PyRun_SimpleString path, 0 = PythonObject path
comptime _BLK_CODE_ADDR = 4  # NUL-terminated code string (raw mode)
comptime _BLK_STATUS = 5  # 1 ok, -1 python error, -2 wrong result, -3 never ran
comptime _BLK_ELAPSED = 6  # nanoseconds inside the body
comptime _BLK_RESULT = 7
comptime _BLK_INTS = 8


def _slot(addr: Int) -> Pointer[Int, MutUntrackedOrigin]:
    return Pointer[Int, MutUntrackedOrigin](unsafe_from_address=addr)


def _thread_body(arg: Int) -> Int:
    """pthread start routine. No prints, no Mojo collections — stores into
    its block and returns. a `def` like the signal handler, kept free of uncaught raises."""
    var t0 = perf_counter_ns()
    var status: Int
    var result = 0

    var use_ensure = _slot(arg + _BLK_USE_ENSURE * 8)[]
    var gs: c_int = 0
    if use_ensure == 1:
        gs = external_call["PyGILState_Ensure", c_int]()

    if _slot(arg + _BLK_RAW_MODE * 8)[] == 1:
        var rc = external_call["PyRun_SimpleString", c_int, Int](
            _slot(arg + _BLK_CODE_ADDR * 8)[]
        )
        # SimpleString runs in __main__ and returns only pass/fail; the
        # correctness half of the probe lives in interop mode.
        status = 1 if Int(rc) == 0 else -1
        result = 0
    else:
        try:
            var work = Pointer[PythonObject, MutUntrackedOrigin](
                unsafe_from_address=_slot(arg + _BLK_WORK_ADDR * 8)[]
            )
            var expect = Pointer[String, MutUntrackedOrigin](
                unsafe_from_address=_slot(arg + _BLK_EXPECT * 8)[]
            )
            # String(py=...) is one of the four measured-clean interop ops —
            # the same read the bridge uses for statuses (bridge.mojo).
            var got = String(py=work[]())
            result = got.byte_length()
            status = 1 if got == expect[] else -2
        except:
            status = -1

    if use_ensure == 1:
        _ = external_call["PyGILState_Release", c_int, c_int](gs)

    _slot(arg + _BLK_STATUS * 8)[] = status
    _slot(arg + _BLK_ELAPSED * 8)[] = perf_counter_ns() - t0
    _slot(arg + _BLK_RESULT * 8)[] = result
    return 0


def _int_env(name: String, default: Int) -> Int:
    var raw = getenv(name, "")
    if raw == "":
        return default
    try:
        return Int(raw)
    except:
        return default


def _c_string(s: String) -> Int:
    """Copy `s` into malloc'd memory with a NUL, returning the address.
    Never freed: the probe is one-shot and the threads outlive any scope."""
    var bytes = s.as_bytes()
    var addr = external_call["malloc", Int, Int](len(bytes) + 1)
    for i in range(len(bytes)):
        _slot_u8(addr + i)[] = Int8(bytes[i])
    _slot_u8(addr + len(bytes))[] = Int8(0)
    return addr


def _slot_u8(addr: Int) -> Pointer[Int8, MutUntrackedOrigin]:
    return Pointer[Int8, MutUntrackedOrigin](unsafe_from_address=addr)


def main() raises:
    var threads = _int_env("M0_PROBE_THREADS", 4)
    var n = _int_env("M0_PROBE_N", 4_000_000)
    var mode = getenv("M0_PROBE_MODE", "interop")
    if mode != "interop" and mode != "raw" and mode != "naive":
        raise Error("M0_PROBE_MODE must be interop, raw, or naive")

    # --- Interpreter up, on the main thread, exactly like the bridge -------
    var builtins = Python.import_module("builtins")
    var ns = Python.dict()
    builtins.exec(PythonObject(SHIM_SOURCE), ns)
    var info = ns["info"]()
    print("python_version=" + String(py=info[0]))
    print("free_threaded_build=" + String(py=info[1]))
    print("gil_enabled=" + String(py=info[2]))
    print("mode=" + mode + " threads=" + String(threads) + " n=" + String(n))

    # Zero-argument thereafter: bind n into a closure once, startup-only, so
    # worker calls carry no arguments (the bridge's leak rule, same reason).
    # The closure answers str() because String(py=...) is the measured-clean
    # way to read a call result back into Mojo.
    _ = builtins.exec(
        PythonObject("_bound = (lambda m: (lambda: str(work(m))))(" + String(n) + ")"),
        ns,
    )
    var work_obj = ns["_bound"]

    # Baseline and expected value, measured the same way the workers work.
    var code_addr = 0
    var expect_str = String("")
    var t0 = perf_counter_ns()
    if mode == "raw":
        var code = String("s = 0\nfor i in range(", n, "):\n    s += i * i\n")
        code_addr = _c_string(code)
        if external_call["PyRun_SimpleString", c_int, Int](code_addr) != c_int(0):
            raise Error("baseline PyRun_SimpleString failed")
    else:
        expect_str = String(py=work_obj())
    var baseline_ns = perf_counter_ns() - t0
    print("baseline_ms=" + String(baseline_ns // 1_000_000))

    # The address of the var holding the callable: read the Pointer's own
    # value as an Int — the address-taking idiom from src/signal.mojo, one
    # level up.
    var work_ptr = Pointer(to=work_obj)
    var work_addr = Pointer(to=work_ptr).unsafe_bitcast[Int]()[]
    var expect_ptr = Pointer(to=expect_str)
    var expect_addr = Pointer(to=expect_ptr).unsafe_bitcast[Int]()[]

    # --- Detach the main thread's state ------------------------------------
    # Py_Initialize left it attached here. On a GIL build, a worker's
    # PyGILState_Ensure blocks until this thread lets go — forever, without
    # this call. On 3.14t it is etiquette rather than survival, and the
    # probe keeps one code path.
    var main_ts = external_call["PyEval_SaveThread", Int]()

    # --- Spawn -------------------------------------------------------------
    var blocks = external_call["malloc", Int, Int](threads * _BLK_INTS * 8)
    var tids = external_call["malloc", Int, Int](threads * 8)
    var body = _thread_body
    var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]

    var wall0 = perf_counter_ns()
    for i in range(threads):
        var blk = blocks + i * _BLK_INTS * 8
        _slot(blk + _BLK_WORK_ADDR * 8)[] = work_addr
        _slot(blk + _BLK_USE_ENSURE * 8)[] = 0 if mode == "naive" else 1
        _slot(blk + _BLK_EXPECT * 8)[] = expect_addr
        _slot(blk + _BLK_RAW_MODE * 8)[] = 1 if mode == "raw" else 0
        _slot(blk + _BLK_CODE_ADDR * 8)[] = code_addr
        _slot(blk + _BLK_STATUS * 8)[] = -3
        _slot(blk + _BLK_ELAPSED * 8)[] = 0
        _slot(blk + _BLK_RESULT * 8)[] = 0
        var rc = external_call["pthread_create", c_int, Int, Int, Int, Int](
            tids + i * 8, 0, body_addr, blk
        )
        if rc != c_int(0):
            raise Error("pthread_create failed for thread ", i)

    for i in range(threads):
        _ = external_call["pthread_join", c_int, Int, Int](_slot(tids + i * 8)[], 0)
    var wall_ns = perf_counter_ns() - wall0

    # --- Reattach and prove the interpreter survived -----------------------
    external_call["PyEval_RestoreThread", NoneType, Int](main_ts)
    var alive = String(py=ns["info"]()[0])

    var ok = 0
    for i in range(threads):
        var blk = blocks + i * _BLK_INTS * 8
        var status = _slot(blk + _BLK_STATUS * 8)[]
        var label = String("ok")
        if status == -1:
            label = "python-error"
        elif status == -2:
            label = "wrong-result"
        elif status == -3:
            label = "never-ran"
        if status == 1:
            ok += 1
        print(
            "thread[" + String(i) + "]: status=" + label
            + " elapsed_ms=" + String(_slot(blk + _BLK_ELAPSED * 8)[] // 1_000_000)
        )

    print("wall_ms=" + String(wall_ns // 1_000_000))
    # Aggregate throughput vs one thread: T*baseline work done in wall time.
    # ~1.0 means serialized (the GIL build's expected answer); ~T means the
    # free-threaded build parallelized Mojo-spawned threads for real.
    var speedup_x100 = threads * baseline_ns * 100 // wall_ns if wall_ns > 0 else 0
    var frac = speedup_x100 % 100
    print(
        "parallel_speedup=" + String(speedup_x100 // 100) + "."
        + ("0" if frac < 10 else "") + String(frac)
    )
    print("threads_ok=" + String(ok) + "/" + String(threads))
    print("interpreter_alive=" + alive)
    if ok != threads:
        raise Error("not every thread completed cleanly")
