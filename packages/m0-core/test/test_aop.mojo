"""Tests for AOP combinators."""

from std.testing import assert_equal

from src.aop import identity, constant, fork, hook, atop, over, under


fn test_identity() raises:
    """Identity should return input unchanged."""
    assert_equal(identity[Int](42), 42)


fn _make_99() -> Int:
    return 99

fn test_constant() raises:
    """K combinator should return a fixed value, ignoring its argument."""
    assert_equal(constant[Int, String, _make_99]("ignored"), 99)
    assert_equal(constant[Int, Int, _make_99](0), 99)


fn _square(x: Int) -> Int:
    return x * x

fn _add(a: Int, b: Int) -> Int:
    return a + b

fn _double(x: Int) -> Int:
    return x * 2


fn test_fork() raises:
    """Fork: fork(square, add, double)(3) = 9 + 6 = 15."""
    var result = fork[Int, Int, Int, Int, _square, _add, _double](3)
    assert_equal(result, 15)


fn _make_pair(a: Int, b: Int) -> Int:
    return a + b

fn _increment(x: Int) -> Int:
    return x + 1


fn test_hook() raises:
    """Hook: hook(make_pair, increment)(5) = 5 + 6 = 11."""
    var result = hook[Int, Int, Int, _make_pair, _increment](5)
    assert_equal(result, 11)


fn _negate(x: Int) -> Int:
    return -x

fn _abs_val(x: Int) -> Int:
    if x < 0:
        return -x
    return x


fn test_atop() raises:
    """Atop: atop(negate, abs_val)(-3) = negate(3) = -3."""
    var result = atop[Int, Int, Int, _negate, _abs_val](-3)
    assert_equal(result, -3)


fn test_atop_same_type() raises:
    """Atop with same types: negate(double(4)) = -8."""
    var result = atop[Int, Int, Int, _negate, _double](4)
    assert_equal(result, -8)


fn test_over() raises:
    """Over: over(add, square)(3, 4) = 9 + 16 = 25."""
    var result = over[Int, Int, Int, _add, _square](3, 4)
    assert_equal(result, 25)


fn _times_ten(x: Int) -> Int:
    return x * 10

fn _div_ten(x: Int) -> Int:
    return x // 10

fn _plus_three(x: Int) -> Int:
    return x + 3


fn test_under() raises:
    """Under: under(times_ten, plus_three, div_ten)(5) = div_ten(53) = 5."""
    var result = under[Int, Int, _times_ten, _plus_three, _div_ten](5)
    assert_equal(result, 5)
