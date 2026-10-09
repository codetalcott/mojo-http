"""A request read, parsed and handed over -- or refused.

`_on_read` dispatches a readable socket on what its slot is doing. A
request's headers are read and parsed (`_handle_read_headers`), its body
read and decoded (`_read_body`), and the request built and answered on
this thread or handed to a pool thread (`_process_request`); what is
pipelined behind it is answered from the buffer (`_drain_pipelined`). A
request refused while its body is still arriving is answered, then read
and discarded until the client stops (`_reject_and_linger`).
"""

from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.c.socket import recv, shutdown, spare_capacity, ShutdownOption
from lightbug_http.connection import ConnectionState
from lightbug_http.framing import (
    BODY_CHUNKED, BODY_NONE, FRAME_REFUSED, FRAME_REQUEST, REFUSED_BARE_LF,
    REFUSED_BODY_TOO_LARGE, REFUSED_FRAMERS_DISAGREE, REFUSED_HEAD_TOO_LARGE,
    REFUSED_MALFORMED, REFUSED_NOT_IMPLEMENTED, REFUSED_URI_TOO_LONG,
    frame_request_head,
)
from lightbug_http.header import HeaderKey
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.http.common_response import (
    BadRequest, InternalError, URITooLong, RequestTimeout, HeadersTooLarge,
    NotImplemented, PayloadTooLarge,
)
from lightbug_http.strings import strHttp11, strHttp10
from lightbug_http.io.bytes import Bytes
from std.memory import unsafe_memcpy
from lightbug_http.server import BodyReadState
from lightbug_http.service import HTTPService
from std.time import perf_counter_ns

from lightbug_http.loop.state import (
    LoopState, TIMER_BODY, UNUSED, _arm_reads, _await_write, _begin_request,
    _close_slot, _notice_once, _rearm_reads, _stop_reads,
)
from lightbug_http.loop.response import (
    _finish_response, _send_error_to_fd, _send_raw_to_fd,
)
from lightbug_http.loop.streams import _read_websocket
from lightbug_http.loop.offload import _run_inline


# How long a connection refused before its request was read keeps reading,
# and discarding, what the client is still sending (`_reject_and_linger`).
# Long enough for an upload a few megabytes over the cap to finish on an
# ordinary link; bounded because a client that never stops must not hold
# the slot.
comptime REJECT_LINGER_NS: Int = 5_000_000_000
# Reads per readiness event while lingering -- 64 of the 4 KB staging
# buffer -- so one fast uploader cannot hold the loop for a whole upload.
comptime LINGER_READS_PER_EVENT = 64


def _on_read[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, fd_val: Int, eof: Bool,
):
    """A connection socket is readable, or its peer has shut down its
    write side (`eof`): dispatch on what the slot is doing -- a request's
    headers or body, a WebSocket's frames, a refused upload's linger, an
    SSE client leaving -- then answer what is pipelined behind."""
    if fd_val >= len(st.fd_to_slot):
        return
    var slot = st.fd_to_slot[fd_val]
    if slot == UNUSED:
        return

    # A slot whose request is in a pool thread belongs to that
    # thread: its job storage is being written right now. Detach
    # the connection if the client left, but hold the provision
    # until the completion arrives (see `_close_slot`).
    if st.offload.offloaded[slot]:
        if eof:
            # The peer half-closed while its request was out on
            # a pool thread. That is not "the client left" — a
            # half-close says "that is the whole request" while
            # the client waits for the answer, and detaching
            # the fd here dropped the response the pool thread
            # was about to complete. Record what is true (no
            # more request bytes exist) and let the completion
            # answer through the still-open fd; a peer that is
            # REALLY gone surfaces as a failed send there.
            # `should_close` is NOT set: the tail may hold a
            # pipelined request the drain still owes an answer,
            # and the recv->0 after the last one closes cleanly.
            st.provision_pool.provisions[slot].peer_eof = True
        # Nothing reads this slot until its completion: the EOF
        # above, or a pipelined request that arrived mid-flight,
        # waits for it. The read interest goes until then. kqueue's
        # is level triggered, and left registered it reported the
        # same bytes or EOF on every wait for as long as the view
        # ran -- the loop at a full core (R4, 3.97 CPU seconds in
        # 4 behind a half-closed /slow). `_after_send` re-arms it,
        # which on epoll, edge triggered, is also what regenerates
        # the readiness this event spent.
        _stop_reads(backend, st, slot, fd_val)
        return

    # A WebSocket whose peer has sent its last byte: read what it
    # left buffered, then close (`_read_websocket`'s `ws_peer_eof`).
    var ws_peer_eof = False
    if eof:
        # The peer shut down its WRITE side. That is not the end
        # of the connection: a client may half-close to say
        # "that is the whole request" and still be waiting to
        # read the response — and closing here discarded it,
        # which the client sees as an RST and a lost answer.
        #
        # kqueue sets EV_EOF on the read filter for exactly
        # this (data can still be pending), and epoll's
        # `add_read` registers EPOLLRDHUP so Linux reports it
        # the same way (see `event_flags`). It was macOS that
        # lost responses when this path closed instead of
        # falling through — 24-30 of 30 requests on every
        # request shape, Linux none, because epoll then left
        # EPOLLRDHUP unregistered and saw only an ordinary
        # readable event. The flag also ends a half-closed
        # INCOMPLETE request promptly on both platforms, where
        # Linux used to hold it until the header timeout's 408.
        #
        # A stream has no request left to answer, so those still
        # close here. Everything else falls through to the read
        # path, which finishes the buffered request, and the answer
        # to the last one the peer sent closes the connection
        # (`_answers_the_last_request`). Not `should_close` here:
        # on a slot whose answer was still going out it closed the
        # connection as that answer landed, and the requests
        # pipelined behind it, read already or still in the socket,
        # went unanswered (review record LF43). The keep-alive
        # transition answers them, and its drain's read finds the
        # EOF again.
        var _eof_state = st.provision_pool.provisions[slot].state.kind
        if _eof_state == ConnectionState.STREAMING_SSE:
            _close_slot(handler, backend, st, slot, fd_val)
            return
        if _eof_state == ConnectionState.STREAMING_WS:
            # A socket is not an SSE stream: its peer may have sent
            # a last message, or its Close, in the same instant it
            # hung up, and closing here threw both away unread --
            # the application heard 1006 for a client that closed
            # with 1000, and lost the message (SPEC L28). The read
            # below takes what is buffered and closes once the
            # socket holds nothing more.
            ws_peer_eof = True
        else:
            st.provision_pool.provisions[slot].peer_eof = True

    if st.provision_pool.provisions[slot].state.kind == ConnectionState.STREAMING_WS:
        _read_websocket(handler, backend, st, slot, fd_val, ws_peer_eof)
        return

    if st.provision_pool.provisions[slot].state.kind == ConnectionState.LINGERING:
        # Refused before its request was read; discard until the
        # client closes (`_reject_and_linger`).
        _linger_discard(handler, backend, st, slot, fd_val)
        return

    if st.provision_pool.provisions[slot].state.kind == ConnectionState.STREAMING_SSE:
        # SSE client disconnect: recv→0 means client closed
        # connection. _close_slot notifies the handler.
        _close_slot(handler, backend, st, slot, fd_val)
        return

    elif st.provision_pool.provisions[slot].state.kind == ConnectionState.READING_HEADERS:
        _handle_read_headers(handler, backend, st, slot, fd_val)

    elif st.provision_pool.provisions[slot].state.kind == ConnectionState.READING_BODY:
        if not _read_body(handler, backend, st, slot, fd_val):
            return

    else:
        # A slot that reads nothing in its state -- RESPONDING, its
        # bytes waiting for the client -- holds no read interest
        # (`_await_write`), so no event should reach it here. One
        # that does is consumed by putting that right, never by
        # falling through: kqueue's read is level triggered and
        # would report it again on every wait, the loop spinning
        # while the client does not read (R4), and on epoll a read
        # registration here has replaced the pending write one-shot
        # (R1's shape), which re-registering the write restores.
        # Belt and braces, deliberately: no path arms reads on such
        # a slot, so no gate fails without this (sabotage-verified);
        # it turns a write registration that FAILED, which leaves
        # kqueue's read filter in place, into a retry or a close
        # rather than a spinning loop.
        if (
            st.provision_pool.provisions[slot].state.kind
            == ConnectionState.RESPONDING
        ):
            if not _await_write(backend, st, slot, fd_val):
                _close_slot(handler, backend, st, slot, fd_val)
        else:
            _stop_reads(backend, st, slot, fd_val)
        return

    # A response completed inline above may have left the NEXT
    # pipelined request whole in recv_buffer, with no event ever
    # coming to announce it.
    _drain_pipelined(handler, backend, st, slot, fd_val)


def _read_body[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
) -> Bool:
    """Read more of a request body, and answer the request once it is
    whole. True when the read path goes on to answer what is pipelined
    behind it; False when the event ends here -- nothing to read, the
    slot closed, or the body refused."""
    var body_st = st.provision_pool.provisions[slot].body_state.value()

    # Phase 2a: recv into per-slot staging buffer (avoids per-recv heap alloc)
    st.provision_pool.provisions[slot].recv_staging.clear()
    var fd_desc = FileDescriptor(fd_val)
    var want = st.provision_pool.provisions[slot].recv_staging.capacity()
    var bytes_read: UInt
    try:
        bytes_read = recv(
            fd_desc,
            spare_capacity(st.provision_pool.provisions[slot].recv_staging),
            0,
        )
    except recv_err:
        if recv_err.would_block():
            return False
        _close_slot(handler, backend, st, slot, fd_val)
        return False

    if bytes_read == 0:
        _close_slot(handler, backend, st, slot, fd_val)
        return False

    st.provision_pool.provisions[slot].recv_staging._len = Int(bytes_read)
    st.provision_pool.provisions[slot].recv_buffer.extend(
        Span(st.provision_pool.provisions[slot].recv_staging)
    )

    if not body_st.is_chunked:
        body_st.bytes_read += Int(bytes_read)
        st.provision_pool.provisions[slot].body_state = body_st

    # No check of the whole buffer's size here: it holds the head, and the
    # next pipelined request behind the body, as well as the body. Measured,
    # it refused a body within both caps -- 400 for a `Content-Length` body
    # whose last read also brought the next request, once head, body and
    # that request passed `recv_buffer_limit()`, and 400 and a close rather
    # than the 413 and linger every size refusal gets (`_refuse_too_large`)
    # for a chunked body over the cap behind a long head (review record
    # LF70). The buffer is bounded without it: a `Content-Length` body is
    # at most the cap the framing checked, plus one read past it; a chunked
    # one is held to both of its bounds after each decode, below, and the
    # decoder consumes every byte it is handed until the body ends, so what
    # waits undecoded is at most one read (`HTTPChunkedDecoder.pending_bytes`;
    # `test_a_chunk_line_that_never_ends_is_refused_at_twice_the_cap`).

    # Phase 1b: chunked body decode, resumed not restarted.
    #
    # The buffer is laid out [headers][decoded so far][raw
    # tail], and only the raw tail is handed to the
    # connection's own decoder — which carries its chunk
    # state across reads, so it continues where it stopped.
    # Decoded output lands at the front of that tail, i.e.
    # contiguous with what was already decoded. The decoder
    # consumes every byte it is handed, a half-read size line
    # or extension included, so while the body is incomplete
    # nothing is left after it (`pending_bytes` is 0), and
    # once it completes what follows is the next request.
    # Total work is linear in the body rather than quadratic
    # in the number of reads; see
    # `ConnectionProvision.chunk_decoder`.
    if body_st.is_chunked:
        var raw_body_start = body_st.header_end_offset
        var decoded_so_far = body_st.bytes_read
        var tail_start = raw_body_start + decoded_so_far
        var buf_len = len(st.provision_pool.provisions[slot].recv_buffer)
        if buf_len > tail_start:
            var ret: Int
            var produced: Int
            ret, produced = st.provision_pool.provisions[
                slot
            ].chunk_decoder.decode(
                Span(st.provision_pool.provisions[slot].recv_buffer)[
                    tail_start:
                ]
            )
            if ret == -1:
                _send_error_to_fd(fd_val, BadRequest())
                _close_slot(handler, backend, st, slot, fd_val)
                return False
            var leftover = st.provision_pool.provisions[
                slot
            ].chunk_decoder.pending_bytes
            # Drop the framing bytes this pass consumed, so
            # the next read appends straight onto the tail.
            st.provision_pool.provisions[slot].recv_buffer.resize(
                tail_start + produced + leftover, 0
            )
            decoded_so_far += produced
            body_st.bytes_read = decoded_so_far
            st.provision_pool.provisions[slot].body_state = body_st
            # Two bounds, because a chunked body has two sizes, each
            # measured after the decode as the head path measures them.
            # The decoded body is what the application sees; the raw
            # stream is what the connection cost. Framing is consumed and
            # dropped as it is decoded, so without the second an attacker
            # could send the body limit in real data and then keep going
            # in chunk-extension bytes, bounded only by the decoder's ratio
            # guard. Measured before the decode, as the decoded body plus
            # the raw tail still buffered, the first counted that tail's
            # framing and the next pipelined request as body: a body at
            # the cap was refused 413 when its framing came after its head
            # and answered when it came with it (review record LF70).
            if (
                decoded_so_far > st.config.max_request_body_size
                or st.provision_pool.provisions[slot].chunk_decoder._total_read
                > 2 * st.config.max_request_body_size
            ):
                _refuse_too_large(handler, backend, st, slot, fd_val)
                return False
            if ret >= 0:
                # Complete. `pending_bytes` bytes past the
                # chunked data stay in the buffer: they are
                # the next pipelined request, and the
                # keep-alive reset preserves them.
                st.provision_pool.provisions[slot].request_end = (
                    raw_body_start + decoded_so_far
                )
                body_st.content_length = decoded_so_far
                body_st.bytes_read = decoded_so_far
                body_st.is_chunked = False
                st.provision_pool.provisions[slot].body_state = body_st
                if st.config.body_read_timeout > 0:
                    backend.try_delete_timer(UInt(fd_val) + TIMER_BODY)
                st.provision_pool.provisions[slot].state = ConnectionState.processing()
                _process_request(handler, backend, st, slot, fd_val)
        # ret == -2 or empty: wait for more data via EVFILT_READ
    elif body_st.bytes_read >= body_st.content_length:
        if st.config.body_read_timeout > 0:
            backend.try_delete_timer(UInt(fd_val) + TIMER_BODY)

        st.provision_pool.provisions[slot].state = ConnectionState.processing()
        _process_request(handler, backend, st, slot, fd_val)

    # One recv per event does not drain an edge-triggered socket: a body
    # larger than the staging buffer leaves bytes pending that will never
    # raise another edge on their own. `_handle_read_headers`' rule, for
    # its reason: re-registered only when this read may have left
    # something no edge will announce -- a read that FILLED the buffer, or
    # a peer that has shut down its side, whose one edge this event spent
    # (re-registering reports the EOF again, and the read of 0 behind it
    # closes an upload that can never finish, where the body timer would
    # otherwise hold it). A shorter read took everything the socket held,
    # and the next byte raises an edge of its own. This re-registered
    # after every read: an `epoll_ctl` ADD, refused EEXIST, and the MOD
    # behind it on each read of an upload still arriving -- R2's pair,
    # per read where the headers' was per request (`poe
    # smoke-large-request` counts both on Linux).
    if (
        st.slot_fds[slot] != UNUSED
        and st.provision_pool.provisions[slot].state.kind
        == ConnectionState.READING_BODY
    ):
        if bytes_read == UInt(want) or st.provision_pool.provisions[slot].peer_eof:
            _rearm_reads(backend, st, slot, fd_val)
        else:
            _ = _arm_reads(backend, st, slot, fd_val)
    return True


def _handle_read_headers[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
):
    """Read and parse HTTP request headers for a connection slot.

    Called both eagerly from the accept path (to handle data already buffered
    before kqueue registration) and from the EVFILT_READ handler.
    """
    var entry_keepalive = st.provision_pool.provisions[slot].keepalive_count
    # 0 means "no request in progress" — the first bytes of a keep-alive
    # request start the clock here rather than inheriting a deadline from
    # whenever the previous response happened to finish.
    if st.slot_header_start[slot] == 0:
        # A request's first bytes: stamp, and nothing to measure yet.
        # (Reading the clock twice here was a fifth of the loop's clock
        # calls.) Whatever the header timeout: the access log and the
        # metrics time the request from here, and with the timeout off the
        # log subtracted a stamp never taken, so every keep-alive request
        # after a connection's first (the accept stamps that one) logged
        # the time since boot (review record LF14).
        st.slot_header_start[slot] = perf_counter_ns()
    elif st.config.header_read_timeout > 0:
        var elapsed_s = (perf_counter_ns() - st.slot_header_start[slot]) / 1_000_000_000
        if elapsed_s >= Int(st.config.header_read_timeout):
            _send_error_to_fd(fd_val, RequestTimeout())
            _close_slot(handler, backend, st, slot, fd_val)
            return

    # Phase 2a: recv straight into the connection's buffer, past whatever
    # it already holds. Still exactly ONE read of `recv_staging.capacity()`
    # bytes per call -- the 8 KB header rule at the bottom of this function
    # depends on that size -- but the staging copy that used to follow it
    # is gone: `List.extend` was 2.7 % of the loop thread and this was its
    # largest caller. The body and WebSocket paths keep the staging buffer.
    var fd_desc = FileDescriptor(fd_val)
    var bytes_read: UInt
    # True only when recv itself RETURNED 0 — the peer's EOF. `bytes_read`
    # alone cannot carry that: the EAGAIN branch below reuses 0 as its
    # "no new data, parse what is buffered" sentinel, and reading THAT as
    # EOF closed every request that was partial at an EAGAIN pass — a
    # dribbled request died on its second byte.
    var recv_eof = False
    var have = len(st.provision_pool.provisions[slot].recv_buffer)
    var want = st.provision_pool.provisions[slot].recv_staging.capacity()
    st.provision_pool.provisions[slot].recv_buffer.reserve(have + want)
    try:
        bytes_read = recv(
            fd_desc,
            Span(
                unsafe_ptr=st.provision_pool.provisions[slot].recv_buffer.unsafe_ptr().unsafe_offset(have),
                length=want,
            ),
            0,
        )
        recv_eof = bytes_read == 0
    except recv_err:
        if recv_err.would_block():
            # No new data — check for pipelined data already in recv_buffer.
            if len(st.provision_pool.provisions[slot].recv_buffer) == 0:
                return
            bytes_read = 0
        else:
            _close_slot(handler, backend, st, slot, fd_val)
            return

    if bytes_read == 0 and len(st.provision_pool.provisions[slot].recv_buffer) == 0:
        _close_slot(handler, backend, st, slot, fd_val)
        return

    # A request has begun, read now or pipelined behind the last answer.
    _begin_request(st, slot)

    if recv_eof:
        # recv returning 0 IS the peer's EOF, however the event was
        # flagged. Without this, a preserved pipelined tail holding only a
        # PARTIAL request would re-arm and re-poll a socket that can never
        # complete it — on kqueue a level-triggered event storm until the
        # header timeout — instead of closing at the peer_eof check below.
        st.provision_pool.provisions[slot].peer_eof = True

    if bytes_read > 0:
        st.provision_pool.provisions[slot].recv_buffer._len = have + Int(bytes_read)

    if len(st.provision_pool.provisions[slot].recv_buffer) > st.config.recv_buffer_limit():
        _send_error_to_fd(fd_val, BadRequest())
        _close_slot(handler, backend, st, slot, fd_val)
        return

    # The framing decision is `frame_request_head`'s alone: where the head
    # ends, whether the parser agrees, how the body is framed, and where the
    # request ends when the head says. This acts on it, and frames nothing
    # itself (SPEC B29). A framed request's parsed head lands in the slot.
    var framing = frame_request_head(
        Span(st.provision_pool.provisions[slot].recv_buffer),
        st.provision_pool.provisions[slot].last_parse_len,
        st.config.max_total_header_size,
        st.config.max_request_uri_length,
        st.config.max_request_body_size,
        st.provision_pool.provisions[slot].parsed_headers,
    )

    if framing.outcome == FRAME_REFUSED:
        # A body over the cap is answered while it may still be arriving
        # (`_refuse_too_large`); every other refusal closes at once, and
        # says so on the wire (`_send_error_to_fd`).
        if framing.rule == REFUSED_BODY_TOO_LARGE:
            _refuse_too_large(handler, backend, st, slot, fd_val)
        else:
            _send_error_to_fd(fd_val, _refusal(framing.rule))
            _close_slot(handler, backend, st, slot, fd_val)
        return

    if framing.outcome == FRAME_REQUEST:
        var header_end_offset = framing.head_end
        var content_length = framing.content_length
        var is_chunked = framing.body == BODY_CHUNKED

        var body_bytes_in_buffer = len(st.provision_pool.provisions[slot].recv_buffer) - header_end_offset

        if framing.body != BODY_NONE:
            # RFC 9110 §10.1.1, and two rules an exact `== "100-continue"`
            # got wrong. The expectation-name is CASE-INSENSITIVE, so a
            # client sending `100-Continue` -- the capitalisation most
            # documentation uses -- was answered with silence and waited out
            # its own timeout before sending the body anyway. And a server
            # MUST NOT send 100 (Continue) to an HTTP/1.0 client: 1.0 has no
            # 1xx, so that client reads the interim response as THE response
            # and the real one behind it as garbage.
            if st.provision_pool.provisions[slot].parsed_headers.value().headers.value_equals_ignore_case(
                HeaderKey.EXPECT, "100-continue"
            ):
                if st.provision_pool.provisions[slot].parsed_headers.value().protocol != strHttp10:
                    _send_raw_to_fd(fd_val, "HTTP/1.1 100 Continue\r\n\r\n".as_bytes())

            var effective_length = st.config.max_request_body_size if is_chunked else content_length
            # For a chunked body `bytes_read` counts DECODED bytes, and
            # nothing has been decoded yet — the buffered bytes below are
            # still raw. Seeding it with the raw count instead made the
            # resumed decode start past bytes it had never consumed, and the
            # chunk framing in the gap was read as body: a 300 KB upload in
            # 64-byte chunks arrived 12 bytes long, carrying two chunks'
            # `40\r\n...\r\n` inside it.
            st.provision_pool.provisions[slot].body_state = BodyReadState(
                content_length=effective_length,
                bytes_read=0 if is_chunked else body_bytes_in_buffer,
                header_end_offset=header_end_offset,
                is_chunked=is_chunked,
            )
            # Where this request will end in recv_buffer — knowable now for
            # Content-Length, only at completion for chunked (0 until then).
            # Bytes past it are the next pipelined request; see
            # `ConnectionProvision.request_end`.
            st.provision_pool.provisions[slot].request_end = framing.request_end
            st.provision_pool.provisions[slot].state = ConnectionState.reading_body()

            # Phase 1b: decode whatever of the body arrived with the headers,
            # through the CONNECTION's decoder — the same one
            # `_read_body` resumes. A throwaway decoder here would
            # consume these bytes and then throw away the chunk state it
            # built, leaving the resumed decode to start mid-chunk.
            if is_chunked and body_bytes_in_buffer > 0:
                var ret: Int
                var decoded_size: Int
                ret, decoded_size = st.provision_pool.provisions[
                    slot
                ].chunk_decoder.decode(
                    Span(st.provision_pool.provisions[slot].recv_buffer)[
                        header_end_offset:
                    ]
                )
                if ret == -1:
                    _send_error_to_fd(fd_val, BadRequest())
                    _close_slot(handler, backend, st, slot, fd_val)
                    return
                var leftover = st.provision_pool.provisions[
                    slot
                ].chunk_decoder.pending_bytes
                st.provision_pool.provisions[slot].recv_buffer.resize(
                    header_end_offset + decoded_size + leftover, 0
                )
                var body_st0 = st.provision_pool.provisions[slot].body_state.value()
                body_st0.bytes_read = decoded_size
                st.provision_pool.provisions[slot].body_state = body_st0
                # Both body bounds. This path had NEITHER: a chunked body
                # that arrives with its headers is decoded and dispatched
                # right here, so `_read_body` -- which is where both
                # limits lived -- never runs for it. Sending head and
                # body in one write was therefore enough to escape the
                # decoded cap and the raw ceiling together, and whether a
                # request was bounded came down to how the client's writes
                # happened to be coalesced.
                if (
                    decoded_size > st.config.max_request_body_size
                    or st.provision_pool.provisions[slot].chunk_decoder._total_read
                    > 2 * st.config.max_request_body_size
                ):
                    _refuse_too_large(handler, backend, st, slot, fd_val)
                    return
                if ret >= 0:
                    # `pending_bytes` bytes remain past the chunked data —
                    # the next pipelined request. The resize above already
                    # kept exactly them; the resize that used to discard
                    # them here is why a request behind a chunked body was
                    # lost.
                    st.provision_pool.provisions[slot].request_end = (
                        header_end_offset + decoded_size
                    )
                    var body_st = st.provision_pool.provisions[slot].body_state.value()
                    body_st.content_length = decoded_size
                    body_st.bytes_read = decoded_size
                    body_st.is_chunked = False
                    st.provision_pool.provisions[slot].body_state = body_st
                    st.provision_pool.provisions[slot].state = ConnectionState.processing()
                    _process_request(handler, backend, st, slot, fd_val)
                    return
                # ret == -2: incomplete, wait for EVFILT_READ to fire again
            elif not is_chunked and body_bytes_in_buffer >= content_length:
                st.provision_pool.provisions[slot].state = ConnectionState.processing()
                _process_request(handler, backend, st, slot, fd_val)

            # The body timer, for a body still OWED. It was armed above the
            # decode, so a body that arrived whole with its headers --
            # completed just above, where nothing deleted it -- left it
            # running, and `body_read_timeout` later it closed the
            # connection, whatever it was doing by then (B1; the timer
            # handler's guard is the other half). Armed here instead, once
            # what came with the headers has been taken: `_process_request`
            # never leaves the slot READING_BODY, so the state says whether a
            # body is still owed, and a small POST costs no timer at all.
            # `_read_body` deletes it at the end of a body that arrives
            # later.
            if (
                st.config.body_read_timeout > 0
                and st.slot_fds[slot] != UNUSED
                and st.provision_pool.provisions[slot].state.kind
                == ConnectionState.READING_BODY
            ):
                backend.try_add_timer(
                    UInt(fd_val) + TIMER_BODY, st.config.body_read_timeout * 1000
                )
        else:
            st.provision_pool.provisions[slot].request_end = framing.request_end
            st.provision_pool.provisions[slot].state = ConnectionState.processing()
            _process_request(handler, backend, st, slot, fd_val)

    # Headers that can never arrive: the peer half-closed while the request
    # was still incomplete, so waiting for the rest only holds the slot
    # until the header timeout answers 408. Release it now instead. (A
    # partial BODY already closes promptly, on the `bytes_read == 0` path.)
    #
    # Before the re-arm below, and returning: a connection whose peer has
    # gone will never produce the readiness that re-arming asks for.
    #
    # Only once this read has taken everything before the FIN: a read of
    # nothing, or a shorter one. `peer_eof` from the event says the FIN has
    # arrived, not that one read took what was ahead of it, and a read that
    # filled its buffer closed a head longer than one read with the rest of
    # it still in the socket, the request unanswered (review record LF42).
    # Such a read is re-armed below, and the next one goes on.
    if (
        st.slot_fds[slot] != UNUSED
        and st.provision_pool.provisions[slot].peer_eof
        and (recv_eof or bytes_read < UInt(want))
        and st.provision_pool.provisions[slot].state.kind
        == ConnectionState.READING_HEADERS
    ):
        _close_slot(handler, backend, st, slot, fd_val)
        return

    # Still short of a complete request: register read interest for the rest.
    #
    # Nothing else does. The accept path arms EVFILT_READ only while the
    # state is still READING_HEADERS, so a request whose headers completed
    # in the eager read but whose body did not would sit unarmed until the
    # body timer answered 408. After a full read the re-registration is
    # unconditional rather than guarded on `slot_read_armed`, because epoll
    # is edge-triggered: the tail of the body is frequently already in the
    # socket buffer, the edge that carried it is spent, and only a fresh
    # EPOLL_CTL_MOD regenerates readiness for bytes that are pending but
    # unread.
    #
    # HEADERS need it for the identical reason, and used not to have it.
    # This function performs exactly ONE `recv` of `recv_staging.capacity()`
    # (4096) per call, so a request whose headers exceed what the eager read
    # plus one edge could take -- 8192 bytes, measured exactly -- left the
    # remainder sitting unread in the socket buffer with no edge left to
    # announce it. On epoll that request stalled until the header timeout
    # answered 408, ten seconds after the client had finished sending it;
    # on kqueue nothing happened at all, because `add_read` there is
    # `EV_ADD` without `EV_CLEAR` and so LEVEL triggered, and the next
    # `kevent` reported the socket readable again. 8 KB of request headers
    # is a large cookie jar or a JWT, not an attack.
    #
    # Re-registered only when this read may have left something that no
    # edge will announce: a read that FILLED the buffer (more may wait
    # behind it), or the peer's EOF (whose one edge this event spent). A
    # shorter read took everything the socket held, so the next byte raises
    # an edge of its own, and a slot whose interest stands needs no syscall
    # at all -- `_arm_reads` adds it only if a write wait took it. Doing it
    # after every read put an `epoll_ctl` ADD, refused EEXIST, and the MOD
    # behind it on every keep-alive request: 4004 calls for 2000 requests,
    # the pair 9a6651f had measured out of the hot path (review record R2;
    # `poe smoke-large-request` counts them on Linux).
    if st.slot_fds[slot] != UNUSED and (
        st.provision_pool.provisions[slot].state.kind == ConnectionState.READING_BODY
        or st.provision_pool.provisions[slot].state.kind
        == ConnectionState.READING_HEADERS
    ):
        if bytes_read == UInt(want) or recv_eof:
            _rearm_reads(backend, st, slot, fd_val)
        else:
            _ = _arm_reads(backend, st, slot, fd_val)

    # After an inline-completed request the keep-alive reset zeroed
    # `last_parse_len` for the PRESERVED pipelined tail; stamping the buffer
    # length over it would start the next terminator search past headers it
    # has never scanned.
    if st.provision_pool.provisions[slot].keepalive_count == entry_keepalive:
        st.provision_pool.provisions[slot].last_parse_len = len(st.provision_pool.provisions[slot].recv_buffer)


@always_inline
def _drain_pipelined[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
):
    """Answer requests already sitting whole in `recv_buffer`.

    Bytes past an answered request were read off the socket with it, so no
    readiness event will ever announce them again — the edge that carried
    them is spent on epoll, and the socket buffer kqueue's level trigger
    watches no longer holds them. After a response completes, whatever the
    keep-alive reset preserved is parsed here, one request per iteration,
    until the buffer holds no complete request or the slot has closed,
    started streaming, gone to a pool thread, or still owes response bytes.

    Iterative on purpose: recursing through the handler chain would nest
    one whole call stack per pipelined request, and a single 4 KB read of
    tiny requests is hundreds of them.

    Not otherwise bounded, also on purpose — the send buffer is the real
    bound. An iteration whose response cannot go out whole leaves the slot
    RESPONDING and the loop exits, so a client that pipelines more than the
    kernel will buffer back stops costing this loop anything until it
    drains its side.
    """
    while (
        st.slot_fds[slot] != UNUSED
        and st.provision_pool.provisions[slot].state.kind
        == ConnectionState.READING_HEADERS
        and len(st.provision_pool.provisions[slot].recv_buffer) > 0
        and not st.offload.offloaded[slot]
    ):
        var before = st.provision_pool.provisions[slot].keepalive_count
        _handle_read_headers(handler, backend, st, slot, fd_val)
        if (
            st.slot_fds[slot] == UNUSED
            or st.provision_pool.provisions[slot].keepalive_count == before
        ):
            break


def _process_request[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
):
    """Build request, call handler, encode response, register for write."""
    var parsed = st.provision_pool.provisions[slot].parsed_headers.take()
    # Asked of the head before `from_parsed` consumes it: the request it
    # builds no longer carries the `chunked` it de-chunked.
    var faulty_framing = parsed.faulty_framing()

    var body = Bytes()
    if st.provision_pool.provisions[slot].body_state:
        var body_st = st.provision_pool.provisions[slot].body_state.value()
        var body_start = body_st.header_end_offset
        var body_end = body_start + body_st.content_length
        if body_end <= len(st.provision_pool.provisions[slot].recv_buffer):
            body = Bytes(capacity=body_st.content_length)
            unsafe_memcpy(
                dest=body.unsafe_ptr(),
                src=st.provision_pool.provisions[slot].recv_buffer.unsafe_ptr().unsafe_offset(body_start),
                count=body_st.content_length,
            )
            body._len = body_st.content_length

    var request: HTTPRequest
    try:
        request = HTTPRequest.from_parsed(
            st.server_host,
            st.server_port,
            parsed^,
            body^,
            st.config.max_request_uri_length,
        )
    except from_parsed_err:
        _send_error_to_fd(fd_val, BadRequest())
        _close_slot(handler, backend, st, slot, fd_val)
        return

    request.slot_id = slot
    request.remote_addr = st.provision_pool.provisions[slot].peer_host
    request.remote_port = st.provision_pool.provisions[slot].peer_port
    st.provision_pool.provisions[slot].should_close = (
        (not st.tcp_keep_alive) or faulty_framing or request.connection_close()
    )
    var request_method = request.method
    var request_path = request.uri.path

    # Recorded before the handler runs, because under `--blocking-threads` the
    # request itself is about to belong to another thread and neither of these
    # can be read back at completion time.
    st.offload.is_head[slot] = request_method == "HEAD"
    st.offload.http11[slot] = request.protocol == strHttp11
    if st.config.access_log:
        st.provision_pool.provisions[slot].log_method = request_method
        st.provision_pool.provisions[slot].log_path = request_path

    var response: HTTPResponse

    # Phase 4e: intercept /__metrics before user handler
    if st.config.enable_metrics and request_path == "/__metrics":
        st.metrics.active_connections = st.active_count
        st.metrics.pool_available = st.provision_pool.available_count()
        var body = st.metrics.to_text()
        response = HTTPResponse(
            body.as_bytes(),
            status_code=200,
            status_text="OK",
        )
        response.headers["Content-Type"] = "text/plain; version=0.0.4; charset=utf-8"
        # `should_close` stays as the request set it above. This branch
        # reset it to False, so a scrape asking `Connection: close`, or an
        # HTTP/1.0 chunked POST whose framing closes the connection (SPEC
        # B15), was kept alive here alone. A scrape that asks nothing is
        # still kept, which a scraper holding one connection relies on.
    else:
        # The before hook first, ON THE LOOP, in every mode. A handler that
        # answers here never becomes a job: m0serve's answers its static
        # mounts and its health path this way, so a stylesheet stays
        # readable whatever the pool is busy with, and the health path
        # reports the registries THIS loop drains rather than a pool
        # thread's own — which are always empty, and under `--realtime
        # --blocking-threads` said "0 subscribers" while events were being
        # delivered. Before the offload rather than after it, because after
        # it the hook only ever ran on the queue-full fallback.
        var early = handler.before_request(request)
        if not early:
            # `--blocking-threads`: hand the request to a pool thread and go
            # back to `wait()`. The slot stays in PROCESSING across loop
            # passes — the idle and header sweeps skip it, the read path
            # refuses to touch it, and `_finish_response` resumes here when
            # the completion arrives. This is the whole point of the mode:
            # no other connection on this loop waits for this handler.
            if st.offload.accepting():
                ref pool = st.offload.pool()[]
                # The path decides the lane, and the loop never learns what
                # a lane means: with `--mount` each application's worker
                # owns one, so a job reaches the worker that can serve it
                # rather than whichever reads the datagram first. Unmounted
                # there is one lane and this is the call it always was.
                var target = request.uri.path
                var lane = pool.lane_for(target)
                pool.park_request(slot, request^)
                if pool.lane_is_executor(lane):
                    # An executor lane: the submit is BUFFERED and sent
                    # with the rest of this pass's at the bottom of it, one
                    # datagram, so the executor wakes once per pass rather
                    # than at the first of N sends. The slot is offloaded
                    # from here exactly as if the datagram were already
                    # gone — every sweep leaves it alone — and
                    # `_flush_submits` runs before the loop ever parks.
                    pool.stamp_lane(slot, lane)
                    st.offload.offloaded[slot] = True
                    st.offload.inflight += 1
                    # The inversion's submit seam: a handler running as the
                    # executor's own loop takes the parked request here, on
                    # this thread, and no datagram is sent. Every other handler
                    # declines (the trait's default) and gets the batch below.
                    if handler.direct_job(slot):
                        return
                    if st.offload.queue_submit(slot, lane):
                        # The lane's batch is full: send it now, and run
                        # inline whatever it could not carry — the same
                        # answer a refused `submit` always had. This path
                        # is non-raising like the rest of the read side; a
                        # raise inside the inline run is a handler that
                        # already answered 500 and closed, so it is logged
                        # rather than propagated.
                        try:
                            _ = _run_inline(
                                handler, backend, st, st.offload.flush_lane(lane)
                            )
                        except e:
                            print("event loop: inline run raised: " + String(e), flush=True)
                    return
                if pool.submit(slot, target):
                    # The slot is working, not idle: the sweeps skip it
                    # while `offloaded` holds, and no deadline from the
                    # PREVIOUS request survives to meet it when the job
                    # comes back -- `_begin_request` cleared that one when
                    # this request's first bytes arrived.
                    st.offload.offloaded[slot] = True
                    st.offload.inflight += 1
                    return
                # Queue full: take the request back and run it here.
                # Degrading to the loop is exactly the behaviour of a server
                # without the flag, and it never drops a request.
                request = pool.unpark_request(slot)

        if early:
            var early_resp = early.take()
            response = early_resp^
        else:
            try:
                response = handler.func(request^)
            except:
                response = InternalError()
                st.provision_pool.provisions[slot].should_close = True

        # After hook: add headers, log, etc.
        handler.after_response(request_method, request_path, response)

    _finish_response(handler, backend, st, slot, fd_val, response^)


def _refusal(rule: Int) -> HTTPResponse:
    """The answer to a head `frame_request_head` refused, by its rule.

    Every rule it refuses by is named here but the body's, which is
    answered while the body may still be arriving (`_refuse_too_large`).
    A rule this does not know is a 500 and a line on stdout, never a
    silent 400: a refusal added to the framer is answered as it means only
    once it is added here too.
    """
    if (
        rule == REFUSED_BARE_LF
        or rule == REFUSED_MALFORMED
        or rule == REFUSED_FRAMERS_DISAGREE
    ):
        return BadRequest()
    if rule == REFUSED_HEAD_TOO_LARGE:
        return HeadersTooLarge()
    if rule == REFUSED_URI_TOO_LONG:
        return URITooLong()
    if rule == REFUSED_NOT_IMPLEMENTED:
        return NotImplemented()
    print("event loop: a request head refused by a rule with no answer:", rule, flush=True)
    return InternalError()


def _refuse_too_large[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
):
    """The 413 for a body over `max_request_body_size`, decoded or raw.

    Every size refusal goes through here, so the config's notice is said
    on the first of them whichever check made it (`_notice_once`).
    """
    _notice_once(st.config.body_size_notice)
    _reject_and_linger(handler, backend, st, slot, fd_val, PayloadTooLarge())


def _reject_and_linger[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
    var response: HTTPResponse,
):
    """Refuse a request whose body is still arriving, then linger.

    A 413 goes out as soon as the size is known -- at the headers for a
    `Content-Length`, partway through for a chunked body -- so the client
    is still uploading, and most clients read nothing until they have
    written everything (`http.client`, so `urllib` and `requests`).
    Closing then, with the rest of the body unread in the receive buffer,
    makes the kernel send RST instead of FIN: the client's next write
    fails with EPIPE, and the 413 already in its receive buffer is
    discarded with the connection. m0serve answered `http.client` with a
    `BrokenPipeError` where Werkzeug answered 413.

    RFC 9112 §9.6 is the cure, and nginx's lingering close is the shape:
    half-close the write side behind the response, read and discard until
    the client closes, then close -- a FIN, and the 413 intact. The slot
    becomes LINGERING and `_linger_discard` does the reading. The bound is
    REJECT_LINGER_NS from here, armed ONCE because this is the transition
    (nothing re-enters it: the read path's LINGERING branch is all a
    lingering slot ever reaches), and the idle sweep reaps it -- a client
    that never stops is reset at the deadline, which is what it got at
    once before. Gated on `idle_timeout > 0` for the reason the WebSocket
    close linger is: that sweep is what bounds the wait, and with idle
    timeouts off the old immediate close is better than a held slot.
    """
    _send_error_to_fd(fd_val, response^)
    var linger = st.config.idle_timeout > 0
    if linger:
        try:
            shutdown(FileDescriptor(fd_val), ShutdownOption.SHUT_WR)
        except:
            linger = False
    if not linger:
        _close_slot(handler, backend, st, slot, fd_val)
        return
    # A chunked body was being read under the body timer, which would
    # otherwise fire mid-linger and close the slot early.
    backend.try_delete_timer(UInt(fd_val) + TIMER_BODY)
    st.provision_pool.provisions[slot].prepare_for_new_request()
    st.provision_pool.provisions[slot].state = ConnectionState.lingering()
    st.slot_idle_deadline[slot] = perf_counter_ns() + REJECT_LINGER_NS
    _ = _arm_reads(backend, st, slot, fd_val)
    # Discard what is already buffered now: on epoll the edge that brought
    # it is spent, and a client blocked on a full window sends nothing
    # that would raise another. Belt and braces, deliberately: the SHUT_WR
    # above is a state change, which wakes epoll and reports the buffered
    # bytes again (measured), and kqueue's level trigger reports them
    # anyway -- removing this changes nothing the probe can see on either.
    # It stays so the linger does not rest on a side effect of shutdown.
    _linger_discard(handler, backend, st, slot, fd_val)


def _linger_discard[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
):
    """Read and discard what a LINGERING client sends; close at its EOF.

    Reads until EAGAIN rather than stopping at a short read, because the
    client's FIN may already be behind the data, and on epoll the event
    that announced both is this one. At most LINGER_READS_PER_EVENT reads:
    past that the socket is re-registered, which on epoll reports it again
    if it is still readable (kqueue's level trigger does so anyway) -- the
    WebSocket read path's rule, for its reason: once the client stops
    sending, nothing else will. Not reproducible on demand here (Linux
    starts a loopback receive buffer below the budget, and a client still
    sending raises an edge per segment), so no gate fails without it.
    """
    for _ in range(LINGER_READS_PER_EVENT):
        st.provision_pool.provisions[slot].recv_staging.clear()
        var n: UInt
        try:
            n = recv(
                FileDescriptor(fd_val),
                spare_capacity(st.provision_pool.provisions[slot].recv_staging),
                0,
            )
        except linger_err:
            if linger_err.would_block():
                return
            n = 0
        if n == 0:
            _close_slot(handler, backend, st, slot, fd_val)
            return
    _rearm_reads(backend, st, slot, fd_val)
