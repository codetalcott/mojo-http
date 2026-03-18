"""macOS kqueue implementation of EventLoopBackend.

Wraps c/kqueue.mojo FFI into the EventLoopBackend trait so run_event_loop
can be parameterized over the backend type.
"""

from lightbug_http.c.kqueue import (
    kevent_t, ev_set, kqueue, kevent_register_one, kevent_poll,
    set_nonblocking,
    EVFILT_READ, EVFILT_WRITE, EVFILT_TIMER,
    EV_ADD, EV_DELETE, EV_CLEAR, EV_ONESHOT, EV_EOF, EV_ERROR,
)
from lightbug_http.event_loop_backend import EventLoopBackend


comptime _MAX_EVENTS = 64


struct KqueueBackend(EventLoopBackend):
    """kqueue-based IO backend for macOS."""

    var kq: FileDescriptor
    var _events: UnsafePointer[kevent_t, MutExternalOrigin]
    var _n_ready: Int

    fn __init__(out self) raises:
        self.kq = kqueue()
        self._events = alloc[kevent_t](count=_MAX_EVENTS)
        for i in range(_MAX_EVENTS):
            self._events[i] = kevent_t(0, 0, 0, 0, 0, 0)
        self._n_ready = 0
    # Note: _events is process-lifetime (server runs until process exit).
    # No __del__ needed; OS reclaims the allocation on process exit.

    # --- EventLoopBackend methods ---

    fn wait(mut self, timeout_ms: Int) raises -> Int:
        self._n_ready = kevent_poll(self.kq, self._events, _MAX_EVENTS, timeout_ms)
        return self._n_ready

    fn event_ident(self, i: Int) -> UInt:
        return self._events[i].ident

    fn event_filter(self, i: Int) -> Int16:
        return self._events[i].filter

    fn event_flags(self, i: Int) -> UInt16:
        return self._events[i].flags

    fn event_data(self, i: Int) -> Int:
        return self._events[i].data

    fn add_read_listen(mut self, fd: Int) raises:
        kevent_register_one(self.kq, ev_set(UInt(fd), EVFILT_READ, EV_ADD | EV_CLEAR))

    fn add_read(mut self, fd: Int) raises:
        kevent_register_one(self.kq, ev_set(UInt(fd), EVFILT_READ, EV_ADD))

    fn try_add_read(mut self, fd: Int):
        try:
            self.add_read(fd)
        except:
            pass

    fn add_write_oneshot(mut self, fd: Int) raises:
        kevent_register_one(self.kq, ev_set(UInt(fd), EVFILT_WRITE, EV_ADD | EV_ONESHOT))

    fn try_add_write_oneshot(mut self, fd: Int):
        try:
            self.add_write_oneshot(fd)
        except:
            pass

    fn try_delete_read(mut self, fd: Int):
        try:
            kevent_register_one(self.kq, ev_set(UInt(fd), EVFILT_READ, EV_DELETE))
        except:
            pass

    fn try_delete_write(mut self, fd: Int):
        try:
            kevent_register_one(self.kq, ev_set(UInt(fd), EVFILT_WRITE, EV_DELETE))
        except:
            pass

    fn try_add_timer(mut self, ident: UInt, timeout_ms: Int):
        try:
            kevent_register_one(
                self.kq,
                ev_set(ident, EVFILT_TIMER, EV_ADD | EV_ONESHOT, data=timeout_ms),
            )
        except:
            pass

    fn try_delete_timer(mut self, ident: UInt):
        try:
            kevent_register_one(self.kq, ev_set(ident, EVFILT_TIMER, EV_DELETE))
        except:
            pass
