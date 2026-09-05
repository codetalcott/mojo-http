# m0serve

A WSGI and ASGI server written in Mojo. A plain synchronous Django or Flask
view can hold a Server-Sent Events stream or a WebSocket by setting two
response headers, and one call publishes to every subscriber on every
worker. It needs neither Channels nor Redis, and runs as one process. It
installs as one wheel with no dependencies.

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

[demo.m0serve.dev](https://demo.m0serve.dev) is this running: open it in two
tabs and type in either. The page names the version serving it.

The view runs first, with sessions and permissions in hand, so authorization
stays where it is. Under gunicorn the two headers pass through unread and the
same view returns a short plain response.

The name is m0serve with a zero, like the packages underneath it: `m0-core`,
`m0-http`, `m0-wsgi`.

## Where next

- [Quickstart](../../QUICKSTART.md): the application above, running, in
  five steps.
- [Running m0serve](../../docs/RUNNING.md): flags, execution modes, what to
  put in front of it, shutdown.
- [Capabilities](../../docs/SPEC.md): what the server does, one row per
  capability with the test that proves it.

## Also

- **WSGI and ASGI from one binary.** The protocol is detected from the
  application object. Django, Flask and FastHTML each have a smoke test in
  CI. WSGI conformance is checked with `wsgiref`, ASGI with a validator
  written from the specification.
- **Several applications in one process.**
  `m0serve --mount /=shop.wsgi --mount /app=live.asgi` runs sync Django on
  handler threads and async FastHTML on an asyncio executor, behind one
  listener with one shutdown.
- **A slow view does not stall the rest.** Handler threads behind each
  event loop are the default for WSGI.

## Limits

- No TLS and no HTTP/2. Terminate at a proxy, as with gunicorn.
- Not the fastest server on raw throughput. The
  [benchmarks](../../docs/BENCHMARKS.md) give the numbers, including where
  it loses.
- Pre-1.0. The API can still change; the [changelog](../../CHANGELOG.md)
  records every change.
- macOS arm64 and Linux x86_64 and aarch64. CPython 3.10 to 3.14, with
  free-threaded builds for WSGI only. Not supported: Intel Mac, Windows,
  musl.

## For agents

[llms.txt](../../llms.txt) is the operating contract and an index of every
page as Markdown; `/llms-full.txt` is the main pages in one file;
[spec.json](../../docs/spec.json) is the capability matrix as data.

## Underneath

m0serve is one package of [mojo-http](../../README.md), an HTTP/1.1 server
and web framework for Mojo with routing, content negotiation, ETags, SSE,
WebSockets, a Datastar adapter and SQLite bindings. The source is on
[GitHub](https://github.com/codetalcott/mojo-http) under the MIT license.
