"""The kernel: its contract, its rules, and slot matching.

`_check_contract` is what the wire and the page depend on, checked on
every trace these tests make against the trace before it: a continuing
slot in the vertex order nearest its previous polygon, nothing vanishing
without a farewell, nothing appearing but as a seed. The rest pin the
rules in `kernel.mojo`'s docstring, and `poe sabotage-blobs` breaks each
rule to prove its test fails.

Run with `uv run poe test-apps`.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from blobs.kernel import (
    BORN_COPY, BORN_SEED, LEAVE_HIDE, LEAVE_SHRINK, NVERT, SEED_SCALE, SLOTS, Shapes, Tracer,
)
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
    """The filled slot, not saying farewell, whose centre is nearest (`x`, `y`)."""
    var best = -1
    var best_d = Float32(1e30)
    for k in range(SLOTS):
        if not shapes.filled[k] or shapes.leaving[k] != 0:
            continue
        var dx = shapes.cx[k] - x
        var dy = shapes.cy[k] - y
        if dx * dx + dy * dy < best_d:
            best_d = dx * dx + dy * dy
            best = k
    return best


comptime SEED_EXTENT = Float32(5.0)
"""How far from its centre a LONE blob's seed or shrunk farewell may reach.

A lone blob reaches ~11 grid units, so its `SEED_SCALE` copy reaches under
one. A merged cluster's seed can reach further; the contract bounds every
seed by what it grows into instead (`_check_contract`).
"""


def _snapshot(s: Shapes) -> Shapes:
    """A copy of `s`: the trace before, for the checks that compare two."""
    var c = Shapes()
    c.px = s.px.copy()
    c.py = s.py.copy()
    c.filled = s.filled.copy()
    c.cx = s.cx.copy()
    c.cy = s.cy.copy()
    c.born = s.born.copy()
    c.leaving = s.leaving.copy()
    c.primed = s.primed
    return c^


def _move_cost(shapes: Shapes, k: Int, prev: Shapes, shift: Int) -> Float64:
    """Squared vertex travel if slot `k`'s vertex `(i + shift)` went to `prev`'s `i`."""
    var d = Float64(0)
    for v in range(NVERT):
        var w = (v + shift) % NVERT
        var dx = Float64(shapes.px[k * NVERT + w]) - Float64(prev.px[k * NVERT + v])
        var dy = Float64(shapes.py[k * NVERT + w]) - Float64(prev.py[k * NVERT + v])
        d += dx * dx + dy * dy
    return d


def _aligned(shapes: Shapes, k: Int, prev: Shapes) -> Bool:
    """No rotation of slot `k` moves its vertices less than the one it has."""
    var here = _move_cost(shapes, k, prev, 0)
    for s in range(1, NVERT):
        if _move_cost(shapes, k, prev, s) < here - 1e-6 * (1.0 + here):
            return False
    return True


def _mean_move(shapes: Shapes, k: Int, prev: Shapes) -> Float64:
    var d = Float64(0)
    for v in range(NVERT):
        var dx = Float64(shapes.px[k * NVERT + v]) - Float64(prev.px[k * NVERT + v])
        var dy = Float64(shapes.py[k * NVERT + v]) - Float64(prev.py[k * NVERT + v])
        d += (dx * dx + dy * dy) ** 0.5
    return d / Float64(NVERT)


def _topmost(shapes: Shapes, k: Int, eps: Float32 = 0.0) -> Bool:
    """Vertex 0 is the topmost, ties leftmost (to within `eps` in y)."""
    var y0 = shapes.py[k * NVERT]
    var x0 = shapes.px[k * NVERT]
    for v in range(1, NVERT):
        var x = shapes.px[k * NVERT + v]
        var y = shapes.py[k * NVERT + v]
        if y < y0 - eps or (eps == 0.0 and y == y0 and x <= x0):
            return False
    return True


def _copies_a_previous(shapes: Shapes, k: Int, prev: Shapes) -> Bool:
    """Slot `k`'s polygon is exactly some slot's previous polygon."""
    for j in range(SLOTS):
        if not prev.filled[j]:
            continue
        var same = True
        for v in range(NVERT):
            if shapes.px[k * NVERT + v] != prev.px[j * NVERT + v] or shapes.py[k * NVERT + v] != prev.py[j * NVERT + v]:
                same = False
                break
        if same:
            return True
    return False


def _extent(shapes: Shapes, k: Int, x: Float32, y: Float32) -> Float32:
    """How far slot `k`'s farthest vertex is from (`x`, `y`)."""
    var r = Float32(0)
    for v in range(NVERT):
        var dx = shapes.px[k * NVERT + v] - x
        var dy = shapes.py[k * NVERT + v] - y
        r = max(r, (dx * dx + dy * dy) ** 0.5)
    return r


def _check_contract(world: World, tracer: Tracer, shapes: Shapes, prev: Shapes) raises:
    """Every clause, for every slot, against the trace before; plus the chain's accounting."""
    # Every marched segment is in a closed cycle; no walk failed to close.
    assert_equal(tracer.open_paths, 0)
    assert_equal(tracer.cycle_segments, tracer.segments)
    var alive = world.count()
    var own = shapes.filled_count() - shapes.leaving_count()
    assert_true(own <= alive)
    if alive > 0:
        assert_true(own >= 1)
    for k in range(SLOTS):
        if not shapes.filled[k]:
            # Nothing vanishes whole: a slot empties only after its farewell.
            if prev.filled[k]:
                assert_equal(prev.leaving[k], LEAVE_HIDE)
            continue
        for v in range(NVERT):
            var x = shapes.px[k * NVERT + v]
            var y = shapes.py[k * NVERT + v]
            # Strictly inside the stage.
            assert_true(x > 0.0 and x < Float32(STAGE))
            assert_true(y > 0.0 and y < Float32(STAGE))
        # One winding: negative shoelace area in page coordinates.
        assert_true(_signed_area(shapes, k) < 0.0)
        if prev.filled[k] and shapes.born[k] == 0:
            # A slot keeps its vertex order: the rotation nearest its last.
            assert_true(_aligned(shapes, k, prev))
            # A seed grows into its shape: it was a small copy of what it became.
            if prev.born[k] == BORN_SEED and shapes.leaving[k] == 0:
                var seed = _extent(prev, k, prev.cx[k], prev.cy[k])
                var grown = _extent(shapes, k, shapes.cx[k], shapes.cy[k])
                assert_true(seed <= 3.0 * SEED_SCALE * grown)
        elif not prev.primed:
            # The first trace: every shape whole, from its canonical start.
            assert_true(_topmost(shapes, k))
        else:
            # Nothing appears whole: a new shape is its parent's copy or a seed.
            assert_true(shapes.born[k] == BORN_COPY or shapes.born[k] == BORN_SEED)
            if shapes.born[k] == BORN_COPY:
                assert_true(_copies_a_previous(shapes, k, prev))
            else:
                assert_true(_topmost(shapes, k, 1e-3))


def _trace(mut tracer: Tracer, world: World, mut shapes: Shapes) raises -> Shapes:
    """Trace one step, check it against the last, and return the last."""
    var prev = _snapshot(shapes)
    tracer.trace(world, shapes)
    _check_contract(world, tracer, shapes, prev)
    return prev^


def test_one_blob_is_one_closed_cycle() raises:
    var world = _empty_world()
    _place(world, 0, 96.0, 96.0, 110.0)
    var tracer = Tracer()
    var shapes = Shapes()
    _ = _trace(tracer, world, shapes)
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
    _ = _trace(tracer, world, shapes)
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
    _ = _trace(tracer, world, shapes)
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
    _ = _trace(tracer, world, shapes)


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
    _ = _trace(tracer, world, shapes)
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
        _ = _trace(tracer, world, shapes)
    assert_equal(world.count(), MAX_BLOBS)


def _own(shapes: Shapes) -> Int:
    """Slots holding a shape of their own: filled, not saying farewell."""
    return shapes.filled_count() - shapes.leaving_count()


def _same_outline(shapes: Shapes, a: Int, b: Int) -> Bool:
    """Slots `a` and `b` hold the same vertices, in some rotation."""
    for s in range(NVERT):
        var same = True
        for v in range(NVERT):
            var w = (v + s) % NVERT
            if shapes.px[a * NVERT + w] != shapes.px[b * NVERT + v] or shapes.py[a * NVERT + w] != shapes.py[b * NVERT + v]:
                same = False
                break
        if same:
            return True
    return False


def test_slots_follow_their_blobs() raises:
    """A moving blob keeps its slot; a merged shape keeps the bigger one's."""
    var world = _empty_world()
    _place(world, 0, 50.0, 96.0, 100.0)
    _place(world, 1, 140.0, 96.0, 125.0)
    var tracer = Tracer()
    var shapes = Shapes()
    _ = _trace(tracer, world, shapes)
    var small = _slot_near(shapes, 50.0, 96.0)
    var big = _slot_near(shapes, 140.0, 96.0)
    assert_true(small >= 0 and big >= 0 and small != big)
    # Drift toward each other, a few units a step: the slots hold.
    for _ in range(6):
        world.x[0] += 5.0
        world.x[1] -= 3.0
        _ = _trace(tracer, world, shapes)
        assert_true(shapes.filled[small] and shapes.filled[big])
        assert_equal(_slot_near(shapes, Float32(world.x[0]), 96.0), small)
        assert_equal(_slot_near(shapes, Float32(world.x[1]), 96.0), big)
    # Together: one shape, in the bigger blob's slot.
    world.x[0] = 100.0
    world.x[1] = 104.0
    _ = _trace(tracer, world, shapes)
    assert_equal(_own(shapes), 1)
    assert_true(shapes.filled[big] and shapes.leaving[big] == 0)


def test_a_slot_keeps_its_vertex_order() raises:
    """A peanut whose highest point passes from one lobe to the other.

    Vertex 0 restarted at the topmost point every step until the first
    deploy, and on the step the other lobe rose above, CSS dragged every
    vertex around the outline to its new index. The walk must move
    vertex 0 off the topmost, or it would prove nothing.
    """
    var world = _empty_world()
    _place(world, 0, 84.0, 100.0, 110.0)
    _place(world, 1, 104.0, 108.0, 110.0)
    var tracer = Tracer()
    var shapes = Shapes()
    _ = _trace(tracer, world, shapes)
    assert_equal(_own(shapes), 1)
    var k = _slot_near(shapes, 94.0, 104.0)
    var left_topmost = False
    var worst = Float64(0)
    for _ in range(16):
        world.y[1] -= 1.0
        var prev = _trace(tracer, world, shapes)
        assert_equal(_own(shapes), 1)
        assert_true(shapes.filled[k])
        if not _topmost(shapes, k):
            left_topmost = True
        worst = max(worst, _mean_move(shapes, k, prev))
    assert_true(left_topmost)
    # A lobe moving a unit a step moves its vertices about that far.
    assert_true(worst < 2.0)


def test_a_merge_becomes_the_merged_shape_then_shrinks() raises:
    """The absorbed blob's slot morphs into the merged outline, then away.

    It used to hide the step they touched, leaving the stage bare where it
    had been until the survivor's outline grew over the spot.
    """
    var world = _empty_world()
    _place(world, 0, 70.0, 96.0, 100.0)
    _place(world, 1, 122.0, 96.0, 125.0)
    var tracer = Tracer()
    var shapes = Shapes()
    _ = _trace(tracer, world, shapes)
    var small = _slot_near(shapes, 70.0, 96.0)
    var big = _slot_near(shapes, 122.0, 96.0)
    var merged = False
    for _ in range(40):
        world.x[0] += 1.0
        world.x[1] -= 1.0
        _ = _trace(tracer, world, shapes)
        if shapes.leaving[small] != 0:
            merged = True
            break
    assert_true(merged)
    assert_equal(_own(shapes), 1)
    assert_true(shapes.filled[big] and shapes.leaving[big] == 0)
    assert_equal(shapes.leaving[small], LEAVE_SHRINK)
    assert_true(_same_outline(shapes, small, big))
    var x = shapes.cx[small]
    var y = shapes.cy[small]
    _ = _trace(tracer, world, shapes)
    assert_equal(shapes.leaving[small], LEAVE_HIDE)
    assert_true(_extent(shapes, small, x, y) <= SEED_EXTENT)
    _ = _trace(tracer, world, shapes)
    assert_false(shapes.filled[small])


def test_a_split_starts_as_its_parent() raises:
    """The new half's first polygon is its parent's last, then its own."""
    var world = _empty_world()
    _place(world, 0, 90.0, 96.0, 110.0)
    _place(world, 1, 102.0, 96.0, 110.0)
    var tracer = Tracer()
    var shapes = Shapes()
    _ = _trace(tracer, world, shapes)
    assert_equal(_own(shapes), 1)
    var parent = _slot_near(shapes, 96.0, 96.0)
    var child = -1
    for _ in range(40):
        world.x[0] -= 1.0
        world.x[1] += 1.0
        var prev = _snapshot(shapes)
        _ = _trace(tracer, world, shapes)
        if _own(shapes) == 2:
            for k in range(SLOTS):
                if shapes.born[k] == BORN_COPY:
                    child = k
            assert_true(child >= 0 and child != parent)
            for v in range(NVERT):
                assert_equal(shapes.px[child * NVERT + v], prev.px[parent * NVERT + v])
                assert_equal(shapes.py[child * NVERT + v], prev.py[parent * NVERT + v])
            break
    assert_true(child >= 0)
    _ = _trace(tracer, world, shapes)
    assert_equal(shapes.born[child], 0)
    assert_true(_extent(shapes, child, shapes.cx[child], shapes.cy[child]) > 8.0)


def test_a_shape_that_ends_shrinks_to_its_centre() raises:
    """A blob that goes with nothing to merge into shrinks, then hides."""
    var world = _empty_world()
    _place(world, 0, 50.0, 50.0, 110.0)
    _place(world, 1, 140.0, 140.0, 110.0)
    var tracer = Tracer()
    var shapes = Shapes()
    _ = _trace(tracer, world, shapes)
    var gone = _slot_near(shapes, 50.0, 50.0)
    var x = shapes.cx[gone]
    var y = shapes.cy[gone]
    world.alive[0] = False
    _ = _trace(tracer, world, shapes)
    assert_true(shapes.filled[gone])
    assert_equal(shapes.leaving[gone], LEAVE_HIDE)
    assert_true(_extent(shapes, gone, x, y) <= SEED_EXTENT)
    _ = _trace(tracer, world, shapes)
    assert_false(shapes.filled[gone])


def test_a_drop_grows_from_a_seed() raises:
    """A new blob's first polygon is a tiny copy of it at its centre."""
    var world = _empty_world()
    _place(world, 0, 50.0, 50.0, 110.0)
    var tracer = Tracer()
    var shapes = Shapes()
    _ = _trace(tracer, world, shapes)
    _place(world, 1, 140.0, 140.0, 110.0)
    _ = _trace(tracer, world, shapes)
    var fresh = _slot_near(shapes, 140.0, 140.0)
    assert_equal(shapes.born[fresh], BORN_SEED)
    assert_true(_extent(shapes, fresh, shapes.cx[fresh], shapes.cy[fresh]) <= SEED_EXTENT)
    _ = _trace(tracer, world, shapes)
    assert_equal(shapes.born[fresh], 0)
    assert_true(_extent(shapes, fresh, shapes.cx[fresh], shapes.cy[fresh]) > 8.0)


def test_a_new_shape_takes_a_slot_that_was_empty() raises:
    """A shape with no predecessor never inherits a slot that just emptied.

    Reusing it would animate the vanished shape across the stage into the
    new one, because CSS interpolates a slot's polygon between frames. A
    slot saying farewell is not offered either.
    """
    var world = _empty_world()
    _place(world, 0, 50.0, 50.0, 110.0)
    _place(world, 1, 140.0, 140.0, 110.0)
    var tracer = Tracer()
    var shapes = Shapes()
    _ = _trace(tracer, world, shapes)
    var before = shapes.filled.copy()
    var kept = _slot_near(shapes, 140.0, 140.0)
    # Blob 0 goes; a new one appears far from both.
    world.alive[0] = False
    _place(world, 2, 140.0, 40.0, 110.0)
    _ = _trace(tracer, world, shapes)
    assert_equal(_own(shapes), 2)
    assert_true(shapes.filled[kept])
    var fresh = _slot_near(shapes, 140.0, 40.0)
    assert_true(fresh != kept)
    assert_false(before[fresh])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
