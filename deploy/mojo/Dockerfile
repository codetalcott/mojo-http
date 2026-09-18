# syntax=docker/dockerfile:1
# A pure-Mojo image: the pinned toolchain compiles one app in a builder stage,
# and the runtime stage carries the binary, the Mojo runtime libraries beside
# it, and nothing else -- no interpreter, no toolchain.
#
#     docker build -f deploy/mojo/Dockerfile --build-arg APP=blobs \
#       --build-arg TARGET_CPU=generic .
#
# ONE Dockerfile for every Mojo app (`APP` names a directory under `apps/`
# with a `server.mojo`), because two near-copies are how two images drift:
# the toolchain, the package chain, the relocation and the runtime stage are
# the same for all of them, and what differs is one directory. The binary is
# `/app/server` whatever the app, since an exec-form ENTRYPOINT cannot expand
# a build argument and a shell form would put `sh` at PID 1.
#
# TARGET_CPU is never `native`: the machine that builds is not the machine
# that runs (`check_target_cpu_pinned` holds every distributable build task to
# that). Linux x86-64 -> x86-64-v2, Linux arm64 -> generic, as `build-serve`.

ARG BASE=debian:12-slim

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
COPY scripts/relocate.py scripts/bundle_artifact.py scripts/binfmt.py scripts/

# The package chain by hand rather than through poe, which lives in the dev
# group. Same commands as `build-core`, `build-http` and `build-datastar`,
# and before the app is copied in, so every app shares this layer.
RUN mojo precompile packages/m0-core/src -o packages/m0-core/m0_core.mojoc \
 && cd packages/m0-http && mojo precompile src -I ../m0-core/ -o m0_http.mojoc \
 && cd ../m0-datastar && mojo precompile src -I ../m0-http/ -I ../m0-core/ -o m0_datastar.mojoc

ARG APP=hello
ARG TARGET_CPU=generic
COPY apps/ apps/
# `-I apps/` for an app's own sibling modules (`blobs.kernel`).
RUN test -f "apps/${APP}/server.mojo" \
 && mkdir -p /out && mojo build --target-cpu "${TARGET_CPU}" \
      -I packages/m0-core/ -I packages/m0-http/ -I packages/m0-datastar/ -I apps/ \
      "apps/${APP}/server.mojo" -o /out/server \
 && sed -n 's/^version = "\(.*\)"$/\1/p' pyproject.toml | head -1 > /out/version

# The build venv's path is recorded as a search path and has to go, and the
# Mojo runtime libraries have to travel: the runtime stage has no toolchain.
# `bundle_artifact.py` rewrites the copy it bundles to `$ORIGIN` as well, so
# `relocate.py` is the same belt `build-serve` wears; the grep is the check
# that the binary SHIPPED is rewritten -- one that still names the builder's
# venv loads nothing in the runtime stage.
RUN python scripts/relocate.py --no-id --rpath '@loader_path' /out/server \
 && python scripts/bundle_artifact.py --layout flat /out/server /bundle \
 && if grep -q /src/.venv /bundle/server; then \
      echo "the bundled binary still names the build venv" >&2; exit 1; fi \
 && ls -la /bundle


FROM ${BASE}

ARG BASE
ARG APP=hello
ARG TARGET_CPU=generic
RUN useradd --system --create-home --uid 10001 app
COPY --from=build /bundle/ /app/
COPY --from=build /out/version /tmp/version

# What the image is, measured from inside the image as its last layer and
# written where the app can say it (`M0_IMAGE_FACTS`): a page that claims
# "no Python in this image" and a size reads both from here, so neither is
# prose. The build FAILS if an interpreter is present rather than writing a
# false line. Sizes are unpacked bytes (`du`, what the running filesystem
# holds); the compressed size a registry shows depends on the daemon's
# store and is recorded by the probe, not here.
RUN set -e; \
    if command -v python3 || command -v python \
       || find / -xdev \( -name 'python[0-9]*' -o -name 'libpython*' \) \
            \( -type f -o -type l \) | grep -q .; then \
      echo "an interpreter is in the image" >&2; exit 1; \
    fi; \
    version=$(cat /tmp/version); rm /tmp/version; \
    app_bytes=$(du -sb /app | cut -f1); \
    image_bytes=$(du -sxb / | cut -f1); \
    printf '{"app":"%s","version":"%s","target_cpu":"%s","arch":"%s","base":"%s","python":false,"app_bytes":%s,"image_bytes":%s}\n' \
      "$APP" "$version" "$TARGET_CPU" "$(uname -m)" "$BASE" "$app_bytes" "$image_bytes" > /app/about.json; \
    cat /app/about.json

USER app
WORKDIR /app

ENV M0_HOST=0.0.0.0 \
    M0_PORT=8080 \
    M0_IMAGE_FACTS=/app/about.json
EXPOSE 8080
ENTRYPOINT ["/app/server"]
