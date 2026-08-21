"""SIGTERM/SIGINT handling, wired to the event loop's graceful shutdown.

The event loop has always known how to shut down cleanly — close the listener,
send `: close` to SSE clients and a 1001 frame to WebSocket clients, then drain
in-flight requests for up to five seconds. What was missing was a way for the
outside world to ask for it. `docker stop` sends SIGTERM; without a handler the
default action severs every open connection mid-response.

Usage — **after any fork**, see below::

    from m0_http.signal import install_shutdown_signals

    var shutdown_fd = install_shutdown_signals()
    server.listen_and_serve_nonblocking(
        config.address(), handler, shutdown_read_fd=shutdown_fd
    )

`create_shutdown_pipe` and `ShutdownHandle` are re-exported for the
programmatic path — a `/shutdown` endpoint, or a test that stops its own
server.

INSTALL AFTER THE FORK, NEVER BEFORE

Signal dispositions and open descriptors both survive `fork()`. Installing
before `WorkerSupervisor.fork_all()` gives every worker a handler that writes
to the *supervisor's* pipe, which nothing is watching, so SIGTERM would be
swallowed process-wide. Each worker calls this for itself once `fork_all`
returns; the supervisor installs its own variant from inside `fork_all`, and
the data segment being copy-on-write is what keeps the two from colliding.
This is the same shape as the "fork before the first Python call" rule in
`m0-wsgi`.

WHY A SELF-PIPE AND NOT A FLAG

The handler runs at an arbitrary point in the loop, so it may touch only
async-signal-safe things. Writing one byte to a pipe the loop already watches
is the whole implementation: no shared state to tear, no lock, and the wakeup
is delivered through the same `kevent`/`epoll_wait` the loop is already
blocked in. Both backends already treat EINTR as "zero events", so a signal
arriving mid-wait costs one extra loop pass.

WHEN THE DATA-SEGMENT SLOT IS NOT AVAILABLE

A POSIX handler gets no user-data pointer, so the write fd has to live in
process state — `src/global_slot.mojo`, which reaches an internal MLIR op to
get what C spells `static`. If that op ever stops working, this function
installs **nothing** and returns -1, which is already the server's "shutdown
disabled" sentinel, and the process keeps its default SIGTERM behaviour. That
ordering is deliberate: a handler installed over a dead slot would swallow
SIGTERM and leave no way to stop the server at all, which is strictly worse
than not having one. `shutdown_signals_active()` reports which happened, and
`test/test_lifecycle.mojo` asserts it so the degradation cannot pass silently.
"""

from std.ffi import c_int

from lightbug_http.c.pipe import create_shutdown_pipe, ShutdownHandle, close_fd
from lightbug_http.c.process import (
    install_signal_handler, SIGTERM, SIGINT,
)

from .global_slot import (
    set_shutdown_write_fd, shutdown_write_fd, slot_is_live,
)


comptime _SIG_DFL = 0
"""The default disposition, for putting a signal back the way it was."""


def _on_terminate_signal(sig: c_int):
    """Signal handler: nudge the event loop and return.

    Async-signal-safe end to end — one word load, one `write(2)` of a single
    byte. Everything that decides *what* shutting down means happens on the
    loop thread afterwards. A zero slot means no pipe was ever published, so
    there is nothing to nudge.
    """
    var fd = shutdown_write_fd()
    if fd != 0:
        ShutdownHandle(fd).notify()


def install_shutdown_signals() raises -> Int:
    """Make SIGTERM and SIGINT trigger the event loop's graceful shutdown.

    Call once per process, after any `fork()`. See this module's header for why
    the ordering matters and what the degraded path is.

    Returns:
        The read fd to pass as `shutdown_read_fd`, or -1 if signal-driven
        shutdown could not be armed — in which case nothing was installed and
        the process keeps its default behaviour. -1 is what the server already
        understands as "no shutdown pipe", so it needs no special handling at
        the call site.

    Raises:
        Error: If `pipe(2)` fails, e.g. at the descriptor limit.
    """
    # Probed before anything is created, so this branch has nothing to unwind.
    if not slot_is_live():
        return -1

    var pair = create_shutdown_pipe()
    var read_fd = pair[0]
    set_shutdown_write_fd(pair[1].fd)

    # Held in a var across both installs: the address is taken from the
    # variable holding the function value, so the value has to outlive it.
    var handler = _on_terminate_signal
    var handler_address = Pointer(to=handler).unsafe_bitcast[Int]()[]
    var armed = install_signal_handler(SIGTERM, handler_address)
    if armed:
        armed = install_signal_handler(SIGINT, handler_address)
    _ = handler

    if not armed:
        # Unreachable short of a kernel refusing SIGTERM, but a half-armed
        # process is the one state worse than an unarmed one.
        _ = install_signal_handler(SIGTERM, _SIG_DFL)
        _ = install_signal_handler(SIGINT, _SIG_DFL)
        set_shutdown_write_fd(0)
        close_fd(pair[1].fd)
        close_fd(read_fd)
        return -1

    return read_fd


def shutdown_signals_active() -> Bool:
    """Report whether this process has signal-driven shutdown armed.

    False before `install_shutdown_signals` and after a degraded install. The
    degradation is silent by nature — the server runs perfectly well without
    it — so this exists to be asserted in tests.

    Returns:
        True if a handler is installed and has a pipe to write to.
    """
    return shutdown_write_fd() != 0
