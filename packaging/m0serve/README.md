# m0serve

**Realtime from a synchronous Python app, with no added infrastructure.**

A WSGI/ASGI server written in [Mojo](https://www.modular.com/mojo). Point it
at a Django, Flask, FastHTML or Starlette app and it serves it — no Mojo
toolchain required, no compilation step, nothing to configure:

```bash
pip install m0serve
m0serve myproject.wsgi:application
```

What it adds over gunicorn or uvicorn is that a **plain synchronous view**
can hold a Server-Sent Events stream or a WebSocket, by answering with two
response headers — and reach every subscriber on every worker with one
function call. No Channels, no Redis, no daphne, no Pushpin, no second
process:

```python
from m0serve import m0pub

def events(request):                    # an ordinary synchronous view
    r = HttpResponse(": connected\n\n", content_type="text/event-stream")
    r["M0-Hold"] = "stream"             # m0serve holds the connection open
    r["M0-Channel"] = "news"            # ...subscribed to this channel
    return r                            # Django's part in it ends here


def announce(request):                  # any view, command, or cron job
    m0pub.publish("news", "deploy finished")
    return HttpResponse("ok")
```

Run it with `m0serve myproject.wsgi --realtime`. The view runs *first*, with
sessions and permissions in hand — which is where your auth belongs. Under
gunicorn the two headers are ignored and the same view degrades to a short
plain response, so adopting this is not a fork of your codebase.

The **ten-minute quickstart** goes from `pip install` to live multi-tab sync
from one synchronous Django file:
<https://github.com/codetalcott/mojo-http/blob/main/QUICKSTART.md> — every
command in it is executed by CI on every pull request.

It also hosts **several applications in one process**, each in its native
execution mode: `m0serve --mount /=shop.wsgi --mount /app=live.asgi` runs
sync Django on handler threads and async FastHTML on an asyncio executor,
behind one listener with one shutdown.

The protocol is detected from the object, so the same command serves WSGI and
ASGI. `m0serve --help` lists the flags; `--workers N`, `--threads N` (on
free-threaded CPython) and `--blocking-threads N` are the topology ones.

If something will not start, `m0serve --doctor myproject.wsgi` prints a JSON
report — the interpreter it resolved and the virtualenv it came from, the
spec it discovered, the topology it settled on, and every startup check with
the fix for the ones that failed — and exits with the code the server itself
would have used. It binds nothing and imports nothing twice.

## What is in the wheel

One compiled binary and the Mojo runtime it loads. **No CPython** — m0serve
resolves libpython at run time from the interpreter it is installed beside,
which is why there is no ABI tag and one wheel per platform covers CPython
3.10 through 3.14, free-threaded builds included. It has no Python
dependencies and fetches nothing at install time.

Install it into the same virtual environment as your application, the way you
would gunicorn or uvicorn; the console script points the embedded interpreter
at that environment.

## Platforms

| platform | status |
|---|---|
| macOS arm64 (Apple Silicon) | supported |
| Linux x86_64 (glibc) | supported |
| Linux aarch64 (Graviton, Ampere, arm64 Docker) | supported |
| macOS x86_64 (Intel) | not possible — Modular ships no Intel Mac toolchain |
| musl / Alpine, Windows | not supported |

The wheel's filename carries the exact macOS and glibc floors it was built
against. On an older system `pip` declines to install it rather than
installing something that crashes.

## Status

Pre-1.0 and deliberately small: HTTP/1.1 only, no TLS, no HTTP/2 — terminate
at a proxy, which is gunicorn's answer too. The API will change before 1.0.

Source, documentation and issues: <https://github.com/codetalcott/mojo-http>

## Licence

MIT, and the wheel redistributes third-party components under their own
terms — the Mojo runtime (Apache-2.0 with LLVM Exceptions) and a fork of
lightbug_http (MIT). Full text and attribution ship inside the wheel; see
`NOTICE.txt` beside the installed package.
