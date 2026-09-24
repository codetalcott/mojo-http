# The picture on the wire — measured 2026-09-21

> A design note from the engineering record. Why `apps/blobs` keeps
> sending a drawing rather than a world, written after an investigation
> into Datastar's Rocket component bundle asked whether the demo could
> become a surface the server drives but does not own frame by frame.
> The answer is no, not yet, and the reason is a measurement.

**The question.** Datastar v1.0.4 moved Rocket, its web-component API, out
of Pro and into a free bundle. Rocket's own flagship example is a flow
graph in which "the server owns the graph state while Rocket provides a
canvas" — the same claim `apps/blobs` makes, and a shape blobs might
adopt: send the world, let the client draw it, stop paying for a picture
sixty times a minute. That is worth asking about precisely because blobs
already pays for a picture.

**What blobs sends.** One `datastar-patch-signals` frame per producer
step, carrying every slot as a CSS `polygon(...)` string of `NVERT` = 48
vertex pairs at one decimal place, plus four readouts. Sixteen slots
filled would be about 11 KB. That number is what the case for changing it
rested on, and it is the wrong number.

## The measurement

Forty consecutive frames from a server with three blobs dropped on the
stage, captured with `curl -sN -H 'Accept: text/event-stream'` against a
`M0_WORKERS=1` build on its own port:

| | |
| --- | --- |
| signal JSON per frame | 1,950 B min, **2,544 B median**, 4,296 B max |
| whole SSE frame | 2,595 B median |
| filled slots | **5 of 16** median |
| slots that CHANGE between consecutive frames | **4** median, 7 max |
| share of signal bytes that is vertex text | **92.7 %** |

At 10 Hz that is about **26 KB/s per viewer**, not the 110 KB/s the
16-blob worst case implies, and the median frame leaves roughly 62 KB of
`BUS_MAX_FRAME` headroom rather than 54.

Two things follow, and the second is the one that settles it.

**Delta frames are worth almost nothing here.** Four of the five filled
slots change every frame, because metaballs are in constant motion — a
blob at rest still breathes. Sending only what changed saves about a
fifth, against the cost of overturning a decision with a stated reason
(`wire.mojo`: "a missed full frame is healed by the next one, a missed
delta would leave a stale blob on that screen forever").

**Vertices are 92.7 % of the payload, so the only real reduction is to
stop sending vertices.** Sending blob state instead — centre, radius,
phase, seed, hue, about 30 bytes each — is roughly 500 B per frame, a 20x
cut. There is no middle: trimming precision or vertex count buys a factor
of two and costs contour quality that took four rules to get right.

## Why state on the wire moves the kernel with it

`Tracer.trace` is five stages, not one:

```
sample   the scalar field over a 192x192 grid
march    marching squares at the isovalue
chain    segments into closed loops
resample each loop to exactly NVERT vertices
match    each polygon to the slot it held last step
```

`match` is the one that matters. It gives a continuing blob the slot it
already had, turns its vertex order to the rotation nearest its previous
polygon (`_best_shift`, `_rotate`), gives a merged shape the biggest
contributor's slot, prefers an empty slot for a new polygon over one that
just emptied, and animates births and farewells (`BORN_COPY`,
`BORN_SEED`, `LEAVE_SHRINK`, `LEAVE_HIDE`). All of that exists so that CSS
can interpolate between two frames at all: `transition: clip-path` only
interpolates polygons with equal vertex counts, and it interpolates
vertex *i* to vertex *i*, so a rotation nobody corrected would turn a
drifting blob inside out.

A client that receives state and draws it must reproduce every one of
those stages, including the correspondence — otherwise the animation is
not merely different, it is wrong in ways that appear only when blobs
merge, split or die. That is a port of `kernel.mojo`, not a renderer.

So the wire reduction and the second kernel are one change, not two. An
earlier sketch of this said the wire change was "server-side only, no
client dependency"; that was wrong, and the error is recorded here
because it is the kind that makes a cheap-looking piece expensive.

## The decision

**Not now.** 26 KB/s per viewer is not a cost blobs is paying badly, and
the price of removing it is a second implementation of a contouring
kernel whose rules each cost a round — the tree's own standing warning
(`split_data_lines`, duplicated for a release, where one unauthenticated
POST killed the server on the loop thread: "duplicating a function
duplicates its traps"). It would also rewrite SPEC N16's gate, whose
subject is that underscored signals draw the slots.

**What blobs already does, and should keep getting credit for.** The
server does not own every displayed frame today. It publishes at 10 Hz
(2 Hz idle) and `transition: clip-path var(--period) linear` fills the
gap at the display's own rate, with `--period` carried as `_period_ms` so
the easing tracks a producer that slowed down. That is the
server-drives/client-fills split, with no JavaScript and no second
kernel — which is why the demo can claim no interpreter in its image at
all.

**One fact makes the future cheap when it arrives.** Blobs sends only
`patch_signals` and never `patch_elements`, so the surface is never
morphed by the server. Whatever eventually owns those pixels — a canvas,
a Rocket `mode: 'light'` custom element, a WebGL context — needs nothing
protecting it from a morph that does not happen.

**What would retire this** is an application, not an optimisation: a
surface CSS genuinely cannot draw — a graph with edges, a virtual scroll,
a zoomable canvas — at which point the client needs a real renderer
anyway and the state-shaped wire is free. Blobs is not that application.
Reaching for it to prove the framework would be building the demo for the
framework rather than the other way round.

## Reproducing the measurement

```bash
uv run mojo build -I packages/m0-core/ -I packages/m0-http/ \
  -I packages/m0-datastar/ -I apps/ apps/blobs/server.mojo -o /tmp/blobs
M0_PORT=8931 M0_WORKERS=1 /tmp/blobs &
for i in 1 2 3; do
  curl -s -X POST http://127.0.0.1:8931/drop -H 'Content-Type: application/json' \
    -d "{\"x\":$((20+i*20)),\"y\":$((30+i*15))}" >/dev/null
done
curl -sN --max-time 4 -H 'Accept: text/event-stream' http://127.0.0.1:8931/events
```

Its own port, because `SO_REUSEPORT` lets a stray `blobs` answer for a
shared one and fake either result.
