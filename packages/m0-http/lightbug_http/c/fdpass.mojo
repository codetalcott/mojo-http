"""`sendmsg`/`recvmsg` with `SCM_RIGHTS`: hand an open descriptor to another
process over an `AF_UNIX` socket.

The one caller is `accept_share.mojo`: the worker that won an `accept` on
the shared listener gives the connection to a sibling that has fewer, and
the kernel installs a fresh descriptor for the same open file in the
receiver. Nothing about the connection changes — same socket, same peer,
same bytes in its buffer — only which process answers it.

Two C layouts differ between the platforms this builds on, and both are
spelled out here rather than derived:

- `struct msghdr` is 56 bytes on both, but macOS declares `msg_iovlen` as
  `int` and `msg_controllen` as `socklen_t` where glibc uses `size_t`. On
  a little-endian 64-bit target a `UInt64` field written with a small
  value sets the 32-bit member and zeroes the padding beside it, and
  reading a 32-bit member the kernel wrote through the same `UInt64`
  returns it as long as the padding was zero going in — so one seven-word
  struct serves both, and every header starts from zeros. The same
  single-definition hazard `sockaddr` and `set_nonblocking` document.
- `struct cmsghdr` genuinely differs: macOS opens with a 4-byte
  `socklen_t cmsg_len` (header 12, `CMSG_SPACE(int)` 16), Linux with an
  8-byte `size_t` (header 16, `CMSG_SPACE(int)` 24). The fd sits right
  after the header on both, at `_CMSG_HDR`.
"""

from std.ffi import c_int, c_ssize_t, external_call, get_errno
from std.sys.info import CompilationTarget

from lightbug_http.c.platform import MSG_DONTWAIT
from lightbug_http.c.socket import iovec_t


comptime _SOL_SOCKET = 0xFFFF if CompilationTarget.is_macos() else 1
comptime _SCM_RIGHTS = 1
comptime _CMSG_HDR = 12 if CompilationTarget.is_macos() else 16
"""`sizeof(struct cmsghdr)`: where the passed fd's four bytes begin."""
comptime _CMSG_LEN_INT = _CMSG_HDR + 4
"""`CMSG_LEN(sizeof(int))`: the header plus one fd, unpadded."""
comptime _CMSG_SPACE_INT = 16 if CompilationTarget.is_macos() else 24
"""`CMSG_SPACE(sizeof(int))`: one fd's control message, padded."""
comptime _MSG_CTRUNC = 0x20
"""`msg_flags` bit: the control buffer was too small and the kernel
dropped (and closed) what did not fit. Same value on both platforms."""

comptime FDPASS_MAX_PAYLOAD = 64
"""The most data bytes a passed descriptor travels with. The caller's
payload is the peer address the acceptor already decoded — a port and an
IPv4 dotted quad — so the receiver need not `getpeername` it again."""


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
        _store_u32(control, 4, UInt32(_SOL_SOCKET))
        _store_u32(control, 8, UInt32(_SCM_RIGHTS))
    else:
        _store_u32(control, 4, 0)  # the high half of a size_t cmsg_len
        _store_u32(control, 8, UInt32(_SOL_SOCKET))
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
    """Receive one passed descriptor from `channel`, without blocking.

    Returns the new fd (this process's own reference), with the datagram's
    data bytes in `payload`; -1 when nothing is waiting (EAGAIN), the
    channel is closed, or a datagram arrived carrying no descriptor — a
    truncated control message (`MSG_CTRUNC`) is treated as no descriptor,
    the kernel having already closed whatever it dropped.
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
    var rc = _recvmsg(c_int(channel), Pointer(to=hdr), MSG_DONTWAIT)
    var got = -1
    if Int(rc) > 0:
        for i in range(Int(rc)):
            payload.append(data[i])
        var flags = Int(hdr.msg_flags & 0xFFFFFFFF)
        var clen = Int(hdr.msg_controllen & 0xFFFFFFFF)
        if (flags & _MSG_CTRUNC) == 0 and clen >= _CMSG_LEN_INT:
            var level: Int
            var kind: Int
            comptime if CompilationTarget.is_macos():
                level = Int(_load_u32(control, 4))
                kind = Int(_load_u32(control, 8))
            else:
                level = Int(_load_u32(control, 8))
                kind = Int(_load_u32(control, 12))
            if level == _SOL_SOCKET and kind == _SCM_RIGHTS:
                got = Int(_load_u32(control, _CMSG_HDR))
    _ = iov
    _ = data
    _ = control
    return got


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
