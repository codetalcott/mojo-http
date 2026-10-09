"""Linux epoll FFI wrappers for non-blocking IO multiplexing.

Provides epoll_create1(), epoll_ctl(), epoll_wait(), epoll_pwait2(),
timerfd_create() and timerfd_settime() wrappers following the same FFI pattern as kqueue.mojo.
Used by EpollBackend to implement a single-threaded, non-blocking HTTP server.

Filter constants use kqueue semantics as canonical names (EVFILT_READ etc.)
so that event_loop.mojo comparisons work on both platforms without changes.
"""

from std.memory import stack_allocation
from std.ffi import c_int, external_call, get_errno
from std.sys.info import CompilationTarget

from lightbug_http.c.aliases import ExternalMutPointer
from lightbug_http.c.socket_error import SysError


# Re-export kqueue canonical filter constants so EpollBackend callers can
# import everything they need from this module on Linux.
from lightbug_http.c.kqueue import (
    EVFILT_READ, EVFILT_WRITE, EVFILT_TIMER,
    EV_EOF, timespec_t,
)

# --- epoll event flags ---
comptime EPOLLIN: UInt32 = 0x001
comptime EPOLLOUT: UInt32 = 0x004
comptime EPOLLERR: UInt32 = 0x008
comptime EPOLLHUP: UInt32 = 0x010
comptime EPOLLRDHUP: UInt32 = 0x2000
comptime EPOLLET: UInt32 = 0x80000000   # edge-triggered
comptime EPOLLONESHOT: UInt32 = 0x40000000

# --- epoll_ctl operations ---
comptime EPOLL_CTL_ADD: c_int = 1
comptime EPOLL_CTL_DEL: c_int = 2
comptime EPOLL_CTL_MOD: c_int = 3

# `epoll_create1` and `timerfd_create` take c/fcntl.mojo's `O_CLOEXEC` and
# `O_NONBLOCK`: Linux defines EPOLL_CLOEXEC, TFD_CLOEXEC and TFD_NONBLOCK
# as those.

# --- timerfd constants ---
comptime CLOCK_MONOTONIC: c_int = 1


# glibc packs `struct epoll_event` ONLY on x86_64:
#
#   #ifdef __x86_64__
#   # define __EPOLL_PACKED __attribute__ ((__packed__))
#   #else
#   # define __EPOLL_PACKED          /* empty */
#   #endif
#
# so the layout is architecture-dependent:
#
#   x86_64 (packed, 12 bytes)     other (natural align, 16 bytes)
#     0: events (u32)               0: events (u32)
#     4: data   (u64)               4: <4 bytes padding>
#                                   8: data   (u64)
#
# Hardcoding the 12-byte form makes epoll_wait() return garbage idents on
# aarch64 (the kernel writes 16-byte records while we stride 12), so the
# listen fd never matches and no connection is ever accepted.
# Events are therefore handled as a flat UInt32 word buffer rather than a
# struct: Mojo cannot vary a struct's field list by target, and a struct whose
# size is wrong by 4 bytes silently corrupts every event after the first.
comptime EPOLL_EVENT_WORDS: Int = 3 if CompilationTarget.is_x86() else 4
comptime EPOLL_DATA_WORD: Int = 1 if CompilationTarget.is_x86() else 2


@always_inline
def epoll_event_mask(events: ExternalMutPointer[UInt32], i: Int) -> UInt32:
    """Read the events bitmask of the i-th event in a buffer."""
    return events[unsafe_offset=i * EPOLL_EVENT_WORDS]


@always_inline
def epoll_event_data(events: ExternalMutPointer[UInt32], i: Int) -> UInt64:
    """Read the 64-bit epoll_data_t of the i-th event in a buffer."""
    var base = i * EPOLL_EVENT_WORDS + EPOLL_DATA_WORD
    return UInt64(events[unsafe_offset=base]) | (UInt64(events[unsafe_offset=base + 1]) << 32)


@fieldwise_init
struct itimerspec_t(TrivialRegisterPassable):
    """POSIX struct itimerspec (32 bytes).

    it_interval = repeat interval (0 → one-shot)
    it_value    = initial expiration
    """

    var interval_sec: Int64   # struct timespec it_interval.tv_sec
    var interval_nsec: Int64  # struct timespec it_interval.tv_nsec
    var value_sec: Int64      # struct timespec it_value.tv_sec
    var value_nsec: Int64     # struct timespec it_value.tv_nsec


def epoll_create1(flags: c_int) -> c_int:
    """Raw epoll_create1(flags) syscall."""
    return external_call["epoll_create1", c_int, c_int](flags)


def _epoll_ctl(
    epfd: c_int,
    op: c_int,
    fd: c_int,
    event: OptionalPointer[UInt32, MutUntrackedOrigin],
) -> c_int:
    """Raw epoll_ctl(2) syscall.

    `event` is ignored (and conventionally NULL) for EPOLL_CTL_DEL, so it is
    modelled as `Optional`: Pointer is non-null by design and a literal
    null address is now rejected outright. Optional[Pointer] has the same
    layout with None as the null niche, so the ABI is unchanged.
    """
    return external_call[
        "epoll_ctl", c_int, c_int, c_int, c_int,
        OptionalPointer[UInt32, MutUntrackedOrigin],
    ](
        epfd, op, fd, event,
    )


@always_inline
def _fill_event(ev: ExternalMutPointer[UInt32], events: UInt32, data: UInt64):
    """Write one struct epoll_event into a caller-provided word buffer."""
    for w in range(EPOLL_EVENT_WORDS):
        ev[unsafe_offset=w] = 0
    ev[unsafe_offset=0] = events
    ev[unsafe_offset=EPOLL_DATA_WORD] = UInt32(data & 0xFFFFFFFF)
    ev[unsafe_offset=EPOLL_DATA_WORD + 1] = UInt32(data >> 32)


def epoll_ctl_add(
    epfd: FileDescriptor, fd: Int, events: UInt32, data: UInt64
) raises SysError:
    """Register fd with epoll (EPOLL_CTL_ADD).

    Raises:
        SysError: `epoll_ctl ADD` and its errno: EEXIST for an fd already
            registered, the one a caller may answer with MOD.
    """
    var ev = stack_allocation[EPOLL_EVENT_WORDS, UInt32]()
    _fill_event(ev, events, data)
    var result = _epoll_ctl(c_int(epfd.value), EPOLL_CTL_ADD, c_int(fd), ev)
    if result == -1:
        raise SysError("epoll_ctl ADD", get_errno())


def epoll_ctl_mod(
    epfd: FileDescriptor, fd: Int, events: UInt32, data: UInt64
) raises SysError:
    """Modify fd's epoll registration (EPOLL_CTL_MOD).

    Raises:
        SysError: `epoll_ctl MOD` and its errno: ENOENT for an fd not
            registered, the one a caller may answer with ADD.
    """
    var ev = stack_allocation[EPOLL_EVENT_WORDS, UInt32]()
    _fill_event(ev, events, data)
    var result = _epoll_ctl(c_int(epfd.value), EPOLL_CTL_MOD, c_int(fd), ev)
    if result == -1:
        raise SysError("epoll_ctl MOD", get_errno())


def epoll_ctl_del(epfd: FileDescriptor, fd: Int) raises SysError:
    """Remove fd from epoll (EPOLL_CTL_DEL). event pointer is ignored.

    Raises:
        SysError: `epoll_ctl DEL` and its errno.
    """
    var result = _epoll_ctl(c_int(epfd.value), EPOLL_CTL_DEL, c_int(fd), None)
    if result == -1:
        raise SysError("epoll_ctl DEL", get_errno())


def epoll_wait(
    epfd: FileDescriptor,
    events: ExternalMutPointer[UInt32],
    max_events: Int,
    timeout_ms: Int,
) raises -> Int:
    """Wait for events on epfd, returning the number of ready events.

    `events` must have room for max_events * EPOLL_EVENT_WORDS UInt32 words.
    """
    var result = external_call[
        "epoll_wait", c_int,
        c_int, ExternalMutPointer[UInt32], c_int, c_int,
    ](c_int(epfd.value), events, c_int(max_events), c_int(timeout_ms))
    if result == -1:
        var errno = get_errno()
        if errno == errno.EINTR:
            return 0
        raise Error("epoll_wait failed, errno: ", errno)
    return Int(result)


comptime SYS_EPOLL_PWAIT2 = 441
"""`epoll_pwait2`'s number, the same on x86_64 and aarch64: it came after
the syscall tables were unified (Linux 5.11)."""


def epoll_pwait2_ns(
    epfd: FileDescriptor,
    events: ExternalMutPointer[UInt32],
    max_events: Int,
    timeout_ns: Int,
) -> Int:
    """`epoll_wait` with a timeout in nanoseconds: `epoll_pwait2` (Linux
    5.11), whose timeout is a timespec where `epoll_wait`'s is whole
    milliseconds. Returns the ready count, 0 on EINTR, or -1 when the
    call failed any other way -- ENOSYS on an older kernel, EPERM under a
    seccomp profile that predates it -- and the caller falls back to
    `epoll_wait`.

    Through `syscall(2)` by number, not glibc's wrapper: the wrapper is a
    GLIBC_2.35 symbol, and naming it would raise the glibc floor of every
    binary that links the loop, the wheel's measured platform tag among
    them. `syscall` itself is variadic, and on both Linux ABIs this repo
    builds for an integer or pointer argument travels in the same
    register (or stack slot) whether the callee is variadic or not.
    No signal mask: NULL makes it `epoll_wait`'s semantics."""
    var ts = stack_allocation[1, timespec_t]()
    var ns = timeout_ns if timeout_ns > 0 else 0
    ts[] = timespec_t(Int64(ns // 1_000_000_000), Int64(ns % 1_000_000_000))
    var result = external_call[
        "syscall", Int,
        Int, c_int, ExternalMutPointer[UInt32], c_int,
        ExternalMutPointer[timespec_t], Int, Int,
    ](
        SYS_EPOLL_PWAIT2, c_int(epfd.value), events, c_int(max_events),
        ts, 0, 0,
    )
    if result == -1:
        var errno = get_errno()
        if errno == errno.EINTR:
            return 0
        return -1
    return result


def timerfd_create(clockid: c_int, flags: c_int) -> c_int:
    """Raw timerfd_create(2) syscall."""
    return external_call["timerfd_create", c_int, c_int, c_int](clockid, flags)


def timerfd_settime(
    fd: c_int,
    flags: c_int,
    new_value: ExternalMutPointer[itimerspec_t],
    old_value: OptionalPointer[itimerspec_t, MutUntrackedOrigin],
) -> c_int:
    """Raw timerfd_settime(2) syscall.

    `old_value` is NULL when the caller doesn't want the previous setting back,
    so it is modelled as `Optional` — see _epoll_ctl above.
    """
    return external_call[
        "timerfd_settime", c_int,
        c_int, c_int,
        ExternalMutPointer[itimerspec_t],
        OptionalPointer[itimerspec_t, MutUntrackedOrigin],
    ](fd, flags, new_value, old_value)


def set_timerfd_ms(fd: Int, timeout_ms: Int) raises:
    """Arm (or re-arm) a timerfd for a one-shot timeout in milliseconds."""
    var spec_stack = stack_allocation[1, itimerspec_t]()
    spec_stack[] = itimerspec_t(
        interval_sec=0,
        interval_nsec=0,
        value_sec=Int64(timeout_ms // 1000),
        value_nsec=Int64((timeout_ms % 1000) * 1_000_000),
    )
    var result = timerfd_settime(c_int(fd), 0, spec_stack, None)
    if result == -1:
        var errno = get_errno()
        raise Error("timerfd_settime failed, errno: ", errno)
