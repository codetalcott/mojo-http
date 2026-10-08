"""Linux epoll implementation of EventLoopBackend.

Wraps c/epoll.mojo FFI into the EventLoopBackend trait so run_event_loop
can be parameterized over the backend type.

Timer idents encode both the fd value and the timer type (header/body/idle).
On Linux, timers are implemented via timerfd + epoll. The high bit (bit 63)
of the epoll data field marks a timerfd event so event_filter() can return
EVFILT_TIMER; bits 0–62 carry the original ident for event_ident().

_timer_fds layout (5 * 65536 entries, value = timerfd or -1):
  slot 0: header     ident in [0x100000, 0x10FFFF]  → index = ident - 0x100000
  slot 1: body       ident in [0x200000, 0x20FFFF]  → index = 65536 + ident - 0x200000
  slot 2: idle       ident in [0x300000, 0x30FFFF]  → index = 2*65536 + ident - 0x300000
  slot 3: heartbeat  ident in [0x400000, 0x40FFFF]  → index = 3*65536 + ident - 0x400000
  slot 4: app tick   ident 0x500000 (one per loop)  → index = 4*65536 + ident - 0x500000
"""

from lightbug_http.c.epoll import (
    itimerspec_t,
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
from std.ffi import c_int
from std.memory.alloc import unsafe_alloc


comptime _MAX_EVENTS = 64

# Bit 63 of epoll data.u64 marks events that came from a timerfd.
# The remaining 63 bits carry the original ident value.
comptime _TIMER_FLAG: UInt64 = 1 << 63

# Timer slot bases — must match loop/state.mojo's TIMER_HEADER/BODY/IDLE/
# SSE_HEARTBEAT/APP_TICK.
comptime _TIMER_HEADER: UInt = 0x100000
comptime _TIMER_BODY: UInt = 0x200000
comptime _TIMER_IDLE: UInt = 0x300000
comptime _TIMER_SSE_HEARTBEAT: UInt = 0x400000
comptime _TIMER_APP_TICK: UInt = 0x500000
comptime _TIMER_FD_MAP_SIZE: Int = 5 * 65536


@always_inline
def _timer_slot(ident: UInt) -> Int:
    """Map a timer ident to an index in the _timer_fds flat array.

    Layout (4 * 65536 entries):
      slot 0: header     ident in [0x100000, 0x10FFFF]  → index = ident - 0x100000
      slot 1: body       ident in [0x200000, 0x20FFFF]  → index = 65536 + ident - 0x200000
      slot 2: idle       ident in [0x300000, 0x30FFFF]  → index = 2*65536 + ident - 0x300000
      slot 3: heartbeat  ident in [0x400000, 0x40FFFF]  → index = 3*65536 + ident - 0x400000
      slot 4: app tick   ident 0x500000 (one per loop)  → index = 4*65536 + ident - 0x500000
    """
    if ident >= _TIMER_APP_TICK:
        return 4 * 65536 + Int(ident - _TIMER_APP_TICK)
    elif ident >= _TIMER_SSE_HEARTBEAT:
        return 3 * 65536 + Int(ident - _TIMER_SSE_HEARTBEAT)
    elif ident >= _TIMER_IDLE:
        return 2 * 65536 + Int(ident - _TIMER_IDLE)
    elif ident >= _TIMER_BODY:
        return 65536 + Int(ident - _TIMER_BODY)
    else:
        return Int(ident - _TIMER_HEADER)




struct EpollBackend(ConstructibleBackend):
    """`epoll`-based IO backend for Linux."""

    var epfd: FileDescriptor
    # Flat word buffer of _MAX_EVENTS structs; stride is EPOLL_EVENT_WORDS,
    # which differs by architecture (see c/epoll.mojo).
    var _events: Pointer[UInt32, MutUntrackedOrigin]
    var _n_ready: Int
    # _timer_fds[_timer_slot(ident)] = timerfd value, or -1 if no timer.
    var _timer_fds: Pointer[Int32, MutUntrackedOrigin]
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
        self._timer_fds = unsafe_alloc[Int32](count=_TIMER_FD_MAP_SIZE)
        for i in range(_TIMER_FD_MAP_SIZE):
            self._timer_fds[unsafe_offset=i] = -1
        self._n_ready = 0
        self._no_pwait2 = False
    # Note: _events and _timer_fds are process-lifetime allocations.
    # No __del__ needed; the OS reclaims them on process exit.

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
        EPOLLONESHOT disarmed the fd — still registered but inactive).

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
        except:
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
        # Try MOD first (fd already registered for reads); fall back to ADD.
        try:
            epoll_ctl_mod(self.epfd, fd, _W, UInt64(fd))
        except:
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
        if slot < 0 or slot >= _TIMER_FD_MAP_SIZE:
            return
        var existing_tfd = Int(self._timer_fds[unsafe_offset=slot])
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

        self._timer_fds[unsafe_offset=slot] = Int32(tfd)

    def try_delete_timer(mut self, ident: UInt):
        var slot = _timer_slot(ident)
        if slot < 0 or slot >= _TIMER_FD_MAP_SIZE:
            return
        var tfd = Int(self._timer_fds[unsafe_offset=slot])
        if tfd < 0:
            return
        try:
            epoll_ctl_del(self.epfd, tfd)
        except:
            pass
        close_fd(tfd)
        self._timer_fds[unsafe_offset=slot] = -1
