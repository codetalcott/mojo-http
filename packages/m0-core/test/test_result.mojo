"""Tests for the Result type and combinators."""

from std.testing import assert_equal, assert_true, assert_false

from src.result import Result, Ok, Err, map_result, flat_map_result


def test_ok_creation() raises:
    """Ok results should have ok=True."""
    var result = Ok[Int](42)
    assert_true(result.is_ok())
    assert_false(result.is_err())
    assert_equal(result.get_value(), 42)


def test_err_creation() raises:
    """Err results should have ok=False — no phantom default needed."""
    var result = Err[Int]("something went wrong")
    assert_true(result.is_err())
    assert_false(result.is_ok())
    assert_equal(result.get_error(), "something went wrong")


def test_value_or_on_ok() raises:
    """value_or should return the value for Ok results."""
    var result = Ok[Int](42)
    assert_equal(result.value_or(0), 42)


def test_value_or_on_err() raises:
    """value_or should return the default for Err results."""
    var result = Err[Int]("error")
    assert_equal(result.value_or(99), 99)


def _double(x: Int) -> Int:
    return x * 2


def test_map_result_ok() raises:
    """map_result should transform Ok values."""
    var result = Ok[Int](21)
    var mapped = map_result[Int, Int, _double](result)
    assert_true(mapped.is_ok())
    assert_equal(mapped.get_value(), 42)


def test_map_result_err() raises:
    """map_result should pass through Err unchanged."""
    var result = Err[Int]("original error")
    var mapped = map_result[Int, Int, _double](result)
    assert_true(mapped.is_err())
    assert_equal(mapped.get_error(), "original error")


def test_result_copy() raises:
    """Results should be copyable."""
    var original = Ok[Int](42)
    var copy = original.copy()
    assert_true(copy.is_ok())
    assert_equal(copy.get_value(), 42)


def _double_result(x: Int) -> Result[Int]:
    return Ok[Int](x * 2)


def _fail_result(x: Int) -> Result[Int]:
    return Err[Int]("forced failure")


def test_flat_map_ok_to_ok() raises:
    """flat_map on Ok with a function returning Ok should chain."""
    var result = Ok[Int](21)
    var bound = flat_map_result[Int, Int, _double_result](result)
    assert_true(bound.is_ok())
    assert_equal(bound.get_value(), 42)


def test_flat_map_ok_to_err() raises:
    """flat_map on Ok with a function returning Err should propagate error."""
    var result = Ok[Int](21)
    var bound = flat_map_result[Int, Int, _fail_result](result)
    assert_true(bound.is_err())
    assert_equal(bound.get_error(), "forced failure")


def test_flat_map_err_passthrough() raises:
    """flat_map on Err should pass through without calling the function."""
    var result = Err[Int]("original error")
    var bound = flat_map_result[Int, Int, _double_result](result)
    assert_true(bound.is_err())
    assert_equal(bound.get_error(), "original error")
