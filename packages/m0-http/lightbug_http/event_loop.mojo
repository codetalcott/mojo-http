"""Non-blocking kqueue event loop for concurrent HTTP connection handling.

Replaces the blocking accept-loop in server.mojo with a single-threaded,
non-blocking event loop using macOS kqueue. Handles multiple concurrent
connections by advancing per-connection state machines on IO readiness.
"""

from lightbug_http.c.kqueue import (
    set_nonblocking,
    set_tcp_nodelay,
    EVFILT_READ, EVFILT_WRITE, EVFILT_TIMER,
    EV_EOF, EV_ERROR,
)
from lightbug_http.broadcast import drain_bus_channel
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.c.socket import accept_with_peer, recv, send, close
from lightbug_http.c.socket_error import (
    AcceptEAGAINError, AcceptECONNABORTEDError, AcceptEINTRError,
    RecvEAGAINError, SendEAGAINError,
)
from lightbug_http.connection import ConnectionState, default_buffer_size
from lightbug_http.header import (
    HeaderKey, ParsedRequestHeaders, find_header_end, parse_request_headers,
)
from lightbug_http.http import HTTPRequest, HTTPResponse, encode
from lightbug_http.http.date import http_date_from_unix, unix_now
from lightbug_http.http.common_response import (
    BadRequest, InternalError, URITooLong, RequestTimeout, HeadersTooLarge, PayloadTooLarge,
)
from lightbug_http.http.chunked import (
    HTTPChunkedDecoder,
    chunked_terminator,
    encode_chunk,
)
from lightbug_http.c.sendfile import send_file
from lightbug_http.strings import strHttp11
from lightbug_http.io.bytes import Bytes
from std.memory import unsafe_memcpy
from lightbug_http.metrics import ServerMetrics
from lightbug_http.offload import OffloadPool, OffloadLoopState
from lightbug_http.server import (
    BodyReadState, ConnectionProvision, ProvisionPool,
)
from lightbug_http.server_config import ServerConfig
from lightbug_http.service import HTTPService
from lightbug_http.utils.owning_list import OwningList
from lightbug_http.websocket import (
    WSState, is_ws_upgrade_response, encode_ws_frame, close_frame,
    WS_OP_PING, WS_CLOSE_GOING_AWAY,
)
from std.time import perf_counter_ns
from std.sys.info import CompilationTarget
from m0_http.log import log_access


# Timer ident offsets to distinguish timeout types from fd-based events.
# fd values are small (typically < 65536), so these offsets avoid collision.
comptime TIMER_HEADER: UInt = 0x100000
comptime TIMER_BODY: UInt = 0x200000
comptime TIMER_IDLE: UInt = 0x300000
comptime TIMER_SSE_HEARTBEAT: UInt = 0x400000
comptime TIMER_APP_TICK: UInt = 0x500000

comptime MAX_EVENTS = 64
comptime UNUSED: Int = -1


def run_event_loop[T: HTTPService, B: EventLoopBackend](
    listen_fd: FileDescriptor,
    mut handler: T,
    mut backend: B,
    config: ServerConfig,
    server_address: String,
    tcp_keep_alive: Bool,
    shutdown_read_fd: Int = -1,
    bus_read_fd: Int = -1,
    offload_addr: Int = 0,
    peer_bus_fd: Int = -1,
) raises:
    """Run the IO-multiplexed event loop.

    `bus_read_fd`, when >= 0, is this worker's `BroadcastBus` channel: SSE
    frames broadcast by other workers arrive here as datagrams, and each is
    handed to the handler through `sse_peer_frame` so it can queue them for
    its own subscribers. The subsequent outbox drain in the same loop pass
    then pushes them to the wire.

    `offload_addr`, when non-zero, is the address of a caller-owned
    `OffloadPool` (`--blocking-threads`): this loop becomes an acceptor that
    parks requests for a pool of handler threads instead of calling
    `HTTPService.func` itself, and is woken by the pool's completion channel
    the same way it is woken by a bus channel. The streaming hooks are NOT
    offloaded and cannot be — `sse_drain_slot`, `sse_slot_disconnected` and
    `ws_message` are called on THIS thread's handler, while `func` would run
    against a pool thread's own handler and its own registries. The caller
    refuses the combination rather than letting the two drift.

    Parameters:
        T: The HTTP service handler type.
        B: The IO multiplexing backend (KqueueBackend on macOS, EpollBackend on Linux).
    """
    set_nonblocking(listen_fd)

    # Phase 2e: fd values must fit in 20 bits so timer idents (0x100000+) never collide.
    debug_assert(
        UInt(listen_fd.value) < TIMER_HEADER,
        "listen fd >= 0x100000: timer ident collision possible",
    )

    backend.add_read_listen(listen_fd.value)

    # Phase 4a: register shutdown pipe read end if provided
    if shutdown_read_fd >= 0:
        backend.try_add_read(shutdown_read_fd)

    # Cross-worker broadcast channel: register this worker's receive end.
    if bus_read_fd >= 0:
        backend.try_add_read(bus_read_fd)
    # A second bus channel, for the one deployment that needs two: the
    # asyncio executor consumes `bus_read_fd` for its ASGI chunk stream,
    # and under M0_WORKERS>1 the cross-worker BroadcastBus still has to
    # reach this loop. Same codec, same drain, same handler entry -- the
    # frames themselves are distinguished by their channel names.
    if peer_bus_fd >= 0:
        backend.try_add_read(peer_bus_fd)

    # `--blocking-threads`: the pool's completion channel, registered exactly
    # as a bus channel is — a readable fd that means "somebody else finished
    # something; go look".
    var offload = OffloadLoopState(offload_addr, config.max_connections)
    var offload_complete_fd = offload.pool()[].complete_read if offload.enabled() else -1
    if offload_complete_fd >= 0:
        backend.try_add_read(offload_complete_fd)

    # Application tick: one loop-wide timer driving the handler's `tick`
    # hook. Opt-in — 0 means the hook never fires and costs nothing.
    if config.app_tick_ms > 0:
        backend.try_add_timer(TIMER_APP_TICK, config.app_tick_ms)

    var max_conns = config.max_connections
    var provision_pool = ProvisionPool(max_conns, config)

    # Per-slot state (SoA pattern)
    var slot_fds = List[Int](capacity=max_conns)
    var slot_response = OwningList[Bytes](capacity=max_conns)
    var slot_send_offset = List[Int](capacity=max_conns)
    var slot_header_start = List[Int](capacity=max_conns)
    var slot_sse = List[Bool](capacity=max_conns)
    var slot_ws = List[Bool](capacity=max_conns)
    # Whether the slot's fd currently has a read filter registered with the
    # backend. Registrations are persistent on both backends (epoll: EPOLLIN
    # edge-triggered without ONESHOT; kqueue: EV_ADD without EV_ONESHOT), so
    # re-registering per keep-alive request is two wasted epoll_ctl calls per
    # request — the ADD that fails EEXIST plus the MOD. The one operation
    # that CAN disarm reads is add_write_oneshot: on epoll it replaces the
    # fd's event mask. Tracking that transition here lets the steady-state
    # keep-alive path skip re-arming entirely.
    var slot_read_armed = List[Bool](capacity=max_conns)
    # Idle-timeout deadline (perf_counter_ns value; 0 = none). Replaces a
    # per-request timerfd_settime with a once-a-second sweep — idle timeouts
    # are whole seconds, so 1 s sweep granularity loses nothing.
    var slot_idle_deadline = List[Int](capacity=max_conns)
    # Per-slot WebSocket frame parser. Always allocated, tiny while unused;
    # reset (not reallocated) when a slot is reused.
    var slot_ws_state = OwningList[WSState](capacity=max_conns)

    for _ in range(max_conns):
        slot_fds.append(UNUSED)
        slot_response.append(Bytes())
        slot_send_offset.append(0)
        slot_header_start.append(0)
        slot_sse.append(False)
        slot_ws.append(False)
        slot_read_armed.append(False)
        slot_idle_deadline.append(0)
        slot_ws_state.append(WSState(config.max_request_body_size))

    var fd_map_size = 65536
    var fd_to_slot = List[Int](capacity=fd_map_size)
    for _ in range(fd_map_size):
        fd_to_slot.append(UNUSED)

    var active_count = 0

    # Phase 4e: per-server metrics (opt-in via config.enable_metrics)
    var metrics = ServerMetrics()
    metrics.pool_capacity = max_conns

    comptime if CompilationTarget.is_macos():
        print("Event loop started (kqueue, max_connections=" + String(max_conns) + ")")
    else:
        print("Event loop started (epoll, max_connections=" + String(max_conns) + ")")

    var should_shutdown = False
    var last_idle_sweep = perf_counter_ns()
    # Date-header cache: IMF-fixdate has one-second granularity, so format
    # it once per second instead of once per response (~10 String
    # allocations + gmtime each time — measured ~9% of hello throughput).
    var date_cache_sec: Int64 = unix_now()
    var date_cache = http_date_from_unix(date_cache_sec)
    while True:
        var n_events = backend.wait(1000)

        for i in range(n_events):
            if (backend.event_flags(i) & EV_ERROR) != 0:
                continue

            # Phase 4a: shutdown pipe — write end closed, exit cleanly
            if shutdown_read_fd >= 0 and Int(backend.event_ident(i)) == shutdown_read_fd:
                should_shutdown = True
                break

            # --- Cross-worker broadcast channel ---
            # Registration is edge-triggered, so every waiting datagram must
            # be consumed now; drain_bus_channel reads until EAGAIN. The
            # handler queues each frame for its local subscribers, and the
            # SSE outbox drain at the bottom of this pass sends them out.
            var _ident = Int(backend.event_ident(i))
            var _is_bus = bus_read_fd >= 0 and _ident == bus_read_fd
            var _is_peer_bus = peer_bus_fd >= 0 and _ident == peer_bus_fd
            if _is_bus or _is_peer_bus:
                var peer_frames = drain_bus_channel(
                    bus_read_fd if _is_bus else peer_bus_fd
                )
                for f in range(len(peer_frames)):
                    handler.sse_peer_frame(
                        peer_frames[f].url,
                        peer_frames[f].event_id,
                        peer_frames[f].frame,
                    )
                continue

            # --- `--blocking-threads` completion channel ---
            # A pool thread finished a request. Edge-triggered like the bus,
            # so drain it fully; each completion re-enters the ordinary
            # RESPONDING write path.
            if offload_complete_fd >= 0 and Int(backend.event_ident(i)) == offload_complete_fd:
                _service_completions(
                    backend, handler, config, server_address, tcp_keep_alive,
                    slot_fds, slot_response, slot_send_offset, slot_header_start,
                    fd_to_slot, provision_pool, active_count, metrics,
                    slot_sse, slot_ws, slot_ws_state,
                    slot_read_armed, slot_idle_deadline,
                    date_cache_sec, date_cache, offload, bus_read_fd,
                )
                continue

            # --- Listen socket: accept new connections ---
            if Int(backend.event_ident(i)) == listen_fd.value and backend.event_filter(i) == EVFILT_READ:
                # kqueue reports the pending backlog depth in the event data
                # field; epoll has no equivalent and returns 0 for "unknown".
                #
                # Both backends arm the listen socket edge-triggered, so a
                # burst of simultaneous connections produces exactly ONE
                # readiness event. Accepting a single connection per event
                # would strand the rest in the backlog until some later
                # connection happened to trigger a fresh edge. When the depth
                # is unknown, drain until accept() raises EAGAIN instead — the
                # listen socket is non-blocking (set above) and the loop below
                # breaks on the first failed accept.
                var pending = backend.event_data(i)
                var accept_budget = pending if pending > 0 else max_conns
                for _accept_idx in range(accept_budget):
                    var new_fd: FileDescriptor
                    var peer_host: String
                    var peer_port: Int
                    try:
                        var accepted = accept_with_peer(listen_fd)
                        new_fd = accepted[0]
                        peer_host = accepted[1]
                        peer_port = accepted[2]
                    except accept_err:
                        # EAGAIN: backlog drained — this readiness event is done.
                        if accept_err.isa[AcceptEAGAINError]():
                            break
                        # ECONNABORTED (the client gave up while queued) and
                        # EINTR are per-attempt transients. They MUST NOT end
                        # the drain: the listen socket is edge-triggered on
                        # both backends, so connections left in the backlog
                        # here are owed no new readiness edge until some later
                        # connection arrives — under bursty load that strands
                        # live clients behind a dead one.
                        if accept_err.isa[AcceptECONNABORTEDError]() or accept_err.isa[AcceptEINTRError]():
                            continue
                        # Anything else (EMFILE, ENFILE, ...) won't be cured
                        # by accepting harder; stop and let the loop breathe.
                        break

                    var slot: Int
                    try:
                        slot = provision_pool.borrow()
                    except:
                        try:
                            close(new_fd)
                        except:
                            pass
                        continue

                    var fd_val = new_fd.value

                    if fd_val >= len(fd_to_slot):
                        var new_len = fd_val + 1024
                        for _ in range(len(fd_to_slot), new_len):
                            fd_to_slot.append(UNUSED)

                    try:
                        set_nonblocking(new_fd)
                    except:
                        provision_pool.release(slot)
                        try:
                            close(new_fd)
                        except:
                            pass
                        continue

                    # Nagle off: single-send responses have nothing to
                    # coalesce, and leaving it on stalls a response behind
                    # the previous response's ACK. Best-effort.
                    set_tcp_nodelay(new_fd)

                    slot_fds[slot] = fd_val
                    # One capture per connection covers every request the
                    # keep-alive carries; overwritten at the slot's next
                    # accept, so no clearing on close.
                    provision_pool.provisions[slot].peer_host = peer_host^
                    provision_pool.provisions[slot].peer_port = peer_port
                    slot_send_offset[slot] = 0
                    slot_header_start[slot] = perf_counter_ns()
                    slot_read_armed[slot] = False
                    slot_idle_deadline[slot] = 0
                    # A recycled slot must not inherit the previous
                    # connection's channel-stream state: a pool thread's
                    # ack fd left here would make the next M0-Hold on this
                    # slot look like a chunk-framed stream.
                    offload.clear_stream(slot)
                    fd_to_slot[fd_val] = slot
                    active_count += 1
                    if config.enable_metrics:
                        metrics.accepts_total += 1

                    provision_pool.provisions[slot].prepare_for_new_request()
                    provision_pool.provisions[slot].keepalive_count = 0

                    # No header timerfd: the once-a-second sweep owns this
                    # deadline now. `slot_header_start` stamped just above is
                    # the whole mechanism, and it costs no fd and no syscall.

                    # Eager read: try to process data already buffered.
                    # EVFILT_READ is NOT registered yet — we register it only
                    # if the eager read gets EAGAIN (no data).  This avoids
                    # kqueue state confusion when recv() consumes data that
                    # kqueue hasn't delivered yet.
                    _handle_read_headers(
                        backend, slot, fd_val, handler, config,
                        server_address, tcp_keep_alive,
                        slot_fds, slot_response, slot_send_offset,
                        slot_header_start, fd_to_slot, provision_pool,
                        active_count, metrics, slot_sse, slot_ws, slot_ws_state,
                        slot_read_armed, slot_idle_deadline,
                        date_cache_sec, date_cache, offload,
                    )

                    # If the slot is still active and in reading_headers state,
                    # the eager read got EAGAIN — register EVFILT_READ now.
                    # (_after_send may already have armed it if the eager read
                    # carried a complete request; skip the redundant syscall.)
                    if slot_fds[slot] != UNUSED and (not slot_read_armed[slot]) and provision_pool.provisions[slot].state.kind == ConnectionState.READING_HEADERS:
                        try:
                            backend.add_read(fd_val)
                            slot_read_armed[slot] = True
                        except:
                            _close_slot(
                                backend, handler, slot, fd_val,
                                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                                slot_sse, slot_ws, slot_ws_state,
                            )
                    # The eager read may have taken MORE than one request.
                    _drain_pipelined(
                        backend, slot, fd_val, handler, config,
                        server_address, tcp_keep_alive,
                        slot_fds, slot_response, slot_send_offset,
                        slot_header_start, fd_to_slot, provision_pool,
                        active_count, metrics, slot_sse, slot_ws, slot_ws_state,
                        slot_read_armed, slot_idle_deadline,
                        date_cache_sec, date_cache, offload,
                    )
                continue

            # --- Timer events ---
            if backend.event_filter(i) == EVFILT_TIMER:
                var timer_ident = backend.event_ident(i)
                var fd_val: Int

                # Application tick: hand the handler its scheduled wakeup.
                if timer_ident >= TIMER_APP_TICK:
                    # Re-arm FIRST — one-shot on both backends, and on epoll
                    # the re-arm is also what clears the fired timerfd's
                    # readability (the same level-triggered storm the SSE
                    # heartbeat hit; see that handler below).
                    backend.try_add_timer(TIMER_APP_TICK, config.app_tick_ms)
                    handler.tick(Int(perf_counter_ns() // 1_000_000))
                    # Whatever the handler broadcast is queued in per-slot
                    # outboxes now; the SSE drain at the bottom of this pass
                    # pushes it to the wire.
                    continue

                # Stream heartbeat timer: an SSE comment or a WebSocket ping,
                # depending on what the slot is — same cadence, same job
                # (keep intermediaries from timing the connection out, and
                # discover dead clients that never sent a FIN).
                if timer_ident >= TIMER_SSE_HEARTBEAT:
                    fd_val = Int(timer_ident - TIMER_SSE_HEARTBEAT)
                    if fd_val >= len(fd_to_slot):
                        continue
                    var hb_slot = fd_to_slot[fd_val]
                    if hb_slot == UNUSED or not (slot_sse[hb_slot] or slot_ws[hb_slot]):
                        # The stream this timer belonged to is gone (or the fd
                        # now serves a non-streaming connection); retire the timer.
                        backend.try_delete_timer(timer_ident)
                        continue
                    var hb_is_ws = slot_ws[hb_slot]
                    # Re-arm FIRST, unconditionally. Timers are one-shot on
                    # both backends (kqueue EV_ONESHOT; epoll timerfd with no
                    # interval), so without this a stream gets exactly one
                    # heartbeat ever. On epoll the re-arm is also what clears
                    # the fired timerfd's expiration count — the timerfd is
                    # registered level-triggered and nothing read()s it, so an
                    # expired-and-unrearmed timer would be returned by every
                    # subsequent epoll_wait: a heartbeat storm at loop speed.
                    backend.try_add_timer(timer_ident, config.sse_heartbeat_ms)
                    # An executor's stream: no comment injection. An SSE
                    # event may span two chunks, and a `: heartbeat` landing
                    # between them corrupts the frame for any parser
                    # (Datastar's included). Dead clients are still
                    # discovered — by chunk-send failures and read-EOF, both
                    # of which close the slot. WS pings are frame-atomic and
                    # stay. Asked per SLOT, not per server: under
                    # `--realtime --mount` a held stream shares this loop
                    # with an executor's, and a hold is one frame per event
                    # with nothing to land between — the heartbeat is what
                    # keeps it alive through an idle proxy.
                    if not hb_is_ws and offload.slot_channel_stream(hb_slot):
                        continue
                    var hb_idle_kind = ConnectionState.STREAMING_WS if hb_is_ws else ConnectionState.STREAMING_SSE
                    if provision_pool.provisions[hb_slot].state.kind != hb_idle_kind:
                        # Mid-send of a real event; skip this beat, keep the next.
                        continue
                    if hb_is_ws:
                        slot_response[hb_slot] = Bytes(Span(encode_ws_frame(WS_OP_PING, "hb".as_bytes())))
                    else:
                        var hb = String(": heartbeat\n\n")
                        slot_response[hb_slot] = Bytes(hb.as_bytes())
                    slot_send_offset[hb_slot] = 0
                    provision_pool.provisions[hb_slot].state = ConnectionState.responding()
                    var fd_desc = FileDescriptor(fd_val)
                    var hb_dead = False
                    try:
                        var sent = send(fd_desc, Span(slot_response[hb_slot]), UInt(len(slot_response[hb_slot])), 0)
                        slot_send_offset[hb_slot] = Int(sent)
                    except hb_err:
                        # EPIPE/ECONNRESET here is the heartbeat doing its
                        # other job: discovering a dead subscriber that never
                        # sent a FIN. Close it (which notifies the handler)
                        # rather than leaving a zombie stream.
                        if not hb_err.isa[SendEAGAINError]():
                            hb_dead = True
                    if hb_dead:
                        _close_slot(
                            backend, handler, hb_slot, fd_val,
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse, slot_ws, slot_ws_state,
                        )
                        continue
                    if slot_send_offset[hb_slot] >= len(slot_response[hb_slot]):
                        provision_pool.provisions[hb_slot].state = ConnectionState.streaming_ws() if hb_is_ws else ConnectionState.streaming_sse()
                    else:
                        backend.try_add_write_oneshot(fd_val)
                        slot_read_armed[hb_slot] = False
                    continue

                if timer_ident >= TIMER_IDLE:
                    fd_val = Int(timer_ident - TIMER_IDLE)
                elif timer_ident >= TIMER_BODY:
                    fd_val = Int(timer_ident - TIMER_BODY)
                else:
                    continue

                if fd_val >= len(fd_to_slot):
                    continue
                var slot = fd_to_slot[fd_val]
                if slot == UNUSED:
                    continue

                # Phase 1d: idle timeout is expected client behaviour — close cleanly.
                # Only send 408 for header/body timeouts on the first request.
                if timer_ident < TIMER_IDLE and provision_pool.provisions[slot].keepalive_count == 0:
                    _send_error_to_fd(fd_val, RequestTimeout())

                _close_slot(
                    backend, handler, slot, fd_val,
                    slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                    slot_sse, slot_ws, slot_ws_state,
                )
                continue

            # --- Read events on connection sockets ---
            if backend.event_filter(i) == EVFILT_READ:
                var fd_val = Int(backend.event_ident(i))
                if fd_val >= len(fd_to_slot):
                    continue
                var slot = fd_to_slot[fd_val]
                if slot == UNUSED:
                    continue

                # A slot whose request is in a pool thread belongs to that
                # thread: its job storage is being written right now. Detach
                # the connection if the client left, but hold the provision
                # until the completion arrives (see `_close_slot`).
                if offload.offloaded[slot]:
                    if (backend.event_flags(i) & EV_EOF) != 0:
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
                        provision_pool.provisions[slot].peer_eof = True
                        slot_read_armed[slot] = False
                    else:
                        # A pipelined request arrived mid-flight. Both backends
                        # are edge-triggered, so consuming this event without
                        # reading would lose the only edge those bytes ever
                        # get; clearing the armed flag makes `_after_send`
                        # re-register, which regenerates readiness for them.
                        slot_read_armed[slot] = False
                    continue

                if (backend.event_flags(i) & EV_EOF) != 0:
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
                    # path, which finishes the buffered request; keep-alive
                    # is off, because the peer cannot send another.
                    var _eof_state = provision_pool.provisions[slot].state.kind
                    if (
                        _eof_state == ConnectionState.STREAMING_SSE
                        or _eof_state == ConnectionState.STREAMING_WS
                    ):
                        _close_slot(
                            backend, handler, slot, fd_val,
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse, slot_ws, slot_ws_state,
                        )
                        continue
                    provision_pool.provisions[slot].should_close = True
                    provision_pool.provisions[slot].peer_eof = True

                if provision_pool.provisions[slot].state.kind == ConnectionState.STREAMING_WS:
                    # WebSocket frames from the client. The parser answers
                    # control frames itself (ping→pong, close→close echo);
                    # complete data messages go to the handler, whose queued
                    # replies the outbox drain below this pass sends.
                    provision_pool.provisions[slot].recv_staging.clear()
                    var ws_fd = FileDescriptor(fd_val)
                    var ws_read: UInt
                    try:
                        ws_read = recv(
                            ws_fd,
                            Span(provision_pool.provisions[slot].recv_staging),
                            UInt(provision_pool.provisions[slot].recv_staging.capacity()),
                            0,
                        )
                    except ws_recv_err:
                        if ws_recv_err.isa[RecvEAGAINError]():
                            continue
                        _close_slot(
                            backend, handler, slot, fd_val,
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse, slot_ws, slot_ws_state,
                        )
                        continue
                    if ws_read == 0:
                        _close_slot(
                            backend, handler, slot, fd_val,
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse, slot_ws, slot_ws_state,
                        )
                        continue
                    provision_pool.provisions[slot].recv_staging._len = Int(ws_read)
                    var ws_res = slot_ws_state[slot].feed(
                        Span(provision_pool.provisions[slot].recv_staging)
                    )
                    if len(ws_res.reply) > 0:
                        # Pongs and close echoes are tiny; a send failure that
                        # isn't EAGAIN means the client is gone. A dropped
                        # pong on EAGAIN is fine — the next ping repeats it.
                        var ws_reply_dead = False
                        try:
                            _ = send(ws_fd, Span(ws_res.reply), UInt(len(ws_res.reply)), 0)
                        except ws_send_err:
                            if not ws_send_err.isa[SendEAGAINError]():
                                ws_reply_dead = True
                        if ws_reply_dead:
                            _close_slot(
                                backend, handler, slot, fd_val,
                                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                                slot_sse, slot_ws, slot_ws_state,
                            )
                            continue
                    for m in range(len(ws_res.msg_opcodes)):
                        handler.ws_message(
                            slot, ws_res.msg_opcodes[m], ws_res.msg_payloads[m]
                        )
                    if ws_res.close_after_reply:
                        _close_slot(
                            backend, handler, slot, fd_val,
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse, slot_ws, slot_ws_state,
                        )
                    continue

                if provision_pool.provisions[slot].state.kind == ConnectionState.STREAMING_SSE:
                    # SSE client disconnect: recv→0 means client closed
                    # connection. _close_slot notifies the handler.
                    _close_slot(
                        backend, handler, slot, fd_val,
                        slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                        slot_sse, slot_ws, slot_ws_state,
                    )
                    continue

                elif provision_pool.provisions[slot].state.kind == ConnectionState.READING_HEADERS:
                    _handle_read_headers(
                        backend, slot, fd_val, handler, config,
                        server_address, tcp_keep_alive,
                        slot_fds, slot_response, slot_send_offset,
                        slot_header_start, fd_to_slot, provision_pool,
                        active_count, metrics, slot_sse, slot_ws, slot_ws_state,
                        slot_read_armed, slot_idle_deadline,
                        date_cache_sec, date_cache, offload,
                    )

                elif provision_pool.provisions[slot].state.kind == ConnectionState.READING_BODY:
                    var body_st = provision_pool.provisions[slot].body_state.value()

                    # Phase 2a: recv into per-slot staging buffer (avoids per-recv heap alloc)
                    provision_pool.provisions[slot].recv_staging.clear()
                    var fd_desc = FileDescriptor(fd_val)
                    var bytes_read: UInt
                    try:
                        bytes_read = recv(
                            fd_desc,
                            Span(provision_pool.provisions[slot].recv_staging),
                            UInt(provision_pool.provisions[slot].recv_staging.capacity()),
                            0,
                        )
                    except recv_err:
                        if recv_err.isa[RecvEAGAINError]():
                            continue
                        _close_slot(
                            backend, handler, slot, fd_val,
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse, slot_ws, slot_ws_state,
                        )
                        continue

                    if bytes_read == 0:
                        _close_slot(
                            backend, handler, slot, fd_val,
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse, slot_ws, slot_ws_state,
                        )
                        continue

                    provision_pool.provisions[slot].recv_staging._len = Int(bytes_read)
                    provision_pool.provisions[slot].recv_buffer.extend(
                        Span(provision_pool.provisions[slot].recv_staging)
                    )

                    if not body_st.is_chunked:
                        body_st.bytes_read += Int(bytes_read)
                        provision_pool.provisions[slot].body_state = body_st

                    if len(provision_pool.provisions[slot].recv_buffer) > config.recv_buffer_limit():
                        _send_error_to_fd(fd_val, BadRequest())
                        _close_slot(
                            backend, handler, slot, fd_val,
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse, slot_ws, slot_ws_state,
                        )
                        continue

                    # Phase 1b: chunked body decode, resumed not restarted.
                    #
                    # The buffer is laid out [headers][decoded so far][raw
                    # tail], and only the raw tail is handed to the
                    # connection's own decoder — which carries its chunk
                    # state across reads, so it continues where it stopped.
                    # Decoded output lands at the front of that tail, i.e.
                    # contiguous with what was already decoded, and the
                    # partial header it could not finish is left just after
                    # it (`pending_bytes`). Total work is linear in the body
                    # rather than quadratic in the number of reads; see
                    # `ConnectionProvision.chunk_decoder`.
                    if body_st.is_chunked:
                        var raw_body_start = body_st.header_end_offset
                        var decoded_so_far = body_st.bytes_read
                        var tail_start = raw_body_start + decoded_so_far
                        var buf_len = len(provision_pool.provisions[slot].recv_buffer)
                        # The cap is on the DECODED body plus whatever raw
                        # tail is still buffered — the same quantity the old
                        # code compared, now that consumed framing bytes are
                        # dropped as they are decoded.
                        # Two bounds, because a chunked body has two sizes.
                        # The decoded body is what the application sees; the
                        # raw stream is what the connection cost. Framing is
                        # consumed and dropped as it is decoded, so without
                        # the second an attacker could send the body limit
                        # in real data and then keep going in chunk-extension
                        # bytes, bounded only by the decoder's ratio guard.
                        if (
                            buf_len - raw_body_start > config.max_request_body_size
                            or provision_pool.provisions[slot].chunk_decoder._total_read
                            > 2 * config.max_request_body_size
                        ):
                            _send_error_to_fd(fd_val, PayloadTooLarge())
                            _close_slot(backend, handler, slot, fd_val, slot_fds, fd_to_slot, provision_pool, active_count, metrics, slot_sse, slot_ws, slot_ws_state)
                            continue
                        if buf_len > tail_start:
                            var ret: Int
                            var produced: Int
                            ret, produced = provision_pool.provisions[
                                slot
                            ].chunk_decoder.decode(
                                Span(provision_pool.provisions[slot].recv_buffer)[
                                    tail_start:
                                ]
                            )
                            if ret == -1:
                                _send_error_to_fd(fd_val, BadRequest())
                                _close_slot(backend, handler, slot, fd_val, slot_fds, fd_to_slot, provision_pool, active_count, metrics, slot_sse, slot_ws, slot_ws_state)
                                continue
                            var leftover = provision_pool.provisions[
                                slot
                            ].chunk_decoder.pending_bytes
                            # Drop the framing bytes this pass consumed, so
                            # the next read appends straight onto the tail.
                            provision_pool.provisions[slot].recv_buffer.resize(
                                tail_start + produced + leftover, 0
                            )
                            decoded_so_far += produced
                            body_st.bytes_read = decoded_so_far
                            provision_pool.provisions[slot].body_state = body_st
                            if ret >= 0:
                                # Complete. `pending_bytes` bytes past the
                                # chunked data stay in the buffer: they are
                                # the next pipelined request, and the
                                # keep-alive reset preserves them.
                                provision_pool.provisions[slot].request_end = (
                                    raw_body_start + decoded_so_far
                                )
                                body_st.content_length = decoded_so_far
                                body_st.bytes_read = decoded_so_far
                                body_st.is_chunked = False
                                provision_pool.provisions[slot].body_state = body_st
                                if config.body_read_timeout > 0:
                                    backend.try_delete_timer(UInt(fd_val) + TIMER_BODY)
                                provision_pool.provisions[slot].state = ConnectionState.processing()
                                _process_request(
                                    backend, slot, fd_val, handler,
                                    config, server_address, tcp_keep_alive,
                                    slot_fds, slot_response, slot_send_offset, slot_header_start,
                                    fd_to_slot, provision_pool, active_count, metrics,
                                    slot_sse, slot_ws, slot_ws_state,
                                    slot_read_armed, slot_idle_deadline,
                                    date_cache_sec, date_cache, offload,
                                )
                        # ret == -2 or empty: wait for more data via EVFILT_READ
                    elif body_st.bytes_read >= body_st.content_length:
                        if config.body_read_timeout > 0:
                            backend.try_delete_timer(UInt(fd_val) + TIMER_BODY)

                        provision_pool.provisions[slot].state = ConnectionState.processing()
                        _process_request(
                            backend, slot, fd_val,
                            handler,
                            config, server_address, tcp_keep_alive,
                            slot_fds, slot_response, slot_send_offset,
                            slot_header_start,
                            fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse, slot_ws, slot_ws_state,
                            slot_read_armed, slot_idle_deadline,
                            date_cache_sec, date_cache, offload,
                        )

                    # One recv per event does not drain an edge-triggered
                    # socket: a body larger than the staging buffer leaves
                    # bytes pending that will never raise another edge on
                    # their own. Re-register to regenerate readiness for
                    # them, the same reason as the arm in
                    # _handle_read_headers.
                    if (
                        slot_fds[slot] != UNUSED
                        and provision_pool.provisions[slot].state.kind
                        == ConnectionState.READING_BODY
                    ):
                        backend.try_add_read(fd_val)
                        slot_read_armed[slot] = True

                # A response completed inline above may have left the NEXT
                # pipelined request whole in recv_buffer, with no event ever
                # coming to announce it.
                _drain_pipelined(
                    backend, slot, fd_val, handler, config,
                    server_address, tcp_keep_alive,
                    slot_fds, slot_response, slot_send_offset,
                    slot_header_start, fd_to_slot, provision_pool,
                    active_count, metrics, slot_sse, slot_ws, slot_ws_state,
                    slot_read_armed, slot_idle_deadline,
                    date_cache_sec, date_cache, offload,
                )
                continue

            # --- Write events on connection sockets ---
            if backend.event_filter(i) == EVFILT_WRITE:
                var fd_val = Int(backend.event_ident(i))
                if fd_val >= len(fd_to_slot):
                    continue
                var slot = fd_to_slot[fd_val]
                if slot == UNUSED:
                    continue

                if provision_pool.provisions[slot].state.kind != ConnectionState.RESPONDING:
                    continue

                if offload.offloaded[slot]:
                    continue

                var remaining = len(slot_response[slot]) - slot_send_offset[slot]
                if remaining <= 0:
                    # Head already drained: this readiness belongs to the
                    # file body, if one is still owed.
                    var pumped = _pump_body_fd(
                        provision_pool.provisions[slot], fd_val
                    )
                    if pumped == BODY_FD_FATAL:
                        _close_slot(
                            backend, handler, slot, fd_val,
                            slot_fds, fd_to_slot, provision_pool,
                            active_count, metrics,
                            slot_sse, slot_ws, slot_ws_state,
                        )
                        continue
                    if pumped == BODY_FD_MORE:
                        try:
                            backend.add_write_oneshot(fd_val)
                            slot_read_armed[slot] = False
                        except:
                            _close_slot(
                                backend, handler, slot, fd_val,
                                slot_fds, fd_to_slot, provision_pool,
                                active_count, metrics,
                                slot_sse, slot_ws, slot_ws_state,
                            )
                        continue
                    _after_send(
                        backend, slot, fd_val,
                        handler, config, server_address, tcp_keep_alive,
                        slot_fds, slot_response, slot_send_offset,
                        slot_header_start,
                        fd_to_slot, provision_pool, active_count, metrics,
                        slot_sse, slot_ws, slot_ws_state,
                        slot_read_armed, slot_idle_deadline,
                    )
                    _drain_pipelined(
                        backend, slot, fd_val, handler, config,
                        server_address, tcp_keep_alive,
                        slot_fds, slot_response, slot_send_offset,
                        slot_header_start, fd_to_slot, provision_pool,
                        active_count, metrics, slot_sse, slot_ws, slot_ws_state,
                        slot_read_armed, slot_idle_deadline,
                        date_cache_sec, date_cache, offload,
                    )
                    continue

                var fd_desc = FileDescriptor(fd_val)
                var sent: UInt
                try:
                    sent = send(
                        fd_desc,
                        Span(slot_response[slot])[slot_send_offset[slot]:],
                        UInt(remaining),
                        0,
                    )
                except send_err:
                    if send_err.isa[SendEAGAINError]():
                        backend.try_add_write_oneshot(fd_val)
                        slot_read_armed[slot] = False
                        continue
                    _close_slot(
                        backend, handler, slot, fd_val,
                        slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                        slot_sse, slot_ws, slot_ws_state,
                    )
                    continue

                slot_send_offset[slot] += Int(sent)

                if slot_send_offset[slot] >= len(slot_response[slot]):
                    # The partial-send completion of a streaming buffer: ack
                    # the PAYLOAD the drain recorded for it (the drain pass
                    # acked nothing, having sent only part). Not the buffer
                    # length — chunk framing makes those differ, and the
                    # window must count what the application produced. The
                    # stream head lands here too, with 0 owed.
                    if offload.ack_payload[slot] > 0 and offload.slot_channel_stream(slot):
                        if not offload.pool()[].ack_stream(slot, offload.ack_payload[slot]):
                            if offload.ack_owed[slot] == 0:
                                offload.ack_owed_count += 1
                            offload.ack_owed[slot] += offload.ack_payload[slot]
                    offload.ack_payload[slot] = 0
                    _after_send(
                        backend, slot, fd_val,
                        handler, config, server_address, tcp_keep_alive,
                        slot_fds, slot_response, slot_send_offset,
                        slot_header_start,
                        fd_to_slot, provision_pool, active_count, metrics,
                        slot_sse, slot_ws, slot_ws_state,
                        slot_read_armed, slot_idle_deadline,
                    )
                    _drain_pipelined(
                        backend, slot, fd_val, handler, config,
                        server_address, tcp_keep_alive,
                        slot_fds, slot_response, slot_send_offset,
                        slot_header_start, fd_to_slot, provision_pool,
                        active_count, metrics, slot_sse, slot_ws, slot_ws_state,
                        slot_read_armed, slot_idle_deadline,
                        date_cache_sec, date_cache, offload,
                    )
                else:
                    try:
                        backend.add_write_oneshot(fd_val)
                        slot_read_armed[slot] = False
                    except:
                        _close_slot(
                            backend, handler, slot, fd_val,
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse, slot_ws, slot_ws_state,
                        )

        # Credit the ack channel refused earlier (`ack_stream` returned
        # False: EAGAIN, the executor not reading at that instant — most
        # likely because it was itself waiting for THIS loop to drain its
        # chunks). Retried every pass and never dropped: a window short by
        # one ack is a `send()` that awaits forever. A slot that has since
        # closed forfeits what it was owed; the head of the next stream on
        # that slot seeds a fresh window.
        if offload.ack_owed_count > 0:
            var can_ack = offload.chunk_active()
            for s in range(max_conns):
                if offload.ack_owed[s] <= 0:
                    continue
                if slot_fds[s] == UNUSED or (can_ack and offload.pool()[].ack_stream(s, offload.ack_owed[s])):
                    offload.ack_owed[s] = 0
                    offload.ack_owed_count -= 1

        # Outbox drain: push pending bytes to streaming connections — SSE
        # events and WebSocket frames share the same per-slot outbox contract
        # (sse_drain_slot returns whichever the handler queued).
        for s in range(max_conns):
            var s_idle = (
                slot_sse[s] and provision_pool.provisions[s].state.kind == ConnectionState.STREAMING_SSE
            ) or (
                slot_ws[s] and provision_pool.provisions[s].state.kind == ConnectionState.STREAMING_WS
            )
            if s_idle and slot_fds[s] != UNUSED and not offload.offloaded[s]:
                # A channel stream — an executor's, or a pool thread's WSGI
                # iterable (asked per slot: a held stream on the same loop
                # is drained by the same pass and is none of this): drained
                # bytes are acked back to the producer's credit window, and
                # `sse_is_streaming` — unread by the loop anywhere else —
                # becomes the end-of-stream signal: the handler unsubscribes
                # once the final chunk has been handed out, and the loop
                # closes after those bytes land. Close is how a
                # content-length-free streamed body ends.
                var asgi_stream = offload.slot_channel_stream(s)
                var pending = handler.sse_drain_slot(s)
                # Read ONCE per pass: `sse_drain_slot` above is what makes it
                # go false, so asking twice can straddle the transition and
                # send a terminator on a stream that just queued more.
                var ended = asgi_stream and not handler.sse_is_streaming(s)
                var framed = offload.chunked[s]

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
                    slot_response[s] = out^
                    slot_send_offset[s] = 0
                    # What the write-ready completion owes the producer if
                    # this buffer does not land in one send below.
                    offload.ack_payload[s] = payload_len if asgi_stream else 0
                    provision_pool.provisions[s].state = ConnectionState.responding()
                    # Eager send
                    var sse_fd = FileDescriptor(slot_fds[s])
                    try:
                        var sent = send(sse_fd, Span(slot_response[s]), UInt(len(slot_response[s])), 0)
                        slot_send_offset[s] = Int(sent)
                    except:
                        pass
                    if slot_send_offset[s] >= len(slot_response[s]):
                        # Landed in one send: ack here and cancel what the
                        # write-ready path would otherwise have owed.
                        offload.ack_payload[s] = 0
                        if asgi_stream and payload_len > 0:
                            if not offload.pool()[].ack_stream(s, payload_len):
                                if offload.ack_owed[s] == 0:
                                    offload.ack_owed_count += 1
                                offload.ack_owed[s] += payload_len
                        if ended:
                            # Whatever comes next on this slot is not this
                            # stream: forget its producer's ack fd and its
                            # generation before the connection is reused
                            # or closed.
                            offload.clear_stream(s)
                            if framed:
                                # The terminator landed: the message is
                                # complete and the connection is reusable.
                                # Clearing the stream flag is what routes
                                # `_after_send` down its keep-alive path
                                # instead of back into streaming.
                                slot_sse[s] = False
                                offload.chunked[s] = False
                                _after_send(
                                    backend, s, slot_fds[s],
                                    handler, config, server_address, tcp_keep_alive,
                                    slot_fds, slot_response, slot_send_offset,
                                    slot_header_start,
                                    fd_to_slot, provision_pool, active_count, metrics,
                                    slot_sse, slot_ws, slot_ws_state,
                                    slot_read_armed, slot_idle_deadline,
                                )
                                _drain_pipelined(
                                    backend, s, slot_fds[s], handler, config,
                                    server_address, tcp_keep_alive,
                                    slot_fds, slot_response, slot_send_offset,
                                    slot_header_start, fd_to_slot, provision_pool,
                                    active_count, metrics, slot_sse, slot_ws, slot_ws_state,
                                    slot_read_armed, slot_idle_deadline,
                                    date_cache_sec, date_cache, offload,
                                )
                            else:
                                _close_slot(
                                    backend, handler, s, slot_fds[s],
                                    slot_fds, fd_to_slot, provision_pool,
                                    active_count, metrics,
                                    slot_sse, slot_ws, slot_ws_state,
                                )
                            continue
                        provision_pool.provisions[s].state = ConnectionState.streaming_ws() if slot_ws[s] else ConnectionState.streaming_sse()
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
                            offload.clear_stream(s)
                        if ended and not framed:
                            # The rest of the final buffer flushes through
                            # the write-ready path; _after_send's existing
                            # should_close branch closes it there.
                            provision_pool.provisions[s].should_close = True
                        elif ended and framed:
                            # Same flush, but the message ends with the
                            # terminator already in this buffer — so the
                            # write-ready completion must finish it as a
                            # keep-alive response, not a close.
                            slot_sse[s] = False
                            offload.chunked[s] = False
                        backend.try_add_write_oneshot(slot_fds[s])
                        slot_read_armed[s] = False
                elif ended:
                    # End marked with nothing left to send. Only reachable
                    # unframed: a framed stream always has a terminator to
                    # write, so `out` is never empty when it ends.
                    offload.clear_stream(s)
                    _close_slot(
                        backend, handler, s, slot_fds[s],
                        slot_fds, fd_to_slot, provision_pool,
                        active_count, metrics,
                        slot_sse, slot_ws, slot_ws_state,
                    )

        # The pass's executor submits, one datagram per lane. After the
        # outbox drain and before this loop can park in `wait`: a slot left
        # buffered across a wait is a request nothing would ever run.
        _flush_submits(
            backend, handler, config, server_address, tcp_keep_alive,
            slot_fds, slot_response, slot_send_offset, slot_header_start,
            fd_to_slot, provision_pool, active_count, metrics,
            slot_sse, slot_ws, slot_ws_state, slot_read_armed,
            slot_idle_deadline, date_cache_sec, date_cache, offload,
        )

        # Idle-timeout sweep. Replaces the old per-request timerfd re-arm
        # (one timerfd_settime per keep-alive request) with a once-a-second
        # scan of active slots. Timeouts are whole seconds, so the 1 s sweep
        # granularity changes nothing observable; the loop's wait() timeout
        # of 1000 ms guarantees the sweep runs even when the server is idle.
        if config.idle_timeout > 0 or config.header_read_timeout > 0:
            var sweep_now = perf_counter_ns()
            if sweep_now - last_idle_sweep >= 1_000_000_000:
                last_idle_sweep = sweep_now
                var header_ns = config.header_read_timeout * 1_000_000_000
                for s in range(max_conns):
                    if slot_fds[s] == UNUSED:
                        continue
                    # A slot with a job in a pool thread is working, not idle,
                    # and its request belongs to another thread — closing it
                    # here would release a provision still in use.
                    if offload.offloaded[s]:
                        continue
                    if (
                        config.idle_timeout > 0
                        and slot_idle_deadline[s] != 0
                        and sweep_now > slot_idle_deadline[s]
                    ):
                        _close_slot(
                            backend, handler, s, slot_fds[s],
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse, slot_ws, slot_ws_state,
                        )
                        continue
                    # Header deadline, sweeping rather than by timerfd. A client
                    # that connects and says nothing produces no read event, so
                    # the check in `_read_headers` can never fire for it and
                    # something has to notice on its own. Unlike the timerfd this
                    # replaces, it also covers a client that stalls midway through
                    # headers on a REUSED connection — that timer was armed on
                    # accept and retired at the first complete header parse.
                    if (
                        config.header_read_timeout > 0
                        and slot_header_start[s] != 0
                        and provision_pool.provisions[s].state.kind
                        == ConnectionState.READING_HEADERS
                        and sweep_now - slot_header_start[s] > header_ns
                    ):
                        if provision_pool.provisions[s].keepalive_count == 0:
                            _send_error_to_fd(slot_fds[s], RequestTimeout())
                        _close_slot(
                            backend, handler, s, slot_fds[s],
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse, slot_ws, slot_ws_state,
                        )

        if should_shutdown:
            # Graceful shutdown: close listener, drain in-flight, close SSE
            try:
                close(listen_fd)
            except:
                pass


            # Tell every streaming client we're going: an SSE close comment,
            # or a WebSocket close frame (1001 going away).
            for s in range(max_conns):
                if (slot_sse[s] or slot_ws[s]) and slot_fds[s] != UNUSED:
                    var farewell: List[UInt8]
                    if slot_ws[s]:
                        farewell = close_frame(WS_CLOSE_GOING_AWAY)
                    else:
                        farewell = List[UInt8](String(": close\n\n").as_bytes())
                    try:
                        _ = send(FileDescriptor(slot_fds[s]), Span(farewell), UInt(len(farewell)), 0)
                    except:
                        pass
                    _close_slot(
                        backend, handler, s, slot_fds[s],
                        slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                        slot_sse, slot_ws, slot_ws_state,
                    )

            # Close the connections that have nothing to drain, before timing
            # anything. `active_count` counts a connection that is merely
            # *open* the same as one with a request in flight, so without this
            # a server holding idle keep-alive connections waited out the
            # whole DRAIN_TIMEOUT_NS budget for clients that had already been
            # answered — measured at 5.02 s to exit against 0.02 s idle, in
            # every execution mode, which is most of `docker stop`'s 10 s.
            #
            # A slot in READING_HEADERS with an empty receive buffer is
            # between requests: `prepare_for_new_request` clears the buffer
            # after each response, and the first byte of the next request
            # both refills it and moves the state on. Such a connection
            # cannot be served by the drain loop under any circumstance —
            # that loop dispatches EVFILT_WRITE only, so a request arriving
            # during the drain is not read there today either. Closing it now
            # therefore drops nothing that waiting would have delivered, and
            # leaves the whole budget to connections genuinely mid-request or
            # mid-response.
            #
            # Skipped, for the reasons the idle and header sweeps skip them:
            # a slot with a job in a pool thread is working, not idle, and its
            # provision is still borrowed by another thread.
            for s in range(max_conns):
                if slot_fds[s] == UNUSED or offload.offloaded[s]:
                    continue
                if (
                    provision_pool.provisions[s].state.kind
                    == ConnectionState.READING_HEADERS
                    and len(provision_pool.provisions[s].recv_buffer) == 0
                ):
                    _close_slot(
                        backend, handler, s, slot_fds[s],
                        slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                        slot_sse, slot_ws, slot_ws_state,
                    )

            # Drain in-flight: wait for active non-SSE connections (max 5s).
            #
            # `offload.inflight` is in the condition as well as `active_count`,
            # and not redundantly: a client that vanished while its request was
            # in a pool thread has already been subtracted from `active_count`,
            # but its slot stays borrowed until the completion arrives. Without
            # the second term a shutdown could leave that job unclaimed.
            # Requests still inside a pool thread are answered here rather than
            # dropped, on the same 5 s budget — `_service_completions` runs on
            # every pass below, before the events are dispatched.
            var drain_start = perf_counter_ns()
            comptime DRAIN_TIMEOUT_NS: Int = 5_000_000_000
            while active_count > 0 or offload.inflight > 0:
                if (perf_counter_ns() - drain_start) > DRAIN_TIMEOUT_NS:
                    break
                # Nothing new is read during the drain, so this only ever
                # sends what the pass that saw the shutdown had buffered —
                # but it must go before this wait, for the reason above.
                _flush_submits(
                    backend, handler, config, server_address, tcp_keep_alive,
                    slot_fds, slot_response, slot_send_offset, slot_header_start,
                    fd_to_slot, provision_pool, active_count, metrics,
                    slot_sse, slot_ws, slot_ws_state, slot_read_armed,
                    slot_idle_deadline, date_cache_sec, date_cache, offload,
                )
                var drain_events = backend.wait(100)
                _service_completions(
                    backend, handler, config, server_address, tcp_keep_alive,
                    slot_fds, slot_response, slot_send_offset, slot_header_start,
                    fd_to_slot, provision_pool, active_count, metrics,
                    slot_sse, slot_ws, slot_ws_state,
                    slot_read_armed, slot_idle_deadline,
                    date_cache_sec, date_cache, offload, bus_read_fd,
                )
                for di in range(drain_events):
                    if (backend.event_flags(di) & EV_ERROR) != 0:
                        continue
                    var drain_ident = Int(backend.event_ident(di))
                    var drain_filter = backend.event_filter(di)
                    # Handle write completions during drain
                    if drain_filter == EVFILT_WRITE:
                        var drain_slot = fd_to_slot[drain_ident] if drain_ident < len(fd_to_slot) else UNUSED
                        if drain_slot != UNUSED:
                            _close_slot(
                                backend, handler, drain_slot, drain_ident,
                                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                                slot_sse, slot_ws, slot_ws_state,
                            )
            # A stream whose head completed DURING the drain — a pool
            # thread answering a streamed WSGI response in its last job —
            # became a streaming slot after the farewell pass above, and
            # the drain loop dispatches EVFILT_WRITE only, so nothing in it
            # would close that connection. Say goodbye to it now, so the
            # producer thread gets its disconnect and comes back before the
            # bounded join, instead of being abandoned as a straggler.
            for s in range(max_conns):
                if (slot_sse[s] or slot_ws[s]) and slot_fds[s] != UNUSED:
                    var late_farewell: List[UInt8]
                    if slot_ws[s]:
                        late_farewell = close_frame(WS_CLOSE_GOING_AWAY)
                    else:
                        late_farewell = List[UInt8](String(": close\n\n").as_bytes())
                    try:
                        _ = send(FileDescriptor(slot_fds[s]), Span(late_farewell), UInt(len(late_farewell)), 0)
                    except:
                        pass
                    _close_slot(
                        backend, handler, s, slot_fds[s],
                        slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                        slot_sse, slot_ws, slot_ws_state,
                    )
            # Once more before returning: the executor's pill goes out on
            # its lane after this loop returns, and it must be FIFO behind
            # every job — a job still buffered here would arrive after the
            # pill and never run.
            _flush_submits(
                backend, handler, config, server_address, tcp_keep_alive,
                slot_fds, slot_response, slot_send_offset, slot_header_start,
                fd_to_slot, provision_pool, active_count, metrics,
                slot_sse, slot_ws, slot_ws_state, slot_read_armed,
                slot_idle_deadline, date_cache_sec, date_cache, offload,
            )
            break


def _handle_read_headers[T: HTTPService, B: EventLoopBackend](
    mut backend: B,
    slot: Int,
    fd_val: Int,
    mut handler: T,
    config: ServerConfig,
    server_address: String,
    tcp_keep_alive: Bool,
    mut slot_fds: List[Int],
    mut slot_response: OwningList[Bytes],
    mut slot_send_offset: List[Int],
    mut slot_header_start: List[Int],
    mut fd_to_slot: List[Int],
    mut provision_pool: ProvisionPool,
    mut active_count: Int,
    mut metrics: ServerMetrics,
    mut slot_sse: List[Bool],
    mut slot_ws: List[Bool],
    mut slot_ws_state: OwningList[WSState],
    mut slot_read_armed: List[Bool],
    mut slot_idle_deadline: List[Int],
    mut date_cache_sec: Int64,
    mut date_cache: String,
    mut offload: OffloadLoopState,
):
    """Read and parse HTTP request headers for a connection slot.

    Called both eagerly from the accept path (to handle data already buffered
    before kqueue registration) and from the EVFILT_READ handler.
    """
    var entry_keepalive = provision_pool.provisions[slot].keepalive_count
    if config.header_read_timeout > 0:
        # 0 means "no request in progress" — the first bytes of a keep-alive
        # request start the clock here rather than inheriting a deadline from
        # whenever the previous response happened to finish.
        if slot_header_start[slot] == 0:
            slot_header_start[slot] = perf_counter_ns()
        var elapsed_s = (perf_counter_ns() - slot_header_start[slot]) / 1_000_000_000
        if elapsed_s >= Int(config.header_read_timeout):
            _send_error_to_fd(fd_val, RequestTimeout())
            _close_slot(
                backend, handler, slot, fd_val,
                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                slot_sse, slot_ws, slot_ws_state,
            )
            return

    # Phase 2a: recv into per-slot staging buffer (avoids per-recv heap alloc)
    provision_pool.provisions[slot].recv_staging.clear()
    var fd_desc = FileDescriptor(fd_val)
    var bytes_read: UInt
    # True only when recv itself RETURNED 0 — the peer's EOF. `bytes_read`
    # alone cannot carry that: the EAGAIN branch below reuses 0 as its
    # "no new data, parse what is buffered" sentinel, and reading THAT as
    # EOF closed every request that was partial at an EAGAIN pass — a
    # dribbled request died on its second byte.
    var recv_eof = False
    try:
        bytes_read = recv(
            fd_desc,
            Span(provision_pool.provisions[slot].recv_staging),
            UInt(provision_pool.provisions[slot].recv_staging.capacity()),
            0,
        )
        recv_eof = bytes_read == 0
    except recv_err:
        if recv_err.isa[RecvEAGAINError]():
            # No new data — check for pipelined data already in recv_buffer.
            if len(provision_pool.provisions[slot].recv_buffer) == 0:
                return
            bytes_read = 0
        else:
            _close_slot(
                backend, handler, slot, fd_val,
                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                slot_sse, slot_ws, slot_ws_state,
            )
            return

    if bytes_read == 0 and len(provision_pool.provisions[slot].recv_buffer) == 0:
        _close_slot(
            backend, handler, slot, fd_val,
            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
            slot_sse, slot_ws, slot_ws_state,
        )
        return

    if recv_eof:
        # recv returning 0 IS the peer's EOF, however the event was
        # flagged. Without this, a preserved pipelined tail holding only a
        # PARTIAL request would re-arm and re-poll a socket that can never
        # complete it — on kqueue a level-triggered event storm until the
        # header timeout — instead of closing at the peer_eof check below.
        provision_pool.provisions[slot].peer_eof = True

    if bytes_read > 0:
        provision_pool.provisions[slot].recv_staging._len = Int(bytes_read)
        provision_pool.provisions[slot].recv_buffer.extend(
            Span(provision_pool.provisions[slot].recv_staging)
        )

    if len(provision_pool.provisions[slot].recv_buffer) > config.recv_buffer_limit():
        _send_error_to_fd(fd_val, BadRequest())
        _close_slot(
            backend, handler, slot, fd_val,
            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
            slot_sse, slot_ws, slot_ws_state,
        )
        return

    var search_start = provision_pool.provisions[slot].last_parse_len
    if search_start > 3:
        search_start -= 3

    var header_end = find_header_end(
        Span(provision_pool.provisions[slot].recv_buffer),
        search_start,
    )

    if header_end:
        var header_end_offset = header_end.value()

        if header_end_offset > config.max_total_header_size:
            _send_error_to_fd(fd_val, HeadersTooLarge())
            _close_slot(
                backend, handler, slot, fd_val,
                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                slot_sse, slot_ws, slot_ws_state,
            )
            return

        var parsed: ParsedRequestHeaders
        try:
            parsed = parse_request_headers(
                Span(provision_pool.provisions[slot].recv_buffer)[:header_end_offset],
                provision_pool.provisions[slot].last_parse_len,
            )
        except parse_err:
            _send_error_to_fd(fd_val, BadRequest())
            _close_slot(
                backend, handler, slot, fd_val,
                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                slot_sse, slot_ws, slot_ws_state,
            )
            return

        if parsed.path.byte_length() > config.max_request_uri_length:
            _send_error_to_fd(fd_val, URITooLong())
            _close_slot(
                backend, handler, slot, fd_val,
                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                slot_sse, slot_ws, slot_ws_state,
            )
            return

        var content_length = parsed.content_length()
        var is_chunked = parsed.is_chunked_body()

        if not is_chunked and content_length > config.max_request_body_size:
            _send_error_to_fd(fd_val, PayloadTooLarge())
            _close_slot(
                backend, handler, slot, fd_val,
                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                slot_sse, slot_ws, slot_ws_state,
            )
            return



        var body_bytes_in_buffer = len(provision_pool.provisions[slot].recv_buffer) - header_end_offset
        provision_pool.provisions[slot].parsed_headers = parsed^

        if content_length > 0 or is_chunked:
            var expect_val = provision_pool.provisions[slot].parsed_headers.value().headers.get(HeaderKey.EXPECT)
            if expect_val:
                if expect_val.value() == "100-continue":
                    _send_raw_to_fd(fd_val, "HTTP/1.1 100 Continue\r\n\r\n".as_bytes())

            var effective_length = config.max_request_body_size if is_chunked else content_length
            # For a chunked body `bytes_read` counts DECODED bytes, and
            # nothing has been decoded yet — the buffered bytes below are
            # still raw. Seeding it with the raw count instead made the
            # resumed decode start past bytes it had never consumed, and the
            # chunk framing in the gap was read as body: a 300 KB upload in
            # 64-byte chunks arrived 12 bytes long, carrying two chunks'
            # `40\r\n...\r\n` inside it.
            provision_pool.provisions[slot].body_state = BodyReadState(
                content_length=effective_length,
                bytes_read=0 if is_chunked else body_bytes_in_buffer,
                header_end_offset=header_end_offset,
                is_chunked=is_chunked,
            )
            # Where this request will end in recv_buffer — knowable now for
            # Content-Length, only at completion for chunked (0 until then).
            # Bytes past it are the next pipelined request; see
            # `ConnectionProvision.request_end`.
            provision_pool.provisions[slot].request_end = (
                0 if is_chunked else header_end_offset + content_length
            )
            provision_pool.provisions[slot].state = ConnectionState.reading_body(effective_length)

            if config.body_read_timeout > 0:
                backend.try_add_timer(UInt(fd_val) + TIMER_BODY, config.body_read_timeout * 1000)

            # Phase 1b: decode whatever of the body arrived with the headers,
            # through the CONNECTION's decoder — the same one the
            # READING_BODY branch resumes. A throwaway decoder here would
            # consume these bytes and then throw away the chunk state it
            # built, leaving the resumed decode to start mid-chunk.
            if is_chunked and body_bytes_in_buffer > 0:
                var ret: Int
                var decoded_size: Int
                ret, decoded_size = provision_pool.provisions[
                    slot
                ].chunk_decoder.decode(
                    Span(provision_pool.provisions[slot].recv_buffer)[
                        header_end_offset:
                    ]
                )
                if ret == -1:
                    _send_error_to_fd(fd_val, BadRequest())
                    _close_slot(backend, handler, slot, fd_val, slot_fds, fd_to_slot, provision_pool, active_count, metrics, slot_sse, slot_ws, slot_ws_state)
                    return
                var leftover = provision_pool.provisions[
                    slot
                ].chunk_decoder.pending_bytes
                provision_pool.provisions[slot].recv_buffer.resize(
                    header_end_offset + decoded_size + leftover, 0
                )
                var body_st0 = provision_pool.provisions[slot].body_state.value()
                body_st0.bytes_read = decoded_size
                provision_pool.provisions[slot].body_state = body_st0
                if ret >= 0:
                    # `pending_bytes` bytes remain past the chunked data —
                    # the next pipelined request. The resize above already
                    # kept exactly them; the resize that used to discard
                    # them here is why a request behind a chunked body was
                    # lost.
                    provision_pool.provisions[slot].request_end = (
                        header_end_offset + decoded_size
                    )
                    var body_st = provision_pool.provisions[slot].body_state.value()
                    body_st.content_length = decoded_size
                    body_st.bytes_read = decoded_size
                    body_st.is_chunked = False
                    provision_pool.provisions[slot].body_state = body_st
                    provision_pool.provisions[slot].state = ConnectionState.processing()
                    _process_request(
                        backend, slot, fd_val, handler,
                        config, server_address, tcp_keep_alive,
                        slot_fds, slot_response, slot_send_offset, slot_header_start,
                        fd_to_slot, provision_pool, active_count, metrics,
                        slot_sse, slot_ws, slot_ws_state,
                        slot_read_armed, slot_idle_deadline,
                        date_cache_sec, date_cache, offload,
                    )
                    return
                # ret == -2: incomplete, wait for EVFILT_READ to fire again
            elif not is_chunked and body_bytes_in_buffer >= content_length:
                provision_pool.provisions[slot].state = ConnectionState.processing()
                _process_request(
                    backend, slot, fd_val,
                    handler,
                    config, server_address, tcp_keep_alive,
                    slot_fds, slot_response, slot_send_offset,
                    slot_header_start,
                    fd_to_slot, provision_pool, active_count, metrics,
                    slot_sse, slot_ws, slot_ws_state,
                    slot_read_armed, slot_idle_deadline,
                    date_cache_sec, date_cache, offload,
                )
        else:
            provision_pool.provisions[slot].request_end = header_end_offset
            provision_pool.provisions[slot].state = ConnectionState.processing()
            _process_request(
                backend, slot, fd_val,
                handler,
                config, server_address, tcp_keep_alive,
                slot_fds, slot_response, slot_send_offset,
                slot_header_start,
                fd_to_slot, provision_pool, active_count, metrics,
                slot_sse, slot_ws, slot_ws_state,
                slot_read_armed, slot_idle_deadline,
                date_cache_sec, date_cache, offload,
            )

    # Headers that can never arrive: the peer half-closed while the request
    # was still incomplete, so waiting for the rest only holds the slot
    # until the header timeout answers 408. Release it now instead. (A
    # partial BODY already closes promptly, on the `bytes_read == 0` path.)
    #
    # Before the re-arm below, and returning: a connection whose peer has
    # gone will never produce the readiness that re-arming asks for.
    if (
        slot_fds[slot] != UNUSED
        and provision_pool.provisions[slot].peer_eof
        and provision_pool.provisions[slot].state.kind
        == ConnectionState.READING_HEADERS
    ):
        _close_slot(
            backend, handler, slot, fd_val,
            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
            slot_sse, slot_ws, slot_ws_state,
        )
        return

    # Still short of a complete request: register read interest for the rest.
    #
    # Nothing else does. The accept path arms EVFILT_READ only while the
    # state is still READING_HEADERS, so a request whose headers completed
    # in the eager read but whose body did not would sit unarmed until the
    # body timer answered 408. The re-registration is unconditional rather
    # than guarded on `slot_read_armed`, because epoll is edge-triggered:
    # the tail of the body is frequently already in the socket buffer, the
    # edge that carried it is spent, and only a fresh EPOLL_CTL_MOD
    # regenerates readiness for bytes that are pending but unread.
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
    if slot_fds[slot] != UNUSED and (
        provision_pool.provisions[slot].state.kind == ConnectionState.READING_BODY
        or provision_pool.provisions[slot].state.kind
        == ConnectionState.READING_HEADERS
    ):
        backend.try_add_read(fd_val)
        slot_read_armed[slot] = True

    # After an inline-completed request the keep-alive reset zeroed
    # `last_parse_len` for the PRESERVED pipelined tail; stamping the buffer
    # length over it would start the next terminator search past headers it
    # has never scanned.
    if provision_pool.provisions[slot].keepalive_count == entry_keepalive:
        provision_pool.provisions[slot].last_parse_len = len(provision_pool.provisions[slot].recv_buffer)


def _drain_pipelined[T: HTTPService, B: EventLoopBackend](
    mut backend: B,
    slot: Int,
    fd_val: Int,
    mut handler: T,
    config: ServerConfig,
    server_address: String,
    tcp_keep_alive: Bool,
    mut slot_fds: List[Int],
    mut slot_response: OwningList[Bytes],
    mut slot_send_offset: List[Int],
    mut slot_header_start: List[Int],
    mut fd_to_slot: List[Int],
    mut provision_pool: ProvisionPool,
    mut active_count: Int,
    mut metrics: ServerMetrics,
    mut slot_sse: List[Bool],
    mut slot_ws: List[Bool],
    mut slot_ws_state: OwningList[WSState],
    mut slot_read_armed: List[Bool],
    mut slot_idle_deadline: List[Int],
    mut date_cache_sec: Int64,
    mut date_cache: String,
    mut offload: OffloadLoopState,
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
        slot_fds[slot] != UNUSED
        and provision_pool.provisions[slot].state.kind
        == ConnectionState.READING_HEADERS
        and len(provision_pool.provisions[slot].recv_buffer) > 0
        and not offload.offloaded[slot]
    ):
        var before = provision_pool.provisions[slot].keepalive_count
        _handle_read_headers(
            backend, slot, fd_val, handler, config,
            server_address, tcp_keep_alive,
            slot_fds, slot_response, slot_send_offset,
            slot_header_start, fd_to_slot, provision_pool,
            active_count, metrics, slot_sse, slot_ws, slot_ws_state,
            slot_read_armed, slot_idle_deadline,
            date_cache_sec, date_cache, offload,
        )
        if (
            slot_fds[slot] == UNUSED
            or provision_pool.provisions[slot].keepalive_count == before
        ):
            break


def _process_request[T: HTTPService, B: EventLoopBackend](
    mut backend: B,
    slot: Int,
    fd_val: Int,
    mut handler: T,
    config: ServerConfig,
    server_address: String,
    tcp_keep_alive: Bool,
    mut slot_fds: List[Int],
    mut slot_response: OwningList[Bytes],
    mut slot_send_offset: List[Int],
    mut slot_header_start: List[Int],
    mut fd_to_slot: List[Int],
    mut provision_pool: ProvisionPool,
    mut active_count: Int,
    mut metrics: ServerMetrics,
    mut slot_sse: List[Bool],
    mut slot_ws: List[Bool],
    mut slot_ws_state: OwningList[WSState],
    mut slot_read_armed: List[Bool],
    mut slot_idle_deadline: List[Int],
    mut date_cache_sec: Int64,
    mut date_cache: String,
    mut offload: OffloadLoopState,
):
    """Build request, call handler, encode response, register for write."""
    var parsed = provision_pool.provisions[slot].parsed_headers.take()

    var body = Bytes()
    if provision_pool.provisions[slot].body_state:
        var body_st = provision_pool.provisions[slot].body_state.value()
        var body_start = body_st.header_end_offset
        var body_end = body_start + body_st.content_length
        if body_end <= len(provision_pool.provisions[slot].recv_buffer):
            body = Bytes(capacity=body_st.content_length)
            unsafe_memcpy(
                dest=body.unsafe_ptr(),
                src=provision_pool.provisions[slot].recv_buffer.unsafe_ptr().unsafe_offset(body_start),
                count=body_st.content_length,
            )
            body._len = body_st.content_length

    var request: HTTPRequest
    try:
        request = HTTPRequest.from_parsed(
            server_address,
            parsed^,
            body^,
            config.max_request_uri_length,
        )
    except from_parsed_err:
        _send_error_to_fd(fd_val, BadRequest())
        _close_slot(
            backend, handler, slot, fd_val,
            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
            slot_sse, slot_ws, slot_ws_state,
        )
        return

    request.slot_id = slot
    request.remote_addr = provision_pool.provisions[slot].peer_host
    request.remote_port = provision_pool.provisions[slot].peer_port
    provision_pool.provisions[slot].should_close = (not tcp_keep_alive) or request.connection_close()
    var request_method = request.method
    var request_path = request.uri.path

    # Recorded before the handler runs, because under `--blocking-threads` the
    # request itself is about to belong to another thread and neither of these
    # can be read back at completion time.
    offload.is_head[slot] = request_method == "HEAD"
    offload.http11[slot] = request.protocol == strHttp11
    if config.access_log:
        provision_pool.provisions[slot].log_method = request_method
        provision_pool.provisions[slot].log_path = request_path

    var response: HTTPResponse

    # Phase 4e: intercept /__metrics before user handler
    if config.enable_metrics and request_path == "/__metrics":
        metrics.active_connections = active_count
        metrics.pool_available = provision_pool.available_count()
        var body = metrics.to_text()
        response = HTTPResponse(
            body.as_bytes(),
            status_code=200,
            status_text="OK",
        )
        response.headers["Content-Type"] = "text/plain; version=0.0.4; charset=utf-8"
        provision_pool.provisions[slot].should_close = False
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
            if offload.accepting():
                ref pool = offload.pool()[]
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
                    offload.offloaded[slot] = True
                    offload.inflight += 1
                    slot_idle_deadline[slot] = 0
                    if offload.queue_submit(slot, lane):
                        # The lane's batch is full: send it now, and run
                        # inline whatever it could not carry — the same
                        # answer a refused `submit` always had. This path
                        # is non-raising like the rest of the read side; a
                        # raise inside the inline run is a handler that
                        # already answered 500 and closed, so it is logged
                        # rather than propagated.
                        try:
                            _ = _run_inline(
                                backend, handler, config, server_address,
                                tcp_keep_alive, slot_fds, slot_response,
                                slot_send_offset, slot_header_start, fd_to_slot,
                                provision_pool, active_count, metrics, slot_sse,
                                slot_ws, slot_ws_state, slot_read_armed,
                                slot_idle_deadline, date_cache_sec, date_cache,
                                offload, offload.flush_lane(lane),
                            )
                        except e:
                            print("event loop: inline run raised: " + String(e), flush=True)
                    return
                if pool.submit(slot, target):
                    offload.offloaded[slot] = True
                    offload.inflight += 1
                    # A stale deadline from the PREVIOUS request on this
                    # connection would sweep the slot closed while a pool
                    # thread still owned it. The connection is not idle; it
                    # is working.
                    slot_idle_deadline[slot] = 0
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
                provision_pool.provisions[slot].should_close = True

        # After hook: add headers, log, etc.
        handler.after_response(request_method, request_path, response)

    _finish_response(
        backend, slot, fd_val, handler, config, server_address, tcp_keep_alive,
        slot_fds, slot_response, slot_send_offset, slot_header_start,
        fd_to_slot, provision_pool, active_count, metrics,
        slot_sse, slot_ws, slot_ws_state, slot_read_armed, slot_idle_deadline,
        date_cache_sec, date_cache, offload, response^,
    )


def _flush_submits[T: HTTPService, B: EventLoopBackend](
    mut backend: B,
    mut handler: T,
    config: ServerConfig,
    server_address: String,
    tcp_keep_alive: Bool,
    mut slot_fds: List[Int],
    mut slot_response: OwningList[Bytes],
    mut slot_send_offset: List[Int],
    mut slot_header_start: List[Int],
    mut fd_to_slot: List[Int],
    mut provision_pool: ProvisionPool,
    mut active_count: Int,
    mut metrics: ServerMetrics,
    mut slot_sse: List[Bool],
    mut slot_ws: List[Bool],
    mut slot_ws_state: OwningList[WSState],
    mut slot_read_armed: List[Bool],
    mut slot_idle_deadline: List[Int],
    mut date_cache_sec: Int64,
    mut date_cache: String,
    mut offload: OffloadLoopState,
) raises:
    """Send every executor lane's buffered submits; run inline what would
    not go.

    "Leave it parked and retry next pass" is not an option: a slot in the
    loop's buffer is invisible to everything that reads `offloaded` as "a
    worker owns it" — the shutdown drain would wait on `inflight` for a
    completion that cannot come, a pill sent meanwhile would outrun it,
    and `wait(1000)` would stall the retry by a second. So a refused batch
    is exactly what a refused `submit` always was: those requests run on
    the loop, which never drops a request. It cannot fill in practice
    (`accepting()` bounds the channel to 256 jobs, and batching shrinks the
    datagram count further); this is the backstop.
    """
    if not offload.enabled() or offload.pending_submit_count == 0:
        return
    _ = _run_inline(
        backend, handler, config, server_address, tcp_keep_alive,
        slot_fds, slot_response, slot_send_offset, slot_header_start,
        fd_to_slot, provision_pool, active_count, metrics,
        slot_sse, slot_ws, slot_ws_state, slot_read_armed,
        slot_idle_deadline, date_cache_sec, date_cache, offload,
        offload.flush_submits(),
    )


def _run_inline[T: HTTPService, B: EventLoopBackend](
    mut backend: B,
    mut handler: T,
    config: ServerConfig,
    server_address: String,
    tcp_keep_alive: Bool,
    mut slot_fds: List[Int],
    mut slot_response: OwningList[Bytes],
    mut slot_send_offset: List[Int],
    mut slot_header_start: List[Int],
    mut fd_to_slot: List[Int],
    mut provision_pool: ProvisionPool,
    mut active_count: Int,
    mut metrics: ServerMetrics,
    mut slot_sse: List[Bool],
    mut slot_ws: List[Bool],
    mut slot_ws_state: OwningList[WSState],
    mut slot_read_armed: List[Bool],
    mut slot_idle_deadline: List[Int],
    mut date_cache_sec: Int64,
    mut date_cache: String,
    mut offload: OffloadLoopState,
    slots: List[Int],
) raises -> Int:
    """Run parked requests on the loop: `_process_request`'s queue-full tail,
    applied to the slots a batch could not carry. Returns how many ran."""
    if len(slots) == 0:
        return 0
    ref pool = offload.pool()[]
    for i in range(len(slots)):
        var slot = slots[i]
        if slot < 0 or slot >= len(slot_fds) or not offload.offloaded[slot]:
            continue
        offload.offloaded[slot] = False
        offload.inflight -= 1
        var request = pool.unpark_request(slot)
        if slot_fds[slot] == UNUSED:
            # The client left while its request sat in the buffer; nothing
            # to answer, and the provision is released as an abandoned
            # completion's would be.
            pool.discard(slot)
            provision_pool.release(slot)
            continue
        var request_method = request.method
        var request_path = request.uri.path
        var response: HTTPResponse
        try:
            response = handler.func(request^)
        except:
            response = InternalError()
            provision_pool.provisions[slot].should_close = True
        handler.after_response(request_method, request_path, response)
        _finish_response(
            backend, slot, slot_fds[slot], handler, config, server_address,
            tcp_keep_alive,
            slot_fds, slot_response, slot_send_offset, slot_header_start,
            fd_to_slot, provision_pool, active_count, metrics,
            slot_sse, slot_ws, slot_ws_state, slot_read_armed, slot_idle_deadline,
            date_cache_sec, date_cache, offload, response^,
        )
        _drain_pipelined(
            backend, slot, slot_fds[slot], handler, config,
            server_address, tcp_keep_alive,
            slot_fds, slot_response, slot_send_offset,
            slot_header_start, fd_to_slot, provision_pool,
            active_count, metrics, slot_sse, slot_ws, slot_ws_state,
            slot_read_armed, slot_idle_deadline,
            date_cache_sec, date_cache, offload,
        )
    return len(slots)


def _service_completions[T: HTTPService, B: EventLoopBackend](
    mut backend: B,
    mut handler: T,
    config: ServerConfig,
    server_address: String,
    tcp_keep_alive: Bool,
    mut slot_fds: List[Int],
    mut slot_response: OwningList[Bytes],
    mut slot_send_offset: List[Int],
    mut slot_header_start: List[Int],
    mut fd_to_slot: List[Int],
    mut provision_pool: ProvisionPool,
    mut active_count: Int,
    mut metrics: ServerMetrics,
    mut slot_sse: List[Bool],
    mut slot_ws: List[Bool],
    mut slot_ws_state: OwningList[WSState],
    mut slot_read_armed: List[Bool],
    mut slot_idle_deadline: List[Int],
    mut date_cache_sec: Int64,
    mut date_cache: String,
    mut offload: OffloadLoopState,
    bus_read_fd: Int = -1,
) raises:
    """Take every finished job off the completion channel and answer it.

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
    if not offload.enabled():
        return
    ref pool = offload.pool()[]
    var finished = pool.drain_completions()
    var aborts = pool.take_aborts()
    for f in range(len(finished)):
        var slot = finished[f]
        if slot < 0 or slot >= len(slot_fds):
            continue
        if not offload.offloaded[slot]:
            continue
        offload.offloaded[slot] = False
        offload.inflight -= 1
        if not pool.has_response(slot):
            # A pool thread completed without parking a response. Nothing can
            # produce this today; if it ever does, the slot is freed rather
            # than leaked and the connection is closed rather than hung.
            pool.discard(slot)
            if slot_fds[slot] == UNUSED:
                provision_pool.release(slot)
            else:
                _close_slot(
                    backend, handler, slot, slot_fds[slot],
                    slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                    slot_sse, slot_ws, slot_ws_state,
                )
            continue
        var response = pool.take_response(slot)
        # The synchronous path sets this when `func` raises; the pool thread
        # cannot reach the provision, so it reports and the loop applies it.
        if pool.raised(slot):
            provision_pool.provisions[slot].should_close = True
        if slot_fds[slot] == UNUSED:
            # Abandoned mid-flight: the response has nowhere to go, and this
            # is the point at which the slot is finally safe to reuse.
            pool.discard(slot)
            provision_pool.release(slot)
            continue
        if response.sse_streaming and bus_read_fd >= 0 and offload.slot_channel_stream(slot):
            # Begin-before-head, made deterministic. The producer sent its
            # begin frame on the chunk channel BEFORE this completion, so
            # the datagram is in that socket now — but whether this pass's
            # event batch happens to carry the chunk channel's readiness
            # ahead of the completion's is the kernel's ready-list order,
            # not ours. Draining it here, before the head goes out, means
            # the handler is subscribed before the slot can ever be seen
            # streaming, whatever order the events arrived in.
            var begin_frames = drain_bus_channel(bus_read_fd)
            for bf in range(len(begin_frames)):
                handler.sse_peer_frame(
                    begin_frames[bf].url,
                    begin_frames[bf].event_id,
                    begin_frames[bf].frame,
                )
        _finish_response(
            backend, slot, slot_fds[slot], handler, config, server_address,
            tcp_keep_alive,
            slot_fds, slot_response, slot_send_offset, slot_header_start,
            fd_to_slot, provision_pool, active_count, metrics,
            slot_sse, slot_ws, slot_ws_state, slot_read_armed, slot_idle_deadline,
            date_cache_sec, date_cache, offload, response^,
        )
        # A request pipelined behind the one this pool thread just answered
        # is already in recv_buffer; nothing else will ever announce it.
        _drain_pipelined(
            backend, slot, slot_fds[slot], handler, config,
            server_address, tcp_keep_alive,
            slot_fds, slot_response, slot_send_offset,
            slot_header_start, fd_to_slot, provision_pool,
            active_count, metrics, slot_sse, slot_ws, slot_ws_state,
            slot_read_armed, slot_idle_deadline,
            date_cache_sec, date_cache, offload,
        )


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
        if abort_slot < 0 or abort_slot >= len(slot_fds):
            continue
        if slot_fds[abort_slot] == UNUSED or not (
            slot_sse[abort_slot] or slot_ws[abort_slot]
        ):
            continue
        if offload.stream_gen[abort_slot] != abort_gen:
            continue
        var last = handler.sse_drain_slot(abort_slot)
        if len(last) > 0:
            var out = encode_chunk(Span(last)) if offload.chunked[abort_slot] else Bytes(Span(last))
            try:
                _ = send(FileDescriptor(slot_fds[abort_slot]), Span(out), UInt(len(out)), 0)
            except:
                pass
        offload.clear_stream(abort_slot)
        _close_slot(
            backend, handler, abort_slot, slot_fds[abort_slot],
            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
            slot_sse, slot_ws, slot_ws_state,
        )


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
            # Neither progress nor a reason: treat as would-block rather
            # than spinning the loop on this connection forever.
            return BODY_FD_MORE

    provision.close_body_fd()
    return BODY_FD_DONE


def _finish_response[T: HTTPService, B: EventLoopBackend](
    mut backend: B,
    slot: Int,
    fd_val: Int,
    mut handler: T,
    config: ServerConfig,
    server_address: String,
    tcp_keep_alive: Bool,
    mut slot_fds: List[Int],
    mut slot_response: OwningList[Bytes],
    mut slot_send_offset: List[Int],
    mut slot_header_start: List[Int],
    mut fd_to_slot: List[Int],
    mut provision_pool: ProvisionPool,
    mut active_count: Int,
    mut metrics: ServerMetrics,
    mut slot_sse: List[Bool],
    mut slot_ws: List[Bool],
    mut slot_ws_state: OwningList[WSState],
    mut slot_read_armed: List[Bool],
    mut slot_idle_deadline: List[Int],
    mut date_cache_sec: Int64,
    mut date_cache: String,
    mut offload: OffloadLoopState,
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
    if response.sse_streaming:
        slot_sse[slot] = True
        provision_pool.provisions[slot].should_close = False

    # A 101 with Upgrade: websocket switches this connection to frame mode
    # once the handshake response is on the wire (see _after_send).
    var upgraded_ws = is_ws_upgrade_response(response)
    if upgraded_ws:
        slot_ws[slot] = True
        slot_ws_state[slot].reset()
        provision_pool.provisions[slot].should_close = False
        # A 1xx response carries no body: drop the defaulted entity headers.
        response.headers.pop("content-length")
        response.headers.pop("content-type")

    if (not provision_pool.provisions[slot].should_close) and (config.max_keepalive_requests > 0):
        if (provision_pool.provisions[slot].keepalive_count + 1) >= config.max_keepalive_requests:
            provision_pool.provisions[slot].should_close = True

    # RFC 9110 §9.3.2: HEAD response must not contain a body. The headers
    # stay as they are — including Content-Length, which must describe the
    # body a GET would have returned — so an fd-backed body is dropped by
    # closing the file rather than by rewriting the head.
    if offload.is_head[slot]:
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
    elif provision_pool.provisions[slot].should_close:
        response.set_connection_close()
    else:
        response.set_connection_keep_alive()

    var response_status = response.status_code
    provision_pool.provisions[slot].response_status = response_status

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
    offload.ack_payload[slot] = 0
    if offload.ack_owed[slot] > 0:
        offload.ack_owed[slot] = 0
        offload.ack_owed_count -= 1
    if response.sse_streaming:
        response.headers.pop("content-length")
        var asgi_stream = offload.slot_channel_stream(slot)
        # The head names its stream's generation; an abort datagram is
        # checked against this, so one for an earlier stream on a recycled
        # slot cannot close this connection.
        if slot < len(offload.stream_gen):
            offload.stream_gen[slot] = response.stream_gen
        # RFC 9110 §6.4.1: a 1xx, 204 or 304 carries no body at all, so
        # there is nothing to frame and a `0\r\n\r\n` would itself be a
        # body. An application streaming into one of these is already
        # wrong, but framing it turns "wrong" into "unparseable", and the
        # reader would hang waiting for a terminator on a message the
        # status says is already complete.
        var bodiless = (
            response.status_code == 204
            or response.status_code == 304
            or (response.status_code >= 100 and response.status_code < 200)
        )
        var can_chunk = (
            asgi_stream
            and offload.http11[slot]
            and not offload.is_head[slot]
            and not upgraded_ws
            and not bodiless
        )
        # Written unconditionally: a recycled slot must not inherit the
        # previous connection's framing.
        offload.chunked[slot] = can_chunk
        if can_chunk:
            response.headers[HeaderKey.TRANSFER_ENCODING] = "chunked"
    else:
        offload.chunked[slot] = False
        # Not a stream: whatever channel-stream state the slot carried is
        # over. Defensive — every ending path clears it too.
        offload.clear_stream(slot)

    if upgraded_ws and slot < len(offload.stream_gen):
        # A socket's generation, recorded for the same reason a stream's is
        # above: an abort names a slot AND a generation, so one meant for
        # the connection this slot used to hold cannot close the one it
        # holds now. AFTER the clear, not before — a 101 is not an
        # `sse_streaming` response, so it takes the `else` branch, which
        # clears exactly this. Its absence is what made an executor's abort
        # of a socket a silent no-op, and a WebSocket frame the chunk
        # channel would not take therefore a connection that never closed.
        offload.stream_gen[slot] = response.stream_gen

    # Stamp the Date header from the loop's per-second cache (encode()
    # would otherwise format a fresh date string for every response).
    if HeaderKey.DATE not in response.headers:
        var now_s = unix_now()
        if now_s != date_cache_sec:
            date_cache_sec = now_s
            date_cache = http_date_from_unix(now_s)
        response.headers[HeaderKey.DATE] = date_cache

    # Encode into the slot's spare buffer rather than allocating a fresh one.
    # `_after_send` parks the just-sent buffer back here, so one allocation
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

    var scratch = Bytes()
    swap(provision_pool.provisions[slot].encoding_buffer, scratch)
    slot_response[slot] = response^.encode_into(scratch^)
    slot_send_offset[slot] = 0
    provision_pool.provisions[slot].close_body_fd()
    if file_fd >= 0:
        provision_pool.provisions[slot].body_fd = file_fd
        provision_pool.provisions[slot].body_fd_offset = file_off
        provision_pool.provisions[slot].body_fd_remaining = file_len

    # The access log's method and path were recorded in `_process_request`,
    # before the request could leave this thread.
    provision_pool.provisions[slot].state = ConnectionState.responding()

    var response_len = len(slot_response[slot])

    # Eager send: macOS kqueue EVFILT_WRITE is edge-triggered at registration time
    # and won't fire for a socket that was already writable before the filter was
    # added. Attempt an immediate send; fall back to kqueue only on EAGAIN.
    if response_len > 0:
        var fd_desc = FileDescriptor(fd_val)
        try:
            var sent = send(fd_desc, Span(slot_response[slot]), UInt(response_len), 0)
            slot_send_offset[slot] = Int(sent)
        except send_err:
            if not send_err.isa[SendEAGAINError]():
                _close_slot(
                    backend, handler, slot, fd_val,
                    slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                    slot_sse, slot_ws, slot_ws_state,
                )
                return
            # EAGAIN: fall through to register EVFILT_WRITE

    if slot_send_offset[slot] >= response_len:
        # The head has landed. A file body, if any, follows it — the two
        # are separate transfers and this is the ordering between them.
        var pumped = _pump_body_fd(provision_pool.provisions[slot], fd_val)
        if pumped == BODY_FD_FATAL:
            _close_slot(
                backend, handler, slot, fd_val,
                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                slot_sse, slot_ws, slot_ws_state,
            )
            return
        if pumped == BODY_FD_DONE:
            _after_send(
                backend, slot, fd_val,
                handler, config, server_address, tcp_keep_alive,
                slot_fds, slot_response, slot_send_offset,
                slot_header_start,
                fd_to_slot, provision_pool, active_count, metrics,
                slot_sse, slot_ws, slot_ws_state,
                slot_read_armed, slot_idle_deadline,
            )
            return
        # else: more of the file is owed — fall through and wait for
        # writability exactly as a partial head send does.

    # Partial send or EAGAIN: register EVFILT_WRITE for the remainder.
    try:
        backend.add_write_oneshot(fd_val)
        slot_read_armed[slot] = False
    except:
        _close_slot(
            backend, handler, slot, fd_val,
            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
            slot_sse, slot_ws, slot_ws_state,
        )


def _after_send[T: HTTPService, B: EventLoopBackend](
    mut backend: B,
    slot: Int,
    fd_val: Int,
    mut handler: T,
    config: ServerConfig,
    server_address: String,
    tcp_keep_alive: Bool,
    mut slot_fds: List[Int],
    mut slot_response: OwningList[Bytes],
    mut slot_send_offset: List[Int],
    mut slot_header_start: List[Int],
    mut fd_to_slot: List[Int],
    mut provision_pool: ProvisionPool,
    mut active_count: Int,
    mut metrics: ServerMetrics,
    mut slot_sse: List[Bool],
    mut slot_ws: List[Bool],
    mut slot_ws_state: OwningList[WSState],
    mut slot_read_armed: List[Bool],
    mut slot_idle_deadline: List[Int],
):
    """Handle post-send: close or transition to keep-alive."""
    # Phase 4e: record completed response metrics
    if config.enable_metrics:
        metrics.record_response(
            provision_pool.provisions[slot].response_status,
            slot_send_offset[slot],
        )
        metrics.active_connections = active_count
    if provision_pool.provisions[slot].should_close:
        if config.access_log and provision_pool.provisions[slot].log_method.byte_length() > 0:
            var elapsed_us = Int((perf_counter_ns() - slot_header_start[slot]) / 1000)
            log_access(
                provision_pool.provisions[slot].log_method,
                provision_pool.provisions[slot].log_path,
                provision_pool.provisions[slot].response_status,
                elapsed_us,
                slot_send_offset[slot],
            )
        _close_slot(
            backend, handler, slot, fd_val,
            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
            slot_sse, slot_ws, slot_ws_state,
        )
        return

    if (config.max_keepalive_requests > 0) and (provision_pool.provisions[slot].keepalive_count >= config.max_keepalive_requests):
        if config.access_log and provision_pool.provisions[slot].log_method.byte_length() > 0:
            var elapsed_us = Int((perf_counter_ns() - slot_header_start[slot]) / 1000)
            log_access(
                provision_pool.provisions[slot].log_method,
                provision_pool.provisions[slot].log_path,
                provision_pool.provisions[slot].response_status,
                elapsed_us,
                slot_send_offset[slot],
            )
        _close_slot(
            backend, handler, slot, fd_val,
            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
            slot_sse, slot_ws, slot_ws_state,
        )
        return

    # Phase 4d: emit structured access log before resetting provision state
    if config.access_log and provision_pool.provisions[slot].log_method.byte_length() > 0:
        var elapsed_us = Int((perf_counter_ns() - slot_header_start[slot]) / 1000)
        log_access(
            provision_pool.provisions[slot].log_method,
            provision_pool.provisions[slot].log_path,
            provision_pool.provisions[slot].response_status,
            elapsed_us,
            slot_send_offset[slot],
        )

    # WebSocket: the 101 (or a pushed frame) is on the wire — sit in frame
    # mode. Reads now mean frames, not a new HTTP request, and the idle
    # timeout no longer applies (an idle WebSocket is healthy; heartbeat
    # pings discover dead ones).
    if slot_ws[slot]:
        slot_response[slot] = Bytes()
        slot_send_offset[slot] = 0
        provision_pool.provisions[slot].state = ConnectionState.streaming_ws()
        slot_idle_deadline[slot] = 0
        if not slot_read_armed[slot]:
            backend.try_add_read(fd_val)
            slot_read_armed[slot] = True
        if config.sse_heartbeat_ms > 0:
            backend.try_add_timer(UInt(fd_val) + TIMER_SSE_HEARTBEAT, config.sse_heartbeat_ms)
        return

    # SSE streaming: after initial response (or a pushed event) is sent,
    # enter idle streaming state instead of returning to READING_HEADERS.
    if slot_sse[slot]:
        slot_response[slot] = Bytes()
        slot_send_offset[slot] = 0
        provision_pool.provisions[slot].state = ConnectionState.streaming_sse()
        # A stale idle deadline from the keep-alive request that preceded the
        # stream open would sweep the stream closed mid-flight.
        slot_idle_deadline[slot] = 0
        # Register EVFILT_READ for client disconnect detection (recv→0)
        if not slot_read_armed[slot]:
            backend.try_add_read(fd_val)
            slot_read_armed[slot] = True
        # Set up heartbeat timer (configurable interval, repeating)
        if config.sse_heartbeat_ms > 0:
            backend.try_add_timer(UInt(fd_val) + TIMER_SSE_HEARTBEAT, config.sse_heartbeat_ms)
        return

    # Keep-alive: prepare for next request
    provision_pool.provisions[slot].keepalive_count += 1
    provision_pool.provisions[slot].prepare_for_new_request(keep_pipelined=True)
    # Park the buffer just sent as the slot's encode scratch instead of
    # dropping its allocation. The swap hands back whatever was parked
    # there — the empty stand-in `_process_request` left behind — so the
    # two rotate for the life of the connection.
    swap(slot_response[slot], provision_pool.provisions[slot].encoding_buffer)
    slot_response[slot].clear()
    slot_send_offset[slot] = 0
    # Not perf_counter_ns(): the header deadline governs how long a client may
    # take to SEND a request, not how long it may wait before starting one.
    # Stamping it here made every keep-alive gap longer than header_read_timeout
    # answer 408 to a request the client had just sent perfectly promptly.
    slot_header_start[slot] = 0

    if config.idle_timeout > 0:
        slot_idle_deadline[slot] = perf_counter_ns() + config.idle_timeout * 1_000_000_000

    # Register EVFILT_READ for the next keep-alive request — unless it is
    # still armed from this cycle (registrations are persistent; only
    # add_write_oneshot disarms them, and that path clears the flag).
    if not slot_read_armed[slot]:
        backend.try_add_read(fd_val)
        slot_read_armed[slot] = True


def _close_slot[T: HTTPService, B: EventLoopBackend](
    mut backend: B,
    mut handler: T,
    slot: Int,
    fd_val: Int,
    mut slot_fds: List[Int],
    mut fd_to_slot: List[Int],
    mut provision_pool: ProvisionPool,
    mut active_count: Int,
    mut metrics: ServerMetrics,
    mut slot_sse: List[Bool],
    mut slot_ws: List[Bool],
    mut slot_ws_state: OwningList[WSState],
    release_provision: Bool = True,
):
    """Close a connection and release its slot.

    Notifies the handler's `sse_slot_disconnected` hook when the slot was in
    SSE streaming mode, whatever path led here — EV_EOF, a failed write, a
    dead heartbeat, timeouts, shutdown. This is the single point that keeps
    the handler's subscriber registry from retaining a stale subscription
    (and, once the slot is reused, misdirecting queued bytes) after a client
    vanishes without the clean recv→0 the read path handles.

    `release_provision=False` is the escape valve for closing a slot whose
    request is out on a `--blocking-threads` pool thread: everything here
    still runs — the fd is closed, the registrations dropped, the slot
    marked UNUSED — but the provision stays borrowed, because a pool thread
    still holds a reference into this slot's job storage, and releasing it
    would hand the slot to the next connection while another thread was
    still writing into it. A completion that finds `slot_fds[slot] ==
    UNUSED` releases it then.

    As of the half-close fix NOTHING passes it. The read path used to
    detach a half-closed offloaded slot this way, which dropped the
    response the pool thread was about to complete; it now marks
    `peer_eof` and keeps the fd attached for the completion to answer
    through. The parameter and the UNUSED-completion handling stay,
    because the borrow rule they encode is what any future path that must
    close an offloaded slot's fd has to obey.
    """
    if slot_sse[slot] or slot_ws[slot]:
        # One disconnect hook serves both stream kinds — the handler-side
        # cleanup (drop the subscription, forget the slot) is identical.
        handler.sse_slot_disconnected(slot)
    backend.try_delete_read(fd_val)
    backend.try_delete_write(fd_val)
    backend.try_delete_timer(UInt(fd_val) + TIMER_BODY)
    # No TIMER_IDLE delete: idle timeouts are deadline-swept by the loop,
    # never armed as backend timers (see slot_idle_deadline).
    backend.try_delete_timer(UInt(fd_val) + TIMER_SSE_HEARTBEAT)
    slot_sse[slot] = False
    slot_ws[slot] = False
    slot_ws_state[slot].reset()
    # A client that vanished mid-transfer still leaves an open file behind.
    # This is the one place every close goes through, which is why the
    # release lives here rather than beside each caller.
    provision_pool.provisions[slot].close_body_fd()

    try:
        close(FileDescriptor(fd_val))
    except:
        pass

    slot_fds[slot] = UNUSED
    if fd_val < len(fd_to_slot):
        fd_to_slot[fd_val] = UNUSED
    provision_pool.provisions[slot].prepare_for_new_request()
    provision_pool.provisions[slot].keepalive_count = 0
    if release_provision:
        provision_pool.release(slot)
    active_count -= 1
    metrics.closes_total += 1


def _send_error_to_fd(fd_val: Int, var response: HTTPResponse):
    """Best-effort send an error response on a raw fd."""
    var encoded = encode(response^)
    try:
        _ = send(
            FileDescriptor(fd_val),
            Span(encoded),
            UInt(len(encoded)),
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
            UInt(len(data)),
            0,
        )
    except:
        pass
