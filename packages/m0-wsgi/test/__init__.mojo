# m0-wsgi tests
#
# This file is load-bearing: with test/ marked as a package, a test file's
# `from src.x import` binds to THIS package's src regardless of -I order.
# Without it, resolution falls back to -I order — which is why test-wsgi
# once had to list its own package first. test_resolution.mojo guards this.
