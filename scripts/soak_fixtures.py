"""The soak's binary fixtures, generated from a SEED.

    python3 scripts/soak_fixtures.py --out /tmp/soak

`color-separation`'s two images are noise PNGs, and noise is what makes
them worth serving: they do not compress, so the 9.7 MB original really is
9.7 MB on the wire and larger than every buffer in the server. Until
2026-09-10 they were generated unseeded, so every pass produced different
bytes and the manifest's `bytes` pins had to be re-measured -- a step that
looks like bookkeeping and is the third of the three traps recorded against
this corpus (a pin left at the last pass's size fails every read of that
route with `stream PATH: N bytes, expected M`).

Seeded, a later pass reproduces the same files, which is what lets the pins
be a property of the manifest rather than of the run. `numpy.random.
default_rng` is the reproducible generator: the legacy `numpy.random.seed`
global is not guaranteed stable across versions, and PIL's PNG encoder is
deterministic for identical input.

The pins the current seed produces are in the manifest's comments; a change
of seed or of Pillow's zlib level moves them, and the manifest is the place
that records what they became.
"""
import argparse
import os

SEED = 20260910

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="/tmp/soak")
    ap.add_argument("--seed", type=int, default=SEED)
    args = ap.parse_args()

    import numpy as np
    from PIL import Image

    rng = np.random.default_rng(args.seed)
    os.makedirs(args.out, exist_ok=True)
    # Order matters: the generator is drawn from once per image, so
    # swapping these two changes both files.
    for name, shape in (("big.png", (1800, 1800, 3)),
                        ("small.png", (300, 400, 3))):
        path = os.path.join(args.out, name)
        Image.fromarray(rng.integers(0, 256, size=shape, dtype=np.uint8)).save(path)
        print("%s %d bytes" % (path, os.path.getsize(path)))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
