"""The kernel's contract, checked on whatever `trace` is.

Today `trace` is the stand-in (circles). These tests do not know that:
they hold the contract `wire.mojo` and the page depend on, so the metaball
kernel that replaces it must pass them unchanged, and adds its own for
what only it can get wrong (closed contours, merges, holes).

Run with `uv run poe test-apps`.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from blobs.kernel import NVERT, SLOTS, Shapes, trace
from blobs.world import MAX_BLOBS, STAGE, World, keep_out


def _signed_area(shapes: Shapes, k: Int) -> Float64:
    var area = Float64(0)
    for v in range(NVERT):
        var w = (v + 1) % NVERT
        var x0 = Float64(shapes.px[k * NVERT + v])
        var y0 = Float64(shapes.py[k * NVERT + v])
        var x1 = Float64(shapes.px[k * NVERT + w])
        var y1 = Float64(shapes.py[k * NVERT + w])
        area += x0 * y1 - x1 * y0
    return area / 2.0


def _check_contract(world: World, shapes: Shapes) raises:
    """Every clause of the contract, for every slot."""
    for k in range(SLOTS):
        assert_equal(shapes.filled[k], world.alive[k])
        if not shapes.filled[k]:
            continue
        var y0 = shapes.py[k * NVERT]
        var x0 = shapes.px[k * NVERT]
        for v in range(NVERT):
            var x = shapes.px[k * NVERT + v]
            var y = shapes.py[k * NVERT + v]
            # Clear of the stage edge: a clipped contour is an open path.
            assert_true(x > 0.0 and x < Float32(STAGE))
            assert_true(y > 0.0 and y < Float32(STAGE))
            # Vertex 0 is the canonical start: smallest y, ties by x.
            if v > 0:
                assert_true(y > y0 or (y == y0 and x > x0))
        # One winding: negative shoelace area in page coordinates.
        assert_true(_signed_area(shapes, k) < 0.0)


def test_the_seeded_world_meets_the_contract() raises:
    var world = World()
    var shapes = Shapes()
    trace(world, shapes)
    assert_equal(shapes.filled_count(), world.count())
    assert_true(world.count() > 0)
    _check_contract(world, shapes)


def test_corner_drops_stay_clear_of_the_edge() raises:
    """A drop at each corner is clamped, and its shape stays inside.

    This is the rule that keeps every contour closed: the drop view and
    the world clamp a centre to `keep_out()` from every edge.
    """
    var world = World()
    for c in [(0.0, 0.0), (STAGE, 0.0), (0.0, STAGE), (STAGE, STAGE), (-1e9, 1e9)]:
        world.drop(c[0], c[1])
    for i in range(MAX_BLOBS):
        if world.alive[i]:
            assert_true(world.x[i] >= keep_out() and world.x[i] <= STAGE - keep_out())
            assert_true(world.y[i] >= keep_out() and world.y[i] <= STAGE - keep_out())
    var shapes = Shapes()
    trace(world, shapes)
    _check_contract(world, shapes)


def test_the_contract_holds_over_a_long_run() raises:
    """Five hundred steps with a drop every seventh: every frame complies."""
    var world = World(seed=12345)
    var shapes = Shapes()
    for step in range(500):
        if step % 7 == 0:
            var t = Float64(step)
            world.drop((t * 37.0) % 250.0 - 30.0, (t * 53.0) % 250.0 - 30.0)
        world.advance(0.1)
        trace(world, shapes)
        _check_contract(world, shapes)
    assert_equal(world.count(), MAX_BLOBS)


def test_a_full_world_evicts_the_oldest() raises:
    """Drop number `MAX_BLOBS + 1` reuses the slot the first drop took."""
    var world = World()
    var first = world.next
    for _ in range(MAX_BLOBS):
        world.drop(STAGE / 2.0, STAGE / 2.0)
    assert_equal(world.count(), MAX_BLOBS)
    assert_equal(world.next, first)
    world.drop(0.0, STAGE)
    assert_equal(world.x[first], keep_out())
    assert_equal(world.y[first], STAGE - keep_out())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
