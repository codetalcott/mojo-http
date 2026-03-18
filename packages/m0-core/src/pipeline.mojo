"""
Pipeline Utilities — Pipe and Compose

- compose: Right-to-left function composition
- pipe_2/pipe_3/pipe_4: Left-to-right sequential pipelines (arity-specific)
- PipelineContext: Wrapper supporting early exit in pipelines

Fixed-arity combinators compile to zero-overhead call chains.
"""


# ============================================================================
# Compose — Right-to-Left Composition
# ============================================================================


fn compose[
    T: Copyable & Movable & ImplicitlyDestructible,
    f: fn (T) -> T,
    g: fn (T) -> T,
](input: T) -> T:
    """Compose two functions right-to-left: f(g(input))."""
    return f(g(input))


fn compose3[
    T: Copyable & Movable & ImplicitlyDestructible,
    f: fn (T) -> T,
    g: fn (T) -> T,
    h: fn (T) -> T,
](input: T) -> T:
    """Compose three functions right-to-left: f(g(h(input)))."""
    return f(g(h(input)))


# ============================================================================
# Pipe — Left-to-Right Sequential Pipeline
# ============================================================================


fn pipe_2[
    T: Copyable & Movable & ImplicitlyDestructible,
    f: fn (T) -> T,
    g: fn (T) -> T,
](input: T) -> T:
    """Pipe input through two functions left-to-right: g(f(input))."""
    return g(f(input))


fn pipe_3[
    T: Copyable & Movable & ImplicitlyDestructible,
    f: fn (T) -> T,
    g: fn (T) -> T,
    h: fn (T) -> T,
](input: T) -> T:
    """Pipe input through three functions left-to-right: h(g(f(input)))."""
    return h(g(f(input)))


fn pipe_4[
    T: Copyable & Movable & ImplicitlyDestructible,
    f: fn (T) -> T,
    g: fn (T) -> T,
    h: fn (T) -> T,
    k: fn (T) -> T,
](input: T) -> T:
    """Pipe input through four functions left-to-right: k(h(g(f(input))))."""
    return k(h(g(f(input))))


# ============================================================================
# Pipeline with Early Exit (Context-style)
# ============================================================================


struct PipelineContext[T: Copyable & Movable & ImplicitlyDestructible](Copyable, Movable):
    """Context wrapper that supports early exit in pipelines."""

    var val: Self.T
    var should_exit: Bool

    fn __init__(out self, val: Self.T, should_exit: Bool = False):
        self.val = val.copy()
        self.should_exit = should_exit

    fn with_exit(self) -> PipelineContext[Self.T]:
        """Create a copy with should_exit set to True."""
        return PipelineContext[Self.T](self.val.copy(), True)


fn pipe_ctx_2[
    T: Copyable & Movable & ImplicitlyDestructible,
    f: fn (PipelineContext[T]) -> PipelineContext[T],
    g: fn (PipelineContext[T]) -> PipelineContext[T],
](input: PipelineContext[T]) -> PipelineContext[T]:
    """Pipe a PipelineContext through two functions with early exit support."""
    var result = f(input)
    if result.should_exit:
        return result^
    return g(result^)


fn pipe_ctx_3[
    T: Copyable & Movable & ImplicitlyDestructible,
    f: fn (PipelineContext[T]) -> PipelineContext[T],
    g: fn (PipelineContext[T]) -> PipelineContext[T],
    h: fn (PipelineContext[T]) -> PipelineContext[T],
](input: PipelineContext[T]) -> PipelineContext[T]:
    """Pipe a PipelineContext through three functions with early exit support."""
    var result = f(input)
    if result.should_exit:
        return result^
    result = g(result^)
    if result.should_exit:
        return result^
    return h(result^)
