"""An ASGI server validator: the ``wsgiref.validate`` that never got written.

WSGI has a stdlib conformance checker and this repo runs it
(``M0_WSGI_VALIDATE=1`` wraps the Django row in ``wsgiref.validate``).
ASGI has NOTHING standard: the spec lives in the ``asgiref`` package,
whose testing helper plays the server rather than checking one, and
uvicorn/hypercorn/daphne each verify themselves with bespoke suites.
So this is the analog, written from the ASGI 3 spec's HTTP and lifespan
chapters, checking the SERVER'S obligations:

- every scope key the spec requires, with the exact type it requires
  (``method``/``path`` as str, ``query_string``/``raw_path`` and header
  pairs as bytes, ``server``/``client`` as 2-sequences or None) --
  bytes-vs-str confusion is THE classic ASGI server bug, invisible until
  a framework calls ``.decode()`` on a str;
- the receive stream's protocol: ``http.request`` messages with ``body``
  bytes and ``more_body`` bool, never another request after the final
  one, ``http.disconnect`` only ever terminal;
- and, so the engagement canary can exist at all, one app-side rule:
  a message ``type`` the spec does not define is refused.

A violation raises ``AssertionError`` out of the application call; the
server answers 500, so a conformance failure surfaces as a failing
status, never a quiet pass. Off by default for the same reason the WSGI
validator is: it costs per-message checks production should not carry.
"""

_HTTP_SEND_TYPES = frozenset(
    (
        "http.response.start",
        "http.response.body",
        # Extensions a server may accept; validating them is not our job,
        # refusing them would be wrong.
        "http.response.trailers",
        "http.response.push",
    )
)


def _fail(detail):
    raise AssertionError("ASGI validator: " + detail)


def _check_addr(name, value):
    if value is None:
        return
    if not isinstance(value, (tuple, list)) or len(value) != 2:
        _fail("%s must be None or a (host, port) 2-sequence, got %r" % (name, value))
    host, port = value
    if not isinstance(host, str):
        _fail("%s host must be str, got %r" % (name, host))
    if port is not None and not isinstance(port, int):
        _fail("%s port must be int or None, got %r" % (name, port))


def _check_http_scope(scope):
    asgi = scope.get("asgi")
    if not isinstance(asgi, dict) or not isinstance(asgi.get("version"), str):
        _fail("scope['asgi'] must be a dict with a str 'version'")
    for key, kind in (
        ("http_version", str),
        ("method", str),
        ("scheme", str),
        ("path", str),
        ("query_string", bytes),
    ):
        if key not in scope:
            _fail("scope[%r] is required" % key)
        if not isinstance(scope[key], kind):
            _fail(
                "scope[%r] must be %s, got %r"
                % (key, kind.__name__, type(scope[key]).__name__)
            )
    if not scope["method"].isupper():
        _fail("scope['method'] must be uppercase, got %r" % scope["method"])
    if "raw_path" in scope and scope["raw_path"] is not None:
        if not isinstance(scope["raw_path"], bytes):
            _fail("scope['raw_path'] must be bytes")
    headers = scope.get("headers")
    if headers is None:
        _fail("scope['headers'] is required")
    for pair in headers:
        if len(pair) != 2 or not isinstance(pair[0], bytes) or not isinstance(pair[1], bytes):
            _fail("every header pair must be (bytes, bytes), got %r" % (pair,))
        if pair[0] != pair[0].lower():
            _fail("header names must be lowercased, got %r" % (pair[0],))
    _check_addr("scope['server']", scope.get("server"))
    _check_addr("scope['client']", scope.get("client"))


def validator(app):
    async def validated(scope, receive, send):
        if scope["type"] != "http":
            # Lifespan and websocket pass through: this validator's charter
            # is the HTTP chapter, and refusing the others would just turn
            # the wrapper on-ness into a behavior change.
            return await app(scope, receive, send)

        _check_http_scope(scope)
        state = {"final_seen": False, "disconnected": False}

        async def checked_receive():
            message = await receive()
            t = message.get("type")
            if state["disconnected"]:
                _fail("a message arrived after http.disconnect: %r" % t)
            if t == "http.disconnect":
                state["disconnected"] = True
                return message
            if t != "http.request":
                _fail("receive() produced %r; only http.request or http.disconnect" % t)
            if state["final_seen"]:
                _fail("an http.request arrived after more_body=False")
            body = message.get("body", b"")
            if not isinstance(body, bytes):
                _fail("http.request body must be bytes, got %r" % type(body).__name__)
            more = message.get("more_body", False)
            if not isinstance(more, bool):
                _fail("more_body must be bool, got %r" % type(more).__name__)
            if not more:
                state["final_seen"] = True
            return message

        async def checked_send(message):
            t = message.get("type")
            if t not in _HTTP_SEND_TYPES:
                _fail("application sent unknown message type %r" % t)
            return await send(message)

        return await app(scope, checked_receive, checked_send)

    return validated
