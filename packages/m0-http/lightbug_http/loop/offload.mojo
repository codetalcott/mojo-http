"""The loop's side of the handler pool and the ASGI executor.

A request handed to a pool thread (`--blocking-threads`) or an executor is
a job, and this is the loop's half of the hand-off; the pool's half is
`lightbug_http/offload.mojo`. An executor's submits are buffered and
flushed once per pass (`_flush_submits`), and what a batch could not carry
waits (`_hold_unsent`), as a request that finds an executor lane full does
(`_admit_waiting`). A finished job comes back over the
completion channel, or directly under the loop inversion
(`service_direct_completions`), and `_complete_one` answers it. Stream
credit the ack channel refused is retried every pass (`_retry_owed_acks`).
"""

from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.c.socket import send
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.http.common_response import InternalError
from lightbug_http.http.chunked import encode_chunk
from lightbug_http.io.bytes import Bytes
from lightbug_http.service import HTTPService
from lightbug_http.websocket import is_ws_upgrade_response

from lightbug_http.loop.state import LoopState, UNUSED, _close_slot
from lightbug_http.loop.request import _drain_pipelined
from lightbug_http.loop.response import _finish_response
from lightbug_http.loop.streams import _deliver_bus_frames
from std.collections import Optional
from std.ffi import c_int
from std.time import perf_counter_ns


def _retry_owed_acks(mut st: LoopState):
    """Retry the stream credit the ack channel refused.

    Credit the ack channel refused earlier (`ack_stream` returned
    False: EAGAIN, the executor not reading at that instant — most
    likely because it was itself waiting for THIS loop to drain its
    chunks). Retried every pass and never dropped: a window short by
    one ack is a `send()` that awaits forever. A slot that has since
    closed forfeits what it was owed; the head of the next stream on
    that slot seeds a fresh window.
    """
    if st.offload.ack_owed_count > 0:
        var can_ack = st.offload.chunk_active()
        for s in range(st.max_conns):
            if st.offload.ack_owed[s] <= 0:
                continue
            if st.slot_fds[s] == UNUSED or (can_ack and st.offload.pool()[].ack_stream(s, st.offload.ack_owed[s])):
                st.offload.ack_owed[s] = 0
                st.offload.ack_owed_count -= 1


def _flush_submits[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState,
):
    """Send every executor lane's buffered submits; what would not go
    waits (`_hold_unsent`).

    A slot left in the submit BUFFER across a wait is not an option: it is
    counted in `inflight`, so the shutdown drain would wait for a
    completion that cannot come, and a pill sent meanwhile would outrun
    it. A refused batch therefore leaves the buffer for the waiting queue,
    which the loop owns: it is out of `inflight`, the drain counts it by
    name, and `_admit_waiting` offers it again at the bottom of the pass
    after the refusal's wait (`OffloadLoopState.back_off`), which
    `_wait_for_events` waits out while anything waits with room for it,
    or after a job comes back.
    """
    if not st.offload.enabled() or st.offload.pending_submit_count == 0:
        return
    _hold_unsent(st, st.offload.flush_submits())


def _admit_waiting[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState,
):
    """Submit the requests that waited for room on an executor lane, oldest
    first, for as long as there is room (`OffloadLoopState.waiting_slots`).

    Called at the bottom of every pass, after the completions that make the
    room and before `_flush_submits` sends what this buffers, and after the
    inversion's direct completions, which no pass follows. A request whose
    client left while it waited is released unanswered, as one that left
    while it sat in a submit batch is.

    Nothing is offered while a refusal's wait runs (SPEC L44): the channel
    that refused is full, and its executor is not reading it.
    """
    if st.offload.waiting_count() == 0:
        return
    if st.offload.backing_off(Int(perf_counter_ns())):
        return
    ref pool = st.offload.pool()[]
    while st.offload.waiting_count() > 0 and st.offload.accepting():
        var slot = st.offload.next_waiting()
        var request = st.offload.take_waiting()
        if st.slot_fds[slot] == UNUSED:
            st.offload.offloaded[slot] = False
            st.provision_pool.release(slot)
            continue
        var lane = pool.lane_for(request.uri.path)
        pool.park_request(slot, request^)
        pool.stamp_lane(slot, lane)
        st.offload.inflight += 1
        if handler.direct_job(slot):
            continue
        if st.offload.queue_submit(slot, lane):
            var unsent = st.offload.flush_lane(lane)
            if len(unsent) > 0:
                # The channel is full: what it refused waits again, and
                # nothing more is offered this pass.
                _hold_unsent(st, unsent)
                break


def _hold_unsent(mut st: LoopState, slots: List[Int]):
    """Take back the requests a submit batch could not carry, to wait for
    the channel (`OffloadLoopState.waiting_slots`), ahead of what already
    waits and in their own order, and back off before offering them again.

    A refused batch used to run on the loop, as a refused `submit` to a
    pool thread still does. For an executor that is the application's
    `run_until_complete` on the loop's thread: every connection stopped,
    and the stop signal with them, until the handler returned (SPEC L39).
    Each slot stays `offloaded`, gives its job entry back and leaves
    `inflight`, exactly as a request that never found room.

    The batch goes back with one rebuild of the queue, and nothing is
    offered again until a job comes back or the refusal's wait ends
    (`OffloadLoopState.back_off`). Retried every millisecond with a
    rebuild per request, the loop spent most of a core while an
    application blocked its own asyncio loop (SPEC L44).
    """
    if len(slots) == 0:
        return
    ref pool = st.offload.pool()[]
    var room = len(slots) + st.offload.waiting_count()
    var back_slots = List[Int](capacity=room)
    var back_requests = List[Optional[HTTPRequest]](capacity=room)
    for i in range(len(slots)):
        var slot = slots[i]
        if slot < 0 or slot >= len(st.slot_fds) or not st.offload.offloaded[slot]:
            continue
        st.offload.inflight -= 1
        back_slots.append(slot)
        back_requests.append(Optional[HTTPRequest](pool.unpark_request(slot)))
    if len(back_slots) == 0:
        return
    st.offload.hold_waiting_first(back_slots^, back_requests^)
    st.offload.back_off(Int(perf_counter_ns()))


def _service_completions[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, read_fd: Bool = True,
):
    """Take every finished job off the completion ring — and, with
    `read_fd`, the completion channel — and answer it.

    Two outcomes per slot. The ordinary one hands the response to
    `_finish_response`, which is the same code the synchronous path runs. The
    other is a slot whose client vanished while the job was out: the fd is
    already closed and `slot_fds[slot]` is UNUSED, so the response is dropped
    and the provision — deliberately kept borrowed by `_close_slot` — is
    released here, where nothing else can be holding it.

    The channel carries one more shape: a stream abort, a producer saying
    that generation `gen` of `slot`'s stream died after its head. That slot
    is closed WITHOUT the chunked terminator — the client sees a truncated
    body, which is the truth — but only if it is still streaming that very
    generation; an abort for a stream the slot no longer serves is dropped.
    """
    if not st.offload.enabled():
        return
    ref pool = st.offload.pool()[]
    # Into the loop's own scratch list, kept across passes: a fresh List
    # per drain was an allocation and a free on most passes. Read by
    # index against the live length, so a completion that somehow
    # re-entered here could not walk a stale bound.
    st.offload.done_scratch.clear()
    pool.drain_completions_into(st.offload.done_scratch, read_fd)
    if len(st.offload.done_scratch) > 0:
        # A job came back, so its executor is reading: what waits behind
        # a refusal is offered at the bottom of this pass (SPEC L44).
        st.offload.executor_read()
    var aborts = pool.take_aborts()
    var f = 0
    while f < len(st.offload.done_scratch):
        var finished_slot = st.offload.done_scratch[f]
        f += 1
        _complete_one(handler, backend, st, finished_slot)


    # Aborts AFTER the completions of the same batch: an abort follows its
    # own head on this FIFO channel, and the head is what makes the slot a
    # stream (`slot_sse`) with a generation to check against. Handled
    # first, an abort that arrived beside its head would find nothing to
    # abort and the stream would stay open for good. Whatever the producer
    # managed to send before it died is handed out first — one eager,
    # chunk-framed send — so the client gets the bytes that exist and then
    # a close with no terminator, which is the truth about the body.
    var a = 0
    while a + 1 < len(aborts):
        var abort_slot = aborts[a]
        var abort_gen = aborts[a + 1]
        a += 2
        if abort_slot < 0 or abort_slot >= len(st.slot_fds):
            continue
        if st.slot_fds[abort_slot] == UNUSED or not (
            st.slot_sse[abort_slot] or st.slot_ws[abort_slot]
        ):
            continue
        if st.offload.stream_gen[abort_slot] != abort_gen:
            continue
        var last = handler.sse_drain_slot(abort_slot)
        if len(last) > 0:
            var out = encode_chunk(Span(last)) if st.offload.chunked[abort_slot] else Bytes(Span(last))
            try:
                _ = send(RawFileDescriptor(c_int(st.slot_fds[abort_slot])), Span(out), 0)
            except:
                pass
        st.offload.clear_stream(abort_slot)
        _close_slot(handler, backend, st, abort_slot, st.slot_fds[abort_slot])


def _complete_one[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, slot: Int,
):
    """Answer ONE finished job: the per-slot body of `_service_completions`.

    Shared by the datagram path (a completion arrived on the channel) and the
    inversion's direct path (`service_direct_completions`: the executor,
    on this same thread, hands the loop the slots it parked responses for).
    """
    ref pool = st.offload.pool()[]
    if slot < 0 or slot >= len(st.slot_fds):
        return
    if not st.offload.offloaded[slot]:
        return
    st.offload.offloaded[slot] = False
    st.offload.inflight -= 1
    if not pool.has_response(slot):
        # A pool thread completed without parking a response. Nothing can
        # produce this today; if it ever does, the slot is freed rather
        # than leaked and the connection is closed rather than hung.
        pool.discard(slot)
        if st.slot_fds[slot] == UNUSED:
            st.provision_pool.release(slot)
        else:
            _close_slot(handler, backend, st, slot, st.slot_fds[slot])
        return
    var response = pool.take_response(slot)
    # The synchronous path sets this when `func` raises; the pool thread
    # cannot reach the provision, so it reports and the loop applies it.
    if pool.raised(slot):
        st.provision_pool.provisions[slot].should_close = True
    if st.slot_fds[slot] == UNUSED:
        # Abandoned mid-flight: the response has nowhere to go, and this
        # is the point at which the slot is finally safe to reuse.
        pool.discard(slot)
        st.provision_pool.release(slot)
        return
    if response.sse_streaming or is_ws_upgrade_response(response):
        # Frame-before-head, made deterministic. The producer sent its
        # frame BEFORE this completion — an executor's or a streaming
        # pool thread's begin frame on the chunk channel (`bus_read_fd`),
        # a pool thread's hold frame (`h`/`H`) on this loop's own bus
        # channel (`peer_bus_fd`) — so the datagram is in its socket now.
        # But a completion off the ring is not an event: its frame's
        # readiness may not be in this pass's batch at all, and even a
        # datagram completion's batch carries the two readinesses in the
        # kernel's ready-list order, not ours. Draining both channels
        # here, before the head goes out, means the handler is subscribed
        # before the slot can ever be seen streaming — otherwise the
        # outbox sweep finds a flagged slot nothing produces for and
        # closes it, and the frame subscribes a slot that is already gone
        # (Linux CI, smoke-django-realtime phase 5, 2026-09-05).
        if st.bus_read_fd >= 0:
            var bus_fd = st.bus_read_fd
            _deliver_bus_frames(handler, st, bus_fd)
        if st.peer_bus_fd >= 0:
            var peer_fd = st.peer_bus_fd
            _deliver_bus_frames(handler, st, peer_fd)
    _finish_response(handler, backend, st, slot, st.slot_fds[slot], response^)
    # A request pipelined behind the one this pool thread just answered
    # is already in recv_buffer; nothing else will ever announce it.
    _drain_pipelined(handler, backend, st, slot, st.slot_fds[slot])


def service_direct_completions[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, slots: List[Int],
):
    """The inversion's completion seam: answer `slots` without a datagram.

    The executor, running on this same thread, parked a response for each
    slot exactly as a pool thread would and then calls this instead of
    poking the completion channel. Same per-slot code as the channel path
    (`_complete_one`); only the delivery differs. **Call `run_pass_once`
    FIRST**: a streamed response's begin frame rides the chunk channel and
    is drained by a pass, so a head completed here before that pass would
    precede its own begin frame — the recycled-slot hazard the streaming
    rules exist to prevent. On one thread the order is simply the order
    these two are called in.
    """
    if not st.offload.enabled():
        return
    for i in range(len(slots)):
        _complete_one(handler, backend, st, slots[i])
    if len(slots) > 0:
        st.offload.executor_read()
    _admit_waiting(handler, backend, st)
