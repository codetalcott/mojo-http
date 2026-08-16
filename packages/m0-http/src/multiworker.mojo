"""Multi-worker fork supervisor with crash respawn and signal propagation.

Forks N child processes. Children return to the caller to run the
normal server startup path. The parent supervises: respawns crashed
children, propagates SIGTERM/SIGINT to all children.

Usage:
    var supervisor = WorkerSupervisor(num_workers)
    supervisor.fork_all()
    # Only children reach here — run normal server startup
"""

from std.time import perf_counter_ns
from lightbug_http.c.process import (
    fork, process_exit, getpid, waitpid_blocking,
    kill_process, was_signaled, term_signal, exit_code,
    SIGTERM, SIGINT,
)


# _try_respawn outcomes. A plain Bool cannot express the case that matters:
# after the respawn fork() there are *two* processes inside _try_respawn, and
# the child must unwind all the way out of fork_all while the parent keeps
# supervising.
comptime _RESPAWN_FAILED = 0
comptime _RESPAWN_PARENT = 1
comptime _RESPAWN_CHILD = 2


struct WorkerSupervisor:
    """Supervises forked worker processes with crash respawn."""
    var child_pids: List[Int]
    var num_workers: Int
    var max_respawns: Int
    var respawn_count: Int
    var rapid_crash_count: Int
    var last_fork_ns: Int

    def __init__(out self, num_workers: Int):
        self.child_pids = List[Int]()
        self.num_workers = num_workers
        self.max_respawns = num_workers * 10
        self.respawn_count = 0
        self.rapid_crash_count = 0
        self.last_fork_ns = 0

    def fork_all(mut self) raises:
        """Fork all workers. Children return. Parent enters supervise loop and exits.

        Every child — initial or respawned — returns from this call to run the
        caller's normal server startup path. The parent never returns: it
        supervises until all children are gone, then exits the process.
        """
        for i in range(self.num_workers):
            self.last_fork_ns = perf_counter_ns()
            var pid = fork()
            if pid == 0:
                # Child: print worker ID and return to caller
                print("[worker {}] pid={} starting".format(i, getpid()))
                return
            self.child_pids.append(pid)

        # Parent process: supervise children
        print("[parent] pid={} supervising {} workers".format(getpid(), self.num_workers))
        if self._supervise():
            # Respawned child: unwind to the caller's server startup path,
            # exactly as an initially-forked child does above.
            return
        process_exit(0)

    def _supervise(mut self) raises -> Bool:
        """Parent supervision loop: respawn crashes, propagate signals.

        Returns True only in a respawned child, which must return to
        `fork_all`'s caller rather than keep supervising. Returns False in the
        parent once supervision is over.
        """
        var remaining = self.num_workers
        while remaining > 0:
            var result = waitpid_blocking(-1)
            var child_pid = result[0]
            var status = result[1]

            # Remove from tracked list
            self._remove_pid(child_pid)

            if was_signaled(status):
                var sig = term_signal(status)
                print("[parent] worker pid={} killed by signal {}".format(child_pid, sig))
                if sig == SIGTERM or sig == SIGINT:
                    # Propagate to all remaining children and shut down
                    print("[parent] propagating signal {} to remaining workers".format(sig))
                    self._kill_all(sig)
                    remaining -= 1
                    # Wait for remaining children to exit
                    while remaining > 0:
                        _ = waitpid_blocking(-1)
                        remaining -= 1
                    return False
                # Other signal (e.g., SIGKILL) — treat as crash, try respawn
                var outcome = self._try_respawn()
                if outcome == _RESPAWN_CHILD:
                    return True
                if outcome == _RESPAWN_PARENT:
                    continue
                remaining -= 1
            else:
                var code = exit_code(status)
                if code != 0:
                    print("[parent] worker pid={} crashed (exit_code={})".format(child_pid, code))
                    var outcome = self._try_respawn()
                    if outcome == _RESPAWN_CHILD:
                        return True
                    if outcome == _RESPAWN_PARENT:
                        continue
                else:
                    print("[parent] worker pid={} exited cleanly".format(child_pid))
                remaining -= 1
        return False

    def _try_respawn(mut self) raises -> Int:
        """Attempt to respawn a worker.

        Returns `_RESPAWN_PARENT` in the parent on success, `_RESPAWN_CHILD` in
        the freshly forked child (which must unwind out to `fork_all`'s
        caller), and `_RESPAWN_FAILED` when the respawn budget is spent.
        """
        if self.respawn_count >= self.max_respawns:
            print("[parent] max respawns ({}) reached, not respawning".format(self.max_respawns))
            return _RESPAWN_FAILED

        # Rapid crash detection: if child died within 1 second of last fork
        var now = perf_counter_ns()
        var elapsed_ns = now - self.last_fork_ns
        if elapsed_ns < 1_000_000_000:  # 1 second
            self.rapid_crash_count += 1
            if self.rapid_crash_count >= 5:
                print("[parent] 5 rapid crashes detected, stopping respawn")
                return _RESPAWN_FAILED
        else:
            self.rapid_crash_count = 0

        self.respawn_count += 1
        self.last_fork_ns = perf_counter_ns()
        var new_pid = fork()
        if new_pid == 0:
            print("[worker respawn] pid={} starting".format(getpid()))
            return _RESPAWN_CHILD
        self.child_pids.append(new_pid)
        print("[parent] respawned worker as pid={}".format(new_pid))
        return _RESPAWN_PARENT

    def _remove_pid(mut self, pid: Int):
        """Remove a PID from the tracked list."""
        for i in range(len(self.child_pids)):
            if self.child_pids[i] == pid:
                # Swap with last and pop
                var last_idx = len(self.child_pids) - 1
                if i != last_idx:
                    self.child_pids[i] = self.child_pids[last_idx]
                _ = self.child_pids.pop()
                return

    def _kill_all(self, signal: Int):
        """Send a signal to all tracked child processes."""
        for i in range(len(self.child_pids)):
            _ = kill_process(self.child_pids[i], signal)
