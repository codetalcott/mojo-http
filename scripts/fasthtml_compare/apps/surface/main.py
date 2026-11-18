"""A FastHTML app that exercises the documented API surface a server can get
wrong: background tasks, toasts, cookies, HTMX headers, errors (debug and
not), streaming (sync and async), disconnects, files, uploads, lifespan.
Served by compare.py under m0serve and under uvicorn."""
import asyncio, os, time
from fasthtml.common import *
from starlette.background import BackgroundTask
from starlette.responses import PlainTextResponse
from starlette.middleware.gzip import GZipMiddleware
from starlette.applications import Starlette
from starlette.routing import Route

LOG = []


def _life(msg):
    with open("lifespan.log", "a") as f: f.write(msg + "\n")


async def startup(): _life("startup")
async def shutdown(): _life("shutdown")


async def _gz_big(req): return PlainTextResponse("gzip me " * 5000)
gz = GZipMiddleware(Starlette(routes=[Route("/big", _gz_big)]), minimum_size=100)

app, rt = fast_app(debug=os.environ.get("PROBE_DEBUG") == "1",
                   on_startup=[startup], on_shutdown=[shutdown],
                   routes=[Mount("/gz", app=gz)])
setup_toasts(app)


@rt("/scope")
async def scope_(req):
    s = req.scope
    body = await req.body()
    return JSONResponse({
        "type": s["type"], "http_version": s.get("http_version"), "method": s["method"],
        "scheme": s.get("scheme"), "path": s["path"], "raw_path": (s.get("raw_path") or b"").decode("latin-1"),
        "query_string": s.get("query_string", b"").decode("latin-1"), "root_path": s.get("root_path"),
        "server_host": (s.get("server") or [None])[0], "client_host": (s.get("client") or [None])[0],
        "headers": [[k.decode("latin-1"), v.decode("latin-1")] for k, v in s["headers"]
                    if k not in (b"user-agent", b"accept-encoding", b"accept", b"host")],
        "bodylen": len(body), "url": str(req.url).replace(str(req.url.port), "PORT"),
        "asgi": s.get("asgi"),
    })


@rt("/state-keys")
def state_keys(req): return JSONResponse(sorted((req.scope.get("state") or {}).keys()))


@rt("/upload", methods=["post"])
async def upload(myFile: UploadFile): return f"got {len(await myFile.read())} bytes"


@rt("/boom")
def boom(): raise ValueError("kaboom from a route")


@rt("/boom-async")
async def boom_async():
    await asyncio.sleep(0)
    raise KeyError("async kaboom")


async def slow_bg(tag):
    await asyncio.sleep(1.5)
    LOG.append(f"bg-async-done:{tag}")


def slow_bg_sync(tag):
    time.sleep(1.5)
    LOG.append(f"bg-sync-done:{tag}")


@rt("/bg")
def bg(tag: str = "x"): return P(f"queued {tag}"), BackgroundTask(slow_bg, tag)


@rt("/bg-sync")
def bg_sync(tag: str = "x"): return P(f"queued {tag}"), BackgroundTask(slow_bg_sync, tag)


# Sorted: two tasks of one length finish in either order.
@rt("/log")
def log(): return JSONResponse(sorted(LOG))


@rt("/toast")
def toast(sess):
    add_toast(sess, "Saved ✓", "success")
    return Redirect("/after-toast")


@rt("/after-toast")
def after_toast(): return Titled("After", P("page"))


@rt("/cookies")
def cookies():
    return (P("ok"), cookie("a", "1"), cookie("b", "two words", httponly=True, max_age=60),
            HtmxResponseHeaders(trigger="evt", push_url="/pushed"))


@rt("/redir")
def redir(): return Redirect("/after-toast")


@rt("/nocontent")
def nocontent(): return Response(status_code=204)


@rt("/notmod")
def notmod(): return Response(status_code=304, headers={"etag": '"v1"'})


@rt("/json", methods=["post"])
async def json_(req): return JSONResponse({"got": await req.json()})


@rt("/big")
def big(): return PlainTextResponse("0123456789abcdef" * (5 * 1024 * 1024 // 16))


@rt("/file")
def file(): return FileResponse("blob.bin")


def sync_chunks():
    for i in range(5):
        yield f"sync-chunk-{i}\n"
        time.sleep(0.3)


async def async_chunks():
    for i in range(5):
        yield f"async-chunk-{i}\n"
        await asyncio.sleep(0.3)


@rt("/stream-sync")
def stream_sync(): return StreamingResponse(sync_chunks(), media_type="text/plain")


@rt("/stream-async")
def stream_async(): return StreamingResponse(async_chunks(), media_type="text/plain")


@rt("/watch")
async def watch(req):
    # However the framework ends a stream whose client left -- the check
    # below, or a cancellation -- the server must have told it: `finally`.
    async def gen():
        try:
            for i in range(200):
                if await req.is_disconnected(): return
                yield f"data: {i}\n\n"
                await asyncio.sleep(0.1)
            LOG.append("watch-ran-to-end")
        finally:
            LOG.append("watch-released")
    return StreamingResponse(gen(), media_type="text/event-stream")


@rt("/sleep")
async def sleep_(): await asyncio.sleep(1.0); return "slept"


@rt("/sync-sleep")
def sync_sleep(): time.sleep(1.0); return "sync slept"


@rt("/q")
def q(req): return JSONResponse(req.query_params.multi_items())


@rt("/p/{name}")
def p(name: str): return f"name={name}"


@rt("/form", methods=["post"])
async def form(req):
    f = await req.form()
    return JSONResponse(f.multi_items())


QUIET = {"open": 0, "closed": 0}


@rt("/quiet")
async def quiet():
    # A stream nobody has written to: its head must still reach the client,
    # and the client's leaving must still reach here.
    async def gen():
        QUIET["open"] += 1
        try:
            await asyncio.Event().wait()
            yield ""
        finally:
            QUIET["open"] -= 1
            QUIET["closed"] += 1
    return EventStream(gen())


@rt("/quiet-count")
def quiet_count(): return JSONResponse(QUIET)


@app.ws("/ws")
async def ws(msg: str, send):
    await send(Div(f"echo {msg}", id="out"))
