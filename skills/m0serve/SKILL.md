---
name: m0serve
description: Serve a Python WSGI or ASGI application (Django, Flask, FastAPI) with m0serve, and give a plain synchronous view live updates — a Server-Sent Events stream or a WebSocket held by the server, published to with m0pub.publish() from any code — without Channels, Redis or a second process. Use when the user mentions m0serve or m0pub, or wants SSE, WebSockets or push between browser tabs from sync Django or Flask.
---

# m0serve

A WSGI and ASGI server, `pip install m0serve`: one wheel, no
dependencies, no Mojo toolchain. macOS arm64 and glibc Linux (x86_64,
aarch64), CPython 3.10–3.14. No Windows, no musl, no TLS (terminate at a
proxy).

## Read the docs as Markdown

https://m0serve.dev/llms.txt is the operating contract and an index of
every page. Every page is Markdown at its URL with `.md` in place of the
trailing slash: https://m0serve.dev/quickstart.md is the pattern below,
whole and runnable. Fetch those with `curl`; a fetch that summarises HTML
drops the code blocks.

## The pattern

A synchronous view approves a held connection with two response headers;
the server holds it from there. `m0pub.publish()` reaches every subscriber
of the channel on every worker.

```python
from django.http import HttpResponse, JsonResponse
from django.views.decorators.csrf import csrf_exempt
from m0serve import m0pub


def events(request):                       # GET /events -> an SSE stream
    # Your access check goes here: this view runs first, with the session.
    r = HttpResponse(": connected\n\n", content_type="text/event-stream")
    r["M0-Hold"] = "stream"                # or "websocket" for a WebSocket
    r["M0-Channel"] = "news"
    return r


@csrf_exempt                               # the server reserves this path
def ws_message(request):                   # each inbound WebSocket message
    m0pub.publish(request.headers["M0-Channel"], request.body.decode())
    return JsonResponse({"ok": True})


def announce(request):                     # any view, command or cron job
    m0pub.publish("news", request.POST["text"])
    return HttpResponse(status=204)
```

```bash
m0serve myproject.wsgi:application --realtime --host 127.0.0.1 --port 8000
```

- `--realtime` is what turns the headers into held connections. Without
  it the app serves, the hold views return short responses, and a
  `publish()` reaches nobody.
- `--host 127.0.0.1` binds this machine alone; the default is every
  interface. `--health-path /health` answers in the server, before Python.
- A bare `MODULE` tries `MODULE.asgi:application`,
  `MODULE.wsgi:application`, `MODULE:app` and `MODULE.main:app`.
- Under gunicorn or any other server the headers pass through unread and
  the same views return short plain responses.

## What `publish` does

- `publish(channel, data)` sends `data` as ONE event. Each line of it is
  one `data:` field, and an `EventSource` joins them with a newline again:
  do not flatten line breaks. Text that is already an SSE frame goes
  through `publish_frame`; passed to `publish` it is framed twice.
- It returns the number of worker channels written. `0` means not sent: a
  frame over the size limit, a refused channel, or no m0serve underneath.
- Every event gets an `id:` from a counter shared across workers.
  `publish_with_id` returns it.
- A stream that reconnects with `Last-Event-ID` is sent what it missed, or
  one `event: m0-gap` when the server's journal (`--replay-frames`, 64)
  no longer holds it: listen for `m0-gap` and fetch the current state.
- Channel names are yours to police, except a leading `\x01` byte, which
  the server reserves.

## Rules the pattern depends on

- **The view that approves a hold is the access check.** Nothing
  downstream asks again.
- **Inbound WebSocket messages are POSTs to `/ws/message`**, carrying
  `M0-Channel`, `M0-Slot` and `M0-Opcode` headers. The server answers 404
  to that path from the network, so its view can be `csrf_exempt`.
- **A form a page posts meets Django's CSRF check** in a project with
  `CsrfViewMiddleware`: render the token (`{% csrf_token %}`, or
  `django.middleware.csrf.get_token(request)` in a page built as a
  string). Exempt only a view no browser form posts to.
- **The WebSocket handshake has no `Origin` check.** With cookie auth,
  check `Origin` in the view that approves the upgrade.
- **The binary resolves libpython from the `python3` on `PATH`.** A start
  script activates the virtualenv or puts `.venv/bin` first on `PATH`;
  `MOJO_PYTHON_LIBRARY` names the library outright.

## Running and checking it

- Pick a free port. If the port is taken, m0serve logs `Bind failed on
  ... (address in use ...)` and retries once a second, and whatever
  answers meanwhile is the other server. Read the server's log before
  trusting a response.
- Verify with two streams and a publish, as the quickstart does:

  ```bash
  curl -sN --max-time 5 http://127.0.0.1:8000/events > one.txt &
  curl -sN --max-time 5 http://127.0.0.1:8000/events > two.txt &
  sleep 1
  curl -s -X POST -d text=hello http://127.0.0.1:8000/announce
  wait; grep "data: hello" one.txt two.txt
  ```

- `m0serve --doctor [ARGS] MODULE` prints the resolved configuration as
  JSON, starts nothing, and exits with the code serving would.
- Exit codes: 2 a command line that cannot be read, 1 a startup failure,
  78 a configuration refused. A refusal names its fix on stderr: read it
  rather than retry.
- `--workers N` prefork workers, and `publish` reaches all of them.
  `--static PREFIX=DIR` serves files from the server. `--mount
  PREFIX=SPEC` hosts several applications in one process. `m0serve
  --help` lists every flag, and each overrides its `M0_*` variable.
- ASGI applications get the same bus as `scope["state"]["m0"]`:
  `publish(channel, payload)`, and `subscribe(channel)` as an async
  iterator under the default executor mode.
