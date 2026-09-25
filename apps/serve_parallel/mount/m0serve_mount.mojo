"""An m0serve mount that links MAX's parallel runtime: `smoke-serve-parallel-runtime`'s
binary (SPEC E33).

Built with `M0SERVE_MOUNT_DIR=apps/serve_parallel/mount M0SERVE_INCLUDE=apps`
(the module's own root, for `host_parallel.compute`), which REPLACES the
demo mount (SPEC N14). Two routes under the lane's prefix:

    GET  PREFIX/par   one job spread with `max.algorithm.parallelize`
    GET  PREFIX/ser   the same job on the pool thread alone

The body is `par=<us>us sum=<n>` or `ser=<us>us sum=<n>`, as the host's
probe answers it, and `x-thread` names the pool thread. The point of the
binary is what it links: `compute.mojo`'s import puts
`libAsyncRTMojoBindings` in the image, and m0serve reads that fact to
refuse a forked worker (`--workers N`, `--reload`) and to accept a spawned
one (`--spawn-workers`), which execs and starts the runtime fresh.
"""

from lightbug_http import HTTPRequest, HTTPResponse
from m0_http import Mount, PoolContext, PoolHandler, Views

from host_parallel.compute import timed


struct ParState(Movable):
    """Which pool thread answered, and the lane's prefix for its links."""

    var thread: Int
    var at: Mount

    def __init__(out self, thread: Int, var at: Mount):
        self.thread = thread
        self.at = at^


def par(req: HTTPRequest, params: List[String], st: ParState) raises -> HTTPResponse:
    return timed(True, st.thread)


def ser(req: HTTPRequest, params: List[String], st: ParState) raises -> HTTPResponse:
    return timed(False, st.thread)


def par_urls(at: Mount) raises -> Views[ParState]:
    var v = Views[ParState](at)
    v.add_read("GET", "/par", par)
    v.add_read("GET", "/ser", ser)
    return v^


struct MojoMount(PoolHandler):
    """One instance per pool thread, over the lane's prefix."""

    var views: Views[ParState]
    var state: ParState

    def __init__(out self, var views: Views[ParState], var state: ParState):
        self.views = views^
        self.state = state^

    @staticmethod
    def make(ctx: PoolContext) raises -> Self:
        var at = Mount(ctx.prefix)
        return Self(par_urls(at), ParState(ctx.index, at))

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return self.views.dispatch(req, self.state)

    def shutdown(mut self):
        pass
