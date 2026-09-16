"""The frame: full state, every slot, and small enough for the bus.

Run with `uv run poe test-apps`.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.broadcast import BUS_MAX_FRAME

from blobs.kernel import NVERT, SLOTS, Shapes, Tracer
from blobs.wire import fits_the_bus, polygon, signals_json, state_frame
from blobs.world import MAX_BLOBS, STAGE, World


def _full_world() -> World:
    """Sixteen blobs on a 4 x 4 lattice, too far apart to merge."""
    var world = World()
    for i in range(MAX_BLOBS):
        world.alive[i] = True
        world.x[i] = 35.0 + 40.0 * Float64(i % 4)
        world.y[i] = 35.0 + 40.0 * Float64(i // 4)
        world.strength[i] = 100.0
    return world^


def test_a_full_stage_fits_the_bus_with_room() raises:
    """Sixteen polygons of 48 vertices: under a fifth of `BUS_MAX_FRAME`.

    Sixteen blobs far enough apart not to merge draw sixteen polygons, the
    largest frame the kernel can make.

    The bus refuses a larger frame without a word, and the per-slot
    outbox holds 64 KB, so the headroom is what lets a slow viewer miss
    a frame and not a stream.
    """
    var world = _full_world()
    var shapes = Shapes()
    var tracer = Tracer()
    tracer.trace(world, shapes)
    var frame = state_frame(shapes, 7, 123, 2, world.count(), 100)
    assert_equal(shapes.filled_count(), SLOTS)
    assert_true(fits_the_bus(frame))
    assert_true(frame.byte_length() * 5 < BUS_MAX_FRAME)
    assert_true(frame.startswith("event: datastar-patch-signals\nid: 7\n"))
    assert_equal(frame.count("\ndata: "), 1)
    assert_true(frame.endswith("\n\n"))


def test_every_slot_is_in_every_frame() raises:
    """Full state: an empty slot is `""`, never absent."""
    var world = World()
    var shapes = Shapes()
    var tracer = Tracer()
    tracer.trace(world, shapes)
    var json = signals_json(shapes, 5, 1, world.count(), 100)
    for k in range(SLOTS):
        assert_true(json.find(String('"_b', k, '":"')) >= 0)
    assert_true(json.find('"_b15":""') >= 0)
    assert_true(json.find('"_step_us":5,"_viewers":1,"_blobs":5,"_period_ms":100}') >= 0)


def test_a_polygon_is_nvert_percent_pairs() raises:
    var world = World()
    var shapes = Shapes()
    var tracer = Tracer()
    tracer.trace(world, shapes)
    var p = polygon(shapes, 0)
    assert_true(p.startswith("polygon(") and p.endswith(")"))
    assert_equal(p.count(","), NVERT - 1)
    assert_equal(p.count("%"), 2 * NVERT)
    # One decimal place on every coordinate.
    assert_equal(p.count("."), 2 * NVERT)


def test_coordinates_clamp_to_the_stage() raises:
    """A vertex off the stage renders as 0.0 % or 100.0 %, never beyond."""
    var shapes = Shapes()
    shapes.filled[0] = True
    for v in range(NVERT):
        shapes.px[v] = Float32(-50.0)
        shapes.py[v] = Float32(STAGE * 3.0)
    var p = polygon(shapes, 0)
    assert_equal(p.count("0.0% 100.0%"), NVERT)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
