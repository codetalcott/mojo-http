"""A response onto the wire, and what its slot does once it has landed.

`_finish_response` is the one implementation of the wire rules, for every
response however it arrived: from the handler on this thread, or from a
pool thread passes later. `_on_write` sends what the first send left, and
a file body after its head (`_pump_body_fd`); `_after_send` then records
the response and closes, lingers, goes back to streaming or waits for the
next request. `_send_error_to_fd` is the best-effort answer before a close.
"""

from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.c.socket import MSG_PEEK, recv, send, close, set_tcp_keepalive
from lightbug_http.connection import ConnectionState
from lightbug_http.header import HeaderKey, KH_DATE
from lightbug_http.http import (
    HTTPResponse, encode, enforce_bodiless_framing, is_bodiless_status,
)
from lightbug_http.http.date import http_date_from_unix, unix_now
from lightbug_http.c.sendfile import send_file
from lightbug_http.io.bytes import Bytes
from lightbug_http.server import ConnectionProvision
from lightbug_http.service import HTTPService
from lightbug_http.websocket import is_ws_upgrade_response

from lightbug_http.loop.state import (
    LoopState, STREAM_KEEPALIVE_PROBES, UNUSED, _arm_send_deadline,
    _await_write, _close_slot, _end_request, _keep_stream_close,
    _record_response, _stream_idle, _ws_linger,
)
from lightbug_http.loop.request import _drain_pipelined


def _on_write[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, fd_val: Int,
):
    """A connection socket is writable: send more of the response it owes
    -- the head, then a file body -- and once it has landed, finish it and
    answer what is pipelined behind."""
    if fd_val >= len(st.fd_to_slot):
        return
    var slot = st.fd_to_slot[fd_val]
    if slot == UNUSED:
        return

    if st.provision_pool.provisions[slot].state.kind != ConnectionState.RESPONDING:
        return

    if st.offload.offloaded[slot]:
        return

    var remaining = len(st.slot_response[slot]) - st.slot_send_offset[slot]
    # Whether this readiness moved any bytes, head or file: the
    # send deadline restarts on progress (`_arm_send_deadline`).
    var moved = False
    if remaining > 0:
        var fd_desc = FileDescriptor(fd_val)
        var sent: UInt
        try:
            sent = send(
                fd_desc,
                Span(st.slot_response[slot])[st.slot_send_offset[slot]:],
                0,
            )
        except send_err:
            if send_err.would_block():
                _ = _await_write(backend, st, slot, fd_val)
                return
            _close_slot(handler, backend, st, slot, fd_val)
            return

        st.slot_send_offset[slot] += Int(sent)
        moved = sent > 0

        if st.slot_send_offset[slot] < len(st.slot_response[slot]):
            # Bytes moved and more are owed: the send deadline starts
            # again (`_arm_send_deadline`). Only one already armed, so a
            # stream's zero deadline stays zero.
            if moved and st.slot_idle_deadline[slot] != 0:
                _arm_send_deadline(st, slot)
            if not _await_write(backend, st, slot, fd_val):
                _close_slot(handler, backend, st, slot, fd_val)
            return

        # The partial-send completion of a streaming buffer: ack
        # the PAYLOAD the drain recorded for it (the drain pass
        # acked nothing, having sent only part). Not the buffer
        # length — chunk framing makes those differ, and the
        # window must count what the application produced. The
        # stream head lands here too, with 0 owed.
        if st.offload.ack_payload[slot] > 0 and st.offload.slot_channel_stream(slot):
            if not st.offload.pool()[].ack_stream(slot, st.offload.ack_payload[slot]):
                if st.offload.ack_owed[slot] == 0:
                    st.offload.ack_owed_count += 1
                st.offload.ack_owed[slot] += st.offload.ack_payload[slot]
        st.offload.ack_payload[slot] = 0

    # The head is on the wire, drained just now or by an earlier
    # readiness: a file body, if one is owed, follows it -- the
    # ordering `_finish_response` keeps between the two transfers.
    # A head that needed this path used to go straight to
    # `_after_send`, which reset the slot for its next request with
    # the file unsent: the client read a `Content-Length` promise
    # and then the next response's head where the body belonged.
    # It needs a send buffer full at the head, which a pipelined
    # predecessor or a slow reader of `--static` files provides.
    var file_owed = st.provision_pool.provisions[slot].body_fd_remaining
    var pumped = _pump_body_fd(
        st.provision_pool.provisions[slot], fd_val
    )
    if pumped == BODY_FD_FATAL:
        _close_slot(handler, backend, st, slot, fd_val)
        return
    if pumped == BODY_FD_MORE:
        # The response moved: the client is still taking it, so its
        # send deadline starts again (`_arm_send_deadline`).
        if st.slot_idle_deadline[slot] != 0 and (
            moved
            or st.provision_pool.provisions[slot].body_fd_remaining
            < file_owed
        ):
            _arm_send_deadline(st, slot)
        if not _await_write(backend, st, slot, fd_val):
            _close_slot(handler, backend, st, slot, fd_val)
        return
    _after_send(handler, backend, st, slot, fd_val)
    _drain_pipelined(handler, backend, st, slot, fd_val)


comptime BODY_FD_DONE = 1
comptime BODY_FD_MORE = 0
comptime BODY_FD_FATAL = -1


def _pump_body_fd(mut provision: ConnectionProvision, fd_val: Int) -> Int:
    """Push the pending file body at the socket until it stops taking it.

    Returns `BODY_FD_DONE` when nothing is owed (including the common case
    of no file at all), `BODY_FD_MORE` when the socket filled up and the
    caller must wait for writability, and `BODY_FD_FATAL` when the
    transfer cannot continue.

    A fatal error has to close the connection rather than move on: the head
    is already on the wire promising `Content-Length` bytes, so a short body
    is indistinguishable from a truncated response to the client. Closing is
    at least an error it can detect.

    Loops rather than sending once per readiness event, because a large
    file would otherwise cost one event loop pass per socket buffer.
    """
    if provision.body_fd < 0 or provision.body_fd_remaining <= 0:
        provision.close_body_fd()
        return BODY_FD_DONE

    while provision.body_fd_remaining > 0:
        var r = send_file(
            fd_val,
            provision.body_fd,
            provision.body_fd_offset,
            provision.body_fd_remaining,
        )
        # `sent` is meaningful even alongside `again` — Darwin reports a
        # short write as EAGAIN WITH a count — so advance before branching
        # or those bytes are sent twice.
        provision.body_fd_offset += r.sent
        provision.body_fd_remaining -= r.sent
        if r.failed():
            provision.close_body_fd()
            return BODY_FD_FATAL
        if provision.body_fd_remaining <= 0:
            break
        if r.again:
            return BODY_FD_MORE
        if r.sent == 0:
            # Neither progress nor a reason, which `send_file` no longer
            # answers for a count above 0: end of file is `failed()`
            # (review record LF16). Fatal, like that answer: waiting for
            # writability on it is what spun a slot whose file had been
            # truncated, and a `send_file` that gave it again would spin
            # one again. Here so no answer keeps this loop calling it.
            provision.close_body_fd()
            return BODY_FD_FATAL

    provision.close_body_fd()
    return BODY_FD_DONE


def _keep_stream_alive(st: LoopState, fd_val: Int):
    """Turn TCP keepalive on for a connection that is becoming a stream.

    A stream has no deadline (DECISIONS D57), so nothing of the loop's
    looks at an idle one, and a client that vanished without a FIN holds
    its slot until something sent to it goes unanswered. The heartbeat is
    that something for a stream the loop writes; a stream the application
    writes through the chunk channel gets none, and no stream does with
    the heartbeat off. The kernel's probe covers both and puts no byte in
    the stream. A live client answers it from its kernel, so a reader that
    is merely slow, or idle, keeps its slot.

    A failure is not the stream's: the option is advice to the kernel, and
    a socket it cannot be set on is one the next send will report.
    """
    if st.stream_keepalive_s <= 0:
        return
    try:
        set_tcp_keepalive(
            FileDescriptor(fd_val), st.stream_keepalive_s,
            st.stream_keepalive_s, STREAM_KEEPALIVE_PROBES,
        )
    except e:
        pass


def _answers_the_last_request(mut st: LoopState, slot: Int, fd_val: Int) -> Bool:
    """Whether the request being answered is the last one its client will
    send: the client has half-closed (`peer_eof`), and nothing it sent is
    left behind this request.

    A request pipelined behind it keeps the connection, so the rest is
    still answered; the keep-alive reset keeps `peer_eof`, and this says
    so for the last one. And `peer_eof` says the FIN has arrived, not that
    every byte ahead of it has been read: a read that filled its buffer can
    stop exactly where this request ends, with the next one still in the
    socket, and closing then drops that one and resets the connection over
    the answer. Behind a FIN a read does not block, so a look settles it --
    nothing is the end, and anything else is the next request. A look, not
    a read (`MSG_PEEK`): what it finds stays in the socket for the next
    read event, which the drain registers for, so an answer takes nothing
    off the socket and a pass answers no more than its one read brought
    (review record LF72). Only a half-closed connection's request that ends
    its buffer pays for it.
    """
    if not st.provision_pool.provisions[slot].peer_eof:
        return False
    var have = len(st.provision_pool.provisions[slot].recv_buffer)
    if st.provision_pool.provisions[slot].request_end < have:
        return False
    st.provision_pool.provisions[slot].recv_buffer.reserve(have + 1)
    var n: UInt
    try:
        n = recv(
            FileDescriptor(fd_val),
            Span(
                unsafe_ptr=st.provision_pool.provisions[slot].recv_buffer.unsafe_ptr().unsafe_offset(have),
                length=1,
            ),
            MSG_PEEK,
        )
    except:
        # A reset, or a read that would wait, which a FIN rules out: no
        # further request will be read either way.
        return True
    return n == 0


def _finish_response[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
    var response: HTTPResponse,
):
    """Turn a finished response into bytes on the wire.

    Split out of `_process_request` so the two ways a response can arrive —
    the handler returning on this thread, or a `--blocking-threads` pool
    thread completing a job several loop passes later — converge on ONE
    implementation of the wire rules (stream flags, upgrade, keep-alive cap,
    HEAD, Date, encode, eager send). Every response the server has ever sent
    went through this code; the pool path did not get a second copy of it.
    """
    # A 101 with Upgrade: websocket switches this connection to frame mode
    # once the handshake response is on the wire (see _after_send).
    var upgraded_ws = is_ws_upgrade_response(response)

    # A client that has half-closed is answered with a close once its last
    # request is (review record LF11). The EOF set `should_close` and the
    # request's own `Connection` replaced it: the answer read `keep-alive`,
    # and on epoll, whose edge for the FIN was spent, the slot waited for a
    # request no event would announce until the idle sweep, or for good
    # with idle timeouts off. Here rather than where the request is read,
    # because a pool thread's answer comes back through here too, with an
    # EOF that arrived while it ran. Not for a handshake, whose socket
    # reads frames from here on, never a next request; and not for a
    # request closing anyway, whose read would only pull a pipelined
    # request into a buffer about to be dropped.
    if (
        not upgraded_ws
        and not st.provision_pool.provisions[slot].should_close
        and _answers_the_last_request(st, slot, fd_val)
    ):
        st.provision_pool.provisions[slot].should_close = True
    # What the request asked of the connection, before a stream's head
    # clears it below (so the head landing does not close the slot). A
    # chunked stream that ends takes it back (`_chunked_stream_ends`), and
    # the head says it now: a request asking for `Connection: close` had
    # its chunked stream answered `keep-alive` and its connection kept, and
    # so did every request on a server with keep-alive off (LF13).
    var close_after = _keep_stream_close(st, slot)

    # A HEAD's response is its head (RFC 9110 §9.3.2), whatever a handler
    # made of it: a hold approved on a HEAD -- an `M0-Hold` view that answers
    # every method, a native SSE route matched by path alone -- subscribed
    # the slot and wrote every event and heartbeat after the head, where a
    # keep-alive client reads its next response (SPEC L27). The handler has
    # already subscribed the slot; drop that through the hook a stream's
    # close calls, and send the head as an ordinary answer, with no length,
    # because the GET's body is a stream.
    if response.sse_streaming and st.offload.is_head[slot]:
        response.sse_streaming = False
        response.headers.pop("content-length")
        handler.sse_slot_disconnected(slot)

    if response.sse_streaming:
        st.slot_sse[slot] = True
        # The outbox sweep's gate: every site that sets a stream flag
        # raises it, or the sweep skips a stream nothing else drains.
        st.offload.streaming_hint += 1
        st.provision_pool.provisions[slot].should_close = False
        _keep_stream_alive(st, fd_val)

    if upgraded_ws:
        st.slot_ws[slot] = True
        st.offload.streaming_hint += 1
        st.slot_ws_state[slot].reset()
        st.provision_pool.provisions[slot].should_close = False
        _keep_stream_alive(st, fd_val)
        # A 1xx response carries no body: drop the defaulted entity headers.
        response.headers.pop("content-length")
        response.headers.pop("content-type")

    # The cap counts keep-alive REUSE, and a stream or an upgrade is not
    # reuse: it owns the connection until it ends. Both branches above say
    # so by clearing `should_close` -- and `not should_close` is exactly
    # what this guard used to read as "safe to apply the cap", so the two
    # shapes that had just opted out were the two it caught. `_after_send`
    # then closed the slot as soon as the HEAD drained, before the body
    # frames arrived over the chunk channel: measured on the 100th request
    # of a keep-alive connection as a 200 carrying `Content-Length: 124926`
    # and zero bytes, and as a 101 that never sent a frame. The second
    # enforcement site below (`keepalive_count >= max`) needs no such guard:
    # this one closes at `max - 1`, so a live stream never reaches it.
    if (
        (not response.sse_streaming)
        and (not upgraded_ws)
        and (not st.provision_pool.provisions[slot].should_close)
        and (st.config.max_keepalive_requests > 0)
    ):
        if (st.provision_pool.provisions[slot].keepalive_count + 1) >= st.config.max_keepalive_requests:
            st.provision_pool.provisions[slot].should_close = True

    # RFC 9110 §8.6 and §6.4.1, whoever set it: a 1xx or 204 carries no
    # Content-Length, a 304 only one its handler set, and none of the three
    # carries content (SPEC A21). A handler's own length on a 204 is
    # Django's CommonMiddleware on every such response, and its bytes, if
    # written, would begin the connection's next response.
    if is_bodiless_status(response.status_code):
        enforce_bodiless_framing(response)

    # RFC 9110 §9.3.2: HEAD response must not contain a body. The headers
    # stay as they are — including Content-Length, which must describe the
    # body a GET would have returned — so an fd-backed body is dropped by
    # closing the file rather than by rewriting the head.
    if st.offload.is_head[slot]:
        response.body_raw = Bytes()
        if response.body_fd >= 0:
            try:
                close(FileDescriptor(response.body_fd))
            except:
                pass
            response.body_fd = -1
            response.body_fd_len = 0

    if upgraded_ws:
        # The handshake already set "Connection: Upgrade"; a keep-alive or
        # close rewrite here would corrupt the upgrade.
        pass
    elif st.provision_pool.provisions[slot].should_close or close_after:
        response.set_connection_close()
    else:
        response.set_connection_keep_alive()

    var response_status = response.status_code
    st.provision_pool.provisions[slot].response_status = response_status

    # Streaming: the body has no length to declare, so it is framed one of
    # two ways. Chunked (HTTP/1.1) keeps the connection reusable, which is
    # the whole reason to prefer it; close-delimiting is the fallback and
    # was the only option before.
    #
    # The refusals are all cases where a framed body would corrupt the
    # message rather than merely differ: HTTP/1.0 has no chunked encoding,
    # a HEAD response carries no body to frame, and a 101 hands the
    # connection to the WebSocket framing instead. Chunking is limited to
    # ASGI streams — the executor's, which end and therefore benefit —
    # because a `--realtime` SSE stream is refused alongside the executor
    # and never ends on its own anyway.
    # A response head owes the producer nothing: the credit window is
    # seeded when the stream opens, and the head is not payload. Credit a
    # previous stream on this slot was still owed dies with it: the new
    # window is seeded whole, and a late ack would inflate it.
    st.offload.ack_payload[slot] = 0
    if st.offload.ack_owed[slot] > 0:
        st.offload.ack_owed[slot] = 0
        st.offload.ack_owed_count -= 1
    if response.sse_streaming:
        response.headers.pop("content-length")
        var asgi_stream = st.offload.slot_channel_stream(slot)
        # The head names its stream's generation; an abort datagram is
        # checked against this, so one for an earlier stream on a recycled
        # slot cannot close this connection.
        if slot < len(st.offload.stream_gen):
            st.offload.stream_gen[slot] = response.stream_gen
        # RFC 9110 §6.4.1: a 1xx, 204 or 304 carries no body at all, so
        # there is nothing to frame and a `0\r\n\r\n` would itself be a
        # body. An application streaming into one of these is already
        # wrong, but framing it turns "wrong" into "unparseable", and the
        # reader would hang waiting for a terminator on a message the
        # status says is already complete.
        var bodiless = is_bodiless_status(response.status_code)
        var can_chunk = (
            asgi_stream
            and st.offload.http11[slot]
            and not st.offload.is_head[slot]
            and not upgraded_ws
            and not bodiless
        )
        # Written unconditionally: a recycled slot must not inherit the
        # previous connection's framing.
        st.offload.chunked[slot] = can_chunk
        if can_chunk:
            response.headers[HeaderKey.TRANSFER_ENCODING] = "chunked"
    else:
        st.offload.chunked[slot] = False
        # Not a stream: whatever channel-stream state the slot carried is
        # over. Defensive — every ending path clears it too.
        st.offload.clear_stream(slot)

    if upgraded_ws and slot < len(st.offload.stream_gen):
        # A socket's generation, recorded for the same reason a stream's is
        # above: an abort names a slot AND a generation, so one meant for
        # the connection this slot used to hold cannot close the one it
        # holds now. AFTER the clear, not before — a 101 is not an
        # `sse_streaming` response, so it takes the `else` branch, which
        # clears exactly this. Its absence is what made an executor's abort
        # of a socket a silent no-op, and a WebSocket frame the chunk
        # channel would not take therefore a connection that never closed.
        st.offload.stream_gen[slot] = response.stream_gen

    # Stamp the Date header from the loop's per-second cache (encode()
    # would otherwise format a fresh date string for every response).
    if response.headers.known_index(KH_DATE) < 0:
        var now_s = unix_now()
        if now_s != st.date_cache_sec:
            st.date_cache_sec = now_s
            st.date_cache = http_date_from_unix(now_s)
        response.headers.set_known(
            KH_DATE, HeaderKey.DATE.as_bytes(), st.date_cache.as_bytes()
        )

    # Encode into the slot's spare buffer rather than allocating a fresh one.
    # `_end_request` parks the just-sent buffer back here, so one allocation
    # per slot serves the whole connection instead of one per response.
    #
    # The buffer has to leave the provision to be encoded into, and a struct
    # with a field moved out cannot be destroyed — so it goes out by swap,
    # the same idiom `HTTPRequest.from_parsed` and `Headers` use. (An earlier
    # comment here claimed Mojo could not move out of a list-element field at
    # all; it can, verified on the 1.0 toolchain against both this shape and
    # a bare `List[Bytes]` element.)
    # Take the file body off the response BEFORE it is consumed by
    # `encode_into`, which moves out of it. From here the provision owns
    # the descriptor and `close_body_fd` is the only thing that releases
    # it — the response object is gone a line later.
    var file_fd = response.body_fd
    var file_off = response.body_fd_offset
    var file_len = response.body_fd_len
    response.body_fd = -1
    # The body as it goes out, for the access log's `bytes` and the metrics'
    # bytes sent: read here because `encode_into` consumes the response, and
    # the file part never enters `slot_response`. A HEAD's and a bodiless
    # status's bodies were dropped above, so they count none.
    var file_body = file_len if file_fd >= 0 else 0
    st.provision_pool.provisions[slot].response_body_len = (
        len(response.body_raw) + file_body
    )
    st.provision_pool.provisions[slot].response_file_len = file_body

    var scratch = Bytes()
    swap(st.provision_pool.provisions[slot].encoding_buffer, scratch)
    st.slot_response[slot] = response^.encode_into(scratch^)
    st.slot_send_offset[slot] = 0
    st.provision_pool.provisions[slot].close_body_fd()
    if file_fd >= 0:
        st.provision_pool.provisions[slot].body_fd = file_fd
        st.provision_pool.provisions[slot].body_fd_offset = file_off
        st.provision_pool.provisions[slot].body_fd_remaining = file_len

    # The access log's method and path were recorded in `_process_request`,
    # before the request could leave this thread.
    st.provision_pool.provisions[slot].state = ConnectionState.responding()

    var response_len = len(st.slot_response[slot])

    # Eager send: macOS kqueue EVFILT_WRITE is edge-triggered at registration time
    # and won't fire for a socket that was already writable before the filter was
    # added. Attempt an immediate send; fall back to kqueue only on EAGAIN.
    if response_len > 0:
        var fd_desc = FileDescriptor(fd_val)
        try:
            var sent = send(fd_desc, Span(st.slot_response[slot]), 0)
            st.slot_send_offset[slot] = Int(sent)
        except send_err:
            if not send_err.would_block():
                _close_slot(handler, backend, st, slot, fd_val)
                return
            # EAGAIN: fall through to register EVFILT_WRITE

    if st.slot_send_offset[slot] >= response_len:
        # The head has landed. A file body, if any, follows it — the two
        # are separate transfers and this is the ordering between them.
        var pumped = _pump_body_fd(st.provision_pool.provisions[slot], fd_val)
        if pumped == BODY_FD_FATAL:
            _close_slot(handler, backend, st, slot, fd_val)
            return
        if pumped == BODY_FD_DONE:
            _after_send(handler, backend, st, slot, fd_val)
            return
        # else: more of the file is owed — fall through and wait for
        # writability exactly as a partial head send does.

    # Partial send or EAGAIN: register EVFILT_WRITE for the remainder, and
    # start the send deadline; the write-ready path refreshes it as long as
    # the client keeps taking bytes.
    _arm_send_deadline(st, slot)
    if not _await_write(backend, st, slot, fd_val):
        _close_slot(handler, backend, st, slot, fd_val)


def _after_send[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
):
    """The bytes in `slot_response` have landed whole -- a response, or a
    stream's frame: record the response, then close, linger, go back to
    streaming, or ready the connection for its next request."""
    _record_response(st, slot)
    if st.provision_pool.provisions[slot].should_close:
        if st.slot_ws[slot] and st.slot_ws_state[slot].closing:
            # The tail of this side's Close frame has landed. Same linger as
            # the drain's own two close sites: wait for the peer's Close
            # rather than resetting its reply off the wire. `should_close`
            # and `closing` both stay set while the slot lingers, so a later
            # send that completes here reaches this again: the linger arms
            # once (`_arm_ws_linger`).
            _ws_linger(backend, st, slot, fd_val)
            return
        _close_slot(handler, backend, st, slot, fd_val)
        return

    if (st.config.max_keepalive_requests > 0) and (st.provision_pool.provisions[slot].keepalive_count >= st.config.max_keepalive_requests):
        _close_slot(handler, backend, st, slot, fd_val)
        return

    if st.slot_ws[slot] or st.slot_sse[slot]:
        _stream_idle(backend, st, slot, fd_val)
        return

    _end_request(backend, st, slot, fd_val)


def _send_error_to_fd(fd_val: Int, var response: HTTPResponse):
    """Best-effort send an error response on a raw fd.

    Every caller ends the connection after it, so the response says so:
    `Connection: close` (RFC 9112 §9.6, the server's final response on a
    connection). Left to the encoder's default it said `keep-alive`, an
    invitation to send the next request down a socket that is closing.
    """
    response.set_connection_close()
    var encoded = encode(response^)
    try:
        _ = send(
            FileDescriptor(fd_val),
            Span(encoded),
            0,
        )
    except:
        pass


def _send_raw_to_fd(fd_val: Int, data: Span[Byte, _]):
    """Best-effort send raw bytes on a fd."""
    try:
        _ = send(
            FileDescriptor(fd_val),
            data,
            0,
        )
    except:
        pass
