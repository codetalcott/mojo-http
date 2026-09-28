"""The one error the socket wrappers raise: the call that failed, and its errno.

Every wrapper in `c/socket.mojo` raises a `SysError` whenever its call
reports a failure, whatever the errno. The upstream wrappers gave each errno
a man page lists a type of its own -- 109 of them, and 14 variants over
those -- and returned normally for any errno their list did not name, so
`socket()` handed back -1 as a descriptor and `listen()` on a connected
socket reported success (review record B9). A caller that tells failures
apart asks the error: `would_block()`, `interrupted()`,
`connection_aborted()`, `address_in_use()`, or `errno` itself.
"""

from std.ffi import ErrNo


@fieldwise_init
struct SysError(Copyable, Movable, Writable, TrivialRegisterPassable):
    """A failed system call: its name and the errno it set.

    Written as `op: strerror (errno N)`, for example
    `listen: Invalid argument (errno 22)`.
    """

    var op: StaticString
    """The call that failed, by its C name: `"accept"`, `"send"`."""

    var errno: ErrNo
    """What the call set `errno` to."""

    def would_block(self) -> Bool:
        """EAGAIN or EWOULDBLOCK: a non-blocking call had nothing to do yet.

        POSIX lets the two be different values, so both are tested.
        """
        return self.errno == ErrNo.EAGAIN or self.errno == ErrNo.EWOULDBLOCK

    def interrupted(self) -> Bool:
        """EINTR: a signal arrived before the call could finish."""
        return self.errno == ErrNo.EINTR

    def connection_aborted(self) -> Bool:
        """ECONNABORTED: `accept` dequeued a connection its client had reset."""
        return self.errno == ErrNo.ECONNABORTED

    def address_in_use(self) -> Bool:
        """EADDRINUSE: `bind` found the address taken."""
        return self.errno == ErrNo.EADDRINUSE

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(self.op, ": ", self.errno, " (errno ", self.errno.value, ")")
