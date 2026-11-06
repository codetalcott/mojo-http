# m0serve

**Realtime from a synchronous Python app, with no added infrastructure.**

A WSGI/ASGI server written in [Mojo](https://www.modular.com/mojo). Point it
at a Django, Flask, FastHTML or Starlette app and it serves it. It needs no
Mojo toolchain and no build step:

```bash
pip install m0serve
m0serve myproject.wsgi:application
```

What it adds over gunicorn or uvicorn is that a **plain synchronous view**
can hold a Server-Sent Events stream or a WebSocket by answering with two
response headers, and reach every subscriber on every worker with one
function call. On one machine it needs none of Channels, Redis, daphne,
Pushpin or a second process; across machines, Postgres `NOTIFY` is the bus,
through `--pg-listen`:

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
sessions and permissions in hand, so authorization stays in your app. Under
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

When it is up it prints one line per worker, after the application has
imported, so the line means it is serving:

```text
🔥 m0serve: myproject.wsgi:application on http://127.0.0.1:8000 (protocol=wsgi workers=4)
```

For an orchestrator use `--health-path /health` or a TCP check.

If something will not start, `m0serve --doctor myproject.wsgi` prints a JSON
report and exits with the code the server itself would have used. The
report names the interpreter and its virtualenv, the spec discovery chose,
the topology, and every startup check, with the fix for each that failed.
It binds nothing and imports nothing twice.

## What is in the wheel

One compiled binary and the Mojo runtime it loads. It carries no CPython:
m0serve loads libpython at run time from the interpreter it is installed
beside, so the wheel has no ABI tag and one wheel per platform covers
CPython 3.10 through 3.14, free-threaded builds included. It has no Python
dependencies and fetches nothing at install time.

Install it into the same virtual environment as your application, the way you
would gunicorn or uvicorn; the console script points the embedded interpreter
at that environment.

## Platforms

| platform | status |
|---|---|
| macOS arm64 (Apple Silicon), macOS 13+ | supported |
| Linux x86_64, glibc 2.35+ | supported |
| Linux aarch64, glibc 2.35+ (Graviton, Ampere, arm64 Docker) | supported |
| macOS x86_64 (Intel) | not possible — Modular ships no Intel Mac toolchain |
| musl / Alpine, Windows | not supported |

The wheel's filename carries its macOS and glibc floors, measured from the
binary at each release. On an older system `pip` declines the wheel.

## Status

HTTP/1.1 only: terminate TLS and HTTP/2 at a proxy, as with gunicorn. From
1.0 the served contract (the flags and environment variables, the
`M0-Hold`/`M0-Channel` headers and `m0pub.publish()`) does not break in a
minor release, and a minor leaves every other Thursday
([Releases](https://github.com/codetalcott/mojo-http/blob/main/docs/RELEASES.md)).

The full capability matrix, with the CI gate behind each row, is
[docs/SPEC.md](https://github.com/codetalcott/mojo-http/blob/main/docs/SPEC.md).

Source, documentation and issues: <https://github.com/codetalcott/mojo-http>

## Licence

MIT, and the wheel redistributes third-party components under their own
terms — the Mojo runtime (Apache-2.0 with LLVM Exceptions; the wheel also
carries the MAX License, which Modular's distribution of the runtime names)
and a fork of lightbug_http (MIT). Full text and attribution ship inside the
wheel; see `licenses/NOTICE.txt` inside the installed `m0serve` package, or
the wheel's `.dist-info/licenses/`.
