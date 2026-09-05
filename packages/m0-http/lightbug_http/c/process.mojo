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

from lightbug_http.c.aliases import ExternalMutPointer


def _fork() -> c_int:
    """Raw fork() syscall."""
    return external_call["fork", c_int]()


def _waitpid(
    pid: c_int, status: ExternalMutPointer[c_int], options: c_int,
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
    # EINTR is not a failure: a caught signal interrupted the wait and there is
    # still a child to reap. Only reachable since the supervisor started
    # catching SIGTERM, and only on a platform whose signal(2) does not set
    # SA_RESTART — but a supervisor that died with "errno: 4" on shutdown
    # would be a maddening thing to debug.
    var err = get_errno()
    while result == -1 and err == err.EINTR:
        result = _waitpid(c_int(pid), status, c_int(0))
        err = get_errno()
    if result == -1:
        var errno = get_errno()
        status.unsafe_free()
        raise Error("waitpid() failed, errno: ", errno)
    var status_val = Int(status[unsafe_offset=0])
    status.unsafe_free()
    return (Int(result), status_val)


comptime WNOHANG = 1
"""`waitpid` option: report a stopped or exited child, but never block.

The same value on macOS and Linux, and on every other POSIX in practice —
it is one of the handful of constants the standard fixes rather than leaves
to the implementation.
"""


def waitpid_nonblocking() raises -> Tuple[Int, Int]:
    """Reap one exited child if there is one; otherwise return immediately.

    Returns:
        `(child_pid, exit_status)` for a child that has exited, `(0, 0)` when
        children exist but none has exited, and `(-1, 0)` when there are no
        children left to wait for (`ECHILD`).

    Raises:
        Error: If `waitpid()` fails for any other reason.

    The blocking twin is the right call for a supervisor whose only job is
    to outlive its workers. A supervisor that must also do something on a
    timer — watch files, for one — cannot afford to be parked in `wait`, so
    it polls with this and sleeps between passes. `ECHILD` is a return value
    rather than an error for the same reason: to a poller it means "nothing
    left to supervise", which is an ordinary end of the loop.
    """
    # A stack local rather than `alloc`, unlike the blocking twin: a poller
    # calls this several times a second for the life of the process, and a
    # heap allocation freed on every return is the wrong shape for that. It
    # also keeps the deprecated `alloc`-without-a-Layout out of a new call
    # site — see the note in `waitpid_blocking` for why that spelling is
    # still there at all.
    var status = c_int(0)
    # The origin has to be erased for the FFI signature; the round trip
    # through the address is the idiom this repo already uses for that.
    var local = Pointer(to=status)
    var status_ptr = Pointer[c_int, MutUntrackedOrigin](
        unsafe_from_address=Pointer(to=local).unsafe_bitcast[Int]()[]
    )
    var result = _waitpid(c_int(-1), status_ptr, c_int(WNOHANG))
    var err = get_errno()
    while result == -1 and err == err.EINTR:
        result = _waitpid(c_int(-1), status_ptr, c_int(WNOHANG))
        err = get_errno()
    if result == -1:
        if err == err.ECHILD:
            return (-1, 0)
        raise Error("waitpid(WNOHANG) failed, errno: ", err)
    return (Int(result), Int(status))


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
comptime SIGKILL = 9
"""The signal a process cannot catch, block or ignore.

Only ever the second half of a pair here: a supervisor asks with SIGTERM,
waits out a drain deadline, and uses this on whatever is still standing.
"""

comptime _SIG_ERR = -1
"""What signal(2) returns when it refuses — SIGKILL and SIGSTOP always do."""


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


def _raw_signal(sig: c_int, handler: Int) -> Int:
    """Raw signal() syscall. `handler` is a function address, or SIG_DFL/SIG_IGN."""
    return external_call["signal", Int, c_int, Int](sig, handler)


def install_signal_handler(sig: Int, handler_address: Int) -> Bool:
    """Install a handler for `sig`, returning True if it took.

    Uses `signal(2)` rather than `sigaction(2)` deliberately: `struct
    sigaction` has no portable layout (16 bytes on macOS, 152 on glibc, with
    `sa_mask` in different places), and nothing here needs a flag it cannot
    reach. `signal` gives BSD semantics on both platforms — the handler stays
    installed across deliveries, and restartable syscalls resume rather than
    failing with EINTR.

    Args:
        sig: Signal number, e.g. `SIGTERM`.
        handler_address: Address of a `def f(sig: c_int)` with no captures.
            Take it with `Pointer(to=handler_value).unsafe_bitcast[Int]()[]`,
            and keep `handler_value` alive across the call.

    Returns:
        True on success; False if the kernel refused (SIG_ERR), which is what
        SIGKILL and SIGSTOP always answer.
    """
    return _raw_signal(c_int(sig), handler_address) != _SIG_ERR


# --- exec, and the shared page that survives it ----------------------------
#
# A spawned worker is a forked child that immediately `execv`s the same
# binary. What it keeps across the exec is what POSIX keeps: open file
# descriptors (the listener, the bus socketpairs, the shared page's fd) and
# the environment. What it loses is every mapping — which is why the shared
# atomics page must be FILE-backed to survive, where fork alone was happy
# with MAP_ANONYMOUS.
#
# Buffers here are `List`s, not `alloc`: `alloc` without a `Layout` is one
# of the ratchet's counted warnings, and a list's `unsafe_ptr()` is the same
# pointer for the duration of the call.

from std.sys.info import CompilationTarget
from lightbug_http.c.kqueue import _fcntl


def _c_string(s: String) -> List[UInt8]:
    """A NUL-terminated copy: Mojo's `String` guarantees no NUL past its end."""
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b) + 1)
    out.extend(b)
    out.append(0)
    return out^


def executable_path() raises -> String:
    """The running binary's path, from the OS rather than from `argv[0]`.

    `argv[0]` may be a bare name resolved through PATH or a path relative to
    a directory the process has since left; a worker that re-execs must name
    the file itself. macOS answers through `_NSGetExecutablePath`, Linux
    through `/proc/self/exe`.
    """
    comptime cap = 4096
    var buf = List[UInt8](capacity=cap)
    buf.resize(cap, 0)
    var n: Int
    comptime if CompilationTarget.is_macos():
        var size = List[UInt32](capacity=1)
        size.append(UInt32(cap))
        var rc = external_call[
            "_NSGetExecutablePath", c_int, type_of(buf.unsafe_ptr()),
            type_of(size.unsafe_ptr()),
        ](buf.unsafe_ptr(), size.unsafe_ptr())
        _ = size
        if rc != 0:
            raise Error("_NSGetExecutablePath failed: path longer than 4096")
        n = 0
        while n < cap and buf[n] != 0:
            n += 1
    else:
        var link = _c_string("/proc/self/exe")
        var got = external_call[
            "readlink", c_ssize_t, type_of(link.unsafe_ptr()),
            type_of(buf.unsafe_ptr()), Int,
        ](link.unsafe_ptr(), buf.unsafe_ptr(), cap - 1)
        _ = link
        if got < 0:
            raise Error("readlink(/proc/self/exe) failed, errno: ", get_errno())
        n = Int(got)
    var out = String()
    for i in range(n):
        out += chr(Int(buf[i]))
    return out^


def exec_process(path: String, args: List[String]) -> String:
    """`execv(path, args)`: replace this process image. Returns only on failure.

    `args` is the whole argv, `args[0]` included. The environment is the
    caller's — `execv` passes `environ` — so anything `setenv`'d before this
    call reaches the new image, which is how a spawned worker learns its
    index. The return value names the errno.
    """
    var bufs = List[List[UInt8]]()
    for i in range(len(args)):
        bufs.append(_c_string(args[i]))
    var path_c = _c_string(path)
    var argv = List[Int](capacity=len(args) + 1)
    for i in range(len(args)):
        argv.append(Int(bufs[i].unsafe_ptr()))
    argv.append(0)
    _ = external_call[
        "execv", c_int, type_of(path_c.unsafe_ptr()), type_of(argv.unsafe_ptr())
    ](path_c.unsafe_ptr(), argv.unsafe_ptr())
    # Only reached on failure.
    var errno = String(get_errno())
    _ = argv
    _ = bufs
    _ = path_c
    return errno^


comptime _O_RDWR = 0x2
comptime _O_CREAT = 0x200 if CompilationTarget.is_macos() else 0x40
comptime _O_EXCL = 0x800 if CompilationTarget.is_macos() else 0x80
comptime _PROT_READ_WRITE = 0x1 | 0x2
comptime _MAP_SHARED = 0x01


comptime _F_GETFD = 1
comptime _F_SETFD = 2
comptime _FD_CLOEXEC = 1


def keep_across_exec(fd: Int) -> Bool:
    """Clear `FD_CLOEXEC` on `fd`, so an exec'd worker inherits it.

    Sockets and socketpairs are created without the flag here, but macOS's
    `shm_open` sets it on the descriptor it returns (measured: the spawned
    worker's `mmap` answered EBADF), and a future `SOCK_CLOEXEC` somewhere
    would silently detach a worker from its listener. Every descriptor a
    spawned worker must inherit goes through this, whatever its origin.
    """
    # `_fcntl` carries the macOS variadic ABI; a second `external_call` of
    # the same symbol with a different signature does not compile.
    var flags = _fcntl(c_int(fd), c_int(_F_GETFD), c_int(0))
    if flags < 0:
        return False
    if (Int(flags) & _FD_CLOEXEC) == 0:
        return True
    var rc = _fcntl(c_int(fd), c_int(_F_SETFD), c_int(Int(flags) & ~_FD_CLOEXEC))
    return rc == 0


def shared_file_fd(length: Int) raises -> Int:
    """An fd backing `length` bytes of shared memory that survives `exec`.

    `shm_open` under a name derived from this pid, unlinked at once so the
    fd is the only handle, sized with `ftruncate`. Not `FD_CLOEXEC`, on
    purpose: a spawned worker maps the same fd number it inherits.
    """
    var attempt = 0
    while True:
        var name = _c_string(
            "/m0-" + String(getpid()) + "-" + String(attempt)
        )
        var fd = external_call[
            "shm_open", c_int, type_of(name.unsafe_ptr()), c_int, c_int
        ](name.unsafe_ptr(), c_int(_O_RDWR | _O_CREAT | _O_EXCL), c_int(0o600))
        if fd >= 0:
            _ = external_call["shm_unlink", c_int, type_of(name.unsafe_ptr())](
                name.unsafe_ptr()
            )
            _ = name
            var rc = external_call["ftruncate", c_int, c_int, Int](fd, length)
            if rc != 0:
                raise Error("ftruncate on the shared page failed, errno: ", get_errno())
            if not keep_across_exec(Int(fd)):
                raise Error("could not clear FD_CLOEXEC on the shared page, errno: ", get_errno())
            return Int(fd)
        var errno = get_errno()
        _ = name
        attempt += 1
        if attempt > 16:
            raise Error("shm_open failed, errno: ", errno)


def map_shared_fd(fd: Int, length: Int) raises -> Int:
    """`mmap(MAP_SHARED)` the file `fd` describes; returns the address."""
    var raw = external_call[
        "mmap", Int, Int, Int, c_int, c_int, c_int, Int
    ](0, length, c_int(_PROT_READ_WRITE), c_int(_MAP_SHARED), c_int(fd), 0)
    if raw == -1 or raw == 0:
        raise Error("mmap of the shared page failed, errno: ", get_errno())
    return raw
