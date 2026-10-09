# Probes and instruments

The measuring tools the design notes under `docs/notes/` quote numbers
from. None is a CI gate; two are pre-release gates through `poe`.

| file | what it measures | runner |
|---|---|---|
| `phase5_probe.py` | `smoke-django-realtime` phase 5 repeated with a fresh server each round: a hold taken on a pool thread behind two slow views must register within half a second (the lost pool wake, docs/notes/pool-ring-handoff.md) | `poe stress-pool` (Linux container) |
| `hold_race_probe.py` | forty SSE holds opened one at a time while three clients keep the loop busy; every one must register | `poe stress-pool` |
| `herd.c` | CPU per datagram round trip with W receivers blocked on one `SOCK_DGRAM` pair (macOS wakes all W, Linux the oldest; docs/notes/elastic-pool.md) | `poe probe-herd` |
| `handoff_pingpong.c` | one loop-to-worker handoff by primitive: datagram pair, datagram pair with a `kevent` park, condvar, spin (docs/notes/pool-ring-handoff.md) | `cc -O2 -o /tmp/pp scripts/probes/handoff_pingpong.c && /tmp/pp` |
| `fairness_sweep.py` | `pool_fairness_probe.py`'s arms across loads -- threads, connections, the view's length, CPUs, busy loops beside the server -- with a request's share of the GIL per load: the instrument that chose the probe's load (docs/notes/fairness-judged-by-order.md) | `uv run python scripts/probes/fairness_sweep.py --list` |
| `bench_threads.py` | one server under `wrk` with per-thread CPU by `ps -M` and an optional `xctrace` profile; one JSON line per run | see its docstring |
| `bench_arms.py` | alternates pool arms (zero-config, eager, bt1, …, granian) under `bench_threads.py` | see its docstring |
| `bench_slow.py` | the fast route's tail with N slow Django views in flight, one fresh server per arm and round, arms alternated; arms carry env overrides and alternative binaries | see its docstring |
| `bench_http_parts.mojo` | the Mojo HTTP layer's user-space cost per request, part by part in isolation: the header scan, the parse, the request object, header lookups, routing, the response encode (docs/SERVER_PERFORMANCE.md, docs/notes/loop-user-space.md) | `uv run mojo run -I packages/m0-http -I packages/m0-core scripts/probes/bench_http_parts.mojo` |
| `bench_bridge_parts.mojo` | the WSGI and ASGI bridge's cost per request, part by part, in both directions (docs/WSGI_PERFORMANCE.md) | `uv run mojo run -I packages/m0-wsgi -I packages/m0-http -I packages/m0-core scripts/probes/bench_bridge_parts.mojo` |
| `py_thread_probe.mojo` | Mojo-spawned pthreads attaching to the embedded interpreter through the raw C API: correctness per mode and the parallel speedup, the thread pool's go/no-go (docs/notes/wsgi-vs-asgi-history.md) | `poe py-thread-probe`, which builds it against the venv's libpython |
| `py_thread_stdpy_probe.mojo` | the same through `std.python`'s own bindings with no libpython on the link line, plus `print` from a pthread and a parametric `def` as a start routine | `poe py-thread-probe-stdpy` |
| `mut_copyback_matrix.py` | when a write made through a struct's address is lost across a call: a `mut` argument of 256 B or less passed by value and stored back, a stack local hidden by a `tail` call, and a larger `mut` argument's `noalias`, each read from the unoptimized IR and run; `--census IR` lists the first shape in a real program (docs/notes/mut-arguments-and-raw-addresses.md) | `uv run --no-sync python scripts/probes/mut_copyback_matrix.py --evidence` |
| `float64_rounding_probe.mojo` | whether the toolchain's `Float64` parsing and printing round correctly: known one-ulp misses of both kinds on Mojo 1.1.0, the printer judged by libc's `strtod`; exits 1 while any still misses, 2 if a control fails (the Known issue in docs/ROADMAP.md) | `uv run mojo run scripts/probes/float64_rounding_probe.mojo` |
| `quiet-machine-ab.md` | the runbook for two pool A/Bs that need a quiet machine, both run 2026-10-09 with no difference: the wake and thread records on 128-byte lines against 64 (LF24), and the cost of the park's look at its lane socket (LF22); the arms, the commands and what result changes the code | read it; a release's quiet stage |
| `pool_ab.py` | that runbook's runner: arm A against arm B, alternated, over `poe probe-pool`'s pooled row and `poe probe-pool-fairness`'s fair arm, `uptime` and the busiest processes recorded beside every cell; prints the verdict by the runbook's rule and writes an artifact under `bench/results/pool-ab-<YYYY-MM>/` | `uv run --no-sync python scripts/probes/pool_ab.py LF24` |
| `xctrace_report.py` | per-thread on-CPU self time by leaf symbol from an `xctrace` export (regex-based: Mojo symbols break the XML) | see its docstring |
| `linux_setup.sh`, `linux_sync.sh` | create the `m0lin` build container and copy the Mac tree into it | header of each |
| `source_stamp.sh` | a content hash of the sources the sync copies, computed identically on the Mac and in the container, so a sync that landed the wrong tree is loud | `bash scripts/probes/source_stamp.sh` |

Absolute rates on a laptop move 5–10 % across a session; alternate arms
and quote ratios. The two shell benches under `scripts/` refuse to run
while the machine is busy (`scripts/bench_guard.py`); these do not, so
look at `ps` first.
