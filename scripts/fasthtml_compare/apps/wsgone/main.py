"""A client that vanishes without a Close: the disconnect hook must run, and
a later send to it must raise or be refused, never reach another client."""
from fasthtml.common import *
app, rt = fast_app(exts="ws")
conns, events = {}, []
async def on_connect(ws, send):
    conns[id(ws)] = send; events.append("connect")
async def on_disconnect(ws):
    conns.pop(id(ws), None); events.append("disconnect")
@app.ws("/ws", conn=on_connect, disconn=on_disconnect)
async def ws(msg: str, send): pass
@rt("/broadcast")
async def broadcast():
    for k, send in list(conns.items()):
        try:
            await send(Div("tick", id="t")); events.append("send-ok")
        except Exception as e:
            events.append(f"send-raised:{type(e).__name__}"); conns.pop(k, None)
    return "ok"
@rt("/state")
def state(): return JSONResponse({"conns": len(conns), "events": events})
