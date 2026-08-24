"""Probe the embedded CPython that `std.python` actually loads.

Run by `poe py-canary` to answer, from INSIDE the embedded interpreter —
which no HTTP route exposes — three questions with one exit code:

1. Does the interpreter initialize at all under this venv's libpython?
2. Is it a free-threaded build, and is the GIL really off right now?
   (`free_threaded_build=` / `gil_enabled=` below; the canary greps them.
   The probe itself only *reports* — it must run green on the pinned 3.13
   venv too, where it doubles as a standing regression check for the shim
   mechanics.)
3. Do `bridge.mojo`'s load-bearing moves work here: a shim `exec`'d from a
   string, a persistent Python-side bytearray, its raw address crossing via
   a zero-argument `ctypes` call, and Mojo writing bytes through that
   pointer that Python then reads back.

Each stage fails with its own message, so the canary can tell "libpython
would not load" from "the interpreter is up but the ctypes crossing broke".

    uv run mojo run scripts/py_canary_probe.mojo    # no -I flags needed
"""

from std.python import Python, PythonObject


comptime PROBE_SOURCE = """
import ctypes, sys, sysconfig

_buf = bytearray(64)


def info():
    # Everything as str: the Mojo side reads results with String(py=...).
    build_ft = sysconfig.get_config_var('Py_GIL_DISABLED') or 0
    gil_on = getattr(sys, '_is_gil_enabled', lambda: True)()
    return ('%d.%d.%d' % sys.version_info[:3],
            str(int(bool(build_ft))),
            'True' if gil_on else 'False')


def buf_addr():
    return ctypes.addressof(ctypes.c_char.from_buffer(_buf))


def readback():
    return bytes(_buf[:8]).decode('ascii')
"""


def main() raises:
    # Stage 1: interpreter init + exec'd shim — the bridge's startup shape.
    var ns: PythonObject
    try:
        var builtins = Python.import_module("builtins")
        ns = Python.dict()
        builtins.exec(PythonObject(PROBE_SOURCE), ns)
    except e:
        print("probe: FAIL(interpreter-init-or-exec): " + String(e))
        raise Error("interpreter init or shim exec failed")

    # Stage 2: report from inside. The canary asserts on these lines; this
    # probe only reports them.
    try:
        var info = ns["info"]()
        print("python_version=" + String(py=info[0]))
        print("free_threaded_build=" + String(py=info[1]))
        print("gil_enabled=" + String(py=info[2]))
    except e:
        print("probe: FAIL(introspection): " + String(e))
        raise Error("interpreter is up but introspection failed")

    # Stage 3: the raw-address crossing. The serving path no longer uses it
    # (both bodies go through PyBytes_* now), but the realtime publish path
    # still does — m0pub.py hands SharedAtomics' page address to ctypes — and
    # it is the sharpest probe of Python↔Mojo pointer interop under a new
    # interpreter: Mojo takes a bytearray's address from a zero-argument call
    # and writes through the pointer; Python must read those exact bytes back.
    try:
        var addr = ns["buf_addr"]()
        var ptr = addr.unsafe_get_as_pointer[DType.uint8]()
        comptime MSG = "m0canary"
        var msg = MSG.as_bytes()
        for i in range(8):
            ptr[unsafe_offset=i] = msg[i]
        var back = String(py=ns["readback"]())
        if back != "m0canary":
            print("probe: FAIL(ctypes-round-trip): read back '" + back + "'")
            raise Error("bytes did not survive the raw-address crossing")
    except e:
        print("probe: FAIL(ctypes-round-trip): " + String(e))
        raise Error("the ctypes address crossing failed")

    print("shim_mechanics=ok")
