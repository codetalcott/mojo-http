# The asgi shape of bench_linux_arms.py with the executor inverted as a fourth arm,
# the server pinned to cpus 0-1 and wrk to 2-3 so the two never share a vCPU
# (the 2026-09-09 Linode run's noise was a 4-vCPU box shared by both).
import json, sys, subprocess, statistics as st
sys.path.insert(0, "/work")
import bench_linux_arms as A
SRV, CLI = ["taskset", "-c", "0,1"], ["taskset", "-c", "2,3"]
def pinned_wrk(conns, dur, lat=True):
    cmd = CLI + ["wrk", "-t2", f"-c{conns}", f"-d{dur}s"] + (["--latency"] if lat else []) \
        + A.HDRS + [f"http://127.0.0.1:{A.PORT}/"]
    return subprocess.run(cmd, capture_output=True, text=True).stdout
A.wrk = pinned_wrk
arms = [("m0serve asgi pump", SRV + [A.M0] + A.ASGI, {}),
        ("m0serve asgi inverted", SRV + [A.M0] + A.ASGI, {"M0_INVERTED": "1"}),
        ("uvicorn asyncio", SRV + A.uvi("asyncio"), {}),
        ("uvicorn uvloop", SRV + A.uvi("uvloop"), {})]
res = []
for r in range(1, 4):
    for name, cmd, env in arms:
        x = A.measure(name, cmd, 16, 8, env); x.update(round=r); res.append(x); print(json.dumps(x), flush=True)
for n in [a[0] for a in arms]:
    v = [x for x in res if x["name"] == n and x.get("rps")]
    if not v: print(n, "FAILED"); continue
    print(f"{n:<24} rps {st.median([x['rps'] for x in v]):>9.0f}  cores {st.median([x['cores'] for x in v]):.2f}  rps/core {st.median([x['rps_per_core'] for x in v]):>8.0f}  spread {(max(x['rps'] for x in v)-min(x['rps'] for x in v))/st.median([x['rps'] for x in v])*100:.1f}%")
