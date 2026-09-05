"""POSIX pipe() FFI for graceful event-loop shutdown.

Usage:
    var (read_fd, handle) = create_shutdown_pipe()
    server.listen_and_serve_nonblocking(addr, handler, shutdown_read_fd=read_fd)
    # ... later, to trigger clean shutdown:
    handle.signal()
"""

from std.ffi import c_int, external_call, get_errno
from std.memory.alloc import unsafe_alloc

from lightbug_http.c.aliases import ExternalMutPointer


def _pipe(fds: ExternalMutPointer[c_int]) -> c_int:
    """Raw pipe() syscall."""
    return external_call["pipe", c_int](fds)


def _close(fd: c_int) -> c_int:
    """Raw close() syscall."""
    return external_call["close", c_int, c_int](fd)


def close_fd(fd: Int):
    """Close a descriptor, ignoring the result.

    For unwinding a half-built pipe: the only failure close() reports is EBADF,
    and a caller that is already abandoning the fd has nothing to do about it.

    Args:
        fd: The descriptor to close.
    """
    _ = _close(c_int(fd))


comptime _OpaqueConst = Pointer[NoneType, ImmUntrackedOrigin]
"""write(2) does not modify its buffer, so the source pointer is immutable.
Origins are erased in the C signature, so this still matches the declaration
the stdlib emits for this symbol."""

comptime _NUDGE_BYTE = "!"
"""The byte `notify` writes. Its value is arbitrary — the loop only reads
"this fd became readable" — but its *storage* is not: see `notify`."""


def _write(fd: Int, buf: _OpaqueConst, count: Int) -> Int:
    """Raw write() syscall.

    The argument types match the declaration the stdlib already emits for this
    symbol; a differently-shaped one is rejected as a conflicting signature.
    """
    return external_call["write", Int, Int, _OpaqueConst, Int](fd, buf, count)


struct ShutdownHandle(Movable):
    """Write end of a graceful-shutdown pipe.

    The event loop watches the corresponding read end via kqueue EVFILT_READ.
    Closing the write end sends EV_EOF to the read end, which the loop detects
    and uses to break out cleanly after draining in-flight work.
    """

    var fd: Int

    def __init__(out self, fd: Int):
        self.fd = fd

    def signal(self):
        """Trigger graceful shutdown by closing the write end of the pipe.

        The event loop sees EV_EOF on the read end and exits cleanly. This is
        the programmatic path — a `/shutdown` endpoint, a test. **Signal
        handlers must use `notify` instead**: close() is async-signal-safe, but
        it is not repeat-safe, and see `notify` for why that matters.
        """
        _ = _close(c_int(self.fd))

    def notify(self):
        """Trigger graceful shutdown by writing one byte to the pipe.

        What a signal handler calls. Both write() and close() are
        async-signal-safe, but only write() is safe to repeat: SIGTERM
        followed by SIGINT would close the same fd twice, and in between the
        kernel is free to hand that number to a freshly accepted connection —
        so the second close would drop a live client instead. Writing is
        idempotent, and the event loop treats "readable" and "EOF" on this fd
        identically.

        A full pipe (EAGAIN) or a closed read end (EPIPE) is ignored: the
        first means a shutdown is already queued, the second that the loop is
        already gone.
        """
        # The byte is sourced from .rodata, not from a local. A `var byte =
        # UInt8(1)` here compiles and writes A byte, but the address has to be
        # handed to an `external_call` as an untracked pointer, which severs
        # the alias information — the store is then dead-coded and the pipe
        # receives whatever the stack slot happened to hold. Verified: it wrote
        # 0x00. A literal's pointer is immortal, always initialised, and needs
        # no allocation, which a signal handler could not do anyway.
        _ = _write(
            self.fd,
            _NUDGE_BYTE.unsafe_ptr().unsafe_bitcast[NoneType]().unsafe_origin_cast[
                ImmUntrackedOrigin
            ](),
            1,
        )


def create_shutdown_pipe() raises -> Tuple[Int, ShutdownHandle]:
    """Create a pipe pair for graceful event-loop shutdown.

    Returns:
        (read_fd, handle): Pass read_fd to Server.listen_and_serve_nonblocking
        as the shutdown_read_fd keyword argument.  Hold handle and call
        handle.signal() whenever you want the server to stop.

    Raises:
        Error: If the pipe() syscall fails (e.g. file-descriptor limit reached).
    """
    # Freed below; `unsafe_alloc` is the non-Layout allocator (std.memory.alloc).
    var fds = unsafe_alloc[c_int](count=2)
    var ret = _pipe(fds)
    if ret == -1:
        var errno = get_errno()
        fds.unsafe_free()
        raise Error("pipe() failed, errno: ", errno)
    var read_fd = Int(fds[unsafe_offset=0])
    var write_fd = Int(fds[unsafe_offset=1])
    fds.unsafe_free()
    return (read_fd, ShutdownHandle(write_fd))
