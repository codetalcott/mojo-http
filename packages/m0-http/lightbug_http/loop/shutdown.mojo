"""The graceful drain: stop accepting, say goodbye, finish what is in flight.

`_run_shutdown` is the blocking composition every topology but the loop
inversion runs; the inversion drives the same three steps a pass at a
time from an asyncio callback (`_shutdown_begin`, `_shutdown_drain_step`,
`_shutdown_finish`). The drain's passes are ordinary ones (`_run_pass`, in
`event_loop.mojo`), for at most `DRAIN_TIMEOUT_NS`.
"""

from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.c.socket import close
from lightbug_http.connection import ConnectionState
from lightbug_http.ring import atomic_at
from lightbug_http.service import HTTPService
from std.time import perf_counter_ns

from lightbug_http.loop.state import (
    LoopState, UNUSED, _close_slot, _farewell_streams,
)
from lightbug_http.loop.accept import _admit_handoffs
from lightbug_http.loop.offload import _flush_submits
from lightbug_http.event_loop import _run_pass, _wait_for_events


def _close_between_requests[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState,
):
    """Close every connection that is between requests, during a shutdown.

    `active_count` counts a connection that is merely *open* the same as
    one with a request in flight, so without this a server holding idle
    keep-alive connections waited out the whole DRAIN_TIMEOUT_NS budget
    for clients that had already been answered — measured at 5.02 s to
    exit against 0.02 s idle, in every execution mode, which is most of
    `docker stop`'s 10 s.

    A slot in READING_HEADERS with an empty receive buffer is between
    requests: `prepare_for_new_request` clears the buffer after each
    response, and the first byte of the next request both refills it and
    moves the state on. Such a connection cannot be served by the drain
    loop under any circumstance — that loop dispatches EVFILT_WRITE only,
    so a request arriving during the drain is not read there. Closing it
    drops nothing that waiting would have delivered, and leaves the whole
    budget to connections genuinely mid-request or mid-response. A
    LINGERING slot is closed for the same reason: its refusal went out
    when it began, and what it is still reading is discarded.

    Called once before the drain clock starts AND after every completion
    pass inside it. The second call is the fix for the drain's other
    hold: a response that completes DURING the drain and goes out in one
    `send` never registers a write interest, so the drain's EVFILT_WRITE
    dispatch never sees it — it takes `_finish_response`'s keep-alive
    branch and re-arms for a next request the drain will never read.
    Measured with a 1.5 s request in flight at SIGTERM: the process
    exited at 1.55 s with `Connection: close` and 5.35 s with keep-alive,
    the response itself delivered at 1.5 s in both.

    Skipped, for the reasons the idle and header sweeps skip them: a slot
    with a job in a pool thread is working, not idle, and its provision
    is still borrowed by another thread.
    """
    for s in range(st.max_conns):
        if st.slot_fds[s] == UNUSED or st.offload.offloaded[s]:
            continue
        var kind = st.provision_pool.provisions[s].state.kind
        if (
            kind == ConnectionState.READING_HEADERS
            and len(st.provision_pool.provisions[s].recv_buffer) == 0
        ) or kind == ConnectionState.LINGERING:
            _close_slot(handler, backend, st, s, st.slot_fds[s])


comptime DRAIN_TIMEOUT_NS: Int = 5_000_000_000
"""The graceful drain's budget. Module scope because the drain is three
functions now, and both the blocking composition and the polled one
measure against the same 5 s."""

def _shutdown_begin[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState,
) raises -> Int:
    """Everything before the drain: leave accept sharing, close the
    listener, say goodbye to streams, close what has nothing to drain, and
    stop watching the shutdown pipe. Returns the stamp the drain measures
    its budget from.

    Split out of `_run_shutdown` so the drain can also be driven ONE PASS
    AT A TIME (`_shutdown_drain_step`). The blocking composition below is
    unchanged and is what every topology but the loop inversion uses.
    """
    # First, before anything the drain waits on: the caller's stop word,
    # so a producer thread ends DURING the drain rather than after it
    # (the host's join then counts from this stamp). Non-zero is the
    # signal; the value is when, for the bound.
    if st.stop_addr != 0:
        atomic_at(st.stop_addr)[].store(Int64(perf_counter_ns()))

    # Accept sharing: siblings stop sending here the moment they read the
    # word; what they sent before that is admitted now, so the drain
    # answers it rather than the kernel closing it unread at exit.
    if st.accept_share.active():
        st.accept_share.leave()
        # Every one, not a batch: the drain answers what was handed over.
        _ = _admit_handoffs(handler, backend, st)

    # Graceful shutdown: close listener, drain in-flight, close SSE
    try:
        close(st.listen_fd)
    except:
        pass
    # Nothing is owed from a listener that is gone: the drain's passes
    # must neither accept on the closed descriptor nor wait without
    # blocking for it.
    st.accept_owed = False
    st.handoffs_owed = False


    # Tell every streaming client we're going: an SSE close comment,
    # or a WebSocket close frame (1001 going away).
    _farewell_streams(handler, backend, st)

    # Close the connections that have nothing to drain, before timing
    # anything (see `_close_between_requests` for why this is safe).
    _close_between_requests(handler, backend, st)

    # Drain in-flight: keep serving what is already in flight, for at most
    # DRAIN_TIMEOUT_NS, with ordinary event-loop passes.
    #
    # This loop used to dispatch EVFILT_WRITE only and read nothing new,
    # which was two defects with one cause. A request whose BODY was still
    # arriving when SIGTERM landed was neither read on nor closed: the
    # client's remaining bytes sat unread, it was reset at the deadline,
    # and the process exited at 5.09 s (SPEC D9 -- found by the soak's
    # uploads population, 9.7 MB POSTs in flight at every drain; the bare
    # reproducer is `scripts/drain_upload_probe.py`). And a response too
    # large for one send was cut at its first write readiness, because
    # the write branch here closed the slot instead of sending the rest.
    # An ordinary pass does both correctly, services pool completions and
    # bus frames on the way, and flushes buffered submits at its bottom --
    # everything the old loop re-implemented in part. The listener is
    # already closed, so a pass accepts nothing; what a pass CAN still do
    # is answer a request that arrives on an open keep-alive connection,
    # and `_close_between_requests` after every pass is what bounds that:
    # a connection with no request in progress is closed, so only bytes
    # already sent by the client are ever served. gunicorn's graceful
    # timeout has the same shape.
    #
    # The shutdown pipe is deregistered first: its byte is never read, so
    # on kqueue a registered pipe stays readable, and every drain pass
    # would read the stop again and admit nothing a sibling handed over
    # during the drain. A second SIGTERM during the drain is ignored, as
    # it always was.
    #
    # `offload.inflight` is in the condition as well as `active_count`,
    # and not redundantly: a client that vanished while its request was
    # in a pool thread has already been subtracted from `active_count`,
    # but its slot stays borrowed until the completion arrives. Without
    # the second term a shutdown could leave that job unclaimed.
    if st.shutdown_read_fd >= 0:
        backend.try_delete_read(st.shutdown_read_fd)
    return perf_counter_ns()


def _shutdown_drain_step[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState,
    drain_start: Int,
    wait_ms: Int,
) raises -> Bool:
    """One pass of the drain. True when the drain is OVER -- nothing left
    in flight, or the budget spent.

    `wait_ms` is how long the pass may block in the backend. The blocking
    composition passes 100, as the `while` loop here always did; the loop
    inversion passes 0, because this runs inside an asyncio callback there
    and the in-flight application tasks live on that same loop -- blocking
    here is blocking them, which is the bug this split exists to fix.
    """
    # The `while` condition this replaces, then the deadline it broke on:
    # same order, so a drain with nothing left never waits, and one that
    # ran out of budget stops before another pass.
    if not (st.active_count > 0 or st.offload.inflight > 0):
        return True
    if (perf_counter_ns() - drain_start) > DRAIN_TIMEOUT_NS:
        return True
    var drain_events = _wait_for_events(backend, st, wait_ms)
    _ = _run_pass(handler, backend, st, drain_events)
    # A completion that just went out whole on a keep-alive
    # connection re-armed the slot for a request the drain must not
    # wait for; close it now rather than at the deadline.
    _close_between_requests(handler, backend, st)
    return False


def _shutdown_finish[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState,
) raises:
    """After the drain: say goodbye to a stream that appeared during it,
    flush the buffered submits, and record what accept sharing did."""
    # A stream whose head completed DURING the drain — a pool
    # thread answering a streamed WSGI response in its last job —
    # became a streaming slot after the farewell pass above, and
    # the drain loop dispatches EVFILT_WRITE only, so nothing in it
    # would close that connection. Say goodbye to it now, so the
    # producer thread gets its disconnect and comes back before the
    # bounded join, instead of being abandoned as a straggler.
    _farewell_streams(handler, backend, st)
    # Once more before returning: the executor's pill goes out on
    # its lane after this loop returns, and it must be FIFO behind
    # every job — a job still buffered here would arrive after the
    # pill and never run.
    _flush_submits(handler, backend, st)
    # The record of what accept sharing did in this worker's life, in the
    # shape `scripts/accept_spread.py` reads: a balanced split with zero
    # passed would be luck, not the mechanism.
    if st.accept_share.active():
        print(
            "Accept sharing: worker " + String(st.accept_share.worker)
            + " passed " + String(st.accept_share.handoffs_out)
            + " connections to siblings, received "
            + String(st.accept_share.handoffs_in),
            flush=True,
        )


def _run_shutdown[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState,
) raises:
    """The graceful shutdown, blocking: close the listener, say goodbye to
    streams, drain in-flight requests within the budget, flush the last
    submits. Behaviour is exactly what it was before the split -- the
    drain's pass still blocks up to 100 ms in the backend -- and this is
    what every topology except the loop inversion runs.
    """
    var drain_start = _shutdown_begin(handler, backend, st)
    while not _shutdown_drain_step(handler, backend, st, drain_start, 100):
        pass
    _shutdown_finish(handler, backend, st)
