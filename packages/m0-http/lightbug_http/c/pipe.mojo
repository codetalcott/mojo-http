"""POSIX pipe() FFI for graceful event-loop shutdown.

Usage:
    var (read_fd, handle) = create_shutdown_pipe()
    server.listen_and_serve_nonblocking(addr, handler, shutdown_read_fd=read_fd)
    # ... later, to trigger clean shutdown:
    handle.signal()
"""

from std.ffi import c_int, external_call, get_errno

from lightbug_http.c.aliases import ExternalMutPointer


def _pipe(fds: ExternalMutPointer[c_int]) -> c_int:
    """Raw pipe() syscall."""
    return external_call["pipe", c_int](fds)


def _close(fd: c_int) -> c_int:
    """Raw close() syscall."""
    return external_call["close", c_int, c_int](fd)


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

        Safe to call at any time — including from a POSIX signal handler, since
        close() is async-signal-safe per POSIX.1-2017.  The event loop will
        detect EV_EOF on the read end and perform a clean exit.
        """
        _ = _close(c_int(self.fd))


def create_shutdown_pipe() raises -> Tuple[Int, ShutdownHandle]:
    """Create a pipe pair for graceful event-loop shutdown.

    Returns:
        (read_fd, handle): Pass read_fd to Server.listen_and_serve_nonblocking
        as the shutdown_read_fd keyword argument.  Hold handle and call
        handle.signal() whenever you want the server to stop.

    Raises:
        Error: If the pipe() syscall fails (e.g. file-descriptor limit reached).
    """
    # NOTE: `alloc` without a Layout is deprecated, but the Layout form returns
    # an owning Allocation[T] (not subscriptable, no unsafe_free) and
    # `unsafe_alloc` does not exist in Mojo 1.0. Revisit when either lands.
    var fds = alloc[c_int](count=2)
    var ret = _pipe(fds)
    if ret == -1:
        var errno = get_errno()
        fds.unsafe_free()
        raise Error("pipe() failed, errno: ", errno)
    var read_fd = Int(fds[unsafe_offset=0])
    var write_fd = Int(fds[unsafe_offset=1])
    fds.unsafe_free()
    return (read_fd, ShutdownHandle(write_fd))
