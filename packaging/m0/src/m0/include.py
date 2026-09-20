"""`m0 include`: where the framework's source is."""

from m0 import paths


def run(args):
    print(paths.include_root())
    return 0
