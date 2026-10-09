"""Non-blocking kqueue event loop for concurrent HTTP connection handling.

The server's only accept loop: every `Server` entry point runs it, and the
blocking one it replaced in server.mojo is gone. Single-threaded and
non-blocking, over kqueue on macOS and epoll on Linux. Handles multiple
concurrent connections by advancing per-connection state machines on IO
readiness.

This file is the loop's door and its outline: `prepare_loop`,
`run_event_loop` and `run_pass_once`, which callers import from here, and
`_run_pass`, one pass, whose body names the rest. The rest is the package
`lightbug_http.loop`, a module for each thing the loop does (review record
C3):

    state      `LoopState`, the constants the modules share, and each
               slot's transitions, `_close_slot` among them
    timers     what the backend's timers fire, and the deadline sweep
    accept     new connections, one batch per door per pass
    request    a request read, parsed and handed over, or refused
    response   a response onto the wire, and what its slot does next
    streams    SSE and WebSocket: frames, outboxes, heartbeats, bus frames
    offload    the loop's side of the handler pool and the ASGI executor
    shutdown   the graceful drain

The modules import one another and this file, because the loop is
recursive -- a response that lands answers the request pipelined behind
it, and the drain runs ordinary passes -- and Mojo resolves a cycle of
imports inside one package. What the ASGI executor imports from here and
now lives in a module (`LoopState`, `service_direct_completions` and the
shutdown's steps) is imported below, so that path still resolves.

Nothing in `m0_http` (`src/`) may import this file or any module of
`loop/`, at any depth (DECISIONS D33): `loop/state.mojo` imports
`m0_http.log`, which resolves through the `.mojoc` that `build-http` is
writing while it compiles `src/`.
"""

from lightbug_http.c.kqueue import (
    EVFILT_READ, EVFILT_WRITE, EVFILT_TIMER, EV_EOF, EV_ERROR,
)
from lightbug_http.accept_share import AcceptShare
from lightbug_http.c.fcntl import set_nonblocking
from lightbug_http.c.socket import close
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.offload import POOL_WAKE_WAIT_MS
from lightbug_http.server_config import ServerConfig
from lightbug_http.service import HTTPService
from std.time import perf_counter_ns
from std.sys.info import CompilationTarget
from std.os import getenv

# The loop's modules. `LoopState`, `service_direct_completions` and the
# shutdown's steps are imported for callers too: the ASGI executor takes
# them from this module, as it did before the split.
from lightbug_http.loop.state import LoopState, TIMER_APP_TICK
from lightbug_http.loop.timers import _on_timer, _sweep_deadlines
from lightbug_http.loop.accept import _admit_batches
from lightbug_http.loop.request import _on_read
from lightbug_http.loop.response import _on_write
from lightbug_http.loop.streams import (
    _deliver_bus_frames, _drain_outboxes, _linger_handler_closes,
    _resume_suspended_reads,
)
from lightbug_http.loop.offload import (
    _flush_submits, _retry_owed_acks, _service_completions,
    service_direct_completions,
)
from lightbug_http.loop.shutdown import (
    _run_shutdown, _shutdown_begin, _shutdown_drain_step, _shutdown_finish,
)


def prepare_loop[B: EventLoopBackend](
    listen_fd: FileDescriptor,
    mut backend: B,
    config: ServerConfig,
    server_address: String,
    tcp_keep_alive: Bool,
    shutdown_read_fd: Int = -1,
    bus_read_fd: Int = -1,
    offload_addr: Int = 0,
    peer_bus_fd: Int = -1,
    accept_share: AcceptShare = AcceptShare(),
) raises -> LoopState:
    """The setup half of `run_event_loop`: build the state a pass runs over
    (`LoopState`, the slot tables), and register the listener, the
    shutdown pipe, the bus channels, the completion channel and the app
    timer on `backend`. Split from the driver so the loop inversion can
    prepare a loop it will drive one pass at a time from an asyncio
    callback.

    `listen_fd` becomes the loop's, as it does in `run_event_loop`: the
    drain closes it (`_shutdown_begin`), so its caller must not (review
    B26). A caller driving the passes itself closes it on an error that
    comes before the drain, or leaves it to its process's exit, as the
    inversion's m0serve does.
    """
    set_nonblocking(listen_fd)
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

    # Accept sharing (`--workers N`, SPEC E16): the channel a sibling passes
    # accepted connections down, registered like a bus channel and drained
    # like one. `start` publishes this worker as parked and empty; a
    # respawned worker inherits its predecessor's words otherwise.
    if accept_share.active():
        backend.try_add_read(accept_share.read_fd())
        accept_share.start()

    var st = LoopState(
        listen_fd, config, server_address, tcp_keep_alive,
        shutdown_read_fd, bus_read_fd, offload_addr, peer_bus_fd, accept_share,
    )

    # `--blocking-threads`: the pool's completion channel, registered exactly
    # as a bus channel is — a readable fd that means "somebody else finished
    # something; go look".
    if st.offload_complete_fd >= 0:
        backend.try_add_read(st.offload_complete_fd)

    # Application tick: one loop-wide timer driving the handler's `tick`
    # hook. Opt-in — 0 means the hook never fires and costs nothing.
    if config.app_tick_ms > 0:
        backend.try_add_timer(TIMER_APP_TICK, config.app_tick_ms)

    comptime if CompilationTarget.is_macos():
        print("Event loop started (kqueue, max_connections=" + String(st.max_conns) + ")")
    else:
        print("Event loop started (epoll, max_connections=" + String(st.max_conns) + ")")
    if accept_share.active():
        print(
            "Accept sharing: worker " + String(accept_share.worker) + " of "
            + String(accept_share.workers()) + " passes connections it"
            + " accepts to the least-loaded sibling",
            flush=True,
        )
    return st^


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
    accept_share: AcceptShare = AcceptShare(),
    stop_addr: Int = 0,
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

    `stop_addr`, when non-zero, is the address of an Int64 word the loop
    stores `perf_counter_ns()` into the moment its drain BEGINS -- the Mojo
    host's producer stop word (`ProducerThread.stop_addr`), so a thread the
    caller must join after the loop returns is told to stop while the drain
    runs and its join bound overlaps the drain's, instead of starting when
    the drain ends. Told only then, a slow request in flight at SIGTERM
    beside a step past its bound put the two 5 s budgets in sequence, which
    is `docker stop`'s whole default grace.

    **The loop owns `listen_fd`** (review B26), and closes it exactly once:
    as its drain begins (`_shutdown_begin`), or on the way out of a raise
    that came before the drain did. A caller holding a `NoTLSListener`
    gives it up with `listener^.into_fd()`, never `listener.socket.fd`: a
    listener kept past the call closed the number a second time when it
    was destroyed, after the drain had freed it and something else in the
    process -- a `print`'s `dup(1)`, a pool thread's `.pyc`, a straggler's
    socket -- had very likely been given it. A caller that wants its own
    reference passes a `dup` (the threaded modes pass one per loop).

    Parameters:
        T: The HTTP service handler type.
        B: The IO multiplexing backend (KqueueBackend on macOS, EpollBackend on Linux).
    """
    from lightbug_http.c.process import ignore_sigpipe

    # Before the loop's first send: a client that resets is then an EPIPE
    # on its own connection, not SIGPIPE ending the process (SPEC A25).
    ignore_sigpipe()
    var st: LoopState
    try:
        st = prepare_loop(
            listen_fd, backend, config, server_address,
            tcp_keep_alive, shutdown_read_fd, bus_read_fd, offload_addr,
            peer_bus_fd, accept_share,
        )
    except e:
        # Nothing has closed the listener, and nothing else will.
        _close_listener(listen_fd)
        raise e^
    st.stop_addr = stop_addr
    try:
        while True:
            var n_events = _wait_for_events(backend, st, 1000)
            var pass_start = perf_counter_ns()
            var stop = _run_pass(handler, backend, st, n_events)
            st.offload.note_pass(perf_counter_ns() - pass_start)
            if stop:
                _run_shutdown(handler, backend, st)
                if st.offload.ring_active() and getenv("M0_POOL_DEBUG", "") != "":
                    print(st.offload.wait_report(), flush=True)
                break
    except e:
        # Reached from the backend's wait alone: `_wait_for_events`, before
        # a pass or in one of `_run_shutdown`'s drain steps. A pass does not
        # raise. Closed already if the drain had begun: `_shutdown_begin`
        # forgets the number (-1) before it closes it.
        if st.listen_fd.value >= 0:
            backend.try_delete_read(st.listen_fd.value)
            _close_listener(st.listen_fd)
            st.listen_fd = FileDescriptor(-1)
        raise e^


def _close_listener(listen_fd: FileDescriptor):
    """Close the loop's listener, once, whatever the close says: there is
    no second attempt that would do better, and the number is not the
    loop's afterwards either way."""
    try:
        close(listen_fd)
    except:
        pass


def _wait_for_events[B: EventLoopBackend](
    mut backend: B, mut st: LoopState, timeout_ms: Int
) raises -> Int:
    """`backend.wait`, announced to the pool threads.

    With the ring handoff (`offload.mojo`, module docstring) a pool thread
    pokes this loop's completion channel only when the loop has said it
    is parked — so the flag goes up BEFORE the wait and the completion
    ring is re-checked AFTER it goes up, in that order. A completion
    published between the check and the park would otherwise wait for
    the next event, up to the timeout, with nobody sending the datagram.
    A non-empty ring skips the wait entirely and runs a pass with no
    events, whose first act is to drain it. Without rings this is the
    plain wait it always was.

    With the elastic rules a job may sit on a lane's ring with nobody
    woken for it — the loop's age check (`wake_aged`, at the bottom of
    every pass) is what wakes a sibling once it has waited its lane's
    threshold — so while a job is pending the loop waits until the
    earliest head's deadline that no look has judged yet
    (`OffloadPool.next_look`), to the nanosecond (`wait_ns`), and once
    every deadline has been judged, `POOL_WAKE_WAIT_MS` at most, or an
    idle loop would sleep its full second on top of a slow view. Rings
    empty, the timeout is the caller's.

    A batch left owed (`ACCEPT_BATCH`) makes the wait non-blocking: the
    listener and the hand-off channel are edge-triggered, so what is still
    queued there will not wake it.
    """
    var timeout = 0 if st.owes_accepts() else timeout_ms
    if not st.offload.ring_active():
        return backend.wait(timeout)
    var capped = False
    # The look's deadline, when one comes before the wait would end: a
    # wait in nanoseconds instead of `timeout`. -1 for none.
    var look_ns = -1
    if timeout > 0 and st.offload.jobs_pending():
        var bound = POOL_WAKE_WAIT_MS if timeout > POOL_WAKE_WAIT_MS else timeout
        var now = perf_counter_ns()
        var due = st.offload.next_look(now)
        if due != 0 and due - now < bound * 1_000_000:
            look_ns = due - now if due > now else 0
            capped = True
        elif timeout > POOL_WAKE_WAIT_MS:
            timeout = POOL_WAKE_WAIT_MS
            capped = True
    st.offload.set_loop_parked(True)
    if st.offload.done_pending():
        st.offload.set_loop_parked(False)
        st.offload.note_wait(capped, True, 0)
        return 0
    var t0 = perf_counter_ns()
    var n: Int
    var asked: Int
    if look_ns >= 0:
        n = backend.wait_ns(look_ns)
        asked = look_ns
    else:
        n = backend.wait(timeout)
        asked = timeout * 1_000_000
    st.offload.set_loop_parked(False)
    st.offload.note_wait(capped, False, n, perf_counter_ns() - t0 - asked)
    return n


def _run_pass[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, n_events: Int,
) -> Bool:
    """One pass of the event loop over `n_events` ready events.

    Everything between one `backend.wait` and the next, in an order that
    is load-bearing: pool completions already in memory; the events,
    dispatched by kind (the shutdown pipe, the bus channels, the
    accept-share channel, the completion channel, the listener, then
    timers, reads and writes); one batch of new connections per door,
    AFTER the events of the connections already held; completions again;
    owed acks; the outbox drain; the buffered submits; the elastic pool's
    age check; the deadline sweep; the handler's own WebSocket closes and
    resumes. Returns True when the shutdown pipe fired, and the caller
    then runs `_run_shutdown` once. The pass that reads the stop is an
    ordinary pass but for one thing: it dispatches its whole batch, the
    events behind the pipe included, and admits no new connection.

    Each block is a function over the loop's state -- `handler`,
    `backend` and `st`, and the slot and descriptor it acts on -- so this
    reads as the pass's outline.
    """
    var should_shutdown = False
    # New connections are taken AFTER the events of the ones already held
    # (the batch below the event loop), so these only record the doors.
    var listen_ready = False
    var listen_pending = 0
    var handoffs_ready = False

    # Accept sharing: siblings read this worker's state off the shared
    # page to decide whether to hand it a connection. Inside a pass it is
    # "busy since now"; `pass_end` parks it again and publishes the count.
    if st.accept_share.active():
        st.accept_share.pass_begin(perf_counter_ns())

    # Pool completions that arrived in memory: first, because a pass may
    # have been entered with no events at all for exactly this (see
    # `_wait_for_events`), and no syscall — the channel is read only when
    # its readiness says a datagram is there.
    if st.offload.done_pending():
        _service_completions(handler, backend, st, read_fd=False)

    for i in range(n_events):
        # EV_ERROR is kqueue's report of a CHANGE that failed (a
        # registration, errno in `data`), not of a socket, and no wait here
        # returns one: kqueue changes go through `kevent_register_one` with
        # no eventlist, so a failed one raises there instead. A socket's
        # error reaches this loop as EV_EOF from both backends. epoll's
        # EPOLLERR used to arrive as EV_ERROR, and this skip swallowed
        # every client reset on Linux with it (B12).
        if (backend.event_flags(i) & EV_ERROR) != 0:
            continue

        # The shutdown pipe. The stop is noted and the batch goes on: each
        # event behind the pipe is reported once, here -- epoll's reads,
        # channels and writes are edge triggered, kqueue's writes and
        # timers one-shots -- and one this pass skipped was never reported
        # again. It used to `break`: a completion behind the pipe left its
        # request unanswered and the drain waiting out its 5 s (B22). The
        # stop's one effect on this pass is below the batch: no new
        # connection is admitted.
        if st.shutdown_read_fd >= 0 and Int(backend.event_ident(i)) == st.shutdown_read_fd:
            should_shutdown = True
            continue

        # --- Cross-worker broadcast channel ---
        # Registration is edge-triggered, so every waiting datagram must
        # be consumed now; the loop's `BusReader` reads until EAGAIN. The
        # handler queues each frame for its local subscribers, and the
        # SSE outbox drain at the bottom of this pass sends them out.
        var _ident = Int(backend.event_ident(i))
        var _is_bus = st.bus_read_fd >= 0 and _ident == st.bus_read_fd
        var _is_peer_bus = st.peer_bus_fd >= 0 and _ident == st.peer_bus_fd
        if _is_bus or _is_peer_bus:
            var _bus_fd = st.bus_read_fd if _is_bus else st.peer_bus_fd
            _deliver_bus_frames(handler, st, _bus_fd)
            continue

        # --- Accept sharing: connections a sibling accepted for us ---
        # Each datagram carries an open descriptor and its peer address;
        # admitting one is exactly the accept path minus the accept.
        if st.accept_share.active() and _ident == st.accept_share.read_fd():
            # Admitted below the event loop, one batch like the
            # listener's: each admission is an eager read, and a sibling
            # can hand over a whole backlog at once.
            handoffs_ready = True
            continue

        # --- `--blocking-threads` completion channel ---
        # A pool thread finished a request. Edge-triggered like the bus,
        # so drain it fully; each completion re-enters the ordinary
        # RESPONDING write path.
        if st.offload_complete_fd >= 0 and Int(backend.event_ident(i)) == st.offload_complete_fd:
            _service_completions(handler, backend, st)
            continue

        # --- Listen socket: accept new connections ---
        if Int(backend.event_ident(i)) == st.listen_fd.value and backend.event_filter(i) == EVFILT_READ:
            # kqueue reports the pending backlog depth in the event data
            # field; epoll has no equivalent and returns 0 for "unknown".
            #
            # Both backends arm the listen socket edge-triggered, so a
            # burst of simultaneous connections produces exactly ONE
            # readiness event. Accepting a single connection per event
            # would strand the rest in the backlog until some later
            # connection happened to trigger a fresh edge. When the depth
            # is unknown, drain until accept() raises EAGAIN instead — the
            # listen socket is non-blocking (set above) and `_accept_batch`
            # stops at the first failed accept.
            #
            # The accepting itself is below the event loop, after every
            # other event of this pass (ACCEPT_BATCH).
            listen_ready = True
            listen_pending = backend.event_data(i)
            continue

        # --- Timer events ---
        if backend.event_filter(i) == EVFILT_TIMER:
            _on_timer(handler, backend, st, backend.event_ident(i))
            continue

        # --- Read events on connection sockets ---
        if backend.event_filter(i) == EVFILT_READ:
            _on_read(
                handler, backend, st, Int(backend.event_ident(i)),
                (backend.event_flags(i) & EV_EOF) != 0,
            )
            continue

        # --- Write events on connection sockets ---
        if backend.event_filter(i) == EVFILT_WRITE:
            _on_write(handler, backend, st, Int(backend.event_ident(i)))

    # New connections, after every event of the connections already held
    # (ACCEPT_BATCH): at most one batch per door per pass, whether this
    # pass saw the door's edge or a previous batch left some owed. Not
    # once the shutdown pipe has fired -- the listener is about to close.
    if not should_shutdown:
        _admit_batches(
            handler, backend, st, listen_ready, listen_pending, handoffs_ready
        )

    # And once more after the events: what the pool threads finished
    # while this pass ran gets answered now, before the outbox drain
    # below (a streaming head completed here has its first chunks swept
    # this pass) and before the loop can park.
    if st.offload.done_pending():
        _service_completions(handler, backend, st, read_fd=False)

    # Stream credit the ack channel refused earlier, retried every pass.
    _retry_owed_acks(st)

    # The outboxes: what the handler queued for its streams goes out.
    _drain_outboxes(handler, backend, st)

    # The pass's executor submits, one datagram per lane. After the
    # outbox drain and before this loop can park in `wait`: a slot left
    # buffered across a wait is a request nothing would ever run.
    _flush_submits(handler, backend, st)

    # The elastic pool's trigger (offload.mojo, `wake_aged`): a job that
    # has sat at the head of a lane's ring for `POOL_WAKE_AGE_NS` is
    # behind a thread that is not coming back — a slow view — and gets a
    # parked sibling woken for it. Once per pass, after every submit of
    # the pass is on its ring; `_wait_for_events` wakes the loop for the
    # next head's deadline, and within a millisecond while anything is
    # pending once every deadline has been judged. A peek per lane and
    # one clock read when the rings are empty, which is the common case.
    if st.offload.ring_active():
        _ = st.offload.wake_aged(perf_counter_ns())

    # The deadlines: idle, send, linger and header, once a second.
    _sweep_deadlines(handler, backend, st)

    # The WebSocket closes the handler made itself, then the reads it
    # suspended and has resumed.
    _linger_handler_closes(handler, backend, st)
    _resume_suspended_reads(handler, backend, st)

    # Accept sharing: park, publish the count, retire what the channel
    # delivered during this pass from the in-flight word.
    if st.accept_share.active():
        st.accept_share.pass_end(st.active_count)

    return should_shutdown


def run_pass_once[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState,
) raises -> Bool:
    """One non-blocking pass: poll the backend with a zero timeout and run
    `_run_pass` over whatever is ready. The inversion's driver calls this
    from an asyncio readiness callback on the backend's own fd, and from a
    1 Hz timer for the sweeps that assume a wake per second. Returns True
    when the shutdown pipe fired.

    A batch left owed (`ACCEPT_BATCH`) produces no readiness on that fd,
    so it is taken here, a pass at a time: each pass still serves the
    events of the connections already held before its batch. At most
    `max_connections` accepts' worth of passes, the bound one drain had
    before batches: under a flood the backlog never empties, and this
    callback must return for the application's tasks to run.
    """
    var n_events = backend.wait(0)
    var stop = _run_pass(handler, backend, st, n_events)
    var extra = st.max_conns // st.accept_batch if st.accept_batch > 0 else 0
    while not stop and st.owes_accepts() and extra > 0:
        extra -= 1
        n_events = backend.wait(0)
        stop = _run_pass(handler, backend, st, n_events)
    return stop
