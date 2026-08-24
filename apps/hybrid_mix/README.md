# hybrid_mix — two applications, one process

Two frameworks served by one `m0serve` process at different path prefixes:

```bash
uv run bin/m0serve \
  --mount /=shop.wsgi \
  --mount /portal=portal.wsgi:app \
  --app-dir apps/hybrid_mix --port 8099
```

`/` and `/where` reach Django; `/portal/` and `/portal/where` reach Flask;
anything else is a 404 answered in Mojo, never entering Python.

Each mount gets its own bridge and its own shim namespace, which is what
makes two frameworks in one interpreter safe. Two Django projects would
*not* prove that — they would share `django.conf.settings` and the first
one imported would win — so the second half is deliberately Flask.

## What the `/where` routes are for

Both frameworks build absolute URLs from `SCRIPT_NAME`, so a server that
hands an application a prefix it does not actually strip from `PATH_INFO`
breaks every generated link while every direct request still works. That
failure is invisible until someone clicks something. `poe smoke-hybrid`
compares `reverse()`, `url_for()` and the two `request.path` values byte
for byte against what the mount promises.

## Not here yet

Both mounts are WSGI. Mixed WSGI/ASGI mounts are refused for now with a
message pointing at `docs/WSGI_VS_ASGI.md` — routing them is done, but
giving each its native execution mode (the asyncio executor for the async
one, the handler pool for the sync one) is the next stage, and running an
ASGI app through the buffered bridge beside a WSGI one would quietly cost
it its streaming.
