# asgi_bare — the bare ASGI conformance app

The ASGI sibling of [`apps/wsgi_bare`](../wsgi_bare/): a plain `async def
application(scope, receive, send)` with no framework and no third-party
imports, so a failing assertion in `poe smoke-asgi` is the server's bug by
construction.

```bash
uv run poe serve-asgi-bare     # bin/m0serve bareapp.asgi:application --app-dir apps/asgi_bare
uv run poe smoke-asgi          # start it, assert the contract, stop it
```

Each route pins one clause of the ASGI HTTP contract — see the module
docstring in [`bareapp/asgi.py`](bareapp/asgi.py). Two routes are about the
*bridge* rather than the spec:

- `/lifespan` proves lifespan startup ran and its `state` reached the
  request scope.
- `/stream-forever` is an infinite stream: under the buffered ASGI bridge it
  must fail with the watchdog's explanatory error (and the server must stay
  healthy), and under a streaming host it must actually stream. The smoke
  asserts whichever the serving mode promises.
