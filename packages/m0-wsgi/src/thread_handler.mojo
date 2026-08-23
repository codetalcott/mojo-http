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


struct ThreadContext(Copyable, Movable):
    """What a handler factory is handed: which thread, and the app's spec."""

    var index: Int
    var user: Int
    """The address passed to `ThreadedServer.serve` — the app's own spec."""

    def __init__(out self, index: Int, user: Int):
        self.index = index
        self.user = user
