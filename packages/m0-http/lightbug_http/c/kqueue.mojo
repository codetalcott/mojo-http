"""macOS kqueue FFI wrappers for non-blocking IO multiplexing.

Provides kqueue(), kevent(), and fcntl() wrappers following the same
FFI pattern as socket.mojo. Used by event_loop.mojo to implement a
single-threaded, non-blocking HTTP server.
"""

from std.memory import stack_allocation
from std.ffi import c_int, external_call, get_errno
from std.sys.info import CompilationTarget, size_of

from lightbug_http.c.aliases import ExternalMutUnsafePointer
from lightbug_http.c.socket import O_NONBLOCK


# --- kqueue filter constants ---
comptime EVFILT_READ: Int16 = -1
comptime EVFILT_WRITE: Int16 = -2
comptime EVFILT_TIMER: Int16 = -7

# --- kqueue flag constants ---
comptime EV_ADD: UInt16 = 0x0001
comptime EV_DELETE: UInt16 = 0x0002
comptime EV_ENABLE: UInt16 = 0x0004
comptime EV_DISABLE: UInt16 = 0x0008
comptime EV_ONESHOT: UInt16 = 0x0010
comptime EV_CLEAR: UInt16 = 0x0020
comptime EV_EOF: UInt16 = 0x8000
comptime EV_ERROR: UInt16 = 0x4000

# --- fcntl commands ---
comptime F_GETFL: c_int = 3
comptime F_SETFL: c_int = 4


@fieldwise_init
struct kevent_t(TrivialRegisterPassable):
    """macOS struct kevent (32 bytes on ARM64).

    ```c
    struct kevent {
        uintptr_t  ident;   // 8 bytes
        int16_t    filter;  // 2 bytes
        uint16_t   flags;   // 2 bytes
        uint32_t   fflags;  // 4 bytes
        intptr_t   data;    // 8 bytes
        void      *udata;   // 8 bytes
    };
    ```
    """

    var ident: UInt
    var filter: Int16
    var flags: UInt16
    var fflags: UInt32
    var data: Int
    var udata: UInt


@fieldwise_init
struct timespec_t(TrivialRegisterPassable):
    """POSIX struct timespec."""

    var tv_sec: Int64
    var tv_nsec: Int64


def ev_set(
    ident: UInt,
    filter: Int16,
    flags: UInt16,
    fflags: UInt32 = 0,
    data: Int = 0,
    udata: UInt = 0,
) -> kevent_t:
    """Build a kevent struct (equivalent of EV_SET macro)."""
    return kevent_t(ident, filter, flags, fflags, data, udata)


def _kqueue() -> c_int:
    """Raw kqueue() syscall."""
    return external_call["kqueue", c_int]()


def kqueue() raises -> FileDescriptor:
    """Create a new kqueue file descriptor."""
    var result = _kqueue()
    if result == -1:
        var errno = get_errno()
        raise Error("kqueue() failed, errno: ", errno)
    return FileDescriptor(Int(result))


def _kevent(
    kq: c_int,
    changelist: OptionalUnsafePointer[kevent_t, MutExternalOrigin],
    nchanges: c_int,
    eventlist: OptionalUnsafePointer[kevent_t, MutExternalOrigin],
    nevents: c_int,
    timeout: OptionalUnsafePointer[timespec_t, MutExternalOrigin],
) -> c_int:
    """Raw kevent() syscall — single FFI signature using ExternalMut pointers.

    kevent() accepts NULL for changelist/eventlist/timeout, so those are
    modelled as `Optional`: UnsafePointer is non-null by design and a literal
    null address is now rejected outright. Optional[UnsafePointer] has the same
    layout with None as the null niche, so the ABI is unchanged.
    """
    return external_call["kevent", c_int](
        kq, changelist, nchanges, eventlist, nevents, timeout,
    )


def kevent_register_one(kq: FileDescriptor, ev: kevent_t) raises:
    """Submit a single kevent change using stack allocation (zero heap)."""
    var cl = stack_allocation[1, kevent_t]()
    cl[] = ev
    var result = _kevent(Int32(kq.value), cl, c_int(1), None, c_int(0), None)
    if result == -1:
        var errno = get_errno()
        raise Error("kevent_register_one failed, errno: " + String(errno))


def kevent_register(kq: FileDescriptor, changes: Span[kevent_t, ...]) raises:
    """Submit kevent changes without polling for events."""
    var n = len(changes)
    var cl = alloc[kevent_t](count=n)
    for i in range(n):
        cl[i] = changes[i]

    var result = _kevent(kq.value, cl, c_int(n), None, c_int(0), None)
    cl.free()

    if result == -1:
        var errno = get_errno()
        raise Error("kevent_register failed, errno: " + String(errno))


def kevent_poll(
    kq: FileDescriptor,
    eventlist: ExternalMutUnsafePointer[kevent_t],
    max_events: Int,
    timeout_ms: Int,
) raises -> Int:
    """Poll kqueue for events with a timeout."""
    var ts = alloc[timespec_t](count=1)
    ts[] = timespec_t(
        Int64(timeout_ms // 1000),
        Int64((timeout_ms % 1000) * 1_000_000),
    )
    var result = _kevent(
        Int32(kq.value), None, c_int(0), eventlist, c_int(max_events), ts,
    )
    ts.free()

    if result == -1:
        var errno = get_errno()
        if errno == errno.EINTR:
            return 0
        raise Error("kevent_poll failed, errno: ", errno)
    return Int(result)


def _fcntl(fd: c_int, cmd: c_int, arg: c_int = 0) -> c_int:
    """Raw fcntl(fd, cmd, arg) — single signature to avoid conflicting declarations.

    fcntl is variadic (int fcntl(int, int, ...)), and the two major ABIs
    disagree about what that means for the third argument:

    - x86-64 SysV and AAPCS64-Linux pass leading variadic args in the same
      registers as fixed args, so a plain three-argument declaration works.
    - Darwin ARM64 passes ALL variadic arguments on the stack; fixed
      arguments fill x0–x7 first. A three-argument call puts `arg` in x2,
      the callee's va_list never sees it, and F_SETFL silently reads
      whatever the stack happened to hold — historically making
      `set_nonblocking` a no-op there.

    The Darwin branch therefore declares NINE fixed arguments: fd and cmd
    land in x0/x1, six zero dummies burn x2–x7, and the ninth — the real
    arg — is forced onto the stack at sp+0, exactly where a variadic
    callee's va_list points after two named parameters. The dummies are
    never read by fcntl; only the stack slot is. `test_broadcast.mojo`
    asserts F_GETFL reflects O_NONBLOCK after `set_nonblocking`, which is
    what holds this ABI claim to account on the macOS CI runner.
    """
    comptime if CompilationTarget.is_macos():
        return external_call[
            "fcntl", c_int,
            c_int, c_int, Int, Int, Int, Int, Int, Int, Int,
        ](fd, cmd, 0, 0, 0, 0, 0, 0, Int(arg))
    else:
        return external_call["fcntl", c_int, c_int, c_int, c_int](fd, cmd, arg)


def set_nonblocking(fd: FileDescriptor) raises:
    """Set a file descriptor to non-blocking mode via fcntl().

    Works on both platforms — including ARM64 macOS, where this was a
    silent no-op until `_fcntl` learned the Darwin variadic convention (see
    its docstring). Callers written while the no-op stood carry their own
    belt-and-braces (MSG_DONTWAIT on the broadcast bus, event_data-based
    accept counting on the listen socket); those stay, because they are
    also correct and they document the history.
    """
    var fd_c = c_int(fd.value)
    var flags = _fcntl(fd_c, F_GETFL)
    if flags == -1:
        var errno = get_errno()
        raise Error("fcntl F_GETFL failed, errno: ", errno)
    var result = _fcntl(fd_c, F_SETFL, flags | c_int(O_NONBLOCK))
    if result == -1:
        var errno = get_errno()
        raise Error("fcntl F_SETFL failed, errno: ", errno)


def is_nonblocking(fd: FileDescriptor) raises -> Bool:
    """Whether O_NONBLOCK is set — F_GETFL truth, not what a caller hoped.

    F_GETFL takes no variadic argument, so it has always been reliable on
    every platform; that is what makes this the right probe for asserting
    `set_nonblocking` actually took effect.
    """
    var flags = _fcntl(c_int(fd.value), F_GETFL)
    if flags == -1:
        var errno = get_errno()
        raise Error("fcntl F_GETFL failed, errno: ", errno)
    return (Int(flags) & O_NONBLOCK) != 0
