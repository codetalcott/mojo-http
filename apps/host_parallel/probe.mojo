"""The Mojo host with MAX's parallel runtime linked: `smoke-parallel-runtime`'s
app (SPEC E32).

    GET  /health  answered on the loop
    GET  /par     one CPU job spread over the runtime's workers with
                  `max.algorithm.parallelize`; `x-thread` names the pool
                  thread that answered, or -1 for the loop
    GET  /ser     the same job on the serving thread alone

The body of either is `par=<us>us sum=<n>` or `ser=<us>us sum=<n>`: the
job's own time and a digest of its result, so the gate can see the two
routes agree and can record what the split cost.

The entry file is `probe.mojo`, not `server.mojo`, on purpose: `build-apps`
compiles every `apps/*/server.mojo` inside `test-all`, whose venv does not
hold MAX (`pyproject.toml`'s `max` group is synced by the two MAX smokes'
CI steps alone), and `from max.algorithm import parallelize` resolves only
there.
Everything else about it is a host application like any other.

The job lives in `compute.mojo`, shared with `apps/serve_parallel`, the
m0serve mount that links the same runtime (SPEC E33): 64 items of 100,000
square roots -- about 12 ms on one thread of a 2.8 GHz Xeon, 4 to 7 ms
spread over four -- big enough for the split to show and small enough to
run eight at once inside a smoke's patience.
"""

from lightbug_http import HTTPRequest, HTTPResponse
from m0_host.host import HostContext, ViewState, ViewsApp, serve
from m0_host.flags import host_config
from m0_http import Views, reply

from host_parallel.compute import timed


def health(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    return reply.html(String("ok"))


def par(req: HTTPRequest, params: List[String], st: Probe) raises -> HTTPResponse:
    return timed(True, st.thread)


def ser(req: HTTPRequest, params: List[String], st: Probe) raises -> HTTPResponse:
    return timed(False, st.thread)


struct Probe(ViewState):
    """Which instance answered: the loop's (-1) or a pool thread's."""

    var thread: Int

    def __init__(out self, thread: Int):
        self.thread = thread

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return Probe(ctx.thread)

    @staticmethod
    def urls() raises -> Views[Self]:
        var v = Views[Self]()
        v.add_loop("GET", "/health", health)
        v.add_read("GET", "/par", par)
        v.add_read("GET", "/ser", ser)
        return v^


def main() raises:
    serve[ViewsApp[Probe]](host_config())
