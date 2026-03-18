"""
Array-Oriented Programming (AOP) Combinators

J/APL-style function combinators for expressing transformation patterns.
These enable declarative, point-free function composition in Mojo.

Notation:
  fork:  (f g h) x  →  (f x) g (h x)
  hook:  (f g) x    →  x f (g x)
  atop:  (f g) x    →  f(g(x))
  over:  (f g) x y  →  (g x) f (g y)
  under: (f g) x    →  g⁻¹(f(g(x)))
"""


# ============================================================================
# SK Combinators (foundational)
# ============================================================================


fn identity[T: Copyable & Movable & ImplicitlyDestructible](input: T) -> T:
    """Identity combinator (I combinator). Returns input unchanged."""
    return input.copy()


fn constant[
    T: Copyable & Movable & ImplicitlyDestructible,
    U: Copyable & Movable & ImplicitlyDestructible,
    val_fn: fn () -> T,
](ignored: U) -> T:
    """Constant combinator (K combinator).

    Pattern: K x y = x
    Returns a fixed value produced by val_fn, ignoring its argument.
    Uses a factory function since Mojo can't hold generic comptime values.
    """
    return val_fn()


# ============================================================================
# Fork Combinator
# ============================================================================


fn fork[
    T: Copyable & Movable & ImplicitlyDestructible,
    L: Copyable & Movable & ImplicitlyDestructible,
    R: Copyable & Movable & ImplicitlyDestructible,
    O: Copyable & Movable & ImplicitlyDestructible,
    left_fn: fn (T) -> L,
    middle_fn: fn (L, R) -> O,
    right_fn: fn (T) -> R,
](input: T) -> O:
    """Fork combinator — parallel execution with merge.

    Pattern: (f x) g (h x)
    Executes left and right on the same input, combines with middle.
    """
    var left_result = left_fn(input)
    var right_result = right_fn(input)
    return middle_fn(left_result, right_result)


# ============================================================================
# Hook Combinator
# ============================================================================


fn hook[
    T: Copyable & Movable & ImplicitlyDestructible,
    R: Copyable & Movable & ImplicitlyDestructible,
    O: Copyable & Movable & ImplicitlyDestructible,
    left_fn: fn (T, R) -> O,
    right_fn: fn (T) -> R,
](input: T) -> O:
    """Hook combinator — monadic hook.

    Pattern: x f (g x)
    Applies right to input, then left receives both original and transformed.
    """
    var right_result = right_fn(input)
    return left_fn(input, right_result)


# ============================================================================
# Atop Combinator
# ============================================================================


fn atop[
    T: Copyable & Movable & ImplicitlyDestructible,
    U: Copyable & Movable & ImplicitlyDestructible,
    V: Copyable & Movable & ImplicitlyDestructible,
    f: fn (U) -> V,
    g: fn (T) -> U,
](input: T) -> V:
    """Atop combinator — two-function composition.

    Pattern: f(g(x))
    """
    return f(g(input))


# ============================================================================
# Over Combinator
# ============================================================================


fn over[
    T: Copyable & Movable & ImplicitlyDestructible,
    U: Copyable & Movable & ImplicitlyDestructible,
    O: Copyable & Movable & ImplicitlyDestructible,
    combine_fn: fn (U, U) -> O,
    transform_fn: fn (T) -> U,
](a: T, b: T) -> O:
    """Over combinator — apply same transform to both args, then combine.

    Pattern: combine(f(a), f(b))
    """
    return combine_fn(transform_fn(a), transform_fn(b))


# ============================================================================
# Under Combinator
# ============================================================================


fn under[
    T: Copyable & Movable & ImplicitlyDestructible,
    U: Copyable & Movable & ImplicitlyDestructible,
    transform_fn: fn (T) -> U,
    operation_fn: fn (U) -> U,
    untransform_fn: fn (U) -> T,
](input: T) -> T:
    """Under combinator — transform, apply, untransform.

    Pattern: g⁻¹(f(g(x)))
    Work in a different domain, then come back.
    """
    return untransform_fn(operation_fn(transform_fn(input)))
