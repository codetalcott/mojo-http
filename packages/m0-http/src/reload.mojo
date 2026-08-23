"""`MtimeScanner` — the change detector behind a reloading supervisor.

    var scanner = MtimeScanner(dirs, ".py")
    _ = scanner.changed()          # first pass: records, never reports
    ...
    if scanner.changed():          # a later pass: something moved
        ...

One number per pass: the newest modification time under any watched
directory, plus a count of the files that produced it. Both matter — an
mtime alone cannot see a deletion, because removing the newest file leaves
the maximum in the past, and this compares against the *previous* pass
rather than against a high-water mark for exactly that reason.

**Suffix-filtered, and the caller names the suffix.** `m0-http` has no
opinion about what a source file is; `m0serve` passes `.py` because Python
is what its workers reload. Keeping the policy in the caller is what keeps
this module free of any notion of an interpreter — the same rule that keeps
libpython off every link line but `m0-wsgi`'s.

**Nothing here touches Python, which is the point.** This runs in the
supervising parent, a process that has forked without `exec` and must
therefore stay away from platform runtimes; `listdir` and `stat` are plain
libc. See `WorkerSupervisor` for the rule and `exit_worker` for what
happens to code that forgets it.

Deliberately not `inotify`/`FSEvents`: two platform implementations, a
descriptor budget, and a recursive-watch registration problem, in exchange
for latency nobody editing a file can perceive. A poll every ~300 ms costs
one `stat` per watched file and is the same choice uvicorn's `StatReload`
makes.
"""

from std.os import listdir, stat
from std.os.path import isdir


comptime MAX_SCAN_DEPTH = 12
"""How deep a recursive scan will go before it stops descending.

A guard against a symlink cycle, not a real limit: a source tree deeper
than this exists, but one that a reloader must watch does not.
"""

comptime MAX_SCAN_ENTRIES = 20000
"""How many files one pass will stat before it gives up descending.

A `--reload-dir` aimed at a home directory should degrade into a slow
reloader, not a process that never answers.
"""


struct ScanResult(ImplicitlyCopyable, Copyable, Movable):
    """What one pass saw: the newest mtime, and how many files it weighed."""

    var newest_ns: Int
    var files: Int

    def __init__(out self, newest_ns: Int = 0, files: Int = 0):
        self.newest_ns = newest_ns
        self.files = files

    def __eq__(self, other: Self) -> Bool:
        return self.newest_ns == other.newest_ns and self.files == other.files

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)


struct MtimeScanner(Movable):
    """Watches directories for a changed set of suffix-matching files."""

    var dirs: List[String]
    var suffix: String
    var _last: ScanResult
    var _primed: Bool

    def __init__(out self, var dirs: List[String], var suffix: String):
        self.dirs = dirs^
        self.suffix = suffix^
        self._last = ScanResult()
        self._primed = False

    def __init__(out self, *, deinit move: Self):
        self.dirs = move.dirs^
        self.suffix = move.suffix^
        self._last = move._last
        self._primed = move._primed

    def scan(self) -> ScanResult:
        """One pass over every watched directory. Never raises: see below.

        An unreadable directory contributes nothing rather than failing the
        pass. A reloader that died because a build tool deleted a directory
        mid-scan would be worse than one that notices the change a pass
        later, and the next pass sees the same tree the compiler will.
        """
        var acc = ScanResult()
        for i in range(len(self.dirs)):
            self._walk(self.dirs[i], 0, acc)
        return acc

    def _walk(self, path: String, depth: Int, mut acc: ScanResult):
        if depth > MAX_SCAN_DEPTH or acc.files >= MAX_SCAN_ENTRIES:
            return
        var names: List[String]
        try:
            names = listdir(path)
        except:
            return  # vanished, or not ours to read
        for i in range(len(names)):
            var name = String(names[i])
            # Skip the directories every source tree has and no edit lives
            # in. `__pycache__` matters most: it is written BY the very
            # import the reload triggers, so watching it would make every
            # reload cause the next one.
            if (
                name == "__pycache__"
                or name == ".git"
                or name == "node_modules"
                or name.startswith(".")
            ):
                continue
            var child = path + "/" + name
            if isdir(child):
                self._walk(child, depth + 1, acc)
                continue
            if not name.endswith(self.suffix):
                continue
            try:
                var st = stat(child)
                var ns = (
                    Int(st.st_mtimespec.tv_sec) * 1_000_000_000
                    + Int(st.st_mtimespec.tv_subsec)
                )
                if ns > acc.newest_ns:
                    acc.newest_ns = ns
                acc.files += 1
            except:
                continue  # raced with a delete

    def changed(mut self) -> Bool:
        """Whether this pass differs from the last. The first pass is False.

        The first call records the baseline and reports nothing — a
        supervisor that reloaded once at startup would be reporting only
        that it had started.
        """
        var now = self.scan()
        if not self._primed:
            self._last = now
            self._primed = True
            return False
        var moved = now != self._last
        self._last = now
        return moved

    def watching(self) -> Int:
        """How many files the last pass weighed; 0 before the first pass."""
        return self._last.files

    def describe(self) -> String:
        """The watched directories, comma-separated, for a startup line."""
        var text = String("")
        for i in range(len(self.dirs)):
            if i > 0:
                text += ", "
            text += self.dirs[i]
        return text^
