# Scheduling stickiness: which worker wins the accept race is CPU placement, not load

> A design note from the engineering record, moved out of ROADMAP.md's
> Known issues on 2026-09-05 and kept as written. The change that followed
> is [accept sharing](accept-sharing.md).

**Scheduling stickiness: two forked workers, one shared listener, and
eighty accepts in a row to the same worker — reproduced, and it is CPU
placement, not load.** Seen once (2026-08-29, ubuntu CI runner, PR
#168's first run): `smoke-reload`'s two-worker phase re-forked both
workers onto the new module — both logged their loop start — and then
every one of ten rounds of eight fresh connections was answered by
worker 6522; the smoke wants to see both pids and failed. The first
recorded failure of that step, and the CI re-run of the same job on the
same head passed. The mechanism it looked like was right, the load
theory attached to it was not, and the fix direction it named was
backwards; all three measured 2026-09-02 in a Linux container (colima,
4 vCPU, the 0.16.0 aarch64 wheel, `--workers 2`, the smoke's own probe
of 10 rounds x 8 sequential connections) with
`scripts/accept_placement.py`.

The mechanism: `M0_WORKERS` forks after `listen`, so both workers share
ONE listen socket, each registers it `EPOLLIN|EPOLLET` in its own epoll,
and on a connection both wake and the first to reach `accept()` drains
the backlog until EAGAIN while the other gets EAGAIN and parks. Which
one is first is the scheduler's, and on a quiet 4-CPU box it is already
the same one nine times in ten: 63–77 of 80 to one worker across 15
unpinned runs, the smoke passing each time only because the minority
worker surfaced in round 1–3. What makes it ten of ten is where the
CLIENT runs. Workers pinned to CPUs 0 and 1 and the probe on CPU 1:
80 of 80 to the worker on CPU 0, no round with both pids, in four runs
of five (the fifth 79/1). Probe on CPU 2: 70–76 of 80. The worker that
shares the client's CPU loses every time — the accept-queue wakeup runs
inside the client's own `connect()` on its CPU, the worker with an idle
CPU of its own is running before the client has blocked, and the
co-located worker finds an empty backlog when it finally runs. Nothing
pins tasks on a CI runner, but wake-affine placement can hold exactly
that shape for the five seconds the probe lasts, and that is the
sighting. Load is not the mechanism and tends to CURE it: everything on
one CPU alternates 45/35 (one runqueue, CFS's vruntime picks the worker
that has run less), and hogs beside either worker move the split toward
even, not away from it. Concurrent connections do not fix it either
(the burst is drained by whichever worker wakes first; 1–3 rounds of 10
in most placements).

`EPOLLEXCLUSIVE` is NOT the fix direction: in a pure-Python model of the
accept path it sends 80 of 80 to one worker in every placement, quiet or
loaded — it removes the very race that was giving the other worker its
share. Per-worker `SO_REUSEPORT` listeners (bound after the fork, the
kernel hashing connections across them) balance 40/40 to 46/34 in every
placement and are the only shape that does. Not adopted on one CI
failure: it changes the accept path of every prefork deployment, and a
connection queued at a worker that dies is reset until the respawn
rebinds — the shared socket is what makes the supervisor's respawn and
`--reload` invisible to clients. Sequential one-shot connections from a
single client are the smoke's shape, not a deployment's; keep-alive
connections spread over time, and gunicorn's and nginx's prefork share
the property.

The smoke is asserting scheduler fairness (memory: "assert blocking, not
fairness"), and loosening it to one pid would hide what it exists to
see. The assertion that does not depend on fairness was measured on the
same wheel under the reproducing placement: SIGSTOP the worker that
answered, and the same probe is answered 80 of 80 by the other worker,
promptly (5.5 s for ten rounds, all of it the probe's own sleeps); SIGCONT
it, and SIGTERM exits 0 with no `crashed` or `respawned` line — the
supervisor reaps with `WNOHANG` alone, so a stopped worker is neither a
crash nor a respawn. `smoke-reload`'s two-worker phase now asserts it
that way — stop the worker that answered, the other must serve the new
body 8 of 8, and both pids must be the ones the supervisor logged as
re-forked — and was sabotaged in both layers before it counted: with
`kill -STOP` made a no-op it fails as "SIGSTOP did not take", and with
`_reload` altered to leave the old worker 1 alive while logging it as
re-forked (so only the stop layer can see it) it fails naming the old
body that worker served. `accept_placement.py serve --stop-winner` is
the same measurement bare. `SO_REUSEPORT` per worker stays the change to
make to the server only if a deployment, not a probe, shows the
imbalance mattering.
