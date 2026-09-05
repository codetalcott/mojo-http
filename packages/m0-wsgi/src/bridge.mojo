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

**The shim is a Python file rendered into a string.** Its source of truth
is `packages/m0-wsgi/shim/m0_shim.py` — an ordinary Python file that
editors, pyflakes and `poe test-shim` read as one — and
`scripts/render_shim.py` renders it into `SHIM_SOURCE` in `shim_source.mojo`
(committed, generated, checked current by `poe check-docs`), which this
file imports and `exec`s into a fresh namespace dict at startup. The
rendering exists because a `.py` file next to a compiled binary would have
to be located at run time relative to it — an unforced deployment failure;
a string is compiled into the binary and cannot go missing. Which parts of
the shim must be Python and which could be Mojo is answered, with numbers,
in docs/notes/shim-language.md.

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

from std.ffi import c_char, c_long
from std.memory import OptionalPointer, unsafe_memcpy
from std.python import Python, PythonObject
from std.python._cpython import (
    CPython,
    ExternalFunction,
    PyObjectPtr,
    Py_ssize_t,
)

from lightbug_http import HTTPRequest, Headers, HeaderKey
from lightbug_http.cookie import ResponseCookieJar
from lightbug_http.header import name_is

from .environ import (
    all_ascii,
    append_cgi_name_as_utf8,
    append_latin1_as_utf8,
    header_is_excluded,
    span_has_control_bytes,
)
from .shim_source import SHIM_SOURCE


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
    def(PyObjectPtr) thin abi("C") -> OptionalPointer[c_char, ImmutAnyOrigin],
]
"""The response body's exit: a direct read of the `bytes` buffer.
Measured at **1.0 ns**, against 1,095 ns for the `ctypes` round trip through
the shim that this replaced."""

comptime _PyBytes_FromStringAndSize = ExternalFunction[
    "PyBytes_FromStringAndSize",
    # PyObject *PyBytes_FromStringAndSize(const char *v, Py_ssize_t len)
    def(
        OptionalPointer[c_char, ImmutAnyOrigin], Py_ssize_t
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
    var _spawn: PythonObject
    """The shim's `spawn` (executor mode), resolved once for the same
    reason: it is called per request, so the lookup must not be."""
    var _spawn_ws: PythonObject
    """The shim's `spawn_ws`: one WebSocket connection as a task."""
    var _run_forever: PythonObject
    """`run_forever`: the executor thread's whole serving life, one
    zero-argument call. Events reach Mojo through the `ExecutorPort` the
    thread set with `set_port`, not through a per-pass return value."""
    var _on_disconnect: PythonObject
    """`_exec_on_disconnect`: the shim's per-slot disconnect, called
    DIRECTLY under the loop inversion (`notify_disconnect`) rather than
    tagged onto the submit channel. Cached at construction like the rest,
    so the per-call path builds one tuple through the C API and never
    passes a `PythonObject` argument."""
    var _base: PythonObject
    """The request-invariant environ entries, held as one finished Python
    dict. Built in `set_base`; every request starts from
    `PyDict_Copy(_base)` — one C call instead of a hash-and-store per
    entry."""

    var _k_method: PythonObject
    var _k_path: PythonObject
    var _k_query: PythonObject
    var _k_remote_addr: PythonObject
    var _k_remote_port: PythonObject
    var _k_protocol: PythonObject
    """The six per-request key strings, interned once. They never vary, so
    building them per request would be six `PyUnicode_DecodeUTF8` calls
    and six frees for nothing."""

    var _scope: PythonObject
    """The executor's request-invariant scope entries, as one finished
    Python dict: `type`, `asgi`, `scheme`, `root_path`, `server` and
    `client: None`. Built in `set_base` beside the environ template, for
    the same reason: every request starts from `PyDict_Copy(_scope)` and
    stores its eight variable keys through `PyDict_SetItem`, so the
    `dict(_scope_base)` plus eight Python-level stores (an `encode` and a
    `split` among them) that the shim's `spawn` used to do per request are
    one C copy and eight C stores. Rebuilt whenever `set_base` runs, so a
    mount's `root_path` and `server` are in it."""
    var _lifespan_state: PythonObject
    """The shim's lifespan `state` dict, read once at construction. Its
    identity never changes (the shim mutates it and never rebinds it), and
    each request's `scope["state"]` is a `PyDict_Copy` of it: uvicorn's
    shallow copy, so an application's request-scoped keys never leak into
    the lifespan state."""

    var _k_s_method: PythonObject
    var _k_s_path: PythonObject
    var _k_s_raw_path: PythonObject
    var _k_s_query: PythonObject
    var _k_s_http_version: PythonObject
    var _k_s_headers: PythonObject
    var _k_s_client: PythonObject
    var _k_s_state: PythonObject
    """The eight per-request scope keys, interned once like the environ's."""

    var _bytes_as_string: _PyBytes_AsString.type
    var _bytes_from: _PyBytes_FromStringAndSize.type
    var _dict_copy: _PyDict_Copy.type
    """The unbound C-API calls, resolved once from the interpreter's own
    handle. Loading is a `dlsym`; the calls it returns cost nanoseconds, so
    they are resolved here and never per request."""

    var _script_len: Int
    """Bytes of `SCRIPT_NAME` to trim off the front of `PATH_INFO`.

    Set by `set_base` from the mount prefix; 0 for an unmounted server, so
    the trim below is a comparison against 0 rather than a branch anyone
    pays for."""

    var _scratch_name: List[UInt8]
    var _scratch_value: List[UInt8]
    """Reused byte buffers for the two transforms that cannot be done in
    place: the CGI header name, and the latin-1 → UTF-8 re-encode for the
    values that need it. Kept on the bridge so a request allocates neither.
    Two of them because a header's name and value are in flight at once."""

    var _stream_next_fn: PythonObject
    var _stream_close_fn: PythonObject
    """The shim's streamed-body half, resolved once: zero-argument calls,
    which the interop leaks nothing on."""

    var stream_pending: Bool
    """`run` returned the HEAD of a streamed WSGI body and the shim still
    holds the iterable; `stream_next`/`stream_close` finish it. Cleared by
    `stream_close`."""

    def __init__(out self) raises:
        var builtins = Python.import_module("builtins")
        self._ns = Python.dict()
        builtins.exec(PythonObject(SHIM_SOURCE), self._ns)
        self._run = self._ns["run"]
        self._spawn = self._ns["spawn"]
        self._spawn_ws = self._ns["spawn_ws"]
        self._run_forever = self._ns["run_forever"]
        self._on_disconnect = self._ns["_exec_on_disconnect"]
        self._stream_next_fn = self._ns["wsgi_stream_next"]
        self._stream_close_fn = self._ns["wsgi_stream_close"]
        self.stream_pending = False

        self._script_len = 0
        self._k_method = _py_str("REQUEST_METHOD")
        self._k_path = _py_str("PATH_INFO")
        self._k_query = _py_str("QUERY_STRING")
        self._k_remote_addr = _py_str("REMOTE_ADDR")
        self._k_remote_port = _py_str("REMOTE_PORT")
        self._k_protocol = _py_str("SERVER_PROTOCOL")

        self._k_s_method = _py_str("method")
        self._k_s_path = _py_str("path")
        self._k_s_raw_path = _py_str("raw_path")
        self._k_s_query = _py_str("query_string")
        self._k_s_http_version = _py_str("http_version")
        self._k_s_headers = _py_str("headers")
        self._k_s_client = _py_str("client")
        self._k_s_state = _py_str("state")
        self._lifespan_state = self._ns["_lifespan_state"]

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
        var empty_scope = cpy.PyDict_New()
        if not empty_scope:
            raise cpy.get_error()
        self._scope = PythonObject(from_owned=empty_scope)

        self._scratch_name = List[UInt8](capacity=64)
        self._scratch_value = List[UInt8](capacity=256)

    def __init__(out self, *, deinit move: Self):
        self._ns = move._ns^
        self._run = move._run^
        self._spawn = move._spawn^
        self._spawn_ws = move._spawn_ws^
        self._run_forever = move._run_forever^
        self._on_disconnect = move._on_disconnect^
        self._base = move._base^
        self._script_len = move._script_len
        self._k_method = move._k_method^
        self._k_path = move._k_path^
        self._k_query = move._k_query^
        self._k_remote_addr = move._k_remote_addr^
        self._k_remote_port = move._k_remote_port^
        self._k_protocol = move._k_protocol^
        self._scope = move._scope^
        self._lifespan_state = move._lifespan_state^
        self._k_s_method = move._k_s_method^
        self._k_s_path = move._k_s_path^
        self._k_s_raw_path = move._k_s_raw_path^
        self._k_s_query = move._k_s_query^
        self._k_s_http_version = move._k_s_http_version^
        self._k_s_headers = move._k_s_headers^
        self._k_s_client = move._k_s_client^
        self._k_s_state = move._k_s_state^
        self._bytes_as_string = move._bytes_as_string
        self._bytes_from = move._bytes_from
        self._dict_copy = move._dict_copy
        self._scratch_name = move._scratch_name^
        self._scratch_value = move._scratch_value^
        self._stream_next_fn = move._stream_next_fn^
        self._stream_close_fn = move._stream_close_fn^
        self.stream_pending = move.stream_pending

    def set_stream_capable(self, flag: Bool) raises:
        """Let the shim stream unsized iterables (a pool thread with a chunk
        channel) or keep joining them. Startup-only: the argument leaks one
        reference, bounded like `set_app`'s."""
        _ = self._ns["set_stream_capable"](PythonObject(flag))

    def stream_next(mut self) raises -> List[UInt8]:
        """The next chunk of a streamed body, copied out binary-safe; empty
        at the end. A zero-argument call, then `body_bytes` — no per-request
        argument crosses, so nothing leaks."""
        var chunk = self._stream_next_fn()
        return self.body_bytes(chunk)

    def stream_close(mut self):
        """Close the streamed iterable (idempotent) and clear `stream_pending`.
        Never raises: a `close()` that raises has nowhere to report."""
        self.stream_pending = False
        try:
            _ = self._stream_close_fn()
        except:
            pass

    def set_app(
        self,
        app: PythonObject,
        forced: String = "auto",
        run_lifespan: Bool = True,
    ) raises -> String:
        """Install the application callable and resolve its protocol.

        `forced` is `auto` (detect from the object), `wsgi`, or `asgi`;
        the return value is the protocol the shim resolved. For an ASGI
        application this also creates the bridge's persistent asyncio loop
        and — unless `run_lifespan` is False (the executor mode's fallback
        bridge, which serves only queue-overflow requests) — runs lifespan
        startup, so a `lifespan.startup.failed` raises here, at startup,
        where it belongs.

        Startup-only: each call argument leaks one reference (see module
        docstring), which is harmless for a bounded number of calls at
        construction."""
        var result = self._ns["set_app"](
            app, PythonObject(forced), PythonObject(run_lifespan)
        )
        return String(py=result)

    def lifespan_shutdown(self) raises:
        """Run ASGI lifespan shutdown and close the bridge's loop.

        A no-op for WSGI (the shim guards on a missing loop). Call once at
        teardown, on the thread that owns this bridge, inside its attached
        region — never per request."""
        _ = self._ns["lifespan_shutdown"]()

    # --- the executor mode -------------------------------------------------

    def executor_init(self, submit_read_fd: Int, ack_read_fd: Int = -1) raises:
        """Register the OffloadPool's submit channel — and, when streaming
        is enabled, the drain-ack channel — with the shim's loop.

        Startup-only (the fd arguments leak one reference each, bounded).
        From here the asyncio loop reads job/tag datagrams and credit acks
        itself via `add_reader`; the caller must have made the fds
        non-blocking first."""
        _ = self._ns["asgi_executor_init"](
            PythonObject(submit_read_fd), PythonObject(ack_read_fd)
        )

    def set_port(self, port: PythonObject) raises:
        """Hand the shim this thread's `ExecutorPort` (an `m0native` type
        built in-process). Startup-only: the one `__setitem__` leaks one
        reference, bounded. Must precede `executor_init`, whose submit
        reader produces events the moment the loop runs."""
        self._ns["_port"] = port

    def run_forever(mut self) raises:
        """Park in the shim's loop for the executor thread's whole life.

        Returns after the poison pill, once the shim has run the in-flight
        tasks to completion and stopped the loop. A zero-argument call,
        leak-free; while this thread is inside it every request task
        makes progress and every event is dispatched into the port."""
        _ = self._run_forever()

    def run_forever_inverted(mut self, backend_fd: Int) raises:
        """`M0_INVERTED`: park in the shim's loop with the event loop's own
        backend fd registered on it, so the Mojo pass runs as a readiness
        callback on this thread. Startup-only: the one argument leaks one
        reference, bounded. Returns once the shutdown pipe has fired, the
        drain has run and the in-flight tasks have finished."""
        _ = self._ns["run_forever_inverted"](PythonObject(backend_fd))

    def notify_disconnect(mut self, slot: Int) raises:
        """`M0_INVERTED`: tell the shim `slot`'s connection is gone, NOW.

        On the pump this is a `TAG_DISCONNECT` datagram on the submit
        channel, and the FIFO there is what keeps it ahead of the slot's
        next job. Inverted, the next job is spawned directly from the pass
        that accepted it and would overtake a tag still sitting in the
        channel, stamping the NEW task as disconnected: the ASGI smoke's
        HTTP/1.0-then-1.1 probe found exactly that as a second stream that
        never arrived. A direct call keeps program order — the close runs
        in the pass before the accept that recycles the slot — and costs
        no syscall. One tuple through the C API, no `PythonObject`
        argument, so nothing leaks per call."""
        ref cpy = Python().cpython()
        var args = cpy.PyTuple_New(1)
        if not args:
            raise cpy.get_error()
        _ = cpy.PyTuple_SetItem(args, 0, cpy.PyLong_FromSsize_t(slot))
        var result = cpy.PyObject_CallObject(self._on_disconnect._obj_ptr, args)
        cpy.Py_DecRef(args)
        if not result:
            raise cpy.get_error()
        cpy.Py_DecRef(result)

    def _py_text(
        mut self, ref cpy: CPython, value: Span[Byte, _]
    ) raises -> PyObjectPtr:
        """A Python `str` of raw request bytes: UTF-8 when they are, the
        latin-1 tunnel when they are not. Returns a new reference."""
        var s = cpy.PyUnicode_DecodeUTF8(StringSpan(unsafe_from_utf8=value))
        if not s:
            # Not valid UTF-8: clear the pending decode error, tunnel as
            # latin-1 (the same re-encode the environ path uses).
            _ = cpy.get_error()
            self._scratch_value.clear()
            append_latin1_as_utf8(self._scratch_value, value)
            s = cpy.PyUnicode_DecodeUTF8(
                StringSpan(unsafe_from_utf8=Span(self._scratch_value))
            )
            if not s:
                raise cpy.get_error()
        return s

    def _py_bytes_span(
        self, ref cpy: CPython, value: Span[Byte, _]
    ) raises -> PyObjectPtr:
        """A Python `bytes` straight from a request span. New reference."""
        var b = self._bytes_from(
            value.unsafe_ptr()
            .unsafe_bitcast[c_char]()
            .as_imm()
            .as_unsafe_any_origin(),
            Py_ssize_t(len(value)),
        )
        if not b:
            raise cpy.get_error()
        return b

    def _py_headers(
        mut self, ref cpy: CPython, req: HTTPRequest
    ) raises -> PyObjectPtr:
        """The request's headers as a ready ASGI list of lowercase
        `(bytes, bytes)` pairs (the header map normalized names on
        insert). New reference; `PyList_SetItem` steals each pair."""
        var count = req.headers.count()
        var headers = cpy.PyList_New(count)
        if not headers:
            raise cpy.get_error()
        for i in range(count):
            var pair = cpy.PyTuple_New(2)
            if not pair:
                cpy.Py_DecRef(headers)
                raise cpy.get_error()
            try:
                _ = cpy.PyTuple_SetItem(
                    pair, 0,
                    self._py_bytes_span(cpy, req.headers.name_span(i)),
                )
                _ = cpy.PyTuple_SetItem(
                    pair, 1,
                    self._py_bytes_span(cpy, req.headers.value_span(i)),
                )
            except e:
                cpy.Py_DecRef(pair)
                cpy.Py_DecRef(headers)
                raise e
            # PyList_SetItem steals: the list owns the pair now.
            _ = cpy.PyList_SetItem(headers, i, pair)
        return headers

    def spawn_asgi_ws(mut self, slot: Int, req: HTTPRequest) raises:
        """Hand one validated WebSocket handshake to the shim as a task.

        Same crossing discipline as `spawn_asgi`, minus the body: the
        `websocket` scope's variable half rides one stolen args tuple.
        The caller holds the ready 101 until the app's `websocket.accept`
        comes back as a `('ws_accept', slot)` event."""
        ref cpy = Python().cpython()

        var args = cpy.PyTuple_New(7)
        if not args:
            raise cpy.get_error()
        _ = cpy.PyTuple_SetItem(args, 0, cpy.PyLong_FromSsize_t(slot))
        try:
            _ = cpy.PyTuple_SetItem(
                args, 1, self._py_text(cpy, req.uri.path.as_bytes())
            )
            _ = cpy.PyTuple_SetItem(
                args, 2,
                self._py_bytes_span(cpy, req.uri.query_string.as_bytes()),
            )
            _ = cpy.PyTuple_SetItem(
                args, 3, self._py_text(cpy, req.protocol.as_bytes())
            )
            _ = cpy.PyTuple_SetItem(args, 4, self._py_headers(cpy, req))
            _ = cpy.PyTuple_SetItem(
                args, 5, self._py_text(cpy, req.remote_addr.as_bytes())
            )
            _ = cpy.PyTuple_SetItem(
                args, 6, cpy.PyLong_FromSsize_t(req.remote_port)
            )
        except e:
            cpy.Py_DecRef(args)
            raise e

        var result = cpy.PyObject_CallObject(self._spawn_ws._obj_ptr, args)
        cpy.Py_DecRef(args)
        if not result:
            raise cpy.get_error()
        cpy.Py_DecRef(result)

    def _build_scope(mut self, req: HTTPRequest) raises -> PythonObject:
        """One request's HTTP scope, entirely through the C API.

        `PyDict_Copy` of the template `set_base` built, then the eight
        variable keys through `PyDict_SetItem` -- which does NOT steal, so
        `_scope_set` releases each value once the dict holds its own
        reference (the environ's rule, `_set_latin1`). `method`, `path`
        and `http_version` are `str`; `raw_path` and `query_string` are
        `bytes` of the request's own bytes; `headers` is the ready list of
        lowercase `(bytes, bytes)` pairs; `client` is `(host, port)` only
        when the loop captured a peer (the template says None); `state` is
        a fresh copy of the lifespan state. Returned owned, so a raise
        anywhere below frees the half-built dict; `spawn_asgi` steals it
        into the args tuple.

        This is what the shim's `spawn` used to do in Python per request:
        `dict(_scope_base)`, eight stores, an `encode` for `raw_path`, a
        `split` for `http_version` and a `dict(_lifespan_state)`.
        """
        ref cpy = Python().cpython()
        var d = self._dict_copy(self._scope._obj_ptr)
        if not d:
            raise cpy.get_error()
        var scope = PythonObject(from_owned=d)

        # Each key pointer is copied out of `self` first, as build_environ
        # does: `self._k_*._obj_ptr` straight in would alias `self` mutably
        # (the scratch buffers) and immutably in one call.
        var k_method = self._k_s_method._obj_ptr
        _scope_set(cpy, d, k_method, self._py_text(cpy, req.method.as_bytes()))
        var path_bytes = req.uri.path.as_bytes()
        var k_path = self._k_s_path._obj_ptr
        _scope_set(cpy, d, k_path, self._py_text(cpy, path_bytes))
        var k_raw_path = self._k_s_raw_path._obj_ptr
        _scope_set(cpy, d, k_raw_path, self._py_bytes_span(cpy, path_bytes))
        var k_query = self._k_s_query._obj_ptr
        _scope_set(
            cpy, d, k_query,
            self._py_bytes_span(cpy, req.uri.query_string.as_bytes()),
        )
        # "HTTP/1.1" -> "1.1": the text after the last slash, or the whole
        # protocol when there is none -- what `protocol.split('/')[-1]` gave.
        var protocol = req.protocol.as_bytes()
        var slash = -1
        for i in range(len(protocol)):
            if protocol[i] == 0x2F:
                slash = i
        var k_version = self._k_s_http_version._obj_ptr
        _scope_set(cpy, d, k_version, self._py_text(cpy, protocol[slash + 1 :]))
        var k_headers = self._k_s_headers._obj_ptr
        _scope_set(cpy, d, k_headers, self._py_headers(cpy, req))

        # The peer, for scope["client"]: Django's ASGIRequest reads it into
        # REMOTE_ADDR/REMOTE_PORT `if scope.get("client")`, so an absent one
        # does not error -- it silently logs every visitor as address-less,
        # which is the worse failure. The template's None stands when the
        # loop captured no peer.
        if req.remote_addr.byte_length() > 0:
            var client = cpy.PyTuple_New(2)
            if not client:
                raise cpy.get_error()
            try:
                _ = cpy.PyTuple_SetItem(
                    client, 0, self._py_text(cpy, req.remote_addr.as_bytes())
                )
            except e:
                cpy.Py_DecRef(client)
                raise e
            _ = cpy.PyTuple_SetItem(
                client, 1, cpy.PyLong_FromSsize_t(req.remote_port)
            )
            var k_client = self._k_s_client._obj_ptr
            _scope_set(cpy, d, k_client, client)

        # uvicorn's shallow copy per request: the app may add request-scoped
        # keys without polluting the lifespan state.
        var state = self._dict_copy(self._lifespan_state._obj_ptr)
        if not state:
            raise cpy.get_error()
        var k_state = self._k_s_state._obj_ptr
        _scope_set(cpy, d, k_state, state)
        return scope^

    def spawn_asgi(mut self, slot: Int, req: HTTPRequest) raises:
        """Hand one parked request to the shim's loop as a task.

        The scope arrives FINISHED (`_build_scope`), and the body as
        `bytes` built straight from the request's buffer; both ride as
        stolen slots of one three-slot args tuple through one
        `PyObject_CallObject`, so a single `Py_DecRef` of the tuple frees
        the lot on every path and nothing leaks per request. A half-filled
        tuple is safe to release: tuple dealloc skips NULL slots.

        Two designs preceded this. The first spawned through
        `build_environ` plus a Python-side environ→scope transform, doing
        the header work twice; the second crossed nine loose arguments and
        let the shim assemble the scope in Python -- `dict(_scope_base)`,
        eight stores, an `encode` and a `split` per request, which is what
        the template copy replaces."""
        ref cpy = Python().cpython()
        var scope = self._build_scope(req)
        # An empty body is fine down this path: CPython documents a NULL
        # pointer with size 0 as valid (see `run`).
        var body = self._py_bytes_span(cpy, Span(req.body_raw))

        var args = cpy.PyTuple_New(3)
        if not args:
            cpy.Py_DecRef(body)
            raise cpy.get_error()
        _ = cpy.PyTuple_SetItem(args, 0, cpy.PyLong_FromSsize_t(slot))
        _ = cpy.PyTuple_SetItem(args, 1, scope^.steal_data())
        _ = cpy.PyTuple_SetItem(args, 2, body)

        var result = cpy.PyObject_CallObject(self._spawn._obj_ptr, args)
        cpy.Py_DecRef(args)
        if not result:
            raise cpy.get_error()
        cpy.Py_DecRef(result)

    def set_base(
        mut self,
        server_name: String,
        server_port: String,
        multiprocess: Bool,
        multithread: Bool = False,
        script_name: String = String(""),
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
        # The mount prefix, and the ONE place it enters either protocol:
        # WSGI reads it here as SCRIPT_NAME (with PATH_INFO trimmed to the
        # remainder in `build_environ`), ASGI reads it as `root_path` from
        # the scope base below, with `path` left whole. Empty for an
        # unmounted server, which is what both specs want at the root.
        _base_set(d, "SCRIPT_NAME", _py_str(script_name))
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

        # The executor's HTTP scope template, the same request-invariant
        # idea as the environ base: what `_build_scope` copies per request.
        var sd = cpy.PyDict_New()
        if not sd:
            raise cpy.get_error()
        var scope = PythonObject(from_owned=sd)
        _base_set(sd, "type", _py_str("http"))
        var ad = cpy.PyDict_New()
        if not ad:
            raise cpy.get_error()
        var asgi = PythonObject(from_owned=ad)
        _base_set(ad, "version", _py_str("3.0"))
        _base_set(ad, "spec_version", _py_str("2.3"))
        _base_set(sd, "asgi", asgi^)
        _base_set(sd, "scheme", _py_str("http"))
        # ASGI's `root_path` is the mount prefix, and `path` stays whole
        # (Django's ASGIHandler strips it itself) -- the one place the two
        # protocols disagree about the prefix, see `build_environ`.
        _base_set(sd, "root_path", _py_str(script_name))
        var port: Int
        try:
            port = Int(server_port)
        except:
            port = 0
        var server = cpy.PyTuple_New(2)
        if not server:
            raise cpy.get_error()
        _ = cpy.PyTuple_SetItem(server, 0, _py_str(server_name).steal_data())
        _ = cpy.PyTuple_SetItem(server, 1, cpy.PyLong_FromSsize_t(port))
        _base_set(sd, "server", PythonObject(from_owned=server))
        # None until a request with a peer overwrites it: ASGI makes
        # `client` optional and Django/Starlette branch on its truthiness,
        # so the blocking accept path (no peer captured) must read None.
        _base_set(sd, "client", PythonObject(None))
        self._scope = scope^

        # The shim keeps its own copy of the invariant half for the
        # WebSocket scope, which `spawn_ws` still builds in Python.
        # Startup-only PythonObject call.
        _ = self._ns["set_scope_base"](
            _py_str(server_name), _py_str(server_port), _py_str(script_name)
        )
        self._script_len = script_name.byte_length()

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
        # PEP 3333: PATH_INFO is the part of the target AFTER SCRIPT_NAME,
        # and is empty (not "/") when the request names the mount point
        # exactly. Django answers that with its APPEND_SLASH redirect, the
        # same as under gunicorn.
        var path_bytes = req.uri.path.as_bytes()
        if self._script_len > 0 and len(path_bytes) >= self._script_len:
            path_bytes = path_bytes[self._script_len :]
        self._set_latin1(cpy, d, k_path, path_bytes)
        var k_query = self._k_query._obj_ptr
        self._set_latin1(cpy, d, k_query, req.uri.query_string.as_bytes())
        var k_protocol = self._k_protocol._obj_ptr
        self._set_latin1(cpy, d, k_protocol, req.protocol.as_bytes())

        # The peer. The template's REMOTE_ADDR is "", so a request the
        # blocking path served (no peer captured) keeps the CGI-truthful
        # empty string rather than a stale previous value -- PyDict_Copy
        # starts every request from the template. REMOTE_PORT is set only
        # when real: it is optional in CGI and gunicorn omits absent ones.
        if req.remote_addr.byte_length() > 0:
            var k_addr = self._k_remote_addr._obj_ptr
            self._set_latin1(cpy, d, k_addr, req.remote_addr.as_bytes())
            var port_text = String(req.remote_port)
            var k_port = self._k_remote_port._obj_ptr
            self._set_latin1(cpy, d, k_port, port_text.as_bytes())

        # Walked by index over the header map's own spans: no `keys()`
        # snapshot, no `get()` lookup per key, no String anywhere.
        for i in range(req.headers.count()):
            # httpoxy: `Proxy:` would become `HTTP_PROXY`, which outbound
            # HTTP clients read as a proxy setting. See
            # `header_is_excluded` for why this one name and no others.
            if header_is_excluded(req.headers.name_span(i)):
                continue
            self._scratch_name.clear()
            append_cgi_name_as_utf8(
                self._scratch_name, req.headers.name_span(i)
            )
            var key = cpy.PyUnicode_DecodeUTF8(
                StringSpan(unsafe_from_utf8=Span(self._scratch_name))
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
            s = cpy.PyUnicode_DecodeUTF8(StringSpan(unsafe_from_utf8=value))
        else:
            self._scratch_value.clear()
            append_latin1_as_utf8(self._scratch_value, value)
            s = cpy.PyUnicode_DecodeUTF8(
                StringSpan(unsafe_from_utf8=Span(self._scratch_value))
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

    # --- the response head -------------------------------------------------

    def read_head(
        self,
        headers: PythonObject,
        bytes_pairs: Bool,
        mut out: Headers,
        mut cookies: ResponseCookieJar,
    ) raises:
        """Fill `out` and `cookies` from the application's response headers,
        reading them through the C API.

        `headers` is the list the application handed over — `(str, str)`
        pairs from a WSGI `start_response`, `(bytes, bytes)` pairs from an
        ASGI `http.response.start`; `bytes_pairs` says which. Every
        reference taken here is BORROWED: `PyList_GetItem`,
        `PyTuple_GetItem` and `PyUnicode_AsUTF8AndSize` return pointers
        into objects the list keeps alive, and `PyBytes_AsString` reads the
        object's own buffer, so nothing is `Py_DecRef`'d. A DecRef on a
        borrowed reference is a double free that surfaces later and
        elsewhere; the RSS guards in `smoke-django` and `smoke-asgi` are the
        instruments.

        This replaced iterating the list as `PythonObject`s with two
        `String(py=...)` per pair — priced at 1.27 µs of a six-header
        response's 3.30 (docs/WSGI_PERFORMANCE.md), with `Headers()` plus
        six stores another 1.39 — which is what the reserve from the
        counted bytes is for. The two passes over borrowed pointers cost
        nanoseconds; the reallocations they avoid cost more.

        A `str` crosses as the UTF-8 CPython caches on the object, the
        same text `String(py=...)` produced, so the wire bytes are
        unchanged. A `bytes` value is latin-1 on the wire and is re-encoded
        to UTF-8 only when a byte above 0x7F makes that necessary, so
        `write_latin1_to` puts the application's own bytes back. Set-Cookie
        takes the verbatim jar path, and a name or value carrying CR, LF
        or NUL is refused before anything is copied — the rules
        `build_response` applied, on the same bytes.
        """
        ref cpy = Python().cpython()
        var list_ptr = headers._obj_ptr
        var count = Int(cpy.PyObject_Length(list_ptr))
        if count < 0:
            raise cpy.get_error()
        # Pass one sizes the blob; pass two fills it.
        var total = 0
        for i in range(count):
            var pair = cpy.PyList_GetItem(list_ptr, i)
            if not pair:
                raise cpy.get_error()
            total += len(
                self._head_span(cpy, _pair_item(cpy, pair, 0), bytes_pairs)
            )
            total += len(
                self._head_span(cpy, _pair_item(cpy, pair, 1), bytes_pairs)
            )
        out.reserve(total, count)
        for i in range(count):
            var pair = cpy.PyList_GetItem(list_ptr, i)
            if not pair:
                raise cpy.get_error()
            var name = self._head_span(
                cpy, _pair_item(cpy, pair, 0), bytes_pairs
            )
            var value = self._head_span(
                cpy, _pair_item(cpy, pair, 1), bytes_pairs
            )
            # Response splitting: refused here, on the application's own
            # bytes, and dropped rather than raised — the application has
            # already run and its body is real. Applies to Set-Cookie too.
            if span_has_control_bytes(name) or span_has_control_bytes(value):
                continue
            if bytes_pairs and not (all_ascii(name) and all_ascii(value)):
                # The rare latin-1 byte above 0x7F: the blob holds UTF-8,
                # and `write_latin1_to` transcodes it back on the wire.
                var name8 = List[UInt8](capacity=2 * len(name))
                append_latin1_as_utf8(name8, name)
                var value8 = List[UInt8](capacity=2 * len(value))
                append_latin1_as_utf8(value8, value)
                _store_header(out, cookies, Span(name8), Span(value8))
            else:
                _store_header(out, cookies, name, value)

    def _head_span(
        self, ref cpy: CPython, obj: PyObjectPtr, is_bytes: Bool
    ) raises -> Span[Byte, ImmutAnyOrigin]:
        """The bytes of one header name or value, borrowed from `obj`.

        A `str` answers through `PyUnicode_AsUTF8AndSize` (the object's
        cached UTF-8, built once per string), a `bytes` through
        `PyBytes_AsString` plus `PyObject_Length`. Both are checked calls:
        an object of the wrong type answers NULL with a TypeError, which is
        raised here and becomes the request's 500.
        """
        if is_bytes:
            var n = Int(cpy.PyObject_Length(obj))
            if n < 0:
                raise cpy.get_error()
            var maybe = self._bytes_as_string(obj)
            if not maybe:
                raise cpy.get_error()
            return Span[Byte, ImmutAnyOrigin](
                unsafe_ptr=maybe.unsafe_value().unsafe_bitcast[UInt8](),
                length=n,
            )
        var text = cpy.PyUnicode_AsUTF8AndSize(obj)
        if not text:
            raise cpy.get_error()
        return text.value().as_bytes()

    # --- diagnostic probes -------------------------------------------------
    #
    # `scripts/bench_bridge_parts.mojo` uses these to split the per-request
    # cost into its parts. They are the same operations `run` performs,
    # exposed individually; nothing in the serving path calls them.

    def probe_build_environ(mut self, req: HTTPRequest) raises:
        """The C-API environ build alone, without running the application."""
        var d = self.build_environ(req)
        _ = d

    def probe_build_scope(mut self, req: HTTPRequest) raises:
        """The C-API scope build alone, without spawning a task."""
        var d = self._build_scope(req)
        _ = d


def _scope_set(
    ref cpy: CPython, d: PyObjectPtr, key: PyObjectPtr, value: PyObjectPtr
) raises:
    """Store `value` under `key` and release it: `PyDict_SetItem` does not
    steal, and forgetting the DecRef is the unbounded per-request leak the
    RSS guards exist to catch. The value is released on the failing path
    too, so a refused store is not a leaked object."""
    var rc = cpy.PyDict_SetItem(d, key, value)
    cpy.Py_DecRef(value)
    if rc != 0:
        raise cpy.get_error()


def _pair_item(
    ref cpy: CPython, pair: PyObjectPtr, index: Int
) raises -> PyObjectPtr:
    """Item `index` of one header pair, borrowed.

    PEP 3333 and the ASGI spec both say tuples and every framework sends
    them, so the tuple read is the path; an application that sends
    two-element lists is not wrong, so the tuple read's refusal (a
    `SystemError`, cleared here) falls through to the list read, and only
    a pair that is neither raises.
    """
    var item = cpy.PyTuple_GetItem(pair, index)
    if not item:
        _ = cpy.get_error()
        item = cpy.PyList_GetItem(pair, index)
        if not item:
            raise cpy.get_error()
    return item


def _store_header(
    mut out: Headers,
    mut cookies: ResponseCookieJar,
    name: Span[Byte, _],
    value: Span[Byte, _],
):
    """One header into the map, or a Set-Cookie into the jar, verbatim.

    `name_is`, not a lowercased copy: the copy this used to allocate per
    header, purely to test one constant, was 3.2 µs per header (see
    `response.mojo`'s history). The jar path is verbatim because the
    application's line IS the header — the `Cookie` round trip dropped
    `expires` and `SameSite` from every Django cookie.
    """
    if name_is(name, HeaderKey.SET_COOKIE):
        cookies.add_raw(String(unsafe_from_utf8=value))
    else:
        out.set_bytes(name, value)


def _base_set(d: PyObjectPtr, key: StringSpan, var value: PythonObject) raises:
    """Store one entry in the base template.

    `PyDict_SetItem` does not steal, and both the fresh key and `value` are
    owned `PythonObject`s — their destructors release them once the dict
    holds its own references, so there is no manual DecRef to forget.
    """
    ref cpy = Python().cpython()
    var k = _py_str(key)
    if cpy.PyDict_SetItem(d, k._obj_ptr, value._obj_ptr) != 0:
        raise cpy.get_error()


def _py_str(s: StringSpan) raises -> PythonObject:
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
