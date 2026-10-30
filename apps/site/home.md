# m0serve

A WSGI and ASGI server written in Mojo. A plain synchronous Django or Flask
view can hold a Server-Sent Events stream or a WebSocket by setting two
response headers, and one call publishes to every subscriber on every
worker. On one machine it needs neither Channels nor Redis nor a second
process; across several, Postgres `NOTIFY` is the bus. It installs as one
wheel with no dependencies.

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

For an agent: [llms.txt](../../llms.txt) is the operating contract and an
index of every page, and each page is Markdown at its URL with `.md` in
place of the trailing slash (`/quickstart.md`); `/llms-full.txt` is the
main pages in one file, and [spec.json](../../docs/spec.json) the
capability matrix as data. Two agent skills carry what a coding agent
looks for first: [m0serve](../../skills/m0serve/SKILL.md) and
[m0](../../skills/m0/SKILL.md).

[demo.m0serve.dev](https://demo.m0serve.dev) is this running: open it in two
tabs and type in either. The page names the version serving it.

[blobs.m0serve.dev](https://blobs.m0serve.dev) is the other end of the same
stack: an application written in Mojo on the HTTP server underneath
m0serve, in an image with no Python in it. Click to drop a blob; every open
tab sees it. [The Mojo stack](../../docs/MOJO.md) is how to write one.

The view runs first, with sessions and permissions in hand, so authorization
stays where it is. Under gunicorn the two headers pass through unread and the
same view returns a short plain response.

The design is not new. It is Fanout's GRIP protocol, which
[Pushpin](https://pushpin.org/) has served since 2013: `Grip-Hold` and
`Grip-Channel` on a response tell a proxy in front of the application to
hold the connection, and WebSocket messages reach the application as HTTP
requests. m0serve does the same inside the server that runs the view.
There is no proxy to deploy beside it, and a publish is a write to a local
socket rather than a request to a publish endpoint. Pushpin fronts any
backend in any language and scales as a tier of its own; m0serve serves
Python applications, one server per machine.

The name is m0serve with a zero, like the packages underneath it: `m0-core`,
`m0-http`, `m0-wsgi`.

## Where next

- [Quickstart](../../QUICKSTART.md): the application above, running, in
  five steps.
- [Running m0serve](../../docs/RUNNING.md): flags, execution modes, what to
  put in front of it, shutdown.
- [Capabilities](../../docs/SPEC.md): what the server does, one row per
  capability with the test that proves it.

## Beyond realtime

- **WSGI and ASGI from one binary.** The protocol is detected from the
  application object. Django, Flask, FastAPI and FastHTML each have a smoke
  test in CI. WSGI conformance is checked with `wsgiref`, ASGI with a validator
  written from the specification.
- **Several applications in one process.**
  `m0serve --mount /=shop.wsgi --mount /app=live.asgi` runs sync Django on
  handler threads and async FastHTML on an asyncio executor, behind one
  listener with one shutdown.
- **A slow view does not stall the rest.** Handler threads behind each
  event loop are the default for WSGI.
- **Throughput is level with the fast servers, not ahead of them.** Per
  core on a bare ASGI app it is <!-- num:asgi-per-core-vs-uvloop@2 -->0.99<!-- /num -->x uvicorn with uvloop; it
  serves <!-- num:asgi-vs-uvloop@2 -->1.64<!-- /num -->x the requests per second only because it uses
  <!-- num:asgi-m0-cores@1 -->1.6<!-- /num --> cores where uvicorn uses one. On bare WSGI, one worker with
  one handler thread each, Granian to m0serve is <!-- num:granian-vs-m0-rps@2 -->0.99<!-- /num -->x, a tie.
  Under mixed load its fast-request p99 is ahead of uvicorn's in every
  recorded run. These are one Apple M4 laptop's numbers; on Linux the
  per-core ASGI figure is a little behind uvloop's. The
  [benchmarks](../../docs/BENCHMARKS.md) have every number, each rendered
  from a dated artifact that CI refuses once it is more than a minor
  version old, and the Linux runs.

## Limits

- No TLS and no HTTP/2. Terminate at a proxy, as with gunicorn.
- **Fan-out is one machine's.** `m0pub.publish()` reaches every worker of
  the server it runs in, and no other. Servers on several machines share
  a bus through Postgres: each runs with `--pg-listen URL`, and a publisher
  anywhere executes `m0pub.notify_sql(channel, data)` on its own database
  connection ([Running](../../docs/RUNNING.md)).
- **A loop holds 1024 connections**, `--max-connections` to change it, and
  held streams take all but the last 16 of them, so the health path still
  answers when streams are full. A stream past that is answered `503`.
  More streams are more workers or threads.
- The served contract is stable from 1.0: flags and environment variables,
  the two hold headers, and `m0pub.publish()`. The
  [changelog](../../CHANGELOG.md) records every change.
- macOS arm64 (13 or newer), and Linux x86_64 and aarch64 with glibc
  2.35 or newer: Ubuntu 22.04, Debian 12 and RHEL 10 and later. RHEL 9
  and Amazon Linux 2023, at glibc 2.34, are below the floor, and `pip`
  declines the wheel there. CPython 3.10 to 3.14, with free-threaded
  builds for WSGI only. Not supported: Intel Mac, Windows, musl.

## Underneath

m0serve is one package of [mojo-http](../../README.md), an HTTP/1.1 server
and web framework for Mojo with routing, content negotiation, ETags, SSE,
WebSockets, a Datastar adapter and SQLite bindings. The source is on
[GitHub](https://github.com/codetalcott/mojo-http) under the MIT license.
