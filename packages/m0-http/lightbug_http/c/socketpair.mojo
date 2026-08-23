"""`socketpair(2)` — one AF_UNIX datagram channel, shared by the two things
in this server that need to hand messages between execution contexts.

Two callers, and they want the same fds for the same reason. `broadcast.mojo`
carries SSE frames between worker processes; `offload.mojo` carries jobs and
completions between the event loop and its handler threads. Both want
SOCK_DGRAM rather than a pipe, and for the same reason: datagrams preserve
message boundaries, so concurrent writers can never interleave bytes mid-frame
and concurrent readers each dequeue exactly one whole message. A pipe
guarantees that only up to PIPE_BUF.

They differ in what they do with the ends afterwards — the bus makes both
non-blocking, while the pool deliberately leaves a worker's receive end
blocking so a parked thread sleeps instead of spinning — so this returns raw
descriptors and sets no options.
"""

from std.ffi import c_int, external_call, get_errno
from std.memory import alloc


comptime AF_UNIX = 1
comptime SOCK_DGRAM = 2


def socketpair_dgram() raises -> Tuple[Int, Int]:
    """One SOCK_DGRAM AF_UNIX pair. Returns (receive end, send end).

    The pair is symmetric — either end can send — so the naming is a
    convention the callers keep, not something the kernel enforces.

    NOTE: `alloc` without a `Layout` is deprecated, and the replacement does
    not exist on this toolchain: the `Layout` form returns a non-subscriptable
    `Allocation` and `unsafe_alloc` is not a symbol in Mojo 1.0. Same dead end
    `c/pipe.mojo` records. This is one of the counted warning sites in the
    ratchet's baseline.
    """
    var fds = alloc[c_int](count=2)
    var rc = external_call[
        "socketpair", c_int, c_int, c_int, c_int, type_of(fds)
    ](c_int(AF_UNIX), c_int(SOCK_DGRAM), c_int(0), fds)
    if rc != 0:
        var errno = get_errno()
        fds.unsafe_free()
        raise Error("socketpair() failed, errno: ", errno)
    var read_end = Int(fds[unsafe_offset=0])
    var write_end = Int(fds[unsafe_offset=1])
    fds.unsafe_free()
    return (read_end, write_end)
