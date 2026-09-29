"""Process-lifetime slots in the data segment, for POSIX signal handlers.

WHY THIS EXISTS

A POSIX signal handler is a bare `void (*)(int)`. There is no user-data
pointer, no `self`, and no argument the caller controls — so everything a
handler needs must already be reachable from process state. In C that is a
`static volatile sig_atomic_t`. Mojo's *language surface* has no module-level
`var`; it errors with "global variables are not supported".

The MLIR layer underneath does have one. `pop.global_alloc` — the mutable
sibling of the op behind `builtin/globals.global_constant` — lowers to
`llvm.mlir.global internal @<name>`, a zero-initialised, module-private slot
in the data segment. That is exactly the C construct, and it is what lets
`src/signal.mojo` install a real SIGTERM handler.

Verified on Mojo 1.0.0 (ed45d567): zero-initialised, one stable address across
call sites, and stores survive `mojo precompile` — an app linking m0-http's
`.mojoc` reads back what m0-http wrote.

`@no_inline` IS LOAD-BEARING

`pop.global_alloc` is marked `Pure`, so every inlined copy materialises its
OWN global: the accessors would hand back sequential addresses and stores
would be lost. Do not remove it, and do not add `@always_inline`.

THE SLOTS ARE PRIVATE TO m0-http

`internal` linkage means one emission per module image. Keeping every read and
write inside this package is what guarantees writer and reader address the
same word. Apps never touch these slots; they call `install_shutdown_signals`
and get an fd back.

FORK MAKES A COPY, NOT A SHARE

The data segment is copy-on-write, so after `fork()` each process has its own
slots. That is exactly right for a shutdown fd — every worker wants its own —
and exactly wrong for anything workers must agree on. Cross-process state uses
`SharedAtomics` in `multiworker.mojo` (`mmap(MAP_SHARED)`); do not reach for
this file instead.

FAILURE MODE

The slots read zero until something fills them. If a toolchain change ever
stops honouring `@no_inline` here, `slot_is_live()` reports it and
`install_shutdown_signals` declines to install a handler at all, leaving the
default termination behaviour. That fallback is what makes depending on an
internal compiler interface affordable — see `src/signal.mojo`.

`__mlir_op` has no stability guarantee and `_get_kgen_string` is a private
stdlib import. Both are deliberate, and both are covered by tests in
`test/test_lifecycle.mojo`.
"""

from std.collections.string.string_span import _get_kgen_string

from lightbug_http.c.process import getpid


comptime MAX_TRACKED_CHILDREN = 64
"""Child PIDs the supervisor's signal handler can propagate to.

Past this, propagation covers the first `MAX_TRACKED_CHILDREN`; the parent's
ordinary `_kill_all` path is unaffected and still reaches every child.
"""


@no_inline
def _shutdown_fd_slot() -> Pointer[Int, MutUntrackedOrigin]:
    """Return the one-word slot holding the shutdown pipe's write fd.

    Zero until `set_shutdown_write_fd` fills it. `@no_inline` is required for
    the address to be stable — see this file's header.

    Returns:
        A pointer to this module image's shutdown-fd slot.
    """
    return {
        _mlir_value = __mlir_op.`pop.global_alloc`[
            name = _get_kgen_string["m0_http_shutdown_write_fd"](),
            count = Int(1).__mlir_index__(),
            _type = Pointer[Int, MutUntrackedOrigin]._mlir_type,
            alignment = Int(8).__mlir_index__(),
        ]()
    }


comptime _OWNER_WORD = MAX_TRACKED_CHILDREN + 1
"""The child-PID block's last word: the PID of the process that published it."""


@no_inline
def _child_pid_slot() -> Pointer[Int, MutUntrackedOrigin]:
    """Return the block holding the supervisor's child PIDs.

    Word 0 is the count; words 1..`MAX_TRACKED_CHILDREN` are the PIDs; the
    word after them (`_OWNER_WORD`) is the PID of the process that
    published them. `@no_inline` is required for the address to be stable —
    see this file's header.

    Returns:
        A pointer to this module image's child-PID block.
    """
    return {
        _mlir_value = __mlir_op.`pop.global_alloc`[
            name = _get_kgen_string["m0_http_child_pids"](),
            count = Int(_OWNER_WORD + 1).__mlir_index__(),
            _type = Pointer[Int, MutUntrackedOrigin]._mlir_type,
            alignment = Int(8).__mlir_index__(),
        ]()
    }


@no_inline
def _supervisor_stopping_slot() -> Pointer[Int, MutUntrackedOrigin]:
    """Return the one-word slot the supervisor's handler sets on SIGTERM/SIGINT.

    It holds the signal number, 0 until a stop is recorded. `@no_inline` is
    required for the address to be stable — see this file's header.

    Returns:
        A pointer to this module image's supervisor-stopping slot.
    """
    return {
        _mlir_value = __mlir_op.`pop.global_alloc`[
            name = _get_kgen_string["m0_http_supervisor_stopping"](),
            count = Int(1).__mlir_index__(),
            _type = Pointer[Int, MutUntrackedOrigin]._mlir_type,
            alignment = Int(8).__mlir_index__(),
        ]()
    }


def record_supervisor_stop(sig: Int):
    """Record that the supervisor has been told to stop, and by which signal.

    Async-signal-safe: one aligned word store. The number is kept so the
    supervisor can send a child the handler could not reach the same signal
    it passed on to the rest (`WorkerSupervisor._publish_children`).

    Args:
        sig: The signal received, SIGTERM or SIGINT; never 0.
    """
    _supervisor_stopping_slot()[] = sig


def clear_supervisor_stop():
    """Forget a recorded stop: a forked child starts with none of its own."""
    _supervisor_stopping_slot()[] = 0


def supervisor_stopping() -> Bool:
    """Whether the supervisor has been told to stop (SIGTERM or SIGINT)."""
    return _supervisor_stopping_slot()[] != 0


def supervisor_stop_signal() -> Int:
    """The signal the supervisor was told to stop by, or 0 if it has not been."""
    return _supervisor_stopping_slot()[]


def set_shutdown_write_fd(fd: Int):
    """Publish the shutdown pipe's write fd for the signal handler to find.

    Args:
        fd: Write end of the pipe the event loop watches, or 0 to clear.
    """
    _shutdown_fd_slot()[] = fd


def shutdown_write_fd() -> Int:
    """Read the shutdown pipe's write fd, or 0 if none has been published.

    Async-signal-safe: one aligned word load, no allocation.

    Returns:
        The write fd, or 0 meaning "no handler should act".
    """
    return _shutdown_fd_slot()[]


def slot_is_live() -> Bool:
    """Report whether a store to the shutdown slot is actually readable back.

    The one thing a caller must check before installing a handler that depends
    on it. Writes a probe value, reads it back, and restores what was there —
    so it is safe to call at any time, but it is meant for startup.

    Returns:
        True if the data-segment slot behaves; False if the `@no_inline`
        guarantee has silently broken.
    """
    var saved = shutdown_write_fd()
    comptime probe = 0x6D30_5F31  # "m0_1"
    set_shutdown_write_fd(probe)
    var ok = shutdown_write_fd() == probe
    set_shutdown_write_fd(saved)
    return ok


def publish_child_pids(pids: List[Int]):
    """Publish the supervisor's child PIDs where its signal handler can read them.

    The handler can run part-way through this, so the count is ordered against
    the PIDs it guards: growing publishes the PIDs first and the count last,
    shrinking publishes the count first. Either way the handler never reads a
    slot past the count that has not been written. A PID that has since exited
    just makes `kill` return ESRCH.

    A vacant index — `WorkerSupervisor` writes -1 there, because position is
    the worker index and the list must never compact — is published as 0.
    Handing -1 to `kill(2)` would signal *every process the caller can reach*,
    so the reader guards against it too.

    The block also records WHO published it (`child_pids_owner`): a forked
    child inherits its parent's block with its parent's handler, and the
    handler passes a signal on only in the process whose list it is.

    Args:
        pids: Child PIDs by worker index, -1 or 0 for a vacant one. Beyond
            `MAX_TRACKED_CHILDREN` the tail is dropped — the supervisor's
            ordinary `_kill_all` still reaches every child.
    """
    var block = _child_pid_slot()
    block[unsafe_offset = _OWNER_WORD] = getpid()
    var n = len(pids)
    if n > MAX_TRACKED_CHILDREN:
        n = MAX_TRACKED_CHILDREN
    var shrinking = n < block[]
    if shrinking:
        block[] = n
    for i in range(n):
        block[unsafe_offset = i + 1] = pids[i] if pids[i] > 0 else 0
    if not shrinking:
        block[] = n


def child_pid_count() -> Int:
    """Return how many child PIDs are published.

    Async-signal-safe: one aligned word load, no allocation.

    Returns:
        The published count, 0 before any `publish_child_pids` call.
    """
    return _child_pid_slot()[]


def child_pid_at(index: Int) -> Int:
    """Return one published child PID.

    Async-signal-safe: one aligned word load, no allocation.

    Args:
        index: Position in `[0, child_pid_count())`.

    Returns:
        The PID, 0 for a vacant index, and 0 if `index` is out of range.
    """
    if index < 0 or index >= MAX_TRACKED_CHILDREN:
        return 0
    var pid = _child_pid_slot()[unsafe_offset = index + 1]
    return pid if pid > 0 else 0


def child_pids_owner() -> Int:
    """Return the PID of the process that last published the child PIDs.

    Async-signal-safe: one aligned word load, no allocation.

    Returns:
        That PID, or 0 before any `publish_child_pids` call. In a child forked
        since, it is still the parent's until the child publishes its own.
    """
    return _child_pid_slot()[unsafe_offset = _OWNER_WORD]
