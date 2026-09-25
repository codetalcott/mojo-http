"""Where the kick count lives between runs: one row in SQLite.

`m0_sqlite` opens the system libsqlite3 at run time, so nothing links it
and `uv run m0 test` can open a database like any other test. Two rules
this file keeps, both the framework's:

- **A connection belongs to one thread, opened where that thread runs.**
  The producer opens this store on its own thread at its first step, never
  in `make`: `make` runs before the host forks, and a SQLite connection
  carried across `fork()` is the one thing SQLite's own documentation says
  never to do. A view that needed the database would open a connection of
  its own in its handler's `make`, which the host runs once per worker.
- **`open()` wants a real file.** It puts the database in WAL mode and
  raises on a target that cannot do that (`:memory:` among them), so the
  tests use `in_memory()` and the server a path -- `M0_DB`, else
  `__M0_APP__.db` in the working directory, which the image points at its
  data volume (deploy/Dockerfile).
"""

from std.os import getenv

from m0_sqlite import Connection, open, open_memory

comptime DB_ENV = "M0_DB"
comptime DB_DEFAULT = "__M0_APP__.db"


def db_path() -> String:
    """The file the server opens: `M0_DB`, else the default beside it."""
    return getenv(DB_ENV, DB_DEFAULT)


struct KickStore(Movable):
    """One counter, `kicks`, kept in a `counters` table."""

    var db: Connection

    def __init__(out self, var db: Connection) raises:
        db.execute(
            "CREATE TABLE IF NOT EXISTS counters ("
            "  name TEXT PRIMARY KEY,"
            "  value INTEGER NOT NULL)"
        )
        db.execute("INSERT OR IGNORE INTO counters (name, value) VALUES ('kicks', 0)")
        self.db = db^

    @staticmethod
    def open_file(path: String) raises -> Self:
        return KickStore(open(path))

    @staticmethod
    def in_memory() raises -> Self:
        return KickStore(open_memory())

    def kicks(self) raises -> Int:
        """Kicks ever posted, as last saved."""
        var q = self.db.prepare("SELECT value FROM counters WHERE name = 'kicks'")
        var n = 0
        if q.step():
            n = q.column_int(0)
        return n

    def save_kicks(self, n: Int) raises:
        var u = self.db.prepare("UPDATE counters SET value = ? WHERE name = 'kicks'")
        u.bind_int(1, n)
        _ = u.step()
