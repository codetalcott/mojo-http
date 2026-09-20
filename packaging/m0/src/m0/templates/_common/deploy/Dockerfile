# syntax=docker/dockerfile:1
# A pure-Mojo image: the pinned toolchain compiles the app in a builder
# stage, and the runtime stage carries the binary, the Mojo runtime
# libraries beside it, and nothing else -- no interpreter, no toolchain.
#
#     docker build -f deploy/Dockerfile -t __M0_APP__ .      (from the project root)
#
# The builder runs what you run: `uv sync`, then `uv run m0 build --release`,
# which compiles for the platform's BASELINE CPU (never the builder's own:
# the machine that builds is not the machine that runs), rewrites the
# binary's library search path to its own directory and bundles the runtime
# into dist/.

ARG BASE=debian:12-slim

FROM python:3.13-slim AS build

# `mojo build` links through the name `cc`; patchelf rewrites the search
# path. Both stay in this stage.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates build-essential patchelf \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:0.9 /uv /usr/local/bin/uv

WORKDIR /src
# The toolchain first, so an edit to src/ does not download it again.
# uv.lock must exist: run `uv sync` once and commit it.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen

COPY src/ src/
RUN uv run --frozen m0 build --release \
 && sed -n 's/^version = "\(.*\)"$/\1/p' pyproject.toml | head -1 > /tmp/version


FROM ${BASE}

ARG BASE
RUN useradd --system --create-home --uid 10001 app
COPY --from=build /src/dist/ /app/
COPY --from=build /tmp/version /tmp/version

# What the image is, measured from inside it as its last layer. The build
# FAILS if an interpreter is present rather than writing a false line.
RUN set -e; \
    if command -v python3 || command -v python \
       || find / -xdev \( -name 'python[0-9]*' -o -name 'libpython*' \) \
            \( -type f -o -type l \) | grep -q .; then \
      echo "an interpreter is in the image" >&2; exit 1; \
    fi; \
    version=$(cat /tmp/version); rm /tmp/version; \
    app_bytes=$(du -sb /app | cut -f1); \
    image_bytes=$(du -sxb / | cut -f1); \
    printf '{"app":"%s","version":"%s","arch":"%s","base":"%s","python":false,"app_bytes":%s,"image_bytes":%s}\n' \
      "__M0_APP__" "$version" "$(uname -m)" "$BASE" "$app_bytes" "$image_bytes" > /app/about.json; \
    cat /app/about.json

USER app
WORKDIR /app

ENV M0_HOST=0.0.0.0 \
    M0_PORT=8080
EXPOSE 8080
ENTRYPOINT ["/app/server"]
