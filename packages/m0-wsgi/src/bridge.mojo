"""The Mojo↔Python boundary, isolated to one file.

Everything that touches CPython lives here. The rest of the package works in
Mojo types and calls through `PyBridge`.

Two design choices are load-bearing:

**The shim is a string, not a file.** `SHIM_SOURCE` is `exec`'d into a fresh
namespace dict at startup. A `.py` file next to the source would have to be
located at run time relative to a compiled binary — an unforced deployment
failure. A string is compiled into the binary and cannot go missing.

**WSGI's `start_response` is implemented in Python.** WSGI hands the
application a callable that the *server* supplies, and building a Python
callable that closes over Mojo state is the hardest thing at this boundary.
The shim does it instead, so `call_app` is a single call in and a 3-tuple out.
No Mojo-side callables, no iterator protocol driven from Mojo.

Bytes cross as raw addresses, because neither direction has a supported
conversion:

- **Python → Mojo** is zero-copy. `ctypes.c_char_p(b)` borrows the `bytes`
  object's own buffer; `PythonObject.unsafe_get_as_pointer` turns the address
  into an `UnsafePointer`. The `bytes` object must outlive the read, which is
  why `body_bytes` takes the object and the caller holds it.
- **Mojo → Python** copies once, via `ctypes.string_at`. Unavoidable: a Python
  `bytes` owns its buffer.
"""

from std.python import Python, PythonObject


comptime SHIM_SOURCE = """
import ctypes, io, sys


def call_app(app, environ):
    captured = {}

    def start_response(status, headers, exc_info=None):
        captured['status'] = status
        captured['headers'] = headers
        return lambda data: None

    body = b''.join(app(environ, start_response))
    return captured.get('status', '500 Internal Server Error'), \
        captured.get('headers', []), body


def buf_addr(b):
    return ctypes.cast(ctypes.c_char_p(b), ctypes.c_void_p).value


def make_input(addr, n):
    return io.BytesIO(ctypes.string_at(addr, n) if n else b'')


def stderr():
    return sys.stderr
"""


struct PyBridge(Movable):
    """Holds the interpreter-side helpers for one process.

    Construct once at startup, never per request — `exec`'ing the shim is
    cheap but the point is that each request costs exactly one call into
    Python.
    """

    var _ns: PythonObject
    """Namespace dict the shim was exec'd into."""

    def __init__(out self) raises:
        var builtins = Python.import_module("builtins")
        self._ns = Python.dict()
        builtins.exec(PythonObject(SHIM_SOURCE), self._ns)

    def __init__(out self, *, deinit move: Self):
        self._ns = move._ns^

    def call_app(
        self, app: PythonObject, environ: PythonObject
    ) raises -> PythonObject:
        """Run a WSGI application. Returns `(status, headers, body)`.

        Any exception the application raises — including a Django view's —
        propagates here as a Mojo error carrying the Python message.
        """
        return self._ns["call_app"](app, environ)

    def make_input(self, body: Span[UInt8, _]) raises -> PythonObject:
        """Wrap request body bytes in a `BytesIO` for `wsgi.input`.

        Copies. `body` need not outlive the call.
        """
        if len(body) == 0:
            return self._ns["make_input"](0, 0)
        return self._ns["make_input"](Int(body.unsafe_ptr()), len(body))

    def stderr(self) raises -> PythonObject:
        """`sys.stderr`, for `wsgi.errors`."""
        return self._ns["stderr"]()

    def body_bytes(self, body: PythonObject) raises -> List[UInt8]:
        """Copy a Python `bytes` into a Mojo list, binary-safe.

        Reads straight out of the object's buffer, so a response body that is
        a PNG or a gzip stream survives intact — a latin-1 round trip through
        `String` would not, because Mojo strings are UTF-8.
        """
        var n = Int(len(body))
        var out = List[UInt8](capacity=n)
        if n == 0:
            return out^
        var addr = self._ns["buf_addr"](body)
        var ptr = addr.unsafe_get_as_pointer[DType.uint8]()
        for i in range(n):
            out.append(ptr[unsafe_offset=i])
        # `body` must stay alive until the copy is done; the read above borrows
        # its buffer.
        _ = body
        return out^
