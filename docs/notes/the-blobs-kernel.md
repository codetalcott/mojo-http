# The blobs kernel — landed 2026-09-16

> A design note from the engineering record. The second round of
> `apps/blobs`: the metaball kernel that replaced the stand-in circles,
> the rule the prototype had that the kernel no longer needs, and the one
> it lacked. The first round is
> [a-world-the-page-cannot-hold](a-world-the-page-cannot-hold.md).

**The piece.** `Tracer.trace(world, shapes)` in `apps/blobs/kernel.mojo`.
Every blob adds `strength / (d² + 1)` to a 192 × 192 grid. Marching
squares cuts the grid where the field crosses 1, and the cuts are chained
into closed outlines. Each outline is resampled to 48 vertices and given
the slot its previous outline held. Blobs that come close merge into one
shape, which is the work the page's step time now reports and a
stylesheet could not do. The server, stream and page did not change: the
kernel meets the contract the first round's stand-in was written against
(`NVERT` vertices strictly inside the stage, vertex 0 topmost with ties
leftmost, negative shoelace area), with one clause relaxed. A slot per
blob became at most one slot per blob, because merged blobs draw fewer
shapes.

## What changed from the prototype

The prototype was `~/projects/ideas/blobs-prototype/k2.mojo`. Five
rules are pinned by `test/test_kernel.mojo`, and `poe sabotage-blobs`
breaks each one against those tests:

- **Complementary cases wind oppositely**, and **chaining is keyed on
  grid-edge identity** — both carried over from the prototype unchanged.
  Writing case 14 as case 1 fails the closure tests, and so does keying
  the chain on coordinates rounded to a unit, which confirms the
  prototype's finding that coordinate keys fragment the walk.
- **A zero border replaced "walk path heads first".** The prototype kept
  contours closed by keeping blob centres a margin inside the stage, and
  walked open paths from their heads when that failed. The margin does
  not survive merging. A lone blob's outline sits ~11 grid units from its
  centre, and the clamp keeps centres ~23 from a wall, but sixteen blobs
  at the clamp point reach ~45. So the field's outer ring is forced to
  zero. Every contour then closes inside the grid, and a cluster pressed
  against a wall is drawn flattened against it: sixteen blobs at the clamp
  point trace as one closed shape of 272 segments whose leftmost vertex
  is 0.24 grid units from the wall. With no open paths,
  heads-first ordering has nothing to order, so it is gone; a walk that
  still fails to close is counted in `open_paths`, which `/stats` reports
  and the smoke requires to be 0. The drop clamp stays, now as a look
  rather than a safety rule: a LONE blob is never drawn against a wall.
- **Holes are dropped.** At the prototype's own layout, its four outlines
  were measured at −423, −12,783, **+893** and −482 (shoelace area). The
  positive one is a hole enclosed by merged blobs, and the prototype drew
  it as a shape of its own. A `clip-path` cannot cut a hole out of
  anything, so the kernel drops it. The test pins the layout exactly:
  1190 segments, 4 cycles, 1 hole, 3 shapes.
- **Vertex 0 is chosen after resampling.** The prototype resampled from
  its topmost raw vertex. That is correct in exact arithmetic, and
  interpolation can round a resampled vertex a hair above it. Rotating
  the resampled ring makes the rule exact, which is what the contract
  test asserts.

## What the prototype did not have

**Slot matching.** The stand-in drew blob `i` in slot `i`. Merged blobs
break that, and CSS moves a slot's vertex `i` to its next vertex `i`, so
a shape that changed slots would sweep across the stage. `match` gives
each shape the slot whose previous centre was nearest, within 40 grid
units, working largest shape first. On a merge, the merged shape keeps
the biggest one's slot. A shape with no predecessor takes a slot that was
empty in the previous step: a slot that has only just emptied would
animate its vanished shape into the new one. Both rules have a test.

**Buffers that persist.** The prototype's chain built two dictionaries
and an order list per step, 69 µs of its 276. A `Tracer` sizes its field
and edge maps once. The edge maps are stamped with a generation number
instead of being cleared, so a step touches only the entries its own
segments wrote. Chaining now costs ~4 µs.

## Measured

Apple M4, macOS. Stage times are for a built binary on the main thread,
with the five seeded blobs:

| stage | µs |
|---|---:|
| field | 40 |
| march | 102 |
| chain | 4 |
| resample | 6 |
| match | 6 |

The prototype's layout (sixteen blobs) traced at 217 µs a step under
`mojo run`. Inside the server, on the producer thread and including the
world's motion, `smoke-blobs` read 382 µs for the last step and 1,076 µs
for the slowest. Both are inside the 2 ms step budget, and the smoke
records both on each CI runner, so the x86-64 figure arrives with every
pull request's Linux leg. That is the runner's own CPU, not the
`x86-64-v2` target a deployment would pin.

Merging also shrinks the frame. In one local smoke run, sixteen blobs
drew at most five shapes, in a largest frame of 3.2 KB against the
stand-in's 9.6 KB. Sixteen blobs too far apart to merge still draw sixteen
shapes, and `test_wire.mojo` holds that worst case under a fifth of the
bus's 64 KB.

## Found on the way

**`std.testing` prints durations that are not wall time.** The kernel
tests reported a 66-second summary, and single tests reported a quarter
of a second each. The same file ran in 0.6 s under `time`, and a built
copy in 0.3 s while printing 87 s. Before believing a test is slow, time
it from the shell.
