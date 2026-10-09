"""SSE and WebSocket: what a streaming slot does after its head.

A WebSocket's frames are read and handed to the handler
(`_read_websocket`); what the handler queued for any stream goes out every
pass (`_drain_outboxes`); a heartbeat keeps an idle stream alive and finds
a dead one (`_heartbeat`); frames other workers publish arrive over the
bus (`_deliver_bus_frames`); and the closes and resumed reads the handler
asks for are applied at the bottom of every pass. Every frame this module
puts on a stream -- a heartbeat, a pong or close echo, what the handler
queued -- goes through `_send_frame`: one send, and one rule for a client
that has gone. Two sends elsewhere do not, each a best-effort send just
before its slot closes: the shutdown farewell (`_farewell_streams`,
`loop/state.mojo`) and an aborted stream's last bytes
(`_service_completions`, `loop/offload.mojo`).
"""

from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.c.socket import recv, send, spare_capacity
from lightbug_http.connection import ConnectionState
from lightbug_http.http.chunked import chunked_terminator, encode_chunk
from lightbug_http.io.bytes import Bytes
from lightbug_http.service import HTTPService
from lightbug_http.websocket import encode_ws_frame, WS_OP_PING

from lightbug_http.loop.state import (
    LoopState, TIMER_SSE_HEARTBEAT, UNUSED, _arm_reads, _arm_ws_linger,
    _await_write, _chunked_stream_ends, _close_slot, _rearm_reads,
    _slot_of, _stop_reads, _takes_an_out_of_band_frame, _ws_linger,
)
from lightbug_http.loop.request import _drain_pipelined
from lightbug_http.loop.response import _after_send


def _deliver_bus_frames[T: HTTPService](
    mut handler: T, mut st: LoopState, fd: Int
):
    """Drain one bus channel to EAGAIN through the loop's reader and hand
    each frame to the handler (`sse_peer_frame`), which queues it for its
    own subscribers; the pass's outbox drain sends it. What the reader
    refused is counted where `/__metrics` reads it."""
    var frames = st.bus_reader.drain(fd)
    st.metrics.bus_frames_refused = st.bus_reader.refused
    for f in range(len(frames)):
        handler.sse_peer_frame(frames[f].url, frames[f].event_id, frames[f].frame)


def _send_frame[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
    var frame: Bytes,
) -> Bool:
    """Put a frame on a stream slot: the slot's response, sent now as far as
    the socket takes it.

    The slot is RESPONDING while the frame goes out. What the send leaves
    -- all of it, when the send fails EAGAIN or takes no bytes -- waits for
    writability (`_await_write`, whose registration replaces the read
    interest on both backends), and the write-ready path sends the rest and
    runs `_after_send`. A send that fails with anything else means the
    client is gone, and the slot closes in the pass that found it
    (`_close_slot`, which tells the handler). That was the heartbeat's rule
    and the WebSocket reader's; the outbox drain swallowed the error and
    waited for writability, leaving the dead peer to the write-ready path a
    pass later. No deadline and no read interest are set here: those belong
    to the transitions (`loop/state.mojo`, review record C4).

    True when the frame is on its way: landed whole (`slot_send_offset`
    reaches its length, and the slot stays RESPONDING for the caller to say
    what follows) or waiting to be written. False when it is not: the slot
    is closed (`slot_fds` holds `UNUSED`), or the write registration failed
    and the slot is left as it stands, for the caller to close or leave
    (`_await_write`).
    """
    st.slot_response[slot] = frame^
    st.slot_send_offset[slot] = 0
    st.provision_pool.provisions[slot].state = ConnectionState.responding()
    try:
        st.slot_send_offset[slot] = Int(
            send(FileDescriptor(fd_val), Span(st.slot_response[slot]), 0)
        )
    except send_err:
        if not send_err.would_block():
            _close_slot(handler, backend, st, slot, fd_val)
            return False
    if st.slot_send_offset[slot] < len(st.slot_response[slot]):
        return _await_write(backend, st, slot, fd_val)
    return True


def _heartbeat[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, timer_ident: UInt,
):
    """A stream's heartbeat: an SSE comment or a WebSocket ping, re-armed
    first; a send that fails closes the stream."""
    var fd_val = Int(timer_ident - TIMER_SSE_HEARTBEAT)
    var hb_slot = _slot_of(st, fd_val)
    if hb_slot == UNUSED or not (st.slot_sse[hb_slot] or st.slot_ws[hb_slot]):
        # The stream this timer belonged to is gone (or the fd
        # now serves a non-streaming connection); retire the timer.
        backend.try_delete_timer(timer_ident)
        return
    var hb_is_ws = st.slot_ws[hb_slot]
    # Re-arm FIRST, unconditionally. Timers are one-shot on
    # both backends (kqueue EV_ONESHOT; epoll timerfd with no
    # interval), so without this a stream gets exactly one
    # heartbeat ever. On epoll the re-arm is also what clears
    # the fired timerfd's expiration count — the timerfd is
    # registered level-triggered and nothing read()s it, so an
    # expired-and-unrearmed timer would be returned by every
    # subsequent epoll_wait: a heartbeat storm at loop speed.
    backend.try_add_timer(timer_ident, st.config.sse_heartbeat_ms)
    # Skip this beat, keep the next, for a stream that may not take a frame
    # its application did not write now: an SSE stream the application
    # writes through the chunk channel, a WebSocket lingering after its
    # Close, a frame half sent (`_takes_an_out_of_band_frame`). Dead clients
    # of a channel stream are still discovered -- by chunk-send failures
    # and read-EOF, both of which close the slot -- and a hold's heartbeat
    # is what keeps it alive through an idle proxy.
    if not _takes_an_out_of_band_frame(st, hb_slot):
        return
    var frame: Bytes
    if hb_is_ws:
        frame = encode_ws_frame(WS_OP_PING, "hb".as_bytes())
    else:
        var hb = String(": heartbeat\n\n")
        frame = Bytes(hb.as_bytes())
    # EPIPE/ECONNRESET here is the heartbeat doing its other job:
    # discovering a dead subscriber that never sent a FIN, whose slot
    # `_send_frame` closes (telling the handler) rather than leaving a
    # zombie stream. A write registration that failed leaves the slot as
    # it stands, as the heartbeat always has.
    if not _send_frame(handler, backend, st, hb_slot, fd_val, frame^):
        return
    if st.slot_send_offset[hb_slot] >= len(st.slot_response[hb_slot]):
        st.provision_pool.provisions[hb_slot].state = ConnectionState.streaming_ws() if hb_is_ws else ConnectionState.streaming_sse()


def _read_websocket[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
    ws_peer_eof: Bool,
):
    """WebSocket frames from the client. The parser answers
    control frames itself (ping→pong, close→close echo);
    complete data messages go to the handler, whose queued
    replies the pass's outbox drain sends.
    """
    st.provision_pool.provisions[slot].recv_staging.clear()
    var ws_fd = FileDescriptor(fd_val)
    var ws_read: UInt
    try:
        ws_read = recv(
            ws_fd,
            spare_capacity(st.provision_pool.provisions[slot].recv_staging),
            0,
        )
    except ws_recv_err:
        if ws_recv_err.would_block():
            return
        _close_slot(handler, backend, st, slot, fd_val)
        return
    if ws_read == 0:
        _close_slot(handler, backend, st, slot, fd_val)
        return
    st.provision_pool.provisions[slot].recv_staging._len = Int(ws_read)
    var ws_res = st.slot_ws_state[slot].feed(
        Span(st.provision_pool.provisions[slot].recv_staging)
    )
    # The close code, told to the handler the moment it is parsed
    # (SPEC L28): before the echo, whose send fails when the
    # client has already gone -- a Close then a hang-up, the
    # ordinary shape -- and closes the slot on a path that never
    # reaches `close_after_reply` below.
    if ws_res.close_after_reply and ws_res.close_code >= 0:
        handler.ws_close_code(slot, ws_res.close_code)
    if len(ws_res.reply) > 0 and st.slot_ws_state[slot].closing:
        # This side already sent its Close; the parser's echo
        # would be a SECOND one. Drop it and let
        # `close_after_reply` do the closing — which is now the
        # RFC's moment for it, both Closes having been
        # exchanged.
        ws_res.reply.clear()
    # The pongs and the close echo go out WHOLE, now or through
    # the write-ready path, never cut. This send's count was
    # thrown away: a reply the kernel took only part of lost
    # its tail, and the peer read the next frame's header as the
    # rest of the payload -- every frame after it misframed
    # (R6; measured on macOS, where a one-read reply of 31 pongs
    # overflows a send buffer with 2 KB or more left, cut at
    # byte 115 of a 125-byte pong). What the kernel refused is
    # queued as the slot's response and the socket waits for
    # writability like any frame the outbox sends (`_send_frame`);
    # the write registration takes the read interest with it on
    # both backends, so reads stop until it lands, and the reply
    # is bounded by this one recv. A pong is no longer dropped on
    # EAGAIN either: RFC 6455 §5.5.2 says MUST, and a dropped
    # close echo left the peer with no Close at all.
    var reply_owed = False
    # The reply's write registration failed: nothing will send the rest.
    var reply_stranded = False
    if len(ws_res.reply) > 0:
        if not _send_frame(
            handler, backend, st, slot, fd_val, Bytes(Span(ws_res.reply))
        ):
            if st.slot_fds[slot] == UNUSED:
                # The client is gone, and its slot closed.
                return
            reply_stranded = True
        reply_owed = st.slot_send_offset[slot] < len(st.slot_response[slot])
        if not reply_owed:
            # Landed whole: the socket is back in frame mode.
            st.provision_pool.provisions[slot].state = (
                ConnectionState.streaming_ws()
            )
    # Every message of this batch is handed over — a False
    # does not stop the delivery, because these messages were
    # already read off the socket and the handler PARKS what
    # it cannot forward (bounded by this one recv: suspension
    # below is what stops a next batch from existing).
    var ws_suspend = False
    for m in range(len(ws_res.msg_opcodes)):
        if not handler.ws_message_take(
            slot, ws_res.msg_opcodes[m], ws_res.msg_payloads[m]
        ):
            ws_suspend = True
    if ws_res.close_after_reply:
        if reply_owed:
            # The echo is still going out: close once it has
            # (`_after_send`'s `should_close` branch).
            st.provision_pool.provisions[slot].should_close = True
        else:
            _close_slot(handler, backend, st, slot, fd_val)
    elif ws_suspend:
        # Inbound backpressure: stop READING this socket until
        # the handler's parked messages have gone through
        # (`take_ws_resumes`, at the bottom of every pass).
        # The socket's receive buffer then fills and TCP's
        # zero window stops the client — the peer's own Close
        # or ping simply waits in that buffer with the rest.
        # Writes are untouched: echoes and heartbeats still
        # drain, which is what lets the app's `receive` loop
        # keep consuming and the window reopen.
        #
        # `slot_read_armed` is the invariant, not bookkeeping:
        # EVERY re-arm site in the loop consults it, and on
        # epoll read and write share ONE registration, so the
        # outbox drain's `add_write_oneshot` MODs this read
        # interest away. Left saying "armed", nothing re-arms
        # and the socket stalls for ever — which is exactly
        # what Linux CI measured (3 of 3000 echoed, no drops)
        # while macOS passed, kqueue's filters being
        # independent.
        #
        # A reply still owed has taken the read interest already
        # (`_send_frame`), and its slot waits to write: on epoll
        # the delete would take the write one-shot with it, and
        # the reply would never go out (`_stop_reads`).
        if not reply_owed:
            _stop_reads(backend, st, slot, fd_val)
        st.slot_ws_state[slot].inbound_suspended = True
    elif (
        ws_read == UInt(st.provision_pool.provisions[slot].recv_staging.capacity())
        and st.slot_fds[slot] != UNUSED
    ):
        # ONE recv per event does not drain an edge-triggered
        # socket, and this path had no answer to that. The body
        # path already carries the fix and the reason ("a body
        # larger than the staging buffer leaves bytes pending
        # that will never raise another edge on their own"); the
        # WebSocket path was simply never asked, because until
        # there was an inbound flood gate nothing sent more than
        # a staging buffer at a time from the client side.
        #
        # kqueue hides it completely -- `add_read` is EV_ADD
        # without EV_CLEAR, so connection reads are LEVEL
        # triggered and the next pass simply reports the socket
        # readable again. On epoll the edge is spent, and once
        # the CLIENT stops sending (which is exactly what the
        # inbound window makes it do) no further edge is coming:
        # measured on Linux as 3 of 3000 messages echoed, with
        # the rest sitting unread in a socket buffer nobody
        # would look at again.
        #
        # Only on a FULL staging buffer, so an ordinary
        # small-message socket pays no extra syscall. Not while
        # a reply is owed: `_after_send` re-arms once it lands.
        if not reply_owed:
            _rearm_reads(backend, st, slot, fd_val)
    elif ws_peer_eof:
        # The peer has sent everything it will, and this read
        # took the rest of it: nothing more can arrive, so the
        # socket ends here, after its frames were delivered. A
        # full read re-armed above instead (more is buffered),
        # and a suspended one closes when its resumed read finds
        # the EOF again. An owed reply goes out first.
        if reply_owed:
            st.provision_pool.provisions[slot].should_close = True
        else:
            _close_slot(handler, backend, st, slot, fd_val)
    if reply_stranded and st.slot_fds[slot] != UNUSED:
        # Nothing will send the rest of the reply: the socket
        # closes, the batch's messages handed over first.
        _close_slot(handler, backend, st, slot, fd_val)


def _drain_outboxes[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState,
):
    """Outbox drain: push pending bytes to streaming connections — SSE
    events and WebSocket frames share the same per-slot outbox contract
    (sse_drain_slot returns whichever the handler queued).
    """
    # Skipped whole when no slot streams (`streaming_hint`, an upper
    # bound the flag-setting sites raise and this sweep recounts) — its
    # miss path is 1.2 µs per pass, +3.5% on the hello row and +4% on the
    # inverted executor. EXCEPT under a pump executor, where the loop
    # thread keeps sweeping every pass: measured, removing the sweep
    # there cost −3% rps at +6% CPU at c16 (nothing at c256), because a
    # loop that returns to `wait` a microsecond sooner batches fewer
    # submits and the executor takes more wakes per request. The
    # microsecond is accidental pacing; ROADMAP.md, "Pacing the pump's
    # loop thread", is the follow-up that would make it deliberate.
    var sweep_slots = (
        st.max_conns
        if (st.offload.streaming_hint > 0 or st.offload.sweep_every_pass())
        else 0
    )
    var streaming_seen = 0
    for s in range(sweep_slots):
        # The miss path, and it must stay exactly this — one flag pair
        # and a `continue` — because under the pump it runs 1,024 times
        # a pass whether anything streams or not.
        if not (st.slot_sse[s] or st.slot_ws[s]):
            continue
        streaming_seen += 1
        var s_idle = (
            st.slot_sse[s] and st.provision_pool.provisions[s].state.kind == ConnectionState.STREAMING_SSE
        ) or (
            st.slot_ws[s] and st.provision_pool.provisions[s].state.kind == ConnectionState.STREAMING_WS
        )
        if s_idle and st.slot_fds[s] != UNUSED and not st.offload.offloaded[s]:
            # A channel stream — an executor's, or a pool thread's WSGI
            # iterable (asked per slot: a held stream on the same loop
            # is drained by the same pass and is none of this): drained
            # bytes are acked back to the producer's credit window, and
            # `sse_is_streaming` — unread by the loop anywhere else —
            # becomes the end-of-stream signal: the handler unsubscribes
            # once the final chunk has been handed out, and the loop
            # closes after those bytes land. Close is how a
            # content-length-free streamed body ends.
            var channel_stream = st.offload.slot_channel_stream(s)
            var pending = handler.sse_drain_slot(s)
            # Read ONCE per pass: `sse_drain_slot` above is what makes it
            # go false, so asking twice can straddle the transition and
            # send a terminator on a stream that just queued more.
            var ended = channel_stream and not handler.sse_is_streaming(s)
            var framed = st.offload.chunked[s]

            # Payload bytes are what the producer's credit window counts.
            # Framing bytes are added below and deliberately excluded: a
            # window replenished by wire bytes shrinks by the framing
            # overhead on every chunk, and a long stream starves itself.
            var payload_len = len(pending)
            var out = Bytes()
            if framed:
                if payload_len > 0:
                    out = encode_chunk(Span(pending))
                if ended:
                    out.extend(chunked_terminator())
            elif payload_len > 0:
                out = Bytes(Span(pending))

            if len(out) > 0:
                # What the write-ready completion owes the producer if
                # this buffer does not land in one send below.
                st.offload.ack_payload[s] = payload_len if channel_stream else 0
                if not _send_frame(handler, backend, st, s, st.slot_fds[s], out^):
                    if st.slot_fds[s] == UNUSED:
                        # The client is gone, and its slot closed in this
                        # pass (`_send_frame`).
                        continue
                    # A write registration that failed leaves the slot as
                    # it stands, as the drain always has.
                if st.slot_send_offset[s] >= len(st.slot_response[s]):
                    # Landed in one send: ack here and cancel what the
                    # write-ready path would otherwise have owed.
                    st.offload.ack_payload[s] = 0
                    if channel_stream and payload_len > 0:
                        if not st.offload.pool()[].ack_stream(s, payload_len):
                            if st.offload.ack_owed[s] == 0:
                                st.offload.ack_owed_count += 1
                            st.offload.ack_owed[s] += payload_len
                    if ended:
                        # Whatever comes next on this slot is not this
                        # stream: forget its producer's ack fd and its
                        # generation before the connection is reused
                        # or closed.
                        st.offload.clear_stream(s)
                        if framed:
                            # The terminator landed: the message is
                            # complete and the connection is reusable,
                            # unless its request asked otherwise.
                            # Clearing the stream flag is what routes
                            # `_after_send` down its keep-alive path
                            # instead of back into streaming.
                            _chunked_stream_ends(st, s)
                            _after_send(handler, backend, st, s, st.slot_fds[s])
                            _drain_pipelined(handler, backend, st, s, st.slot_fds[s])
                        elif st.slot_ws[s] and st.config.idle_timeout > 0:
                            # The application's Close frame is on the wire,
                            # and closing HERE -- which is what this did --
                            # reset the peer's reply off the wire. Linger for
                            # it instead; `_arm_ws_linger` says why, and why
                            # this branch, which the drain reaches on every
                            # pass while the slot lingers, must arm ONCE.
                            _ws_linger(backend, st, s, st.slot_fds[s])
                        else:
                            _close_slot(handler, backend, st, s, st.slot_fds[s])
                        continue
                    st.provision_pool.provisions[s].state = ConnectionState.streaming_ws() if st.slot_ws[s] else ConnectionState.streaming_sse()
                else:
                    if ended:
                        # The final buffer is on its way; the stream's
                        # bookkeeping is over even so. The credit its
                        # last bytes owe was recorded in `ack_payload`
                        # before this and is acked by the write-ready
                        # path through `slot_channel_stream` — which
                        # stays true for an executor's slot (lane) and,
                        # for a pool thread's, is answered by the ack
                        # the eager send already covered.
                        st.offload.clear_stream(s)
                    if ended and not framed:
                        # The rest of the final buffer flushes through
                        # the write-ready path; _after_send's existing
                        # should_close branch closes it there — or lingers
                        # it, for a WebSocket, on the same `closing` flag
                        # the landed-whole branch above sets.
                        st.provision_pool.provisions[s].should_close = True
                        if st.slot_ws[s] and st.config.idle_timeout > 0:
                            st.slot_ws_state[s].closing = True
                    elif ended and framed:
                        # Same flush, but the message ends with the
                        # terminator already in this buffer — so the
                        # write-ready completion must finish it as a
                        # keep-alive response, or the close its request
                        # asked for.
                        _chunked_stream_ends(st, s)
            elif ended:
                # End marked with nothing left to send. Only reachable
                # unframed: a framed stream always has a terminator to
                # write, so `out` is never empty when it ends.
                st.offload.clear_stream(s)
                if st.slot_ws[s] and st.config.idle_timeout > 0:
                    # Same linger as the landed-whole branch above, and for
                    # the same reason: the peer's Close reply must not reach
                    # a socket that is already closed. This is the branch
                    # that was measured re-arming ~once a second forever.
                    _ws_linger(backend, st, s, st.slot_fds[s])
                else:
                    _close_slot(handler, backend, st, s, st.slot_fds[s])
    # The recount: what this sweep saw flagged is the bound for the next
    # pass. Nothing between the top of the sweep and here sets a flag
    # (`_finish_response` is not on this path), so a stream that begins
    # later in this pass raises the hint AFTER this store and is swept
    # next pass. Under a pump executor the store is harmless: the sweep
    # runs regardless.
    st.offload.streaming_hint = streaming_seen


def _linger_handler_closes[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState,
):
    """Sockets the handler closed itself (SPEC I26): its Close is queued, so
    the loop lingers as it does after its own -- the peer's reply ends the
    connection with no second Close, a peer that never replies is reaped
    by the sweep. With idle timeouts off nothing would bound that wait,
    so, as at the loop's own close sites, the socket closes at once.
    """
    var ws_closes = handler.take_ws_closes()
    for ci in range(len(ws_closes)):
        var cs = ws_closes[ci]
        if cs < 0 or cs >= st.max_conns or st.slot_fds[cs] == UNUSED or not st.slot_ws[cs]:
            continue
        if st.config.idle_timeout > 0:
            # Armed now, with the Close still queued: the socket keeps its
            # state and its registrations, which the drain's send of the
            # Close governs like any frame's.
            _arm_ws_linger(st, cs)
        else:
            _close_slot(handler, backend, st, cs, st.slot_fds[cs])


def _resume_suspended_reads[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState,
):
    """Inbound WebSocket resume: slots whose parked messages all went
    through get their read re-armed. kqueue's level trigger refires for
    bytes already buffered; epoll's ADD (the registration was DELETED,
    not disarmed) reports readiness at add time — so a client that
    finished sending mid-suspension is not stranded. Guarded on the slot
    still being THIS websocket: a stale resume for a closed slot names
    either an UNUSED slot or a successor whose read is already armed,
    so the worst case is an idempotent re-add. A socket whose frame or
    pong is still going out keeps waiting to write, and its reads come
    back when that lands (`_arm_reads`, R1).
    """
    var ws_resumes = handler.take_ws_resumes()
    for ri in range(len(ws_resumes)):
        var rs = ws_resumes[ri]
        if (
            rs >= 0 and rs < st.max_conns and st.slot_fds[rs] != UNUSED
            and st.slot_ws[rs] and not st.slot_read_armed[rs]
        ):
            st.slot_ws_state[rs].inbound_suspended = False
            _ = _arm_reads(backend, st, rs, st.slot_fds[rs])
