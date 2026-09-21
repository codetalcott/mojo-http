# A signpost in a forked child

2026-09-21. `test_two_processes_open_one_fresh_database` has gone red on
macOS CI twice in two days, both times on a pull request that touched
nothing near it: the failure that prompted #364 (which taught the test to
name the signal a child died of, precisely because a bare `-1` could not),
and #368, whose whole diff is a pause in a Python soak driver. A re-run
was green both times, which is the shape this repository has learned not
to trust — the ASGI executor's slot-ownership bug was found on exactly
such a "flake", 1 macOS smoke in 2, green on every re-run. This one is
not our bug and not the lock race the test is about, but it is real, and
it reproduces on demand once the test is run in bulk.

## What it is

The test forks two children per round and has each `open` the same fresh
database. The failing rounds had BOTH children killed by a signal. #364 had
just taught `_wait_exit` to name the signal, and with `MODULAR_DEBUG=stack-trace-on-error`
the crash handler symbolises it:

```
_sigtramp
_os_log_preferences_refresh + 36        libsystem_trace.dylib
os_signpost_enabled + 300               libsystem_trace.dylib
os_signpost_id_make_with_pointer + 32   libsystem_trace.dylib
openDatabase + 2564                     libsqlite3.dylib
src::conn::Connection::__init__
```

Signal 11, SIGSEGV, in both children. Apple's libsqlite3 instruments
`openDatabase` with **os_signpost**, and that path reads logging
preferences; in a process that forked without `exec` it can fault. It is
the family this tree already documents — `_scproxy` reaching
CoreFoundation, Core ML in a forked child — reached this time through
SQLite's own instrumentation rather than through application code.

## The measurements

The test binary, run in a loop on an M4 (macOS 26.6.2, arm64):

    observed: 20 runs, 2 failed; then 60 runs, 3 failed
    observed: 200 runs with OS_ACTIVITY_MODE=disable, 0 failed

`OS_ACTIVITY_MODE=disable` turns off the subsystem the trace faults in. At
the baseline rate a clean run of 200 is a 1-in-30,000 coincidence, so the
variable is the fix and the signpost path is the cause.

**The variable does not blunt the gate**, which is the check that mattered
before adopting it. With the `SQLITE_BUSY` retry removed from
`_switch_to_wal` — the defect O1 exists to catch — the test fails 12 of 12
runs *with the variable set*, and fails as `exit 1`, a child that lost the
lock, not as a signal. The two failure shapes stay distinguishable.

## What was NOT established

A minimal probe — fork a pair, open the database, exit, in a loop — did
**not** reproduce it in 3,360 children across three variants: a parent that
had never touched SQLite, a parent that had opened and closed a database
first, and a parent that waited 600 ms before its first fork. So the
arming condition is something the full test process has and a small one
does not, and it is not simply "the parent opened a database" or "the
process had been running a while". The failing rounds are always round 0,
the process's first fork, which says the same thing from the other side.

That is why the advice below is narrow. Do not read this as "a forked
worker that opens SQLite on macOS will crash": it is "this has been seen
in one process, and here is what turns it off".

## What it means for an application

A Mojo host or `m0serve` worker builds its handler AFTER the fork, so an
application whose handler opens an m0-sqlite connection under
`M0_WORKERS=2` runs the same code in the same shape. On macOS, two
mitigations, both already in the tree's vocabulary:

- `--spawn-workers` / `M0_SPAWN_WORKERS`, which `exec`s the worker and so
  leaves nothing inherited to fault — the documented answer to every other
  member of this family;
- `OS_ACTIVITY_MODE=disable` in the server's environment, measured above.

Linux is unaffected: there is no `libsystem_trace` there, and the
deployment target is a Linux container either way.
