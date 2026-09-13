"""A mount from somewhere else: what `smoke-mount-seam` builds `m0serve` with.

It stands in for an application's own directory. `M0SERVE_MOUNT_DIR` names
this directory instead of `packages/m0-wsgi/mount/`, so the binary that
comes out serves these routes and not the demo's, and `m0serve.mojo` is
not copied or edited to get there. Kept deliberately unlike the demo --
different routes, different state, a path parameter, a writing view -- so a
build that silently picked up the wrong module cannot pass by accident.
"""

from lightbug_http import PoolContext, PoolHandler, HTTPRequest, HTTPResponse
from m0_http import Mount, Views, reply

comptime SEAM_INDEX = "/"
comptime SEAM_HELLO = "/hello/:name"


@fieldwise_init
struct Greeter(Movable):
    """Per-thread state, as any mount's is: where it is mounted, which
    thread it is, and a counter the writing view advances."""

    var at: Mount
    var thread_index: Int
    var greeted: Int


def seam_index(
    req: HTTPRequest, params: List[String], st: Greeter
) raises -> HTTPResponse:
    """A link, reversed through the mount, for the smoke to follow."""
    return reply.html(
        String('<a href="', st.at.url_for(SEAM_HELLO, String("ada")), '">hello</a>')
    )


def seam_hello(
    req: HTTPRequest, params: List[String], mut st: Greeter
) raises -> HTTPResponse:
    st.greeted += 1
    return reply.json(
        200,
        String("OK"),
        String(
            '{"mount":"fixture","name":"', params[0], '","thread":',
            st.thread_index, ',"greeted":', st.greeted, "}",
        ),
    )


struct MojoMount(PoolHandler):
    """The one name the seam asks for."""

    var views: Views[Greeter]
    var state: Greeter

    def __init__(out self, var views: Views[Greeter], var state: Greeter):
        self.views = views^
        self.state = state^

    @staticmethod
    def make(ctx: PoolContext) raises -> Self:
        var at = Mount(ctx.prefix)
        var v = Views[Greeter](at)
        v.add_read("GET", SEAM_INDEX, seam_index)
        v.add_write("GET", SEAM_HELLO, seam_hello)
        return Self(v^, Greeter(at, ctx.index, 0))

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return self.views.dispatch(req, self.state)

    def shutdown(mut self):
        pass
