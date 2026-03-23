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


def compose[
    T: Copyable & Movable & ImplicitlyDestructible,
    f: def (T) -> T,
    g: def (T) -> T,
](input: T) -> T:
    """Compose two functions right-to-left: f(g(input))."""
    return f(g(input))


def compose3[
    T: Copyable & Movable & ImplicitlyDestructible,
    f: def (T) -> T,
    g: def (T) -> T,
    h: def (T) -> T,
](input: T) -> T:
    """Compose three functions right-to-left: f(g(h(input)))."""
    return f(g(h(input)))


# ============================================================================
# Pipe — Left-to-Right Sequential Pipeline
# ============================================================================


def pipe_2[
    T: Copyable & Movable & ImplicitlyDestructible,
    f: def (T) -> T,
    g: def (T) -> T,
](input: T) -> T:
    """Pipe input through two functions left-to-right: g(f(input))."""
    return g(f(input))


def pipe_3[
    T: Copyable & Movable & ImplicitlyDestructible,
    f: def (T) -> T,
    g: def (T) -> T,
    h: def (T) -> T,
](input: T) -> T:
    """Pipe input through three functions left-to-right: h(g(f(input)))."""
    return h(g(f(input)))


def pipe_4[
    T: Copyable & Movable & ImplicitlyDestructible,
    f: def (T) -> T,
    g: def (T) -> T,
    h: def (T) -> T,
    k: def (T) -> T,
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

    def __init__(out self, val: Self.T, should_exit: Bool = False):
        self.val = val.copy()
        self.should_exit = should_exit

    def with_exit(self) -> PipelineContext[Self.T]:
        """Create a copy with should_exit set to True."""
        return PipelineContext[Self.T](self.val.copy(), True)


def pipe_ctx_2[
    T: Copyable & Movable & ImplicitlyDestructible,
    f: def (PipelineContext[T]) -> PipelineContext[T],
    g: def (PipelineContext[T]) -> PipelineContext[T],
](input: PipelineContext[T]) -> PipelineContext[T]:
    """Pipe a PipelineContext through two functions with early exit support."""
    var result = f(input)
    if result.should_exit:
        return result^
    return g(result^)


def pipe_ctx_3[
    T: Copyable & Movable & ImplicitlyDestructible,
    f: def (PipelineContext[T]) -> PipelineContext[T],
    g: def (PipelineContext[T]) -> PipelineContext[T],
    h: def (PipelineContext[T]) -> PipelineContext[T],
](input: PipelineContext[T]) -> PipelineContext[T]:
    """Pipe a PipelineContext through three functions with early exit support."""
    var result = f(input)
    if result.should_exit:
        return result^
    result = g(result^)
    if result.should_exit:
        return result^
    return h(result^)
