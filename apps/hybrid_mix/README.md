# hybrid_mix — sync and async in one process

Three frameworks, three prefixes, one `m0serve` process — and each
application runs in the concurrency model it was written for:

```bash
uv run bin/m0serve \
  --mount /=shop.wsgi \
  --mount /portal=portal.wsgi:app \
  --mount /app=live.asgi \
  --app-dir apps/hybrid_mix --port 8099
```

| prefix | framework | protocol | runs on |
|---|---|---|---|
| `/` | Django | WSGI | handler-pool threads |
| `/portal` | Flask | WSGI | handler-pool threads |
| `/app` | FastHTML | ASGI | the asyncio executor |

The banner says which mount took the executor: `asgi-loop@/app`.

**This is the thing the hybrid gateway is for.** uvicorn, daphne and
Granian each host exactly one callable, so a codebase that is partly sync
and partly async runs two servers behind a proxy, or drops the sync half
onto an event loop's threadpool. Here the loop routes by prefix before
either application sees the request, and hands the job to a submit lane
whose worker is the right kind.

## What the routes are for

- `/where` and `/app/where` are the scope-fidelity probes, and they assert
  **opposite** things on purpose: WSGI gets `SCRIPT_NAME` with `PATH_INFO`
  trimmed to the remainder, ASGI gets `root_path` with `path` left whole
  (the framework strips it itself). One seam in `PyBridge.set_base` serves
  both, and getting it backwards breaks every generated link while every
  direct request still works.
- `/slow?ms=` blocks a pool thread — a stand-in for the ORM call or
  outbound request a real Django view makes.
- `/app/await?ms=` awaits, so the executor can overlap it.

`scripts/hybrid_isolation.py` is the measurement: four `/slow?ms=2000`
requests hold every pool thread while the FastHTML mount is polled, and the
async p99 must stay inside a few hundred milliseconds. Sharing one
execution mode puts it in the seconds.

Two Django projects would **not** make this point — they would share
`django.conf.settings` and the first import would win. Three frameworks
cannot accidentally share anything.

## Limits

One ASGI mount. A second needs its own streaming chunk channel, and the
loop has a single `bus_read_fd`; sharing it is possible (slots are unique
per loop) but drain-ack credit belongs to the executor that owns the slot,
so the routing has to come first. Any number of WSGI mounts may sit beside
it — they share the pool, dealt round-robin across the lanes.

`--realtime` is refused with `--mount`: an inbound WebSocket message is
delivered back into one application's urlconf, and which mount should
receive it has no defensible answer.
