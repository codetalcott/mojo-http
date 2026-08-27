"""An application whose import fails two frames deep.

`smoke-serve`'s traceback case: `m0serve deep_fail:application` must exit 1
with the message naming the spec AND the Python traceback that names
``inner.py`` — the way a real project fails when its settings module raises
at import (a missing environment variable, a bad database URL). A missing
module or attribute, by contrast, stays a one-line message with no
traceback, because discovery tries four candidates and must stay quiet
about the misses.
"""

from .inner import settings

application = settings
