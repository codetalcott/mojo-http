# Threads first for m0 applications — 2026-09-25

The Mojo host has had two ways to more than one core since 2026-09-18:
`M0_WORKERS=N`, forked processes under a supervisor, and `M0_THREADS=N`, N
loops on N threads of one process. They measured the same, so the
documentation kept reaching for prefork first and served threads as the
option (DECISIONS D35). This round reverses that for applications built
with `m0`, on correctness rather than speed: a runtime an m0 application
is now expected to link does not survive `fork()`. D48 is the decision;
SPEC E32 is the refusal that keeps it honest.

## The question

MAX became the home of Mojo's parallel primitives at Mojo 1.0:
`parallelize` moved to `max.algorithm`, and Mojo 1.1 made the async task
API private, leaving `initialize_runtime()` and `parallelism_level()` in
`std.runtime`. An m0 application that spreads one computation over its
cores — a producer's `step`, a heavy view — links MAX's parallel runtime,
`libAsyncRTMojoBindings`. The question was which host mode serves it, and
the answer was found by running it under each.

## What was measured

`apps/host_parallel/probe.mojo`: two views over one CPU job, 64 items of
100,000 square roots. `/ser` runs it on the serving thread, `/par` spreads
it with `parallelize`. One request alone to each route, then eight clients
in a closed loop for five seconds against each, per host mode. A 4-core
Linux container (Intel Xeon, 2.8 GHz), Mojo 1.1.0, `max-core` 26.6.0, one
run per mode, a Python client on the same machine.

| host mode | `/ser` alone | `/par` alone | `/ser` under load | `/par` under load |
|---|---:|---:|---:|---:|
| one loop | 12.7 ms | 7.2 ms | 84 rps, p99 102 ms | 267 rps, p99 58 ms |
| `M0_THREADS=4` | 12.6 ms | 6.6 ms | 318 rps, p99 45 ms | 307 rps, p99 48 ms |
| `M0_BLOCKING_THREADS=4` | 12.4 ms | 4.0 ms | 318 rps, p99 32 ms | 307 rps, p99 33 ms |
| `M0_THREADS=2` and a pool of 2 | 12.5 ms | 4.1 ms | 317 rps, p99 35 ms | 296 rps, p99 48 ms |
| `M0_WORKERS=2` | 12.6 ms | **no answer in 8 s** | 84 rps, p99 112 ms | not run |

Three things the table says:

- **Prefork breaks.** The `/par` request under two forked workers never
  answered. Its worker's loop stayed wedged, the other worker carried
  everything at one loop's rate (84 rps, the single-loop figure), and
  SIGTERM had not ended the process after 12 s. A bare probe narrowed it:
  `parallelize` hangs in any forked child, including one whose parent
  never called it; after `fork()` then `exec()` it runs. A Mojo program
  starts its runtime before `main`, and `fork()` copies the calling thread
  alone, so a forked worker inherits the runtime's bookkeeping and none of
  its worker threads.
- **Under load, `parallelize` inside a view adds nothing** (318 against
  307 rps on four loops): the cores are already busy with other requests.
  It pays when cores are idle — one request alone, 12.6 ms serially and
  4.0 to 7.2 ms spread, and a single loop from 84 to 267 rps. That is the
  shape of a producer's `step` and of a heavy view that is rarely busy at
  the same time as another, and not of a hot route.
- **The pool lane gave the best tail** (p99 32 to 33 ms with the job on
  four handler threads, against 45 to 48 ms with it on four loops), which
  is what a pool is for: the loops keep answering streams and cheap routes
  while the views that compute wait their turn.

## The decision (D48)

An m0 application reaches N cores as N loops on N threads. On one vCPU it
stays one loop (D36). Views that compute go behind a handler pool.
`parallelize` belongs in a producer's `step` and in heavy views that are
rarely busy at once, never in a hot route. Prefork stays served, for an
application that links no MAX and wants a supervisor, and is REFUSED when
the binary links the parallel runtime.

D35's measurement stands and is the other half of the argument: threads
were already at parity with workers on throughput and the tail, at 0.56 to
0.80x the RSS, with x86's loop route at 256 connections the one consistent
figure in workers' favour. What moves the default is that one of the two
modes cannot serve what the application layer is now expected to use.

What threads give up is crash isolation: there is no supervisor, so a
crash ends the process and the platform restarts it, which the blobs
deploy already accepts. The way back, if an application asks, is a
supervised spawn — one exec'd child running its loops on threads,
respawned on a crash. The probe showed `fork` then `exec` works, and
m0serve already has the exec machinery (`--spawn-workers`, SPEC E15 and
E24); the host refuses spawning today, so this is future work, not a
promise.

## The refusal (SPEC E32)

`workers-vs-parallel-runtime` is a new entry in `host_checks`, the one list
`serve` and `--doctor` both read, so a count that cannot be served is one
refusal whichever way it arrived and the doctor cannot report as served
what the server refuses. It fails when `M0_WORKERS` is above 1 and the
binary links `libAsyncRTMojoBindings`, naming `--threads (M0_THREADS)` as
the fix, and exits 78 before the bind.

The fact is read off the loaded images, never by calling anything of
MAX's — this package imports nothing from it, and a binary without MAX
answers the check as passed. On Linux, `dlopen` with `RTLD_NOLOAD` answers
a handle for an image already mapped, matched by soname, and maps nothing
otherwise; probed here, it is true in the binary that links the runtime
and false in one that does not. macOS spells `RTLD_NOLOAD` as another bit
and matches a bare name less predictably, so that branch walks dyld's
image list by leaf name. The unit test supplies the fact by hand, since
the test binary links no MAX; the smoke proves the gathered one.

## What is gated

`smoke-parallel-runtime`, on every pull request on both platforms. Its CI
step is the only place the `max` dependency group is synced — `max-core`
pins `mojo-compiler==` to its own release's, so the pin moves with the
mojo pin and a bump of one without the other does not resolve — and the
next plain `uv run` puts the venv back. The gate app's entry file is
`probe.mojo` rather than `server.mojo`, so `build-apps`, whose venv holds
no MAX, never sees it.

Six phases: the doctor refuses two workers with the check failed and the
fix named; the server refuses them with 78 having bound nothing; the
doctor passes two loops; two loops serve `/ser` and `/par`, eight `/par`
at once, and drain to 0; a pool of two answers `/par` from a pool thread
(`x-thread` at or above 0); one loop answers it alone. The probe never
asks a forked worker for `/par` — that is the hang — and every wait it
makes is bounded, so `sabotage-host --only parallel`, which removes the
check, fails in seconds on the served prefork rather than hanging the
job. The two routes' job times go to the recorder as `parallel_view_us`
and `serial_view_us`.

## Not measured, and where it will be

macOS ran nothing on this page; the CI step's macOS leg is where the dyld
branch is first proven. A producer calling `parallelize` inside the host
was not measured, only views on loops and pool threads. And `parallelize`
inside a mount library loaded into m0serve, which the Django ramp would
need: a forked m0serve worker should hang the same way, and
`--spawn-workers` should not.

## What follows

`m0` learning MAX — a pinned MAX version beside the pinned Mojo, a doctor
check that applies only when `max-core` is installed, the release build
bundling `libAsyncRTMojoBindings` into `dist/`, and the scaffold's
AGENTS.md rules on capture lists (`def work(i: Int) {var out} -> None:`)
and on where `parallelize` belongs — is its own round.
