"""`sendfile(2)` — move file bytes to a socket without a userspace round trip.

The two platforms disagree about almost everything except the name, so this
module exists to make them agree about the ONE thing a caller wants: "send
up to `count` bytes from `in_fd` at `offset` to `out_fd`; tell me how many
actually went and whether to come back."

    Linux   ssize_t sendfile(int out_fd, int in_fd, off_t *offset, size_t count)
            Returns bytes sent, or -1. Advances *offset itself when offset
            is non-NULL, and then does NOT move the file's own position.

    Darwin  int sendfile(int fd, int s, off_t offset, off_t *len,
                         struct sf_hdtr *hdtr, int flags)
            `fd` is the FILE and `s` the SOCKET — the opposite order to
            Linux's first two arguments, which is the easiest way to get
            this wrong. Returns 0 or -1, and reports the count through
            *len IN BOTH CASES. On EAGAIN it has still sent *len bytes.

That last line is the whole reason a partial send is not an error here. A
non-blocking socket will routinely take some bytes and then refuse the
rest; on Darwin that is `-1`/`EAGAIN` *with a positive `len`*, and a caller
that treats -1 as "nothing happened" would resend those bytes and corrupt
the response. `send_file` normalises both platforms onto the same answer:
bytes actually written, plus whether the caller should wait for writability
and continue.

No `hdtr` on the Darwin side. Linux has no equivalent, so a portable caller
has to be able to send its headers separately anyway; using the header
vector on one platform only would mean two different orderings to reason
about for no gain.
"""

from std.ffi import c_int, external_call, get_errno
from std.sys.info import CompilationTarget

from lightbug_http.io.bytes import Bytes


struct SendFileResult(Copyable, Movable):
    """What one `sendfile` call achieved.

    `sent` is bytes that reached the socket — trustworthy even when
    `again` is True, which is the Darwin subtlety this type exists to stop
    callers from rediscovering.
    """

    var sent: Int
    """Bytes written to the socket by this call. Never negative."""

    var again: Bool
    """The socket is full: wait for writability and call again from the
    advanced offset. Not an error."""

    var error: Bool
    """The call failed for a reason that is not EAGAIN/EINTR. A caller
    should close the connection."""

    def __init__(out self, sent: Int, again: Bool, error: Bool):
        self.sent = sent
        self.again = again
        self.error = error

    def failed(self) -> Bool:
        return self.error


def send_file(out_fd: Int, in_fd: Int, offset: Int, count: Int) -> SendFileResult:
    """Send up to `count` bytes of `in_fd` starting at `offset` to `out_fd`.

    Does not move either descriptor's file position: the offset is passed
    per call, so several responses may stream from one open file at once
    without a lock. The caller advances its own offset by `sent`.
    """
    if count <= 0:
        return SendFileResult(0, False, False)

    # The in/out parameter is a stack local addressed with `Pointer(to=)`
    # rather than a one-element heap allocation: the callee writes to it
    # before returning, so it never outlives this frame. That also keeps
    # this file off the warning ratchet, since `alloc` without a `Layout`
    # is deprecated with no replacement on this toolchain (the dead end
    # `c/socketpair.mojo` and `c/pipe.mojo` both record).
    comptime if CompilationTarget.is_macos():
        # Darwin: len is in/out — set to the request, read back as the
        # amount actually sent, on success AND on EAGAIN.
        var sent_len = Int64(count)
        var rc = external_call[
            "sendfile",
            c_int,
            c_int,
            c_int,
            Int64,
            type_of(Pointer(to=sent_len)),
            Int,
            c_int,
        ](
            c_int(in_fd),   # fd: the FILE
            c_int(out_fd),  # s:  the SOCKET
            Int64(offset),
            Pointer(to=sent_len),
            0,              # hdtr: none, see the module docstring
            c_int(0),
        )
        var wrote = Int(sent_len)
        if rc == 0:
            return SendFileResult(wrote, False, False)
        var err = get_errno()
        if err in [err.EAGAIN, err.EWOULDBLOCK, err.EINTR]:
            # `wrote` is real even here — that is the whole trap.
            return SendFileResult(wrote, True, False)
        return SendFileResult(wrote, False, True)
    else:
        # Linux: the offset is in/out and the return is the byte count.
        var off = Int64(offset)
        var rc = external_call[
            "sendfile", Int, c_int, c_int, type_of(Pointer(to=off)), Int
        ](c_int(out_fd), c_int(in_fd), Pointer(to=off), count)
        if rc >= 0:
            return SendFileResult(Int(rc), False, False)
        var err = get_errno()
        if err in [err.EAGAIN, err.EWOULDBLOCK, err.EINTR]:
            return SendFileResult(0, True, False)
        return SendFileResult(0, False, True)
