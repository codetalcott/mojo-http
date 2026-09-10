"""The Python arm of `poe bench-mojo-mount`.

Reproduces `MojoMount`'s corpus exactly -- same LCG, same seed, same draw
order -- so both arms score the same data and their top-k must agree. There
is no fixture file: the generator IS the fixture.

`/search` is deliberately numpy's BEST shape for the job. At a selectivity it
gathers the eligible rows and hands one contiguous matvec to BLAS, which is
faster than scoring everything and masking. What it cannot do is avoid the
gather, and the gather holds the GIL -- which is the whole comparison.
"""

import json

import numpy as np

ROWS = 4096
DIMS = 256
SEED = 20260910
_MASK = (1 << 64) - 1


def _corpus():
    state = SEED
    total = ROWS * DIMS
    flat = np.empty(total, dtype=np.float32)
    tags = np.empty(ROWS, dtype=np.uint8)

    def nxt():
        nonlocal state
        state = (state * 6364136223846793005 + 1442695040888963407) & _MASK
        return (state >> 33) & 0x7FFFFFFF

    i = 0
    for r in range(ROWS):
        for _ in range(DIMS):
            flat[i] = nxt() / 1073741824.0 - 1.0
            i += 1
        tags[r] = nxt() % 100
    query = np.empty(DIMS, dtype=np.float32)
    for d in range(DIMS):
        query[d] = nxt() / 1073741824.0 - 1.0
    return flat.reshape(ROWS, DIMS), tags, query


_VECS, _TAGS, _QUERY = _corpus()


def _search(sel, k):
    if sel >= 100:
        scores = _VECS @ _QUERY
        top = np.argpartition(-scores, k)[:k]
        return [int(i) for i in top[np.argsort(-scores[top])]]
    idx = np.flatnonzero(_TAGS < sel)      # the gather; holds the GIL
    scores = _VECS[idx] @ _QUERY
    order = np.argsort(-scores)[:k]
    return [int(idx[i]) for i in order]


def _qint(qs, key, fallback):
    for part in qs.split("&"):
        if part.startswith(key + "="):
            try:
                return int(part[len(key) + 1:])
            except ValueError:
                return fallback
    return fallback


def application(environ, start_response):
    path = environ.get("PATH_INFO", "/")
    if path.endswith("/search"):
        qs = environ.get("QUERY_STRING", "")
        sel = _qint(qs, "sel", 100)
        k = _qint(qs, "k", 10)
        sel = 100 if sel < 1 or sel > 100 else sel
        k = 10 if k < 1 or k > 64 else k
        body = json.dumps(
            {"mount": "python", "sel": sel, "top": _search(sel, k)}
        ).encode()
    else:
        body = b'{"mount":"python"}'
    start_response("200 OK", [("Content-Type", "application/json"),
                              ("Content-Length", str(len(body)))])
    return [body]
