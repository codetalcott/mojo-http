"""Sentinel for src-import binding — deliberately colliding.

Every package defines a module with THIS name, so `from src.which_package
import PACKAGE_NAME` can only resolve one package's copy — and
`test_resolution.mojo` asserts it resolved its own. See that file for the
actual binding rules; the short version is that `test/__init__.mojo` makes
the binding structural, and this pair fails loudly if that ever erodes into
the silent cross-package misbinding it replaced.
"""

comptime PACKAGE_NAME = "m0-sqlite"
