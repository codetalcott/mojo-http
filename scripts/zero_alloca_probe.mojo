"""The counterfactual behind `scripts/zero_alloca_check.py` (review B30).

Never run: `main` prints and returns. This file exists to be compiled to
LLVM IR beside m0serve's, and the check reads what the exported functions
below instantiate.

**The hazard.** `stack_allocation[N, T]()` reserves N values of `T`, so its
size is N times `T`'s. The fork's `c_void` is `NoneType`, whose size is
0, so `stack_allocation[4, c_void]()` reserves nothing at all: KGEN emits
`alloca {}, i64 4`, zero bytes. `inet_pton` allocated its address buffer
that way until review B30 and handed it to C, which wrote the four bytes of
an IPv4 address (sixteen of an IPv6 one) over whatever the stack held
beside it. Every `ListenConfig.listen` went through it. Most layouts left
the damage harmless; one corrupted a String `listen` was building and
crashed the process.

**Three arms.**

  - `zero_alloca_probe_inet4` and `zero_alloca_probe_inet6` call the fork's
    real `inet_pton` for each address family, so both instantiations are in
    the IR whatever m0serve reaches (it listens on IPv4 only). The check
    refuses a zero-size buffer in either.
  - `zero_alloca_probe_bare` is the old shape, spelled the way `inet_pton`
    spelled it, handed to the same C function. The check REQUIRES it to be
    refused. Without that half the gate would pass on a toolchain where
    `NoneType` had grown a byte, or on a reading of the IR that had
    stopped seeing allocas, and would have stopped being evidence of
    anything.
"""

from std.ffi import c_char, c_int, external_call
from std.memory import stack_allocation

from lightbug_http.c.address import AddressFamily
from lightbug_http.c.aliases import c_void
from lightbug_http.c.network import inet_pton


@export("zero_alloca_probe_inet4")
def zero_alloca_probe_inet4() abi("C") -> UInt32:
    """The fork's `inet_pton` for IPv4, as `Socket.bind` calls it."""
    try:
        return UInt32(inet_pton[AddressFamily.AF_INET](String("127.0.0.1")))
    except:
        return 0


@export("zero_alloca_probe_inet6")
def zero_alloca_probe_inet6() abi("C") -> UInt32:
    """The fork's `inet_pton` for IPv6."""
    try:
        return UInt32(inet_pton[AddressFamily.AF_INET6](String("::1")))
    except:
        return 0


@export("zero_alloca_probe_bare")
def zero_alloca_probe_bare() abi("C") -> Int:
    """`inet_pton`'s buffer before review B30: four `c_void`s, zero bytes,
    handed to C. The check must refuse it."""
    var src = String("127.0.0.1")
    var buffer = stack_allocation[4, c_void]()
    var rc = external_call["inet_pton", c_int](
        c_int(2), src.as_c_string_span().ptr(), buffer
    )
    _ = src
    return Int(rc)


def main():
    print(
        "scripts/zero_alloca_probe.mojo is compiled, not run --",
        "see scripts/zero_alloca_check.py",
    )
