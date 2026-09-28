"""A project whose ASGI entry point raises on import and whose WSGI one does not.

`smoke-serve`'s discovery case. A bare `split_fail` tries `split_fail`, then
`split_fail.asgi`, then `split_fail.wsgi`: the first is a quiet miss (no
`application` here), and the second RAISES, which is the answer rather than
a miss -- a project whose settings cannot load must say so, with the
traceback naming ``asgi.py``, and must never be served through the next
convention instead. `--mount /=split_fail` used to do exactly that: the
mount resolver lacked the positional one's re-raise, so it skipped the
traceback and served ``wsgi.py`` (review record B8).
"""
