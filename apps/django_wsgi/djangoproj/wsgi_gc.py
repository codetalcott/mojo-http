"""The same application as `wsgi.py`, with CPython's cyclic GC configured
by `M0_GC` — a measurement module for the fast-route tail question
(docs/notes/pool-tail.md), not a deployment recommendation.

    M0_GC=freeze    gc.freeze() after the import: everything Django built at
                    startup moves to the permanent generation, so a gen-2
                    collection no longer walks it (Instagram's trick)
    M0_GC=disable   gc.disable(): no automatic collections at all for the run
    M0_GC=threshold gc.set_threshold(50000, 50, 50): collections ~70x rarer
    unset           the interpreter's defaults, i.e. exactly `wsgi.py`

Under `--workers N` this module is imported per worker after the fork, so
the setting applies in each.
"""

import gc
import os

from .wsgi import application  # noqa: F401  (re-exported)

_mode = os.environ.get("M0_GC", "")
if _mode == "freeze":
    gc.collect()
    gc.freeze()
elif _mode == "disable":
    gc.disable()
elif _mode == "threshold":
    gc.set_threshold(50000, 50, 50)
