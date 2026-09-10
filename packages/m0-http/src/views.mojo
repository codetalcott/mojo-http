"""A URL table that names view functions directly, and the service that runs it.

`Router` answers *which* route matched, as an integer. Turning that integer
back into code has been every app's own business, and all three Mojo apps
in this tree do it the same way: a `comptime H_GET = 2` block, a
`router.add("GET", "/notes/:id", H_GET)` call, and an
`if m.handler_id == H_GET: return self._get_one(...)` chain. The URL and
the code that answers it are three edits apart, and nothing checks that
they agree — `apps/notes_api` ends its chain with a bare
`return self._delete(req, id)`, so a route added without a matching arm
does not 404, it deletes.

This module removes the integer from the app's view. `add_read` and
`add_write` take the function, assign the id themselves and store the two
together, so a route cannot be registered without a view or point at the
wrong one. What an app writes is the mapping and nothing else:

```mojo
views.add_read("GET", "/notes", list_notes)
views.add_write("POST", "/notes", create_note)
```

A **view** is a plain function — not a method, not a struct, not a trait
conformance:

```mojo
def note_detail(
    req: HTTPRequest, params: List[String], store: AppState
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
  from the `MatchResult`. `reply.param_int` is the usual next call. The
  positions are the residual weakness of this design and the module
  docstring's last section says why they stay.
- `state` is what Django reaches through a module-level global. Mojo has
  no global `var`, and this framework could not use one anyway: under
  `--threads` a `WSGIApp`, an `SSERegistry` and an m0-sqlite `Connection`
  are per-thread by rule, so the thing a view needs is the *caller's*
  state, handed in. The parameter is that rule made visible.

## Reading views cannot write

There are two tables, and registering a view means saying which it is.
A view added with `add_read` receives the state **borrowed**, so a write
to it does not compile; `add_write` receives it `mut`. Nothing infers this
from the method — a GET that bumps a counter is ordinary and registers as
a write — but having to name it is the point, and it is checked rather
than documented.

This is the one place the translation gains something Python cannot state.
Django has no way to say a view does not write, and this framework has a
specific reason to care: shared mutable state across serving threads is a
measured 0.7x cliff (docs/notes/wsgi-vs-asgi-history.md §5), so which
views mutate is a question the deployment shape actually asks.

## Views are stored as thin function pointers

`fn` is gone in Mojo 1.0 and a function type spells `def (...) -> ...`,
but that type is an existential and is not `Movable`, so it cannot go in a
`List`. The compiler's own error message names the storable one:
`raises thin`. A capturing closure is not thin either, which means there is
no way to wrap a view in a decorator and put the result back in the table.
Guards are therefore written as early returns inside the view — the shape a
flat, readable view wanted anyway.

## What positional parameters cost, and why they stay

`params[0]` is an index, and an index can drift against the pattern the
same way a handler id drifted against its dispatch arm: insert a segment
before an existing capture and every view reading that route silently
shifts by one. The router already carries the names — `add` stores `:name`
minus the colon, and says in a comment that matching never reads it — so a
named lookup is not a data problem.

It is a type problem. A `RouteParams` that *borrowed* the names needs a
`Pointer`, so an origin as a struct parameter, and origins are not
spellable as struct parameters on the pinned toolchain (probed: none of
`ImmutableAnyOrigin`, `Origin[False]`, `Origin[False]._mlir_type` or
`type_of(MutUntrackedOrigin)` resolve). One that *owned* them allocates a
`String` per name per request, doubling what a matched route allocates, on
a hot path whose docstring exists to say it allocates nothing on a miss.
Passing names as a fourth borrowed argument is free but puts two adjacent
`List[String]` arguments in every signature, which is its own footgun.

So positions stay, and the mitigation is a convention rather than a type:
a view with more than one capture names them on its first lines, which
localises the damage to those lines instead of spreading it through the
body.
"""

from lightbug_http.header import HeaderKey
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.service import HTTPService

from .reply import problem
from .router import Router


struct Views[S: Movable]:
    """A `Router` and the view functions its handler ids stand for.

    Parameterized on the application's state type, which every view of a
    given table receives as its third argument.
    """

    comptime ReadView = def (
        HTTPRequest, List[String], Self.S
    ) raises thin -> HTTPResponse
    """A view that does not write: the state arrives borrowed."""

    comptime WriteView = def (
        HTTPRequest, List[String], mut Self.S
    ) raises thin -> HTTPResponse
    """A view that may write: the state arrives `mut`."""

    comptime LoopView = def (HTTPRequest, List[String]) thin -> HTTPResponse
    """A view answered on the EVENT LOOP, before the request becomes a job.

    It receives **no state**, and that is a correctness rule rather than a
    simplification. Under `--blocking-threads` each pool thread owns a whole
    handler of its own, built on the thread that will use it
    (`mojo_pool.mojo`: "Nothing in a handler is shared between pool threads
    unless the handler itself shares it"). The loop has its own handler too.
    So a view answered on the loop would read the LOOP instance's state
    while every other view read a pool thread's — the same URL returning
    different answers depending on where it ran. Giving a loop view nothing
    to read is what makes that unrepresentable.

    Non-raising, because `HTTPService.before_request` is.
    """

    var router: Router
    """Exposed because `allow_header` is the app's business on a preflight."""

    var loop_router: Router
    """Loop routes only, kept apart from `router` on purpose.

    `before_request` runs for every request, so matching loop routes against
    the whole table would route twice on every request that is not one. A
    second router holding one or two routes makes the loop's check a scan of
    one or two routes instead.
    """

    var _reads: List[Self.ReadView]
    var _writes: List[Self.WriteView]

    var _is_read: List[Bool]
    """Indexed by the handler id: which table `_slot` indexes."""
    var _slot: List[Int32]
    """Indexed by the handler id: the position within that table.

    The router's id space is one list; the two view tables are separate
    because their types differ. These two arrays are what joins them, and
    only `add_read`/`add_write` write to them — which is what keeps a route
    from ever naming a view that is not there.
    """

    var _loops: List[Self.LoopView]

    var _not_found: Optional[Self.ReadView]

    def __init__(out self):
        self.router = Router()
        self.loop_router = Router()
        self._reads = List[Self.ReadView]()
        self._writes = List[Self.WriteView]()
        self._is_read = List[Bool]()
        self._slot = List[Int32]()
        self._loops = List[Self.LoopView]()
        self._not_found = None

    def add_read(mut self, method: String, pattern: String, view: Self.ReadView):
        """Register a view that does not write. State arrives borrowed."""
        self.router.add(method, pattern, len(self._is_read))
        self._is_read.append(True)
        self._slot.append(Int32(len(self._reads)))
        self._reads.append(view)

    def add_write(mut self, method: String, pattern: String, view: Self.WriteView):
        """Register a view that may write. State arrives `mut`."""
        self.router.add(method, pattern, len(self._is_read))
        self._is_read.append(False)
        self._slot.append(Int32(len(self._writes)))
        self._writes.append(view)

    def add_loop(mut self, method: String, pattern: String, view: Self.LoopView):
        """Register a view answered on the loop, without becoming a job.

        For the routes that must not pay an offload round trip and have no
        state to read: health checks, `robots.txt`, a redirect. `WSGIHandler`
        answers its static mounts and its health path this way for the same
        reason. Keep the body quick — it runs on the thread every other
        connection is waiting on.
        """
        self.loop_router.add(method, pattern, len(self._loops))
        self._loops.append(view)

    def answer_on_loop(self, req: HTTPRequest) -> Optional[HTTPResponse]:
        """The `before_request` body: a loop route's answer, or nothing.

        A miss returns None and the request goes on to `dispatch` as usual,
        so a 404 here is never this table's to give.
        """
        if len(self._loops) == 0:
            return None
        var m = self.loop_router.match(req.method, req.uri.path)
        if not m.matched:
            return None
        return self._loops[m.handler_id](req, m.params)

    def set_not_found(mut self, view: Self.ReadView):
        """Answer unmatched paths with `view` instead of RFC 9457 problem+json.

        A 404 an app wants to *style* is a page, and a page is a view. It is
        a reading one: a request that matched no route has no business
        writing. The default stays machine-readable because most of this
        framework's callers are not browsers.
        """
        self._not_found = view

    def route_count(self) -> Int:
        """How many routes are registered. One per `add_read`/`add_write`."""
        return len(self._is_read)

    def loop_route_count(self) -> Int:
        """How many loop routes are registered. One per `add_loop`."""
        return len(self._loops)

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
            var slot = Int(self._slot[m.handler_id])
            if self._is_read[m.handler_id]:
                return self._reads[slot](req, m.params, state)
            return self._writes[slot](req, m.params, state)

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


struct ViewService[S: Movable & Deinitable](HTTPService):
    """A table and its state, as a handler — so an app writes neither.

    The shell an app used to write for itself is ceremony: hold the table,
    hold the state, delegate. Django never asks anyone to write it, and
    there is no reason to here. `main` becomes

    ```mojo
    var handler = ViewService(urls(), NoteStore())
    server.listen_and_serve_nonblocking(config.address(), handler)
    ```

    This is the convenience, not the pattern. An app that needs the other
    `HTTPService` hooks — `before_request` to answer on the loop thread
    without becoming a pool job, `after_response` for CORS, `tick`,
    `ws_message` — writes its own struct and calls `Views.dispatch` from
    `func`, which is a three-line handler and still has no dispatch chain
    in it.
    """

    var views: Views[Self.S]
    var state: Self.S

    def __init__(out self, var views: Views[Self.S], var state: Self.S):
        self.views = views^
        self.state = state^

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        """Answer a loop route here, so it never becomes a pool job."""
        return self.views.answer_on_loop(req)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return self.views.dispatch(req, self.state)
