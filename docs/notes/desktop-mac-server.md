# The desktop-Mac server, and what the wheel gives up to ship

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

**The hypothesis** (not yet tested): this server's strongest commercial
position may be as a *desktop* server — a Mac mini or Studio running an
application on hardware someone already owns — rather than as a Linux
container competing with Granian and uvicorn on rps. The reasoning is that
Mojo's reason to exist is compute, and a Mac's compute is unusual: unified
memory, a GPU on the same die, a neural engine, and from M4 the SME/SME2
matrix extension. A server that could reach those from a request handler
would be doing something no Python server can.

**The finding that complicates it, which is concrete and already in the
tree.** `poe build-serve` pins `--target-cpu` to the *oldest* Apple Silicon:

    Darwin-arm64) tcpu=apple-m1 ;;      # oldest Apple Silicon

That pin exists because it had to — the first release crashed with SIGILL
in a clean container, and the comment beside it records that this
developer's machine natively targets `apple-m4` with **+sme/+sme2**, which
no M1/M2/M3 has. So the honest answer to "does the PyPI wheel retain
M-series-specific capability?" is **no, deliberately**. One portable wheel
per platform and per-microarchitecture code generation are the same
tradeoff seen from two sides, and the release path currently takes
portability.

That is not an argument against the hypothesis. It is an argument that
**the current distribution shape and that hypothesis are in tension**, and
that the tension should be resolved deliberately rather than discovered.
The options, none costed yet:

- per-microarchitecture wheels (`apple-m1` / `apple-m4`), selected by
  `pip` — more release matrix, and `pip` has no microarch selector, so it
  would need a launcher or a source path
- runtime dispatch: one binary, feature-detected code paths — the usual
  answer, and the most work
- keep the wheel portable and treat accelerator work as an opt-in
  component built on the target machine

**What has to be established before any of that is worth costing**, because
the whole hypothesis rests on it:

1. **Can Mojo target the Apple GPU at all?** Not assumed either way here.
   This toolchain has no `gpu` module — `from gpu.host import DeviceContext`
   fails with "unable to locate module 'gpu'" — but this repo installs
   `mojo` alone rather than the full MAX package, so that is evidence about
   *our* install, not about Modular's support. Check the MAX documentation
   for Metal/Apple Silicon status before building anything on it.
2. **The neural engine is probably not reachable.** Apple exposes the ANE
   through CoreML and publishes no low-level API; a language targeting it
   directly would be doing something Apple does not document. Treat "tap
   the neural engine" as *via CoreML from Python*, which needs no Mojo at
   all, until shown otherwise.
3. **What would a request handler actually do with it?** The server's hot
   path is HTTP parsing and a CPython crossing; neither is matrix work.
   The win, if it exists, is in *application* code the server hosts — which
   makes this a story about `m0-core`/MAX rather than about the HTTP layer,
   and possibly a different product.
4. **Is the premise even load-bearing?** `has_accelerator()` returns True on
   this M4, but that is one bit and should not be over-read.

Recorded now because the packaging decision that forfeits M-series
capability was made for a good reason, is already shipped, and would
otherwise be invisible to whoever picks this hypothesis up.

## 2026-09-04: the split, resolved deliberately

The tension above was resolved the day after it was recorded, by the design
page the ideas folder holds as `m0serve-apple-silicon.md` and by this
change. The resolution is **not a fork and not a second wheel**: one tree,
two build flavors, one backend seam, and runtime detection for what varies
within the M family. What landed:

- **`poe build-serve-native`** builds `bin/m0serve-native` for the build
  host's CPU and OS floor -- the M-series-specific codegen the wheel forfeits
  -- as a local build or a release tarball, never a wheel, because pip
  cannot select a microarchitecture. `--doctor` tells the two apart:
  `build.apple_target` is `m1` for the wheel on every Mac (the pin above)
  and the host's generation for the native build. On the M4 that raised the
  question the two binaries answer `m1` and `m4`.
- **One backend seam.** `lightbug_http/c/platform.mojo` names
  `PlatformBackend` (kqueue on macOS, epoll on Linux) and the two libc
  constants that differ between them. The choice used to be spelled out at
  five sites, each a `comptime if CompilationTarget.is_macos()` with the
  import inside the branch, plus three private copies of `MSG_DONTWAIT`.
  Mojo 1.0 accepts a conditional type alias as a type parameter and a
  variable type but can only construct it through an initializer a shared
  trait declares, which is why `ConstructibleBackend` exists; a factory
  returning the alias does not compile (no implicit conversion, and
  `rebind` needs a copyable value). `check_backend_seam` in
  `scripts/check_docs.py` refuses a backend chosen anywhere else.
- **Performance cores are a runtime fact, reported, not a compile-time
  one.** `--doctor` now prints `topology.performance_cpus` (4 on this M4,
  beside `cpus: 10`) from the stdlib's `num_performance_cores`, checked in
  CI against `sysctl` as a second source. The compile-time predicates
  (`is_apple_m4()` and friends) answer what the BUILD targeted, which under
  the `apple-m1` pin is m1 on every Mac.
- **`--qos` / `M0_QOS`**: the event loop at user-interactive QoS and pool
  and executor threads at user-initiated, the one placement lever Darwin
  offers (there is no affinity API). Behind a knob, default off, because
  the effect is a measurement, below.

### The pool-size question, measured and closed

The page's strongest-evidence item was that zero-config sizes the handler
pool from `sysconf`, which counts efficiency cores: `min(10, 8) = 8`
threads on a machine with 4 performance cores. Measured on that machine
(2026-09-04, `bin/m0serve` at fb33593, `wrk -t4 -c64 -d8s`, two rounds,
the bare WSGI app):

| pool threads | `/` (loop only) rps | `/busy?ms=1` (1 ms of CPU under the GIL) rps |
|---|---|---|
| 4 | 141k, 99k | 956, 982 |
| 8 | 117k, 130k | 979, 982 |

The CPU-bound view is pinned at the GIL's ceiling (1 ms per request, one
thread at a time, so about 1000 rps) whichever the count, and hello-world
differs only inside the run-to-run noise. A pool thread's parallelism is
WAITING -- a thread parked in a view holds no core -- so the count that
matters is how many views may wait at once, and an efficiency core is as
good as any for that. The zero-config rule stays at logical CPUs
(`pool_cpus` in `cli.mojo` is the one home of that policy, and its
docstring carries these numbers); the P-core count steers PLACEMENT
through `--qos`, not size.

### The QoS knob, measured: no effect on this box, so it stays off

Same machine, same harness, `--blocking-threads 4`, the knob the only
variable; then again with six `yes > /dev/null` hogs at default QoS
competing for every core:

| scenario | `/` rps, qos off | `/` rps, qos on | `/busy?ms=1` rps, off / on |
|---|---|---|---|
| idle machine | 145k, 147k | 148k, 148k | 985, 985 / 985, 986 |
| six CPU hogs | 66k, 65k | 66k, 65k | 977, 974 / 978, 977 |

The hogs halve hello-world in both arms and the knob moves nothing,
tails included. Two readings, neither flattering to the knob: the
scheduler already places a busy default-QoS thread on a performance core
when one is free, so there is nothing to win idle; and under contention
the load generator is starved as much as the server, so the harness
cannot see a placement win even if there is one. What docs/BENCHMARKS.md
measured was the reverse experiment -- a worker pinned to BACKGROUND QoS
serving at a quarter of the rate -- which shows the E-cores are slow, not
that asking for a P-core gets one you would not have had. The knob is
kept, default off, because it is harmless, `--doctor` reports it, and
the measurement that would justify a default is one on a Mac serving
alongside real desktop applications, not one under `yes`. The sequencing
the page proposed stands: the §4.2 in-memory handoff with a Darwin wake
primitive is the next lever, and microarchitecture flavors last.
