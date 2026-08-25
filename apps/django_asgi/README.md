# django_asgi — Django's ASGI handler on the asyncio executor

```bash
uv run bin/m0serve djasgi --app-dir apps/django_asgi --port 8095
```

A bare `djasgi` discovers `djasgi.asgi:application`; detection classifies
it ASGI and zero-config serves it through the executor — real
await-concurrency, live `StreamingHttpResponse`, sessions.

The row exists for `scope["client"]`. Django populates
`REMOTE_ADDR`/`REMOTE_PORT` only when the server sends a client tuple;
`None` doesn't error — it silently logs every visitor as address-less.
`/meta` echoes what Django saw, and `poe smoke-django-asgi` asserts a
real address (verified load-bearing against a server sending `None`).
