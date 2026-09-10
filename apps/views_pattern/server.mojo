"""The pattern: a view is a function, and one table maps URLs to views.

Built from
https://spookylukey.github.io/django-views-the-right-way/the-pattern.html,
translated to Mojo. The article's claim is that a view's three essential
elements — a function, a request in, a response out — should be visible in
the code, and that class-based views hide all three. Its recommended
starting point is:

    def example_view(request: HttpRequest, arg: str) -> HttpResponse:
        return TemplateResponse(request, 'example.html', {})

The Mojo equivalent, and what each difference is paying for:

    def detail(
        req: HTTPRequest, params: List[String], mut store: NoteStore
    ) raises -> HTTPResponse:
        var page = store.note_page(reply.param_int(params[0]))
        if not page:
            return _missing(req.uri.path)
        return reply.html(render_note(page.value()))

- **Captured URL parameters arrive as a list, not as named arguments.** A
  table of views must hold one uniform function type, and Mojo cannot vary
  arity across it. Wrapping the request and its captures in one struct was
  the alternative and it costs more: the wrapper needs a
  `Pointer[HTTPRequest, o]` and so an origin parameter, which lands in the
  stored function type and stops the table being one list.
- **State is a parameter.** Django's views reach a module-level global.
  Mojo has no global `var`, and under `--threads` this framework requires
  per-thread state anyway, so the caller's state is handed in. The
  argument is that rule made visible rather than a workaround for it.
- **No `TemplateResponse`.** Its job is to keep the template and context
  inspectable instead of rendering eagerly, which needs `dict[str, Any]`.
  Mojo's answer is a context *struct* and a template *function*
  (`templates.mojo`): a missing field is a compile error rather than a
  blank in the output, and the pure `state -> context` step
  (`store.mojo`) is testable without a request. Late binding is what is
  given up.

Where the files sit mirrors the article's implicit layout:

    templates.mojo   contexts (structs) and templates (functions)
    store.mojo       state, and the pure `state -> context` reads
    views.mojo       the views, the guards, and `urls()` — the whole mapping
    server.mojo      this file: the shell, which stays small on purpose

Run it:  uv run poe serve-views-pattern
Try it:  curl -si localhost:8080/notes
         curl -si -X POST localhost:8080/notes -d '{"title":"hi","body":"yo"}'
"""

from std.os import getenv

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse

from m0_http import AppConfig, HealthRegistry, Views, reply, install_shutdown_signals

from views_pattern.store import NoteStore
from views_pattern.views import urls


struct ViewsHandler(HTTPService):
    """The shell. It owns the table and the state, and answers `/health`.

    Everything an app would otherwise pile into `func` — the dispatch
    chain, the 404, the 405 and its `Allow` header — is `Views.dispatch`.
    What is left here is the two things only the shell can decide: what
    answers before routing, and what the state is.
    """

    var views: Views[NoteStore]
    var store: NoteStore
    var health: HealthRegistry

    def __init__(out self, var api_key: String) raises:
        self.views = urls()
        self.store = NoteStore(api_key^)
        self.health = HealthRegistry()
        self.health.register(String("store"), True)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        # Answered before routing because it is the server's, not the app's.
        if req.uri.path == "/health":
            return reply.json(200, String("OK"), self.health.to_json())
        return self.views.dispatch(req, self.store)


def main() raises:
    var config = AppConfig()
    print("views_pattern on " + config.base_url)
    var server = Server(config.server_config())
    var handler = ViewsHandler(getenv("M0_API_KEY"))
    var shutdown_fd = install_shutdown_signals()
    server.listen_and_serve_nonblocking(
        config.address(), handler, shutdown_read_fd=shutdown_fd
    )
