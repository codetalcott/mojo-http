"""The binary wire formats, against hand-built bytes.

No server and no libpq: every case here is a byte string written out in the
test and the value Postgres means by it. That is what lets these run in
`poe test-all` on both CI legs, where the server-backed tests cannot.

The bytes are not invented. Each is what `SELECT ... ` returns with
`resultFormat = 1`, and the ones that could be got wrong by guessing —
negative integers of each width, the 2000 epoch, jsonb's version byte — are
the reason this file is a table rather than a round trip.
"""

from std.collections.span import Span
from std.testing import (
    TestSuite,
    assert_almost_equal,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from src.wire import (
    OID_INT4,
    OID_JSONB,
    OID_NAME,
    OID_TIMESTAMPTZ,
    PG_EPOCH_UNIX_SECONDS,
    decode_bool,
    decode_float,
    decode_int,
    decode_jsonb,
    decode_timestamp_micros,
    decode_uuid,
    encode_bool,
    encode_float8,
    encode_int8,
    has_binary_decoder,
    type_name,
    unix_micros,
)


def _bytes(*values: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for v in values:
        out.append(UInt8(v))
    return out^


# --- Integers ---------------------------------------------------------------


def test_integers_are_big_endian_at_every_width() raises:
    """Network order at 2, 4 and 8 bytes.

    covers: O6
    """
    assert_equal(decode_int(Span(_bytes(0x00, 0x2A))), 42)
    assert_equal(decode_int(Span(_bytes(0x00, 0x00, 0x00, 0x2A))), 42)
    assert_equal(
        decode_int(Span(_bytes(0, 0, 0, 0, 0, 0, 0, 0x2A))), 42
    )
    # Big-endian, not little: the same bytes reversed are a different number.
    assert_equal(decode_int(Span(_bytes(0x01, 0x00))), 256)


def test_negative_integers_are_sign_extended_from_their_own_width() raises:
    """The trap this function exists for.

    `int2`'s -1 is `FF FF`, which read as unsigned is 65535 — a value that
    looks plausible everywhere except where it matters. Each width has to
    extend its OWN sign bit, not the 64-bit one.

    covers: O6
    """
    assert_equal(decode_int(Span(_bytes(0xFF, 0xFF))), -1)
    assert_equal(decode_int(Span(_bytes(0xFF, 0xFF, 0xFF, 0xFF))), -1)
    assert_equal(
        decode_int(Span(_bytes(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF))),
        -1,
    )
    # int2's most negative, and int4's.
    assert_equal(decode_int(Span(_bytes(0x80, 0x00))), -32768)
    assert_equal(decode_int(Span(_bytes(0x80, 0x00, 0x00, 0x00))), -2147483648)
    assert_equal(decode_int(Span(_bytes(0xFF, 0x9C))), -100)


def test_an_integer_of_the_wrong_width_is_refused() raises:
    """A width Postgres never sends is an error, not a guess.

    covers: O6
    """
    with assert_raises(contains="2, 4 or 8 bytes"):
        _ = decode_int(Span(_bytes(0x01, 0x02, 0x03)))


def test_encode_int8_round_trips_through_the_decoder() raises:
    """What this encodes, it decodes.

    covers: O6
    """
    for value in [0, 1, -1, 42, -42, 2147483648, -2147483649, 9007199254740993]:
        assert_equal(decode_int(Span(encode_int8(value))), value)


# --- Floats -----------------------------------------------------------------


def test_floats_are_ieee_754_big_endian() raises:
    """Both widths, against their published bit patterns.

    covers: O6
    """
    # 1.0 is 0x3FF0000000000000 as binary64, 0x3F800000 as binary32.
    assert_equal(
        decode_float(Span(_bytes(0x3F, 0xF0, 0, 0, 0, 0, 0, 0))), 1.0
    )
    assert_equal(decode_float(Span(_bytes(0x3F, 0x80, 0, 0))), 1.0)
    assert_equal(
        decode_float(Span(_bytes(0xC0, 0x00, 0, 0, 0, 0, 0, 0))), -2.0
    )
    assert_almost_equal(
        decode_float(Span(_bytes(0x40, 0x09, 0x21, 0xFB, 0x54, 0x44, 0x2D, 0x18))),
        3.141592653589793,
    )


def test_encode_float8_round_trips() raises:
    """What this encodes, it decodes.

    covers: O6
    """
    for value in [0.0, 1.0, -1.0, 0.5, 1e300, -1e-300]:
        assert_almost_equal(decode_float(Span(encode_float8(value))), value)


def test_a_float_of_the_wrong_width_is_refused() raises:
    """A width Postgres never sends is an error, not a guess.

    covers: O6
    """
    with assert_raises(contains="4 or 8 bytes"):
        _ = decode_float(Span(_bytes(0x01, 0x02)))


# --- Bool -------------------------------------------------------------------


def test_bool_is_one_byte() raises:
    """One byte, and any other length is refused.

    covers: O6
    """
    assert_true(decode_bool(Span(_bytes(1))))
    assert_false(decode_bool(Span(_bytes(0))))
    assert_true(decode_bool(Span(encode_bool(True))))
    assert_false(decode_bool(Span(encode_bool(False))))
    with assert_raises(contains="1 byte"):
        _ = decode_bool(Span(_bytes(0, 1)))


# --- Timestamps -------------------------------------------------------------


def test_timestamps_count_microseconds_from_2000_not_1970() raises:
    """The epoch difference, which is the whole of this decoder.

    A timestamp read against the Unix epoch is thirty years early and looks
    entirely valid — 1970-01-01 for a row written today. The offset is
    exact: both scales count SI seconds from their own epoch, so there is no
    leap-second term.

    covers: O6
    """
    # 2000-01-01T00:00:00Z is zero on Postgres's scale.
    assert_equal(decode_timestamp_micros(Span(_bytes(0, 0, 0, 0, 0, 0, 0, 0))), 0)
    assert_equal(unix_micros(0), PG_EPOCH_UNIX_SECONDS * 1000000)
    # One second past the Postgres epoch.
    var one_second = encode_int8(1000000)
    assert_equal(decode_timestamp_micros(Span(one_second)), 1000000)
    assert_equal(
        unix_micros(decode_timestamp_micros(Span(one_second))),
        (PG_EPOCH_UNIX_SECONDS + 1) * 1000000,
    )
    # A timestamp BEFORE 2000 is negative, and must stay negative.
    var before = encode_int8(-1000000)
    assert_equal(
        unix_micros(decode_timestamp_micros(Span(before))),
        (PG_EPOCH_UNIX_SECONDS - 1) * 1000000,
    )


# --- jsonb ------------------------------------------------------------------


def test_jsonb_carries_a_version_byte_and_json_does_not() raises:
    """`jsonb`'s binary form opens with its version.

    covers: O6
    """
    var frame = List[UInt8]()
    frame.append(1)
    for b in String('{"a":1}').as_bytes():
        frame.append(b)
    assert_equal(decode_jsonb(Span(frame)), '{"a":1}')


def test_an_unknown_jsonb_version_is_refused_rather_than_shifted() raises:
    """Reading the byte is the point of reading it at all.

    A future version byte, ignored, returns JSON with one byte missing from
    the front — which parses as something else or as nothing, depending on
    what follows.

    covers: O6
    """
    var frame = List[UInt8]()
    frame.append(2)
    for b in String('{"a":1}').as_bytes():
        frame.append(b)
    with assert_raises(contains="version 2"):
        _ = decode_jsonb(Span(frame))


# --- uuid -------------------------------------------------------------------


def test_uuid_is_sixteen_bytes_rendered_canonically() raises:
    """Sixteen bytes to 8-4-4-4-12, lowercase.

    covers: O6
    """
    var raw = _bytes(
        0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
        0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
    )
    assert_equal(
        decode_uuid(Span(raw)), "12345678-9abc-def0-1234-56789abcdef0"
    )
    with assert_raises(contains="16 bytes"):
        _ = decode_uuid(Span(_bytes(1, 2, 3)))


# --- The decoder table ------------------------------------------------------


def test_the_binary_decoder_list_and_the_type_names_agree() raises:
    """Every type with a decoder has a name, and the absences are deliberate.

    `numeric`, `date` and the array types are text-only on purpose: a
    numeric's binary form is a base-10000 digit vector with its own NaN
    encoding, and a wrong decoding of one is silently a different number.
    This asserts the absence, so adding a decoder is a deliberate edit here
    rather than a surprise.

    covers: O6
    """
    assert_true(has_binary_decoder(OID_INT4))
    assert_true(has_binary_decoder(OID_JSONB))
    assert_true(has_binary_decoder(OID_TIMESTAMPTZ))
    assert_true(has_binary_decoder(OID_NAME))
    assert_false(has_binary_decoder(1700))  # numeric
    assert_false(has_binary_decoder(1082))  # date
    assert_false(has_binary_decoder(1007))  # int4[]
    assert_equal(type_name(OID_INT4), "int4")
    assert_equal(type_name(1700), "oid 1700")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
