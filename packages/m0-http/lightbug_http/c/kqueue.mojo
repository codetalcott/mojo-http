"""`kqueue` FFI wrappers for non-blocking IO multiplexing on macOS.

Provides kqueue() and kevent() wrappers, following the same FFI pattern as
socket.mojo, and the filter and flag constants `EventLoopBackend` uses as
its canonical names on both platforms. Used by `KqueueBackend` to
implement a single-threaded, non-blocking HTTP server.
"""

from std.memory import stack_allocation
from std.memory.alloc import unsafe_alloc
from std.ffi import c_int, external_call, get_errno
from std.sys.info import CompilationTarget, size_of

from lightbug_http.c.aliases import ExternalMutPointer


# --- kqueue filter constants ---
comptime EVFILT_READ: Int16 = -1
comptime EVFILT_WRITE: Int16 = -2
comptime EVFILT_TIMER: Int16 = -7

# --- kqueue flag constants ---
comptime EV_ADD: UInt16 = 0x0001
comptime EV_DELETE: UInt16 = 0x0002
comptime EV_ONESHOT: UInt16 = 0x0010
comptime EV_CLEAR: UInt16 = 0x0020
comptime EV_EOF: UInt16 = 0x8000
comptime EV_ERROR: UInt16 = 0x4000


@fieldwise_init
struct kevent_t(TrivialRegisterPassable):
    """`struct kevent` on macOS (32 bytes on ARM64).

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
    changelist: OptionalPointer[kevent_t, MutUntrackedOrigin],
    nchanges: c_int,
    eventlist: OptionalPointer[kevent_t, MutUntrackedOrigin],
    nevents: c_int,
    timeout: OptionalPointer[timespec_t, MutUntrackedOrigin],
) -> c_int:
    """Raw kevent() syscall — single FFI signature using ExternalMut pointers.

    kevent() accepts NULL for changelist/eventlist/timeout, so those are
    modelled as `Optional`: Pointer is non-null by design and a literal
    null address is now rejected outright. Optional[Pointer] has the same
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


def kevent_register_pair(kq: FileDescriptor, first: kevent_t, second: kevent_t) raises:
    """Submit two kevent changes in ONE syscall, forgiving the second a
    delete of nothing.

    kevent applies a changelist in order and, with no eventlist to report
    into, stops at the first change that fails and returns its errno -- so
    when the call fails with ENOENT, the first change has taken effect and
    the second found nothing to delete. No EV_ADD returns ENOENT, which is
    what makes it the one failure safe to forgive. The caller is
    `KqueueBackend.add_write_oneshot`, whose second change drops a read
    filter that may already be gone.
    """
    var cl = stack_allocation[2, kevent_t]()
    cl[unsafe_offset=0] = first
    cl[unsafe_offset=1] = second
    var result = _kevent(Int32(kq.value), cl, c_int(2), None, c_int(0), None)
    if result == -1:
        var errno = get_errno()
        if errno == errno.ENOENT:
            return
        raise Error("kevent_register_pair failed, errno: " + String(errno))


def kevent_poll(
    kq: FileDescriptor,
    eventlist: ExternalMutPointer[kevent_t],
    max_events: Int,
    timeout_ms: Int,
) raises -> Int:
    """Poll kqueue for events with a timeout."""
    return kevent_poll_ns(kq, eventlist, max_events, timeout_ms * 1_000_000)


def kevent_poll_ns(
    kq: FileDescriptor,
    eventlist: ExternalMutPointer[kevent_t],
    max_events: Int,
    timeout_ns: Int,
) raises -> Int:
    """Poll kqueue for events with a timeout in nanoseconds: `kevent`'s
    timespec carries them whole (measured on an Apple M4 at about 13 µs
    for a 10 µs timeout and 1.14 ms for 1 ms, the kernel's leeway)."""
    var ts = unsafe_alloc[timespec_t](count=1)
    ts[] = timespec_t(
        Int64(timeout_ns // 1_000_000_000),
        Int64(timeout_ns % 1_000_000_000),
    )
    var result = _kevent(
        Int32(kq.value), None, c_int(0), eventlist, c_int(max_events), ts,
    )
    ts.unsafe_free()

    if result == -1:
        var errno = get_errno()
        if errno == errno.EINTR:
            return 0
        raise Error("kevent_poll failed, errno: ", errno)
    return Int(result)
