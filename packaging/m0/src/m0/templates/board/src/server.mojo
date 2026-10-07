"""`__M0_APP__` — a list every tab shares: a message one tab posts reaches every open tab.

    GET  /          the document: the form, and the board as it stands
                    (Datastar opens /events from data-init)
    GET  /events    the stream: the newest board at open, then one frame
                    per message
    POST /messages  a urlencoded form carrying `text`: adds it, sends the
                    board to every open stream, and answers the signal
                    patch that empties the poster's input
    GET  /health    {"status":"ok"}, answered on the loop

A VIEW sends here, not a producer: `post` in `views.mojo` appends to the
list and publishes the whole board through the state's `DatastarStream`.
A producer is for work on a cadence (`m0 new --template live`).

The list lives in this process, so `max_workers() -> 1`, and every view
that touches it runs on the event loop (`on_loop=True`): under
`--blocking-threads N` each pool thread builds a state of its own, whose
stream nothing drains.

`views.mojo` holds the state and the table, `pages.mojo` the rendering.
This file is the whole of `main`: the host owns the listener, the signals
and the drain (`uv run m0 doctor` prints what it resolved).

Build it:  uv run m0 build      Test it:  uv run m0 test
"""

from m0_host.flags import host_config
from m0_host.host import ViewsApp, serve

from views import Board


def main() raises:
    # With the command line applied, so the address printed here is the one
    # `serve` binds under `--host` and `--port`.
    var config = host_config()
    print(String("__M0_APP__ on ", config.base_url), flush=True)
    serve[ViewsApp[Board]](config)
