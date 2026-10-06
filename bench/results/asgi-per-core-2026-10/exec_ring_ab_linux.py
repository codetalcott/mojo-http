# Executor completion ring A/B in the container: M0_EXEC_RING=0 / 1 / uvicorn uvloop, rounds alternated.
import json, sys, os, statistics as st
sys.path.insert(0, "/work")
import bench_linux_arms as A
conns = int(os.environ.get("CONNS", "16")); rounds = int(os.environ.get("ROUNDS", "6"))
arms = [("ring off", [A.M0] + A.ASGI, {"M0_EXEC_RING": "0"}),
        ("ring on", [A.M0] + A.ASGI, {"M0_EXEC_RING": "1"}),
        ("uvicorn uvloop", A.uvi("uvloop"), {})]
res = []
for r in range(1, rounds + 1):
    for name, cmd, env in arms:
        x = A.measure(name, cmd, conns, 8, env); x.update(round=r); res.append(x); print(json.dumps(x), flush=True)
for n in [a[0] for a in arms]:
    v = [x for x in res if x["name"] == n and x.get("rps")]
    print(f"{n:<16} rps {st.median(x['rps'] for x in v):>9.0f}  cores {st.median(x['cores'] for x in v):.2f}  rps/core {st.median(x['rps_per_core'] for x in v):>8.0f}  spread {(max(x['rps'] for x in v)-min(x['rps'] for x in v))/st.median(x['rps'] for x in v)*100:.1f}%")
by = {}
for x in res: by.setdefault(x["round"], {})[x["name"]] = x
print("paired on/off per-core:", [round(d["ring on"]["rps_per_core"] / d["ring off"]["rps_per_core"], 3) for _, d in sorted(by.items())])
print("paired on/off rps:     ", [round(d["ring on"]["rps"] / d["ring off"]["rps"], 3) for _, d in sorted(by.items())])
