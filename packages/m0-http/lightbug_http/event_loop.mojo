"""Non-blocking kqueue event loop for concurrent HTTP connection handling.

Replaces the blocking accept-loop in server.mojo with a single-threaded,
non-blocking event loop using macOS kqueue. Handles multiple concurrent
connections by advancing per-connection state machines on IO readiness.
"""

from lightbug_http.c.kqueue import (
    set_nonblocking,
    EVFILT_READ, EVFILT_WRITE, EVFILT_TIMER,
    EV_EOF, EV_ERROR,
)
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.c.socket import accept, recv, send, close
from lightbug_http.c.socket_error import (
    AcceptEAGAINError, RecvEAGAINError, SendEAGAINError,
)
from lightbug_http.connection import ConnectionState, default_buffer_size
from lightbug_http.header import (
    HeaderKey, ParsedRequestHeaders, find_header_end, parse_request_headers,
)
from lightbug_http.http import HTTPRequest, HTTPResponse, encode
from lightbug_http.http.common_response import (
    BadRequest, InternalError, URITooLong, RequestTimeout, HeadersTooLarge, PayloadTooLarge,
)
from lightbug_http.http.chunked import HTTPChunkedDecoder
from lightbug_http.io.bytes import Bytes
from std.memory import memcpy
from lightbug_http.metrics import ServerMetrics
from lightbug_http.server import (
    BodyReadState, ConnectionProvision, ProvisionPool,
)
from lightbug_http.server_config import ServerConfig
from lightbug_http.service import HTTPService
from lightbug_http.utils.owning_list import OwningList
from std.time import perf_counter_ns
from std.sys.info import CompilationTarget
from m0_http.log import log_access


# Timer ident offsets to distinguish timeout types from fd-based events.
# fd values are small (typically < 65536), so these offsets avoid collision.
comptime TIMER_HEADER: UInt = 0x100000
comptime TIMER_BODY: UInt = 0x200000
comptime TIMER_IDLE: UInt = 0x300000
comptime TIMER_SSE_HEARTBEAT: UInt = 0x400000

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
) raises:
    """Run the IO-multiplexed event loop.

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

    var max_conns = config.max_connections
    var provision_pool = ProvisionPool(max_conns, config)

    # Per-slot state (SoA pattern)
    var slot_fds = List[Int](capacity=max_conns)
    var slot_response = OwningList[Bytes](capacity=max_conns)
    var slot_send_offset = List[Int](capacity=max_conns)
    var slot_header_start = List[Int](capacity=max_conns)
    var slot_sse = List[Bool](capacity=max_conns)

    for _ in range(max_conns):
        slot_fds.append(UNUSED)
        slot_response.append(Bytes())
        slot_send_offset.append(0)
        slot_header_start.append(0)
        slot_sse.append(False)

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
    while True:
        var n_events = backend.wait(1000)

        for i in range(n_events):
            if (backend.event_flags(i) & EV_ERROR) != 0:
                continue

            # Phase 4a: shutdown pipe — write end closed, exit cleanly
            if shutdown_read_fd >= 0 and Int(backend.event_ident(i)) == shutdown_read_fd:
                should_shutdown = True
                break

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
                    try:
                        new_fd = accept(listen_fd)
                    except:
                        break

                    var slot = UNUSED
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

                    slot_fds[slot] = fd_val
                    slot_send_offset[slot] = 0
                    slot_header_start[slot] = perf_counter_ns()
                    fd_to_slot[fd_val] = slot
                    active_count += 1
                    if config.enable_metrics:
                        metrics.accepts_total += 1

                    provision_pool.provisions[slot].prepare_for_new_request()
                    provision_pool.provisions[slot].keepalive_count = 0

                    if config.header_read_timeout > 0:
                        backend.try_add_timer(
                            UInt(fd_val) + TIMER_HEADER,
                            config.header_read_timeout * 1000,
                        )

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
                        active_count, metrics, slot_sse,
                    )

                    # If the slot is still active and in reading_headers state,
                    # the eager read got EAGAIN — register EVFILT_READ now.
                    if slot_fds[slot] != UNUSED and provision_pool.provisions[slot].state.kind == ConnectionState.READING_HEADERS:
                        try:
                            backend.add_read(fd_val)
                        except:
                            _close_slot(
                                backend, slot, fd_val,
                                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                                slot_sse,
                            )
                continue

            # --- Timer events ---
            if backend.event_filter(i) == EVFILT_TIMER:
                var timer_ident = backend.event_ident(i)
                var fd_val: Int

                # SSE heartbeat timer: send ": heartbeat\n\n" to keep connection alive
                if timer_ident >= TIMER_SSE_HEARTBEAT:
                    fd_val = Int(timer_ident - TIMER_SSE_HEARTBEAT)
                    if fd_val < len(fd_to_slot):
                        var hb_slot = fd_to_slot[fd_val]
                        if hb_slot != UNUSED and slot_sse[hb_slot] and provision_pool.provisions[hb_slot].state.kind == ConnectionState.STREAMING_SSE:
                            var hb = String(": heartbeat\n\n")
                            slot_response[hb_slot] = Bytes(hb.as_bytes())
                            slot_send_offset[hb_slot] = 0
                            provision_pool.provisions[hb_slot].state = ConnectionState.responding()
                            var fd_desc = FileDescriptor(fd_val)
                            try:
                                var sent = send(fd_desc, Span(slot_response[hb_slot]), UInt(len(slot_response[hb_slot])), 0)
                                slot_send_offset[hb_slot] = Int(sent)
                            except:
                                pass
                            if slot_send_offset[hb_slot] >= len(slot_response[hb_slot]):
                                provision_pool.provisions[hb_slot].state = ConnectionState.streaming_sse()
                            else:
                                backend.try_add_write_oneshot(fd_val)
                    continue

                if timer_ident >= TIMER_IDLE:
                    fd_val = Int(timer_ident - TIMER_IDLE)
                elif timer_ident >= TIMER_BODY:
                    fd_val = Int(timer_ident - TIMER_BODY)
                elif timer_ident >= TIMER_HEADER:
                    fd_val = Int(timer_ident - TIMER_HEADER)
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
                    backend, slot, fd_val,
                    slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                    slot_sse,
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

                if (backend.event_flags(i) & EV_EOF) != 0:
                    _close_slot(
                        backend, slot, fd_val,
                        slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                        slot_sse,
                    )
                    continue

                if provision_pool.provisions[slot].state.kind == ConnectionState.STREAMING_SSE:
                    # SSE client disconnect: recv→0 means client closed connection
                    handler.sse_slot_disconnected(slot)
                    _close_slot(
                        backend, slot, fd_val,
                        slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                        slot_sse,
                    )
                    continue

                elif provision_pool.provisions[slot].state.kind == ConnectionState.READING_HEADERS:
                    _handle_read_headers(
                        backend, slot, fd_val, handler, config,
                        server_address, tcp_keep_alive,
                        slot_fds, slot_response, slot_send_offset,
                        slot_header_start, fd_to_slot, provision_pool,
                        active_count, metrics, slot_sse,
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
                            backend, slot, fd_val,
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse,
                        )
                        continue

                    if bytes_read == 0:
                        _close_slot(
                            backend, slot, fd_val,
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse,
                        )
                        continue

                    provision_pool.provisions[slot].recv_staging._len = Int(bytes_read)
                    provision_pool.provisions[slot].recv_buffer.extend(
                        Span(provision_pool.provisions[slot].recv_staging)
                    )

                    if not body_st.is_chunked:
                        body_st.bytes_read += Int(bytes_read)
                        provision_pool.provisions[slot].body_state = body_st

                    if len(provision_pool.provisions[slot].recv_buffer) > config.recv_buffer_max:
                        _send_error_to_fd(fd_val, BadRequest())
                        _close_slot(
                            backend, slot, fd_val,
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse,
                        )
                        continue

                    # Phase 1b: chunked body decode attempt
                    if body_st.is_chunked:
                        var raw_body_start = body_st.header_end_offset
                        var raw_body_len = len(provision_pool.provisions[slot].recv_buffer) - raw_body_start
                        if raw_body_len > config.max_request_body_size:
                            _send_error_to_fd(fd_val, PayloadTooLarge())
                            _close_slot(backend, slot, fd_val, slot_fds, fd_to_slot, provision_pool, active_count, metrics, slot_sse)
                            continue
                        if raw_body_len > 0:
                            var chunk_buf = Bytes(capacity=raw_body_len)
                            for j in range(raw_body_start, len(provision_pool.provisions[slot].recv_buffer)):
                                chunk_buf.append(provision_pool.provisions[slot].recv_buffer[j])
                            var decoder = HTTPChunkedDecoder()
                            var (ret, decoded_size) = decoder.decode(Span(chunk_buf))
                            if ret == -1:
                                _send_error_to_fd(fd_val, BadRequest())
                                _close_slot(backend, slot, fd_val, slot_fds, fd_to_slot, provision_pool, active_count, metrics, slot_sse)
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
                                    slot_sse,
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
                            slot_sse,
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

                var remaining = len(slot_response[slot]) - slot_send_offset[slot]
                if remaining <= 0:
                    _after_send(
                        backend, slot, fd_val,
                        handler, config, server_address, tcp_keep_alive,
                        slot_fds, slot_response, slot_send_offset,
                        slot_header_start,
                        fd_to_slot, provision_pool, active_count, metrics,
                        slot_sse,
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
                        continue
                    _close_slot(
                        backend, slot, fd_val,
                        slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                        slot_sse,
                    )
                    continue

                slot_send_offset[slot] += Int(sent)

                if slot_send_offset[slot] >= len(slot_response[slot]):
                    _after_send(
                        backend, slot, fd_val,
                        handler, config, server_address, tcp_keep_alive,
                        slot_fds, slot_response, slot_send_offset,
                        slot_header_start,
                        fd_to_slot, provision_pool, active_count, metrics,
                        slot_sse,
                    )
                else:
                    try:
                        backend.add_write_oneshot(fd_val)
                    except:
                        _close_slot(
                            backend, slot, fd_val,
                            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                            slot_sse,
                        )

        # SSE outbox drain: push pending events to streaming connections
        for s in range(max_conns):
            if slot_sse[s] and slot_fds[s] != UNUSED and provision_pool.provisions[s].state.kind == ConnectionState.STREAMING_SSE:
                var pending = handler.sse_drain_slot(s)
                if len(pending) > 0:
                    slot_response[s] = Bytes(Span(pending))
                    slot_send_offset[s] = 0
                    provision_pool.provisions[s].state = ConnectionState.responding()
                    # Eager send
                    var sse_fd = FileDescriptor(slot_fds[s])
                    try:
                        var sent = send(sse_fd, Span(slot_response[s]), UInt(len(slot_response[s])), 0)
                        slot_send_offset[s] = Int(sent)
                    except:
                        pass
                    if slot_send_offset[s] >= len(slot_response[s]):
                        provision_pool.provisions[s].state = ConnectionState.streaming_sse()
                    else:
                        backend.try_add_write_oneshot(slot_fds[s])

        if should_shutdown:
            # Graceful shutdown: close listener, drain in-flight, close SSE
            try:
                close(listen_fd)
            except:
                pass

            # Send SSE close comment to all streaming slots
            for s in range(max_conns):
                if slot_sse[s] and slot_fds[s] != UNUSED:
                    var close_comment = String(": close\n\n").as_bytes()
                    try:
                        _ = send(FileDescriptor(slot_fds[s]), Span(close_comment), UInt(len(close_comment)), 0)
                    except:
                        pass
                    _close_slot(
                        backend, s, slot_fds[s],
                        slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                        slot_sse,
                    )

            # Drain in-flight: wait for active non-SSE connections (max 5s)
            var drain_start = perf_counter_ns()
            comptime DRAIN_TIMEOUT_NS: Int = 5_000_000_000
            while active_count > 0:
                if (perf_counter_ns() - drain_start) > DRAIN_TIMEOUT_NS:
                    break
                var drain_events = backend.wait(100)
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
                                backend, drain_slot, drain_ident,
                                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                                slot_sse,
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
):
    """Read and parse HTTP request headers for a connection slot.

    Called both eagerly from the accept path (to handle data already buffered
    before kqueue registration) and from the EVFILT_READ handler.
    """
    if config.header_read_timeout > 0:
        var elapsed_s = (perf_counter_ns() - slot_header_start[slot]) / 1_000_000_000
        if elapsed_s >= Int(config.header_read_timeout):
            _send_error_to_fd(fd_val, RequestTimeout())
            _close_slot(
                backend, slot, fd_val,
                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                slot_sse,
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
                backend, slot, fd_val,
                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                slot_sse,
            )
            return

    if bytes_read == 0 and len(provision_pool.provisions[slot].recv_buffer) == 0:
        _close_slot(
            backend, slot, fd_val,
            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
            slot_sse,
        )
        return

    if bytes_read > 0:
        provision_pool.provisions[slot].recv_staging._len = Int(bytes_read)
        provision_pool.provisions[slot].recv_buffer.extend(
            Span(provision_pool.provisions[slot].recv_staging)
        )

    if len(provision_pool.provisions[slot].recv_buffer) > config.recv_buffer_max:
        _send_error_to_fd(fd_val, BadRequest())
        _close_slot(
            backend, slot, fd_val,
            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
            slot_sse,
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
                backend, slot, fd_val,
                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                slot_sse,
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
                backend, slot, fd_val,
                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                slot_sse,
            )
            return

        if parsed.path.byte_length() > config.max_request_uri_length:
            _send_error_to_fd(fd_val, URITooLong())
            _close_slot(
                backend, slot, fd_val,
                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                slot_sse,
            )
            return

        var content_length = parsed.content_length()
        var is_chunked = parsed.is_chunked_body()

        if not is_chunked and content_length > config.max_request_body_size:
            _send_error_to_fd(fd_val, PayloadTooLarge())
            _close_slot(
                backend, slot, fd_val,
                slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                slot_sse,
            )
            return

        if config.header_read_timeout > 0:
            backend.try_delete_timer(UInt(fd_val) + TIMER_HEADER)

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
                    _close_slot(backend, slot, fd_val, slot_fds, fd_to_slot, provision_pool, active_count, metrics, slot_sse)
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
                        slot_sse,
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
                    slot_sse,
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
                slot_sse,
            )

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
            memcpy(
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
            backend, slot, fd_val,
            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
            slot_sse,
        )
        return

    request.slot_id = slot
    provision_pool.provisions[slot].should_close = (not tcp_keep_alive) or request.connection_close()
    var request_method = request.method
    var request_path = request.uri.path

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
        # Before hook: short-circuit if it returns a response
        var early = handler.before_request(request)
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

    if response.sse_streaming:
        slot_sse[slot] = True
        provision_pool.provisions[slot].should_close = False

    if (not provision_pool.provisions[slot].should_close) and (config.max_keepalive_requests > 0):
        if (provision_pool.provisions[slot].keepalive_count + 1) >= config.max_keepalive_requests:
            provision_pool.provisions[slot].should_close = True

    # RFC 9110 §9.3.2: HEAD response must not contain a body
    if request_method == "HEAD":
        response.body_raw = Bytes()

    if provision_pool.provisions[slot].should_close:
        response.set_connection_close()
    else:
        response.set_connection_keep_alive()

    var response_status = response.status_code
    provision_pool.provisions[slot].response_status = response_status

    # SSE streaming: remove Content-Length so client reads until close
    if response.sse_streaming:
        response.headers.pop("content-length")

    # Encode response. encode_into() (Phase 2f) requires moving the buffer
    # out of the provision, which Mojo does not allow for list-element fields;
    # use encode() until the move-from-field story matures in Mojo.
    slot_response[slot] = encode(response^)
    slot_send_offset[slot] = 0

    # Phase 4d: populate access log fields (emitted after send)
    if config.access_log:
        provision_pool.provisions[slot].log_summary = String(
            '"', request_method, ' ', request_path, ' HTTP/1.1" ', String(response_status),
        )
        provision_pool.provisions[slot].log_method = request_method
        provision_pool.provisions[slot].log_path = request_path
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
                    backend, slot, fd_val,
                    slot_fds, fd_to_slot, provision_pool, active_count, metrics,
                    slot_sse,
                )
                return
            # EAGAIN: fall through to register EVFILT_WRITE

    if slot_send_offset[slot] >= response_len:
        _after_send(
            backend, slot, fd_val,
            handler, config, server_address, tcp_keep_alive,
            slot_fds, slot_response, slot_send_offset,
            slot_header_start,
            fd_to_slot, provision_pool, active_count, metrics,
            slot_sse,
        )
        return

    # Partial send or EAGAIN: register EVFILT_WRITE for the remainder.
    try:
        backend.add_write_oneshot(fd_val)
    except:
        _close_slot(
            backend, slot, fd_val,
            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
            slot_sse,
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
            backend, slot, fd_val,
            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
            slot_sse,
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
            backend, slot, fd_val,
            slot_fds, fd_to_slot, provision_pool, active_count, metrics,
            slot_sse,
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

    # SSE streaming: after initial response (or a pushed event) is sent,
    # enter idle streaming state instead of returning to READING_HEADERS.
    if slot_sse[slot]:
        slot_response[slot] = Bytes()
        slot_send_offset[slot] = 0
        provision_pool.provisions[slot].state = ConnectionState.streaming_sse()
        # Register EVFILT_READ for client disconnect detection (recv→0)
        backend.try_add_read(fd_val)
        # Set up heartbeat timer (configurable interval, repeating)
        if config.sse_heartbeat_ms > 0:
            backend.try_add_timer(UInt(fd_val) + TIMER_SSE_HEARTBEAT, config.sse_heartbeat_ms)
        return

    # Keep-alive: prepare for next request
    provision_pool.provisions[slot].keepalive_count += 1
    provision_pool.provisions[slot].prepare_for_new_request()
    slot_response[slot] = Bytes()
    slot_send_offset[slot] = 0
    slot_header_start[slot] = perf_counter_ns()

    if config.idle_timeout > 0:
        backend.try_add_timer(UInt(fd_val) + TIMER_IDLE, config.idle_timeout * 1000)

    # Register EVFILT_READ for the next keep-alive request.
    # The filter was deleted (or never registered for this cycle) when we
    # consumed data via recv() outside kqueue delivery. Registering now
    # ensures kqueue fires when the client sends the next request.
    backend.try_add_read(fd_val)


def _close_slot[B: EventLoopBackend](
    mut backend: B,
    slot: Int,
    fd_val: Int,
    mut slot_fds: List[Int],
    mut fd_to_slot: List[Int],
    mut provision_pool: ProvisionPool,
    mut active_count: Int,
    mut metrics: ServerMetrics,
    mut slot_sse: List[Bool],
):
    """Close a connection and release its slot."""
    backend.try_delete_read(fd_val)
    backend.try_delete_write(fd_val)
    backend.try_delete_timer(UInt(fd_val) + TIMER_HEADER)
    backend.try_delete_timer(UInt(fd_val) + TIMER_BODY)
    backend.try_delete_timer(UInt(fd_val) + TIMER_IDLE)
    backend.try_delete_timer(UInt(fd_val) + TIMER_SSE_HEARTBEAT)
    slot_sse[slot] = False

    try:
        close(FileDescriptor(fd_val))
    except:
        pass

    slot_fds[slot] = UNUSED
    if fd_val < len(fd_to_slot):
        fd_to_slot[fd_val] = UNUSED
    provision_pool.provisions[slot].prepare_for_new_request()
    provision_pool.provisions[slot].keepalive_count = 0
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
