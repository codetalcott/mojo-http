"""The chat idiom: a disconnect hook tells the sockets still connected."""
import os, time, socket
import websockets.sync.client as wsc
from compare import HERE
OWN = True
APP_DIR = os.path.join(HERE, "apps", "wsleft"); SPEC = "main:app"; EXTRA = {}
def got(ws):
    out = []
    try:
        while True: out.append(ws.recv(timeout=1.0))
    except TimeoutError: pass
    return out
def scenario(srv, steps):
    u = f"ws://127.0.0.1:{srv.port}/ws"
    a, b, c = wsc.connect(u), wsc.connect(u), wsc.connect(u)
    time.sleep(0.3)
    b.socket.shutdown(socket.SHUT_RDWR); b.socket.close()      # vanishes
    steps.append(("a and c hear that b left (vanished)", {"a": got(a), "c": got(c)}))
    c.close()                                                   # clean close
    steps.append(("a hears that c left (clean close)", {"a": got(a)}))
    a.close()
