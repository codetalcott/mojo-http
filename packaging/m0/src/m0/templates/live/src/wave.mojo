"""The state the producer steps. Pure — no clock, no I/O — so
`test/test_live.mojo` can step it in a `uv run m0 test`."""

from std.math import sin

from pages import BARS


struct Wave(Movable):
    """A travelling wave, lifted by kicks that decay."""

    var step_no: Int
    var energy: Int

    def __init__(out self):
        self.step_no = 0
        self.energy = 0

    def advance(mut self, kicks: Int):
        self.step_no += 1
        self.energy = self.energy * 7 // 10 + 40 * kicks
        if self.energy > 60:
            self.energy = 60

    def heights(self) -> List[Int]:
        """Each bar as a percentage: a travelling wave, lifted by a kick."""
        var out = List[Int]()
        for i in range(BARS):
            var phase = Float64(self.step_no) * 0.6 + Float64(i) * 0.5
            out.append(20 + Int(15.0 * (sin(phase) + 1.0)) + self.energy)
        return out^
