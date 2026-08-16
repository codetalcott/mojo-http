"""Pins src-import binding: our own `src` must win the name collision.

Every package's sources live in a directory named `src`. What actually
binds `from src.x import` in a test file, measured against the toolchain:
with `test/__init__.mojo` present, the test is part of its package and its
own `src` wins REGARDLESS of -I order; without it, the first -I root wins
— which is how test-wsgi (the one package then missing the marker) once
came to need its own package listed first, and how that observation got
over-generalized into an ordering rule.

Both protections now exist: every test/ has the marker, and every test task
still lists its package first. This test fails loudly if either erodes —
`which_package.mojo` exists in every package under the same name, so a
misbinding imports another package's sentinel instead of silently compiling
another package's modules.
"""

from std.testing import assert_equal, TestSuite

from src.which_package import PACKAGE_NAME


def test_our_own_src_wins_the_name_collision() raises:
    assert_equal(PACKAGE_NAME, "m0-sqlite")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
