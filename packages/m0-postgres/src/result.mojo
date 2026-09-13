"""Query results: a `PGresult` this package owns, read by row and column.

The shape here differs from `m0-sqlite`'s on purpose, because the two C
libraries differ. SQLite steps a cursor inside the process and a row is
valid until the next `step`. libpq hands back a COMPLETE result that owns
its own memory and needs no connection to read or free — so `Result` is a
value: it can outlive the `Connection` that produced it, be moved into a
renderer, and be read in any order.

It holds the entry points it calls BY VALUE (`ResultLib`), never by the
address of its connection's table. The address was what it held first, and
`var rows = db.query(...)` with no later mention of `db` then read a
destroyed connection's struct through a library that had been unloaded — a
segmentation fault on the first `rows.text(0, 0)`. `lib.mojo`'s third rule,
the pin, is what makes the copy sound.

`Movable` and not `Copyable`, the rule every handle type in this repo
follows: a copy would duplicate the `PGresult *` and the second destructor
would `PQclear` an already-cleared result.

**Text is the default and binary is opt-in per query.** libpq's result
format is one choice for the whole query, not per column, so only the
application knows whether every column it selected has a binary decoder.
In text mode every value is text and the integer and float readers parse
it; in binary mode `wire.mojo` decodes what it names and a type it does not
know raises, naming the way out rather than returning plausible nonsense.

Every accessor bounds-checks. `PQgetvalue` past the end returns NULL, which
`read_cstr` would turn into an empty string and nothing upstream would
notice — the same defect `m0-sqlite`'s column readers exist to refuse.
"""

from std.collections.span import Span
from std.memory import Pointer

from .lib import ResultLib, read_cstr
from .wire import (
    OID_BOOL,
    OID_FLOAT4,
    OID_FLOAT8,
    OID_INT2,
    OID_INT4,
    OID_INT8,
    OID_JSONB,
    OID_TIMESTAMP,
    OID_TIMESTAMPTZ,
    OID_UUID,
    decode_bool,
    decode_float,
    decode_int,
    decode_jsonb,
    decode_timestamp_micros,
    decode_uuid,
    has_binary_decoder,
    type_name,
)


struct Result(Movable):
    """One complete query result. Cleared when it goes out of scope."""

    var _handle: Int
    var _pq: ResultLib
    """The entry points this result calls, copied rather than borrowed.

    Nothing here refers to the `Connection` that produced the result, so
    that connection may be moved or destroyed — at its last use, which is
    routinely the query itself — without this result noticing.
    """

    var rows: Int
    var cols: Int
    var binary: Bool

    def __init__(out self, handle: Int, pq: ResultLib, binary: Bool) raises:
        """Take ownership of a `PGresult *`.

        Refuses NULL, which libpq returns only when it could not allocate
        the result at all — a case the caller must not read as an empty
        result set.
        """
        if handle == 0:
            raise Error(
                "libpq returned no result at all — out of memory, or the"
                " connection was already broken"
            )
        self._handle = handle
        self._pq = pq
        self.binary = binary
        self.rows = pq.ntuples(handle)
        self.cols = pq.nfields(handle)

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle
        self._pq = move._pq
        self.rows = move.rows
        self.cols = move.cols
        self.binary = move.binary

    def __deinit__(deinit self):
        if self._handle != 0:
            self._pq.clear(self._handle)

    def status(self) -> Int:
        return self._pq.result_status(self._handle)

    def command_rows(self) raises -> Int:
        """Rows affected by an INSERT, UPDATE or DELETE.

        `PQcmdTuples` answers with TEXT — the empty string for a statement
        that affects no rows by nature, such as DDL — so this parses it and
        reports 0 for the empty case rather than raising, which is what the
        empty string means.
        """
        var text = read_cstr(self._pq.cmd_tuples(self._handle))
        if not text:
            return 0
        var n = 0
        for b in text.as_bytes():
            if b < UInt8(ord("0")) or b > UInt8(ord("9")):
                raise Error(
                    "PQcmdTuples answered " + text + ", which is not a count"
)
            n = n * 10 + Int(b - UInt8(ord("0")))
        return n

    def name(self, col: Int) raises -> String:
        """A column's name, as the query named it."""
        self._check(0, col, check_row=False)
        return read_cstr(self._pq.fname(self._handle, col))

    def column(self, name: String) raises -> Int:
        """The index of the column with this name.

        Raises rather than answering -1, which `PQfnumber` does: an
        unnoticed -1 reads every row's LAST column on some accessors and
        NULL on others, and both are silent.
        """
        for c in range(self.cols):
            if self.name(c) == name:
                return c
        raise Error(
            "this result has no column named `" + name + "` — it has "
            + String(self.cols) + " columns"
)

    def oid(self, col: Int) raises -> Int:
        """A column's type OID."""
        self._check(0, col, check_row=False)
        return self._pq.ftype(self._handle, col)

    def is_null(self, row: Int, col: Int) raises -> Bool:
        """Whether this cell is SQL NULL.

        Asked before any reader, because NULL and a zero-length value are
        indistinguishable afterwards: both have length 0, and text mode
        reports both as the empty string.
        """
        self._check(row, col)
        return self._pq.getisnull(self._handle, row, col) != 0

    def raw(self, row: Int, col: Int) raises -> Span[UInt8, MutUntrackedOrigin]:
        """The cell's bytes, exactly as the server sent them.

        Valid while this `Result` lives, and no longer: the bytes belong to
        the `PGresult` and `PQclear` frees them.
        """
        self._check(row, col)
        var addr = self._pq.getvalue(self._handle, row, col)
        var n = self._pq.getlength(self._handle, row, col)
        if addr == 0 or n <= 0:
            return Span[UInt8, MutUntrackedOrigin](
                unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=Int(self._handle)
                ),
                length=0,
            )
        return Span[UInt8, MutUntrackedOrigin](
            unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=addr
            ),
            length=n,
        )

    def bytes(self, row: Int, col: Int) raises -> List[UInt8]:
        """A copy of the cell's bytes, owned by the caller."""
        var span = self.raw(row, col)
        var out = List[UInt8](capacity=len(span))
        for b in span:
            out.append(b)
        return out^

    def text(self, row: Int, col: Int) raises -> String:
        """The cell as text.

        In text mode this is what the server sent. In binary mode it is
        `wire.mojo`'s decoding, rendered — so a query's columns read the
        same either way and only the cost differs. A binary column whose
        type has no decoder raises here, naming the type and the way out.
        """
        if self.is_null(row, col):
            return String("")
        var span = self.raw(row, col)
        if not self.binary:
            return String(unsafe_from_utf8=span)
        var t = self.oid(col)
        if not has_binary_decoder(t):
            raise Error(
                "column " + String(col) + " is " + type_name(t)
                + ", which has no binary decoder — run this query in text"
                " mode, or cast the column in SQL"
)
        if t == OID_INT2 or t == OID_INT4 or t == OID_INT8:
            return String(decode_int(span))
        if t == OID_FLOAT4 or t == OID_FLOAT8:
            return String(decode_float(span))
        if t == OID_BOOL:
            return String("t") if decode_bool(span) else String("f")
        if t == OID_UUID:
            return decode_uuid(span)
        if t == OID_JSONB:
            return decode_jsonb(span)
        if t == OID_TIMESTAMP or t == OID_TIMESTAMPTZ:
            return String(decode_timestamp_micros(span))
        return String(unsafe_from_utf8=span)

    def int(self, row: Int, col: Int) raises -> Int:
        """The cell as an integer.

        Binary mode decodes; text mode parses, including a leading `-`. A
        value that is not an integer raises rather than answering 0, which
        is the difference between a missing row and a row holding zero.
        """
        if self.is_null(row, col):
            raise Error(
                "column " + String(col) + " of row " + String(row)
                + " is NULL — ask is_null before reading it as an integer"
)
        var span = self.raw(row, col)
        if self.binary:
            var t = self.oid(col)
            if t == OID_INT2 or t == OID_INT4 or t == OID_INT8:
                return decode_int(span)
            if t == OID_TIMESTAMP or t == OID_TIMESTAMPTZ:
                return decode_timestamp_micros(span)
            raise Error(
                "column " + String(col) + " is " + type_name(t)
                + ", not an integer type, in a binary result"
)
        return _parse_int(String(unsafe_from_utf8=span))

    def float(self, row: Int, col: Int) raises -> Float64:
        """The cell as a double."""
        if self.is_null(row, col):
            raise Error(
                "column " + String(col) + " of row " + String(row)
                + " is NULL — ask is_null before reading it as a float"
)
        var span = self.raw(row, col)
        if self.binary:
            var t = self.oid(col)
            if t == OID_FLOAT4 or t == OID_FLOAT8:
                return decode_float(span)
            if t == OID_INT2 or t == OID_INT4 or t == OID_INT8:
                return Float64(decode_int(span))
            raise Error(
                "column " + String(col) + " is " + type_name(t)
                + ", not a numeric type, in a binary result"
)
        return Float64(String(unsafe_from_utf8=span))

    def bool(self, row: Int, col: Int) raises -> Bool:
        """The cell as a boolean.

        Text mode sends `t` and `f`, which is why this is not a comparison
        against `true`.
        """
        if self.is_null(row, col):
            raise Error(
                "column " + String(col) + " of row " + String(row)
                + " is NULL — ask is_null before reading it as a bool"
)
        var span = self.raw(row, col)
        if self.binary:
            return decode_bool(span)
        return len(span) > 0 and span[0] == UInt8(ord("t"))

    def fetch_ints(self, col: Int) raises -> List[Int]:
        """Every row's value in one column, as integers.

        The column helper `m0-sqlite` has, for the same reason: a list of
        ids is the commonest thing a query returns, and writing the loop at
        every call site is where an off-by-one goes.
        """
        var out = List[Int](capacity=self.rows)
        for r in range(self.rows):
            out.append(self.int(r, col))
        return out^

    def fetch_texts(self, col: Int) raises -> List[String]:
        """Every row's value in one column, as text. NULL reads as ""."""
        var out = List[String](capacity=self.rows)
        for r in range(self.rows):
            out.append(self.text(r, col))
        return out^

    def _check(self, row: Int, col: Int, check_row: Bool = True) raises:
        if col < 0 or col >= self.cols:
            raise Error(
                "column index " + String(col) + " is out of range for "
                + String(self.cols) + " columns"
)
        if check_row and (row < 0 or row >= self.rows):
            raise Error(
                "row index " + String(row) + " is out of range for "
                + String(self.rows) + " rows"
)


def _parse_int(text: String) raises -> Int:
    """A decimal integer, with an optional sign. Raises on anything else."""
    var b = text.as_bytes()
    if len(b) == 0:
        raise Error("an empty value is not an integer")
    var i = 0
    var negative = False
    if b[0] == UInt8(ord("-")):
        negative = True
        i = 1
    elif b[0] == UInt8(ord("+")):
        i = 1
    if i >= len(b):
        raise Error("`" + text + "` is not an integer")
    var n = 0
    while i < len(b):
        if b[i] < UInt8(ord("0")) or b[i] > UInt8(ord("9")):
            raise Error("`" + text + "` is not an integer")
        n = n * 10 + Int(b[i] - UInt8(ord("0")))
        i += 1
    return -n if negative else n
