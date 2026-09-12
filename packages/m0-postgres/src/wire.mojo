"""Postgres wire formats, decoded and encoded in pure Mojo.

No FFI, no server, no connection: every function here takes bytes and returns
a value, which is what lets `test_wire.mojo` run in `poe test-all` on a
machine with no database. The binary formats are stable parts of the
protocol — a type's binary representation is part of its `send`/`recv`
functions and does not change between major versions — so testing them
against hand-built bytes is testing the real thing.

**Integers and floats are big-endian**, network order, whatever the host is.
**Timestamps count microseconds from 2000-01-01**, not from the Unix epoch;
`unix_micros` applies the difference. **`jsonb` carries a version byte** (1)
before its text, and `json` does not — the one place two types that look
identical in text mode differ in binary.

Which OIDs have a decoder is a deliberate, short list (`has_binary_decoder`).
`numeric` is absent because its binary form is a base-10000 digit vector with
its own NaN encoding, and a wrong one is silently a different number; dates
and intervals are absent because they need a calendar. Those are text-mode
types until an application needs arithmetic on them in Mojo, and
`Result.text` says so by name rather than handing back plausible nonsense.
"""

from std.collections.span import Span


# --- Type OIDs -------------------------------------------------------------
#
# From `pg_type`. Stable across versions — these numbers are part of the
# protocol, not an implementation detail, which is why they can be constants
# here rather than a lookup against the server's own catalog.

comptime OID_BOOL: Int = 16
comptime OID_BYTEA: Int = 17
comptime OID_NAME: Int = 19
comptime OID_INT8: Int = 20
comptime OID_INT2: Int = 21
comptime OID_INT4: Int = 23
comptime OID_TEXT: Int = 25
comptime OID_JSON: Int = 114
comptime OID_FLOAT4: Int = 700
comptime OID_FLOAT8: Int = 701
comptime OID_VARCHAR: Int = 1043
comptime OID_TIMESTAMP: Int = 1114
comptime OID_TIMESTAMPTZ: Int = 1184
comptime OID_UUID: Int = 2950
comptime OID_JSONB: Int = 3802
comptime OID_UNKNOWN: Int = 0
"""The OID that means "let the server infer it from context".

Not a type: a parameter sent as `unknown` is resolved by the expression it
appears in, which is what makes `Params.literal` work for a timestamp or an
array without this file knowing their formats.
"""

comptime PG_EPOCH_UNIX_SECONDS: Int = 946684800
"""2000-01-01T00:00:00Z as a Unix timestamp.

Postgres counts microseconds from here, not from 1970. The difference is
exact and has no leap-second component: both scales are counts of SI
seconds from their own epoch, and Postgres's is 30 years of 86400 s.
"""


def has_binary_decoder(oid: Int) -> Bool:
    """Whether `decode_*` here can read this type's binary form.

    The gate `Result` asks before handing back a value from a binary result.
    A type not on this list is not "unsupported" in general — it reads
    perfectly in text mode — so the refusal names the way out.
    """
    return (
        oid == OID_BOOL
        or oid == OID_BYTEA
        or oid == OID_NAME
        or oid == OID_INT8
        or oid == OID_INT2
        or oid == OID_INT4
        or oid == OID_TEXT
        or oid == OID_JSON
        or oid == OID_FLOAT4
        or oid == OID_FLOAT8
        or oid == OID_VARCHAR
        or oid == OID_TIMESTAMP
        or oid == OID_TIMESTAMPTZ
        or oid == OID_UUID
        or oid == OID_JSONB
    )


def type_name(oid: Int) -> String:
    """A type's name for an error message, or its number if unknown."""
    if oid == OID_BOOL:
        return String("bool")
    if oid == OID_BYTEA:
        return String("bytea")
    if oid == OID_NAME:
        return String("name")
    if oid == OID_INT8:
        return String("int8")
    if oid == OID_INT2:
        return String("int2")
    if oid == OID_INT4:
        return String("int4")
    if oid == OID_TEXT:
        return String("text")
    if oid == OID_JSON:
        return String("json")
    if oid == OID_FLOAT4:
        return String("float4")
    if oid == OID_FLOAT8:
        return String("float8")
    if oid == OID_VARCHAR:
        return String("varchar")
    if oid == OID_TIMESTAMP:
        return String("timestamp")
    if oid == OID_TIMESTAMPTZ:
        return String("timestamptz")
    if oid == OID_UUID:
        return String("uuid")
    if oid == OID_JSONB:
        return String("jsonb")
    if oid == OID_UNKNOWN:
        return String("unknown")
    return String("oid ") + String(oid)


# --- Decoding --------------------------------------------------------------


def decode_int(data: Span[UInt8, _]) raises -> Int:
    """A big-endian signed integer of 2, 4 or 8 bytes.

    Sign-extended by hand rather than by a cast: `int2` arrives as two bytes
    and -1 is `FF FF`, which read as unsigned is 65535. Getting this wrong is
    a value that is plausible everywhere except where it matters.
    """
    var n = len(data)
    if n != 2 and n != 4 and n != 8:
        raise Error(
            "a binary integer must be 2, 4 or 8 bytes, got " + String(n)
        )
    var bits = UInt64(0)
    for i in range(n):
        bits = (bits << 8) | UInt64(data[i])
    if n == 8:
        return Int(Int64(bits))
    # The sign bit of the width actually sent, extended to 64.
    var sign = UInt64(1) << UInt64(n * 8 - 1)
    if bits & sign != 0:
        var mask = (UInt64(1) << UInt64(n * 8)) - 1
        return -Int(Int64((~bits & mask) + 1))
    return Int(Int64(bits))


def decode_float(data: Span[UInt8, _]) raises -> Float64:
    """A big-endian IEEE 754 float of 4 or 8 bytes.

    `float4` widens to `Float64` on the way out, which is exact: every
    binary32 value is a binary64 value.
    """
    var n = len(data)
    if n == 4:
        var bits = UInt32(0)
        for i in range(4):
            bits = (bits << 8) | UInt32(data[i])
        return Float64(Float32(from_bits=bits))
    if n == 8:
        var bits64 = UInt64(0)
        for i in range(8):
            bits64 = (bits64 << 8) | UInt64(data[i])
        return Float64(from_bits=bits64)
    raise Error("a binary float must be 4 or 8 bytes, got " + String(n))


def decode_bool(data: Span[UInt8, _]) raises -> Bool:
    """One byte, 0 or 1."""
    if len(data) != 1:
        raise Error("a binary bool must be 1 byte, got " + String(len(data)))
    return data[0] != 0


def decode_timestamp_micros(data: Span[UInt8, _]) raises -> Int:
    """Microseconds since 2000-01-01, as Postgres sends them.

    `timestamptz` is an instant and this is that instant in UTC;
    `timestamp` has no zone and this is its face value read as if UTC.
    The distinction belongs to the caller, which knows the column.

    Infinity is sent as INT64_MIN/MAX and is returned as such rather than
    raising: it is a legitimate value of the type, and an application that
    stores it should be the one to decide what it means.
    """
    if len(data) != 8:
        raise Error(
            "a binary timestamp must be 8 bytes, got " + String(len(data))
        )
    return decode_int(data)


def unix_micros(pg_micros: Int) -> Int:
    """Postgres microseconds to Unix microseconds."""
    return pg_micros + PG_EPOCH_UNIX_SECONDS * 1000000


def decode_jsonb(data: Span[UInt8, _]) raises -> String:
    """`jsonb`'s binary form: a version byte, then the JSON text.

    Version 1 is the only one defined. Refusing an unknown version is the
    point of reading the byte at all — a future version that put something
    else there would otherwise be returned as JSON with one byte missing
    from the front.
    """
    if len(data) < 1:
        raise Error("a binary jsonb value is empty")
    if data[0] != 1:
        raise Error(
            "binary jsonb version " + String(Int(data[0]))
            + " is not version 1, the only one this decoder knows"
        )
    return String(unsafe_from_utf8=data[1:])


def decode_uuid(data: Span[UInt8, _]) raises -> String:
    """Sixteen bytes to the canonical 8-4-4-4-12 hex text."""
    if len(data) != 16:
        raise Error(
            "a binary uuid must be 16 bytes, got " + String(len(data))
        )
    comptime HEX = "0123456789abcdef"
    var hex = HEX.as_bytes()
    var out = List[UInt8](capacity=36)
    for i in range(16):
        if i == 4 or i == 6 or i == 8 or i == 10:
            out.append(UInt8(ord("-")))
        out.append(hex[Int(data[i] >> 4)])
        out.append(hex[Int(data[i] & 0x0F)])
    return String(unsafe_from_utf8=Span(out))


# --- Encoding (parameters) -------------------------------------------------


def encode_int8(value: Int) -> List[UInt8]:
    """A signed 64-bit integer, big-endian — `int8`'s binary form."""
    var bits = UInt64(Int64(value))
    var out = List[UInt8](capacity=8)
    for shift in range(56, -8, -8):
        out.append(UInt8((bits >> UInt64(shift)) & 0xFF))
    return out^


def encode_float8(value: Float64) -> List[UInt8]:
    """A double, big-endian IEEE 754 — `float8`'s binary form."""
    var bits = UInt64(value.to_bits())
    var out = List[UInt8](capacity=8)
    for shift in range(56, -8, -8):
        out.append(UInt8((bits >> UInt64(shift)) & 0xFF))
    return out^


def encode_bool(value: Bool) -> List[UInt8]:
    """One byte, 0 or 1 — `bool`'s binary form."""
    var out = List[UInt8](capacity=1)
    out.append(UInt8(1) if value else UInt8(0))
    return out^
