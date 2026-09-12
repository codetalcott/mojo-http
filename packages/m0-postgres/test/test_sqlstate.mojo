"""SQLSTATE: carried in the message, recovered from the end.

The twin of `m0-sqlite`'s `error_code` tests, and pure for the same reason:
a Mojo `Error` is text, so the contract is about text.
"""

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from src.sqlstate import (
    ADMIN_SHUTDOWN,
    CONNECTION_FAILURE,
    DEADLOCK_DETECTED,
    QUERY_CANCELED,
    SERIALIZATION_FAILURE,
    TOO_MANY_CONNECTIONS,
    UNDEFINED_TABLE,
    UNIQUE_VIOLATION,
    describe,
    describe_in,
    is_connection_lost,
    is_retryable,
    sqlstate,
)


def test_a_described_error_ends_in_its_sqlstate() raises:
    """The code travels at the end of the message.

    covers: O8
    """
    var text = describe("exec", UNIQUE_VIOLATION, "duplicate key value")
    assert_true(text.endswith("(sqlstate=23505)"))
    assert_equal(sqlstate(text), UNIQUE_VIOLATION)


def test_the_context_goes_before_the_code_not_after() raises:
    """The ordering `m0-sqlite`'s `describe_in` established.

    `sqlstate` recovers the code from the END, so anything appended past it
    makes the code silently unrecoverable — which is how three call sites in
    the SQLite package once came to raise without one.

    covers: O8
    """
    var text = describe_in(
        "exec", UNDEFINED_TABLE, 'relation "t" does not exist', "SELECT * FROM t"
    )
    assert_true("[SELECT * FROM t]" in text)
    assert_true(text.endswith("(sqlstate=42P01)"))
    assert_equal(sqlstate(text), UNDEFINED_TABLE)


def test_a_message_with_no_code_recovers_nothing() raises:
    """An error raised where no result carried a state has none to report.

    covers: O8
    """
    assert_equal(sqlstate("could not connect to postgres://db/x: refused"), "")
    assert_equal(sqlstate(""), "")
    assert_equal(sqlstate("(sqlstate=)"), "")
    # A truncated or malformed field is not a state either.
    assert_equal(sqlstate("something (sqlstate=42P0)"), "")


def test_an_error_with_no_state_still_reads_as_an_error() raises:
    """A connection-level failure has no PGresult and so no SQLSTATE.

    covers: O8
    """
    var text = describe("exec", String(""), "server closed the connection")
    assert_true("server closed the connection" in text)
    assert_false("sqlstate" in text)


def test_an_empty_message_says_so_rather_than_reading_as_success() raises:
    """A blank message is named, not left as an empty error.

    covers: O8
    """
    var text = describe("exec", UNIQUE_VIOLATION, "   ")
    assert_true("(no message)" in text)


def test_the_two_predicates_name_the_classes_they_claim() raises:
    """Retry means class 40; lost means class 08 or a shutdown.

    Named once here so an application's own policy asks a function rather
    than carrying five-character literals.

    covers: O8
    """
    assert_true(is_retryable(SERIALIZATION_FAILURE))
    assert_true(is_retryable(DEADLOCK_DETECTED))
    assert_false(is_retryable(UNIQUE_VIOLATION))
    assert_false(is_retryable(QUERY_CANCELED))

    assert_true(is_connection_lost(CONNECTION_FAILURE))
    assert_true(is_connection_lost(ADMIN_SHUTDOWN))
    assert_false(is_connection_lost(TOO_MANY_CONNECTIONS))
    assert_false(is_connection_lost(UNIQUE_VIOLATION))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
