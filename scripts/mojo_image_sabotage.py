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
the line. Pre-release: ten image builds, most of them a layer or two.

    uv run poe sabotage-mojo-image
    uv run poe sabotage-mojo-image --only pid        one entry, by label substring
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DOCKERFILE = Path("deploy/mojo/Dockerfile")
ABOUT = Path("apps/blobs/about.mojo")
SERVER = Path("apps/blobs/server.mojo")
HOST = Path("packages/m0-http/m0_host/host.mojo")
EVENT_LOOP = Path("packages/m0-http/lightbug_http/event_loop.mojo")

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
        "probe", (EVENT_LOOP, HOST),
        (
            "    if st.stop_addr != 0:\n"
            "        atomic_at(st.stop_addr)[].store(Int64(perf_counter_ns()))\n",
            "            block.set(BLK_STOP, now)\n",
        ),
        ("", ""),
        "docker stop is the drain",
    ),
]


def _edits(entry):
    _, _, files, olds, news, _ = entry
    if isinstance(olds, tuple):
        return list(zip(files, olds, news))
    return [(files, olds, news)]


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


def _run(argv, cwd, timeout=1800):
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def _tail(text: str, n: int = 12) -> str:
    return "\n".join("      " + ln for ln in text.strip().splitlines()[-n:])


def attempt(entry, target_cpu: str) -> tuple[str, str]:
    label, kind, _, _, _, expect = entry
    with tempfile.TemporaryDirectory(prefix="m0-image-sabotage-") as tmp:
        ctx = Path(tmp) / "ctx"
        _copy_context(ctx)
        for f, old, new in _edits(entry):
            path = ctx / f
            text = path.read_text()
            if text.count(old) != 1:
                return "NOT APPLICABLE", f"anchor matched {text.count(old)} times in {f}"
            path.write_text(text.replace(old, new))
        tag = f"m0-image-sabotage:{uuid.uuid4().hex[:8]}"
        build = _run(["docker", "build", "-f", str(DOCKERFILE), "--build-arg", "APP=blobs",
                      "--build-arg", f"TARGET_CPU={target_cpu}", "-t", tag, "."], cwd=ctx)
        try:
            out = build.stdout + build.stderr
            if kind == "build":
                if build.returncode == 0:
                    return "MISSED", "the build succeeded"
                if expect not in out:
                    return "MISSED", f"the build failed, but not with {expect!r}:\n{_tail(out)}"
                return "CAUGHT", f"the build refused ({expect!r})"
            if build.returncode != 0:
                return "BROKEN", f"the sabotaged image did not build:\n{_tail(out)}"
            probe = _run([sys.executable, str(REPO / "scripts" / "mojo_image_probe.py"), "--app", "blobs",
                          "--image", tag, "--target-cpu", target_cpu, "--port", "18361"], cwd=REPO)
            said = probe.stdout + probe.stderr
            if probe.returncode == 0:
                return "MISSED", "the probe passed"
            if f"FAIL: {expect}" not in said:
                return "MISSED", f"the probe failed, but not in {expect!r}:\n{_tail(said)}"
            line = next((ln for ln in said.splitlines() if "FAIL:" in ln), "")
            return "CAUGHT", line.strip()[:200]
        finally:
            _run(["docker", "rmi", "-f", tag], cwd=REPO)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--only", default="", help="run the entries whose label contains this")
    args = ap.parse_args()
    arch = _run(["docker", "info", "--format", "{{.Architecture}}"], cwd=REPO).stdout.strip()
    target_cpu = "x86-64-v2" if arch in ("x86_64", "amd64") else "generic"
    chosen = [e for e in SABOTAGES if args.only in e[0]]
    if not chosen:
        print(f"no sabotage matches {args.only!r}")
        return 2
    caught = 0
    for entry in chosen:
        verdict, why = attempt(entry, target_cpu)
        print(f"{verdict:14} {entry[0]}\n      {why}", flush=True)
        caught += verdict == "CAUGHT"
    print(f"\n{caught} of {len(chosen)} caught"
          + ("" if len(chosen) == len(SABOTAGES) else f" (of {len(SABOTAGES)}; --only {args.only!r})"))
    return 0 if caught == len(chosen) else 1


if __name__ == "__main__":
    sys.exit(main())
