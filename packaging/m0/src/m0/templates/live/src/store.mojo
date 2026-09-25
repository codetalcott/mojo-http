"""Where the kick count lives between runs: one row in SQLite.

`m0_sqlite` opens the system libsqlite3 at run time, so nothing links it
and `uv run m0 test` can open a database like any other test. Three rules
this file keeps, all the framework's:

- **A connection belongs to one thread, opened where that thread runs.**
  `LiveHandler.make` opens this store, and the host runs `make` once per
  worker, per loop and per handler-pool thread -- always after it forks,
  never before: a SQLite connection carried across `fork()` is the one
  thing SQLite's own documentation says never to do.
- **A count that must survive a restart is written in the request that
  changes it.** The kick view adds to this table before it answers, so
  the 204 the client sees is a committed row. It used to be the producer
  writing the board's word back on its next step, and a kick posted just
  before SIGTERM was lost: the producer polls, and the poll never came.
- **`open()` wants a real file.** It puts the database in WAL mode and
  raises on a target that cannot do that (`:memory:` among them), so the
  tests use `in_memory()` and the server a path -- `M0_DB`, else
  `__M0_APP__.db` in the working directory, which the image points at its
  data volume (deploy/Dockerfile).

Two workers open one file. The schema is created inside an IMMEDIATE
transaction because `CREATE TABLE IF NOT EXISTS` reads first and upgrades
to a write, and SQLite answers that upgrade with "database is locked" at
once rather than through the busy handler; taking the write lock up front
waits instead (apps/datastar_todo found this at two workers).
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
        db.begin_immediate()
        db.execute(
            "CREATE TABLE IF NOT EXISTS counters ("
            "  name TEXT PRIMARY KEY,"
            "  value INTEGER NOT NULL)"
        )
        db.execute("INSERT OR IGNORE INTO counters (name, value) VALUES ('kicks', 0)")
        db.commit()
        self.db = db^

    @staticmethod
    def open_file(path: String) raises -> Self:
        return KickStore(open(path))

    @staticmethod
    def in_memory() raises -> Self:
        return KickStore(open_memory())

    def kicks(self) raises -> Int:
        """Kicks ever posted, as committed."""
        var q = self.db.prepare("SELECT value FROM counters WHERE name = 'kicks'")
        var n = 0
        if q.step():
            n = q.column_int(0)
        return n

    def add_kick(self) raises:
        """Count one kick, durably: the row is committed when this returns.
        An UPDATE in the database, not a read-add-write here, so two workers
        kicking at once both count."""
        var u = self.db.prepare("UPDATE counters SET value = value + 1 WHERE name = 'kicks'")
        _ = u.step()
