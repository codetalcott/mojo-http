"""Platform-agnostic IO multiplexing backend trait.

Implementations: KqueueBackend (macOS), EpollBackend (Linux).
run_event_loop is parameterized on this trait for zero-cost abstraction.

Filter constants are defined with kqueue semantics as the canonical names;
epoll backends map EPOLLIN/EPOLLOUT to these internally.
"""

from lightbug_http.c.kqueue import EVFILT_READ, EVFILT_WRITE, EVFILT_TIMER


comptime _MAX_EVENTS = 64
"""Events one `wait` can report: the size of each backend's event buffer."""


trait EventLoopBackend:
    """Abstraction over OS IO multiplexing (kqueue / epoll)."""

    def wait(mut self, timeout_ms: Int) raises -> Int:
        """Block until events arrive or timeout. Returns number of ready events."""
        ...

    def wait_ns(mut self, timeout_ns: Int) raises -> Int:
        """`wait` with a timeout in nanoseconds, for the pool's look at a
        pending job's deadline (`OffloadPool.next_look`), which is tens of
        microseconds away where `wait` counts milliseconds.

        kqueue: the `kevent` timespec, whole
        epoll:  `epoll_pwait2`, falling back to `epoll_wait` rounded UP to
                the millisecond where the kernel refuses it (before 5.11,
                or a seccomp profile without it)

        The default rounds up to milliseconds, never down: a wait that ends
        early is a look that finds nothing due and waits again, and a
        rounding to zero would be a spin."""
        return self.wait((timeout_ns + 999_999) // 1_000_000)

    def event_ident(self, i: Int) -> UInt:
        """Return the fd/ident for event at index i."""
        ...

    def event_filter(self, i: Int) -> Int16:
        """Return the filter for event at index i.

        Returns one of EVFILT_READ (-1), EVFILT_WRITE (-2), EVFILT_TIMER (-7)
        regardless of the underlying OS mechanism.
        """
        ...

    def event_flags(self, i: Int) -> UInt16:
        """Return the flags for event at index i.

        EV_EOF: the peer shut down or reset, or the socket holds an error --
        the recv or send the loop makes next returns it. kqueue sets it on
        the filter (the error in `fflags`); epoll maps EPOLLHUP, EPOLLRDHUP
        and EPOLLERR to it. EV_ERROR is kqueue's report of a registration
        that failed, which no backend's `wait` returns: a socket error is
        never EV_ERROR, because the loop skips that flag (B12).
        """
        ...

    def event_data(self, i: Int) -> Int:
        """Return the data field for event at index i."""
        ...

    # --- Registration ---

    def add_read_listen(mut self, fd: Int) raises:
        """Register fd for persistent edge-triggered read events (listen socket).

        kqueue: EV_ADD | EV_CLEAR
        epoll:  EPOLLIN | EPOLLET
        """
        ...

    def add_read(mut self, fd: Int) raises:
        """Register fd for read events (connection socket).

        The two differ, and every read path must satisfy the stricter:
        kqueue: EV_ADD, LEVEL triggered (no EV_CLEAR) -- bytes left unread
                are reported again by the next wait
        epoll:  EPOLLIN | EPOLLRDHUP | EPOLLET, edge triggered -- bytes
                left unread raise no further event until a re-add (ADD, or
                MOD on an fd already registered) regenerates one
        """
        ...

    def try_add_read(mut self, fd: Int):
        """Non-raising version of add_read: a failure is dropped."""
        try:
            self.add_read(fd)
        except:
            pass

    def add_write_oneshot(mut self, fd: Int) raises:
        """Register fd for a one-shot write-ready event IN PLACE OF its read
        interest, on both backends: a slot waiting to write reads nothing
        until `add_read` restores it (R4).

        kqueue: EV_ADD | EV_ONESHOT on EVFILT_WRITE, and EV_DELETE on
                EVFILT_READ, in one kevent call
        epoll:  EPOLLOUT | EPOLLET | EPOLLONESHOT (the MOD replaces the mask)
        """
        ...

    def try_add_write_oneshot(mut self, fd: Int):
        """Non-raising version of add_write_oneshot: a failure is dropped."""
        try:
            self.add_write_oneshot(fd)
        except:
            pass

    def try_delete_read(mut self, fd: Int):
        """Remove read filter for fd (best-effort, non-raising).

        kqueue: EV_DELETE on EVFILT_READ
        epoll:  EPOLL_CTL_DEL (removes all filters)
        """
        ...

    def try_delete_write(mut self, fd: Int):
        """Remove write filter for fd (best-effort, non-raising).

        kqueue: EV_DELETE on EVFILT_WRITE
        epoll:  no-op (EPOLLONESHOT auto-disarms after firing)
        """
        ...

    def try_add_timer(mut self, ident: UInt, timeout_ms: Int):
        """Register a one-shot timer with the given ident (best-effort).

        kqueue: EVFILT_TIMER, EV_ADD | EV_ONESHOT, data=timeout_ms
        epoll:  timerfd_create + timerfd_settime + EPOLLIN
        """
        ...

    def try_delete_timer(mut self, ident: UInt):
        """Remove a timer (best-effort, non-raising).

        kqueue: EVFILT_TIMER, EV_DELETE
        epoll:  close timerfd and EPOLL_CTL_DEL
        """
        ...


trait ConstructibleBackend(EventLoopBackend):
    """An `EventLoopBackend` a caller can build with no arguments.

    The two OS backends conform; the wrapping `DetachingBackend` does not,
    because it is built around one of them. The trait exists so that
    `PlatformBackend()` in `c/platform.mojo` has an initializer to resolve
    to -- a conditional type alias only sees what a shared trait declares.
    """

    def __init__(out self) raises:
        """Open the OS multiplexer (`kqueue()` / `epoll_create1`).

        The backend closes it, and every descriptor it opened beside it
        (epoll's timerfds), when it is destroyed: whoever holds a backend
        by address past its last use keeps it alive with `_ = backend`.
        """
        ...

    def multiplexer_fd(self) -> Int:
        """The multiplexer's own fd, for a selector that wants to watch it.

        The inverted executor hands it to asyncio (`add_reader`) so the
        server loop runs inside the Python loop's iteration.
        """
        ...
