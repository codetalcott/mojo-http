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
        req: HTTPRequest, params: List[String], store: NoteStore
    ) raises -> HTTPResponse:
        var page = store.note_page(reply.param_int(params[0]))
        if not page:
            return _missing(req.uri.path)
        return reply.html(render_note(page.value()))

- **Captured URL parameters arrive as a list, not as named arguments.** A
  table of views must hold one uniform function type, and Mojo cannot vary
  arity across it. Wrapping the request and its captures in one struct was
  the alternative and it costs more: the wrapper needs a
  `Pointer[HTTPRequest, o]` and so an origin parameter, which is not
  spellable as a struct parameter on this toolchain.
- **State is a parameter, and its mutability is the registration.** Django's
  views reach a module-level global; Mojo has no global `var`, and under
  `--threads` this framework needs per-thread state anyway. `add_read` hands
  it over borrowed and `add_write` hands it over `mut`, so a reading view
  that writes does not compile. `poe sabotage-views` is the gate.
- **No `TemplateResponse`.** Its job is to keep the template and context
  inspectable instead of rendering eagerly, which needs `dict[str, Any]`.
  Mojo's answer is a context *struct* and a template *function*
  (`templates.mojo`): a missing field is a compile error rather than a
  blank in the output, and the pure `state -> context` step
  (`store.mojo`) is testable without a request. Late binding is what is
  given up.
- **The table says WHERE a view runs.** `/health` is registered with
  `add_loop`, so it is answered on the event loop and never becomes a pool
  job. Loop views get no state, because the loop and each pool thread own
  separate handler instances and reading one from the other would answer
  the same URL differently depending on where it ran.

There is no handler struct in this app. `ViewService` is one in the
framework, so `main` is the table, the state, and serve. An app that needs
the other `HTTPService` hooks — `after_response` for CORS, `tick`,
`ws_message` — writes its own three-line struct and calls `Views.dispatch`
from `func`; it still has no dispatch chain in it.

Where the files sit mirrors the article's implicit layout:

    templates.mojo   contexts (structs) and templates (functions)
    store.mojo       state, and the pure `state -> context` reads
    views.mojo       the views, the guards, and `urls()` — the whole mapping
    server.mojo      this file: what is left, which is `main`

Run it:  uv run poe serve-views-pattern
Try it:  curl -si localhost:8080/notes
         curl -si -X POST localhost:8080/notes -d '{"title":"hi","body":"yo"}'
"""

from std.os import getenv

from lightbug_http import Server

from m0_http import AppConfig, ViewService, install_shutdown_signals

from views_pattern.store import NoteStore
from views_pattern.views import urls


def main() raises:
    var config = AppConfig()
    print("views_pattern on " + config.base_url)
    var server = Server(config.server_config())
    var handler = ViewService(urls(), NoteStore(getenv("M0_API_KEY")))
    var shutdown_fd = install_shutdown_signals()
    server.listen_and_serve_nonblocking(
        config.address(), handler, shutdown_read_fd=shutdown_fd
    )
