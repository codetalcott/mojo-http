"""What the backend's timers fire, and the deadlines the loop sweeps.

A timer's ident says whose it is (`TIMER_*`, in `loop/state.mojo`): the
application's tick, a stream's heartbeat (`_heartbeat`, in
`loop/streams.mojo`) or a request body that stopped arriving. The loop's
other clocks -- the idle, send, linger and header deadlines -- are stamps
in `LoopState` (`slot_idle_deadline`, `slot_header_start`) that
`_sweep_deadlines` checks once a second, rather than a timer per request.
"""

from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.connection import ConnectionState
from lightbug_http.http.common_response import RequestTimeout
from lightbug_http.service import HTTPService
from std.time import perf_counter_ns

from lightbug_http.loop.state import (
    LoopState, TIMER_APP_TICK, TIMER_BODY, TIMER_IDLE, TIMER_SSE_HEARTBEAT,
    UNUSED, _close_slot, _notice_once,
)
from lightbug_http.loop.response import _send_error_to_fd
from lightbug_http.loop.streams import _heartbeat


def _on_timer[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, timer_ident: UInt,
):
    """A timer fired: the application tick, a stream's heartbeat, or a
    request's body or idle timer."""
    # Application tick: hand the handler its scheduled wakeup.
    if timer_ident >= TIMER_APP_TICK:
        # Re-arm FIRST — one-shot on both backends, and on epoll
        # the re-arm is also what clears the fired timerfd's
        # readability (the same level-triggered storm the SSE
        # heartbeat hit; see `_heartbeat`).
        backend.try_add_timer(TIMER_APP_TICK, st.config.app_tick_ms)
        handler.tick(Int(perf_counter_ns() // 1_000_000))
        # Whatever the handler broadcast is queued in per-slot
        # outboxes now; the SSE drain at the bottom of this pass
        # pushes it to the wire.
        return

    # Stream heartbeat timer: an SSE comment or a WebSocket ping,
    # depending on what the slot is — same cadence, same job
    # (keep intermediaries from timing the connection out, and
    # discover dead clients that never sent a FIN).
    if timer_ident >= TIMER_SSE_HEARTBEAT:
        _heartbeat(handler, backend, st, timer_ident)
        return

    var fd_val: Int
    if timer_ident >= TIMER_IDLE:
        fd_val = Int(timer_ident - TIMER_IDLE)
    elif timer_ident >= TIMER_BODY:
        fd_val = Int(timer_ident - TIMER_BODY)
    else:
        return

    if fd_val >= len(st.fd_to_slot):
        return
    var slot = st.fd_to_slot[fd_val]
    if slot == UNUSED:
        return

    # A body timer ends a body that stopped arriving, and nothing
    # else. It closed its slot unasked -- a keep-alive connection
    # idle between requests, or one whose request was out on a pool
    # thread, whose provision `_close_slot` then RELEASED: the next
    # connection took the slot and was sent the pool thread's
    # response (B1). The arm below the decode in
    # `_handle_read_headers` leaves no timer behind a body that is
    # complete, but an expiry already in this batch outlives any
    # delete: the body's last bytes and the timer can land in one
    # `wait`, the read first, and the pass that completes the body
    # then reaches the timer. Retired rather than skipped, because
    # epoll's timerfd is level-triggered and an unread expiry is
    # reported by every wait after it.
    if timer_ident < TIMER_IDLE and (
        st.provision_pool.provisions[slot].state.kind
        != ConnectionState.READING_BODY
        or st.offload.offloaded[slot]
    ):
        backend.try_delete_timer(timer_ident)
        return

    # Phase 1d: idle timeout is expected client behaviour — close cleanly.
    # Only send 408 for header/body timeouts on the first request.
    if timer_ident < TIMER_IDLE:
        # A body that stopped arriving, refused whichever request it was.
        _notice_once(st.config.body_timeout_notice)
    if timer_ident < TIMER_IDLE and st.provision_pool.provisions[slot].keepalive_count == 0:
        _send_error_to_fd(fd_val, RequestTimeout())

    _close_slot(handler, backend, st, slot, fd_val)


def _sweep_deadlines[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState,
):
    """Idle-timeout sweep. Replaces the old per-request timerfd re-arm
    (one timerfd_settime per keep-alive request) with a once-a-second
    scan of active slots. Timeouts are whole seconds, so the 1 s sweep
    granularity changes nothing observable; the loop's wait() timeout
    of 1000 ms guarantees the sweep runs even when the server is idle.
    """
    if st.config.idle_timeout > 0 or st.config.header_read_timeout > 0:
        var sweep_now = perf_counter_ns()
        if sweep_now - st.last_idle_sweep >= 1_000_000_000:
            st.last_idle_sweep = sweep_now
            var header_ns = st.config.header_read_timeout * 1_000_000_000
            for s in range(st.max_conns):
                if st.slot_fds[s] == UNUSED:
                    continue
                # A slot with a job in a pool thread is working, not idle,
                # and its request belongs to another thread — closing it
                # here would release a provision still in use.
                if st.offload.offloaded[s]:
                    continue
                if (
                    st.config.idle_timeout > 0
                    and st.slot_idle_deadline[s] != 0
                    and sweep_now > st.slot_idle_deadline[s]
                ):
                    _close_slot(handler, backend, st, s, st.slot_fds[s])
                    continue
                # Header deadline, sweeping rather than by timerfd. A client
                # that connects and says nothing produces no read event, so
                # the check in `_read_headers` can never fire for it and
                # something has to notice on its own. Unlike the timerfd this
                # replaces, it also covers a client that stalls midway through
                # headers on a REUSED connection — that timer was armed on
                # accept and retired at the first complete header parse.
                if (
                    st.config.header_read_timeout > 0
                    and st.slot_header_start[s] != 0
                    and st.provision_pool.provisions[s].state.kind
                    == ConnectionState.READING_HEADERS
                    and sweep_now - st.slot_header_start[s] > header_ns
                ):
                    if st.provision_pool.provisions[s].keepalive_count == 0:
                        _send_error_to_fd(st.slot_fds[s], RequestTimeout())
                    _close_slot(handler, backend, st, s, st.slot_fds[s])
