"""Query parameters: the four arrays `PQexecParams` takes, built once.

libpq binds by position with four parallel C arrays — OIDs, value pointers,
lengths, formats — and the format is chosen PER PARAMETER, unlike the result
format, which is one choice for the whole query. `Params` owns all four,
plus the bytes they point into, so a request's parameters cost one growing
buffer rather than an allocation each.

    var p = Params()
    p.int(7)
    p.text("ada")
    var rows = conn.query("SELECT * FROM users WHERE id = $1 OR name = $2", p)

**Positions are 1-based in SQL (`$1`) and 0-based in these arrays**, which is
libpq's asymmetry, not this package's; `add` order is what assigns them, so
the first call is `$1`.

**Every parameter carries an explicit OID.** A parameter left as `unknown`
is resolved from the expression it appears in — text in `SELECT $1`, the
column's type in `WHERE id = $1` — so the same `Params` would mean different
things in different queries. `int8` compares with and assigns to `int4`
without a cast, which is why one integer method is enough; an application
that needs a narrower type writes `$1::int4` in its SQL, where it is
visible. `literal` is the deliberate escape hatch for the types this package
does not encode — a timestamp, a uuid, an array, a numeric — sent as
`unknown` text for the server to coerce, which is exactly how `psql` sends
them.

**The value pointers are taken after the last append**, in `build`, never
during it: the buffer moves when it grows, so a pointer taken during
construction would dangle on the next `append`. That is the same class of
bug as the module-level rule in `lib.mojo`, and it is why this type exists
rather than four lists at each call site.
"""

from std.collections.span import Span
from std.memory import Pointer

from .wire import (
    OID_BOOL,
    OID_BYTEA,
    OID_FLOAT8,
    OID_INT8,
    OID_TEXT,
    OID_UNKNOWN,
    encode_bool,
    encode_float8,
    encode_int8,
)
from .lib import FORMAT_BINARY, FORMAT_TEXT


comptime NULL_OFFSET: Int = -1
"""The offset that means SQL NULL: libpq reads a NULL value pointer as NULL,
and no other length or format is consulted."""


struct Params(Movable, Copyable, Sized):
    """Positional query parameters and the bytes they point into.

    Copyable, unlike the handle types in this package: it owns only its own
    memory — no descriptor, no server-side object — so a copy is a copy of
    bytes and duplicates nothing that a destructor would release twice.
    """

    var _bytes: List[UInt8]
    """Every parameter's encoded value, back to back. Text values carry a
    NUL terminator they do not count in their length, so a value can be
    passed to an entry point that takes no length if one is ever needed."""

    var _offsets: List[Int]
    var _lengths: List[Int]
    var _oids: List[Int]
    var _formats: List[Int]

    def __init__(out self):
        self._bytes = List[UInt8]()
        self._offsets = List[Int]()
        self._lengths = List[Int]()
        self._oids = List[Int]()
        self._formats = List[Int]()

    def __init__(out self, *, deinit move: Self):
        self._bytes = move._bytes^
        self._offsets = move._offsets^
        self._lengths = move._lengths^
        self._oids = move._oids^
        self._formats = move._formats^

    def __init__(out self, *, copy: Self):
        self._bytes = copy._bytes.copy()
        self._offsets = copy._offsets.copy()
        self._lengths = copy._lengths.copy()
        self._oids = copy._oids.copy()
        self._formats = copy._formats.copy()

    def __len__(self) -> Int:
        return len(self._oids)

    def _push(mut self, data: Span[UInt8, _], oid: Int, format: Int):
        self._offsets.append(len(self._bytes))
        self._lengths.append(len(data))
        self._oids.append(oid)
        self._formats.append(format)
        for b in data:
            self._bytes.append(b)
        # A NUL past every value's own length: free, and it means a value
        # can be handed to an entry point that takes no length.
        self._bytes.append(0)

    def int(mut self, value: Int):
        """A 64-bit integer, sent binary as `int8`."""
        self._push(Span(encode_int8(value)), OID_INT8, FORMAT_BINARY)

    def float(mut self, value: Float64):
        """A double, sent binary as `float8`."""
        self._push(Span(encode_float8(value)), OID_FLOAT8, FORMAT_BINARY)

    def bool(mut self, value: Bool):
        """A boolean, sent binary as `bool`."""
        self._push(Span(encode_bool(value)), OID_BOOL, FORMAT_BINARY)

    def text(mut self, value: String):
        """Text, sent as `text`.

        Text format, not binary: for a string the two are the same bytes,
        and text is what an application reading the wire expects to see.
        The bytes go as given — the connection is `client_encoding=UTF8`
        and a Mojo `String` is UTF-8, so no transcoding is needed or done.
        """
        self._push(value.as_bytes(), OID_TEXT, FORMAT_TEXT)

    def bytes(mut self, value: Span[UInt8, _]):
        """Arbitrary bytes, sent binary as `bytea`.

        Binary, so a blob crosses as itself rather than through `bytea`'s
        hex text form, which doubles it and has to be decoded on the way
        back.
        """
        self._push(value, OID_BYTEA, FORMAT_BINARY)

    def null(mut self):
        """SQL NULL, of whatever type the expression requires."""
        self._offsets.append(NULL_OFFSET)
        self._lengths.append(0)
        self._oids.append(OID_UNKNOWN)
        self._formats.append(FORMAT_TEXT)

    def literal(mut self, value: String):
        """Text the SERVER types, for a type this package does not encode.

        Sent as `unknown`, which Postgres resolves from context: a
        timestamp against a `timestamptz` column, `{1,2,3}` against an
        integer array, `2.50` against `numeric`. It is how `psql` sends
        every literal, and it is why the absence of a `numeric` encoder
        here costs an application nothing except the loss of a type check
        at the boundary.

        The cost is the cast site: in a bare `SELECT $1` with nothing to
        infer from, an `unknown` parameter comes out as text.
        """
        self._push(value.as_bytes(), OID_UNKNOWN, FORMAT_TEXT)

    def oid_at(self, index: Int) raises -> Int:
        """The OID assigned to position `index` (0-based)."""
        if index < 0 or index >= len(self._oids):
            raise Error(
                "parameter index " + String(index) + " is out of range for "
                + String(len(self._oids)) + " parameters"
            )
        return self._oids[index]


struct ParamArrays(Movable):
    """The four C arrays, pointing into a `Params` that must outlive them.

    Built by `build` immediately before the call and dropped immediately
    after, which is the only window in which the value pointers are valid:
    `Params` grows its buffer by appending, so any pointer taken earlier
    would be to a freed allocation.

    Not a public type. It exists so the unsafe window is one expression in
    `conn.mojo` rather than four lists assembled at every call site.
    """

    var values: List[Int]
    var lengths: List[Int32]
    var oids: List[Int32]
    var formats: List[Int32]

    def __init__(out self, ref params: Params):
        self.values = List[Int]()
        self.lengths = List[Int32]()
        self.oids = List[Int32]()
        self.formats = List[Int32]()
        var base = Int(params._bytes.unsafe_ptr())
        for i in range(len(params._oids)):
            var off = params._offsets[i]
            # NULL is a NULL POINTER, not a zero length: libpq reads the
            # pointer first and consults nothing else when it is null.
            self.values.append(0 if off == NULL_OFFSET else base + off)
            self.lengths.append(Int32(params._lengths[i]))
            self.oids.append(Int32(params._oids[i]))
            self.formats.append(Int32(params._formats[i]))

    def __init__(out self, *, deinit move: Self):
        self.values = move.values^
        self.lengths = move.lengths^
        self.oids = move.oids^
        self.formats = move.formats^

    def values_addr(self) -> Int:
        return Int(self.values.unsafe_ptr()) if len(self.values) else 0

    def lengths_addr(self) -> Int:
        return Int(self.lengths.unsafe_ptr()) if len(self.lengths) else 0

    def oids_addr(self) -> Int:
        return Int(self.oids.unsafe_ptr()) if len(self.oids) else 0

    def formats_addr(self) -> Int:
        return Int(self.formats.unsafe_ptr()) if len(self.formats) else 0
