"""Building a `PyBridge`, through a live interpreter: what a serving thread
pays to run the shim, and what each thread's bridge keeps its own.

Every serving thread builds a bridge, and each bridge runs the shim in a
namespace of its own: the loop's handler, each `--blocking-threads` thread,
each asyncio executor, each `--threads` loop; `detect_protocol` runs it in
one more, once per application at startup. Parsing the shim's source
allocated 4.2 MB at its peak and kept 0.13 (tracemalloc, CPython 3.14.7),
so eight pool threads parsed it eight times, and how many of those freed
peaks the allocator kept dirty moved an idle server's memory in 3.6 MB
steps from one start to the next. So the shim is compiled once per
interpreter and each namespace loads its own copy of the code, as from a
`.pyc`, which allocates 0.15 MB at its peak and takes 0.12 ms where a
parse took 4.3. The code is loaded per namespace rather than shared: code objects
shared by eight namespaces cost the shim's per-request `run` 4 to 5 %,
because the specializing interpreter's caches are keyed on one globals
dict (docs/notes/one-compile-a-process.md).
"""

from std.python import Python, PythonObject
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from src.app import detect_protocol
from src.bridge import PyBridge


comptime _BOUND = 1024 * 1024
"""What a bridge after the first may allocate at its peak: a parse of the
shim took 4.2 MB, loading the compiled code takes 0.15."""


def _peak_of_one_bridge() raises -> Int:
    """Bytes allocated at the peak of building one bridge, as tracemalloc
    counts them, tracing only that construction."""
    var tracemalloc = Python.import_module("tracemalloc")
    tracemalloc.start()
    try:
        _ = PyBridge()
        return Int(py=tracemalloc.get_traced_memory()[1])
    finally:
        tracemalloc.stop()


def test_a_bridge_after_the_first_parses_nothing() raises:
    """The process's first bridge may compile the shim; the next three each
    must peak under a quarter of what a parse allocates.

    covers: E44
    """
    _ = PyBridge()
    for i in range(3):
        var peak = _peak_of_one_bridge()
        assert_true(
            peak < _BOUND,
            "bridge " + String(i + 2) + " of this process peaked at "
            + String(peak) + " bytes building itself, at least "
            + String(_BOUND) + ": it parsed the shim's source again,"
            " where it should load the code compiled for the first",
        )


def test_detecting_an_applications_protocol_parses_nothing() raises:
    """`detect_protocol` runs on the main thread before any handler exists,
    once for the application and once per mount, and execs the shim to
    reach its one detection rule: it loads the same compiled code. The
    application is the standard library's WSGI demo. The traced detection
    is the second, a mount's: the first imports what detection needs
    (`inspect` alone peaks at 1.5 MB), which no later one pays.

    covers: E44
    """
    _ = PyBridge()
    _ = detect_protocol("wsgiref.simple_server", "demo_app")
    var tracemalloc = Python.import_module("tracemalloc")
    tracemalloc.start()
    var peak: Int
    var is_asgi: Bool
    try:
        is_asgi = detect_protocol("wsgiref.simple_server", "demo_app")
        peak = Int(py=tracemalloc.get_traced_memory()[1])
    finally:
        tracemalloc.stop()
    assert_false(is_asgi, "the WSGI demo application detected as ASGI")
    assert_true(
        peak < _BOUND,
        "detecting a protocol peaked at " + String(peak) + " bytes, at"
        " least " + String(_BOUND) + ": it parsed the shim's source again",
    )


def test_each_bridge_runs_code_and_state_of_its_own() raises:
    """Two bridges in one process: neither the namespace, the shim's
    functions, their code objects nor the lifespan state is shared, and
    each function's globals are its own bridge's namespace. The code
    objects are the ones sharing would make one.

    covers: E44
    """
    var a = PyBridge()
    var b = PyBridge()
    var same = Python.evaluate("lambda x, y: x is y")
    var run_a = a._ns["run"]
    var run_b = b._ns["run"]
    assert_false(Bool(same(a._ns, b._ns)), "two bridges share a namespace")
    assert_false(Bool(same(run_a, run_b)), "two bridges share `run`")
    assert_false(
        Bool(same(run_a.__code__, run_b.__code__)),
        "two bridges share `run`'s code object, which costs every request"
        " 4 to 5 % in the specializing interpreter",
    )
    assert_true(
        Bool(same(run_a.__globals__, a._ns)),
        "a bridge's `run` reads globals other than its own namespace",
    )
    assert_false(
        Bool(same(a._lifespan_state, b._lifespan_state)),
        "two bridges share the lifespan state",
    )
    # The shim behaves in each: one bridge's application is not the other's.
    _ = a._ns["set_app"](Python.evaluate("lambda e, s: [b'a']"), "wsgi")
    assert_equal(String(py=b._ns["_app"]), "None")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
