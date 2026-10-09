"""Linux epoll implementation of EventLoopBackend.

Wraps c/epoll.mojo FFI into the EventLoopBackend trait so run_event_loop
can be parameterized over the backend type.

Timer idents encode both the fd value and the timer type (header/body/idle).
On Linux, timers are implemented via timerfd + epoll. The high bit (bit 63)
of the epoll data field marks a timerfd event so event_filter() can return
EVFILT_TIMER; bits 0–62 carry the original ident for event_ident().

`_timer_fds` holds each timer's timerfd (or -1) at `_timer_slot(ident)`,
`fd * 5 + kind`, and grows with the descriptors timers are set for.
"""

from lightbug_http.c.epoll import (
    EPOLLIN, EPOLLOUT, EPOLLET, EPOLLONESHOT, EPOLLERR, EPOLLHUP, EPOLLRDHUP,
    CLOCK_MONOTONIC,
    EVFILT_READ, EVFILT_WRITE, EVFILT_TIMER,
    EV_EOF,
    EPOLL_EVENT_WORDS, epoll_event_mask, epoll_event_data,
    epoll_create1, epoll_ctl_add, epoll_ctl_mod, epoll_ctl_del, epoll_wait,
    epoll_pwait2_ns,
    timerfd_create, set_timerfd_ms,
)
from lightbug_http.c.fcntl import O_CLOEXEC, O_NONBLOCK
from lightbug_http.c.pipe import close_fd
from lightbug_http.event_loop_backend import ConstructibleBackend, EventLoopBackend
from std.ffi import ErrNo, c_int
from std.memory.alloc import unsafe_alloc


comptime _MAX_EVENTS = 64

# Bit 63 of epoll data.u64 marks events that came from a timerfd.
# The remaining 63 bits carry the original ident value.
comptime _TIMER_FLAG: UInt64 = 1 << 63

# A timer's ident is `TIMER_<kind> + fd` (loop/state.mojo): the kinds are
# 0x100000 apart from 0x100000 (header, body, idle, SSE heartbeat, app
# tick), so the kind is the ident's bits from 20 up and the fd the 20 below.
comptime _TIMER_KIND_SHIFT = 20
comptime _TIMER_KINDS = 5
comptime _TIMER_FD_MASK: UInt = (1 << 20) - 1
comptime _TIMER_MAP_START = _TIMER_KINDS * 1024
"""Slots the map starts with: every kind for descriptors below 1024."""


@always_inline
def _timer_slot(ident: UInt) -> Int:
    """A timer ident's index in `_timer_fds`: `fd * 5 + kind`, so every
    (kind, descriptor) pair has a slot of its own at any descriptor number,
    and the map grows with the highest descriptor a timer is set for; -1
    for an ident outside the five kinds.

    The slot was `kind * 65536 + fd` in a map of five 65536-entry regions,
    so a descriptor at or above 65536 took the next kind's slot for a lower
    one -- descriptor 65536's heartbeat the app tick's -- and adding or
    deleting its timer re-armed or closed the other's timerfd (review
    record LF18). A descriptor at or above 2^20 cannot be told from a lower
    one by its ident at all (loop/state.mojo's `TIMER_* + fd`). A process
    reaches one only with a descriptor limit (`RLIMIT_NOFILE`) above 2^20:
    the kernel's `fs.nr_open` defaults to exactly 2^20, but systemd (240
    and later) raises it to its maximum at boot, so on most hosts the limit
    is the only ceiling.
    """
    var kind = Int(ident >> _TIMER_KIND_SHIFT) - 1
    if kind < 0 or kind >= _TIMER_KINDS:
        return -1
    return Int(ident & _TIMER_FD_MASK) * _TIMER_KINDS + kind




struct EpollBackend(ConstructibleBackend):
    """`epoll`-based IO backend for Linux."""

    var epfd: FileDescriptor
    # Flat word buffer of _MAX_EVENTS structs; stride is EPOLL_EVENT_WORDS,
    # which differs by architecture (see c/epoll.mojo).
    var _events: Pointer[UInt32, MutUntrackedOrigin]
    var _n_ready: Int
    # _timer_fds[_timer_slot(ident)] = timerfd value, or -1 if no timer.
    var _timer_fds: List[Int32]
    # The kernel refused `epoll_pwait2` once; `wait_ns` rounds up to
    # `epoll_wait`'s milliseconds from then on.
    var _no_pwait2: Bool

    def __init__(out self) raises:
        var epfd_raw = epoll_create1(c_int(O_CLOEXEC))
        if epfd_raw == -1:
            raise Error("epoll_create1 failed")
        self.epfd = FileDescriptor(Int(epfd_raw))
        self._events = unsafe_alloc[UInt32](count=_MAX_EVENTS * EPOLL_EVENT_WORDS)
        for i in range(_MAX_EVENTS * EPOLL_EVENT_WORDS):
            self._events[unsafe_offset=i] = 0
        self._timer_fds = List[Int32](length=_TIMER_MAP_START, fill=-1)
        self._n_ready = 0
        self._no_pwait2 = False

    def __deinit__(deinit self):
        """Close every timerfd still held, then the epoll instance, and free
        the event buffer. A loop's backend is destroyed when the loop
        returns, and none of the three used to be released until the
        process exited (review record LF21)."""
        for tfd in self._timer_fds:
            if tfd >= 0:
                close_fd(Int(tfd))
        close_fd(self.epfd.value)
        self._events.unsafe_free()

    # --- EventLoopBackend methods ---

    def multiplexer_fd(self) -> Int:
        return self.epfd.value

    def wait(mut self, timeout_ms: Int) raises -> Int:
        self._n_ready = epoll_wait(self.epfd, self._events, _MAX_EVENTS, timeout_ms)
        return self._n_ready

    def wait_ns(mut self, timeout_ns: Int) raises -> Int:
        """`epoll_pwait2`, whose timespec keeps the nanoseconds; on a
        kernel that refuses it (before 5.11, or a seccomp profile without
        it) `epoll_wait` rounded UP to the millisecond, for this call and
        every later one -- the pool's cadence before its looks were timed,
        never a spin."""
        if not self._no_pwait2:
            var n = epoll_pwait2_ns(self.epfd, self._events, _MAX_EVENTS, timeout_ns)
            if n >= 0:
                self._n_ready = n
                return n
            self._no_pwait2 = True
        return self.wait((timeout_ns + 999_999) // 1_000_000)

    def event_ident(self, i: Int) -> UInt:
        var data = epoll_event_data(self._events, i)
        # Strip the timer flag to recover the original ident (or plain fd).
        return UInt(data & ~_TIMER_FLAG)

    def event_filter(self, i: Int) -> Int16:
        if (epoll_event_data(self._events, i) & _TIMER_FLAG) != 0:
            return EVFILT_TIMER
        if (epoll_event_mask(self._events, i) & EPOLLOUT) != 0:
            return EVFILT_WRITE
        return EVFILT_READ

    def event_flags(self, i: Int) -> UInt16:
        """EV_EOF for a peer's shutdown or reset, and for a socket error.

        EPOLLERR is a socket error, and it is reported the way kqueue
        reports one: as EV_EOF, the error being the socket's to return.
        It used to be EV_ERROR, which is kqueue's word for a REGISTRATION
        that failed and which the loop therefore skips -- and the skip took
        every client reset on Linux with it. An RST arrives as ONE event
        carrying EPOLLERR (beside EPOLLHUP), the one-shot write or
        edge-triggered read it lands on is spent by it, and nothing
        reported that socket again: its slot, descriptor and provision
        were held for the life of the process (B12). As EV_EOF it reaches
        the read or write path, whose recv or send returns the error and
        closes the slot.
        """
        var mask = epoll_event_mask(self._events, i)
        var flags: UInt16 = 0
        if (mask & (EPOLLHUP | EPOLLRDHUP | EPOLLERR)) != 0:
            flags |= EV_EOF
        return flags

    def event_data(self, i: Int) -> Int:
        # kqueue reports the listen backlog depth here; epoll has no
        # equivalent. Returning 0 tells the accept loop "unknown" so it
        # drains until accept() reports EAGAIN — see run_event_loop.
        return 0

    def add_read_listen(mut self, fd: Int) raises:
        """Persistent edge-triggered read (listen socket)."""
        epoll_ctl_add(self.epfd, fd, EPOLLIN | EPOLLET, UInt64(fd))

    def add_read(mut self, fd: Int) raises:
        """Edge-triggered read (connection socket).

        Tries ADD first (new fd); falls back to MOD (re-arm after
        EPOLLONESHOT disarmed the fd — still registered but inactive) only
        when ADD fails with EEXIST, the one errno that means the fd is
        registered. Any other failure is ADD's to report: it used to fall
        back on every errno, and an ADD refused for ELOOP, ENOSPC or EPERM
        was reported as MOD's ENOENT (review record LF21).

        EPOLLRDHUP is in the mask so a peer's half-close surfaces as
        EV_EOF (see `event_flags`), exactly as kqueue reports it on the
        read filter. Without it a half-close on Linux was an ordinary
        readable event: a COMPLETE buffered request was answered by the
        header path anyway, but an INCOMPLETE one sat holding its slot
        until the header timeout answered 408 — ten seconds for a
        connection the kernel already knew could never finish. The flag
        costs nothing per connection (same registration, one more mask
        bit) and makes the two backends agree on what a half-close is.

        Belt and braces, deliberately: a recv returning 0 marks
        `peer_eof` too, so the prompt release does not hinge on this
        flag alone (sabotage-verified — removing only the flag changes
        nothing observable). What the flag buys is parity — the EV_EOF
        path runs on both platforms instead of being macOS-only code —
        and the half-close arriving in the same event as the last data.
        """
        comptime _R = EPOLLIN | EPOLLRDHUP | EPOLLET
        try:
            epoll_ctl_add(self.epfd, fd, _R, UInt64(fd))
        except add_err:
            if add_err.errno != ErrNo.EEXIST:
                raise add_err
            epoll_ctl_mod(self.epfd, fd, _R, UInt64(fd))

    def try_add_read(mut self, fd: Int):
        try:
            self.add_read(fd)
        except:
            pass

    def add_write_oneshot(mut self, fd: Int) raises:
        """One-shot write-ready event, in place of the fd's read interest.

        The MOD replaces the whole mask, so the read interest goes with it
        -- the contract both backends now keep (`EventLoopBackend`).
        EPOLLONESHOT disarms the fd after any event fires. After send
        completes, add_read() re-arms with MOD (not ADD) to restore
        read events for keep-alive.
        """
        comptime _W = EPOLLOUT | EPOLLET | EPOLLONESHOT
        # Try MOD first (fd already registered for reads); fall back to ADD
        # only when MOD finds the fd unregistered (ENOENT).
        try:
            epoll_ctl_mod(self.epfd, fd, _W, UInt64(fd))
        except mod_err:
            if mod_err.errno != ErrNo.ENOENT:
                raise mod_err
            epoll_ctl_add(self.epfd, fd, _W, UInt64(fd))

    def try_add_write_oneshot(mut self, fd: Int):
        try:
            self.add_write_oneshot(fd)
        except:
            pass

    def try_delete_read(mut self, fd: Int):
        try:
            epoll_ctl_del(self.epfd, fd)
        except:
            pass

    def try_delete_write(mut self, fd: Int):
        # EPOLLONESHOT auto-disarms after firing; no explicit deletion needed.
        pass

    def try_add_timer(mut self, ident: UInt, timeout_ms: Int):
        var slot = _timer_slot(ident)
        if slot < 0:
            return
        if slot >= len(self._timer_fds):
            self._timer_fds.resize(max(slot + 1, 2 * len(self._timer_fds)), -1)
        var existing_tfd = Int(self._timer_fds[slot])
        if existing_tfd >= 0:
            # Re-arm the existing timerfd (avoids epoll re-registration).
            try:
                set_timerfd_ms(existing_tfd, timeout_ms)
            except:
                pass
            return

        # Create a new timerfd, arm it, and register it with epoll.
        var tfd_raw = timerfd_create(CLOCK_MONOTONIC, c_int(O_NONBLOCK | O_CLOEXEC))
        if tfd_raw == -1:
            return
        var tfd = Int(tfd_raw)
        try:
            set_timerfd_ms(tfd, timeout_ms)
        except:
            close_fd(tfd)
            return

        # Encode original ident in epoll data (high bit set → timer event).
        try:
            epoll_ctl_add(self.epfd, tfd, EPOLLIN, _TIMER_FLAG | UInt64(ident))
        except:
            close_fd(tfd)
            return

        self._timer_fds[slot] = Int32(tfd)

    def try_delete_timer(mut self, ident: UInt):
        var slot = _timer_slot(ident)
        if slot < 0 or slot >= len(self._timer_fds):
            return
        var tfd = Int(self._timer_fds[slot])
        if tfd < 0:
            return
        try:
            epoll_ctl_del(self.epfd, tfd)
        except:
            pass
        close_fd(tfd)
        self._timer_fds[slot] = -1
