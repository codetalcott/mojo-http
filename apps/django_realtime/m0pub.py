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

Event ids are always -1 (`NO_EVENT_ID`): such frames always deliver and never
advance a subscriber's last-seen id. The honest tradeoff: no redelivery
suppression and no `Last-Event-ID` replay for Python-published frames.
Numbered ids must be allocated from the server's shared atomic page, which
Python cannot fetch-and-add atomically; that is future work, not faked here.

Failure mode matches the bus: the fds are non-blocking, and a channel whose
buffer is full (`BlockingIOError`) or whose worker died is skipped — publish
is best-effort, exactly as it is between workers.
"""

import os
import struct

# Mirrors BUS_MAX_FRAME: the Mojo side drops oversized frames, so refusing
# them here just moves the drop somewhere visible.
MAX_FRAME = 65536

NO_EVENT_ID = -1


def bus_write_fds():
    """The inherited bus write fds, as announced by server.mojo."""
    raw = os.environ.get("M0_BUS_WRITE_FDS", "")
    return [int(part) for part in raw.split(",") if part]


def sse_event(data, event=None):
    """Frame `data` as a complete SSE event, terminating blank line included.

    `data` may span lines; each becomes its own `data:` field, which is how
    SSE transports multi-line payloads.
    """
    lines = ["event: " + event] if event else []
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


def publish(channel, data, event=None):
    """Frame `data` and publish it to `channel`. Returns channels written."""
    return publish_frame(channel, sse_event(data, event))
