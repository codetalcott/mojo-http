"""A witness for a cache: whether any page of some tables was written.

The change clock (`Connection.data_version`) says THAT the file changed, for
every table at once. A stamp (`stamps.mojo`) says what a trigger saw, and a
trigger can be got past. The witness reads what SQLite itself wrote. In WAL
mode every committed page is a frame in `<db>-wal`, each frame's header names
its page, and the tables' own pages are known (`dbstat`). So a reader asked
"has `notes` changed since my last look?" can answer from the frames
committed since then, whatever program wrote them, and with no SQL when the
answer is no.

    var w = TableWitness(path, ["notes"])
    ...
    var now = reader.data_version()
    if not cache.current(now):          # the clock moved: look
        if w.look() == UNCHANGED:       # BEFORE the read transaction
            cache.clock = now           # the kept rendering stands
        else:
            reader.begin()
            var body = render(reader)   # CHANGED or UNKNOWN: render again
            reader.commit()
            _ = cache.fill(now, body^)
        w.settle()

`look` answers one of three:

- `UNCHANGED`: no frame committed since the last `settle` wrote a page of the
  tables, page 1, or a new log.
- `CHANGED`: such a frame wrote one of the tables' pages.
- `UNKNOWN`: the frames can't say. Then render again, as for `CHANGED`. The
  reason is `last_unknown()`. UNKNOWN is answered when:
  - page 1 was written, which is how a page changes hands: allocation, a
    free, growth or a schema change;
  - the log was reset after a checkpoint, so its salts changed;
  - a read came up short, or a frame's salts differ;
  - there is no `-shm` (a rollback journal, or `locking_mode=EXCLUSIVE`);
  - the wal-index version isn't the one this reads;
  - there is no `dbstat` to map the tables' pages;
  - a name is no table of the database, or a table with no pages of its own
    (a virtual table);
  - it is the first look.

UNKNOWN is never wrong, only slower, and every case above falls to it.

**The order is the whole contract.**
- `look` reads the wal-index header's `mxFrame` and keeps it as pending.
- The caller's read transaction, begun after `look`, holds at least what that
  header named. A transaction begun BEFORE `look` may not, so a caller
  never looks from inside one.
- `settle`, after the rendering, takes the pending position as seen.

So the witness never covers a frame the caller's rendering does not hold. A
`settle` that read a fresh position would cover commits made between the look
and the read, and the next look would miss them. `test_witness.mojo`
injects exactly that commit.

**What the wal-index is.**
- The `-shm` header's layout is SQLite's: walformat.html §2.1. It has two
  48-byte copies, read until they agree. Every field is native-endian except
  the salts, which are the WAL header's bytes as they are.
- The same page calls the wal-index "left to discretion of individual VFS
  implementations". So a header whose `iVersion` isn't 3007000, or whose
  copies never agree, is UNKNOWN: a different format slows the witness and
  never fools it.
- The frames are read from `-wal` itself: 24-byte headers, big-endian, the
  page number first.

**Its own connection.** The witness opens a read-only connection of its own
and keeps it for its life. That does two jobs:
- SQLite deletes `-wal` and `-shm` when the last connection closes. While the
  witness lives they are never deleted under it, so it never reads a file
  that is no longer the database's.
- It maps the tables' pages (`dbstat`) in a read transaction of its own,
  begun after the `look` that asked for the map, so the map holds at least
  what the look read. A page that changes hands after that writes page 1,
  which the next look answers UNKNOWN.

**A table is named as SQLite names it,** without regard to case: `"Notes"`
watches `notes`. A name no table answers to is UNKNOWN at every look, with
the name in `last_unknown()`, rather than a page map with nothing in it,
which would answer UNCHANGED for every write.

**What a rendering carries besides the tables' rows is the caller's.** A
kept rendering is the one made at the last CHANGED or UNKNOWN. A page that
embeds something the witness doesn't watch, such as the stamp head, which
counts every watched table's writes, keeps its old value. Watch every table
whose writes that value counts, or render it apart.

**The `-shm` descriptor is never closed.** A POSIX `close()` of any
descriptor of a file drops every lock this process holds on that file,
SQLite's own included (howtocorrupt.html §2.2). SQLite takes its WAL locks,
the readers' marks among them, on `-shm`, so closing the witness's copy
would let another process truncate the log under a reader that is still
reading. Measured: on Homebrew's SQLite a witness destroyed beside an open
read transaction let another process's `wal_checkpoint(TRUNCATE)` complete,
`(0, 0, 0)`, where with the witness kept it answered busy. Apple's own
build doesn't show it. So `-shm`'s handle is moved into an allocation that
is never freed, and its descriptor stays open for the life of the process:
one per witness. Make one per loop, not one per request. `-wal` takes no
lock and is closed as usual.

**Limits:**
- WAL mode, on one host: it reads the two files.
- Frequent checkpoints reset the log, and each reset is one UNKNOWN.

docs/notes/a-witness-for-a-table.md has the argument and the measurements.
"""

from std.collections import List
from std.collections.span import Span
from std.ffi import c_int, external_call
from std.io.file import FileHandle
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from .conn import Connection, open_readonly


comptime UNCHANGED: Int = 0
"""No frame since the last `settle` wrote the tables, page 1 or a new log."""
comptime CHANGED: Int = 1
"""A frame since the last `settle` wrote one of the tables' pages."""
comptime UNKNOWN: Int = 2
"""The frames can't say; render again. `last_unknown()` names why."""

comptime WAL_INDEX_VERSION: Int = 3007000
"""The wal-index format this reads (walformat.html: "Always 3007000")."""

comptime _HEADER_BYTES = 96
comptime _FRAME_HEADER_BYTES = 24
comptime _WAL_HEADER_BYTES = 32

comptime _OpaqueMut = Pointer[NoneType, MutUntrackedOrigin]


struct WalPosition(ImplicitlyCopyable, Movable):
    """Where the committed log stands, from one read of the wal-index header."""

    var state: Int
    """0 usable; 1 the two copies disagree (a write in progress: read again);
    2 not a header this reads (short, not initialized, another version)."""
    var salt: UInt64
    """The WAL header's two salts, as the 8 bytes they are: compared, never
    interpreted."""
    var max_frame: Int
    var page_size: Int

    def __init__(out self, state: Int, salt: UInt64, max_frame: Int, page_size: Int):
        self.state = state
        self.salt = salt
        self.max_frame = max_frame
        self.page_size = page_size

    @staticmethod
    def unusable() -> Self:
        return Self(2, 0, 0, 0)


@always_inline
def _le(b: Span[UInt8, _], at: Int, n: Int) -> Int:
    var v = 0
    for i in range(n):
        v |= Int(b[at + i]) << (8 * i)
    return v


def parse_wal_index_header(header: Span[UInt8, _]) -> WalPosition:
    """The position in a wal-index header's first 96 bytes.

    The fields are native-endian, which is little on every platform this
    runs on. A big-endian host reads `iVersion` byte-swapped, and the
    header is then unusable rather than misread. The salts are the WAL
    header's bytes."""
    if len(header) < _HEADER_BYTES:
        return WalPosition.unusable()
    for i in range(48):
        if header[i] != header[48 + i]:
            return WalPosition(1, 0, 0, 0)
    if _le(header, 0, 4) != WAL_INDEX_VERSION or header[12] == 0:
        return WalPosition.unusable()
    var size = _le(header, 14, 2)
    return WalPosition(0, UInt64(_le(header, 32, 8)), _le(header, 16, 4), 65536 if size == 1 else size)


def frame_page(frame_header: Span[UInt8, _], salt: UInt64) -> Int:
    """The page a frame wrote, or -1 when its salts are not `salt`: a frame of
    another generation of the log, never one to read."""
    if len(frame_header) < 16 or UInt64(_le(frame_header, 8, 8)) != salt:
        return -1
    return (
        (Int(frame_header[0]) << 24)
        | (Int(frame_header[1]) << 16)
        | (Int(frame_header[2]) << 8)
        | Int(frame_header[3])
    )


@always_inline
def _pread(fd: Int, mut buf: List[UInt8], n: Int, offset: Int) -> Int:
    return external_call["pread", Int, c_int, _OpaqueMut, Int, Int](
        c_int(fd),
        buf.unsafe_ptr().unsafe_bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin](),
        n,
        offset,
    )


struct TableWitness(Movable):
    """Whether any page of `tables` was written since the last `settle`.

    Not `Copyable`: it holds a connection and two open files. See the module
    docstring for the contract: `look` before the read transaction, `settle`
    after the rendering."""

    var _db: String
    var _tables: List[String]
    var _conn: Connection
    var _shm: Int
    """`-shm`'s descriptor, -1 until opened. Its handle lives in an allocation
    never freed, so it is never closed: see the module docstring."""
    var _wal: FileHandle
    var _open: Bool
    var _pages: List[Bool]
    """By page number: whether it is one of the tables' pages."""
    var _mapped: Bool
    var _covered: WalPosition
    var _pending: WalPosition
    var _pending_answer: Int
    var _header: List[UInt8]
    var _frame: List[UInt8]
    var _why: String
    var _map_why: String
    """Why the last map failed, kept for every look until one succeeds."""
    var looks: Int
    """How many times `look` ran, and how each answered: what a `/stats` reads."""
    var unchanged: Int
    var changed: Int
    var unknown: Int
    var remaps: Int
    var frames_read: Int

    def __init__(out self, db_path: String, var tables: List[String]) raises:
        """A witness for `tables` of the database at `db_path`, which must
        exist. Opens the witness's own read-only connection and reads once,
        which attaches it to the log; the first `look` answers UNKNOWN."""
        self._db = db_path
        self._tables = tables^
        self._conn = open_readonly(db_path)
        _ = self._conn.data_version()
        _ = self._conn.query_scalar("SELECT count(*) FROM sqlite_schema")
        self._shm = -1
        self._wal = FileHandle()
        self._open = False
        self._pages = List[Bool]()
        self._mapped = False
        self._covered = WalPosition.unusable()
        self._pending = WalPosition.unusable()
        self._pending_answer = UNKNOWN
        self._header = List[UInt8](length=_HEADER_BYTES, fill=0)
        self._frame = List[UInt8](length=_FRAME_HEADER_BYTES, fill=0)
        self._why = String("no look yet")
        self._map_why = String("first look")
        self.looks = 0
        self.unchanged = 0
        self.changed = 0
        self.unknown = 0
        self.remaps = 0
        self.frames_read = 0

    def last_unknown(self) -> String:
        """Why the last UNKNOWN was answered."""
        return self._why

    def _files(mut self) -> Bool:
        """The two files, opened at the first look that finds them, and tried
        again at every look until then. While the witness's connection is
        open they are not deleted."""
        if self._open:
            return True
        if self._shm < 0:
            try:
                var handle = FileHandle(self._db + "-shm", "r")
                var kept = unsafe_alloc[FileHandle](count=1)
                kept.unsafe_write(handle^)
                self._shm = kept[].handle
            except:
                self._why = String("no -shm (not WAL mode, or locking_mode=EXCLUSIVE)")
                return False
        try:
            self._wal = FileHandle(self._db + "-wal", "r")
        except e:
            self._why = String("no -shm or -wal (not WAL mode, or locking_mode=EXCLUSIVE): ", e)
            return False
        self._open = True
        return True

    def _position(mut self) -> WalPosition:
        for _ in range(1000):
            if _pread(self._shm, self._header, _HEADER_BYTES, 0) < _HEADER_BYTES:
                self._why = String("-shm shorter than a wal-index header")
                return WalPosition.unusable()
            var p = parse_wal_index_header(Span(self._header))
            if p.state != 1:
                if p.state == 2:
                    self._why = String("not a wal-index header this reads (iVersion ", _le(Span(self._header), 0, 4), ")")
                return p
        self._why = String("the wal-index header's two copies never agreed")
        return WalPosition.unusable()

    def look(mut self) -> Int:
        """Whether the tables can have changed since the last `settle`.

        Call it BEFORE the read transaction a rendering uses; then `settle`
        inside that transaction, or with none when this answered UNCHANGED
        and the kept rendering stands. Reads the wal-index header and the
        headers of the frames committed since; no SQL."""
        self.looks += 1
        var answer = self._look()
        self._pending_answer = answer
        if answer == UNCHANGED:
            self.unchanged += 1
        elif answer == CHANGED:
            self.changed += 1
        else:
            self.unknown += 1
        return answer

    def _look(mut self) -> Int:
        if not self._files():
            self._pending = WalPosition.unusable()
            return UNKNOWN
        var now = self._position()
        self._pending = now
        if now.state != 0:
            return UNKNOWN
        if not self._mapped:
            self._why = self._map_why
            return UNKNOWN
        if self._covered.state != 0:
            self._why = String("nothing covered yet")
            return UNKNOWN
        if now.salt != self._covered.salt or now.max_frame < self._covered.max_frame:
            self._why = String("the log was reset (a checkpoint finished and a writer restarted it)")
            return UNKNOWN
        var hit = False
        for i in range(self._covered.max_frame + 1, now.max_frame + 1):
            var at = _WAL_HEADER_BYTES + (i - 1) * (_FRAME_HEADER_BYTES + now.page_size)
            if _pread(self._wal.handle, self._frame, _FRAME_HEADER_BYTES, at) < _FRAME_HEADER_BYTES:
                self._why = String("a frame read came up short")
                return UNKNOWN
            self.frames_read += 1
            var page = frame_page(Span(self._frame), now.salt)
            if page < 0:
                self._why = String("a frame of another generation of the log")
                return UNKNOWN
            if page == 1:
                self._why = String("page 1 written: pages may have changed hands")
                return UNKNOWN
            if page < len(self._pages) and self._pages[page]:
                hit = True
        return CHANGED if hit else UNCHANGED

    def settle(mut self) raises:
        """Take what the last `look` read as seen.

        Call it after the rendering that followed the look, or after keeping
        the rendering when the look answered UNCHANGED. After an UNKNOWN it
        maps the tables' pages again, in a read transaction of the witness's
        own (`dbstat`): no SQL otherwise."""
        if self._pending.state == 0 and (self._pending_answer == UNKNOWN or not self._mapped):
            self._remap()
        self._covered = self._pending

    def _remap(mut self) raises:
        """Map the tables' pages. Each name is resolved as SQLite resolves it
        (`sqlite_schema`, without regard to case). `dbstat` matches names
        exactly, so a name left as given could match nothing and leave a map
        with no pages in it. A name with no table, or a table with no pages
        (a virtual table), leaves the witness unmapped, and so UNKNOWN."""
        for i in range(len(self._pages)):
            self._pages[i] = False
        self._mapped = False
        self._conn.begin()
        try:
            var named = self._conn.prepare(
                "SELECT name FROM sqlite_schema WHERE type = 'table' AND name = ?1 COLLATE NOCASE"
            )
            var pages = self._conn.prepare("SELECT pageno FROM dbstat WHERE name = ?1")
            for t in range(len(self._tables)):
                named.reset()
                named.bind_text(1, self._tables[t])
                if not named.step():
                    self._map_why = String("no table named ", self._tables[t], " in the database")
                    named.reset()
                    self._conn.rollback()
                    return
                var stored = named.column_text(0)
                named.reset()
                pages.reset()
                pages.bind_text(1, stored)
                var found = 0
                while pages.step():
                    var page = pages.column_int(0)
                    if page >= len(self._pages):
                        self._pages.resize(page + 1024, False)
                    self._pages[page] = True
                    found += 1
                pages.reset()
                if found == 0:
                    self._map_why = String("dbstat lists no pages of ", stored, " (a virtual table has none)")
                    self._conn.rollback()
                    return
            self._conn.commit()
        except e:
            self._conn.rollback()
            self._map_why = String("no dbstat to map the tables' pages: ", e)
            return
        self._mapped = True
        self.remaps += 1
