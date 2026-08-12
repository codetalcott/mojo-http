"""POSIX process management FFI for multi-worker fork.

Usage:
    var pid = fork()
    if pid == 0:
        # child process
        _run_worker()
        process_exit(0)
    # parent: pid > 0
    var (child_pid, status) = waitpid_blocking(pid)
"""

from std.ffi import c_int, c_ssize_t, external_call, get_errno

from lightbug_http.c.aliases import ExternalMutUnsafePointer


def _fork() -> c_int:
    """Raw fork() syscall."""
    return external_call["fork", c_int]()


def _waitpid(
    pid: c_int, status: ExternalMutUnsafePointer[c_int], options: c_int,
) -> c_int:
    """Raw waitpid() syscall."""
    return external_call[
        "waitpid", c_int, type_of(pid), type_of(status), type_of(options),
    ](pid, status, options)


def _exit_raw(status: c_int):
    """Raw _exit() syscall — immediate process termination, no atexit handlers."""
    external_call["_exit", NoneType, c_int](status)


def _getpid() -> c_int:
    """Raw getpid() syscall."""
    return external_call["getpid", c_int]()


def fork() raises -> Int:
    """Fork the current process.

    Returns:
        0 in the child process, child PID (> 0) in the parent.

    Raises:
        Error: If fork() fails (e.g. process limit reached).
    """
    var pid = _fork()
    if pid == -1:
        var errno = get_errno()
        raise Error("fork() failed, errno: ", errno)
    return Int(pid)


def waitpid_blocking(pid: Int) raises -> Tuple[Int, Int]:
    """Wait for a specific child process to exit (blocking).

    Args:
        pid: Child PID to wait for, or -1 for any child.

    Returns:
        (child_pid, exit_status) tuple.

    Raises:
        Error: If waitpid() fails.
    """
    # NOTE: `alloc` without a Layout is deprecated, but the Layout form returns
    # an owning Allocation[T] (not subscriptable, no unsafe_free) and
    # `unsafe_alloc` does not exist in Mojo 1.0. Revisit when either lands.
    var status = alloc[c_int](count=1)
    var result = _waitpid(c_int(pid), status, c_int(0))
    if result == -1:
        var errno = get_errno()
        status.unsafe_free()
        raise Error("waitpid() failed, errno: ", errno)
    var status_val = Int(status[unsafe_offset=0])
    status.unsafe_free()
    return (Int(result), status_val)


def process_exit(status: Int):
    """Immediately terminate the current process.

    Uses _exit() (not exit()) to avoid flushing stdio buffers that
    belong to the parent process after fork().
    """
    _exit_raw(c_int(status))


def getpid() -> Int:
    """Return the PID of the current process."""
    return Int(_getpid())


# --- Signal management ---

comptime SIGTERM = 15
comptime SIGINT = 2


def _kill(pid: c_int, sig: c_int) -> c_int:
    """Raw kill() syscall."""
    return external_call["kill", c_int, c_int, c_int](pid, sig)


def kill_process(pid: Int, signal: Int) -> Bool:
    """Send a signal to a process. Returns True on success."""
    return Int(_kill(c_int(pid), c_int(signal))) == 0


def was_signaled(status: Int) -> Bool:
    """Check if a child process was terminated by a signal (from waitpid status)."""
    return (status & 0x7F) != 0


def term_signal(status: Int) -> Int:
    """Extract the signal number from a waitpid status."""
    return status & 0x7F


def exit_code(status: Int) -> Int:
    """Extract the exit code from a waitpid status (valid only if not signaled)."""
    return (status >> 8) & 0xFF
