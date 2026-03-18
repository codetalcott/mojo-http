"""macOS kqueue FFI wrappers for non-blocking IO multiplexing.

Provides kqueue(), kevent(), and fcntl() wrappers following the same
FFI pattern as socket.mojo. Used by event_loop.mojo to implement a
single-threaded, non-blocking HTTP server.
"""

from std.memory import stack_allocation
from std.ffi import c_int, external_call, get_errno
from sys.info import size_of

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


fn ev_set(
    ident: UInt,
    filter: Int16,
    flags: UInt16,
    fflags: UInt32 = 0,
    data: Int = 0,
    udata: UInt = 0,
) -> kevent_t:
    """Build a kevent struct (equivalent of EV_SET macro)."""
    return kevent_t(ident, filter, flags, fflags, data, udata)


fn _kqueue() -> c_int:
    """Raw kqueue() syscall."""
    return external_call["kqueue", c_int]()


fn kqueue() raises -> FileDescriptor:
    """Create a new kqueue file descriptor."""
    var result = _kqueue()
    if result == -1:
        var errno = get_errno()
        raise Error("kqueue() failed, errno: ", errno)
    return FileDescriptor(Int(result))


fn _kevent(
    kq: c_int,
    changelist: ExternalMutUnsafePointer[kevent_t],
    nchanges: c_int,
    eventlist: ExternalMutUnsafePointer[kevent_t],
    nevents: c_int,
    timeout: ExternalMutUnsafePointer[timespec_t],
) -> c_int:
    """Raw kevent() syscall — single FFI signature using ExternalMut pointers."""
    return external_call["kevent", c_int](
        kq, changelist, nchanges, eventlist, nevents, timeout,
    )


fn kevent_register_one(kq: FileDescriptor, ev: kevent_t) raises:
    """Submit a single kevent change using stack allocation (zero heap)."""
    var cl = stack_allocation[1, kevent_t]()
    cl[] = ev
    var null_ev = ExternalMutUnsafePointer[kevent_t]()
    var null_ts = ExternalMutUnsafePointer[timespec_t]()
    var result = _kevent(Int32(kq.value), cl, c_int(1), null_ev, c_int(0), null_ts)
    if result == -1:
        var errno = get_errno()
        raise Error("kevent_register_one failed, errno: " + String(errno))


fn kevent_register(kq: FileDescriptor, changes: Span[kevent_t, ...]) raises:
    """Submit kevent changes without polling for events."""
    var n = len(changes)
    var cl = alloc[kevent_t](count=n)
    for i in range(n):
        cl[i] = changes[i]

    var null_ev = ExternalMutUnsafePointer[kevent_t]()
    var null_ts = ExternalMutUnsafePointer[timespec_t]()
    var result = _kevent(kq.value, cl, c_int(n), null_ev, c_int(0), null_ts)
    cl.free()

    if result == -1:
        var errno = get_errno()
        raise Error("kevent_register failed, errno: " + String(errno))


fn kevent_poll(
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
    var null_cl = ExternalMutUnsafePointer[kevent_t]()
    var result = _kevent(
        Int32(kq.value), null_cl, c_int(0), eventlist, c_int(max_events), ts,
    )
    ts.free()

    if result == -1:
        var errno = get_errno()
        if errno == errno.EINTR:
            return 0
        raise Error("kevent_poll failed, errno: ", errno)
    return Int(result)


fn _fcntl(fd: c_int, cmd: c_int, arg: c_int = 0) -> c_int:
    """Raw fcntl(fd, cmd, arg) — single signature to avoid conflicting declarations.

    WARNING: fcntl is variadic (int fcntl(int, int, ...)). On ARM64 macOS,
    variadic args go on the stack, but external_call passes all args in
    registers. F_GETFL works (no variadic arg read by callee), but F_SETFL
    silently fails (the flags arg is never received). The event loop
    works around this by using kqueue event_data to count pending accepts
    instead of relying on EAGAIN from a non-blocking listen socket.
    """
    return external_call["fcntl", c_int, c_int, c_int, c_int](fd, cmd, arg)


fn set_nonblocking(fd: FileDescriptor) raises:
    """Set a file descriptor to non-blocking mode via fcntl().

    NOTE: This is currently a no-op on ARM64 macOS due to fcntl's variadic
    calling convention (see _fcntl docstring). Connection sockets still work
    because we only call recv/send when kqueue reports readiness. The listen
    socket uses event_data-based accept counting instead of EAGAIN.
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
