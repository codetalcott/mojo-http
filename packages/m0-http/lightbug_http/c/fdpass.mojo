"""`sendmsg`/`recvmsg` with `SCM_RIGHTS`: hand an open descriptor to another
process over an `AF_UNIX` socket.

The one caller is `accept_share.mojo`: the worker that won an `accept` on
the shared listener gives the connection to a sibling that has fewer, and
the kernel installs a fresh descriptor for the same open file in the
receiver. Nothing about the connection changes — same socket, same peer,
same bytes in its buffer — only which process answers it.

Two C layouts differ between the platforms this builds on, and both are
spelled out here rather than derived:

- `struct msghdr` is 56 bytes on Linux and 48 on macOS, which declares
  `msg_iovlen` as `int` and `msg_controllen` as `socklen_t` where glibc
  uses `size_t`. On a little-endian 64-bit target a `UInt64` field written
  with a small value sets the 32-bit member and zeroes the four bytes
  above it. Above `msg_iovlen` those are padding. Above `msg_controllen`
  they are macOS's `msg_flags`, its struct's last member, so the seventh
  word lies past the end of macOS's struct and its kernel never writes it.
  One seven-word struct serves both for everything but reading
  `msg_flags` back, which `recv_fd` takes from the sixth word's high half
  on macOS (measured with `offsetof`: flags at 44 there, 48 on Linux).
  Every header starts from zeros. The same single-definition hazard
  `sockaddr` and `set_nonblocking` document.
- `struct cmsghdr` genuinely differs: macOS opens with a 4-byte
  `socklen_t cmsg_len` (header 12, `CMSG_SPACE(int)` 16), Linux with an
  8-byte `size_t` (header 16, `CMSG_SPACE(int)` 24). The fd sits right
  after the header on both, at `_CMSG_HDR`.
"""

from std.ffi import c_int, c_ssize_t, external_call
from std.sys.info import CompilationTarget

from lightbug_http.c.platform import MSG_DONTWAIT
from lightbug_http.c.fcntl import mark_fresh_cloexec
from lightbug_http.c.pipe import close_fd

comptime _MSG_CMSG_CLOEXEC_LINUX = 0x40000000
from lightbug_http.c.socket import SOL_SOCKET, iovec_t


comptime _SCM_RIGHTS = 1
comptime _CMSG_HDR = 12 if CompilationTarget.is_macos() else 16
"""`sizeof(struct cmsghdr)`: where the passed fd's four bytes begin."""
comptime _CMSG_LEN_INT = _CMSG_HDR + 4
"""`CMSG_LEN(sizeof(int))`: the header plus one fd, unpadded."""
comptime _CMSG_SPACE_INT = 16 if CompilationTarget.is_macos() else 24
"""`CMSG_SPACE(sizeof(int))`: one fd's control message, padded."""
comptime _MSG_CTRUNC = 0x20 if CompilationTarget.is_macos() else 0x08
"""`msg_flags` bit: the control buffer was too small for what the message
carried. 0x20 in macOS's `<sys/socket.h>` but 0x08 in Linux's
`<bits/socket.h>`, where 0x20 is `MSG_TRUNC`: the data bit, set when a
datagram is longer than its buffer, which costs the payload's tail and
never the descriptor."""

comptime FDPASS_MAX_PAYLOAD = 64
"""The most data bytes a passed descriptor travels with. The caller's
payload is the peer address the acceptor already decoded — a port and an
IPv4 dotted quad — so the receiver need not `getpeername` it again."""

comptime RECV_FD_EMPTY = -1
"""`recv_fd` took nothing off the channel: nothing was waiting (EAGAIN), or
the receive itself failed. A drain stops here."""

comptime RECV_FD_REFUSED = -2
"""`recv_fd` took a datagram off the channel that carried no descriptor to
hand over: none at all, more than `send_fd` sends, or one the kernel could
not install in this process. That datagram is gone and the ones queued
behind it are not, so a drain skips it and goes on."""


@fieldwise_init
struct _msghdr(TrivialRegisterPassable):
    """`struct msghdr` as seven 64-bit words; see the module docstring."""
    var msg_name: UInt64
    var msg_namelen: UInt64
    var msg_iov: UInt64
    var msg_iovlen: UInt64
    var msg_control: UInt64
    var msg_controllen: UInt64
    var msg_flags: UInt64


def _sendmsg[
    origin: ImmOrigin
](fd: c_int, msg: Pointer[_msghdr, origin], flags: c_int) -> c_ssize_t:
    return external_call[
        "sendmsg", c_ssize_t, c_int, type_of(msg), c_int
    ](fd, msg, flags)


def _recvmsg[
    origin: MutOrigin
](fd: c_int, msg: Pointer[_msghdr, origin], flags: c_int) -> c_ssize_t:
    return external_call[
        "recvmsg", c_ssize_t, c_int, type_of(msg), c_int
    ](fd, msg, flags)


def send_fd(channel: Int, fd: Int, payload: List[UInt8]) -> Bool:
    """Send `fd` and up to `FDPASS_MAX_PAYLOAD` bytes of `payload` on the
    `AF_UNIX` socket `channel`, without blocking.

    False on any failure — EAGAIN when the receiver's buffer is full is the
    one that matters, and the caller keeps the connection for itself. The
    sender still owns its `fd` afterwards and closes it; the in-flight
    reference the kernel holds keeps the open file alive until the
    receiver reads it (or the channel itself is closed).
    """
    var n = len(payload)
    if n > FDPASS_MAX_PAYLOAD:
        n = FDPASS_MAX_PAYLOAD
    var data = List[UInt8](capacity=FDPASS_MAX_PAYLOAD + 1)
    for i in range(n):
        data.append(payload[i])
    if n == 0:
        # A zero-length datagram is legal but reads as EOF on some stacks;
        # always carry at least one byte.
        data.append(0)
        n = 1
    var control = List[UInt8](capacity=_CMSG_SPACE_INT)
    for _ in range(_CMSG_SPACE_INT):
        control.append(0)
    # cmsg_len, cmsg_level, cmsg_type, then the fd — little-endian stores.
    _store_u32(control, 0, UInt32(_CMSG_LEN_INT))
    comptime if CompilationTarget.is_macos():
        _store_u32(control, 4, UInt32(SOL_SOCKET))
        _store_u32(control, 8, UInt32(_SCM_RIGHTS))
    else:
        _store_u32(control, 4, 0)  # the high half of a size_t cmsg_len
        _store_u32(control, 8, UInt32(SOL_SOCKET))
        _store_u32(control, 12, UInt32(_SCM_RIGHTS))
    _store_u32(control, _CMSG_HDR, UInt32(fd))
    var iov = iovec_t(UInt(Int(data.unsafe_ptr())), UInt(n))
    var iov_ptr = Pointer(to=iov)
    var hdr = _msghdr(
        0, 0, UInt64(Pointer(to=iov_ptr).unsafe_bitcast[Int]()[]), 1,
        UInt64(Int(control.unsafe_ptr())), UInt64(_CMSG_SPACE_INT), 0,
    )
    var rc = _sendmsg(c_int(channel), Pointer(to=hdr), MSG_DONTWAIT)
    _ = iov
    _ = data
    _ = control
    return Int(rc) >= 0


def recv_fd(channel: Int, mut payload: List[UInt8]) -> Int:
    """Receive one passed descriptor from the non-blocking `channel`,
    without blocking for one to arrive.

    Returns the new fd (this process's own reference), with the datagram's
    data bytes in `payload`; `RECV_FD_EMPTY` when nothing was taken off the
    channel; `RECV_FD_REFUSED` when a datagram was, carrying no descriptor
    to hand over. The two used to be one -1, and a drain that read a
    refusal as an empty channel stopped with hand-offs still queued behind
    it and no edge left to announce them.

    A refusal is what a receiver out of descriptors sees, with nothing
    wrong on the sending side: the kernel cannot install the descriptor,
    so macOS fails that receive with EMSGSIZE and leaves the datagram's
    data queued without it, and Linux delivers the data with `MSG_CTRUNC`
    set and nothing installed (both measured).

    The kernel installs a passed descriptor in this process when the
    message is received, so every one that reaches the control buffer is
    this function's to return or to close: one it drops is open for the
    life of the process, and a handed-over connection's client waits on it
    forever. A message whose control data was cut short (`MSG_CTRUNC`)
    carried more than the one descriptor `send_fd` passes, and is refused,
    each of its descriptors in the buffer closed. What did not fit, Linux
    releases; macOS installs it too, with its number lost (measured), where
    nothing can close it -- which a sender of one never causes. A payload
    cut short (`MSG_TRUNC`) keeps its descriptor, as `send_fd`'s own cap
    does, and so does a datagram with no payload at all: a read of 0 bytes
    that brought a descriptor is a zero-length datagram, whose descriptor
    was installed like any other (it was left open, and -1 returned). A
    read of 0 that brought nothing is taken as nothing received -- a
    zero-length datagram cannot be told from a read side shut down, which
    reads 0 forever, and no drain may spin on that.
    """
    payload.clear()
    var data = List[UInt8](capacity=FDPASS_MAX_PAYLOAD)
    for _ in range(FDPASS_MAX_PAYLOAD):
        data.append(0)
    var control = List[UInt8](capacity=_CMSG_SPACE_INT)
    for _ in range(_CMSG_SPACE_INT):
        control.append(0)
    var iov = iovec_t(UInt(Int(data.unsafe_ptr())), UInt(FDPASS_MAX_PAYLOAD))
    var iov_ptr = Pointer(to=iov)
    var hdr = _msghdr(
        0, 0, UInt64(Pointer(to=iov_ptr).unsafe_bitcast[Int]()[]), 1,
        UInt64(Int(control.unsafe_ptr())), UInt64(_CMSG_SPACE_INT), 0,
    )
    # Close-on-exec (SPEC G16): a handed-over connection is a client's like
    # any other. Born that way on Linux; macOS has no MSG_CMSG_CLOEXEC and
    # marks it right after, below.
    #
    # macOS receives without MSG_DONTWAIT, on a channel that must be
    # non-blocking, as every caller's is (`set_nonblocking`). XNU's receive
    # takes the buffer's lock first, and MSG_DONTWAIT makes it fail EAGAIN
    # when the lock is held rather than wait; being non-blocking only makes
    # an EMPTY buffer fail. Accept sharing keeps each channel's read end in
    # flight (`AcceptShare._anchor_channels`), so the kernel's collector of
    # descriptors in flight scans the channel's buffer, holding that lock,
    # and a receive that met a scan failed with a datagram queued: 5 in
    # 3000 hand-offs, measured with another process closing AF_UNIX sockets
    # throughout, and none without the flag. A drain read the failure as an
    # empty channel. Waiting for the lock is waiting out a scan, never for
    # data.
    var recv_flags: c_int
    comptime if CompilationTarget.is_macos():
        recv_flags = c_int(0)
    else:
        recv_flags = MSG_DONTWAIT | c_int(_MSG_CMSG_CLOEXEC_LINUX)
    var rc = _recvmsg(c_int(channel), Pointer(to=hdr), recv_flags)
    var got = RECV_FD_EMPTY
    if Int(rc) >= 0:
        for i in range(Int(rc)):
            payload.append(data[i])
        var flags: Int
        comptime if CompilationTarget.is_macos():
            # The high half of the sixth word: see the module docstring.
            flags = Int(hdr.msg_controllen >> 32)
        else:
            flags = Int(hdr.msg_flags & 0xFFFFFFFF)
        var clen = Int(hdr.msg_controllen & 0xFFFFFFFF)
        var passed = _passed_fds(control, clen)
        var truncated = (flags & _MSG_CTRUNC) != 0
        # A datagram was taken if it brought bytes or control data.
        if Int(rc) > 0 or len(passed) > 0 or truncated:
            got = RECV_FD_REFUSED
        if len(passed) > 0 and not truncated:
            got = passed[0]
        for i in range(len(passed)):
            if passed[i] != got:
                close_fd(passed[i])
    comptime if CompilationTarget.is_macos():
        if got >= 0:
            mark_fresh_cloexec(got)
    _ = iov
    _ = data
    _ = control
    return got


def _passed_fds(control: List[UInt8], clen: Int) -> List[Int]:
    """The descriptors an `SCM_RIGHTS` message put in `control`: those in
    the `clen` bytes the kernel filled, which is fewer than the header's
    `cmsg_len` claims when the message was cut short."""
    var fds = List[Int]()
    if clen < _CMSG_LEN_INT:
        return fds^
    var level: Int
    var kind: Int
    comptime if CompilationTarget.is_macos():
        level = Int(_load_u32(control, 4))
        kind = Int(_load_u32(control, 8))
    else:
        level = Int(_load_u32(control, 8))
        kind = Int(_load_u32(control, 12))
    if level != SOL_SOCKET or kind != _SCM_RIGHTS:
        return fds^
    # `cmsg_len` is a `size_t` on Linux; its low half is the whole value.
    var end = min(Int(_load_u32(control, 0)), min(clen, len(control)))
    var at = _CMSG_HDR
    while at + 4 <= end:
        fds.append(Int(_load_u32(control, at)))
        at += 4
    return fds^


def _store_u32(mut buf: List[UInt8], offset: Int, value: UInt32):
    var v = value
    for i in range(4):
        buf[offset + i] = UInt8(v & 0xFF)
        v >>= 8


def _load_u32(buf: List[UInt8], offset: Int) -> UInt32:
    var v: UInt32 = 0
    for i in range(4):
        v |= UInt32(buf[offset + i]) << UInt32(8 * i)
    return v
