"""`kqueue` implementation of `EventLoopBackend`, for macOS.

Wraps c/kqueue.mojo FFI into the EventLoopBackend trait so run_event_loop
can be parameterized over the backend type.
"""

from lightbug_http.c.kqueue import (
    kevent_t, ev_set, kqueue, kevent_register_one, kevent_register_pair,
    kevent_poll, kevent_poll_ns,
    EVFILT_READ, EVFILT_WRITE, EVFILT_TIMER,
    EV_ADD, EV_DELETE, EV_CLEAR, EV_ONESHOT,
)
from lightbug_http.c.pipe import close_fd
from lightbug_http.event_loop_backend import (
    ConstructibleBackend, EventLoopBackend, _MAX_EVENTS,
)
from std.memory.alloc import unsafe_alloc


struct KqueueBackend(ConstructibleBackend):
    """`kqueue`-based IO backend for macOS."""

    var kq: FileDescriptor
    var _events: Pointer[kevent_t, MutUntrackedOrigin]
    var _n_ready: Int

    def __init__(out self) raises:
        self.kq = kqueue()
        self._events = unsafe_alloc[kevent_t](count=_MAX_EVENTS)
        for i in range(_MAX_EVENTS):
            self._events[unsafe_offset=i] = kevent_t(0, 0, 0, 0, 0, 0)
        self._n_ready = 0

    def __deinit__(deinit self):
        """Close the kqueue and free the event buffer. A loop's backend is
        destroyed when the loop returns -- `Server.serve_nonblocking`, a
        thread of the host's, a test -- and neither used to be released
        until the process exited (review record LF21)."""
        close_fd(self.kq.value)
        self._events.unsafe_free()

    # --- EventLoopBackend methods ---

    def multiplexer_fd(self) -> Int:
        return self.kq.value

    def wait(mut self, timeout_ms: Int) raises -> Int:
        self._n_ready = kevent_poll(self.kq, self._events, _MAX_EVENTS, timeout_ms)
        return self._n_ready

    def wait_ns(mut self, timeout_ns: Int) raises -> Int:
        """`kevent`'s timespec takes nanoseconds, so nothing is rounded."""
        self._n_ready = kevent_poll_ns(self.kq, self._events, _MAX_EVENTS, timeout_ns)
        return self._n_ready

    def event_ident(self, i: Int) -> UInt:
        return self._events[unsafe_offset=i].ident

    def event_filter(self, i: Int) -> Int16:
        return self._events[unsafe_offset=i].filter

    def event_flags(self, i: Int) -> UInt16:
        return self._events[unsafe_offset=i].flags

    def event_data(self, i: Int) -> Int:
        return self._events[unsafe_offset=i].data

    def add_read_listen(mut self, fd: Int) raises:
        kevent_register_one(self.kq, ev_set(UInt(fd), EVFILT_READ, EV_ADD | EV_CLEAR))

    def add_read(mut self, fd: Int) raises:
        kevent_register_one(self.kq, ev_set(UInt(fd), EVFILT_READ, EV_ADD))

    def add_write_oneshot(mut self, fd: Int) raises:
        """A one-shot write filter IN PLACE OF the fd's read filter.

        epoll's registration is one mask per fd, so its write one-shot has
        always replaced the read interest; kqueue's filters are separate,
        and the read filter stayed. It is level triggered (`add_read` is
        EV_ADD without EV_CLEAR), so a slot waiting to write whose client
        had half-closed, or had sent its next request, was reported
        readable by every wait while it read nothing -- the loop at a full
        core for as long as the response waited (R4). Dropped in the same
        `kevent` call, so the two backends agree and it costs no syscall;
        the loop re-adds it when the send lands. The delete finds nothing
        when the read filter is already gone, which the pair forgives.
        """
        kevent_register_pair(
            self.kq,
            ev_set(UInt(fd), EVFILT_WRITE, EV_ADD | EV_ONESHOT),
            ev_set(UInt(fd), EVFILT_READ, EV_DELETE),
        )

    def try_delete_read(mut self, fd: Int):
        try:
            kevent_register_one(self.kq, ev_set(UInt(fd), EVFILT_READ, EV_DELETE))
        except:
            pass

    def try_delete_write(mut self, fd: Int):
        try:
            kevent_register_one(self.kq, ev_set(UInt(fd), EVFILT_WRITE, EV_DELETE))
        except:
            pass

    def try_add_timer(mut self, ident: UInt, timeout_ms: Int):
        try:
            kevent_register_one(
                self.kq,
                ev_set(ident, EVFILT_TIMER, EV_ADD | EV_ONESHOT, data=timeout_ms),
            )
        except:
            pass

    def try_delete_timer(mut self, ident: UInt):
        try:
            kevent_register_one(self.kq, ev_set(ident, EVFILT_TIMER, EV_DELETE))
        except:
            pass
