"""New connections, admitted one batch per door per pass.

The doors are the listener and, under `--workers N`, the accept-share
channel a sibling passes connections down (`accept_share.mojo`). A pass
admits at most `ACCEPT_BATCH` from each, AFTER the events of the
connections it already holds, and what a batch leaves is owed to the next
pass (`ACCEPT_BATCH`, in `loop/state.mojo`, says why). Admitting a
connection runs its eager read (`_admit_connection`), which on a loop that
runs `func` itself is the whole request.
"""

from lightbug_http.c.fdpass import RECV_FD_EMPTY
from lightbug_http.c.kqueue import set_nonblocking, set_tcp_nodelay
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.c.socket import accept_with_peer, close
from lightbug_http.c.socket_error import SysError
from lightbug_http.connection import ConnectionState
from lightbug_http.service import HTTPService
from std.ffi import ErrNo
from std.sys.info import CompilationTarget
from std.time import perf_counter_ns

from lightbug_http.loop.state import LoopState, UNUSED, _arm_reads, _close_slot
from lightbug_http.loop.request import _drain_pipelined, _handle_read_headers


def _admit_batches[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState,
    listen_ready: Bool, listen_pending: Int, handoffs_ready: Bool,
) raises:
    """At most one batch of new connections per door -- the listener, and
    the accept-share channel -- whether this pass saw the door's edge or a
    previous batch left some owed (`ACCEPT_BATCH`), and what either leaves
    owed to the next pass."""
    if listen_ready or st.accept_owed:
        # kqueue's depth bounds the drain it reports; epoll reports
        # none, so without a batch the drain runs to EAGAIN, bounded
        # only by `max_connections`.
        var accept_budget = st.max_conns
        if listen_ready and listen_pending > 0:
            accept_budget = listen_pending
        var capped = st.accept_batch > 0 and accept_budget > st.accept_batch
        if capped:
            accept_budget = st.accept_batch
        var ran_out = _accept_batch(handler, backend, st, accept_budget)
        # Owed only when the BATCH stopped it: a kqueue budget of the
        # reported depth that ran out left nothing the next edge will
        # not announce.
        st.accept_owed = capped and ran_out
    if handoffs_ready or st.handoffs_owed:
        st.handoffs_owed = _admit_handoffs(handler, backend, st, st.accept_batch)


def _admit_connection[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, fd_val: Int,
    var peer_host: String, peer_port: Int,
) raises:
    """Take a connection into a slot and run its eager read.

    The tail of the accept path, factored out so a connection a SIBLING
    accepted and passed here (`_admit_handoffs`) enters by the same door:
    borrow a slot, non-blocking and Nagle off, the per-slot state reset,
    the eager read, the read registration if that read got EAGAIN, and
    the pipelined tail. `fd_val` is already this process's own
    descriptor; a failure to place it closes it here.
    """
    var new_fd = FileDescriptor(fd_val)

    var slot: Int
    try:
        slot = st.provision_pool.borrow()
    except:
        try:
            close(new_fd)
        except:
            pass
        return

    if fd_val >= len(st.fd_to_slot):
        var new_len = fd_val + 1024
        for _ in range(len(st.fd_to_slot), new_len):
            st.fd_to_slot.append(UNUSED)

    try:
        set_nonblocking(new_fd)
    except:
        st.provision_pool.release(slot)
        try:
            close(new_fd)
        except:
            pass
        return

    # Nagle off: single-send responses have nothing to
    # coalesce, and leaving it on stalls a response behind
    # the previous response's ACK. Best-effort.
    set_tcp_nodelay(new_fd)

    st.slot_fds[slot] = fd_val
    # One capture per connection covers every request the
    # keep-alive carries; overwritten at the slot's next
    # accept, so no clearing on close.
    st.provision_pool.provisions[slot].peer_host = peer_host^
    st.provision_pool.provisions[slot].peer_port = peer_port
    st.slot_send_offset[slot] = 0
    st.slot_header_start[slot] = perf_counter_ns()
    st.slot_read_armed[slot] = False
    st.slot_idle_deadline[slot] = 0
    # A recycled slot must not inherit the previous
    # connection's channel-stream state: a pool thread's
    # ack fd left here would make the next M0-Hold on this
    # slot look like a chunk-framed stream.
    st.offload.clear_stream(slot)
    st.fd_to_slot[fd_val] = slot
    st.active_count += 1
    if st.config.enable_metrics:
        st.metrics.accepts_total += 1

    st.provision_pool.provisions[slot].prepare_for_new_request()
    st.provision_pool.provisions[slot].keepalive_count = 0

    # No header timerfd: the once-a-second sweep owns this
    # deadline now. `slot_header_start` stamped just above is
    # the whole mechanism, and it costs no fd and no syscall.

    # Eager read: try to process data already buffered.
    # EVFILT_READ is NOT registered yet — we register it only
    # if the eager read gets EAGAIN (no data).  This avoids
    # kqueue state confusion when recv() consumes data that
    # kqueue hasn't delivered yet.
    _handle_read_headers(handler, backend, st, slot, fd_val)

    # If the slot is still active and in reading_headers state,
    # the eager read got EAGAIN — register EVFILT_READ now.
    # (_after_send may already have armed it if the eager read
    # carried a complete request; skip the redundant syscall.)
    if (
        st.slot_fds[slot] != UNUSED
        and st.provision_pool.provisions[slot].state.kind
        == ConnectionState.READING_HEADERS
    ):
        if not _arm_reads(backend, st, slot, fd_val):
            _close_slot(handler, backend, st, slot, fd_val)
    # The eager read may have taken MORE than one request.
    _drain_pipelined(handler, backend, st, slot, fd_val)


def _admit_handoffs[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, budget: Int = 0,
) raises -> Bool:
    """Admit the connections waiting on this worker's accept-share channel:
    up to `budget` of them, or every one when `budget` is 0.

    Edge-triggered like the bus, so without a budget the channel is drained
    to EAGAIN. True when the budget ran out first: the rest is owed, and no
    edge will announce it (`ACCEPT_BATCH`).

    A hand-off that arrives with no descriptor (`RECV_FD_REFUSED`: on a
    worker out of descriptors, one the kernel could not install) is
    skipped, and counts against the budget like any other taken. Its
    connection is gone; the ones queued behind it are not, and read as an
    empty channel -- which it was, a single -1 for both -- it stopped the
    drain with them stranded until another hand-off raised an edge.
    """
    var taken = 0
    while budget == 0 or taken < budget:
        var host = String("")
        var port = 0
        var fd = st.accept_share.receive(host, port)
        if fd == RECV_FD_EMPTY:
            return False
        taken += 1
        if fd < 0:
            continue
        _admit_connection(handler, backend, st, fd, host^, port)
    return True


def _accept_retries(err: SysError) -> Bool:
    """Whether the accept drain goes on past a failed `accept`: True when
    the failure cost one connection, False when it stops the pass.

    Going on matters because the listen socket is edge-triggered on both
    backends: connections a stopped drain leaves in the backlog are owed no
    new readiness edge until some later connection arrives, so under bursty
    load one dead connection strands the live ones behind it.

    ECONNABORTED (the client gave up while queued) and EINTR are one
    attempt's trouble everywhere. Linux's `accept` also returns a network
    error already pending on the connection it has just taken off the
    queue -- ENETDOWN, EPROTO, ENOPROTOOPT, EHOSTDOWN, ENONET, EHOSTUNREACH,
    EOPNOTSUPP, ENETUNREACH -- and accept(2) says to treat those like
    EAGAIN by retrying: each has cost a connection, not the listener, and
    read as anything else they stopped the pass. macOS passes none of them
    on, and its EOPNOTSUPP means a listener that cannot accept at all, so
    there the list is the first two. Anything else (EMFILE, ENFILE,
    ENOBUFS, ENOMEM) is the process's or the system's, and accepting harder
    will not cure it.
    """
    var retry = err.connection_aborted() or err.interrupted()
    comptime if not CompilationTarget.is_macos():
        var e = err.errno
        retry = retry or (
            e == ErrNo.ENETDOWN
            or e == ErrNo.EPROTO
            or e == ErrNo.ENOPROTOOPT
            or e == ErrNo.EHOSTDOWN
            or e == ErrNo.ENONET
            or e == ErrNo.EHOSTUNREACH
            or e == ErrNo.EOPNOTSUPP
            or e == ErrNo.ENETUNREACH
        )
    return retry


def _accept_batch[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, budget: Int,
) raises -> Bool:
    """Accept up to `budget` connections off the listener and admit each,
    or pass it to a lighter sibling. True when the budget ran out before
    the backlog did -- the caller decides whether that leaves any owed.

    An error that accepting harder will not cure (EMFILE, ENFILE, ...) is
    False, not owed: carried over, it would be retried every pass with a
    wait that no longer blocks.
    """
    for _ in range(budget):
        var new_fd: FileDescriptor
        var peer_host: String
        var peer_port: Int
        try:
            var accepted = accept_with_peer(st.listen_fd)
            new_fd = accepted[0]
            peer_host = accepted[1]
            peer_port = accepted[2]
        except accept_err:
            # EAGAIN: backlog drained — this readiness event is done.
            if accept_err.would_block():
                return False
            # One connection's trouble goes on to the next; anything
            # else stops the pass and lets the loop breathe.
            if _accept_retries(accept_err):
                continue
            return False

        # Accept sharing: a sibling with fewer connections takes
        # this one. `pick` answers this worker when no sibling is
        # lighter (or all are busy or gone), and a send that fails
        # keeps the connection here -- nothing is ever dropped.
        if st.accept_share.active():
            var target = st.accept_share.pick(st.active_count, perf_counter_ns())
            if (
                target != st.accept_share.worker
                and st.accept_share.send(target, new_fd.value, peer_host, peer_port)
            ):
                # The receiver holds its own reference now.
                try:
                    close(new_fd)
                except:
                    pass
                continue

        _admit_connection(handler, backend, st, new_fd.value, peer_host^, peer_port)
    return True
