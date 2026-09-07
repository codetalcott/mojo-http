"""smoke-django-realtime phase 5, repeated: fresh server each round, two slow
views in flight, a hold on a pool thread, subscribers must be 1 half a
second later. Prints one line per round and a tally; exits 1 if any round
failed. Run from a built tree (bin/m0serve, packages/m0-core/libm0core.so)
— `poe stress-pool` runs it in the m0lin container, which is where the
lost pool wake reproduced (2 of 10 rounds, 2026-09-05; never on macOS).

    python3 scripts/probes/phase5_probe.py [ROUNDS]
"""
import json, os, socket, subprocess, sys, threading, time, urllib.request

PORT = 8080
ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else 10
env = dict(os.environ, M0_CORE_LIB=f"{os.getcwd()}/packages/m0-core/libm0core.so", M0_SSE_HEARTBEAT_MS="500")
cmd = ["bin/m0serve", "djangoproj.wsgi:application", "--app-dir", "apps/django_realtime",
       "--port", str(PORT), "--realtime", "--health-path", "/health",
       "--static", "/static/=apps/django_realtime/static", "--blocking-threads", "4",
       "--static-cache-control", "public, max-age=3600"]

def health():
    with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=5) as r:
        return json.loads(r.read())

def slow():
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{PORT}/slow", timeout=20).read()
    except Exception:
        pass

fails = 0
for rnd in range(ROUNDS):
    log = open(f"/tmp/p5_{rnd}.log", "w")
    srv = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)
    t0 = time.time()
    while True:
        try:
            health(); break
        except Exception:
            if time.time() - t0 > 60:
                print(f"round {rnd}: never healthy"); srv.kill(); sys.exit(2)
            time.sleep(0.2)
    s1 = threading.Thread(target=slow); s2 = threading.Thread(target=slow)
    s1.start(); s2.start()
    time.sleep(0.3)
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=6)
    sock.sendall(b"GET /events?channel=pool&token=letmein HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n")
    t_sub = time.time()
    time.sleep(0.5)
    subs = health()["subscribers"]
    head = b""
    sock.setblocking(False)
    try:
        head = sock.recv(4096)
    except Exception:
        pass
    status = head.split(b"\r\n", 1)[0].decode(errors="replace") if head else "(no bytes yet)"
    # give a late registration a chance to show, for the record
    late = None
    if subs != 1:
        time.sleep(1.5)
        late = health()["subscribers"]
    ok = subs == 1
    fails += 0 if ok else 1
    print(f"round {rnd}: {'ok  ' if ok else 'FAIL'} subscribers={subs}{'' if late is None else f' (after 2s: {late})'} head={status!r}", flush=True)
    sock.close()
    s1.join(timeout=5); s2.join(timeout=5)
    srv.terminate()
    try: srv.wait(10)
    except subprocess.TimeoutExpired: srv.kill()
    log.close()
    if not ok:
        print(open(f"/tmp/p5_{rnd}.log").read()[-1500:], flush=True)
print(f"TALLY: {fails} of {ROUNDS} rounds failed (M0_POOL_RING={os.environ.get('M0_POOL_RING', 'unset')} M0_POOL_ELASTIC={os.environ.get('M0_POOL_ELASTIC', 'unset')} M0_POOL_PARALLEL={os.environ.get('M0_POOL_PARALLEL', 'unset')})")
sys.exit(1 if fails else 0)
