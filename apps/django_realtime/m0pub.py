"""Publish SSE frames from Python onto the server's broadcast bus.

The server creates its `BroadcastBus` — one AF_UNIX SOCK_DGRAM channel per
worker — before forking, so every worker process inherits every descriptor,
including the embedded interpreter this module runs in. `server.mojo` exports
the write fds as `M0_BUS_WRITE_FDS` (pre-fork, pre-Python, so `os.environ`
sees it in every worker). Publishing is therefore one `os.write` per worker:
no Mojo call, no PythonObject traffic, nothing the bridge's leak rule cares
about.

A frame is written to EVERY channel, the publisher's own worker included:
writing channel i delivers to worker i's event loop, which drains it and
hands it to `sse_peer_frame` — the same path a frame from any other worker
takes. There is no separate local-delivery mechanism to keep in sync.

Datagram layout, byte-for-byte `encode_bus_frame` (lightbug_http/broadcast.mojo):

    bytes 0..7    event id, Int64 little-endian (-1 encodes as all-FF)
    bytes 8..9    channel length, UInt16 little-endian
    then          channel, UTF-8
    then          the SSE frame, verbatim, to the end of the datagram

The datagram boundary is the framing — one write, one frame.

**Event ids come from a shared atomic, through C.** Every publish takes a
number from one `Int64` on an `mmap(MAP_SHARED)` page the server allocated
before forking; `M0_SHARED_ID_ADDR` names its address and `M0_CORE_LIB`
names the shared library holding the fetch-and-add. Ids therefore increase
globally across every worker, and the number goes in two places: the bus
datagram's id field, and an `id:` line on the SSE frame. That is what
engages the registry's redelivery filter (`event_id > last_event_ids[slot]`)
and what lets a reconnecting client's `Last-Event-ID` mean something.

This file exists in two places — here, and shipped inside the m0serve wheel
as `m0serve.m0pub` — and check-docs holds the copies byte-identical. Two
rather than one because each must work where the other cannot: the wheel's
copy is what `pip install m0serve` users import, and this one is what the
demo imports from a source tree where the wheel is deliberately not
installed (the repo is a uv virtual project).

Python cannot do this by itself. There is no atomic read-modify-write over a
raw address anywhere in the stdlib and `ctypes` cannot express one; a plain
read-then-write would hand two workers the same id under any concurrency at
all. So `m0_shared_fetch_add` is exported from `m0-core`'s C ABI
(`packages/m0-core/ffi_exports.mojo`, built by `poe build-ffi`) and called
through `ctypes` — which never crosses the WSGI bridge, so the leak rule and
the RSS guard are untouched.

**Publishing from a child process.** The bus descriptors survive `exec`; the
page does not, because a mapping dies at exec while `M0_SHARED_ID_ADDR` is
only a number in the parent's address space. So a child a view starts
publishes safely in either of two ways::

    subprocess.Popen([...], pass_fds=m0pub.child_fds())

hands it the bus AND the page by descriptor (`M0_SHARED_ID_FD`), and its
frames are numbered from the same counter as every worker's -- which is what
keeps `Last-Event-ID` replay covering them. Passing only `bus_write_fds()`
still publishes, unnumbered. Before the page carried a magic word (#322) the
second form was not safe: a child that inherited the environment took an id
at the parent's address and died with SIGSEGV, or, where its own image had
something mapped there, incremented it and published the result as an event
id. `next_event_id` now numbers only through a page it has verified -- mapped
from the descriptor and carrying `PAGE_MAGIC`, or at an address the kernel
says is readable and that carries it -- and anything else is unnumbered.

Everything degrades. No library, no address, no bus: `publish` falls back to
`NO_EVENT_ID` (-1) frames, which always deliver and never advance a
subscriber's last-seen id — the old behaviour, and the only behaviour
available under gunicorn, where none of these variables exist. What is lost
is duplicate suppression, not delivery.

Failure mode matches the bus: the fds are non-blocking, and a channel whose
buffer is full (`BlockingIOError`) or whose worker died is skipped — publish
is best-effort, exactly as it is between workers.
"""

import ctypes
import json
import mmap
import os
import struct
import sys

# Mirrors BUS_MAX_FRAME: the Mojo side drops oversized frames, so refusing
# them here just moves the drop somewhere visible.
MAX_FRAME = 65536

# The channel-name length field is a uint16, so this is what fits.
MAX_CHANNEL = 65535

# A channel opening with this byte is RESERVED for the server's own control
# frames: the m0-wsgi handler reads `\x01<kind>/<slot>[/<lane>]` as an
# instruction aimed at one connection slot — queue these bytes into its
# stream, unsubscribe it, re-point it at another channel. Publishing is the
# boundary where an untrusted name would cross into that namespace (a
# channel is routinely a room name or a POST field, and `%01` in a form body
# decodes to a real control byte), so it is refused here. The Mojo side
# spells the same rule `channel_is_reserved`, in
# packages/m0-http/lightbug_http/broadcast.mojo.
CHANNEL_CONTROL_BYTE = b"\x01"

NO_EVENT_ID = -1

# Set by server.mojo before the fork. The library path is not — nothing in
# the server knows where the repo is — so it comes from the environment or
# from the conventional build output next to the package.
PG_NOTIFY_CHANNEL = "m0"
"""The one channel `--pg-listen` subscribes to. The destination rides in the
payload, so this never varies."""

PG_NOTIFY_MAX_BYTES = 7999
"""What Postgres accepts in a NOTIFY payload, less one byte.

The server's limit is 8000 including its terminator. Refusing at the
boundary makes an oversized publish an error where it is written, rather
than a database error at COMMIT far from the call.
"""

BUS_FDS_ENV = "M0_BUS_WRITE_FDS"
ID_ADDR_ENV = "M0_SHARED_ID_ADDR"
ID_FD_ENV = "M0_SHARED_ID_FD"
CORE_LIB_ENV = "M0_CORE_LIB"

PAGE_MAGIC = 0x6D30706167650001
"""`m0page` and a version byte, which the server writes into the page's slot 2.

Spelled in `lightbug_http/accept_share.mojo` as `SHARED_PAGE_MAGIC`; the
three copies must agree. A page without it is not numbered from."""

PAGE_MAGIC_OFFSET = 16

# Resolved once, then cached: (callable, address) when numbering is available,
# False when it is not. None means "not looked yet".
_counter = None

# The mapping `_page_from_fd` made, held for the life of the process: the
# address handed to the fetch-and-add points into it.
_page = None


def bus_write_fds():
    """The inherited bus write fds, as announced by server.mojo."""
    raw = os.environ.get(BUS_FDS_ENV, "")
    return [int(part) for part in raw.split(",") if part]


def _core_lib_paths():
    """Where to look for libm0core, most specific first."""
    env = os.environ.get(CORE_LIB_ENV, "")
    if env:
        return [env]
    ext = "dylib" if sys.platform == "darwin" else "so"
    # `poe build-ffi` writes the first of these; the second lets the dynamic
    # loader's own search path answer for an installed copy.
    return ["packages/m0-core/libm0core." + ext, "libm0core." + ext]


def _page_fd():
    """`M0_SHARED_ID_FD` if it names an open descriptor here, else None."""
    try:
        fd = int(os.environ.get(ID_FD_ENV, ""))
        os.fstat(fd)
    except (ValueError, OSError):
        return None
    return fd


def child_fds():
    """The descriptors a child process needs to publish numbered frames.

    Pass them as `pass_fds`: the bus's write ends and, where the server
    exported one, the shared page. The child keeps the same numbers, which
    is what the inherited `M0_BUS_WRITE_FDS` and `M0_SHARED_ID_FD` name.
    """
    fds = bus_write_fds()
    page = _page_fd()
    if page is not None:
        fds.append(page)
    return fds


def _page_from_fd():
    """The page's address, mapped here from its descriptor, or 0.

    Refused unless the file is big enough and carries `PAGE_MAGIC`, read
    through the `mmap` object, which is bounds-checked: a descriptor number
    inherited without the page may name any file at all, and nothing is
    written to one that is not the page.
    """
    global _page
    fd = _page_fd()
    if fd is None:
        return 0
    try:
        size = os.fstat(fd).st_size
        if size < PAGE_MAGIC_OFFSET + 8:
            return 0
        page = mmap.mmap(fd, size)
    except (OSError, ValueError):
        return 0
    if struct.unpack_from("<q", page, PAGE_MAGIC_OFFSET)[0] != PAGE_MAGIC:
        page.close()
        return 0
    _page = page
    return ctypes.addressof(ctypes.c_char.from_buffer(page))


def _readable(addr, length):
    """Whether `length` bytes at `addr` can be read, without reading them here.

    The kernel copies them into a pipe, so an unmapped address is `EFAULT`
    from `write` rather than SIGSEGV in this process. (`mincore` looked like
    the answer and is not: on macOS it succeeds for unmapped addresses.)
    """
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        write = libc.write
        write.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t]
        write.restype = ctypes.c_ssize_t
        r, w = os.pipe()
    except (OSError, AttributeError):
        return False
    try:
        return write(w, ctypes.c_void_p(addr), length) == length
    finally:
        os.close(r)
        os.close(w)


def _page_at_address():
    """`M0_SHARED_ID_ADDR` if it is readable here and carries `PAGE_MAGIC`, else 0."""
    try:
        addr = int(os.environ.get(ID_ADDR_ENV, ""))
    except ValueError:
        return 0
    if addr <= 0 or not _readable(addr, PAGE_MAGIC_OFFSET + 8):
        return 0
    if ctypes.c_int64.from_address(addr + PAGE_MAGIC_OFFSET).value != PAGE_MAGIC:
        return 0
    return addr


def _resolve_counter():
    """Bind `m0_shared_fetch_add` to the server's shared slot, or give up."""
    if not os.environ.get(ID_ADDR_ENV, "") and not os.environ.get(ID_FD_ENV, ""):
        # No server-side counter at all — running under gunicorn, or under a
        # build that predates it. Unnumbered frames are the correct answer.
        return False
    addr = _page_from_fd() or _page_at_address()
    if not addr:
        # Offered a page that is not one here: a child process that inherited
        # the environment without `child_fds()`, or a server older than the
        # magic word. Taking an id at that address is the crash (or worse)
        # #322 reported, so the frames go unnumbered and this says why once.
        print(
            "m0pub: %s/%s do not name the server's page in this process (a child "
            "process not given m0pub.child_fds()?); publishing unnumbered frames."
            % (ID_FD_ENV, ID_ADDR_ENV),
            file=sys.stderr,
        )
        return False

    for path in _core_lib_paths():
        try:
            lib = ctypes.CDLL(path)
            op = lib.m0_shared_fetch_add
        except (OSError, AttributeError):
            continue
        op.restype = ctypes.c_int64
        op.argtypes = [ctypes.c_uint64, ctypes.c_int64]
        return (op, addr)

    # The server offered a counter and we could not reach it: that is a
    # misconfiguration, not a deployment choice, and it silently costs
    # duplicate suppression. Say so once.
    print(
        "m0pub: %s is set but libm0core could not be loaded (%s); publishing "
        "unnumbered frames. Set %s to the shared library built by "
        "`poe build-ffi`." % (ID_ADDR_ENV, ", ".join(_core_lib_paths()), CORE_LIB_ENV),
        file=sys.stderr,
    )
    return False


def next_event_id():
    """Take the next globally unique event id, or NO_EVENT_ID if unavailable.

    Ids start at 1: the shared slot starts at 0 and fetch-and-add returns the
    PREVIOUS value, so the first publish gets 1. That matters — a subscriber
    starts at last-seen 0 and the filter is strictly greater-than, so an id of
    0 would be suppressed for everyone.
    """
    global _counter
    if _counter is None:
        _counter = _resolve_counter()
    if not _counter:
        return NO_EVENT_ID
    op, addr = _counter
    return int(op(addr, 1)) + 1


def sse_event(data, event=None, event_id=NO_EVENT_ID):
    """Frame `data` as a complete SSE event, terminating blank line included.

    Field order is `id`, `event`, `data`, matching m0-http's
    `format_sse_event`. `data` may span lines; each becomes its own `data:`
    field, which is how SSE transports multi-line payloads.
    """
    lines = []
    if event_id != NO_EVENT_ID:
        lines.append("id: %d" % event_id)
    if event:
        lines.append("event: " + event)
    lines += ["data: " + line for line in (data.splitlines() or [""])]
    return ("\n".join(lines) + "\n\n").encode("utf-8")


def publish_frame(channel, frame, event_id=NO_EVENT_ID):
    """Send one pre-framed SSE frame to `channel` on every worker.

    Returns the number of worker channels written — 0 means the frame was
    oversized, the channel was refused, or no bus is configured.

    A channel in the reserved namespace (leading 0x01) or longer than the
    uint16 length field returns 0 rather than raising: publishing is
    best-effort everywhere else in this module, and a view that passes a
    user-supplied channel should not turn a bad name into a 500.
    """
    if len(frame) > MAX_FRAME:
        return 0
    url = channel.encode("utf-8")
    if url[:1] == CHANNEL_CONTROL_BYTE or len(url) > MAX_CHANNEL:
        return 0
    datagram = struct.pack("<qH", event_id, len(url)) + url + frame
    written = 0
    for fd in bus_write_fds():
        try:
            os.write(fd, datagram)
            written += 1
        except OSError:
            # Full buffer or dead worker: drop, as the bus itself does.
            pass
    return written


def publish_with_id(channel, data, event=None):
    """Frame `data`, number it, publish it. Returns (channels written, id).

    The id is `NO_EVENT_ID` when numbering is unavailable. Callers that want
    to report or log which event they published use this; `publish` is the
    same thing when only the reach matters.
    """
    event_id = next_event_id()
    frame = sse_event(data, event, event_id)
    return publish_frame(channel, frame, event_id), event_id


def publish(channel, data, event=None):
    """Frame `data` and publish it to `channel`. Returns channels written."""
    return publish_with_id(channel, data, event)[0]

def notify_sql(channel, data, event=None):
    """The SQL that publishes `data` on `channel` from OUTSIDE the server.

    Returns ``(statement, parameters)`` for a DB-API cursor, so a caller
    publishes with the connection it already has::

        from django.db import connection
        with connection.cursor() as cur:
            cur.execute(*m0pub.notify_sql("news", "hello", event="greeting"))

    This is the answer to the limitation `bus_write_fds` documents: those
    descriptors are inherited at fork, so a management command, a cron job, a
    `flyctl ssh console` session or `psql` publishes to nobody. A Postgres
    ``NOTIFY`` is a door every one of them already has, and a server started
    with ``--pg-listen`` turns it into the same frame on the same bus.

    A cursor rather than a connection string, and no import of any database
    driver: this module is stdlib-only on purpose, and the caller invariably
    has a connection already. What it does NOT do is choose a transaction —
    ``NOTIFY`` is delivered at COMMIT, so a publish inside a transaction that
    rolls back is correctly never sent, and one that should be seen only
    after its rows belongs in ``transaction.on_commit``.

    The payload is the three fields the listener reads: ``channel``, ``event``
    and ``data``, all JSON strings. Everything the SSE frame needs, and
    nothing that needs a JSON value scanner on the other side.
    """
    payload = json.dumps(
        {"channel": channel, "event": event or "", "data": data},
        separators=(",", ":"),
    )
    if len(payload.encode("utf-8")) > PG_NOTIFY_MAX_BYTES:
        raise ValueError(
            "a NOTIFY payload is limited to %d bytes and this one is %d; "
            "publish a reference and let the client fetch the rest"
            % (PG_NOTIFY_MAX_BYTES, len(payload.encode("utf-8")))
        )
    return ("SELECT pg_notify(%s, %s)", [PG_NOTIFY_CHANNEL, payload])
