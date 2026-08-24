"""The Mojo↔Python boundary, isolated to one file.

Everything that touches CPython lives here. The rest of the package works in
Mojo types and calls through `PyBridge`.

**Why nothing crosses as a `PythonObject` argument.** Mojo 1.0's
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
reads. **And the raw CPython C API**, which refcounts explicitly and is
reached through `Python().cpython()` — the same door `m0_wsgi.threaded` uses
for `PyEval_SaveThread`. That is the door the environ goes through.

**The environ is built here, in Mojo, through the C API.** `PyDict_New` and
`PyDict_SetItem` build the dict; `PyUnicode_DecodeUTF8` builds every key and
value; `PyTuple_New`/`PyTuple_SetItem`/`PyObject_CallObject` hand the
finished dict to the shim. `PyDict_SetItem` does not steal, so each string
this file creates is `Py_DecRef`'d the moment the dict has taken its own
reference; `PyTuple_SetItem` *does* steal, which is what gives the tuple the
environ. Every reference is accounted for by hand, and `smoke-django`'s RSS
guard is what proves it — 0 KB over 10k requests.

This replaced a design where Mojo serialized the whole request into a
length-prefixed blob and a zero-argument `handle()` parsed it back in pure
Python. That was correct and leak-free, but the parse was 28 Python-level
`_read_str` calls for a twelve-header request and cost 12.09 µs of the
bridge's 14.23 — 85% of it. See docs/WSGI_PERFORMANCE.md.

**Both bodies cross through `PyBytes_*`, loaded from the interpreter's own
handle** — see the `ExternalFunction` declarations below. The REQUEST body
becomes a real `bytes` via `PyBytes_FromStringAndSize` (one copy, inside the
call) and rides to the shim as a stolen tuple slot; `io.BytesIO(bytes)`
*shares* the immutable buffer until first write, so `wsgi.input` costs no
second copy. The RESPONSE body is read straight out of the returned `bytes`
via `PyBytes_AsString`. This retired the last piece of the original blob
design: the persistent transfer bytearray, its `buf_addr()` address call and
the grow protocol are gone, and the shim imports nothing but `io`.

`Python().cpython()` binds no `PyBytes_*` at all, and `external_call` cannot
reach them either because libpython is not on the link line; but the
stdlib's own `ExternalFunction[name, type].load(lib.borrow())` is how
`CPython` populates its bindings, and it works just as well for the ones it
omits. The whole C-API surface is therefore available to this file, not only
the part the stdlib chose to wrap.

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

`start_response` returns a real `write()` callable, not a no-op. Django never
calls it, so nothing in a Django-shaped test can tell the difference and this
silently discarded every byte written through it until `apps/wsgi_bare`
existed to ask. It is the reason that app is a bare callable rather than
another framework.

Request strings reach Python as the `str` a latin-1 decode would produce —
PEP 3333's convention for tunneling raw request bytes, which Django
re-encodes latin-1 and decodes UTF-8 itself. `environ.mojo` explains why
that is spelled as a UTF-8 encode here.
"""

from std.ffi import c_char, c_long, _CPointer
from std.memory import unsafe_memcpy
from std.python import Python, PythonObject
from std.python._cpython import ExternalFunction, PyObjectPtr, Py_ssize_t

from lightbug_http import HTTPRequest

from .environ import (
    all_ascii,
    append_cgi_name_as_utf8,
    append_latin1_as_utf8,
)


comptime SHIM_SOURCE = """
import io

_app = None

# Keeps the last response body alive after `run` returns, so the pointer
# Mojo takes into it (via PyBytes_AsString) stays valid until the next
# request replaces it.
_body = b''


def set_app(app):
    global _app
    _app = app


def run(environ, body):
    # Mojo built `environ` through the C API and `body` is a real bytes
    # built with PyBytes_FromStringAndSize; both arrive as stolen tuple
    # slots. BytesIO(bytes) SHARES the immutable buffer until first write
    # (measured: getsizeof(BytesIO(b)) is ~46 bytes over the header for a
    # 256-byte b), so this line copies nothing -- the request-body path's
    # single copy already happened inside PyBytes_FromStringAndSize.
    global _body
    environ['wsgi.input'] = io.BytesIO(body)

    captured = {}
    written = []

    def start_response(status, headers, exc_info=None):
        # PEP 3333: a second call without exc_info is an application error.
        # With exc_info it must replace the stored status and headers, and may
        # only re-raise once the headers have actually gone out -- which for a
        # fully-buffering server is never, so replacing is always the branch
        # taken here.
        if captured and exc_info is None:
            raise AssertionError('start_response() called twice without exc_info')
        captured['status'] = status
        captured['headers'] = headers
        return written.append

    result = _app(environ, start_response)
    try:
        # PEP 3333: everything passed to write() is transmitted before the
        # iterable's output. The iterable is drained FIRST even so, because an
        # application is allowed to call write() from inside the generator it
        # returned, and joining `written` before draining would drop those.
        chunks = b''.join(result)
        _body = b''.join(written) + chunks
    finally:
        close = getattr(result, 'close', None)
        if close is not None:
            close()
    return (captured.get('status', '500 Internal Server Error'),
            captured.get('headers', []), _body)
"""


# The two C-API functions this file needs and `Python().cpython()` does not
# bind. `external_call` cannot reach them: libpython is **not on the link
# line** — Mojo `dlopen`s it, which is exactly why `CPython` is a struct of
# loaded function pointers rather than a header. But that struct exposes its
# handle, and `ExternalFunction[name, type].load(lib.borrow())` is how the
# stdlib populates every one of its own bindings — the same door opens the
# ones it left out. Both are stable-ABI and *checked*: `PyBytes_AsString`
# returns NULL + TypeError for a non-`bytes` (where the `PyBytes_AS_STRING`
# macro would read the wrong offsets, and a macro is not a symbol anyway),
# and `PyBytes_FromStringAndSize` documents NULL-with-size-0 as valid.

comptime _PyBytes_AsString = ExternalFunction[
    "PyBytes_AsString",
    # char *PyBytes_AsString(PyObject *o)
    def(PyObjectPtr) thin abi("C") -> _CPointer[c_char, ImmutAnyOrigin],
]
"""The response body's exit: a direct read of the `bytes` buffer.
Measured at **1.0 ns**, against 1,095 ns for the `ctypes` round trip through
the shim that this replaced."""

comptime _PyBytes_FromStringAndSize = ExternalFunction[
    "PyBytes_FromStringAndSize",
    # PyObject *PyBytes_FromStringAndSize(const char *v, Py_ssize_t len)
    def(
        _CPointer[c_char, ImmutAnyOrigin], Py_ssize_t
    ) thin abi("C") -> PyObjectPtr,
]
"""The request body's entry: a real `bytes` built straight from the
request's own buffer. Returns a new reference; the copy happens inside.
Measured at **59 ns for 1 KB**, make and free."""


struct PyBridge(Movable):
    """Holds the interpreter-side helpers for one serving thread.

    One per process under prefork, one per thread under `M0_THREADS`;
    nothing here is shared between bridges. Construct once at startup, never
    per request.

    Every request costs exactly one call into Python — the
    `PyObject_CallObject` that runs `run(environ, body)`. Everything else,
    both directions of both bodies included, is C API.
    """

    var _ns: PythonObject
    """Namespace dict the shim was exec'd into."""
    var _run: PythonObject
    """The shim's `run`, resolved once. Called through `PyObject_CallObject`,
    never as a `PythonObject` call — see the module docstring."""
    var _base_keys: List[PythonObject]
    var _base_values: List[PythonObject]
    """The request-invariant environ entries, as parallel lists of finished
    Python objects. Built once in `set_base`; every request replays them
    into a fresh dict with `PyDict_SetItem`, which is a hash and a store
    each. Parallel lists rather than a `Dict` because the order does not
    matter and the pairing is positional — CLAUDE.md's SoA pattern."""

    var _k_method: PythonObject
    var _k_path: PythonObject
    var _k_query: PythonObject
    var _k_protocol: PythonObject
    """The four per-request key strings, interned once. They never vary, so
    building them per request would be four `PyUnicode_DecodeUTF8` calls
    and four frees for nothing."""

    var _bytes_as_string: _PyBytes_AsString.type
    var _bytes_from: _PyBytes_FromStringAndSize.type
    """The two `PyBytes_*` calls, resolved once from the interpreter's own
    handle. Loading is a `dlsym`; the calls it returns cost nanoseconds, so
    they are resolved here and never per request."""

    var _scratch_name: List[UInt8]
    var _scratch_value: List[UInt8]
    """Reused byte buffers for the two transforms that cannot be done in
    place: the CGI header name, and the latin-1 → UTF-8 re-encode for the
    values that need it. Kept on the bridge so a request allocates neither.
    Two of them because a header's name and value are in flight at once."""

    def __init__(out self) raises:
        var builtins = Python.import_module("builtins")
        self._ns = Python.dict()
        builtins.exec(PythonObject(SHIM_SOURCE), self._ns)
        self._run = self._ns["run"]

        self._base_keys = List[PythonObject]()
        self._base_values = List[PythonObject]()

        self._k_method = _py_str("REQUEST_METHOD")
        self._k_path = _py_str("PATH_INFO")
        self._k_query = _py_str("QUERY_STRING")
        self._k_protocol = _py_str("SERVER_PROTOCOL")

        ref cpy = Python().cpython()
        self._bytes_as_string = _PyBytes_AsString.load(cpy.lib.borrow())
        self._bytes_from = _PyBytes_FromStringAndSize.load(cpy.lib.borrow())

        self._scratch_name = List[UInt8](capacity=64)
        self._scratch_value = List[UInt8](capacity=256)

    def __init__(out self, *, deinit move: Self):
        self._ns = move._ns^
        self._run = move._run^
        self._base_keys = move._base_keys^
        self._base_values = move._base_values^
        self._k_method = move._k_method^
        self._k_path = move._k_path^
        self._k_query = move._k_query^
        self._k_protocol = move._k_protocol^
        self._bytes_as_string = move._bytes_as_string
        self._bytes_from = move._bytes_from
        self._scratch_name = move._scratch_name^
        self._scratch_value = move._scratch_value^

    def set_app(self, app: PythonObject) raises:
        """Install the WSGI callable. Startup-only: passing `app` as a call
        argument leaks one reference (see module docstring), which is
        harmless for an object that must outlive the process anyway."""
        _ = self._ns["set_app"](app)

    def set_base(
        mut self,
        server_name: String,
        server_port: String,
        multiprocess: Bool,
        multithread: Bool = False,
    ) raises:
        """Build the request-invariant environ entries, once.

        These used to live in a Python-side `_base` dict that `handle()`
        copied per request. They are Python objects either way; holding them
        here lets a request store them straight into its own dict without
        Python running at all.

        `multithread` is what `wsgi.multithread` reports: True when this
        bridge is one of several serving threads in a process (the threaded
        execution mode), False under prefork or a single loop.
        """
        ref cpy = Python().cpython()
        self._base_keys.clear()
        self._base_values.clear()

        self._add_base("SERVER_NAME", _py_str(server_name))
        self._add_base("SERVER_PORT", _py_str(server_port))
        self._add_base("SCRIPT_NAME", _py_str(""))
        self._add_base("REMOTE_ADDR", _py_str(""))
        self._add_base("wsgi.url_scheme", _py_str("http"))

        # (1, 0) — PyTuple_SetItem steals, so the two ints are handed over
        # and never freed here.
        var version = cpy.PyTuple_New(2)
        if not version:
            raise cpy.get_error()
        _ = cpy.PyTuple_SetItem(version, 0, cpy.PyLong_FromSsize_t(1))
        _ = cpy.PyTuple_SetItem(version, 1, cpy.PyLong_FromSsize_t(0))
        self._add_base("wsgi.version", PythonObject(from_owned=version))

        var sys = Python.import_module("sys")
        self._add_base("wsgi.errors", sys.stderr)

        self._add_base("wsgi.multithread", _py_bool(multithread))
        self._add_base("wsgi.multiprocess", _py_bool(multiprocess))
        self._add_base("wsgi.run_once", _py_bool(False))

    def _add_base(mut self, key: StringSlice, var value: PythonObject) raises:
        self._base_keys.append(_py_str(key))
        self._base_values.append(value^)

    # --- the per-request path ---------------------------------------------

    def build_environ(mut self, req: HTTPRequest) raises -> PythonObject:
        """Build one request's WSGI environ dict, entirely through the C API.

        Returns it as a `PythonObject` so the reference is owned and freed
        correctly whatever the caller does next; `run` hands it straight to
        the args tuple instead, which steals it.
        """
        ref cpy = Python().cpython()
        var d = cpy.PyDict_New()
        if not d:
            raise cpy.get_error()
        var environ = PythonObject(from_owned=d)

        # The invariant half: no strings are built, only stored.
        for i in range(len(self._base_keys)):
            var bk = self._base_keys[i]._obj_ptr
            var bv = self._base_values[i]._obj_ptr
            if cpy.PyDict_SetItem(d, bk, bv) != 0:
                raise cpy.get_error()

        # Each key pointer is copied out of `self` first: passing
        # `self._k_*._obj_ptr` straight in would alias `self` mutably (the
        # scratch buffers) and immutably (the key) in one call.
        var k_method = self._k_method._obj_ptr
        self._set_latin1(d, k_method, req.method.as_bytes())
        var k_path = self._k_path._obj_ptr
        self._set_latin1(d, k_path, req.uri.path.as_bytes())
        var k_query = self._k_query._obj_ptr
        self._set_latin1(d, k_query, req.uri.query_string.as_bytes())
        var k_protocol = self._k_protocol._obj_ptr
        self._set_latin1(d, k_protocol, req.protocol.as_bytes())

        # Walked by index over the header map's own spans: no `keys()`
        # snapshot, no `get()` lookup per key, no String anywhere.
        for i in range(req.headers.count()):
            self._scratch_name.clear()
            append_cgi_name_as_utf8(
                self._scratch_name, req.headers.name_span(i)
            )
            var key = cpy.PyUnicode_DecodeUTF8(
                StringSlice(unsafe_from_utf8=Span(self._scratch_name))
            )
            if not key:
                raise cpy.get_error()
            try:
                self._set_latin1(d, key, req.headers.value_span(i))
            finally:
                cpy.Py_DecRef(key)

        return environ^

    def _set_latin1(
        mut self, d: PyObjectPtr, key: PyObjectPtr, value: Span[Byte, _]
    ) raises:
        """Store `value`'s latin-1 text under `key`, freeing what it built.

        `PyDict_SetItem` does not steal, so the freshly decoded string is
        released as soon as the dict has taken its own reference. Missing
        that `Py_DecRef` is exactly the unbounded per-request leak this
        whole design exists to avoid, and `smoke-django`'s RSS guard is
        what would catch it.
        """
        ref cpy = Python().cpython()
        var s: PyObjectPtr
        if all_ascii(value):
            # ASCII is its own UTF-8: hand CPython the request's own bytes.
            s = cpy.PyUnicode_DecodeUTF8(StringSlice(unsafe_from_utf8=value))
        else:
            self._scratch_value.clear()
            append_latin1_as_utf8(self._scratch_value, value)
            s = cpy.PyUnicode_DecodeUTF8(
                StringSlice(unsafe_from_utf8=Span(self._scratch_value))
            )
        if not s:
            raise cpy.get_error()
        var rc = cpy.PyDict_SetItem(d, key, s)
        cpy.Py_DecRef(s)
        if rc != 0:
            raise cpy.get_error()

    def run(mut self, req: HTTPRequest) raises -> PythonObject:
        """Run one request through the application.

        Returns the Python `(status, headers, body)` tuple. Raises whatever
        the application raised, carrying the Python message.
        """
        ref cpy = Python().cpython()
        var environ = self.build_environ(req)

        # The request body becomes a real `bytes`, built straight from the
        # request's own buffer: one copy, inside PyBytes_FromStringAndSize.
        # An empty body is fine down this same path -- CPython documents a
        # NULL `v` (what an unallocated List's pointer is) with size 0 as
        # valid, answering the empty-bytes singleton without reading `v`.
        var body = self._bytes_from(
            req.body_raw.unsafe_ptr()
            .unsafe_bitcast[c_char]()
            .as_imm()
            .as_unsafe_any_origin(),
            Py_ssize_t(len(req.body_raw)),
        )
        if not body:
            raise cpy.get_error()

        # PyTuple_SetItem steals both values, so the tuple owns the environ
        # and the body from here, and one Py_DecRef of the tuple frees the
        # lot -- including on the raising path, which is why the DecRef comes
        # before the check.
        var args = cpy.PyTuple_New(2)
        if not args:
            cpy.Py_DecRef(body)
            raise cpy.get_error()
        _ = cpy.PyTuple_SetItem(args, 0, environ^.steal_data())
        _ = cpy.PyTuple_SetItem(args, 1, body)

        var result = cpy.PyObject_CallObject(self._run._obj_ptr, args)
        cpy.Py_DecRef(args)
        if not result:
            raise cpy.get_error()
        return PythonObject(from_owned=result)

    def body_bytes(self, body: PythonObject) raises -> List[UInt8]:
        """Copy the response body into a Mojo list, binary-safe.

        Reads straight out of the `bytes` object's buffer, so a response body
        that is a PNG or a gzip stream survives intact — a latin-1 round trip
        through `String` would not, because Mojo strings are UTF-8.

        **No Python runs here at all.** The length comes from
        `PyObject_Length` and the address from `PyBytes_AsString`, both direct
        C calls; the copy is one `memcpy`. This used to be `len(body)` plus a
        zero-argument `body_addr()` into a shim function that built two
        `ctypes` objects, and it cost **1.07 µs — 31% of the whole bridge**,
        of which the call was 1.095 µs and the `len()` three nanoseconds. The
        byte-at-a-time loop it also replaces mattered only for large bodies.

        The shim's `_body` global keeps the object alive until the next
        request, and `body` is held past the copy below for the same reason:
        Mojo destroys at last use, so without it the last reference could be
        released while the `memcpy` is still reading through the pointer.
        """
        ref cpy = Python().cpython()
        var n = Int(cpy.PyObject_Length(body._obj_ptr))
        if n < 0:
            # -1 means an exception is already set. Returning "empty body"
            # here would swallow it AND leave it pending, poisoning whatever
            # C-API call runs next; get_error converts and clears it.
            raise cpy.get_error()
        if n == 0:
            return List[UInt8]()
        var maybe = self._bytes_as_string(body._obj_ptr)
        if not maybe:
            raise cpy.get_error()
        var out = List[UInt8](unsafe_uninit_length=n)
        unsafe_memcpy(
            dest=out.unsafe_ptr(),
            src=maybe.unsafe_value().unsafe_bitcast[UInt8](),
            count=n,
        )
        _ = body
        return out^

    # --- diagnostic probes -------------------------------------------------
    #
    # `scripts/bench_bridge_parts.mojo` uses these to split the per-request
    # cost into its parts. They are the same operations `run` performs,
    # exposed individually; nothing in the serving path calls them.

    def probe_build_environ(mut self, req: HTTPRequest) raises:
        """The C-API environ build alone, without running the application."""
        var d = self.build_environ(req)
        _ = d


def _py_str(s: StringSlice) raises -> PythonObject:
    """A Python `str` from ASCII/UTF-8 Mojo text, through the C API."""
    ref cpy = Python().cpython()
    var p = cpy.PyUnicode_DecodeUTF8(s)
    if not p:
        raise cpy.get_error()
    return PythonObject(from_owned=p)


def _py_bool(b: Bool) raises -> PythonObject:
    """A Python `bool`, through the C API."""
    ref cpy = Python().cpython()
    var p = cpy.PyBool_FromLong(c_long(1) if b else c_long(0))
    if not p:
        raise cpy.get_error()
    return PythonObject(from_owned=p)
