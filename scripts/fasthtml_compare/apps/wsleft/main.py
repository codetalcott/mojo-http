"""The chat idiom: a disconnect hook tells everyone else who left."""
from fasthtml.common import *
app, rt = fast_app(exts="ws")
conns = {}
async def on_connect(ws, send): conns[id(ws)] = send
async def on_disconnect(ws):
    conns.pop(id(ws), None)
    for send in list(conns.values()): await send(Div("someone left", id="t"))
@app.ws("/ws", conn=on_connect, disconn=on_disconnect)
async def ws(msg: str, send): pass
