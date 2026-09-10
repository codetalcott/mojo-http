"""A URL table that names view functions directly.

`Router` answers *which* route matched, as an integer. Turning that integer
back into code has been every app's own business, and all three Mojo apps
in this tree do it the same way: a `comptime H_GET = 2` block, a
`router.add("GET", "/notes/:id", H_GET)` call, and an
`if m.handler_id == H_GET: return self._get_one(...)` chain. The URL and
the code that answers it are three edits apart, and nothing checks that
they agree — `apps/notes_api` ends its chain with a bare
`return self._delete(req, id)`, so a route added without a matching arm
does not 404, it deletes.

This module removes the integer from the app's view. `add` takes the
function, assigns the id itself and stores the two together, so a route
cannot be registered without a view or point at the wrong one. What an app
writes is the mapping and nothing else:

```mojo
views.add("GET", "/notes", list_notes)
views.add("GET", "/notes/:id", note_detail)
```

A **view** is a plain function — not a method, not a struct, not a trait
conformance:

```mojo
def note_detail(
    req: HTTPRequest, params: List[String], mut state: AppState
) raises -> HTTPResponse:
    ...
```

Three arguments rather than Python's one, and each is a constraint of the
language rather than a taste:

- `req` is **borrowed**, so passing it costs nothing and the view type
  names no origin. A wrapper struct holding a `Pointer[HTTPRequest, o]`
  would put `o` in the stored function type and the table could no longer
  be one uniform list; a wrapper that *owned* the request would copy it
  per dispatch, which is the allocation `Router.match` is written to
  avoid. So captured parameters ride beside the request instead of inside
  it.
- `params` carries the `:id` captures in registration order, borrowed
  from the `MatchResult`. `reply.param_int` is the usual next call.
- `state` is what Django reaches through a module-level global. Mojo has
  no global `var`, and this framework could not use one anyway: under
  `--threads` a `WSGIApp`, an `SSERegistry` and an m0-sqlite `Connection`
  are per-thread by rule, so the thing a view needs is the *caller's*
  state, handed in. The parameter is that rule made visible.

Views are stored as `thin` function pointers, which is what makes them
`Movable` and so storable in a `List`. A capturing closure is not, which
means there is no way to wrap a view in a decorator and put the result
back in the table. Guards are therefore written as early returns inside
the view — the shape a flat, readable view wanted anyway.
"""

from lightbug_http.header import HeaderKey
from lightbug_http.http import HTTPRequest, HTTPResponse

from .reply import problem
from .router import Router


struct Views[S: Movable]:
    """A `Router` and the view functions its handler ids stand for.

    Parameterized on the application's state type, which every view of a
    given table receives as its third argument.
    """

    comptime View = def (
        HTTPRequest, List[String], mut Self.S
    ) raises thin -> HTTPResponse
    """What a view is: request, captured parameters, application state."""

    var router: Router
    """Exposed because `allow_header` is the app's business on a preflight."""

    var _fns: List[Self.View]
    """Indexed by the handler id `add` assigned. Parallel to nothing else —
    the id IS the index, which is what makes drift unrepresentable."""

    var _not_found: Optional[Self.View]

    def __init__(out self):
        self.router = Router()
        self._fns = List[Self.View]()
        self._not_found = None

    def add(mut self, method: String, pattern: String, view: Self.View):
        """Register `view` for `method pattern`.

        The handler id is this function's own business; an app never sees
        one and so cannot get one wrong.
        """
        self.router.add(method, pattern, len(self._fns))
        self._fns.append(view)

    def set_not_found(mut self, view: Self.View):
        """Answer unmatched paths with `view` instead of RFC 9457 problem+json.

        A 404 an app wants to *style* is a page, and a page is a view. The
        default stays machine-readable because most of this framework's
        callers are not browsers.
        """
        self._not_found = view

    def route_count(self) -> Int:
        """How many routes are registered. One per `add`."""
        return len(self._fns)

    def dispatch(
        self, req: HTTPRequest, mut state: Self.S
    ) raises -> HTTPResponse:
        """Match `req` and call the view that owns it.

        Answers 405 with the `Allow` header RFC 9110 requires, and 404
        through `set_not_found`'s view when one was given. Every path
        returns a response; there is no fallthrough to guess about.
        """
        var path = req.uri.path
        var m = self.router.match(req.method, path)

        if m.matched:
            return self._fns[m.handler_id](req, m.params, state)

        if m.method_not_allowed:
            var resp = problem(
                405,
                String("Method Not Allowed"),
                String(req.method, " is not supported by ", path),
                path,
            )
            resp.headers[HeaderKey.ALLOW] = self.router.allow_header(path)
            return resp^

        if self._not_found:
            return self._not_found.value()(req, m.params, state)
        return problem(
            404, String("Not Found"), String("no route for this path"), path
        )
