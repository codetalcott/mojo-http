"""Platform-agnostic IO multiplexing backend trait.

Implementations: KqueueBackend (macOS), EpollBackend (Linux).
run_event_loop is parameterized on this trait for zero-cost abstraction.

Filter constants are defined with kqueue semantics as the canonical names;
epoll backends map EPOLLIN/EPOLLOUT to these internally.
"""

from lightbug_http.c.kqueue import EVFILT_READ, EVFILT_WRITE, EVFILT_TIMER


trait EventLoopBackend:
    """Abstraction over OS IO multiplexing (kqueue / epoll)."""

    fn wait(mut self, timeout_ms: Int) raises -> Int:
        """Block until events arrive or timeout. Returns number of ready events."""
        ...

    fn event_ident(self, i: Int) -> UInt:
        """Return the fd/ident for event at index i."""
        ...

    fn event_filter(self, i: Int) -> Int16:
        """Return the filter for event at index i.

        Returns one of EVFILT_READ (-1), EVFILT_WRITE (-2), EVFILT_TIMER (-7)
        regardless of the underlying OS mechanism.
        """
        ...

    fn event_flags(self, i: Int) -> UInt16:
        """Return the flags for event at index i (EV_EOF, EV_ERROR, etc.)."""
        ...

    fn event_data(self, i: Int) -> Int:
        """Return the data field for event at index i."""
        ...

    # --- Registration ---

    fn add_read_listen(mut self, fd: Int) raises:
        """Register fd for persistent edge-triggered read events (listen socket).

        kqueue: EV_ADD | EV_CLEAR
        epoll:  EPOLLIN | EPOLLET
        """
        ...

    fn add_read(mut self, fd: Int) raises:
        """Register fd for edge-triggered read events (connection socket).

        kqueue: EV_ADD
        epoll:  EPOLLIN | EPOLLET
        """
        ...

    fn try_add_read(mut self, fd: Int):
        """Non-raising version of add_read."""
        ...

    fn add_write_oneshot(mut self, fd: Int) raises:
        """Register fd for a one-shot write-ready event.

        kqueue: EV_ADD | EV_ONESHOT on EVFILT_WRITE
        epoll:  EPOLLOUT | EPOLLET | EPOLLONESHOT
        """
        ...

    fn try_add_write_oneshot(mut self, fd: Int):
        """Non-raising version of add_write_oneshot."""
        ...

    fn try_delete_read(mut self, fd: Int):
        """Remove read filter for fd (best-effort, non-raising).

        kqueue: EV_DELETE on EVFILT_READ
        epoll:  EPOLL_CTL_DEL (removes all filters)
        """
        ...

    fn try_delete_write(mut self, fd: Int):
        """Remove write filter for fd (best-effort, non-raising).

        kqueue: EV_DELETE on EVFILT_WRITE
        epoll:  no-op (EPOLLONESHOT auto-disarms after firing)
        """
        ...

    fn try_add_timer(mut self, ident: UInt, timeout_ms: Int):
        """Register a one-shot timer with the given ident (best-effort).

        kqueue: EVFILT_TIMER, EV_ADD | EV_ONESHOT, data=timeout_ms
        epoll:  timerfd_create + timerfd_settime + EPOLLIN
        """
        ...

    fn try_delete_timer(mut self, ident: UInt):
        """Remove a timer (best-effort, non-raising).

        kqueue: EVFILT_TIMER, EV_DELETE
        epoll:  close timerfd and EPOLL_CTL_DEL
        """
        ...
