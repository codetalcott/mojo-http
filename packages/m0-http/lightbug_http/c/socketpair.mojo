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
blocking so a parked thread sleeps instead of spinning — so this sets one
option only, the one both want: close-on-exec, so a process an application
starts with `exec` does not inherit the server's channels (SPEC G16).
"""

from std.ffi import c_int, external_call, get_errno
from std.memory.alloc import unsafe_alloc
from std.sys.info import CompilationTarget

from lightbug_http.c.fcntl import _fcntl, F_SETFD, FD_CLOEXEC


comptime AF_UNIX = 1
comptime SOCK_DGRAM = 2
comptime _SOCK_CLOEXEC_LINUX = 0x80000
"""Linux only: macOS refuses it in a socket type (EPROTONOSUPPORT, measured)."""


def socketpair_dgram() raises -> Tuple[Int, Int]:
    """One SOCK_DGRAM AF_UNIX pair. Returns (receive end, send end).

    The pair is symmetric — either end can send — so the naming is a
    convention the callers keep, not something the kernel enforces.

    The two-slot buffer is `unsafe_alloc`'d and freed on every path: the
    `Layout` allocator's owning `Allocation` would be the safer shape, but
    `socketpair(2)` wants a bare `int[2]`, and this is what the C call reads.
    """
    var fds = unsafe_alloc[c_int](count=2)
    var sock_type = SOCK_DGRAM
    comptime if not CompilationTarget.is_macos():
        # Born close-on-exec, with no instant in which another thread's
        # fork and exec could inherit the pair.
        sock_type = SOCK_DGRAM | _SOCK_CLOEXEC_LINUX
    var rc = external_call[
        "socketpair", c_int, c_int, c_int, c_int, type_of(fds)
    ](c_int(AF_UNIX), c_int(sock_type), c_int(0), fds)
    if rc != 0:
        var errno = get_errno()
        fds.unsafe_free()
        raise Error("socketpair() failed, errno: ", errno)
    var read_end = Int(fds[unsafe_offset=0])
    var write_end = Int(fds[unsafe_offset=1])
    fds.unsafe_free()
    comptime if CompilationTarget.is_macos():
        # Marked right after: a fresh fd's only fd flag is this one, and
        # F_SETFD fails only on EBADF, which a descriptor socketpair() just
        # returned is not.
        _ = _fcntl(c_int(read_end), c_int(F_SETFD), c_int(FD_CLOEXEC))
        _ = _fcntl(c_int(write_end), c_int(F_SETFD), c_int(FD_CLOEXEC))
    return (read_end, write_end)
