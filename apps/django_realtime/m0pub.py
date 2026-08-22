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

Python cannot do this by itself. There is no atomic read-modify-write over a
raw address anywhere in the stdlib and `ctypes` cannot express one; a plain
read-then-write would hand two workers the same id under any concurrency at
all. So `m0_shared_fetch_add` is exported from `m0-core`'s C ABI
(`packages/m0-core/ffi_exports.mojo`, built by `poe build-ffi`) and called
through `ctypes` — which never crosses the WSGI bridge, so the leak rule and
the RSS guard are untouched.

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
import os
import struct
import sys

# Mirrors BUS_MAX_FRAME: the Mojo side drops oversized frames, so refusing
# them here just moves the drop somewhere visible.
MAX_FRAME = 65536

NO_EVENT_ID = -1

# Set by server.mojo before the fork. The library path is not — nothing in
# the server knows where the repo is — so it comes from the environment or
# from the conventional build output next to the package.
BUS_FDS_ENV = "M0_BUS_WRITE_FDS"
ID_ADDR_ENV = "M0_SHARED_ID_ADDR"
CORE_LIB_ENV = "M0_CORE_LIB"

# Resolved once, then cached: (callable, address) when numbering is available,
# False when it is not. None means "not looked yet".
_counter = None


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


def _resolve_counter():
    """Bind `m0_shared_fetch_add` to the server's shared slot, or give up."""
    raw_addr = os.environ.get(ID_ADDR_ENV, "")
    if not raw_addr:
        # No server-side counter at all — running under gunicorn, or under a
        # build that predates it. Unnumbered frames are the correct answer.
        return False
    try:
        addr = int(raw_addr)
    except ValueError:
        return False
    if addr <= 0:
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
    oversized or no bus is configured.
    """
    if len(frame) > MAX_FRAME:
        return 0
    url = channel.encode("utf-8")
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
