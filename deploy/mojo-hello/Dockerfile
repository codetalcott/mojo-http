# syntax=docker/dockerfile:1
# A pure-Mojo image: the pinned toolchain compiles the app in a builder stage,
# and the runtime stage carries the binary, the Mojo runtime libraries beside
# it, and nothing else -- no interpreter, no toolchain.
#
#     docker build -f deploy/mojo-hello/Dockerfile --build-arg TARGET_CPU=generic .
#
# TARGET_CPU is never `native`: the machine that builds is not the machine
# that runs (`check_target_cpu_pinned` holds every distributable build task to
# that). Linux x86-64 -> x86-64-v2, Linux arm64 -> generic, as `build-serve`.

FROM python:3.13-slim AS build

# `mojo build` drives a C compiler for the link step -- without one it stops
# with "unable to find suitable c compiler for linking", so the toolchain
# wheel alone is not enough to compile an app. patchelf is what
# `relocate.py` uses to rewrite DT_RUNPATH; without it the binary keeps a
# search path pointing at the builder's venv. Both stay in this stage: the
# runtime image below gets neither.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates build-essential patchelf \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:0.9 /uv /usr/local/bin/uv

WORKDIR /src
# The toolchain alone: `mojo` is the only runtime dependency of this project,
# and the dev group (Django, pytest, poe) has no part in compiling an app.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev
ENV PATH="/src/.venv/bin:${PATH}"

COPY packages/ packages/
COPY apps/hello/ apps/hello/
COPY scripts/relocate.py scripts/bundle_artifact.py scripts/binfmt.py scripts/

# The package chain by hand rather than through poe, which lives in the dev
# group. Same commands as `build-core` and `build-http`.
RUN mojo precompile packages/m0-core/src -o packages/m0-core/m0_core.mojoc \
 && cd packages/m0-http && mojo precompile src -I ../m0-core/ -o m0_http.mojoc

ARG TARGET_CPU=generic
RUN mkdir -p /out && mojo build --target-cpu "${TARGET_CPU}" \
      -I packages/m0-core/ -I packages/m0-http/ \
      apps/hello/server.mojo -o /out/hello

# The build venv's path is recorded as a search path and has to go, and the
# Mojo runtime libraries have to travel: the runtime stage has no toolchain.
RUN python scripts/relocate.py --no-id --rpath '@loader_path' /out/hello \
 && python scripts/bundle_artifact.py --layout flat /out/hello /bundle \
 && ls -la /bundle


FROM debian:12-slim

RUN useradd --system --create-home --uid 10001 app
COPY --from=build /bundle/ /app/
USER app
WORKDIR /app

ENV M0_HOST=0.0.0.0 \
    M0_PORT=8080
EXPOSE 8080
ENTRYPOINT ["/app/hello"]
