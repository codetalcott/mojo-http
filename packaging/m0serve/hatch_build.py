"""Force the wheel's platform tag to the one measured from the staged binaries.

Hatchling would otherwise infer a tag from the interpreter running the build,
which for a package whose payload is a compiled binary is the wrong source of
truth twice over: it would name a CPython ABI the wheel does not have, and it
would say nothing about the SDK or glibc the binary actually requires.

`scripts/wheel_tag.py` derives the answer from the files themselves. This hook
only refuses to proceed without it -- deliberately loud, because the failure it
prevents (a wheel that installs where it cannot run) is silent.
"""

import os

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class CustomBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version, build_data):
        tag = os.environ.get("M0SERVE_WHEEL_TAG")
        if not tag:
            raise ValueError(
                "M0SERVE_WHEEL_TAG is not set. The platform tag is MEASURED "
                "from the staged binaries by scripts/wheel_tag.py, never "
                "inferred from the build interpreter — build with "
                "`uv run poe build-wheel`, not a bare `uv build`."
            )
        build_data["pure_python"] = False
        build_data["infer_tag"] = False
        build_data["tag"] = tag
