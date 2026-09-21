"""`__M0_APP__` — a server-rendered list, swapped in place by htmx 4.

    GET    /            303 to /items
    GET    /items       the list: a whole document, or the bare fragment
                        when the request says `HX-Request-Type: partial`
    POST   /items       a urlencoded form carrying `title`; answers the list.
                        An empty title is a 422 whose body is the list with
                        the error in it — htmx 4 swaps a 4xx like any answer
    GET    /items/:id   one item, page or fragment the same way
    DELETE /items/:id   removes it, answers the list
    GET    /health      {"status":"ok"}, answered on the loop

`views.mojo` holds the state and the table, `pages.mojo` the rendering.
This file is the whole of `main`: the host owns the listener, the workers,
the signals and the drain (`uv run m0 doctor` prints what it resolved).

Build it:  uv run m0 build      Test it:  uv run m0 test
"""

from m0_host.flags import host_config
from m0_host.host import ViewsApp, serve

from views import Items


def main() raises:
    # With the command line applied, so the address printed here is the one
    # `serve` binds under `--port`.
    var config = host_config()
    print(String("__M0_APP__ on ", config.base_url), flush=True)
    serve[ViewsApp[Items]](config)
