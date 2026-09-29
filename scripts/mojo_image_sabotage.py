#!/usr/bin/env python3
"""Break each rule the Mojo image gate stands on, and insist it fails every time.

`poe smoke-blobs-image` (SPEC M26, M27) says a Mojo app's image is one binary
at PID 1 with no interpreter beside it, that the page's claims about the
image are the image's own measurements, and that `docker stop` is a drain.
A gate nobody has broken on purpose is a gate nobody knows works, so each
entry here builds a SABOTAGED image and requires the failure to land where
it should:

  * `probe` entries must build, then fail `mojo_image_probe.py` in the phase
    named -- a failure in any other phase is reported as MISSED, because a
    gate that fails for the wrong reason would pass the day that reason goes;
  * `build` entries are the rules the Dockerfile enforces itself, and the
    build must fail printing the text named.

Nothing tracked is edited: every entry copies the build context (what
`.dockerignore` lets in, minus `.mojoc` artifacts) to a temporary directory,
edits the copy -- the Dockerfile or a source file -- and builds that. The
layers before the edited one come from the build cache, so most entries
rebuild a layer or two. An anchor that does not match
exactly once is NOT APPLICABLE and counted as a miss -- re-point it with
the line. A `probe` entry whose image does not build is a miss, never a
catch. `sabotage_lib.py` owns everything around the table: each gate's
baseline, the unsabotaged image, must pass first, and SIGINT or SIGTERM
ends the build and removes the copy and the image before the harness dies
by the signal. Pre-release: ten sabotaged image builds after the two
baselines, most of them a layer or two.

    uv run poe sabotage-mojo-image
    uv run poe sabotage-mojo-image --only "PID 1"      entries by label substring
    uv run poe sabotage-mojo-image --only build        the Dockerfile's own refusals
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

from sabotage_lib import Gate, Outcome, rule, run, run_command

REPO = Path(__file__).resolve().parent.parent
DOCKERFILE = Path("deploy/mojo/Dockerfile")
ABOUT = Path("apps/blobs/about.mojo")
SERVER = Path("apps/blobs/server.mojo")
HOST = Path("packages/m0-http/m0_host/host.mojo")
LOOP_SHUTDOWN = Path("packages/m0-http/lightbug_http/loop/shutdown.mojo")

# What `.dockerignore` lets into the context, copied for a source sabotage.
CONTEXT = [
    ".dockerignore", "pyproject.toml", "uv.lock", "packages", "apps/hello", "apps/blobs",
    "scripts/relocate.py", "scripts/bundle_artifact.py", "scripts/binfmt.py",
    str(DOCKERFILE),
]

PYTHON_LAYER = (
    "RUN apt-get update && apt-get install -y --no-install-recommends python3-minimal \\\n"
    " && rm -rf /var/lib/apt/lists/*\n"
)

# (label, kind, file, old, new, expect): `kind` is "probe" (expect names
# the probe phase that must fail) or "build" (expect is text the failed
# build must print). `old`/`new` may be tuples for a rule that takes more
# than one edit, with `file` a tuple of the same length.
SABOTAGES = [
    (
        "a shell at PID 1 (the binary is its child, and SIGTERM stops at the shell)",
        "probe", DOCKERFILE,
        'ENTRYPOINT ["/app/server"]\n',
        'ENTRYPOINT ["/bin/sh", "-c", "/app/server"]\n',
        "the binary is PID 1",
    ),
    (
        "SIGTERM never reaches PID 1 (a stop signal the server ignores)",
        "probe", DOCKERFILE,
        'ENTRYPOINT ["/app/server"]\n',
        'STOPSIGNAL SIGWINCH\nENTRYPOINT ["/app/server"]\n',
        "docker stop is the drain",
    ),
    (
        "an interpreter added after the image measured itself",
        "probe", DOCKERFILE,
        "USER app\n",
        PYTHON_LAYER + "USER app\n",
        "no interpreter in the image",
    ),
    (
        "an interpreter in the image before it measures itself (the build refuses)",
        "build", DOCKERFILE,
        "# What the image is, measured from inside the image as its last layer and\n",
        PYTHON_LAYER + "# What the image is, measured from inside the image as its last layer and\n",
        "an interpreter is in the image",
    ),
    (
        "the image's size written as the registry's figure, not measured",
        "probe", DOCKERFILE,
        "    image_bytes=$(du -sxb / | cut -f1); \\\n",
        "    image_bytes=29333629; \\\n",
        "the image's facts are true",
    ),
    (
        # Not "relocate.py removed": bundle_artifact.py rewrites the copy it
        # bundles too, so that alone ships a working binary (measured).
        "the unrelocated binary shipped (the build refuses)",
        "build", DOCKERFILE,
        "RUN python scripts/relocate.py --no-id --rpath '@loader_path' /out/server \\\n"
        " && python scripts/bundle_artifact.py --layout flat /out/server /bundle \\\n",
        "RUN python scripts/bundle_artifact.py --layout flat /out/server /bundle \\\n"
        " && cp /out/server /bundle/server \\\n",
        "the bundled binary still names the build venv",
    ),
    (
        "the footer's size is the app's, not the image's",
        "probe", ABOUT,
        '        " · ", megabytes(facts.image_bytes), " unpacked, ",\n',
        '        " · ", megabytes(facts.app_bytes), " unpacked, ",\n',
        "the page says what the image is",
    ),
    # Not sabotaged: the footer's no-Python clause claimed without reading
    # the facts. No image that builds can say `python: true` -- the build
    # refuses first (above) -- so the probe cannot tell the two apart, and
    # the refusal is what holds the claim.
    (
        "the page rendered without its footer",
        "probe", SERVER,
        "        self.page_html = render_page(render_footer(facts))\n",
        "        self.page_html = render_page(String())\n",
        "the page says what the image is",
    ),
    (
        "/about is not the image's facts file",
        "probe", SERVER,
        '    return reply.json(200, "OK", st.facts.json)\n',
        '    return reply.json(200, "OK", \'{"version":"1.4.0"}\')\n',
        "the page says what the image is",
    ),
    (
        "the producer is never told to stop",
        "probe", (LOOP_SHUTDOWN, HOST),
        (
            "    if st.stop_addr != 0:\n"
            "        atomic_at(st.stop_addr)[].store(Int64(perf_counter_ns()))\n",
            "            block.set(BLK_STOP, now)\n",
        ),
        ("", ""),
        "docker stop is the drain",
    ),
]


PROBE, BUILD = "probe", "build"

# A probe entry's catch is the probe failing in the phase it names, in the
# probe's own words: its phase stamp also ANNOUNCES each phase as it begins
# (`--- name`), so the bare phase name would match a failure in a later one.
RULES = [rule(label, f, old, new, gate=kind,
              expect=f"FAIL: {expect}" if kind == PROBE else expect)
         for label, kind, f, old, new, expect in SABOTAGES]


def _copy_context(dest: Path) -> None:
    ignore = shutil.ignore_patterns("*.mojoc", "__pycache__", ".venv")
    for rel in CONTEXT:
        src = REPO / rel
        out = dest / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        if src.is_dir():
            shutil.copytree(src, out, ignore=ignore)
        else:
            shutil.copy2(src, out)


def _last(text: str) -> str:
    lines = [ln.strip() for ln in text.strip().splitlines() if ln.strip()]
    return lines[-1][:200] if lines else "(no output)"


class Image(Gate):
    """A copy of the build context holding the texts it is handed, built
    into an image: a `build` gate passes when the image builds, a `probe`
    gate when `mojo_image_probe.py` passes against it. The copy and the
    image go however the run ends -- a signal included, which ends the
    build's process group first (`run_command`)."""

    _target_cpu = ""

    def __init__(self, kind: str):
        self.kind = kind

    @classmethod
    def target_cpu(cls) -> str:
        """The daemon's baseline, asked once: never a host-tuned build. Its
        stdout alone: a warning on stderr is not the architecture."""
        if not cls._target_cpu:
            arch = subprocess.run(["docker", "info", "--format", "{{.Architecture}}"],
                                  cwd=REPO, capture_output=True, text=True,
                                  timeout=60).stdout.strip()
            cls._target_cpu = "x86-64-v2" if arch in ("x86_64", "amd64") else "generic"
        return cls._target_cpu

    def run(self, texts) -> Outcome:
        target_cpu = self.target_cpu()
        with tempfile.TemporaryDirectory(prefix="m0-image-sabotage-") as tmp:
            ctx = Path(tmp) / "ctx"
            _copy_context(ctx)
            for f, text in texts.items():
                (ctx / f).write_text(text)
            tag = f"m0-image-sabotage:{uuid.uuid4().hex[:8]}"
            try:
                build = run_command(
                    ["docker", "build", "-f", str(DOCKERFILE), "--build-arg", "APP=blobs",
                     "--build-arg", f"TARGET_CPU={target_cpu}", "-t", tag, "."],
                    timeout=1800, cwd=ctx)
                if self.kind == BUILD:
                    if build.returncode == 0:
                        return Outcome.passed(build.output)
                    if build.timed_out:
                        return Outcome.unclear("the build timed out", build.output)
                    return Outcome.failed("the build refused: " + _last(build.output),
                                          build.output)
                if build.returncode != 0:
                    return Outcome.unbuilt("the image did not build: " + _last(build.output),
                                           build.output)
                probe = run_command(
                    [sys.executable, str(REPO / "scripts" / "mojo_image_probe.py"),
                     "--app", "blobs", "--image", tag, "--target-cpu", target_cpu,
                     "--port", "18361"], timeout=1800, cwd=REPO)
                said = probe.output
                if probe.returncode == 0:
                    return Outcome.passed(said)
                line = next((ln for ln in said.splitlines() if "FAIL:" in ln), "")
                if probe.timed_out and not line:
                    return Outcome.unclear("the probe timed out without failing a phase",
                                           said)
                return Outcome.failed(line.strip()[:200] or _last(said), said)
            finally:
                run_command(["docker", "rmi", "-f", tag], timeout=120, cwd=REPO)


def main(argv: list[str]) -> int:
    return run("sabotage-mojo-image", RULES, {PROBE: Image(PROBE), BUILD: Image(BUILD)},
               argv, write=False)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
