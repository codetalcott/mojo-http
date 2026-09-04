"""The one place the operating system is chosen.

`m0-http` serves on kqueue (macOS) and epoll (Linux), and until this module
existed the choice was spelled out wherever a backend was constructed --
five sites across `server.mojo`, `m0serve.mojo`, `threaded.mojo` and
`asgi_executor.mojo`, each a `comptime if CompilationTarget.is_macos()`
with the import inside the branch -- plus three private copies of the
`MSG_DONTWAIT` flag whose value differs between the two libcs. A variant of
one backend (a Darwin wake primitive for the in-memory handoff, say) would
have had to be threaded through every site. Now it plugs in here.

`PlatformBackend` is a conditional type alias, which Mojo 1.0 accepts as a
type parameter (`DetachingBackend[PlatformBackend]`) and as a variable
type, but can only CONSTRUCT through an initializer a shared trait
declares: `PlatformBackend()` resolves to `ConstructibleBackend.__init__`,
the only initializer the two arms have in common by name. A factory that
returns the alias does not compile (the arms are not implicitly convertible
to the alias, and `rebind` needs a copyable value, which an fd-owning
backend is not), which is why the trait carries the initializer rather
than this module carrying a `make_backend()`.

Both backend modules are imported unconditionally, on both platforms. That
is already the case for `c/kqueue.mojo` (imported by `broadcast.mojo`
everywhere for `set_nonblocking`); the syscall wrappers are only emitted
where a caller instantiates them, so the epoll arm costs macOS nothing and
the kqueue arm costs Linux nothing.

`scripts/check_docs.py::check_backend_seam` refuses a backend constructed
anywhere but here, so the five sites cannot quietly come back.
"""

from std.ffi import c_int
from std.sys.info import CompilationTarget

from lightbug_http.c.epoll_backend import EpollBackend
from lightbug_http.c.kqueue_backend import KqueueBackend


comptime PlatformBackend = KqueueBackend if CompilationTarget.is_macos() else EpollBackend
"""The event-loop backend this build serves on: kqueue on macOS, epoll on Linux."""

comptime MSG_DONTWAIT = c_int(0x80) if CompilationTarget.is_macos() else c_int(0x40)
"""`recv`/`send` flag for a non-blocking call on a possibly-blocking fd.

BSD and glibc number it differently (0x80 and 0x40). Passed per call, so
a datagram channel can be polled without changing the fd's own state.
"""

comptime SC_NPROCESSORS_ONLN = 58 if CompilationTarget.is_macos() else 84
"""`sysconf` name for the online logical CPU count: macOS 58, glibc 84."""
