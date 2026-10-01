"""An application's scalar function, compiled against `m0_sqlite.mojoc`.

`poe check-sqlite-function` runs this with only `-I packages/m0-sqlite`, so
every name below resolves through the compiled package. m0-sqlite's own tests
import `src.*` from source and cannot see two failures that live only behind
the `.mojoc`: a conformance to a trait of the package losing its witness
table (the D28 bug, which a package compiled from `src/` hit on Mojo 1.0,
and which `check-mojoc-trait` guards for m0-http), and the one global word
`function.mojo` publishes the library through not surviving the precompile
(the stores an application makes must be the ones the package's callbacks
read). Either one fails here: the first as a compile error, the second as a
registration the package refuses or a call that answers nothing.

Prints one line and exits 0 when both hold; raises otherwise.
"""

from m0_sqlite import Args, Answer, ScalarFunction, open_memory


struct Scaled(ScalarFunction):
    """`scaled(x)`: x times the factor the instance was built with."""

    comptime arity: Int = 1
    comptime deterministic: Bool = True
    var factor: Int

    def __init__(out self, factor: Int):
        self.factor = factor

    def call(self, args: Args, mut answer: Answer) raises:
        answer.int(args.int(0) * self.factor)


struct Length(ScalarFunction):
    """`length_of(b)`: a blob's length, read where SQLite holds it."""

    comptime arity: Int = 1
    comptime deterministic: Bool = True

    def __init__(out self):
        pass

    def call(self, args: Args, mut answer: Answer) raises:
        answer.int(len(args.blob(0)))


def main() raises:
    var first = open_memory()
    first.create_function("scaled", Scaled(3))
    var second = open_memory()
    second.create_function("length_of", Length())
    var a = first.query_scalar("SELECT scaled(14)")
    var b = second.query_scalar("SELECT length_of(x'00010203')")
    if a != "42" or b != "4":
        raise Error(
            "check-sqlite-function: an application's function answered "
            + a + " and " + b + ", not 42 and 4"
        )
    print("check-sqlite-function: an application's functions register and answer through m0_sqlite.mojoc")
