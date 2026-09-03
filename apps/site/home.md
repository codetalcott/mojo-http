# m0serve

**Realtime from a synchronous Python app, with no added infrastructure.**

A plain sync Django or Flask view can hold a Server-Sent Events stream or a
WebSocket by answering with two response headers, and reach every subscriber
on every worker with one function call. No Channels, no Redis, no daphne, no
second process. The server is written in Mojo and installs as one wheel with
no dependencies.

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

```bash
pip install m0serve
m0serve myproject.wsgi --realtime
```

The name is spelled with a zero, `m0serve`, the way the packages underneath
are named: `m0-core`, `m0-http`, `m0-wsgi`.

The view runs first, with sessions and permissions in hand, which is where
your authorization belongs. Under gunicorn the two headers are ignored and the
same view degrades to a short plain response, so adopting it does not fork
your codebase.

## Where to go

- **[Quickstart](../../QUICKSTART.md)**: ten minutes from `pip install` to
  live multi-tab sync from one Django file. CI executes every command in it
  on every pull request.
- **[Running m0serve](../../docs/RUNNING.md)**: which flags for which app,
  the execution modes, what to put in front of it, how it shuts down.
- **[Capabilities](../../docs/SPEC.md)**: what the server does, one row per
  capability, each naming the test that proves it.
- **[All documentation](../../docs/README.md)**: the map, by what you are
  trying to do.

## What it also does

- **Serves WSGI and ASGI from one binary.** The protocol is detected from the
  object. Django, Flask and FastHTML each have a smoke test in CI, and
  the quickstart's Flask realtime views are driven by the same RFC 6455
  probe as Django's;
  PEP 3333 conformance is validated by `wsgiref` and ASGI by a validator
  written from the spec.
- **Several applications in one process**, each in its native mode:
  `m0serve --mount /=shop.wsgi --mount /app=live.asgi` runs sync Django on
  handler threads and async FastHTML on an asyncio executor behind one
  listener with one shutdown.
- **A slow view does not stall the rest.** Handler threads behind each event
  loop are the default for WSGI, so a 2 s view no longer holds the
  keep-alive connections pinned behind it.

## What it is not

- **No TLS and no HTTP/2.** Terminate at a proxy, as with gunicorn.
- **Not the fastest server on raw throughput.** The
  [benchmarks](../../docs/BENCHMARKS.md) say where it loses and by how much,
  and every figure there is recomputed from a dated artifact. What it wins is
  the fast-request tail under mixed load.
- **Pre-1.0.** The API can still change; the [changelog](../../CHANGELOG.md)
  records every change.
- **macOS arm64 and Linux x86_64 and aarch64 only.** No Intel Mac, no
  Windows, no musl. CPython 3.10 to 3.14, free-threaded builds included for
  WSGI.

## For agents

[llms.txt](../../llms.txt) is the operating contract in one page, with every
page of this site indexed as Markdown; `/llms-full.txt` is the essential
pages in one file; [spec.json](../../docs/spec.json) is the capability matrix
as data.

## Underneath

`m0serve` is one package of [mojo-http](../../README.md), an HTTP/1.1 server
and web framework for Mojo with routing, content negotiation, ETags, SSE and
WebSockets, a Datastar adapter and SQLite bindings. The
[README](../../README.md) covers that side; the source is on
[GitHub](https://github.com/codetalcott/mojo-http) under the MIT license.
