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
    header_is_excluded,
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

# --- streamed WSGI bodies ---------------------------------------------------
# On a pool thread with a chunk channel, an iterable the application did not
# size is streamed rather than joined: `run` returns the head and keeps the
# iterable here, and the thread pulls chunks through wsgi_stream_next until
# it is exhausted, then wsgi_stream_close. The loop's own handler never
# enables this -- streaming from the loop thread is the hostage problem the
# pool exists to remove.
_stream_capable = False
_stream_result = None
_stream_iter = None
_stream_first = b''
_stream_written = None


def set_stream_capable(flag):
    global _stream_capable
    _stream_capable = bool(flag)


def _stream_this(result, environ, status, headers):
    # What streams and what buffers, in order. Rule 1 is what keeps every
    # framework page byte-identical on the wire: Werkzeug computes a
    # Content-Length for every list body, Django's CommonMiddleware adds
    # one, FileResponse sets its own. Rule 3 catches Django's HttpResponse
    # -- an iterable, not a list -- for a project without CommonMiddleware
    # (a bare settings.configure()), where without it every page would go
    # out chunked through the channel. What is left is a lazily produced
    # body: a generator, StreamingHttpResponse, a Flask Response over one,
    # wsgiref.validate's IteratorWrapper.
    if not _stream_capable:
        return False
    if isinstance(result, (bytes, bytearray, list, tuple)):
        return False
    if getattr(result, 'streaming', None) is False:
        return False
    if environ.get('REQUEST_METHOD') == 'HEAD':
        return False
    try:
        code = int(status[:3])
    except (TypeError, ValueError):
        return False
    if code < 200 or code == 204 or code == 304:
        return False
    for name, value in headers:
        n = name.lower()
        if n == 'content-length' or n == 'm0-hold':
            return False
    return True


def wsgi_stream_next():
    # The next chunk to send, b'' at the end. Empty chunks the application
    # yields are skipped here so b'' means exactly one thing. Anything the
    # application passed to write() since the last chunk goes out first:
    # PEP 3333 lets a generator call write() between its yields, and the
    # bytes must reach the wire in the order they were produced.
    global _stream_first
    if _stream_iter is None:
        return b''
    if _stream_first:
        first, _stream_first = _stream_first, b''
        return first
    written = _stream_written
    while True:
        try:
            chunk = next(_stream_iter)
        except StopIteration:
            if written:
                out = b''.join(written)
                del written[:]
                return out
            return b''
        if chunk:
            if written:
                out = b''.join(written) + bytes(chunk)
                del written[:]
                return out
            return bytes(chunk)


def wsgi_stream_close():
    # Idempotent, and safe to call whether the iterable was exhausted, the
    # client vanished, or the generator raised: close() goes to the
    # ORIGINAL result (wsgiref.validate's wrapper asserts exactly that),
    # once, and the iterator is dropped so a later wsgi_stream_next
    # answers b'' instead of iterating a closed object.
    global _stream_result, _stream_iter, _stream_first, _stream_written
    result = _stream_result
    _stream_result = None
    _stream_iter = None
    _stream_first = b''
    _stream_written = None
    if result is not None:
        close = getattr(result, 'close', None)
        if close is not None:
            close()


def set_app(app, forced='auto', run_lifespan=True):
    # run_lifespan=False builds an ASGI bridge whose loop exists but whose
    # lifespan never ran: the executor mode's fallback shape, where the
    # event loop's own handler serves only queue-overflow requests and the
    # executor's bridge owns the one real lifespan per loop.
    global _app, _is_asgi
    _app = app
    if forced == 'auto':
        _is_asgi = _detect(app) == 'asgi'
    else:
        _is_asgi = (forced == 'asgi')
    if _is_asgi:
        _asgi_init(run_lifespan)
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
    #
    # A module that does not exist -- the spec's own, or a parent package
    # of it -- is discovery's ordinary miss and stays a one-line message,
    # because a bare MODULE tries four candidates and the misses must stay
    # quiet. Anything else the import raises is the APPLICATION failing to
    # load (a settings module without its environment variable, a bad
    # database URL, a dependency that is not installed), and the one-line
    # str(e) that used to be all m0serve printed is not enough to find it:
    # the traceback travels with the message.
    import importlib, traceback
    try:
        module = importlib.import_module(module_name)
    except ModuleNotFoundError as e:
        missing = getattr(e, 'name', None) or ''
        if missing and (missing == module_name
                        or module_name.startswith(missing + '.')):
            raise
        # chr(10), not a backslash escape: this source is a Mojo string
        # literal, and Mojo would turn the escape into a real newline.
        raise RuntimeError('%s: %s' % (type(e).__name__, e) + chr(10)
                           + traceback.format_exc()) from None
    except Exception as e:
        # chr(10), not a backslash escape: this source is a Mojo string
        # literal, and Mojo would turn the escape into a real newline.
        raise RuntimeError('%s: %s' % (type(e).__name__, e) + chr(10)
                           + traceback.format_exc()) from None
    return _detect(getattr(module, attribute))


def _asgi_init(run_lifespan=True):
    global _loop
    import asyncio
    if _loop is None:
        # Opportunistic uvloop: strictly faster where installed, and the
        # interface this bridge uses (run_until_complete, create_task,
        # add_reader, futures) is identical. Zero-config means picking the
        # best loop available, not shipping one -- stdlib asyncio is the
        # unconditional fallback (and the free-threaded canary's path,
        # where uvloop may not import).
        try:
            import uvloop
            _loop = uvloop.new_event_loop()
        except Exception:
            _loop = asyncio.new_event_loop()
        # Thread-local, so per-bridge loops never collide across serving
        # threads.
        asyncio.set_event_loop(_loop)
    if 'm0' not in _lifespan_state:
        # Before lifespan runs, so an application can take it during
        # startup; inert (active=False) when no bus fds were exported.
        _lifespan_state['m0'] = _M0Broadcast()
    if run_lifespan:
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
    # ASGI's `path` INCLUDES root_path -- Django's ASGIHandler strips the
    # prefix itself (`get_script_prefix` then `path[len(script_name):]`),
    # and hands `request.path` the untrimmed value. WSGI's PATH_INFO is
    # the trimmed remainder, so the whole path is SCRIPT_NAME + PATH_INFO.
    raw_path = (environ.get('SCRIPT_NAME', '')
                + environ.get('PATH_INFO', '')).encode('latin-1')
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
        'client': (
            (environ['REMOTE_ADDR'],
             int(environ.get('REMOTE_PORT') or 0))
            if environ.get('REMOTE_ADDR') else None
        ),
        'server': (environ.get('SERVER_NAME', ''), port),
        # NB: 'client' is computed above and must not be repeated here. A
        # second `'client': None` key used to follow, and a dict literal
        # keeps the LAST value -- so the peer computed from REMOTE_ADDR was
        # thrown away and every buffered-ASGI request saw
        # `scope["client"] is None`, while the executor path (which builds
        # its scope separately) reported the real peer. An app doing
        # IP-based rate limiting or allow-listing off scope["client"] would
        # behave differently in the two modes for no visible reason.
        # A shallow copy per request, matching uvicorn: the app may add
        # request-scoped keys without polluting the lifespan state.
        'state': dict(_lifespan_state),
    }


async def _serve_one_buffered(scope, body):
    # One request through the app, buffered: returns the same
    # (status, headers, body) triple the WSGI path returns, or raises what
    # the application raised. Shared by the per-request bridge (which runs
    # it to completion) and the executor (which runs many as tasks).
    #
    # Deliberately ONE coroutine awaiting the app directly -- no inner
    # task, no asyncio.wait arbiter, no per-request futures. An earlier
    # version arbitrated app-vs-streaming with ensure_future +
    # wait(FIRST_COMPLETED) + wait_for(shield(...)), and that scaffolding
    # (two tasks and three futures per request, streaming or not) was a
    # measured seven percent of hello-world throughput under the executor.
    # The watchdog moved into send(): a streaming response that is still
    # sending after the grace gets the explanatory error at its next
    # send(). The one shape that arbiter caught and this does not -- an
    # app that sends more_body=True once and then never sends again --
    # hangs exactly as a hung WSGI view does, which is the bridge's
    # documented parity everywhere else.
    from http.client import responses as _reasons
    from time import monotonic as _now

    delivered = []
    captured = {'status': None, 'headers': []}
    chunks = []
    total = [0]
    stream_deadline = [None]

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
            if message.get('more_body', False):
                if stream_deadline[0] is None:
                    stream_deadline[0] = _now() + _ASGI_STREAM_GRACE
                elif _now() > stream_deadline[0]:
                    raise RuntimeError(
                        'ASGI streaming response did not complete within '
                        '%.0fs -- infinite streams (SSE/EventStream) are '
                        'not supported by the buffered ASGI bridge; see '
                        'docs/WSGI_VS_ASGI.md section 8'
                        % _ASGI_STREAM_GRACE)

    await _app(scope, receive, send)

    if captured['status'] is None:
        raise RuntimeError(
            'ASGI application completed without sending '
            'http.response.start')
    status = captured['status']
    headers = [(n.decode('latin-1'), v.decode('latin-1'))
               for n, v in captured['headers']]
    return ('%d %s' % (status, _reasons.get(status, '')), headers,
            b''.join(chunks))


def _run_asgi(environ, body):
    global _body
    result = _loop.run_until_complete(
        _serve_one_buffered(_scope_from_environ(environ), body))
    _body = result[2]
    return result


# --- the executor mode -------------------------------------------------
# One Python thread per Mojo event loop runs this namespace's `_loop`
# persistently: the loop parks each request and submits its slot through
# the OffloadPool's datagram channel exactly as `--blocking-threads`
# does, `add_reader` on the submit fd turns each slot into a task, and
# task completion hands a ('done', ...) event back to the Mojo pump,
# which answers through the pool's completion channel. Requests overlap
# wherever the application awaits -- uvicorn's shape -- while every
# Python object stays owned by this one thread.

_exec_queue = None
_exec_tasks = set()

# Streaming state, all keyed by slot and owned by this thread. Credits
# implement backpressure: a chunk is only emitted when the loop has acked
# enough drained bytes, so the registry's pending buffer never exceeds
# the window and its drop threshold is never reached.
_exec_credits = {}
_exec_credit_evts = {}
_exec_disconnects = {}
_exec_disconnected = set()
_exec_stream_tasks = {}
# slot -> the task that currently owns the slot's per-slot state (spawned
# last). A slot is recycled the instant the loop closes its connection,
# and the previous task may still be alive for an iteration or two; only
# the OWNER may clean the slot up, and a disconnect is delivered to the
# task, not left on the slot for its successor to trip over.
_exec_slot_task = {}

_ASGI_CREDIT_WINDOW = 64 * 1024
_ASGI_CHUNK_SPLIT = 32 * 1024

# Per-stream credit bounds ONE stream's pending bytes; this bounds every
# stream's together. They are not the same limit: the chunk channel is a
# single SOCK_DGRAM pair shared by every stream on this executor, so N
# streams put N windows in flight against one finite buffer, and past it
# `send_stream_chunk` cannot place the datagram -- a dropped chunk, which is
# a short body under a clean terminator. Twelve concurrent WhiteNoise static
# files under a real Django project were enough (docs/REAL_APP_VALIDATION.md,
# 2026-08-26). Kept well under the 256 KB socket buffer because the kernel
# charges per-datagram overhead on top of payload, and because the drain is
# per loop pass: this caps how far ahead of the wire the executor may run,
# not how much it may send.
_ASGI_TOTAL_WINDOW = 128 * 1024
_exec_global_credit = [_ASGI_TOTAL_WINDOW]
_exec_global_evt = None
_exec_inflight = {}

# Tags on the submit channel beyond the plain 8-byte job datagram.
_TAG_DISCONNECT = 1
_TAG_WS_MESSAGE = 2
_TAG_BUS_FRAME = 3
_TAG_JOB_BATCH = 4

_m0_subs = {}
'''channel -> set of asyncio.Queue: this loop's live subscriptions.

Fed by _TAG_BUS_FRAME datagrams the loop's handler forwards off the
BroadcastBus, so a publish on ANY worker reaches subscribers on every
worker -- the Channels channel-layer shape, with no Redis, because the
bus socketpairs already exist pre-fork for exactly this.'''


class _M0Broadcast:
    '''The object at `scope['state']['m0']`: cross-worker pub/sub.

    `publish` is m0pub.py's protocol verbatim -- one datagram per worker
    channel (the publisher's own included; there is no separate local
    path to keep in sync), ids from the shared atomic where available,
    best-effort on a full or dead channel. `subscribe` is executor-mode
    only: frames arrive as forwarded submit-channel datagrams, and the
    buffered bridge has no reader to forward them to.
    '''

    def __init__(self):
        import os
        self._fds = [
            int(x) for x in os.environ.get(
                'M0_BUS_WRITE_FDS', '').split(',') if x.strip()
        ]
        self._next_id = None
        addr = os.environ.get('M0_SHARED_ID_ADDR', '')
        lib = os.environ.get('M0_CORE_LIB', '')
        if addr and lib:
            try:
                import ctypes
                core = ctypes.CDLL(lib)
                core.m0_shared_fetch_add.restype = ctypes.c_int64
                core.m0_shared_fetch_add.argtypes = [
                    ctypes.c_uint64, ctypes.c_int64,
                ]
                base = int(addr)
                self._next_id = lambda: core.m0_shared_fetch_add(base, 1)
            except Exception:
                self._next_id = None

    @property
    def active(self):
        return bool(self._fds)

    def publish(self, channel, payload):
        '''One frame to every worker's loop. Returns the event id (-1
        when no shared counter is available -- delivery still happens,
        duplicate suppression is what degrades).

        A channel opening with 0x01 is REFUSED. That namespace addresses
        connection slots directly on the receiving loop (inject into this
        slot's stream, unsubscribe it, re-point it), and an application's
        channel name is routinely user input -- a `%01` in a form body
        decodes to a real control byte. `channel_is_reserved` in
        `lightbug_http/broadcast.mojo` is the same predicate.'''
        import os
        import struct
        if isinstance(channel, str):
            channel = channel.encode('utf-8')
        if isinstance(payload, str):
            payload = payload.encode('utf-8')
        if channel[:1] == b'\x01' or len(channel) > 65535:
            # Returns rather than raises, matching `m0pub.publish_frame`
            # and the Mojo `publish_to_channels`. All three refuse the same
            # names; they used to disagree on how, so the same user-supplied
            # channel was a silent no-op under WSGI and a 500 under ASGI.
            # Publishing is best-effort on every other failure here (a full
            # channel, a dead worker), and a view that passes a request
            # field as the channel should not become a 500 because of it.
            return -1
        event_id = self._next_id() if self._next_id is not None else -1
        frame = struct.pack('<qH', event_id, len(channel)) + channel + payload
        if len(frame) > 65536:
            raise ValueError('m0 publish frame exceeds 65536 bytes')
        for fd in self._fds:
            try:
                os.write(fd, frame)
            except (BlockingIOError, BrokenPipeError, OSError):
                pass  # best-effort, exactly as between workers
        return event_id

    def subscribe(self, channel, max_queue=256):
        '''An async iterator of (event_id, payload) for `channel`.

        Per-connection, per-loop; drop-oldest at `max_queue` (a slow
        consumer must not grow memory without bound -- the same
        backpressure posture as the registry's outboxes).

        Refuses the reserved namespace for the same reason `publish` does,
        from the other side: a subscription named `\\x01...` would be asking
        to receive the loop's internal control frames.'''
        import asyncio
        if isinstance(channel, bytes):
            channel = channel.decode('utf-8')
        if channel[:1] == '\x01':
            # Subscribe DOES raise where publish returns: publish is
            # best-effort and its return value says what happened, while a
            # subscription that silently yielded nothing forever would be
            # a debugging trap with no signal at all.
            raise ValueError(
                'm0 subscribe channel may not begin with 0x01 '
                '(reserved for internal control frames)'
            )
        q = asyncio.Queue(maxsize=max_queue)
        _m0_subs.setdefault(channel, set()).add(q)

        class _Sub:
            def __aiter__(self):
                return self

            async def __anext__(self):
                return await q.get()

            async def aclose(self):
                subs = _m0_subs.get(channel)
                if subs is not None:
                    subs.discard(q)
                    if not subs:
                        _m0_subs.pop(channel, None)

            async def __aenter__(self):
                return self

            async def __aexit__(self, *exc):
                await self.aclose()

        return _Sub()


def _m0_dispatch(event_id, url, frame):
    subs = _m0_subs.get(url)
    if not subs:
        return
    for q in tuple(subs):
        if q.full():
            try:
                q.get_nowait()  # drop-oldest
            except Exception:
                pass
        try:
            q.put_nowait((event_id, bytes(frame)))
        except Exception:
            pass

# WebSocket state, keyed by slot, owned by this thread: the inbound
# message queue behind receive(), and the accepted-set that decides
# whether a close means "reject the handshake" or "close the socket".
_exec_ws_inbox = {}
_exec_ws_accepted = set()


def _ws_frame_bytes(n):
    '''What the LOOP will queue for a message of `n` payload bytes.

    `encode_ws_frame` builds an unmasked server frame, so the header is 2,
    4 or 10 bytes. Credit is charged in THESE bytes rather than the
    payload's, because these are the bytes the loop acks back: its outbox
    drain acks `len(pending)`, and pending holds encoded frames. Charging
    the payload and being credited the frame drifts by the header on every
    message -- threefold on one-byte sends, which is exactly the traffic
    that reaches the outbox cap first.
    '''
    if n <= 125:
        return n + 2
    if n <= 0xFFFF:
        return n + 4
    return n + 10


async def _ws_spend(slot, nbytes):
    '''Wait for room in BOTH windows, then charge them -- `_emit` for a socket.

    Until this existed `websocket.send` was not gated at all. An
    application that outran its client filled the loop's 64 KB per-slot
    outbox, and the frame the loop then had to refuse was a message the
    peer has no protocol-level way to notice is missing: measured at
    430,693 of 1,638,400 bytes delivered under a clean close frame. The
    loop was already acking a socket's drained bytes -- a WS slot on an
    executor lane answers `slot_channel_stream` -- so what was missing was
    only the window to credit them to, seeded at `websocket.accept`.

    A message bigger than the window is charged the whole window rather
    than waiting for credit that can never exist; the ack that follows
    over-credits by the difference and the clamp in `_on_ack` absorbs it.
    (Such a message is refused by the outbox anyway -- `queue_frame` caps a
    single frame at `MAX_PENDING_BYTES` -- and now says so.)
    '''
    import asyncio
    evt = _exec_credit_evts.get(slot)
    if evt is None:
        # No window: a socket the loop is not acking (a `--realtime` hold
        # on a WSGI lane). Nothing to wait for and nothing to charge.
        return
    if nbytes > _ASGI_CREDIT_WINDOW:
        nbytes = _ASGI_CREDIT_WINDOW
    while _exec_credits.get(slot, 0) < nbytes:
        if _task_gone(slot):
            raise asyncio.CancelledError()
        evt.clear()
        await evt.wait()
    while _exec_global_credit[0] < nbytes:
        if _task_gone(slot):
            raise asyncio.CancelledError()
        _exec_global_evt.clear()
        await _exec_global_evt.wait()
    _exec_credits[slot] -= nbytes
    _exec_global_credit[0] -= nbytes
    _exec_inflight[slot] = _exec_inflight.get(slot, 0) + nbytes


def _task_gone(slot):
    # `import asyncio` here, not at module scope: this shim is a string
    # exec'd into a fresh namespace and every function that needs the
    # module imports it itself (a sys.modules hit). Without it this
    # function raises NameError -- which surfaced as every ASGI stream
    # truncating at its first credit window, since the raise happens
    # after the head has gone out.
    import asyncio
    # Disconnected: the slot's mark (set by the loop's tag, cleared when a
    # new task takes the slot), or THIS task's own (stamped on the owner at
    # the time of the tag, and never cleared) -- a task that lingers past
    # its slot's reuse must not keep producing under the successor's
    # generation, nor end the successor's stream in its finally.
    return (slot in _exec_disconnected
            or getattr(asyncio.current_task(), '_m0_disconnected', False))


def _exec_on_disconnect(slot):
    # The loop closed this slot (client vanished, or end-of-stream close
    # raced): resolve the pending receive() into http.disconnect (or
    # queue websocket.disconnect), wake any credit waiter, and cancel the
    # task -- uvicorn's contract. The cancellation is what stops an
    # EventStream generator; frameworks handle CancelledError as cleanup.
    _exec_disconnected.add(slot)
    owner = _exec_slot_task.get(slot)
    if owner is not None:
        owner._m0_disconnected = True
    # The bytes this slot still had in flight are the OLD connection's:
    # its acks are not coming, and its own cleanup may be skipped below
    # if a new task has taken the slot by then. Refund here, where the
    # slot is still unambiguously the old task's.
    stranded = _exec_inflight.pop(slot, 0)
    if stranded:
        _exec_global_credit[0] += stranded
        if _exec_global_evt is not None:
            _exec_global_evt.set()
    fut = _exec_disconnects.get(slot)
    if fut is not None and not fut.done():
        fut.set_result(True)
    inbox = _exec_ws_inbox.get(slot)
    if inbox is not None:
        inbox.put_nowait({'type': 'websocket.disconnect', 'code': 1006})
    evt = _exec_credit_evts.get(slot)
    if evt is not None:
        evt.set()
    task = _exec_stream_tasks.get(slot)
    if task is not None and not task.done():
        task.cancel()


def _exec_on_ws_message(slot, opcode, payload):
    # An inbound frame the loop's parser assembled, forwarded by the
    # handler as a tagged datagram. Opcode 1 is text (the loop already
    # validated UTF-8), 2 is binary.
    inbox = _exec_ws_inbox.get(slot)
    if inbox is None:
        return
    if opcode == 1:
        inbox.put_nowait({'type': 'websocket.receive',
                          'text': payload.decode('utf-8', 'replace')})
    else:
        inbox.put_nowait({'type': 'websocket.receive', 'bytes': payload})


def _exec_cleanup_slot(slot):
    # Whatever this slot still had in flight is returned to the global
    # window: its acks are no longer coming, and a budget that only ever
    # shrinks stalls every stream after it.
    stranded = _exec_inflight.pop(slot, 0)
    if stranded:
        _exec_global_credit[0] += stranded
        if _exec_global_evt is not None:
            _exec_global_evt.set()
    _exec_credits.pop(slot, None)
    _exec_credit_evts.pop(slot, None)
    _exec_disconnects.pop(slot, None)
    _exec_disconnected.discard(slot)
    _exec_stream_tasks.pop(slot, None)
    _exec_ws_inbox.pop(slot, None)
    _exec_ws_accepted.discard(slot)


def asgi_executor_init(fd, ack_fd):
    # `fd` is the OffloadPool's submit_read end, `ack_fd` the streaming
    # channel's ack read end; both already non-blocking. Submit datagrams:
    # 8 bytes = a little-endian job slot (-1 is the poison pill); 9 bytes
    # = [tag u8][slot i64 LE], today only _TAG_DISCONNECT. Ack datagrams:
    # (slot: i32, bytes: i32) LE -- drained bytes to re-credit.
    global _exec_queue, _exec_global_evt
    import asyncio, os
    _exec_queue = None  # every event goes straight to _port (see _exec_put)
    # Created here rather than at import: an asyncio.Event binds to the
    # running loop, and this is the first point where that loop exists.
    _exec_global_evt = asyncio.Event()

    def _on_submit():
        while True:
            try:
                data = os.read(fd, 65546)
            except (BlockingIOError, InterruptedError):
                return
            except OSError:
                _loop.remove_reader(fd)
                _exec_put(('job', -1))
                return
            if len(data) == 8:
                _exec_put(
                    ('job', int.from_bytes(data, 'little', signed=True)))
            elif (len(data) >= 9 and data[0] == _TAG_JOB_BATCH
                  and (len(data) - 1) % 8 == 0):
                # [tag u8][slot i64 LE] x n: the loop's whole pass of
                # submits in one datagram. Checked BEFORE the generic
                # fallthrough, which treats an unknown shape as EOF.
                for at in range(1, len(data), 8):
                    _exec_put(
                        ('job', int.from_bytes(data[at:at + 8], 'little',
                                               signed=True)))
            elif len(data) == 9 and data[0] == _TAG_DISCONNECT:
                _exec_on_disconnect(
                    int.from_bytes(data[1:9], 'little', signed=True))
            elif len(data) >= 10 and data[0] == _TAG_WS_MESSAGE:
                # [tag u8][slot i64 LE][opcode u8][payload...]
                _exec_on_ws_message(
                    int.from_bytes(data[1:9], 'little', signed=True),
                    data[9], data[10:])
            elif len(data) >= 11 and data[0] == _TAG_BUS_FRAME:
                # [tag u8][event_id i64 LE][url_len u16 LE][url][frame...]
                _ulen = int.from_bytes(data[9:11], 'little')
                _m0_dispatch(
                    int.from_bytes(data[1:9], 'little', signed=True),
                    data[11:11 + _ulen].decode('utf-8', 'replace'),
                    data[11 + _ulen:])
            else:
                _loop.remove_reader(fd)
                _exec_put(('job', -1))
                return

    def _on_ack():
        while True:
            try:
                data = os.read(ack_fd, 8)
            except (BlockingIOError, InterruptedError):
                return
            except OSError:
                _loop.remove_reader(ack_fd)
                return
            if len(data) < 8:
                return
            slot = int.from_bytes(data[0:4], 'little')
            n = int.from_bytes(data[4:8], 'little')
            if slot in _exec_credits:
                # CLAMPED to the window, never merely added. An ack names a
                # SLOT and carries no generation, and the loop recycles a
                # slot the instant it closes a connection -- so an ack for
                # the stream that just ended can land after the next stream
                # on that slot has seeded its window whole. Added, that
                # lets the new stream put more than one window of bytes
                # into the ONE shared chunk channel, which is the
                # over-commit `_ASGI_TOTAL_WINDOW` exists to prevent and
                # whose symptom is a dropped datagram: a short body under a
                # clean terminator. `credit + in flight == the window` is
                # the invariant a live stream keeps; min() is what makes a
                # stale ack unable to break it.
                credited = _exec_credits[slot] + n
                if credited > _ASGI_CREDIT_WINDOW:
                    credited = _ASGI_CREDIT_WINDOW
                _exec_credits[slot] = credited
                evt = _exec_credit_evts.get(slot)
                if evt is not None:
                    evt.set()
            # The global window is refunded whatever the slot's own state:
            # bytes that left the channel are bytes the channel has room for
            # again, and a slot torn down between spend and ack must not
            # strand its share (that would ratchet the budget to zero and
            # stall every later stream).
            spent = _exec_inflight.get(slot, 0)
            refund = n if n < spent else spent
            if refund:
                _exec_inflight[slot] = spent - refund
                _exec_global_credit[0] += refund
                if _exec_global_evt is not None:
                    _exec_global_evt.set()

    _loop.add_reader(fd, _on_submit)
    if ack_fd >= 0:
        _loop.add_reader(ack_fd, _on_ack)


# The Mojo side of the pump: an m0native.ExecutorPort the executor thread
# built inside this interpreter and set here before the submit reader
# existed. Every event is handed to it NOW, on this thread, inside the
# loop iteration that produced it -- a ~70 ns call into Mojo -- and the
# loop is never left: the executor thread parks in one run_forever for
# its life (run_forever below), not a run_until_complete per pass.
_port = None
_flush_armed = [False]


def set_port(port):
    global _port
    _port = port


def _exec_put(ev):
    # Dispatch, and arm ONE flush for the end of this loop iteration: the
    # port parks each completion and pokes the loop for all of them at
    # once when _flush runs -- every done-callback of the iteration lands
    # in the same datagram, batching without a batch buffer. The port's
    # own ordering rules (begin frame before head, flush before any
    # non-begin chunk frame) are inside dispatch and unchanged.
    stopping = _port.dispatch(ev)
    if not _flush_armed[0]:
        _flush_armed[0] = True
        _loop.call_soon(_flush)
    if stopping:
        # The pill: the submit channel is quiet behind it. Run the
        # in-flight tasks to completion -- their events dispatch here as
        # they finish -- then stop the loop, which returns run_forever to
        # the executor thread for the final flush and lifespan shutdown.
        _loop.create_task(_finish_and_stop())


def _flush():
    _flush_armed[0] = False
    _port.flush()


async def _finish_and_stop():
    import asyncio
    if _exec_tasks:
        await asyncio.gather(*list(_exec_tasks), return_exceptions=True)
    await asyncio.sleep(0)
    _loop.stop()


def run_forever():
    # The executor thread's whole serving life. Returns after the pill,
    # via _finish_and_stop; a task that never completes (a chunk credit
    # that never arrives) keeps it here until stop_and_join's budget runs
    # out, exactly as the per-pass pump was.
    _loop.run_forever()


# The request-invariant half of every executor scope, built once by
# set_scope_base. The executor path never builds a WSGI environ at all:
# Mojo hands over method/path/query/headers directly (headers as ready
# lowercase (bytes, bytes) pairs -- no CGI names, no latin-1 re-encodes,
# no Python-side re-transform), which is what closed the measured gap to
# uvicorn's parser-to-scope path.
_scope_base = None
_root_path = ''


def set_scope_base(server_name, server_port, root_path=''):
    global _scope_base, _root_path
    try:
        port = int(server_port)
    except ValueError:
        port = 0
    _root_path = root_path
    _scope_base = {
        'type': 'http',
        'asgi': {'version': '3.0', 'spec_version': '2.3'},
        'scheme': 'http',
        'root_path': root_path,
        'server': (server_name, port),
        'client': None,
    }


async def _serve_one_exec(slot, scope, body):
    # The executor's request coroutine: buffered until the application
    # proves it is streaming (its first more_body=True chunk), then a
    # credit-gated chunk producer. A buffered request returns the same
    # (status, headers, body) triple as ever and the done-callback answers
    # through the completion channel; a streaming one returns None and its
    # bytes travel as events instead -- ('stream_start', slot, status,
    # headers, b''), ('stream_chunk', slot, bytes), ('stream_end', slot).
    # After stream_start the completion channel must never be used for
    # this slot again: the head already answered it, and the slot may be
    # recycled the instant the loop closes it.
    import asyncio
    from http.client import responses as _reasons
    from time import monotonic as _now

    delivered = []
    captured = {'status': None, 'headers': []}
    chunks = []
    total = [0]
    stream_deadline = [None]
    streaming = [False]

    async def receive():
        if not delivered:
            delivered.append(True)
            return {'type': 'http.request', 'body': body,
                    'more_body': False}
        # Unlike the buffered bridge, the executor CAN observe a
        # disconnect: the loop's close sends a tag that resolves this
        # future. Shielded so a task cancellation cancels the await, not
        # the shared future.
        fut = _exec_disconnects.get(slot)
        if fut is None:
            fut = _loop.create_future()
            _exec_disconnects[slot] = fut
        await asyncio.shield(fut)
        return {'type': 'http.disconnect'}

    async def _emit(data):
        # Split under the bus frame cap, and never outrun the loop: each
        # piece waits for the drain acks to leave room in BOTH windows --
        # this stream's, and every stream's together. The global one is what
        # keeps N concurrent streams from over-committing the one chunk
        # channel they share; see _ASGI_TOTAL_WINDOW. Waiting here is an
        # await, so the loop's GIL and this executor's other tasks both keep
        # running -- which is why the wait belongs here and not in the Mojo
        # send.
        view = memoryview(data)
        for start in range(0, len(view), _ASGI_CHUNK_SPLIT):
            piece = bytes(view[start:start + _ASGI_CHUNK_SPLIT])
            evt = _exec_credit_evts[slot]
            while _exec_credits.get(slot, 0) < len(piece):
                if _task_gone(slot):
                    raise asyncio.CancelledError()
                evt.clear()
                await evt.wait()
            while _exec_global_credit[0] < len(piece):
                if _task_gone(slot):
                    raise asyncio.CancelledError()
                _exec_global_evt.clear()
                await _exec_global_evt.wait()
            _exec_credits[slot] -= len(piece)
            _exec_global_credit[0] -= len(piece)
            _exec_inflight[slot] = _exec_inflight.get(slot, 0) + len(piece)
            _exec_put(('stream_chunk', slot, piece))

    async def send(message):
        t = message.get('type', '')
        if t == 'http.response.start':
            captured['status'] = int(message.get('status', 500))
            captured['headers'] = list(message.get('headers', []))
        elif t == 'http.response.body':
            chunk = bytes(message.get('body', b'') or b'')
            more = bool(message.get('more_body', False))
            if streaming[0]:
                if chunk:
                    await _emit(chunk)
                return
            if more:
                # The switch: this response is a stream. Send the head
                # through the completion channel (the pump turns it into
                # the sse_streaming response), flush what was buffered,
                # and stream from here on.
                if captured['status'] is None:
                    raise RuntimeError(
                        'ASGI streamed a body chunk before '
                        'http.response.start')
                streaming[0] = True
                task = asyncio.current_task()
                task._m0_streaming = True
                _exec_stream_tasks[slot] = task
                _exec_credits[slot] = _ASGI_CREDIT_WINDOW
                _exec_credit_evts[slot] = asyncio.Event()
                status = captured['status']
                head_headers = [
                    (n.decode('latin-1'), v.decode('latin-1'))
                    for n, v in captured['headers']
                ]
                _exec_put((
                    'stream_start', slot,
                    '%d %s' % (status, _reasons.get(status, '')),
                    head_headers, b'',
                ))
                buffered = chunks[:]
                chunks.clear()
                total[0] = 0
                for piece in buffered:
                    await _emit(piece)
                if chunk:
                    await _emit(chunk)
                return
            if chunk:
                chunks.append(chunk)
                total[0] += len(chunk)
                if total[0] > _ASGI_BUFFER_CAP:
                    raise RuntimeError(
                        'ASGI response body exceeded the buffered '
                        'bridge cap (%d bytes)' % _ASGI_BUFFER_CAP)

    aborted = [False]
    try:
        await _app(scope, receive, send)
    except BaseException:
        aborted[0] = True
        raise
    finally:
        if streaming[0] and not _task_gone(slot):
            # End of stream. A normal completion ends with the chunked
            # terminator and the connection returns to keep-alive; an
            # application error after the head -- or a cancellation that
            # was not a disconnect -- aborts instead, and the loop closes
            # WITHOUT the terminator, so the client sees a truncated body
            # rather than a short one under a clean ending.
            _exec_put(
                ('stream_abort' if aborted[0] else 'stream_end', slot))

    if streaming[0]:
        return None
    if captured['status'] is None:
        raise RuntimeError(
            'ASGI application completed without sending '
            'http.response.start')
    status = captured['status']
    headers = [(n.decode('latin-1'), v.decode('latin-1'))
               for n, v in captured['headers']]
    return ('%d %s' % (status, _reasons.get(status, '')), headers,
            b''.join(chunks))


def spawn(slot, method, path, query, protocol, headers, body,
          host='', port=0):
    # Called from the pump; every argument arrived as a stolen tuple slot
    # through one PyObject_CallObject -- the same crossing discipline as
    # the per-request path. Completion is an event, never a callback into
    # Mojo (there is no such thing): ('done', slot, status, headers,
    # body_bytes) or ('err', slot, message) for buffered responses;
    # stream_* events for streaming ones.
    scope = dict(_scope_base)
    scope['method'] = method
    scope['path'] = path
    scope['raw_path'] = path.encode('utf-8', 'replace')
    scope['query_string'] = query
    scope['http_version'] = protocol.split('/')[-1]
    scope['headers'] = headers
    # None rather than ('', 0) when the loop had no peer to give (the
    # blocking accept path): ASGI's spec makes `client` optional, and
    # Django/Starlette both branch on its truthiness.
    scope['client'] = (host, port) if host else None
    scope['state'] = dict(_lifespan_state)
    task = _loop.create_task(_serve_one_exec(slot, scope, body))
    _exec_tasks.add(task)
    _exec_slot_task[slot] = task
    # A disconnect that reached the slot before this task existed was the
    # previous connection's (the tag precedes this job on the FIFO).
    _exec_disconnected.discard(slot)
    _exec_disconnects.pop(slot, None)
    task.add_done_callback(_task_done(slot))


def _task_done(slot):
    def _done(t):
        _exec_tasks.discard(t)
        was_streaming = getattr(t, '_m0_streaming', False)
        if _exec_slot_task.get(slot) is t:
            # Still the slot's owner: the per-slot state is this task's.
            _exec_slot_task.pop(slot, None)
            _exec_cleanup_slot(slot)
        # Otherwise a newer task owns the slot (the loop recycled it while
        # this one was still winding down); its state is not ours to wipe.
        if was_streaming:
            # The stream's own finally already signalled the loop; the
            # completion channel is off limits (the slot may be recycled).
            # Surface an application error to the log only.
            if not t.cancelled():
                exc = t.exception()
                if exc is not None:
                    _exec_put((
                        'stream_note', slot,
                        '%s: %s' % (type(exc).__name__, exc)))
            return
        if t.cancelled():
            _exec_put(('err', slot, 'cancelled'))
            return
        exc = t.exception()
        if exc is not None:
            _exec_put(
                ('err', slot, '%s: %s' % (type(exc).__name__, exc)))
            return
        status, headers, body_bytes = t.result()
        _exec_put(('done', slot, status, headers, body_bytes))
    return _done


async def _serve_one_ws(slot, scope):
    # One WebSocket connection: the loop already validated the handshake
    # and holds the ready 101; the application decides. accept releases
    # the 101 through the completion channel (via the pump); frames go
    # out as 'w' chunk-channel datagrams and come in as tagged
    # submit-channel datagrams the handler forwards from ws_message.
    import asyncio
    inbox = asyncio.Queue()
    _exec_ws_inbox[slot] = inbox
    connected = [False]
    resolved = [False]  # accept or reject reached the pump

    async def receive():
        if not connected[0]:
            connected[0] = True
            return {'type': 'websocket.connect'}
        return await inbox.get()

    async def send(message):
        t = message.get('type', '')
        if _task_gone(slot):
            return
        if t == 'websocket.accept':
            _exec_ws_accepted.add(slot)
            # The send window, seeded BEFORE the accept reaches the pump:
            # from that moment the loop can drain frames and ack them, and
            # an ack for a slot with no window is discarded. See
            # `_ws_spend`.
            _exec_credits[slot] = _ASGI_CREDIT_WINDOW
            _exec_credit_evts[slot] = asyncio.Event()
            resolved[0] = True
            _exec_put(('ws_accept', slot))
        elif t == 'websocket.send':
            if slot not in _exec_ws_accepted:
                raise RuntimeError('websocket.send before websocket.accept')
            data = message.get('bytes')
            if data is None:
                payload = (message.get('text') or '').encode('utf-8')
                opcode = 1
            else:
                payload = bytes(data)
                opcode = 2
            # Backpressure: this await is the whole point. An application
            # faster than its client waits here, exactly as a streaming
            # HTTP response waits in `_emit`.
            await _ws_spend(slot, _ws_frame_bytes(len(payload)))
            if _task_gone(slot):
                return
            _exec_put(('ws_send', slot, opcode, payload))
        elif t == 'websocket.close':
            if slot in _exec_ws_accepted:
                # The close frame rides the same outbox, so it is charged
                # the same way. A peer that has genuinely gone is what
                # `_task_gone` covers; a merely slow one is worth waiting
                # for, because a close that overflows the outbox takes the
                # connection down without its close frame.
                await _ws_spend(slot, _ws_frame_bytes(2))
                if _task_gone(slot):
                    return
                _exec_put(
                    ('ws_close', slot, int(message.get('code', 1000))))
                _exec_ws_accepted.discard(slot)
            else:
                resolved[0] = True
                _exec_put(('ws_reject', slot))

    try:
        await _app(scope, receive, send)
    finally:
        if not _task_gone(slot):
            if slot in _exec_ws_accepted:
                # The app returned with the socket open: close it for it,
                # uvicorn's contract.
                _exec_put(('ws_close', slot, 1000))
            elif not resolved[0]:
                # Returned (or raised) without ever answering the
                # handshake: the held 101 must not leak its slot.
                _exec_put(('ws_reject', slot))
    return None


def spawn_ws(slot, path, query, protocol, headers, host='', port=0):
    scope = {
        'type': 'websocket',
        'asgi': {'version': '3.0', 'spec_version': '2.3'},
        'scheme': 'ws',
        'root_path': _root_path,
        'server': _scope_base['server'],
        'client': (host, port) if host else None,
        'http_version': protocol.split('/')[-1],
        'path': path,
        'raw_path': path.encode('utf-8', 'replace'),
        'query_string': query,
        'headers': headers,
        'subprotocols': _ws_subprotocols(headers),
        'state': dict(_lifespan_state),
    }
    task = _loop.create_task(_serve_one_ws(slot, scope))
    task._m0_streaming = True
    _exec_tasks.add(task)
    _exec_slot_task[slot] = task
    _exec_disconnected.discard(slot)
    _exec_disconnects.pop(slot, None)
    _exec_stream_tasks[slot] = task
    task.add_done_callback(_task_done(slot))


def _ws_subprotocols(headers):
    for name, value in headers:
        if name == b'sec-websocket-protocol':
            return [p.strip() for p in
                    value.decode('latin-1').split(',') if p.strip()]
    return []




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
    sent = [False]

    def start_response(status, headers, exc_info=None):
        # PEP 3333: a second call without exc_info is an application error.
        # With exc_info it must replace the stored status and headers, and may
        # only re-raise once the headers have actually gone out -- which for a
        # buffered response is never, so replacing is the branch taken; for a
        # STREAMED one the head is on the wire, and re-raising is the only
        # honest answer left.
        if exc_info is not None and sent[0]:
            raise exc_info[1].with_traceback(exc_info[2])
        if captured and exc_info is None:
            raise AssertionError('start_response() called twice without exc_info')
        captured['status'] = status
        captured['headers'] = headers
        return written.append

    result = _app(environ, start_response)
    if captured and _stream_this(result, environ, captured['status'],
                                 captured['headers']):
        # Stream. PEP 3333 forbids sending the headers before the first
        # non-empty chunk exists, so it is pulled now: an application that
        # raises before producing anything is still an ordinary 500, and
        # an iterable that exhausts with nothing takes the buffered path
        # with whatever write() produced.
        global _stream_result, _stream_iter, _stream_first, _stream_written
        it = iter(result)
        first = b''
        try:
            while True:
                chunk = next(it)
                if chunk:
                    first = bytes(chunk)
                    break
        except StopIteration:
            it = None
        except BaseException:
            close = getattr(result, 'close', None)
            if close is not None:
                close()
            raise
        if it is not None:
            _stream_result = result
            _stream_iter = it
            _stream_written = written
            _stream_first = b''.join(written) + first
            del written[:]
            sent[0] = True
            return (captured['status'], captured['headers'], b'', True)
        try:
            _body = b''.join(written)
        finally:
            close = getattr(result, 'close', None)
            if close is not None:
                close()
        return (captured['status'], captured['headers'], _body, False)
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
            captured.get('headers', []), _body, False)
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
    var _spawn: PythonObject
    """The shim's `spawn` (executor mode), resolved once for the same
    reason: it is called per request, so the lookup must not be."""
    var _spawn_ws: PythonObject
    """The shim's `spawn_ws`: one WebSocket connection as a task."""
    var _run_forever: PythonObject
    """`run_forever`: the executor thread's whole serving life, one
    zero-argument call. Events reach Mojo through the `ExecutorPort` the
    thread set with `set_port`, not through a per-pass return value."""
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
    """The four per-request key strings, interned once. They never vary, so
    building them per request would be four `PyUnicode_DecodeUTF8` calls
    and four frees for nothing."""

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
        self._spawn = move._spawn^
        self._spawn_ws = move._spawn_ws^
        self._run_forever = move._run_forever^
        self._base = move._base^
        self._script_len = move._script_len
        self._k_method = move._k_method^
        self._k_path = move._k_path^
        self._k_query = move._k_query^
        self._k_remote_addr = move._k_remote_addr^
        self._k_remote_port = move._k_remote_port^
        self._k_protocol = move._k_protocol^
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

    def _py_text(
        mut self, ref cpy: CPython, value: Span[Byte, _]
    ) raises -> PyObjectPtr:
        """A Python `str` of raw request bytes: UTF-8 when they are, the
        latin-1 tunnel when they are not. Returns a new reference."""
        var s = cpy.PyUnicode_DecodeUTF8(StringSlice(unsafe_from_utf8=value))
        if not s:
            # Not valid UTF-8: clear the pending decode error, tunnel as
            # latin-1 (the same re-encode the environ path uses).
            _ = cpy.get_error()
            self._scratch_value.clear()
            append_latin1_as_utf8(self._scratch_value, value)
            s = cpy.PyUnicode_DecodeUTF8(
                StringSlice(unsafe_from_utf8=Span(self._scratch_value))
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

    def spawn_asgi(mut self, slot: Int, req: HTTPRequest) raises:
        """Hand one parked request to the shim's loop as a task.

        No environ: the scope's variable half crosses directly — method,
        path and protocol as `str`, the query as `bytes`, the headers as a
        ready list of lowercase `(bytes, bytes)` pairs (the header map
        already normalized names on insert), the body as `bytes`. Every
        object rides as a stolen slot of one args tuple through one
        `PyObject_CallObject`, so a single `Py_DecRef` of the tuple frees
        the lot on every path and nothing leaks per request. A half-filled
        tuple is safe to release: tuple dealloc skips NULL slots.

        This replaced spawning through `build_environ` + a Python-side
        environ→scope transform, which did the header work twice (CGI
        names built here, unbuilt there) and was the measured gap to
        uvicorn's parser-to-scope path."""
        ref cpy = Python().cpython()

        var args = cpy.PyTuple_New(9)
        if not args:
            raise cpy.get_error()
        _ = cpy.PyTuple_SetItem(args, 0, cpy.PyLong_FromSsize_t(slot))

        try:
            _ = cpy.PyTuple_SetItem(
                args, 1, self._py_text(cpy, req.method.as_bytes())
            )
            _ = cpy.PyTuple_SetItem(
                args, 2, self._py_text(cpy, req.uri.path.as_bytes())
            )
            _ = cpy.PyTuple_SetItem(
                args, 3,
                self._py_bytes_span(cpy, req.uri.query_string.as_bytes()),
            )
            _ = cpy.PyTuple_SetItem(
                args, 4, self._py_text(cpy, req.protocol.as_bytes())
            )

            _ = cpy.PyTuple_SetItem(args, 5, self._py_headers(cpy, req))

            # The peer, for scope["client"]: Django's ASGIRequest reads it
            # into REMOTE_ADDR/REMOTE_PORT `if scope.get("client")`, so an
            # absent one does not error -- it silently logs every visitor
            # as address-less, which is the worse failure.
            _ = cpy.PyTuple_SetItem(
                args, 7, self._py_text(cpy, req.remote_addr.as_bytes())
            )
            _ = cpy.PyTuple_SetItem(
                args, 8, cpy.PyLong_FromSsize_t(req.remote_port)
            )

            _ = cpy.PyTuple_SetItem(
                args, 6, self._py_bytes_span(cpy, Span(req.body_raw))
            )
        except e:
            cpy.Py_DecRef(args)
            raise e

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

        # The executor's scope template, same request-invariant idea as the
        # environ base. Startup-only PythonObject call.
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
