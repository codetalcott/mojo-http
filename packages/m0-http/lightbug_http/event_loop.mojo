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
                    date_cache_sec, date_cache, offload,
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
                    if not hb_is_ws and offload.slot_is_executor(hb_slot):
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
                        _close_slot(
                            backend, handler, slot, fd_val,
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse, slot_ws, slot_ws_state,
                            release_provision=False,
                        )
                    else:
                        # A pipelined request arrived mid-flight. Both backends
                        # are edge-triggered, so consuming this event without
                        # reading would lose the only edge those bytes ever
                        # get; clearing the armed flag makes `_after_send`
                        # re-register, which regenerates readiness for them.
                        slot_read_armed[slot] = False
                    continue

                if (backend.event_flags(i) & EV_EOF) != 0:
                    _close_slot(
                        backend, handler, slot, fd_val,
                        slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                        slot_sse, slot_ws, slot_ws_state,
                    )
                    continue

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

                    # Phase 1b: chunked body decode attempt
                    if body_st.is_chunked:
                        var raw_body_start = body_st.header_end_offset
                        var raw_body_len = len(provision_pool.provisions[slot].recv_buffer) - raw_body_start
                        if raw_body_len > config.max_request_body_size:
                            _send_error_to_fd(fd_val, PayloadTooLarge())
                            _close_slot(backend, handler, slot, fd_val, slot_fds, fd_to_slot, provision_pool, active_count, metrics, slot_sse, slot_ws, slot_ws_state)
                            continue
                        if raw_body_len > 0:
                            var chunk_buf = Bytes(capacity=raw_body_len)
                            for j in range(raw_body_start, len(provision_pool.provisions[slot].recv_buffer)):
                                chunk_buf.append(provision_pool.provisions[slot].recv_buffer[j])
                            var decoder = HTTPChunkedDecoder()
                            var (ret, decoded_size) = decoder.decode(Span(chunk_buf))
                            if ret == -1:
                                _send_error_to_fd(fd_val, BadRequest())
                                _close_slot(backend, handler, slot, fd_val, slot_fds, fd_to_slot, provision_pool, active_count, metrics, slot_sse, slot_ws, slot_ws_state)
                                continue
                            elif ret >= 0:
                                var new_buf = Bytes(capacity=raw_body_start + decoded_size)
                                for j in range(raw_body_start):
                                    new_buf.append(provision_pool.provisions[slot].recv_buffer[j])
                                for j in range(decoded_size):
                                    new_buf.append(chunk_buf[j])
                                provision_pool.provisions[slot].recv_buffer = new_buf^
                                body_st.content_length = decoded_size
                                body_st.bytes_read = decoded_size
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
                    if offload.ack_payload[slot] > 0 and offload.slot_is_executor(slot):
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
            var can_ack = offload.enabled() and offload.pool()[].stream_active()
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
                # An executor's stream (asked per slot: a held stream on
                # another mount is drained by the same pass and is none of
                # this): drained bytes are acked back to the producer's
                # credit window, and `sse_is_streaming` — unread by the loop
                # anywhere else — becomes the end-of-stream signal: the
                # handler unsubscribes once the final chunk has been handed
                # out, and the loop closes after those bytes land. Close is
                # how a content-length-free streamed body ends.
                var asgi_stream = offload.slot_is_executor(s)
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
                    _close_slot(
                        backend, handler, s, slot_fds[s],
                        slot_fds, fd_to_slot, provision_pool,
                        active_count, metrics,
                        slot_sse, slot_ws, slot_ws_state,
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
                var drain_events = backend.wait(100)
                _service_completions(
                    backend, handler, config, server_address, tcp_keep_alive,
                    slot_fds, slot_response, slot_send_offset, slot_header_start,
                    fd_to_slot, provision_pool, active_count, metrics,
                    slot_sse, slot_ws, slot_ws_state,
                    slot_read_armed, slot_idle_deadline,
                    date_cache_sec, date_cache, offload,
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
    try:
        bytes_read = recv(
            fd_desc,
            Span(provision_pool.provisions[slot].recv_staging),
            UInt(provision_pool.provisions[slot].recv_staging.capacity()),
            0,
        )
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
            provision_pool.provisions[slot].body_state = BodyReadState(
                content_length=effective_length,
                bytes_read=body_bytes_in_buffer,
                header_end_offset=header_end_offset,
                is_chunked=is_chunked,
            )
            provision_pool.provisions[slot].state = ConnectionState.reading_body(effective_length)

            if config.body_read_timeout > 0:
                backend.try_add_timer(UInt(fd_val) + TIMER_BODY, config.body_read_timeout * 1000)

            # Phase 1b: attempt immediate chunked decode on bytes already buffered
            if is_chunked and body_bytes_in_buffer > 0:
                var chunk_buf = Bytes(capacity=body_bytes_in_buffer)
                for j in range(header_end_offset, len(provision_pool.provisions[slot].recv_buffer)):
                    chunk_buf.append(provision_pool.provisions[slot].recv_buffer[j])
                var decoder = HTTPChunkedDecoder()
                var (ret, decoded_size) = decoder.decode(Span(chunk_buf))
                if ret == -1:
                    _send_error_to_fd(fd_val, BadRequest())
                    _close_slot(backend, handler, slot, fd_val, slot_fds, fd_to_slot, provision_pool, active_count, metrics, slot_sse, slot_ws, slot_ws_state)
                    return
                elif ret >= 0:
                    var new_buf = Bytes(capacity=header_end_offset + decoded_size)
                    for j in range(header_end_offset):
                        new_buf.append(provision_pool.provisions[slot].recv_buffer[j])
                    for j in range(decoded_size):
                        new_buf.append(chunk_buf[j])
                    provision_pool.provisions[slot].recv_buffer = new_buf^
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

    # Still short of a complete body: register read interest for the rest.
    #
    # Nothing else does. The accept path arms EVFILT_READ only while the
    # state is still READING_HEADERS, so a request whose headers completed
    # in the eager read but whose body did not would sit unarmed until the
    # body timer answered 408. The re-registration is unconditional rather
    # than guarded on `slot_read_armed`, because epoll is edge-triggered:
    # the tail of the body is frequently already in the socket buffer, the
    # edge that carried it is spent, and only a fresh EPOLL_CTL_MOD
    # regenerates readiness for bytes that are pending but unread.
    if (
        slot_fds[slot] != UNUSED
        and provision_pool.provisions[slot].state.kind == ConnectionState.READING_BODY
    ):
        backend.try_add_read(fd_val)
        slot_read_armed[slot] = True

    provision_pool.provisions[slot].last_parse_len = len(provision_pool.provisions[slot].recv_buffer)


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
                pool.park_request(slot, request^)
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
) raises:
    """Take every finished job off the completion channel and answer it.

    Two outcomes per slot. The ordinary one hands the response to
    `_finish_response`, which is the same code the synchronous path runs. The
    other is a slot whose client vanished while the job was out: the fd is
    already closed and `slot_fds[slot]` is UNUSED, so the response is dropped
    and the provision — deliberately kept borrowed by `_close_slot` — is
    released here, where nothing else can be holding it.
    """
    if not offload.enabled():
        return
    ref pool = offload.pool()[]
    var finished = pool.drain_completions()
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
        _finish_response(
            backend, slot, slot_fds[slot], handler, config, server_address,
            tcp_keep_alive,
            slot_fds, slot_response, slot_send_offset, slot_header_start,
            fd_to_slot, provision_pool, active_count, metrics,
            slot_sse, slot_ws, slot_ws_state, slot_read_armed, slot_idle_deadline,
            date_cache_sec, date_cache, offload, response^,
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
        var asgi_stream = offload.slot_is_executor(slot)
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
    provision_pool.provisions[slot].prepare_for_new_request()
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

    `release_provision=False` is the one exception, and it exists for exactly
    one caller: a client that vanishes while its request is in a
    `--blocking-threads` pool thread. Everything here still runs — the fd is
    closed, the registrations dropped, the slot marked UNUSED — but the
    provision stays borrowed, because a pool thread still holds a reference
    into this slot's job storage. Releasing it here would hand the slot to the
    next connection while another thread was still writing into it. The
    completion, when it arrives, finds `slot_fds[slot] == UNUSED` and releases
    it then.
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
