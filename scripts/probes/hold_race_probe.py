"""Holds taken on pool threads while the loop is kept busy: does every one register?

    python3 scripts/probes/hold_race_probe.py [N]

Run from a built tree; `poe stress-pool` runs it in the m0lin container
beside phase5_probe.py. Starts the Django realtime app with
a pool of 4 under --realtime, keeps the loop busy with health requests (served
on the loop, never a pool job), opens N SSE holds one at a time, and after each
asks /health how many subscribers the loop has. A hold whose head went out
before its frame was read is swept closed and never counts.
"""
import json, os, socket, subprocess, sys, threading, time, urllib.request

PORT = 8080
N = int(sys.argv[1]) if len(sys.argv) > 1 else 40
env = dict(os.environ, M0_CORE_LIB=f"{os.getcwd()}/packages/m0-core/libm0core.so", M0_SSE_HEARTBEAT_MS="500")
cmd = ["bin/m0serve", "djangoproj.wsgi:application", "--app-dir", "apps/django_realtime",
       "--port", str(PORT), "--realtime", "--health-path", "/health",
       "--static", "/static/=apps/django_realtime/static", "--blocking-threads", "4"]
log = open("/tmp/probe_srv.log", "w")
srv = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)

def health():
    with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=5) as r:
        return json.loads(r.read())

t0 = time.time()
while True:
    try:
        health(); break
    except Exception:
        if time.time() - t0 > 60:
            print("never healthy"); srv.kill(); sys.exit(2)
        time.sleep(0.2)

stop = False
def hammer():
    while not stop:
        try:
            health()
        except Exception:
            pass
hammers = [threading.Thread(target=hammer, daemon=True) for _ in range(3)]
for h in hammers: h.start()

holds = []
def open_hold(i):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    s.sendall((f"GET /events?channel=race{i}&token=letmein HTTP/1.1\r\nHost: 127.0.0.1\r\n"
               "Accept: text/event-stream\r\n\r\n").encode())
    holds.append(s)

misses = []
for i in range(N):
    open_hold(i)
    time.sleep(0.15)
    subs = health()["subscribers"]
    if subs != i + 1:
        misses.append((i, subs))
time.sleep(1.0)
final = health()["subscribers"]
stop = True
for h in hammers: h.join(timeout=2)
# closed sockets: a hold that was swept sends EOF; a live one is silent
dead = 0
for s in holds:
    s.setblocking(False)
    try:
        data = s.recv(65536)
        if data == b"":
            dead += 1
    except BlockingIOError:
        pass
    except Exception:
        dead += 1
    s.close()
srv.terminate()
try: srv.wait(10)
except subprocess.TimeoutExpired: srv.kill()
verdict = "PASS" if final == N and not misses else "FAIL"
print(f"{verdict}: {N} holds opened, {final} registered at the end, {len(misses)} checks short, {dead} sockets closed by the server; first misses {misses[:5]}")
sys.exit(0 if verdict == "PASS" else 1)
