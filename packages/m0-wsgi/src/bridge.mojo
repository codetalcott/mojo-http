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
the grow protocol are gone, and the shim imports nothing but `io` at exec
time — the ASGI half imports `asyncio` and friends lazily, so a WSGI app
never pays for them.

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
from std.python._cpython import (
    CPython,
    ExternalFunction,
    PyObjectPtr,
    Py_ssize_t,
)

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

# --- the ASGI half -----------------------------------------------------
# One persistent event loop per bridge namespace (so per worker, per
# serving thread, and per pool thread -- each has its own bridge). Each
# ASGI request runs to completion on it, buffered: real await-concurrency
# is the asyncio executor's job, not this bridge's.
_is_asgi = False
_loop = None
_lifespan_state = {}
_lifespan_rq = None
_lifespan_task = None
_lifespan_ok = False

# A buffered response body larger than this is refused rather than grown
# without bound; a streaming response (`more_body=True`) that has not
# finished after the grace is an infinite stream (SSE/EventStream), which
# the buffered bridge cannot carry.
_ASGI_BUFFER_CAP = 16 * 1024 * 1024
_ASGI_STREAM_GRACE = 10.0


def set_app(app, forced='auto'):
    global _app, _is_asgi
    _app = app
    if forced == 'auto':
        _is_asgi = _detect(app) == 'asgi'
    else:
        _is_asgi = (forced == 'asgi')
    if _is_asgi:
        _asgi_init()
    return 'asgi' if _is_asgi else 'wsgi'


def _detect(app):
    # The duck-typing uvicorn and asgiref agree on: an ASGI application is
    # a coroutine function, or an object whose __call__ is one (Starlette
    # and FastHTML instances, Django's ASGIHandler,
    # asgiref.markcoroutinefunction). functools.partial is unwrapped first
    # so a partial over either kind detects as the thing it wraps.
    import functools, inspect
    target = app
    while isinstance(target, functools.partial):
        target = target.func
    if not callable(target):
        raise ValueError(
            'the application object is not callable: expected a WSGI '
            'callable app(environ, start_response) or an ASGI callable '
            'async app(scope, receive, send), got %s'
            % type(target).__name__)
    if inspect.iscoroutinefunction(target):
        return 'asgi'
    call = getattr(target, '__call__', None)
    if call is not None and inspect.iscoroutinefunction(call):
        return 'asgi'
    return 'wsgi'


def detect_spec(module_name, attribute):
    # Startup-only: import and classify without installing anything.
    import importlib
    return _detect(getattr(importlib.import_module(module_name), attribute))


def _asgi_init():
    global _loop
    import asyncio
    if _loop is None:
        _loop = asyncio.new_event_loop()
        # Thread-local, so per-bridge loops never collide across serving
        # threads.
        asyncio.set_event_loop(_loop)
    _lifespan_startup()


def _lifespan_startup():
    # uvicorn's "auto" lifespan: offer the protocol, and treat an
    # application that errors on the lifespan scope as one that does not
    # speak it. An explicit startup.failed is fatal -- Starlette apps use
    # it to refuse to serve half-initialized.
    global _lifespan_rq, _lifespan_task, _lifespan_ok
    import asyncio
    scope = {
        'type': 'lifespan',
        'asgi': {'version': '3.0', 'spec_version': '2.0'},
        'state': _lifespan_state,
    }
    _lifespan_rq = asyncio.Queue()
    started = _loop.create_future()

    async def receive():
        return await _lifespan_rq.get()

    async def send(message):
        t = message.get('type', '')
        if not started.done():
            if t == 'lifespan.startup.complete':
                started.set_result(True)
            elif t == 'lifespan.startup.failed':
                started.set_exception(RuntimeError(
                    'ASGI lifespan startup failed: %s'
                    % message.get('message', '')))

    _lifespan_task = _loop.create_task(_app(scope, receive, send))
    _lifespan_rq.put_nowait({'type': 'lifespan.startup'})

    async def wait_started():
        await asyncio.wait({_lifespan_task, started},
                           return_when=asyncio.FIRST_COMPLETED)
        if _lifespan_task.done() and not started.done():
            # Returned or raised without answering: lifespan unsupported.
            # The exception (usually "unknown scope type") is retrieved so
            # the loop never logs "exception was never retrieved".
            if not _lifespan_task.cancelled():
                _ = _lifespan_task.exception()
            return False
        return bool(await started)

    _lifespan_ok = _loop.run_until_complete(wait_started())


def lifespan_shutdown():
    global _lifespan_task
    import asyncio
    if _loop is None or _loop.is_closed():
        return
    if (_lifespan_ok and _lifespan_task is not None
            and not _lifespan_task.done()):
        _lifespan_rq.put_nowait({'type': 'lifespan.shutdown'})
        try:
            _loop.run_until_complete(asyncio.wait_for(
                asyncio.shield(_lifespan_task), 5.0))
        except Exception:
            pass
    if _lifespan_task is not None and not _lifespan_task.done():
        _lifespan_task.cancel()
        try:
            _loop.run_until_complete(asyncio.gather(
                _lifespan_task, return_exceptions=True))
        except Exception:
            pass
    _lifespan_task = None
    _loop.close()


def _scope_from_environ(environ):
    # The reverse of the CGI transform build_environ applied; latin-1 is
    # PEP 3333's byte tunnel, so encoding it back yields the request's own
    # bytes. ASGI wants `path` decoded UTF-8 and the rest as bytes.
    headers = []
    for key, value in environ.items():
        if key == 'CONTENT_TYPE':
            headers.append((b'content-type', value.encode('latin-1')))
        elif key == 'CONTENT_LENGTH':
            headers.append((b'content-length', value.encode('latin-1')))
        elif key.startswith('HTTP_'):
            headers.append((
                key[5:].replace('_', '-').lower().encode('latin-1'),
                value.encode('latin-1')))
    try:
        port = int(environ.get('SERVER_PORT', '') or 0)
    except ValueError:
        port = 0
    raw_path = environ.get('PATH_INFO', '').encode('latin-1')
    return {
        'type': 'http',
        'asgi': {'version': '3.0', 'spec_version': '2.3'},
        'http_version':
            environ.get('SERVER_PROTOCOL', 'HTTP/1.1').split('/')[-1],
        'method': environ.get('REQUEST_METHOD', 'GET'),
        'scheme': environ.get('wsgi.url_scheme', 'http'),
        'path': raw_path.decode('utf-8', 'replace'),
        # Best effort: the loop hands over the decoded path, so the
        # percent-encoded original is not available here.
        'raw_path': raw_path,
        'query_string': environ.get('QUERY_STRING', '').encode('latin-1'),
        'root_path': environ.get('SCRIPT_NAME', ''),
        'headers': headers,
        'server': (environ.get('SERVER_NAME', ''), port),
        'client': None,
        # A shallow copy per request, matching uvicorn: the app may add
        # request-scoped keys without polluting the lifespan state.
        'state': dict(_lifespan_state),
    }


def _run_asgi(environ, body):
    global _body
    import asyncio
    from http.client import responses as _reasons

    scope = _scope_from_environ(environ)
    delivered = []
    captured = {'status': None, 'headers': []}
    chunks = []
    total = [0]
    streaming = _loop.create_future()

    async def receive():
        # The whole body in one message -- the buffered bridge's contract.
        if not delivered:
            delivered.append(True)
            return {'type': 'http.request', 'body': body,
                    'more_body': False}
        # uvicorn parity: a further receive() WAITS -- for a disconnect a
        # buffered bridge can never observe mid-request. Answering
        # http.disconnect here instead makes Starlette's streaming
        # responses (which race receive against their own send loop) stop
        # after one chunk and answer a truncated 200 that looks fine.
        # Waiting means a streaming app meets the watchdog's explanatory
        # error, and an app that blocks on receive without streaming hangs
        # exactly as a hung WSGI view does -- documented parity.
        await _loop.create_future()

    async def send(message):
        t = message.get('type', '')
        if t == 'http.response.start':
            captured['status'] = int(message.get('status', 500))
            captured['headers'] = list(message.get('headers', []))
        elif t == 'http.response.body':
            chunk = bytes(message.get('body', b'') or b'')
            if chunk:
                chunks.append(chunk)
                total[0] += len(chunk)
                if total[0] > _ASGI_BUFFER_CAP:
                    raise RuntimeError(
                        'ASGI response body exceeded the buffered '
                        'bridge cap (%d bytes)' % _ASGI_BUFFER_CAP)
            if message.get('more_body', False) and not streaming.done():
                streaming.set_result(True)

    task = _loop.create_task(_app(scope, receive, send))

    async def drive():
        await asyncio.wait({task, streaming},
                           return_when=asyncio.FIRST_COMPLETED)
        if not task.done():
            # A streaming response: give a finite chunked body its grace,
            # and call an unfinished one what it is.
            try:
                await asyncio.wait_for(asyncio.shield(task),
                                       _ASGI_STREAM_GRACE)
            except asyncio.TimeoutError:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)
                raise RuntimeError(
                    'ASGI streaming response did not complete within '
                    '%.0fs -- infinite streams (SSE/EventStream) are not '
                    'supported by the buffered ASGI bridge; see '
                    'docs/WSGI_VS_ASGI.md section 8'
                    % _ASGI_STREAM_GRACE) from None
        await task

    _loop.run_until_complete(drive())

    if captured['status'] is None:
        raise RuntimeError(
            'ASGI application completed without sending '
            'http.response.start')
    status = captured['status']
    headers = [(n.decode('latin-1'), v.decode('latin-1'))
               for n, v in captured['headers']]
    _body = b''.join(chunks)
    return ('%d %s' % (status, _reasons.get(status, '')), headers, _body)


def run(environ, body):
    if _is_asgi:
        return _run_asgi(environ, body)
    return _run_wsgi(environ, body)


def _run_wsgi(environ, body):
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

comptime _PyDict_Copy = ExternalFunction[
    "PyDict_Copy",
    # PyObject *PyDict_Copy(PyObject *p)
    def(PyObjectPtr) thin abi("C") -> PyObjectPtr,
]
"""How each request's environ starts: one copy of the finished base
template. Returns a new reference. Measured at **58 ns** for the ten
request-invariant entries, against **214 ns** for storing them one
`PyDict_SetItem` at a time — which is what this replaced."""


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
    var _base: PythonObject
    """The request-invariant environ entries, held as one finished Python
    dict. Built in `set_base`; every request starts from
    `PyDict_Copy(_base)` — one C call instead of a hash-and-store per
    entry."""

    var _k_method: PythonObject
    var _k_path: PythonObject
    var _k_query: PythonObject
    var _k_protocol: PythonObject
    """The four per-request key strings, interned once. They never vary, so
    building them per request would be four `PyUnicode_DecodeUTF8` calls
    and four frees for nothing."""

    var _bytes_as_string: _PyBytes_AsString.type
    var _bytes_from: _PyBytes_FromStringAndSize.type
    var _dict_copy: _PyDict_Copy.type
    """The unbound C-API calls, resolved once from the interpreter's own
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

        self._k_method = _py_str("REQUEST_METHOD")
        self._k_path = _py_str("PATH_INFO")
        self._k_query = _py_str("QUERY_STRING")
        self._k_protocol = _py_str("SERVER_PROTOCOL")

        ref cpy = Python().cpython()
        self._bytes_as_string = _PyBytes_AsString.load(cpy.lib.borrow())
        self._bytes_from = _PyBytes_FromStringAndSize.load(cpy.lib.borrow())
        self._dict_copy = _PyDict_Copy.load(cpy.lib.borrow())

        # An empty template until set_base runs, so build_environ is never
        # copying an absent dict.
        var empty = cpy.PyDict_New()
        if not empty:
            raise cpy.get_error()
        self._base = PythonObject(from_owned=empty)

        self._scratch_name = List[UInt8](capacity=64)
        self._scratch_value = List[UInt8](capacity=256)

    def __init__(out self, *, deinit move: Self):
        self._ns = move._ns^
        self._run = move._run^
        self._base = move._base^
        self._k_method = move._k_method^
        self._k_path = move._k_path^
        self._k_query = move._k_query^
        self._k_protocol = move._k_protocol^
        self._bytes_as_string = move._bytes_as_string
        self._bytes_from = move._bytes_from
        self._dict_copy = move._dict_copy
        self._scratch_name = move._scratch_name^
        self._scratch_value = move._scratch_value^

    def set_app(self, app: PythonObject, forced: String = "auto") raises -> String:
        """Install the application callable and resolve its protocol.

        `forced` is `auto` (detect from the object), `wsgi`, or `asgi`;
        the return value is the protocol the shim resolved. For an ASGI
        application this also creates the bridge's persistent asyncio loop
        and runs lifespan startup, so a `lifespan.startup.failed` raises
        here — at startup, where it belongs.

        Startup-only: passing `app` and `forced` as call arguments leaks
        one reference each (see module docstring), which is harmless for a
        bounded number of calls at construction."""
        var result = self._ns["set_app"](app, PythonObject(forced))
        return String(py=result)

    def lifespan_shutdown(self) raises:
        """Run ASGI lifespan shutdown and close the bridge's loop.

        A no-op for WSGI (the shim guards on a missing loop). Call once at
        teardown, on the thread that owns this bridge, inside its attached
        region — never per request."""
        _ = self._ns["lifespan_shutdown"]()

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
        var d = cpy.PyDict_New()
        if not d:
            raise cpy.get_error()
        # Owned from the first line, so a raise below frees the half-built
        # template instead of leaking it, and a second set_base replaces the
        # old one cleanly.
        var base = PythonObject(from_owned=d)

        _base_set(d, "SERVER_NAME", _py_str(server_name))
        _base_set(d, "SERVER_PORT", _py_str(server_port))
        _base_set(d, "SCRIPT_NAME", _py_str(""))
        _base_set(d, "REMOTE_ADDR", _py_str(""))
        _base_set(d, "wsgi.url_scheme", _py_str("http"))

        # (1, 0) — PyTuple_SetItem steals, so the two ints are handed over
        # and never freed here.
        var version = cpy.PyTuple_New(2)
        if not version:
            raise cpy.get_error()
        _ = cpy.PyTuple_SetItem(version, 0, cpy.PyLong_FromSsize_t(1))
        _ = cpy.PyTuple_SetItem(version, 1, cpy.PyLong_FromSsize_t(0))
        _base_set(d, "wsgi.version", PythonObject(from_owned=version))

        var sys = Python.import_module("sys")
        _base_set(d, "wsgi.errors", sys.stderr)

        _base_set(d, "wsgi.multithread", _py_bool(multithread))
        _base_set(d, "wsgi.multiprocess", _py_bool(multiprocess))
        _base_set(d, "wsgi.run_once", _py_bool(False))

        self._base = base^

    # --- the per-request path ---------------------------------------------

    def build_environ(mut self, req: HTTPRequest) raises -> PythonObject:
        """Build one request's WSGI environ dict, entirely through the C API.

        Returns it as a `PythonObject` so the reference is owned and freed
        correctly whatever the caller does next; `run` hands it straight to
        the args tuple instead, which steals it.
        """
        # Acquired once and threaded through every helper below: the
        # re-acquisition is only ~2 ns, but sixteen of them per request is
        # pure overhead for a value that cannot change mid-request.
        ref cpy = Python().cpython()

        # The invariant half arrives in ONE call: a copy of the finished
        # base template. Measured 58 ns against 214 for replaying the same
        # ten entries through PyDict_SetItem.
        var d = self._dict_copy(self._base._obj_ptr)
        if not d:
            raise cpy.get_error()
        var environ = PythonObject(from_owned=d)

        # Each key pointer is copied out of `self` first: passing
        # `self._k_*._obj_ptr` straight in would alias `self` mutably (the
        # scratch buffers) and immutably (the key) in one call.
        var k_method = self._k_method._obj_ptr
        self._set_latin1(cpy, d, k_method, req.method.as_bytes())
        var k_path = self._k_path._obj_ptr
        self._set_latin1(cpy, d, k_path, req.uri.path.as_bytes())
        var k_query = self._k_query._obj_ptr
        self._set_latin1(cpy, d, k_query, req.uri.query_string.as_bytes())
        var k_protocol = self._k_protocol._obj_ptr
        self._set_latin1(cpy, d, k_protocol, req.protocol.as_bytes())

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
                self._set_latin1(cpy, d, key, req.headers.value_span(i))
            finally:
                cpy.Py_DecRef(key)

        return environ^

    def _set_latin1(
        mut self,
        ref cpy: CPython,
        d: PyObjectPtr,
        key: PyObjectPtr,
        value: Span[Byte, _],
    ) raises:
        """Store `value`'s latin-1 text under `key`, freeing what it built.

        `PyDict_SetItem` does not steal, so the freshly decoded string is
        released as soon as the dict has taken its own reference. Missing
        that `Py_DecRef` is exactly the unbounded per-request leak this
        whole design exists to avoid, and `smoke-django`'s RSS guard is
        what would catch it.
        """
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


def _base_set(d: PyObjectPtr, key: StringSlice, var value: PythonObject) raises:
    """Store one entry in the base template.

    `PyDict_SetItem` does not steal, and both the fresh key and `value` are
    owned `PythonObject`s — their destructors release them once the dict
    holds its own references, so there is no manual DecRef to forget.
    """
    ref cpy = Python().cpython()
    var k = _py_str(key)
    if cpy.PyDict_SetItem(d, k._obj_ptr, value._obj_ptr) != 0:
        raise cpy.get_error()


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
