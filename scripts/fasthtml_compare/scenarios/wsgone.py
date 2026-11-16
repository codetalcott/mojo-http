"""A client that vanishes without a close frame: does the app hear
websocket.disconnect, and does a later send to it raise?"""
import os, time, socket
import httpx
import websockets.sync.client as wsc
from compare import HERE
OWN = True
APP_DIR = os.path.join(HERE, "apps", "wsgone"); SPEC = "main:app"; EXTRA = {}
def scenario(srv, steps):
    a = wsc.connect(f"ws://127.0.0.1:{srv.port}/ws")
    b = wsc.connect(f"ws://127.0.0.1:{srv.port}/ws")
    time.sleep(0.3)
    b.socket.shutdown(socket.SHUT_RDWR); b.socket.close()   # vanish, no close frame
    time.sleep(1.0)
    steps.append(("after vanish", httpx.get(srv.base + "/state").json()))
    httpx.get(srv.base + "/broadcast")
    time.sleep(0.5)
    steps.append(("after broadcast", httpx.get(srv.base + "/state").json()))
    a.close()   # a clean close
    time.sleep(1.0)
    steps.append(("after clean close", httpx.get(srv.base + "/state").json()))
