"""Every `CustomError` reads back as its `message` (review record LF29).

The trait's docstring promised default `write_to` and `__str__` methods it
did not have, and each conformer carried a hand-copied pair. `__str__` is
now the trait's. `write_to` cannot be: `Writable` already defaults it, to
the struct's name and fields, and Mojo 1.1 refuses a second default from a
refining trait. So each conformer keeps its own, and one that dropped it
would still compile and write `ParseEmptyAddressError()` where its message
belongs. These tests read both forms of every conformer back.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.address import (
    ParseEmptyAddressError,
    ParseEmptyPortError,
    ParseIPProtocolPortError,
    ParseInvalidPortNumberError,
    ParseMissingClosingBracketError,
    ParseMissingPortError,
    ParseMissingSeparatorError,
    ParsePortOutOfRangeError,
    ParseTooManyColonsError,
    ParseUnexpectedBracketError,
)
from lightbug_http.c.network import (
    InetNtopEAFNOSUPPORTError,
    InetNtopENOSPCError,
    InetPtonInvalidAddressError,
)
from lightbug_http.connection import AddressParseError, ListenerError
from lightbug_http.header import (
    EmptyBufferError,
    HeaderKeyNotFoundError,
    IncompleteHTTPRequestError,
    InvalidHTTPRequestError,
    RequestParseError,
    UnsupportedHTTPRequestError,
)
from lightbug_http.http.parsing import HTTPParseError, IncompleteError, ParseError
from lightbug_http.server import ProvisionError, ProvisionPoolExhaustedError, ServerError
from lightbug_http.utils.error import CustomError


def _reads_as_its_message[E: CustomError](e: E) raises:
    """`String(e)`, which `write_to` writes, and `__str__` are `message`."""
    assert_equal(String(e), E.message, "write_to does not write the message")
    assert_equal(e.__str__(), E.message, "__str__ is not the message")


@fieldwise_init
struct _OnlyItsMessage(CustomError, TrivialRegisterPassable):
    """A conformer that writes its message and declares nothing else."""

    comptime message = "only its message"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)


def test_a_conformer_gets_str_from_the_trait() raises:
    """A conformer declaring no `__str__` answers it with its message."""
    _reads_as_its_message(_OnlyItsMessage())


def test_every_address_error_reads_as_its_message() raises:
    """The ten listen-address parse errors."""
    _reads_as_its_message(ParseEmptyAddressError())
    _reads_as_its_message(ParseMissingClosingBracketError())
    _reads_as_its_message(ParseMissingPortError())
    _reads_as_its_message(ParseUnexpectedBracketError())
    _reads_as_its_message(ParseEmptyPortError())
    _reads_as_its_message(ParseInvalidPortNumberError())
    _reads_as_its_message(ParsePortOutOfRangeError())
    _reads_as_its_message(ParseMissingSeparatorError())
    _reads_as_its_message(ParseTooManyColonsError())
    _reads_as_its_message(ParseIPProtocolPortError())


def test_every_other_error_reads_as_its_message() raises:
    """The listener's, the provision pool's and the `inet_*` bindings'."""
    _reads_as_its_message(AddressParseError())
    _reads_as_its_message(ProvisionPoolExhaustedError())
    _reads_as_its_message(InetNtopEAFNOSUPPORTError())
    _reads_as_its_message(InetNtopENOSPCError())
    _reads_as_its_message(InetPtonInvalidAddressError())


def test_every_variant_error_writes_the_error_it_holds() raises:
    """The variant errors write the one they hold: a request parse's four
    kinds and its scanner's two, `Headers`' missing key, and the server's
    three arms, a listener's, the provision pool's and a plain `Error`
    (review audit A3)."""
    assert_equal(
        String(RequestParseError(InvalidHTTPRequestError())),
        "InvalidHTTPRequestError: Not a valid HTTP request",
    )
    assert_equal(
        String(RequestParseError(IncompleteHTTPRequestError())),
        "IncompleteHTTPRequestError: Incomplete HTTP request",
    )
    assert_equal(
        String(RequestParseError(EmptyBufferError())),
        "EmptyBufferError: No data available in buffer",
    )
    assert_equal(
        String(RequestParseError(UnsupportedHTTPRequestError())),
        "UnsupportedHTTPRequestError: Not implemented by this server",
    )
    assert_true(RequestParseError(EmptyBufferError()).isa[EmptyBufferError]())
    assert_false(RequestParseError(EmptyBufferError()).isa[InvalidHTTPRequestError]())
    assert_equal(String(HTTPParseError(ParseError())), "ParseError: Invalid HTTP syntax")
    assert_equal(String(HTTPParseError(IncompleteError())), "IncompleteError: Need more data")
    assert_true(HTTPParseError(IncompleteError()).isa[IncompleteError]())
    assert_false(HTTPParseError(IncompleteError()).isa[ParseError]())
    assert_equal(
        String(HeaderKeyNotFoundError()),
        "HeaderKeyNotFoundError: Key not found in headers",
    )
    assert_equal(
        String(ServerError(ListenerError(AddressParseError()))),
        AddressParseError.message,
    )
    assert_equal(
        String(ServerError(ProvisionError(ProvisionPoolExhaustedError()))),
        ProvisionPoolExhaustedError.message,
    )
    assert_equal(String(ServerError(Error("the loop stopped"))), "the loop stopped")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
