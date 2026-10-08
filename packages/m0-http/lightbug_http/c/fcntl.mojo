"""`fcntl(2)`: its one declaration in the program, and the descriptor and
file-status flags built on it.

One declaration because `fcntl` is variadic and Darwin arm64 passes a
variadic argument on the stack (see `_fcntl`), and because a second
`external_call["fcntl"]` with another signature does not compile. It lives
here, importing nothing from this package, so the lowest layers (`socket`,
`socketpair`, `pipe`, `fdpass`, `epoll`) can mark what they create
close-on-exec, and anything can make a descriptor non-blocking, without
an import cycle.

The variadic libc functions the fork calls on Darwin are `fcntl` here and
`shm_open` (`_shm_open` in `c/process.mojo`), and each takes `_fcntl`'s
shape there, its variadic arguments declared after dummies that fill
x0-x7 so that they land on the stack, as any variadic function added
later must.
"""

from std.ffi import c_int, external_call, get_errno
from std.sys.info import CompilationTarget

comptime F_GETFD = 1
comptime F_SETFD = 2
comptime F_GETFL = 3
comptime F_SETFL = 4
comptime FD_CLOEXEC = 1
comptime F_DUPFD_CLOEXEC = 67 if CompilationTarget.is_macos() else 1030

comptime O_NONBLOCK = 0x4 if CompilationTarget.is_macos() else 0x800
"""The file-status flag `set_nonblocking` sets. Linux's `TFD_NONBLOCK` is
this value (its headers define it as `O_NONBLOCK`)."""

comptime O_CLOEXEC = 0x1000000 if CompilationTarget.is_macos() else 0x80000
"""Close-on-exec at creation. On Linux `SOCK_CLOEXEC`, `EPOLL_CLOEXEC` and
`TFD_CLOEXEC` are this value (its headers define each as `O_CLOEXEC`), so
`socket`, `accept4`, `socketpair`, `pipe2`, `epoll_create1` and
`timerfd_create` take it as it is. macOS refuses it in a socket type
(EPROTONOSUPPORT, measured): there the creation helpers mark the
descriptor with `F_SETFD` right after."""


def _fcntl(fd: c_int, cmd: c_int, arg: c_int = 0) -> c_int:
    """Raw fcntl(fd, cmd, arg) — single signature to avoid conflicting declarations.

    fcntl is variadic (int fcntl(int, int, ...)), and the two major ABIs
    disagree about what that means for the third argument:

    - x86-64 SysV and AAPCS64-Linux pass leading variadic args in the same
      registers as fixed args, so a plain three-argument declaration works.
    - Darwin ARM64 passes ALL variadic arguments on the stack; fixed
      arguments fill x0–x7 first. A three-argument call puts `arg` in x2,
      the callee's va_list never sees it, and F_SETFL silently reads
      whatever the stack happened to hold — historically making
      `set_nonblocking` a no-op there.

    The Darwin branch therefore declares NINE fixed arguments: fd and cmd
    land in x0/x1, six zero dummies burn x2–x7, and the ninth — the real
    arg — is forced onto the stack at sp+0, exactly where a variadic
    callee's va_list points after two named parameters. The dummies are
    never read by fcntl; only the stack slot is. `test_broadcast.mojo`
    asserts F_GETFL reflects O_NONBLOCK after `set_nonblocking`, which is
    what holds this ABI claim to account on the macOS CI runner.
    """
    comptime if CompilationTarget.is_macos():
        return external_call[
            "fcntl", c_int,
            c_int, c_int, Int, Int, Int, Int, Int, Int, Int,
        ](fd, cmd, 0, 0, 0, 0, 0, 0, Int(arg))
    else:
        return external_call["fcntl", c_int, c_int, c_int, c_int](fd, cmd, arg)


def set_cloexec(fd: Int) raises:
    """Mark `fd` close-on-exec: a process started with `exec` from this one,
    or from any thread of it, does not inherit it."""
    var flags = _fcntl(c_int(fd), c_int(F_GETFD))
    if flags == -1:
        raise Error("fcntl F_GETFD failed, errno: ", get_errno())
    if (Int(flags) & FD_CLOEXEC) != 0:
        return
    if _fcntl(c_int(fd), c_int(F_SETFD), flags | c_int(FD_CLOEXEC)) == -1:
        raise Error("fcntl F_SETFD failed, errno: ", get_errno())


def is_cloexec(fd: Int) raises -> Bool:
    """Whether `fd` is close-on-exec: `F_GETFD` truth, not what a caller hoped."""
    var flags = _fcntl(c_int(fd), c_int(F_GETFD))
    if flags == -1:
        raise Error("fcntl F_GETFD failed, errno: ", get_errno())
    return (Int(flags) & FD_CLOEXEC) != 0


def clear_cloexec(fd: Int) -> Bool:
    """Let `fd` survive `exec`. False if it is not open."""
    var flags = _fcntl(c_int(fd), c_int(F_GETFD))
    if flags < 0:
        return False
    if (Int(flags) & FD_CLOEXEC) == 0:
        return True
    return _fcntl(c_int(fd), c_int(F_SETFD), c_int(Int(flags) & ~FD_CLOEXEC)) == 0


def dup_cloexec(fd: Int) raises -> Int:
    """`dup(2)`, close-on-exec atomically: `F_DUPFD_CLOEXEC`, on both platforms."""
    var rc = _fcntl(c_int(fd), c_int(F_DUPFD_CLOEXEC), c_int(0))
    if rc < 0:
        raise Error("fcntl F_DUPFD_CLOEXEC failed, errno: ", get_errno())
    return Int(rc)


def set_nonblocking(fd: FileDescriptor) raises:
    """Set a file descriptor to non-blocking mode via fcntl().

    Works on both platforms — including ARM64 macOS, where this was a
    silent no-op until `_fcntl` learned the Darwin variadic convention (see
    its docstring). Callers written while the no-op stood carry their own
    belt-and-braces (MSG_DONTWAIT on the broadcast bus, event_data-based
    accept counting on the listen socket); those stay, because they are
    also correct and they document the history.
    """
    var fd_c = c_int(fd.value)
    var flags = _fcntl(fd_c, c_int(F_GETFL))
    if flags == -1:
        var errno = get_errno()
        raise Error("fcntl F_GETFL failed, errno: ", errno)
    var result = _fcntl(fd_c, c_int(F_SETFL), flags | c_int(O_NONBLOCK))
    if result == -1:
        var errno = get_errno()
        raise Error("fcntl F_SETFL failed, errno: ", errno)


def is_nonblocking(fd: FileDescriptor) raises -> Bool:
    """Whether O_NONBLOCK is set — F_GETFL truth, not what a caller hoped.

    F_GETFL takes no variadic argument, so it has always been reliable on
    every platform; that is what makes this the right probe for asserting
    `set_nonblocking` actually took effect.
    """
    var flags = _fcntl(c_int(fd.value), c_int(F_GETFL))
    if flags == -1:
        var errno = get_errno()
        raise Error("fcntl F_GETFL failed, errno: ", errno)
    return (Int(flags) & O_NONBLOCK) != 0
