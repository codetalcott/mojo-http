# The asgi shape of bench_linux_arms.py, plus the executor inverted (M0_INVERTED=1).
import json, sys, statistics as st
sys.path.insert(0, "/work")
import bench_linux_arms as A
arms = [("m0serve asgi pump", [A.M0] + A.ASGI, {}),
        ("m0serve asgi inverted", [A.M0] + A.ASGI, {"M0_INVERTED": "1"}),
        ("uvicorn asyncio", A.uvi("asyncio"), {}),
        ("uvicorn uvloop", A.uvi("uvloop"), {})]
res = []
for r in range(1, 4):
    for name, cmd, env in arms:
        x = A.measure(name, cmd, 16, 8, env); x.update(round=r); res.append(x); print(json.dumps(x), flush=True)
for n in [a[0] for a in arms]:
    v = [x for x in res if x["name"] == n and x.get("rps")]
    print(f"{n:<24} rps {st.median([x['rps'] for x in v]):>9.0f}  cores {st.median([x['cores'] for x in v]):.2f}  rps/core {st.median([x['rps_per_core'] for x in v]):>8.0f}  spread {(max(x['rps'] for x in v)-min(x['rps'] for x in v))/st.median([x['rps'] for x in v])*100:.1f}%")
