# Workers, signals and the fork: why each process rule holds — moved out of CLAUDE.md 2026-09-28

> A design note from the engineering record, moved out of CLAUDE.md on
> 2026-09-28 (review record C11) and kept as written. CLAUDE.md's "Runtime
> constraints" keeps each rule in a line or two and points here for the
> reason.

## Graceful shutdown is opt-in, and armed after the fork

`install_shutdown_signals()` returns the fd to pass as `shutdown_read_fd`;
its handler writes one byte to that pipe and nothing else. Dispositions and
fds are both inherited across `fork()`, so a pre-fork install points every
worker at the supervisor's pipe, which nothing watches — each worker arms
itself once `fork_all()` returns, and the supervisor arms a different
handler (`kill` each child) from inside `fork_all`, which is what makes
`docker stop` on the supervisor alone reap the workers.

**A forked worker must end with `exit_worker()`, never by returning from
`main`**: the runtime's teardown calls into libdispatch, which is unusable
after a fork without exec, and the worker dies with a SIGTRAP the supervisor
reads as a crash.

**Once told to stop, the supervisor respawns nothing** (SPEC D10): its
handler records the stop before forwarding the signal, and a worker that
then fails its drain is not replaced — the supervisor exits 1 once the rest
are gone — because a replacement would never be signalled and `docker stop`
would end in SIGKILL.

**Between the fork and the arm, SIGTERM takes the default action.**
`_forget_supervisor_signals` restores it in every child, and the worker's
own handler goes in only when its caller calls `install_shutdown_signals`:
at once in the Mojo host, after the application's import in m0serve. A stop
that reaches a worker in that window kills it. That is a stop, not a
failure: a worker that has armed catches the signal, so dying of it names
exactly the unarmed case, and no entry point starts its loop before it
arms, so the worker had taken no request. The supervisor judges it so, and
judges every other worker it reaps as supervision ends (`_reap_the_rest`),
where it used to reap the rest blind once such a death came first — so a
sibling failing its drain went unseen and the exit was 0 (review S1). Under
accept sharing a sibling used to hand the unstarted worker connections,
which died with it; since review AR a worker is handed nothing until its
loop starts ([accept-sharing](accept-sharing.md)). A gate that signals a
supervisor waits for every worker's `armed for a graceful stop` line, never
for one worker answering. The Mojo host prints it as each forked worker
arms; m0serve prints the same line, since review AR, wherever its handler
is armed (a forked or spawned worker, the one process, `--threads`), and
before its banner, which used to come first. m0serve's window is the
application's import, so it is the wider one: signalled once one worker
answered, a sibling of the bare app still importing died of the signal in
5 to 19 rounds of 20 on macOS, the count rising with the machine's load.
`M0_TEST_ARM_GAP_MS` holds each worker but the first in the window, for
the host and for m0serve, so `smoke-shutdown` proves that wait on every
run; `pid1_probe.py` waits for the lines too before its `docker stop`.

## After fork() without exec, platform runtimes are off limits

Including from application code. The `exit_worker()` rule above is one
instance; the general form bites WSGI apps directly. On macOS `urlopen`
consults the system proxy through `_scproxy`, which calls into
CoreFoundation, and Objective-C aborts the process rather than run in a
forked child: under `M0_WORKERS>1` the worker dies with SIGKILL and the
supervisor respawns it, so it reads as a dropped connection and a churning
worker, not a crash. `M0_WORKERS=1` runs the identical code cleanly, which is
what makes it look like a load bug. `http.client.HTTPConnection` does no
proxy lookup — `apps/wsgi_bare`'s `/reentrant` route is the worked example
and `poe smoke-wsgi` pins it.

Apple's libsqlite3 is in this family too, and it needs no application code
at all: it instruments `openDatabase` with os_signpost, and in a forked child
that path can fault — both children of a round killed by SIGSEGV inside
`_os_log_preferences_refresh`, 3 of 60 runs of `test_file.mojo` on an M4
([a-signpost-in-a-forked-child](a-signpost-in-a-forked-child.md)). So a
worker that opens an m0-sqlite connection after the fork is exposed on
macOS, and the answers are this family's usual one, `--spawn-workers`, or
`OS_ACTIVITY_MODE=disable` in the environment, which is measured at 0 of 200
and is what `test-sqlite` sets. A rerun is not the answer: the crash is
rare, real and not ours.

libpq is the third member: its connect reaches GSSAPI, then Kerberos, then
CoreFoundation, which is why `--pg-listen` is refused wherever a worker is
forked on macOS ([the-bus-and-its-doors](the-bus-and-its-doors.md)); MAX's
parallel runtime is the fourth, which does not survive a fork at all
([threads-first-for-m0-apps](threads-first-for-m0-apps.md)).

## A static without a global: `pop.global_alloc`

Mojo has no global `var`, but it does have `pop.global_alloc`. A POSIX
handler gets no user-data pointer, so `src/global_slot.mojo` reaches an
internal MLIR op for what C spells `static`. `@no_inline` on the accessors is
load-bearing (the op is `Pure`, so each inlined copy makes its own global),
the slots are private to m0-http so writer and reader share one emission, and
fork copies them rather than sharing — cross-process state is
`SharedAtomics`, not this. If the op ever stops working nothing is installed
and the default signal behaviour stands, because a handler over a dead slot
would swallow SIGTERM; `shutdown_signals_active()` reports which happened
and `test_lifecycle.mojo` asserts it.

## A pointer handed to C, and the `_ = x` after it

A pointer handed to C does not keep its buffer alive; the bare `_ = x` after
the call does. Mojo destroys a value at its last *tracked* use, and an
address laundered into a C argument is not one — `unsafe_ptr()` and
`Pointer(to=x).unsafe_bitcast[Int]()[]` both erase the origin tying it back
to the local. Measured on this toolchain: without the line the allocator
free is emitted BEFORE the call that reads through the pointer. Roughly
thirty sites end that way, `c/fdpass.mojo`'s `data` and `control` (the
`SCM_RIGHTS` hand-off under `--workers N`), `c/process.mojo`'s
`argv`/`bufs`/`path_c` (the `execv` behind `--spawn-workers`) and
`m0-wsgi/src/bridge.mojo`'s `body` among them; deleting one is a
use-after-free with no symptom at the call site.

**Only an OWNING value is at risk.** The release is Mojo's own destructor
call, placed by the frontend, which is why nothing downstream moves it back.
A plain stack local whose ADDRESS escapes — `fdpass.mojo`'s `iov` — is kept
alive by LLVM's escape analysis without help, so those keep-alives are
belt-and-braces; and `signal.mojo`'s and `multiworker.mojo`'s
`Pointer(to=handler).unsafe_bitcast[Int]()[]` LOADS the function value
rather than taking the local's address, so nothing escapes there at all. One
level of indirection separates the three cases.

`poe check-keepalive-barrier` is the gate (inside `test-all`):
`scripts/keepalive_probe.mojo` is compiled to LLVM IR and the pinned and bare
forms are compared. The BARE arm is the load-bearing half — without a
counterfactual the gate would pass on a toolchain where the line does
nothing and would have stopped being evidence — and `poe sabotage-keepalive`
reverts each of the probe's own rules and insists the check reports every
one. A failure is a finding about the toolchain, not gate noise; each
outcome prints what it means for the tree. The `_ = x^` transfer form is a
different thing and is NOT this idiom: the compiler warns it has no effect
on a trivially register-passable type, and the sites that use it are
genuine destroy-now uses on owning values.

## A reload refills what the poller stopped counting

`--reload`'s supervisor (`_supervise_polling`) counts the indices it
supervises in a local, one fewer for each worker it gave up on
(`_RESPAWN_FAILED`: the respawn budget spent, or a clean exit). A reload
(`_reload`) stops every worker and forks a replacement into every vacant
index — a given-up one included, on purpose: the edit that triggered the
reload may be the fix for the crash. Until 2026-10-09 the count did not
follow, so with two workers, one given up on, and an edit, the supervisor
counted one worker and served two; worker 0's clean exit brought the count
to zero, the supervisor left `fork_all` and exited 1, and the replacement
served on with nothing supervising it, an orphan that no SIGTERM to the
supervisor would reach. Found by the 2026-10-09 quality review reading the
two loops side by side (review record 605); `_supervise`, the blocking
loop, never reloads and was never affected.

The poller now recounts from the live pids after every reload, and the
reload clears the give-up (`_gave_up`), since nothing is vacant: a
development server whose crash a developer then fixed exits 0 at Ctrl-C.
`test_respawn.mojo:test_a_reload_refills_an_index_the_poller_gave_up_on_and_counts_it`
drives it with real forks and a real edit (SPEC D5), and fails on the old
code at "the supervisor left with the reload's replacement still serving".
The respawn budget is not reset by a reload: the old crashes are still
inside the window, so a replacement that crashes again is given up on at
once, and the next edit refills its index again.
