"""
Result Type — Railway-Oriented Programming

Explicit success/failure handling for transformer pipelines.
Errors are carried as DATA through combinator chains, not exceptions.

Uses Optional[T] internally so Err() doesn't require a phantom default value.
"""

from std.collections import Optional


struct Result[T: Copyable & Movable & ImplicitlyDestructible & Writable](Copyable, Movable, Writable):
    """Explicit Result type for railway-oriented programming."""

    var ok: Bool
    var _value: Optional[Self.T]
    var _error: String

    fn __init__(out self, *, ok: Bool, val: Optional[Self.T], error: String = ""):
        self.ok = ok
        self._value = val.copy()
        self._error = error

    fn write_to[W: Writer](self, mut writer: W):
        """Write Result as Ok(...) or Err(...) for debugging."""
        if self.ok:
            writer.write("Ok(")
            if self._value:
                writer.write(self._value.value())
            writer.write(")")
        else:
            writer.write("Err(", self._error, ")")

    fn is_ok(self) -> Bool:
        return self.ok

    fn is_err(self) -> Bool:
        return not self.ok

    fn get_value(self) raises -> Self.T:
        """Get the success value. Raises if error."""
        if not self.ok:
            raise Error("Called get_value() on an Err Result: " + self._error)
        return self._value.value().copy()

    fn get_error(self) raises -> String:
        """Get the error message. Raises if Ok."""
        if self.ok:
            raise Error("Called get_error() on an Ok Result")
        return self._error

    fn value_or(self, default: Self.T) -> Self.T:
        """Get the value or a default if error."""
        if self.ok:
            return self._value.value().copy()
        return default.copy()


fn Ok[T: Copyable & Movable & ImplicitlyDestructible & Writable](val: T) -> Result[T]:
    """Construct a successful Result."""
    return Result[T](ok=True, val=Optional[T](val.copy()))


fn Err[T: Copyable & Movable & ImplicitlyDestructible & Writable](error: String) -> Result[T]:
    """Construct an error Result. No phantom default value needed."""
    return Result[T](ok=False, val=Optional[T](), error=error)


# ============================================================================
# Result Combinators
# ============================================================================


fn map_result[
    T: Copyable & Movable & ImplicitlyDestructible & Writable,
    U: Copyable & Movable & ImplicitlyDestructible & Writable,
    f: fn (T) -> U,
](result: Result[T]) -> Result[U]:
    """Map over a successful Result, leaving errors untouched."""
    if result.is_ok():
        try:
            return Ok[U](f(result.get_value()))
        except e:
            return Err[U](String(e))
    try:
        return Err[U](result.get_error())
    except:
        return Err[U]("unknown error")


fn flat_map_result[
    T: Copyable & Movable & ImplicitlyDestructible & Writable,
    U: Copyable & Movable & ImplicitlyDestructible & Writable,
    f: fn (T) -> Result[U],
](result: Result[T]) -> Result[U]:
    """FlatMap (bind) over a Result — monadic bind for chained operations."""
    if result.is_ok():
        try:
            return f(result.get_value())
        except e:
            return Err[U](String(e))
    try:
        return Err[U](result.get_error())
    except:
        return Err[U]("unknown error")
