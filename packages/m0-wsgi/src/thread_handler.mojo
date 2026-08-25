"""The seam a serving thread constructs its handler through.

`ThreadHandler` and `ThreadContext` live here rather than in `threaded.mojo`
because BOTH thread users need them — the loop-per-thread mode
(`--threads N`) and the handler pool behind `--blocking-threads N` — and
`threaded.mojo` needs `BlockingPool`. One small module both import breaks
what would otherwise be a cycle between them.

The trait is the whole reason `HTTPService` never had to grow a method for
any of this: `ThreadHandler` EXTENDS it. Everything the event loop calls is
unchanged, and the one thing a thread additionally needs — "build yourself,
here, now" — is stated where only threads can see it.
"""

from lightbug_http import HTTPService


trait ThreadHandler(HTTPService, Movable, Deinitable):
    """An `HTTPService` that can construct itself on a serving thread.

    `make` is called ON each thread, inside its attached region, with the
    thread's index and the address the app passed to `ThreadedServer.serve`
    (its own spec). Everything the handler owns — the `WSGIApp`, its
    bridge — is therefore created and destroyed on the thread that uses it.
    A trait rather than a function parameter because Mojo 1.0 cannot
    materialize a function-parameterized `def` as a runtime value (the
    address a pthread needs); a type parameter it can.
    """

    @staticmethod
    def make(ctx: ThreadContext) raises -> Self:
        ...

    def set_asgi_notify(mut self, fd: Int):
        """Where ASGI stream disconnect tags go (the submit channel's
        write end), set by the executor-mode wiring after the pool exists
        — per loop, which is why it cannot ride the shared options. A
        handler with no ASGI streams ignores it.
        """
        ...

    def shutdown(mut self):
        """Teardown the handler owes its application before destruction.

        Called once, on the thread that owns the handler, inside its
        attached region, after its serving loop has finished. Stated here
        for the same reason as `make`: only the thread choreography knows
        when "after the loop, before the destructors" is, and the generic
        `_pool_serve`/`_serve_one` bodies can only call what the trait
        names. Today this is ASGI lifespan shutdown; a WSGI handler's is a
        no-op. Must not raise — teardown has nowhere to send an error.
        """
        ...


struct ThreadContext(Copyable, Movable):
    """What a handler factory is handed: which thread, and the app's spec."""

    var index: Int
    var user: Int
    """The address passed to `ThreadedServer.serve` — the app's own spec."""
    var lane: Int
    """Which mount this thread serves, or -1 for "every mount".

    A `--blocking-threads` pool thread bound to one mount's submit lane
    builds only that mount's application: building all of them per thread
    would run one lifespan per mount per thread and carry N applications'
    worth of interpreter state for jobs it can never receive. -1 is the
    unmounted case and the `--threads` serving loops, which own every
    mount because they route in Mojo before dispatching.
    """

    def __init__(out self, index: Int, user: Int, lane: Int = -1):
        self.index = index
        self.user = user
        self.lane = lane
