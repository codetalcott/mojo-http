"""Whether `PythonModuleBuilder` works under free-threaded CPython.

Mojo's stdlib lays `PyObject` out for the GIL build, a 16-byte header where
a free-threaded build's is 32 (modular/modular#5726), so building a module
segfaults there, in `_PyModule_CreateInitialized` calling
`PyUnicode_FromString` (docs/ROADMAP.md, Known issues). That is why
`m0serve` refuses an ASGI application on a free-threaded build with exit 78,
and because the refusal comes first, no smoke can see whether a new
toolchain fixed the layout. This can: it takes the executor's three steps
for its `ExecutorPort` -- a module with a type and a method, an instance
made with `PythonObject(alloc=...)`, and Python dispatching the method --
printing each as it passes.

Exit 0 with three steps printed: the toolchain works under the interpreter
it loaded, the cue to lift the refusal (SPEC L18) and re-run
`smoke-django-realtime` on 3.14t. A crash before step 1 is the defect. Run
it on the pinned GIL interpreter first, as the control, then on 3.14t:

    uv run mojo run scripts/probes/free_threaded_module_probe.mojo
    MOJO_PYTHON_LIBRARY=<python3.14t's lib>/libpython3.14t.dylib \\
        uv run mojo run scripts/probes/free_threaded_module_probe.mojo

The first line it prints names the interpreter and its `Py_GIL_DISABLED`,
so a run that silently loaded the GIL build cannot pass for an answer.
Not a CI gate.
"""

from std.python import Python, PythonObject
from std.python.bindings import PythonModuleBuilder


struct Counter(Movable, Writable):
    """The smallest stand-in for `ExecutorPort`: one field, one method."""

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def bump(py_self: PythonObject) raises -> PythonObject:
        var c = py_self.downcast_value_ptr[Counter]()
        c[].n += 1
        return PythonObject(c[].n)


def main() raises:
    var sys = Python.import_module("sys")
    var sysconfig = Python.import_module("sysconfig")
    print(
        "interpreter:",
        sys.version.split(" ")[0],
        "Py_GIL_DISABLED =",
        sysconfig.get_config_var("Py_GIL_DISABLED"),
    )
    var builder = PythonModuleBuilder("ftprobe")
    _ = builder.add_type[Counter]("Counter").def_method[Counter.bump]("bump")
    var module = builder.finalize()
    print("step 1: module and type built")
    var counter = PythonObject(alloc=Counter(41))
    print("step 2: instance allocated")
    var first = counter.bump()
    var second = counter.bump()
    print("step 3: Python dispatched the method:", first, second)
    _ = module
