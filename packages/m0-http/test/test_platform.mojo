"""The platform seam: one place chooses the OS multiplexer.

`lightbug_http/c/platform.mojo` names `PlatformBackend` (kqueue on macOS,
epoll on Linux) and the two libc constants whose values differ between
them. These tests prove the alias is a real backend on THIS operating
system -- constructible through the trait-declared initializer, owning a
multiplexer fd -- and that the constants are the ones this OS needs. The
other half of the guarantee, that no other file chooses a backend, is
`scripts/check_docs.py::check_backend_seam`, a rule over the tree's text.
"""

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, TestSuite

from lightbug_http.c.platform import (
    MSG_DONTWAIT,
    PlatformBackend,
    SC_NPROCESSORS_ONLN,
)


def test_platform_backend_is_a_constructible_multiplexer() raises:
    """`PlatformBackend()` resolves to the trait's initializer and opens the
    OS multiplexer: a non-negative fd, distinct across two instances.

    covers: E12
    """
    var a = PlatformBackend()
    var b = PlatformBackend()
    assert_true(a.multiplexer_fd() >= 0)
    assert_true(b.multiplexer_fd() >= 0)
    assert_true(a.multiplexer_fd() != b.multiplexer_fd())


def test_platform_constants_are_this_operating_systems() raises:
    """The seam's constants match the OS the test runs on, and the sysconf
    name it exports really answers: a count of at least one CPU.
    """
    comptime if CompilationTarget.is_macos():
        assert_equal(Int(MSG_DONTWAIT), 0x80)
        assert_equal(SC_NPROCESSORS_ONLN, 58)
    else:
        assert_equal(Int(MSG_DONTWAIT), 0x40)
        assert_equal(SC_NPROCESSORS_ONLN, 84)
    var cpus = external_call["sysconf", Int](Int(SC_NPROCESSORS_ONLN))
    assert_true(cpus >= 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
