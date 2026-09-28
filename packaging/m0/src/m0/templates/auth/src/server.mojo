"""`__M0_APP__` — a list behind a login, swapped in place by htmx 4.

    GET    /            303 to /items
    GET    /login       the login form
    POST   /login       a plain form carrying `user` and `password`: a 303 to
                        /items that sets the session cookie, or a 401 whose
                        body is the form with the error in it
    POST   /logout      expires the cookie: a 303 to /login
    GET    /items       the list: a whole document, or the bare fragment
                        when the request says `HX-Request-Type: partial`.
                        Signed out, a navigation is a 303 to /login and a
                        swap is a 401 carrying the login form
    POST   /items       a urlencoded form carrying `title` and `csrf`;
                        answers the list. An empty title is a 422 whose
                        body is the list with the error in it
    GET    /items/:id   one item, page or fragment the same way
    DELETE /items/:id   removes it, the token in the `X-CSRF-Token` header;
                        answers the list
    GET    /health      {"status":"ok"}, answered on the loop

Every view but the login's needs a session, and every write the session's
CSRF token: a write without it is a 403. One user, configured in the
environment: `APP_KEY` (at least 32 bytes; `openssl rand -hex 32`),
`APP_PASSWORD` and `APP_SECURE` (`1` behind HTTPS, as `deploy/fly.toml`
states it; `0` over http://localhost), and optionally `APP_USER` (admin),
`APP_TTL` (3600 s) and `APP_KEY_PREV` during a key rotation. Without the
three it does not start: exit 78, naming the variable.

`views.mojo` holds the state and the table, `pages.mojo` the rendering.
This file is the whole of `main`: the host owns the listener, the workers,
the signals and the drain (`uv run m0 doctor` prints what it resolved).

Build it:  uv run m0 build      Test it:  uv run m0 test
"""

from std.sys import exit

from m0_host.flags import host_config
from m0_host.host import ViewsApp, serve

from views import Items, login_from_env


def main() raises:
    # With the command line applied, so the address printed here is the one
    # `serve` binds under `--port`.
    var config = host_config()
    # The login's configuration, read BEFORE `serve`: a missing variable is
    # then refused under `--doctor` too, which reaches no `make`. Each
    # `Items.make` reads it again.
    try:
        _ = login_from_env()
    except e:
        print(String("__M0_APP__: ", e), flush=True)
        exit(78)
    print(String("__M0_APP__ on ", config.base_url), flush=True)
    serve[ViewsApp[Items]](config)
