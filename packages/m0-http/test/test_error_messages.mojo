"""Every `CustomError` reads back as its `message` (review record LF29).

The trait's docstring promised default `write_to` and `__str__` methods it
did not have, and each conformer carried a hand-copied pair. `__str__` is
now the trait's. `write_to` cannot be: `Writable` already defaults it, to
the struct's name and fields, and Mojo 1.1 refuses a second default from a
refining trait. So each conformer keeps its own, and one that dropped it
would still compile and write `ParseEmptyAddressError()` where its message
belongs. These tests read both forms of every conformer back.
"""

from std.testing import TestSuite, assert_equal

from lightbug_http.address import (
    ParseEmptyAddressError,
    ParseEmptyPortError,
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
from lightbug_http.connection import AddressParseError
from lightbug_http.server import ProvisionPoolExhaustedError
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
    """The nine listen-address parse errors."""
    _reads_as_its_message(ParseEmptyAddressError())
    _reads_as_its_message(ParseMissingClosingBracketError())
    _reads_as_its_message(ParseMissingPortError())
    _reads_as_its_message(ParseUnexpectedBracketError())
    _reads_as_its_message(ParseEmptyPortError())
    _reads_as_its_message(ParseInvalidPortNumberError())
    _reads_as_its_message(ParsePortOutOfRangeError())
    _reads_as_its_message(ParseMissingSeparatorError())
    _reads_as_its_message(ParseTooManyColonsError())


def test_every_other_error_reads_as_its_message() raises:
    """The listener's, the provision pool's and the `inet_*` bindings'."""
    _reads_as_its_message(AddressParseError())
    _reads_as_its_message(ProvisionPoolExhaustedError())
    _reads_as_its_message(InetNtopEAFNOSUPPORTError())
    _reads_as_its_message(InetNtopENOSPCError())
    _reads_as_its_message(InetPtonInvalidAddressError())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
