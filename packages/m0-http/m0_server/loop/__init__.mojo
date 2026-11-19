"""The event loop's modules, one for each thing the loop does.

`m0_server/event_loop.mojo` is their door: it holds the entry points
and the pass's outline, and its docstring says which module holds what.
Nothing in `m0_http` may import any of them, at any depth (DECISIONS D33).
"""
