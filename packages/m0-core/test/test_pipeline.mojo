"""Tests for pipeline utilities."""

from std.testing import assert_equal, assert_true

from src.pipeline import (
    compose,
    compose3,
    pipe_2,
    pipe_3,
    pipe_4,
    PipelineContext,
    pipe_ctx_2,
    pipe_ctx_3,
)


fn _add_one(x: Int) -> Int:
    return x + 1


fn _double(x: Int) -> Int:
    return x * 2


fn _negate(x: Int) -> Int:
    return -x


fn _square(x: Int) -> Int:
    return x * x


fn test_compose_two() raises:
    """compose should apply f(g(x))."""
    var result = compose[Int, _double, _add_one](3)
    assert_equal(result, 8)


fn test_compose3() raises:
    """compose3 should apply f(g(h(x)))."""
    var result = compose3[Int, _negate, _double, _add_one](3)
    assert_equal(result, -8)


fn test_pipe_2() raises:
    """pipe_2 should apply g(f(x)) - left to right."""
    var result = pipe_2[Int, _add_one, _double](3)
    assert_equal(result, 8)


fn test_pipe_3() raises:
    """pipe_3 should apply h(g(f(x))) - left to right."""
    var result = pipe_3[Int, _add_one, _double, _negate](3)
    assert_equal(result, -8)


fn test_pipe_4() raises:
    """pipe_4 should chain 4 functions left to right."""
    var result = pipe_4[Int, _add_one, _double, _negate, _square](2)
    assert_equal(result, 36)


fn _ctx_add_one(ctx: PipelineContext[Int]) -> PipelineContext[Int]:
    return PipelineContext[Int](ctx.val + 1)


fn _ctx_double(ctx: PipelineContext[Int]) -> PipelineContext[Int]:
    return PipelineContext[Int](ctx.val * 2)


fn _ctx_exit(ctx: PipelineContext[Int]) -> PipelineContext[Int]:
    return ctx.with_exit()


fn test_pipeline_context_basic() raises:
    """PipelineContext should carry values through."""
    var ctx = PipelineContext[Int](5)
    assert_equal(ctx.val, 5)
    assert_equal(ctx.should_exit, False)


fn test_pipe_ctx_2_normal() raises:
    """pipe_ctx_2 should apply both functions."""
    var ctx = PipelineContext[Int](3)
    var result = pipe_ctx_2[Int, _ctx_add_one, _ctx_double](ctx)
    assert_equal(result.val, 8)
    assert_equal(result.should_exit, False)


fn test_pipe_ctx_2_early_exit() raises:
    """pipe_ctx_2 should skip second function on early exit."""
    var ctx = PipelineContext[Int](3)
    var result = pipe_ctx_2[Int, _ctx_exit, _ctx_double](ctx)
    assert_equal(result.val, 3)
    assert_true(result.should_exit)


fn test_pipe_ctx_3_normal() raises:
    """pipe_ctx_3 should apply all three functions."""
    var ctx = PipelineContext[Int](2)
    var result = pipe_ctx_3[Int, _ctx_add_one, _ctx_double, _ctx_add_one](ctx)
    assert_equal(result.val, 7)
