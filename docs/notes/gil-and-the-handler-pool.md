# The GIL and the handler pool — measured 2026-09-09

> Whether `--blocking-threads N` gives a view N threads *at once* is decided
> inside the view, not by the server. This is the measurement that says so,
> the row it produced (SPEC E19), and what it settles about running model
> inference on this server.

## The question

`--blocking-threads N` puts N handler threads behind one event loop. SPEC C5
proves the isolation that buys: a slow view no longer holds the keep-alive
connections pinned behind it. Users then assume the other half — that N
threads do N things at once — and that half is only sometimes true.

It came up as a Core ML finding. An embedding app served through m0serve got
the same throughput on one handler thread and on two, and *lost* a third on
the zero-config eight ([MiniLM on the Neural Engine](coreml-embeddings.md)):

| Core ML embedding app, c8 | req/s | p50 ms | p99 ms |
|---|---:|---:|---:|
| one worker, one blocking thread | 1680 | 4.74 | 5.11 |
| one worker, two blocking threads | 1684 | 4.73 | 5.29 |
| one worker, zero-config pool of 8 | 1159 | 7.07 | 15.75 |

`MLModel.predict` holds the GIL for its duration, so one process is one
prediction at a time however many threads are waiting to start one. That is a
property of the workload. Nothing in the server could fix it, and nothing in
the server said it.

## Does MAX behave differently?

MAX was the obvious comparison, and the answer was not on record. First the
mechanism, in isolation, with no server involved: one thread spins a pure
Python counter, a second drives the workload, and the spinner's lost
iterations are the instrument (`scripts/gil_probe.py` in the
mojo-addon-examples checkout).

The reading needs three controls, because a hold costs the spinner a
different amount depending on where it lives. Python-level work yields every
5 ms switch interval, so two threads split the lock and the spinner loses
about half. A single C call that never drops the lock blocks the spinner for
its whole duration, so it loses nearly all. Both are holds.

| arm | spinner loss | worker busy | reading |
|---|---:|---:|---|
| `time.sleep` | -0.6% | 100% | releases, by construction |
| Python bytecode | 49.9% | 100% | holds at ~half, by construction |
| one C-level `re.match` | 88.1% | 100% | holds at ~all, Core ML's shape |
| **MAX `embed_batch_l2`** | **-4.9%** | **100%** | **releases** |
| **MAX `model.execute` alone** | **-6.4%** | **100%** | **releases** |

MAX releases the GIL. The controls bracket the answer on both sides, and the
C-level control's 88% is the same shape E4 measured for Core ML's `predict`
(24% loss at 28% busy).

## What it is worth at the server

MiniLM-L6-v2, seq 128, batch 1, through `bin/m0serve` on one worker, wrk at
eight connections for 15 s, one server per row started fresh and warmed:

| blocking threads | req/s | p50 ms | p99 ms | vs one thread |
|---:|---:|---:|---:|---:|
| 1 | 215.9 | 35.55 | 85.41 | 1.00x |
| 2 | 260.0 | 30.14 | 43.20 | 1.20x |
| 4 | 289.4 | 27.15 | 39.98 | 1.34x |
| 8 | 300.6 | 26.30 | 35.48 | 1.39x |

It scales, where the Core ML rows above are flat and then negative. The GIL
release is real and it reaches the server.

## But the ceiling is the engine, not the lock

1.39x from eight threads is not eight, and the reason is not the GIL. The
process draws **408% CPU with a single handler thread** and 414% with four,
on a machine with four performance cores. MAX's CPU backend is already
parallel — 29 OS threads in the process — so one request in flight already
fills the machine, and more handler threads can only overlap what is left.

What is left is small. Per request, warm:

| stage | ms |
|---|---:|
| tokenize | 0.024 |
| to numpy | 0.005 |
| `embed_batch_l2` | 5.066 |
| round + tolist | 0.005 |
| `json.dumps` | 0.103 |

The GIL-holding Python around the call is 0.14 ms of 5.2 — under 3%. So both
facts hold at once: releasing the lock is necessary, and on this machine it
was not sufficient, because the resource the threads wanted was already
spent.

## Three more things the sweep settled

- **MAX cannot run in a forked worker either.** `--workers 2` crashes and
  respawns in a loop, the same class as Core ML and for the same reason a
  multithreaded C++ runtime cannot survive `fork()` without `exec`.
  `--spawn-workers` (SPEC E15) runs cleanly and is *slower* here — 223 req/s
  against 260 for one worker — because a second process contends for the same
  saturated cores and loads its own copy of the weights.
- **MAX on the CPU is not the fast backend on a Mac.** 5.07 ms a call against
  Core ML's 0.483 ms on the Neural Engine, and 216–300 req/s served against
  Core ML's 1698. The GIL result is a mechanism finding. It is not a reason to
  switch backends on this hardware, and the place it would pay is a machine
  with more cores than the engine saturates, or one where Core ML does not
  exist.
- **The toolchain does not offer a third option.** MAX has no model-execution
  API reachable from Mojo: the Mojo packages are kernel authoring
  (`nn`, `linalg`, `layout`, `algorithm`), the `max/c` headers that declare
  `M_compileModel` ship with no implementing binary in `max-core` 26.5.0, and
  `InferenceSession` lives only in the CPython extension. Running a model
  without an interpreter in the path means hand-writing its forward pass on
  those kernels.

## What went into the tree

The server-side half of this is a capability, so it is gated rather than
narrated. **SPEC E19**: a view that releases the GIL runs in parallel across
`--blocking-threads` and one that holds it does not.

`bareapp`'s `/work` is a single hashlib call over two buffer sizes either
side of CPython's `HASHLIB_GIL_MINSIZE`, so the lock is the only variable
between its modes — 64 KB releases, 1 KB does not. `smoke-pool-parallelism`
times one request and then two at once for each mode on one server in one
run, and compares the ratios: 1.02x for the releasing mode against 2.01x for
the holding one.

Three things about the gate are deliberate. It asserts a **gap between two
modes**, never a wall-clock threshold, because an absolute figure on a shared
runner measures the runner. It uses **two threads and two connections**, never
four, because a probe that asks four threads to spread four jobs is asserting
scheduler fairness and CI's three-core runners disprove that. And it uses
**fixed work rather than a deadline**: `/busy` beside it spins to a wall-clock
time, so two `/busy` requests at once finish in 1.0x on any server however
serialised they really were. An early draft of the probe used it and passed
against nothing.

## The deployment rule

Two independent questions decide whether more handler threads help, and both
are the application's rather than the server's:

1. **Does the work release the GIL?** If not, one process is one request at a
   time and the pool buys isolation only. Core ML, and any C extension that
   holds the lock, are here. Use one or two threads and scale with
   `--spawn-workers`.
2. **Is there headroom left?** If the library is already parallel, one
   request in flight may already fill the machine. MAX on CPU is here. More
   threads buy the non-parallel remainder and no more.

A view that blocks in a syscall — a database round trip, an outbound call —
is the case the pool was built for and answers yes to both.
