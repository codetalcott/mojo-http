# FastAPI on m0serve

The second Starlette-family ASGI row (SPEC L19; FastHTML is L11), and the
reason the landing page can name FastAPI.

```bash
uv run poe build-serve
bin/m0serve main:app --app-dir apps/fastapi_demo --port 8099
```

`poe smoke-fastapi` is the gate. It asserts three things about the seam and
deliberately nothing about FastAPI itself:

- a buffered response arrives, and the log says the app was detected as ASGI
- `/stream` delivers live ticks AND leaves no traceback in the log — bodies
  arrived intact while the shim marked the wrong task (PR #223), so the body
  alone does not prove this
- `/ws` echoes, and an app-initiated `close(1000)` ends in a FIN

Request validation, dependency injection and the OpenAPI page are FastAPI's
own to test; they are switched off here (`docs_url=None`) so the app stays
the size of the thing being proven.
