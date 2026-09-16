"""World to shapes: the step's compute, behind the contract the wire relies on.

THIS IS A STAND-IN. Each live blob is traced as a circle at its lone
contour radius, so blobs that overlap do not merge. It exists so the
server, the stream and the page could be built and gated before the
metaball kernel lands (field, marching squares, chaining on edge identity,
arc-length resample; `~/projects/ideas/handoff-blobs-kernel.md`), and it is
replaced by that kernel behind the same `trace`. What the wire and the
page depend on is the CONTRACT below, not circles, and `test_kernel.mojo`
checks the contract rather than the shape, so the same tests hold the
replacement to it.

The contract, per filled slot:

- exactly `NVERT` vertices, in grid units, inside the stage and clear of
  its edge (a contour the edge clips is an open path, which `polygon()`
  cannot draw);
- vertex 0 is the canonical start: the smallest y, ties broken by the
  smallest x — CSS moves vertex `i` to vertex `i`, so a start that wanders
  between frames twists every transition;
- one winding for every loop: negative shoelace area in page coordinates
  (y down), which is counter-clockwise on screen — the direction the
  prototype's outer loops run. A hole winds the other way, which is how a
  kernel that forgot to drop holes shows up;
- a slot stays empty (`filled == False`) rather than carrying a degenerate
  polygon.
"""

from std.math import cos, sin

from blobs.world import MAX_BLOBS, World, contour_radius

comptime NVERT = 48
"""Vertices per polygon. CSS interpolates `polygon()` only between equal counts."""

comptime SLOTS = MAX_BLOBS
"""Polygons per frame; slot `i` draws blob `i` (the stand-in's matching)."""

comptime TWO_PI = Float64(6.283185307179586)


struct Shapes(Movable):
    """`SLOTS x NVERT` vertices in grid units, and which slots hold one."""

    var px: List[Float32]
    var py: List[Float32]
    var filled: List[Bool]

    def __init__(out self):
        self.px = List[Float32](length=SLOTS * NVERT, fill=0.0)
        self.py = List[Float32](length=SLOTS * NVERT, fill=0.0)
        self.filled = List[Bool](length=SLOTS, fill=False)

    def filled_count(self) -> Int:
        var n = 0
        for k in range(SLOTS):
            if self.filled[k]:
                n += 1
        return n


def trace(world: World, mut shapes: Shapes):
    """One step's shapes for `world`: the stand-in, circles.

    Vertex `k` sits at angle `2*pi*k/NVERT` measured from the top, moving
    toward smaller x first — so vertex 0 is the top point (the canonical
    start) and the loop runs counter-clockwise on screen.
    """
    for k in range(SLOTS):
        if not world.alive[k]:
            shapes.filled[k] = False
            continue
        var r = contour_radius(world.strength[k])
        var cx = world.x[k]
        var cy = world.y[k]
        for v in range(NVERT):
            var a = TWO_PI * Float64(v) / Float64(NVERT)
            shapes.px[k * NVERT + v] = Float32(cx - r * sin(a))
            shapes.py[k * NVERT + v] = Float32(cy - r * cos(a))
        shapes.filled[k] = True
