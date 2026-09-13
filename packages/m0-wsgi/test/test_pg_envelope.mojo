"""The `--pg-listen` payload rule, as a pure function.

`smoke-pg-notify` proves the same rule end to end against a server; this is
the half that runs on every leg with no database, and names each shape.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from src.pg_envelope import parse_notify_payload


def test_three_string_fields_are_an_envelope() raises:
    """The contract `m0pub.notify_sql` builds.

    covers: I22
    """
    var env = parse_notify_payload(
        '{"channel":"room:1","event":"msg","data":"{\\"n\\":1}"}'
    )
    assert_true(Bool(env))
    assert_equal(env.value().channel, "room:1")
    assert_equal(env.value().event, "msg")
    # Structured data travels serialized INTO the string, and arrives as
    # that text.
    assert_equal(env.value().data, '{"n":1}')


def test_absent_event_and_data_read_as_empty() raises:
    """Optional fields: absent is allowed, and is the empty string.

    covers: I22
    """
    var env = parse_notify_payload('{"channel":"room:1"}')
    assert_true(Bool(env))
    assert_equal(env.value().event, "")
    assert_equal(env.value().data, "")
    var empty = parse_notify_payload('{"channel":"c","data":""}')
    assert_true(Bool(empty))
    assert_equal(empty.value().data, "")


def test_data_that_is_not_a_string_is_refused() raises:
    """The shape a trigger writes first: `'data', row_to_json(NEW)`.

    `parse_json_field` reads an object, a number and `null` as `""`, so each
    of these used to reach every subscriber as a bare `data: ` and was
    counted as delivered.

    covers: I22
    """
    for payload in [
        '{"channel":"c","data":{"id":7,"title":"x"}}',
        '{"channel":"c","data":[1,2,3]}',
        '{"channel":"c","data":42}',
        '{"channel":"c","data":true}',
        '{"channel":"c","data":null}',
        '{"channel":"c","data":"bad \\q escape"}',
        '{"channel":"c","event":{"type":"x"},"data":"ok"}',
        '{"channel":"c","event":7,"data":"ok"}',
    ]:
        if parse_notify_payload(payload):
            raise Error("accepted a non-string field: " + payload)


def test_a_payload_with_no_usable_channel_is_refused() raises:
    """No JSON, no channel, an empty one, a non-string one, a reserved one.

    covers: I22
    """
    for payload in [
        "not json at all",
        "{}",
        '{"channel":""}',
        '{"channel":7,"data":"x"}',
        '{"channel":{"name":"c"},"data":"x"}',
        '{"channel":"\\u0001s/0","data":"reserved"}',
    ]:
        assert_false(Bool(parse_notify_payload(payload)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
