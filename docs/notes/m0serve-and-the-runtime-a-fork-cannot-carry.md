# m0serve and the runtime a fork cannot carry — 2026-09-25

The Mojo host refuses `M0_WORKERS` above 1 when its binary links MAX's
parallel runtime, because a `parallelize` in a forked worker never
returns (SPEC E32, DECISIONS D48, [threads-first-for-m0-apps](threads-first-for-m0-apps.md)).
That note ended with a prediction about the other host in this tree: a
Mojo mount built into m0serve links the same runtime, m0serve's workers
are forked by default, so "a forked m0serve worker should hang the same
way, and `--spawn-workers` should not". This round measured both halves
and made the refusal m0serve's own. SPEC E33 is the row; D51 is the
decision it records.

## What was measured

The mount is `apps/serve_parallel/mount/m0serve_mount.mojo`, two views
over the job `apps/host_parallel` now keeps in `compute.mojo` (64 items of
100,000 square roots; `/par` spreads it with `parallelize`, `/ser` runs it
on the pool thread alone), built in place of the demo mount with
`M0SERVE_MOUNT_DIR=apps/serve_parallel/mount M0SERVE_INCLUDE=apps` and
served beside the bare WSGI app: `--mount /=bareapp.wsgi --mount
/par=mojo`. A 4-core Linux container (Intel Xeon, 2.8 GHz), Mojo 1.1.0,
`max-core` 26.6.0, one run per shape.

**Two forked workers, the refusal removed from `main` by hand** (the
doctor's kept). The root answered 200. `/par/ser` answered 200 in 23 ms
from a forked worker, so the mount, the lane and the fork are all fine.
`/par/par` did not answer within a 10 s client timeout, and neither did a
second request, one per worker. The root still answered afterwards: the
loop is not wedged, because a mount's view runs on a `MojoPool` thread,
and it is that thread that is gone — inside `parallelize`, waiting on
worker threads the fork did not copy. SIGTERM ended the process in
10.1 s with exit 0, each worker printing `1 handler thread(s) still
inside the application 5 s after the drain; exiting without them`: the
bounded join (`JOIN_TIMEOUT_NS`) did what it is for. So the shape differs
from the host's — there the request took its loop and SIGTERM was a
no-op — but the loss is the same: a request that never answers and a
pool thread held for the life of the process, and a lane's threads are
all it takes to lose the mount. The probe run against that binary failed
at its served-prefork phase, `--workers 2 was SERVED with the parallel
runtime linked; the refusal is gone`, which is the negative arm the gate
rests on.

**Two spawned workers.** `--workers 2 --spawn-workers`: each worker forks
and then execs the binary, and the runtime starts fresh in the new image.
Both exec'd images answered `/par/par` (by `x-pid`, sixteen requests at
once), `/par/ser` agreed on the digest, and SIGTERM drained the
supervisor to 0. `/par/par` took 8,433 µs against `/par/ser`'s 11,744 —
the same split the host measures for the same job on the same cores.

**One process.** No topology flag: `/par/par` answered from a pool
thread. `--reload` alone is refused, since it supervises even one worker
and the worker is forked; `--reload --spawn-workers` passes the doctor.

**The shipped binary.** `bin/m0serve` links no MAX, and its doctor at
`--workers 2` passes the check with `topology.parallel_runtime` false.
The refusal is a fact about the image, not a rule about the flag.

## The decision

Refuse and name the flag; do not switch to spawning when the image links
the runtime. The alternative was considered and is cheap to build —
`parallel_runtime_forked` already knows the answer — and it is not
built, for three reasons. The worker mode is the operator's contract: a
spawned worker is one more process start per worker and an image that
re-reads its environment at exec, which is visible in a deploy's timing
and in what a worker sees. `--doctor`'s contract is that its exit equals
the server's for the same flags, and a doctor that reports `worker_mode:
fork` for a server that silently spawns is the drift `smoke-doctor`
exists to catch. And a mode chosen by what a binary happens to link is a
deploy that changes shape when a mount gains an import, with nothing in
its flags to say so. D51 records it, with the measurement that would
retire it: a deploy where the exec's cost is what keeps prefork off a
MAX-linked mount.

## What holds it

`smoke-serve-parallel-runtime` (SPEC E33), every pull request, in the
`smoke` job directly after the host's MAX step and under the same `max`
group sync. `scripts/serve_parallel_probe.py` runs seven phases: the
doctor refuses two workers and `--reload`; the server refuses two workers
before the bind, bounded so a refusal that stopped refusing fails on the
served prefork rather than hanging CI; the doctor passes both spawned
shapes; the shipped binary passes unlinked; two exec'd workers serve;
one process serves. What it never does is ask a forked worker for
`/par/par`.

Three things about the build are load-bearing. The task calls `poe
build-serve` bare, not through `uv run`: a plain `uv run` re-syncs the
venv without the `max` group, and the runtime would leave the venv in
the middle of the smoke. `M0SERVE_INCLUDE=apps` is what resolves
`host_parallel.compute` from the mount — one job, two hosts, so the two
refusals are measured against one binary shape. And the fact moved out
of `host.mojo` into `m0_http.parallel_runtime`, so the host's
`host_checks` and m0serve's `parallel_runtime_forked` read one function
(the predicate lives in `cli.mojo`, and `test_cli.mojo` pins its truth
table with the fact supplied by hand, in a binary that links nothing);
`host.mojo` imports it, `test_host_flags.mojo` imports it from there, and
`sabotage-host --only parallel` still passes against the moved fact.

## What it does not do

No sabotage script reverts m0serve's rules; the negative arm above was
run by hand and is recorded here. `--threads` on m0serve needs a
free-threaded interpreter and is not measured; nothing is forked there,
so the runtime should serve as it does on the host's threads. The host
still does not spawn (D48's retiring condition stands): its escape is
`M0_THREADS`, m0serve's is `--spawn-workers`, and each names its own.
