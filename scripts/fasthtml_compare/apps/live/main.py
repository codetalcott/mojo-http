"""`live=True`: the scenario edits VERSION and waits for the reloaded page."""
from fasthtml.common import *
VERSION = "v1"
app, rt = fast_app(live=True)
@rt("/")
def get(): return Titled("Live", P(f"version {VERSION}"))
