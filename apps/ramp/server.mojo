"""The ramp module under the Mojo host: `serve[ViewsApp[Ramp]]`.

The host-side adapter is the `ViewState` conformance in `ramp.views`
(`make`, `urls`); this file is the `main`. `M0_BLOCKING_THREADS=4` puts
the table's `func` on four pool threads with `/x/` and `/x/now` answered
on the loop; unset, everything runs on the loop, which is the placement
gate's negative arm. `smoke-ramp` builds this beside the m0serve binary
from `mount/` and compares the two on the wire.

Run it:  uv run poe serve-ramp
"""

from m0_host.host import ViewsApp, serve

from m0_http import AppConfig
from ramp.views import RAMP_PREFIX, Ramp


def main() raises:
    var config = AppConfig()
    print(
        String(
            "ramp on ", config.base_url, " under ", RAMP_PREFIX, ", ",
            config.blocking_threads, " handler thread(s)",
        ),
        flush=True,
    )
    serve[ViewsApp[Ramp]](config)
