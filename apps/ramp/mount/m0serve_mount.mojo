"""The ramp module as an `m0serve` mount: `--mount /x=mojo`.

Built with `M0SERVE_MOUNT_DIR=apps/ramp/mount M0SERVE_INCLUDE=apps` (the
module's own root, for `ramp.views`), which REPLACES the demo mount
(`packages/m0-wsgi/mount/`, SPEC N14). The adapter is the whole file: the
prefix comes from the lane (`PoolContext.prefix`, what `--mount` was
given), and the table and state are the module's, built the way the host
builds them. Nothing here is the ramp's own business.
"""

from lightbug_http import HTTPRequest, HTTPResponse, PoolContext, PoolHandler
from m0_http import Mount, Views
from ramp.views import Ramp, ramp_urls


struct MojoMount(PoolHandler):
    """One instance per pool thread, over the lane's prefix."""

    var views: Views[Ramp]
    var state: Ramp

    def __init__(out self, var views: Views[Ramp], var state: Ramp):
        self.views = views^
        self.state = state^

    @staticmethod
    def make(ctx: PoolContext) raises -> Self:
        var at = Mount(ctx.prefix)
        return Self(ramp_urls(at), Ramp.generate(at))

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return self.views.dispatch(req, self.state)

    def shutdown(mut self):
        pass
