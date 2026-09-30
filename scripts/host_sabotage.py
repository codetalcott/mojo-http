#!/usr/bin/env python3
"""Break each rule the Mojo host keeps, and insist its gate fails every time.

`blobs_sabotage.py`'s shape: each entry replaces one EXACT source block in
`packages/m0-http/m0_host/host.mojo`, runs its gate, and restores the
file. The gate is `smoke-host` for what the wire shows,
`smoke-fragment-notes` for `ViewsApp` (the host's own app does not use
it), `test_host.mojo` for what only a thread-level test can see precisely
(a producer that catches up still publishes), `test_prefork.mojo` for
the pre-fork pieces both hosts share (`m0_http.prefork`; a src edit the
apps would only see after a `.mojoc` rebuild, which a test run of `src.*`
does not need), `test_cmdline.mojo` for the command-line reader both hosts
share (`m0_http.cmdline`, the same arrangement), or `test_respawn.mojo` for
the supervisor's part of the host's contract (a refusal ending the
siblings, in `multiworker.mojo`).
The fork is resolved from source by the smokes, and the unit gates
compile `src.*` directly, so nothing needs rebuilding -- with one
exception: a rule against `src/` gated on a SMOKE would need `build-http`
first, and none is written that way (`views.mojo`'s placement rule is
gated on `test_views.mojo`, a unit gate, for that reason). An anchor that
does not match exactly once is NOT APPLICABLE, a failure -- re-point it
with the line -- and a sabotage that does not compile is a miss, never a
catch: `sabotage_lib.py` owns everything around the table, the restore on
SIGINT or SIGTERM among it. A rule that
takes edits in MORE THAN ONE FILE names a tuple of paths beside its tuples
of anchors: the producer's stop has two writers since the pool lane (the
loop's stamp in `loop/shutdown.mojo` and the join's fallback in `host.mojo`),
and removing one alone is not "never told to stop".

Not here, and why: the handler built BEFORE the fork, and the pages and the
bus created AFTER it, are not one-line edits in `serve` -- each needs the
order of several statements changed, and a harness that moves blocks
around would be testing itself. The smoke's two-worker phases are what
would fail (a single shared handler cannot hold a stream in two
processes; a post-fork bus reaches no sibling).

Nor the keep-alive of the pool after the joins (`_ = pool.capacity` at
the end of `serve`): removed, a straggler thread the join gave up on
writes its completion into a freed `OffloadPool`, a use-after-free with
no symptom on the wire in the microseconds before `_exit`. Found by
review; recorded here because a gate that cannot fail is not evidence.

Nor the `_exit` after an abandoned producer. Removed, the smoke still
passes: a forked worker leaves through `exit_worker` anyway, and a single
process returning from `main` with the producer asleep inside its step
exits 0 in the same time (measured). The `_exit` stays so that teardown
never runs under a thread that is mid-step, but nothing on the wire can
tell, so it is not claimed as a guarded rule.

    uv run poe sabotage-host
    uv run poe sabotage-host --only "tick-owner"   one rule, by label substring
    uv run poe sabotage-host --only unit           the thread rules alone
    uv run poe sabotage-host --only respawn        the supervisor's rule
    uv run poe sabotage-host --only views          the placement rule
    uv run poe sabotage-host --only threads        the loops-on-threads rules (SPEC E27-E29)
    uv run poe sabotage-host --only doctor         the command line on the wire (SPEC E30, E31)
    uv run poe sabotage-host --only flags          the parser's rules
    uv run poe sabotage-host --only cmdline        the reader m0serve shares
    uv run poe sabotage-host --only parallel       the refusal of prefork beside
                                                   MAX's parallel runtime (SPEC E32;
                                                   needs `uv sync --group max`)
    uv run poe sabotage-host --skip parallel       every rule but one GATE's

`--only` and `--skip` take a gate's name, which selects that gate's rules,
or else part of a label.

On macOS the whole run cannot share one venv: a build beside `max-core` links
the parallel runtime into every binary (ROADMAP Known issues), so E32 refuses
the prefork baselines there with 78, the doctor's first. Run `--skip parallel`
in the default venv, then `--only parallel` under `uv run --group max`. On
Linux a build links the runtime only where the source names it, and the one
`uv run --group max poe sabotage-host` holds whole.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from sabotage_lib import POE, Command, MojoRun, rule, run

SMOKE = "smoke"
NOTES = "notes"
UNIT = "unit"
PREFORK = "prefork"
RESPAWN = "respawn"
VIEWS = "views"
THREADS = "threads"
DOCTOR = "doctor"
FLAGS = "flags"
CMDLINE = "cmdline"
PARALLEL = "parallel"

HOST = Path("packages/m0-http/m0_host/host.mojo")
LOOP_SHUTDOWN = Path("packages/m0-http/lightbug_http/loop/shutdown.mojo")
VIEWS_SRC = Path("packages/m0-http/src/views.mojo")
HOST_CHECK = Path("apps/host_check/server.mojo")
FLAGS_SRC = Path("packages/m0-http/m0_host/flags.mojo")
CMDLINE_SRC = Path("packages/m0-http/src/cmdline.mojo")
PREFORK_SRC = Path("packages/m0-http/src/prefork.mojo")
ACCEPT_SHARE_SRC = Path("packages/m0-http/lightbug_http/accept_share.mojo")
MULTIWORKER_SRC = Path("packages/m0-http/src/multiworker.mojo")

# (label, gate, path, old, new); `old` and `new` may be tuples of the same
# length for a rule that takes more than one edit to break, and `path` a
# tuple of the same length when those edits are in different files.
SABOTAGES = [
    (
        "the publisher skips worker 0's channel",
        SMOKE,
        HOST,
        "publish_to_channels(self._fds, -1, url, event_id, frame)",
        "publish_to_channels(self._fds, 0, url, event_id, frame)",
    ),
    (
        "the producer is handed worker 0's channel alone",
        SMOKE,
        HOST,
        "    var out = Publisher(ctx.bus.write_fds.copy(), ctx.id_addr)\n",
        "    var out = Publisher([ctx.bus.write_fds[0]], ctx.id_addr)\n",
    ),
    (
        "the bus is drained only above one worker",
        SMOKE,
        HOST,
        "        bus_read_fd=bus.read_fd(worker),\n",
        "        bus_read_fd=bus.read_fd(worker) if forked else -1,\n",
    ),
    (
        "a producer in every worker (the tick-owner rule)",
        SMOKE,
        HOST,
        "    if ctx.tick_owner() and P.wanted(ctx):\n",
        "    if P.wanted(ctx):\n",
    ),
    (
        "accept sharing is never bound",
        SMOKE,
        HOST,
        "    bind_accept_share(share, worker, host_page.addr(0))\n",
        "",
    ),
    (
        "a worker the supervisor reaps is never marked gone",
        SMOKE,
        HOST,
        "        supervisor.share_accepts(share, shared_id_addr())\n",
        "",
    ),
    (
        "signals armed before the fork",
        SMOKE,
        HOST,
        (
            "    var worker = 0\n    var forked = workers > 1\n    if forked:\n",
            "    bind_accept_share(share, worker, host_page.addr(0))\n"
            "    var shutdown_fd = install_shutdown_signals()\n",
        ),
        (
            "    var shutdown_fd = install_shutdown_signals()\n"
            "    var worker = 0\n    var forked = workers > 1\n    if forked:\n",
            "    bind_accept_share(share, worker, host_page.addr(0))\n",
        ),
    ),
    (
        "a forked worker returns from main",
        SMOKE,
        HOST,
        "    if forked:\n        exit_worker()\n",
        "",
    ),
    (
        "the producer is never told to stop",
        SMOKE,
        (LOOP_SHUTDOWN, HOST),
        (
            "    if st.stop_addr != 0:\n"
            "        atomic_at(st.stop_addr)[].store(Int64(perf_counter_ns()))\n",
            "            block.set(BLK_STOP, now)\n",
        ),
        ("", ""),
    ),
    (
        "the join has no bound",
        SMOKE,
        HOST,
        "        self.stragglers = self._set.join_within(left)\n",
        "        self._set.join_all()\n        self.stragglers = 0\n",
    ),
    # --- the pool lane and the overlapping bounds (SPEC E26) -------------------
    (
        "M0_BLOCKING_THREADS is served on the loop",
        SMOKE,
        HOST,
        "    return config.blocking_threads > 0\n",
        "    return False\n",
    ),
    (
        "the loop is never told where the stop word is",
        SMOKE,
        HOST,
        "        stop_addr=producer.stop_addr(),\n",
        "        stop_addr=0,\n",
    ),
    (
        "the producer's join counts from the loop's return, not the drain's start",
        SMOKE,
        HOST,
        "        var left = began + timeout_ns - now\n",
        "        var left = timeout_ns\n",
    ),
    (
        "a pool thread's raising make is served one thread short",
        SMOKE,
        HOST,
        "    var short = threads.wait_ready(POOL_READY_TIMEOUT_NS)\n"
        "    if short > 0:\n",
        "    var short = 0\n"
        "    _ = threads.wait_ready(POOL_READY_TIMEOUT_NS)\n"
        "    if short > 0:\n",
    ),
    (
        "a pool thread's handler is built as the loop's own",
        SMOKE,
        HOST,
        "        mine.thread = ctx.index\n",
        "",
    ),
    (
        "the gate app answers its health path on a pool thread, not the loop",
        SMOKE,
        HOST_CHECK,
        "        if req.uri.path == \"/health\":\n"
        "            return OK('{\"status\":\"ok\"}', \"application/json\")\n"
        "        if req.uri.path == STREAM:\n",
        "        if req.uri.path == STREAM:\n",
    ),
    (
        "an on-loop route is answered without its state",
        VIEWS,
        VIEWS_SRC,
        "            if kind == LOOP_READ:\n"
        "                return self._reads[slot](req, m.params, state)\n",
        "            if kind == LOOP_READ:\n                return None\n",
    ),
    (
        "a producer's sleep is not sliced",
        SMOKE,
        HOST,
        "            if left > SLEEP_SLICE_NS:\n                left = SLEEP_SLICE_NS\n",
        "",
    ),
    (
        "the status slot is written first",
        SMOKE,
        HOST,
        "    var status = STATUS_RAISED\n    try:\n        _producer_run[P](block)\n",
        "    block.set(BLK_STATUS, STATUS_OK)\n    var status = STATUS_RAISED\n    try:\n        _producer_run[P](block)\n",
    ),
    (
        "a configuration the host does not serve is served",
        SMOKE,
        HOST,
        "    if refusal:\n",
        "    if False:\n",
    ),
    (
        "the host never asks how many workers the app serves",
        SMOKE,
        HOST,
        "    var refusal = host_refusal(config, H.max_workers(), H.max_threads())\n",
        "    var refusal = host_refusal(config)\n",
    ),
    (
        "ViewsApp drops its state's worker limit",
        NOTES,
        HOST,
        "        return Self.S.max_workers()\n",
        "        return 0\n",
    ),
    (
        "the refusal comes after the bind",
        SMOKE,
        HOST,
        "    var refusal = host_refusal(config, H.max_workers(), H.max_threads())\n",
        "    var early_listener = ListenConfig().listen(config.address())\n"
        "    var refusal = host_refusal(config, H.max_workers(), H.max_threads())\n",
    ),
    # --- round 4: the id space and a raising make (SPEC E25) -------------------
    (
        "the shared id word is created after the fork, one per worker",
        SMOKE,
        HOST,
        (
            "    var host_page = prefork_page(workers)\n",
            "    bind_accept_share(share, worker, host_page.addr(0))\n",
        ),
        (
            "",
            "    var host_page = prefork_page(workers)\n"
            "    bind_accept_share(share, worker, host_page.addr(0))\n",
        ),
    ),
    (
        "next_id never advances the shared word",
        UNIT,
        HOST,
        "        return shared_fetch_add(self._id_addr, 1) + 1\n",
        "        return shared_fetch_add(self._id_addr, 0) + 1\n",
    ),
    (
        "a raising handler make propagates instead of refusing",
        SMOKE,
        HOST,
        "        process_exit(EX_CONFIG)\n        raise e  # never reached: the process has left\n",
        "        raise e\n",
    ),
    (
        "a raising producer make exits 1, a crash the supervisor respawns",
        SMOKE,
        HOST,
        "            process_exit(EX_CONFIG)\n\n    # The pool lane (docstring, 9a).",
        "            process_exit(1)\n\n    # The pool lane (docstring, 9a).",
    ),
    (
        "start swallows the producer make's error and spawns nothing",
        UNIT,
        HOST,
        "        var producer = P.make(ctx)\n        var built = unsafe_alloc[P](count=1)\n",
        "        var producer: P\n        try:\n            producer = P.make(ctx)\n"
        "        except:\n            return\n        var built = unsafe_alloc[P](count=1)\n",
    ),
    (
        "one worker's refusal leaves its siblings serving",
        RESPAWN,
        MULTIWORKER_SRC,
        "                        self._kill_all(SIGTERM)\n                        self._reap_the_rest()\n",
        "                        self._reap_the_rest()\n",
    ),
    # --- a stop that reaches a worker before it arms (S1) ----------------------
    # The first worker reaped died of the forwarded SIGTERM before it armed;
    # the rest used to be reaped blind, so a sibling failing its drain was
    # unseen and the supervisor exited 0 against D10.
    (
        "after an unarmed worker's death the rest are reaped blind",
        RESPAWN,
        MULTIWORKER_SRC,
        "                    self._kill_all(sig)\n                    self._reap_the_rest()\n",
        "                    self._kill_all(sig)\n"
        "                    while self._alive_count() > 0:\n"
        "                        self._remove_pid(waitpid_blocking(-1)[0])\n",
    ),
    (
        "the polling supervisor reaps the rest blind after an unarmed death",
        RESPAWN,
        MULTIWORKER_SRC,
        "                self._kill_all(sig)\n                self._reap_the_rest()\n",
        "                self._kill_all(sig)\n"
        "                while self._alive_count() > 0:\n"
        "                    self._remove_pid(waitpid_blocking(-1)[0])\n",
    ),
    (
        "a worker killed by the stop before it armed is judged a failure",
        RESPAWN,
        MULTIWORKER_SRC,
        '                    " its handler: a stop, not a failure".format(child_pid, sig)\n'
        "                )\n                return\n",
        '                    " its handler: a stop, not a failure".format(child_pid, sig)\n'
        "                )\n                self._failed_stopping = True\n                return\n",
    ),
    (
        "a sibling's non-zero exit while stopping is not a failure",
        RESPAWN,
        MULTIWORKER_SRC,
        '                " a failed drain".format(child_pid, code)\n'
        "            )\n            self._failed_stopping = True\n",
        '                " a failed drain".format(child_pid, code)\n            )\n',
    ),
    (
        "a sibling killed by another signal while stopping is not a failure",
        RESPAWN,
        MULTIWORKER_SRC,
        '                " a failed drain".format(child_pid, sig)\n'
        "            )\n            self._failed_stopping = True\n",
        '                " a failed drain".format(child_pid, sig)\n            )\n',
    ),
    # --- loops on threads (SPEC E27-E29), against smoke-host-threads ----------
    (
        "only loop 0 drains its bus channel",
        THREADS,
        HOST,
        "        bus_read_fd=block.get(BLK_BUS_FD),\n",
        "        bus_read_fd=block.get(BLK_BUS_FD) if index == 0 else -1,\n",
    ),
    (
        "the stop reaches loop 0 alone",
        THREADS,
        HOST,
        "        block.set(BLK_SHUTDOWN_FD, fanout.read_fd(i))\n",
        "        block.set(BLK_SHUTDOWN_FD, fanout.read_fd(i) if i == 0 else -1)\n",
    ),
    (
        "every loop's handler is built as loop 0",
        THREADS,
        HOST,
        "    ctx.worker = index\n",
        "",
    ),
    (
        "a loop serves before every loop's handler is built",
        THREADS,
        HOST,
        "    while block.get(BLK_LOOP_GO) == 0:\n        sleep(0.001)\n",
        "",
    ),
    (
        "more loops than the app serves are not refused",
        THREADS,
        HOST,
        "    if max_threads > 0 and config.threads > max_threads:\n",
        "    if False:\n",
    ),
    (
        "max_threads does not default to max_workers",
        THREADS,
        HOST,
        "        plain memory every loop sees, or a database) overrides this.\n"
        '        """\n        return Self.max_workers()\n',
        "        plain memory every loop sees, or a database) overrides this.\n"
        '        """\n        return 0\n',
    ),
    (
        "workers and threads together are served",
        THREADS,
        HOST,
        "    if conflict:\n        out.append(HostCheck(\n",
        "    if False:\n        out.append(HostCheck(\n",
    ),
    (
        "ViewsApp drops its state's loop limit",
        NOTES,
        HOST,
        "        return Self.S.max_threads()\n",
        "        return 0\n",
    ),
    # --- the thread's own rules, against test_host.mojo -----------------------
    (
        "an overrun is caught up",
        UNIT,
        HOST,
        "            next_ns = now\n            continue\n",
        "            continue\n",
    ),
    (
        "a raising step reports success",
        UNIT,
        HOST,
        "    except e:\n        print(\"host: the producer raised",
        "    except e:\n        status = STATUS_OK\n        print(\"host: the producer raised",
    ),
    (
        "more workers than the app serves are not refused",
        UNIT,
        HOST,
        "    if max_workers > 0 and config.workers > max_workers:\n",
        "    if False:\n",
    ),
    (
        "the publisher does not count a refusal",
        UNIT,
        HOST,
        "            self.refused += 1\n",
        "",
    ),
    # --- the pre-fork pieces both hosts share, against test_prefork.mojo -----
    (
        "a spawned worker makes a new page instead of mapping its parent's",
        PREFORK,
        PREFORK_SRC,
        "    if spawned_worker_index() >= 0:\n        var fds = int_list_env(\"M0_SHARED_ID_FD\")\n",
        "    if False:\n        var fds = int_list_env(\"M0_SHARED_ID_FD\")\n",
    ),
    (
        "the adopted page's address is not re-exported",
        PREFORK,
        PREFORK_SRC,
        "        var mapped = SharedAtomics(from_fd=fds[0], count=slots)\n"
        "        _ = setenv(\"M0_SHARED_ID_ADDR\", String(mapped.addr(0)), True)\n",
        "        var mapped = SharedAtomics(from_fd=fds[0], count=slots)\n",
    ),
    (
        "the page carries no magic word",
        PREFORK,
        PREFORK_SRC,
        "    page.store(SHARED_PAGE_MAGIC_SLOT, SHARED_PAGE_MAGIC)\n",
        "",
    ),
    (
        "the bus's send ends are not exported",
        PREFORK,
        PREFORK_SRC,
        "    _ = setenv(\"M0_BUS_WRITE_FDS\", _csv(bus.write_fds), True)\n",
        "",
    ),
    (
        "a spawned worker makes its own accept-share channels",
        PREFORK,
        PREFORK_SRC,
        "    if spawned_worker_index() >= 0:\n        return AcceptShare(\n",
        "    if False:\n        return AcceptShare(\n",
    ),
    (
        "M0_ACCEPT_SHARE=0 is ignored",
        PREFORK,
        ACCEPT_SHARE_SRC,
        "    return workers > 1 and getenv(\"M0_ACCEPT_SHARE\", \"\") != \"0\"\n",
        "    return workers > 1\n",
    ),
    # --- The command line and `--doctor` (SPEC E30, E31) ---------------------
    (
        "the doctor ignores what the application declares",
        DOCTOR,
        HOST,
        "    var checks = host_checks(\n"
        "        config, H.max_workers(), H.max_threads(), parallel_runtime\n"
        "    )\n",
        "    var checks = host_checks(config, parallel_runtime=parallel_runtime)\n",
    ),
    (
        "the doctor always exits 0",
        DOCTOR,
        HOST,
        "        process_exit(report.exit_code())\n",
        "        process_exit(0)\n",
    ),
    (
        "--doctor is read and the server starts anyway",
        DOCTOR,
        HOST,
        "    if flags.doctor:\n",
        "    if False:\n",
    ),
    (
        "the command line is read and the environment is served",
        DOCTOR,
        HOST,
        "    var config = flags.config.copy()\n",
        "    var config = seed.copy()\n",
    ),
    (
        "a given flag never reaches the ServerConfig the loop reads",
        DOCTOR,
        HOST,
        "    flags.apply_to(server_config)\n",
        "",
    ),
    (
        "the server refuses by its LAST failed check, the doctor by its first",
        DOCTOR,
        HOST,
        "    for i in range(len(checks)):\n        if not checks[i].ok:\n            return String(",
        "    for i in reversed(range(len(checks))):\n        if not checks[i].ok:\n            return String(",
    ),
    (
        "the gate app's banner is printed from the environment alone",
        DOCTOR,
        HOST_CHECK,
        "    var config = host_config()\n",
        "    var config = AppConfig()\n",
    ),
    (
        "an unknown flag is ignored",
        CMDLINE,
        CMDLINE_SRC,
        '        raise Error("unknown option " + name)\n',
        "        pass\n",
    ),
    (
        "a flag does not mark its count as chosen",
        FLAGS,
        FLAGS_SRC,
        "        config.workers_set = True\n",
        "",
    ),
    (
        "a moved port leaves the base URL naming the old one",
        FLAGS,
        FLAGS_SRC,
        '            config.base_url = "http://localhost:" + String(port)\n',
        "            pass\n",
    ),
    (
        "a flag that was not given overwrites tuning the application set",
        FLAGS,
        FLAGS_SRC,
        '        if self.was_given("--app-tick-ms"):\n',
        "        if True:\n",
    ),
    (
        "--threads 0 is a usage error for the flag and a refusal for the variable",
        FLAGS,
        FLAGS_SRC,
        '        config.threads = parse_int(value, "--threads")\n',
        '        config.threads = parse_int(value, "--threads")\n        if config.threads < 1:\n            raise Error("--threads must be at least 1")\n',
    ),
    (
        "prefork is refused when MAX's parallel runtime is linked",
        PARALLEL,
        HOST,
        "    if config.workers > 1 and linked:\n",
        "    if False and config.workers > 1 and linked:\n",
    ),
]


RULES = [rule(label, path, old, new, gate=gate)
         for label, gate, path, old, new in SABOTAGES]


def why(out: str) -> str:
    """The line the gate failed on, for the report.

    The smoke's `fail` prints its message and then each log under a
    `=== name ===` header, so the message is the line before the first
    header; a unit run names its failing tests.
    """
    # A sabotage that does not compile is caught for the wrong reason. A
    # compiler diagnostic names its file, line and column; `mojo run`'s own
    # "error: execution exited with a non-zero result" is a failing test.
    errors = [
        ln.strip() for ln in out.splitlines()
        if re.search(r"\.mojo:\d+:\d+: error:", ln)
    ]
    if errors:
        return "COMPILE ERROR (wrong reason): " + errors[0][-120:]
    fails = [ln.strip() for ln in out.splitlines() if ln.strip().startswith("FAIL [")]
    if fails:
        return ", ".join(f.split("] ", 1)[-1] for f in fails)[:140]
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("=== ") and i > 0:
            return lines[i - 1].strip()[:140]
    return out.strip().splitlines()[-1][:140] if out.strip() else "(no output)"


def _smoke(task: str, timeout: float = 600) -> Command:
    """A `poe` smoke. It builds its app from source, so a sabotage that does
    not compile shows as the build's diagnostic: a miss, never a catch."""
    return Command([POE, task], passes=f"{task} OK", builds=True, timeout=timeout,
                   detail=why)


def _unit(test: str) -> MojoRun:
    return MojoRun(f"packages/m0-http/test/{test}")


GATES = {
    SMOKE: _smoke("smoke-host"),
    NOTES: _smoke("smoke-fragment-notes"),
    THREADS: _smoke("smoke-host-threads"),
    # `smoke-host-doctor` runs the app under each flag shape in turn.
    DOCTOR: _smoke("smoke-host-doctor", timeout=900),
    # SPEC E32. Needs MAX's Mojo packages in the venv (`uv sync --group
    # max`); without them the baseline fails at the build, which the report
    # shows as a baseline failure, never as a catch.
    PARALLEL: _smoke("smoke-parallel-runtime", timeout=900),
    UNIT: _unit("test_host.mojo"),
    PREFORK: _unit("test_prefork.mojo"),
    VIEWS: _unit("test_views.mojo"),
    RESPAWN: _unit("test_respawn.mojo"),
    # The shared reader's own test, compiled from `src/`: the host resolves
    # `m0_http.cmdline` through the `.mojoc`, so `test_host_flags.mojo`
    # would not see an edit there until `build-http` ran.
    CMDLINE: _unit("test_cmdline.mojo"),
    FLAGS: _unit("test_host_flags.mojo"),
}


def main(argv: list[str]) -> int:
    return run("sabotage-host", RULES, GATES, argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
