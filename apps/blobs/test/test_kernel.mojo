"""The kernel: its contract, its five rules, and slot matching.

`_check_contract` is what the wire and the page depend on, checked on
every trace these tests make. The rest pin the rules in `kernel.mojo`'s
docstring, and `poe sabotage-blobs` breaks each rule to prove its test
fails.

Run with `uv run poe test-apps`.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from blobs.kernel import NVERT, SLOTS, Shapes, Tracer
from blobs.world import MAX_BLOBS, MAX_STRENGTH, STAGE, World, keep_out


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


def _empty_world() -> World:
    var w = World()
    for i in range(MAX_BLOBS):
        w.alive[i] = False
    return w^


def _place(mut w: World, i: Int, x: Float64, y: Float64, strength: Float64):
    w.alive[i] = True
    w.x[i] = x
    w.y[i] = y
    w.strength[i] = strength


def _slot_near(shapes: Shapes, x: Float32, y: Float32) -> Int:
    """The filled slot whose centre is nearest (`x`, `y`)."""
    var best = -1
    var best_d = Float32(1e30)
    for k in range(SLOTS):
        if not shapes.filled[k]:
            continue
        var dx = shapes.cx[k] - x
        var dy = shapes.cy[k] - y
        if dx * dx + dy * dy < best_d:
            best_d = dx * dx + dy * dy
            best = k
    return best


def _check_contract(world: World, tracer: Tracer, shapes: Shapes) raises:
    """Every clause, for every slot, plus the chain's own accounting."""
    # Every marched segment is in a closed cycle; no walk failed to close.
    assert_equal(tracer.open_paths, 0)
    assert_equal(tracer.cycle_segments, tracer.segments)
    var alive = world.count()
    var filled = shapes.filled_count()
    assert_true(filled <= alive)
    if alive > 0:
        assert_true(filled >= 1)
    for k in range(SLOTS):
        if not shapes.filled[k]:
            continue
        var y0 = shapes.py[k * NVERT]
        var x0 = shapes.px[k * NVERT]
        for v in range(NVERT):
            var x = shapes.px[k * NVERT + v]
            var y = shapes.py[k * NVERT + v]
            # Strictly inside the stage.
            assert_true(x > 0.0 and x < Float32(STAGE))
            assert_true(y > 0.0 and y < Float32(STAGE))
            # Vertex 0 is the canonical start: topmost, ties leftmost.
            if v > 0:
                assert_true(y > y0 or (y == y0 and x > x0))
        # One winding: negative shoelace area in page coordinates.
        assert_true(_signed_area(shapes, k) < 0.0)


def test_one_blob_is_one_closed_cycle() raises:
    var world = _empty_world()
    _place(world, 0, 96.0, 96.0, 110.0)
    var tracer = Tracer()
    var shapes = Shapes()
    tracer.trace(world, shapes)
    _check_contract(world, tracer, shapes)
    assert_true(tracer.segments > 40)
    assert_equal(tracer.cycles, 1)
    assert_equal(tracer.holes, 0)
    assert_equal(shapes.filled_count(), 1)


def test_the_prototype_layout_drops_its_hole() raises:
    """The layout the prototype was measured on: 1190 segments, 4 cycles.

    The prototype drew all four. One winds positive — a hole enclosed by
    merged blobs — and a `clip-path` cannot cut one out, so three are kept.
    """
    var world = World()
    for i in range(MAX_BLOBS):
        _place(world, i, Float64(30 + (i * 47) % 132), Float64(30 + (i * 71) % 132),
               Float64(90 + (i * 11) % 40))
    var tracer = Tracer()
    var shapes = Shapes()
    tracer.trace(world, shapes)
    _check_contract(world, tracer, shapes)
    assert_equal(tracer.segments, 1190)
    assert_equal(tracer.cycles, 4)
    assert_equal(tracer.holes, 1)
    assert_equal(shapes.filled_count(), 3)


def test_a_cluster_against_a_wall_still_closes() raises:
    """Sixteen blobs at the wall: one closed shape, flattened against it.

    Nothing clamps these centres, and a contour the grid edge cut would be
    an open path. The zero border is what closes it.
    """
    var world = _empty_world()
    for i in range(MAX_BLOBS):
        _place(world, i, 0.0, STAGE / 2.0, MAX_STRENGTH)
    var tracer = Tracer()
    var shapes = Shapes()
    tracer.trace(world, shapes)
    _check_contract(world, tracer, shapes)
    assert_equal(shapes.filled_count(), 1)
    var minx = Float32(STAGE)
    for k in range(SLOTS):
        if shapes.filled[k]:
            for v in range(NVERT):
                minx = min(minx, shapes.px[k * NVERT + v])
    assert_true(minx < 1.0)


def test_the_seeded_world_meets_the_contract() raises:
    var world = World()
    var tracer = Tracer()
    var shapes = Shapes()
    tracer.trace(world, shapes)
    _check_contract(world, tracer, shapes)


def test_corner_drops_stay_clear_of_the_edge() raises:
    """A drop at each corner is clamped, so a lone blob is not flattened.

    Traced without advancing: `advance` would also pull a centre back
    inside, and it is the drop's own clamp this checks.
    """
    var world = _empty_world()
    world.next = 0
    for c in [(0.0, 0.0), (STAGE, 0.0), (0.0, STAGE), (STAGE, STAGE)]:
        world.drop(c[0], c[1])
    for i in range(4):
        assert_true(world.x[i] >= keep_out() and world.x[i] <= STAGE - keep_out())
        assert_true(world.y[i] >= keep_out() and world.y[i] <= STAGE - keep_out())
    var tracer = Tracer()
    var shapes = Shapes()
    tracer.trace(world, shapes)
    _check_contract(world, tracer, shapes)
    assert_equal(shapes.filled_count(), 4)
    for k in range(SLOTS):
        if shapes.filled[k]:
            for v in range(NVERT):
                assert_true(shapes.px[k * NVERT + v] > 4.0)
                assert_true(shapes.py[k * NVERT + v] > 4.0)


def test_the_contract_holds_over_a_long_run() raises:
    """Six hundred steps, a drop every seventh: every trace complies.

    Merges, splits and wall contacts all happen along the way; the chain's
    accounting in `_check_contract` is what a fragmenting march fails.
    """
    var world = World(seed=12345)
    var tracer = Tracer()
    var shapes = Shapes()
    for step in range(600):
        if step % 7 == 0:
            var t = Float64(step)
            world.drop((t * 37.0) % 250.0 - 30.0, (t * 53.0) % 250.0 - 30.0)
        world.advance(0.1)
        tracer.trace(world, shapes)
        _check_contract(world, tracer, shapes)
    assert_equal(world.count(), MAX_BLOBS)


def test_slots_follow_their_blobs() raises:
    """A moving blob keeps its slot; a merged shape keeps the bigger one's."""
    var world = _empty_world()
    _place(world, 0, 50.0, 96.0, 100.0)
    _place(world, 1, 140.0, 96.0, 125.0)
    var tracer = Tracer()
    var shapes = Shapes()
    tracer.trace(world, shapes)
    var small = _slot_near(shapes, 50.0, 96.0)
    var big = _slot_near(shapes, 140.0, 96.0)
    assert_true(small >= 0 and big >= 0 and small != big)
    # Drift toward each other, a few units a step: the slots hold.
    for _ in range(6):
        world.x[0] += 5.0
        world.x[1] -= 3.0
        tracer.trace(world, shapes)
        _check_contract(world, tracer, shapes)
        assert_true(shapes.filled[small] and shapes.filled[big])
        assert_equal(_slot_near(shapes, Float32(world.x[0]), 96.0), small)
        assert_equal(_slot_near(shapes, Float32(world.x[1]), 96.0), big)
    # Together: one shape, in the bigger blob's slot.
    world.x[0] = 100.0
    world.x[1] = 104.0
    tracer.trace(world, shapes)
    _check_contract(world, tracer, shapes)
    assert_equal(shapes.filled_count(), 1)
    assert_true(shapes.filled[big])


def test_a_new_shape_takes_a_slot_that_was_empty() raises:
    """A shape with no predecessor never inherits a slot that just emptied.

    Reusing it would animate the vanished shape across the stage into the
    new one, because CSS interpolates a slot's polygon between frames.
    """
    var world = _empty_world()
    _place(world, 0, 50.0, 50.0, 110.0)
    _place(world, 1, 140.0, 140.0, 110.0)
    var tracer = Tracer()
    var shapes = Shapes()
    tracer.trace(world, shapes)
    var before = shapes.filled.copy()
    var kept = _slot_near(shapes, 140.0, 140.0)
    # Blob 0 goes; a new one appears far from both.
    world.alive[0] = False
    _place(world, 2, 140.0, 40.0, 110.0)
    tracer.trace(world, shapes)
    _check_contract(world, tracer, shapes)
    assert_equal(shapes.filled_count(), 2)
    assert_true(shapes.filled[kept])
    var fresh = _slot_near(shapes, 140.0, 40.0)
    assert_true(fresh != kept)
    assert_false(before[fresh])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
