# Probes and instruments

The measuring tools the design notes under `docs/notes/` quote numbers
from. None is a CI gate; two are pre-release gates through `poe`.

| file | what it measures | runner |
|---|---|---|
| `phase5_probe.py` | `smoke-django-realtime` phase 5 repeated with a fresh server each round: a hold taken on a pool thread behind two slow views must register within half a second (the lost pool wake, docs/notes/pool-ring-handoff.md) | `poe stress-pool` (Linux container) |
| `hold_race_probe.py` | forty SSE holds opened one at a time while three clients keep the loop busy; every one must register | `poe stress-pool` |
| `herd.c` | CPU per datagram round trip with W receivers blocked on one `SOCK_DGRAM` pair (macOS wakes all W, Linux the oldest; docs/notes/elastic-pool.md) | `poe probe-herd` |
| `handoff_pingpong.c` | one loop-to-worker handoff by primitive: datagram pair, datagram pair with a `kevent` park, condvar, spin (docs/notes/pool-ring-handoff.md) | `cc -O2 -o /tmp/pp scripts/probes/handoff_pingpong.c && /tmp/pp` |
| `bench_threads.py` | one server under `wrk` with per-thread CPU by `ps -M` and an optional `xctrace` profile; one JSON line per run | see its docstring |
| `bench_arms.py` | alternates pool arms (zero-config, eager, bt1, …, granian) under `bench_threads.py` | see its docstring |
| `bench_slow.py` | the fast route's tail with N slow Django views in flight, one fresh server per arm and round, arms alternated; arms carry env overrides and alternative binaries | see its docstring |
| `xctrace_report.py` | per-thread on-CPU self time by leaf symbol from an `xctrace` export (regex-based: Mojo symbols break the XML) | see its docstring |
| `linux_setup.sh`, `linux_sync.sh` | create the `m0lin` build container and copy the Mac tree into it | header of each |

Absolute rates on a laptop move 5–10 % across a session; alternate arms
and quote ratios. The two shell benches under `scripts/` refuse to run
while the machine is busy (`scripts/bench_guard.py`); these do not, so
look at `ps` first.
