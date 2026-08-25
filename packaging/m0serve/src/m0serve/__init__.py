"""m0serve — a WSGI/ASGI server for Python applications, written in Mojo.

The package is a thin wrapper around a compiled binary; see `__main__` for why
it is a package at all rather than a loose script.

`__version__` is read from installed metadata rather than written here. The
repository already keeps two copies of the version in step (`pyproject.toml`
and `M0SERVE_VERSION` in `packages/m0-wsgi/src/cli.mojo`, cross-checked by
`poe smoke-serve`); a literal here would be a third, and the one nobody
remembers to bump.
"""

__all__ = ["__version__"]


def __getattr__(name):
    if name == "__version__":
        from importlib.metadata import PackageNotFoundError, version

        try:
            return version("m0serve")
        except PackageNotFoundError:  # running from a source tree, not installed
            return "0+unknown"
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
