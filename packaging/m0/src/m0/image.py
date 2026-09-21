"""`m0 image [--tag T] [--target-cpu CPU] [-- DOCKER_ARGS]`.

    docker build -f deploy/Dockerfile -t T [--build-arg TARGET_CPU=CPU] DOCKER_ARGS .

from the project's root, then the image's own `/app/about.json` -- what the
image measured of itself as its last layer -- as the last line of stdout.

Three things it deliberately is not:

- **It checks no toolchain.** The compiler runs inside the builder stage,
  so a machine with docker and nothing else builds the image; of the ONE
  list (`checks.py`) only `project` is asked. There is no `docker` check
  there, because `m0 doctor` reads that list whole and a machine without
  docker is not a broken one.
- **It interprets nothing docker says.** Docker missing, the daemon down,
  no `uv.lock` in the context, a compiler error in the builder: exit 1 with
  docker's output untouched, the closed set's "the tool m0 ran failed".
- **It does not deploy** (docs/DECISIONS.md D42). `deploy/README.md` is the
  runbook.

`--target-cpu` reaches `m0 build --release` inside the builder as the
Dockerfile's `TARGET_CPU` build argument; left alone, the release build
takes the platform's baseline. Arguments after `--` go to `docker build`
as they are (`--platform`, `--no-cache`, `--build-arg BASE=...`).
"""

import subprocess
import sys

from m0 import checks

DOCKERFILE = "deploy/Dockerfile"
ABOUT = "/app/about.json"


def build_argv(tag, target_cpu, docker_args):
    argv = ["docker", "build", "-f", DOCKERFILE, "-t", tag]
    if target_cpu:
        argv += ["--build-arg", f"TARGET_CPU={target_cpu}"]
    return argv + list(docker_args) + ["."]


def about_argv(tag):
    return ["docker", "run", "--rm", "--entrypoint", "cat", tag, ABOUT]


def _docker(argv, project):
    try:
        return subprocess.run(argv, cwd=project).returncode
    except OSError as exc:
        print(f"m0 image: {argv[0]}: {exc.strerror or exc}", file=sys.stderr)
        return 1


def run(args):
    project = args.project
    others = tuple(name for name, _ in checks.CHECKS if name != "project")
    failed = checks.preflight(project, skip=others)
    if failed is not None:
        return checks.refuse(failed)

    tag = args.tag or project.name
    if _docker(build_argv(tag, args.target_cpu, args.host_args), project) != 0:
        return 1
    sys.stdout.flush()
    return 1 if _docker(about_argv(tag), project) != 0 else 0
