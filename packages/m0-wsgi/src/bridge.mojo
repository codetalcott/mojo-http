"""The Mojo↔Python boundary, isolated to one file.

Everything that touches CPython lives here. The rest of the package works in
Mojo types and calls through `PyBridge`.

**Why requests cross as a byte blob, not as Python objects.** Mojo 1.0's
`PythonObject` interop leaks one reference per call *argument* and one per
`__setitem__` *value* (measured directly: `sys.getrefcount` of a dict passed
to a no-op function grows by exactly the call count; 2000 distinct strings
assigned to one dict key pin all 2000). A bridge that built the environ dict
with Mojo setitems and passed it to the application leaked the entire environ
— dict, strings, `BytesIO` — on every request, ~2.3 KB/request, which grew
the CPython heap without bound and turned gen-2 GC into 100 ms+ event-loop
pauses on a long-lived worker.

The operations that measurably do NOT leak: zero-argument calls, call
*results* (owned and destroyed correctly), `len()`, and `String(py=...)`
reads. So the request crosses through a persistent Python-side `bytearray`:
Mojo writes a length-prefixed blob into its buffer (raw pointer, no Python
objects), and the zero-argument `handle()` parses it, builds the environ
natively, runs the application, and returns `(status, headers, body)` as a
result. The response body's address comes from zero-argument `body_addr()`,
with the shim holding the `bytes` alive in a global until the next request.

Per-request Python-object traffic is therefore: zero-arg calls and their
results only. The leaky operations are still used exactly twice, in
`set_app` and `set_base` at startup, where leaking a reference to objects
that must live for the process lifetime anyway is harmless.

**The shim is a string, not a file.** `SHIM_SOURCE` is `exec`'d into a fresh
namespace dict at startup. A `.py` file next to the source would have to be
located at run time relative to a compiled binary — an unforced deployment
failure. A string is compiled into the binary and cannot go missing.

**WSGI's `start_response` is implemented in Python.** WSGI hands the
application a callable that the *server* supplies, and building a Python
callable that closes over Mojo state is the hardest thing at this boundary.
The shim does it instead. The shim also calls `close()` on the application's
result iterable, as PEP 3333 requires — Django's `request_finished` cleanup
hangs off it.

Blob strings decode as latin-1 on the Python side, which is PEP 3333's
convention for tunneling raw request bytes through `str`: Django re-encodes
latin-1 and decodes UTF-8 itself.
"""

from std.python import Python, PythonObject


# The initial bytearray size below must match _INITIAL_BUF_CAP in PyBridge.
comptime SHIM_SOURCE = """
import ctypes, io, sys

_app = None
_base = {}
_buf = bytearray(65536)
_body = b''


def set_app(app):
    global _app
    _app = app


def set_base(name, port, multiprocess):
    _base.update({
        'SERVER_NAME': name,
        'SERVER_PORT': port,
        'SCRIPT_NAME': '',
        'REMOTE_ADDR': '',
        'wsgi.version': (1, 0),
        'wsgi.url_scheme': 'http',
        'wsgi.errors': sys.stderr,
        'wsgi.multithread': False,
        'wsgi.multiprocess': bool(multiprocess),
        'wsgi.run_once': False,
    })


def buf_addr():
    return ctypes.addressof(ctypes.c_char.from_buffer(_buf))


def grow():
    # Mojo wrote the required size into the first 8 bytes before calling.
    global _buf
    need = int.from_bytes(_buf[:8], 'little')
    _buf = bytearray(need)
    return buf_addr()


def _read_str(mv, off):
    n = int.from_bytes(mv[off:off + 4], 'little')
    off += 4
    return str(mv[off:off + n], 'latin-1'), off + n


def handle():
    global _body
    mv = memoryview(_buf)
    off = 8
    environ = dict(_base)
    for key in ('REQUEST_METHOD', 'PATH_INFO', 'QUERY_STRING', 'SERVER_PROTOCOL'):
        environ[key], off = _read_str(mv, off)
    n_headers = int.from_bytes(mv[off:off + 4], 'little')
    off += 4
    for _ in range(n_headers):
        k, off = _read_str(mv, off)
        v, off = _read_str(mv, off)
        environ[k] = v
    n_body = int.from_bytes(mv[off:off + 4], 'little')
    off += 4
    environ['wsgi.input'] = io.BytesIO(mv[off:off + n_body].tobytes())

    captured = {}

    def start_response(status, headers, exc_info=None):
        captured['status'] = status
        captured['headers'] = headers
        return lambda data: None

    result = _app(environ, start_response)
    try:
        _body = b''.join(result)
    finally:
        close = getattr(result, 'close', None)
        if close is not None:
            close()
    return (captured.get('status', '500 Internal Server Error'),
            captured.get('headers', []), _body)


def body_addr():
    return ctypes.cast(ctypes.c_char_p(_body), ctypes.c_void_p).value or 0
"""


struct PyBridge(Movable):
    """Holds the interpreter-side helpers for one process.

    Construct once at startup, never per request. Each request costs three
    zero-argument calls into Python: `buf_addr`, `handle`, and (for non-empty
    bodies) `body_addr`.
    """

    var _ns: PythonObject
    """Namespace dict the shim was exec'd into."""
    var _buf_cap: Int
    """Current capacity of the shim's transfer bytearray. Mirrors the Python
    side: the initial value matches the shim's `bytearray(65536)`, and both
    sides move in lockstep through `grow()`."""

    def __init__(out self) raises:
        var builtins = Python.import_module("builtins")
        self._ns = Python.dict()
        builtins.exec(PythonObject(SHIM_SOURCE), self._ns)
        self._buf_cap = 65536

    def __init__(out self, *, deinit move: Self):
        self._ns = move._ns^
        self._buf_cap = move._buf_cap

    def set_app(self, app: PythonObject) raises:
        """Install the WSGI callable. Startup-only: passing `app` as a call
        argument leaks one reference (see module docstring), which is
        harmless for an object that must outlive the process anyway."""
        _ = self._ns["set_app"](app)

    def set_base(
        self, server_name: String, server_port: String, multiprocess: Bool
    ) raises:
        """Install the request-invariant environ entries. Startup-only; the
        same bounded argument-reference leak as `set_app` applies."""
        _ = self._ns["set_base"](
            PythonObject(server_name),
            PythonObject(server_port),
            PythonObject(multiprocess),
        )

    def handle(mut self, payload: Span[UInt8, _]) raises -> PythonObject:
        """Run one request through the application.

        `payload` is the blob from `serialize_request`. Returns the Python
        `(status, headers, body)` tuple. Raises whatever the application
        raised, carrying the Python message.
        """
        var need = len(payload) + 8
        if need > self._buf_cap:
            # Tell the shim how much to allocate: the size goes through the
            # first 8 bytes of the *old* buffer, so even this crossing needs
            # no Python-object argument.
            var old_addr = self._ns["buf_addr"]()
            var old_ptr = old_addr.unsafe_get_as_pointer[DType.uint8]()
            var n = need
            for i in range(8):
                old_ptr[unsafe_offset=i] = UInt8(n & 0xFF)
                n >>= 8
            _ = self._ns["grow"]()
            self._buf_cap = need
        var addr = self._ns["buf_addr"]()
        var ptr = addr.unsafe_get_as_pointer[DType.uint8]()
        for i in range(len(payload)):
            ptr[unsafe_offset=i + 8] = payload[i]
        return self._ns["handle"]()

    def body_bytes(self, body: PythonObject) raises -> List[UInt8]:
        """Copy the response body into a Mojo list, binary-safe.

        Reads straight out of the `bytes` object's buffer, so a response body
        that is a PNG or a gzip stream survives intact — a latin-1 round trip
        through `String` would not, because Mojo strings are UTF-8. The
        address comes from the zero-argument `body_addr()`; the shim's
        `_body` global keeps the object alive until the next request.
        """
        var n = Int(len(body))
        var out = List[UInt8](capacity=n)
        if n == 0:
            return out^
        var addr = self._ns["body_addr"]()
        var ptr = addr.unsafe_get_as_pointer[DType.uint8]()
        for i in range(n):
            out.append(ptr[unsafe_offset=i])
        _ = body
        return out^
