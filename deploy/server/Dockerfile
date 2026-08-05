# syntax=docker/dockerfile:1
#
# Two-stage build. Stage 1 installs the toolchain and compiles the fork.
# Stage 2 is a thin runtime image — just the compiled binaries, no toolchain.
#
# Toolchain versions match this fork's actual pins:
#   Go   1.25.11  (build.assets/versions.mk)
#   Node 24.16.0  (build.assets/versions.mk)
#   Rust 1.94.0   (rust-toolchain.toml)
#
# All installs go through Ubuntu's own apt mirrors or vendor-direct
# downloads (go.dev, rustup.rs, nodejs.org via nvm) — deliberately NOT
# Debian's mirror network, which has had connectivity problems from some
# networks (see build.assets' own Node buildbox, which uses a Debian base
# and hits deb.debian.org — that's what this sidesteps).
#
# Build context MUST be the repo root (teleport/), not this directory —
# see docker-compose.yml's `context: ../..`.

FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ARG GO_VERSION=go1.25.11
ARG NODE_VERSION=24.16.0
ARG RUST_CHANNEL=1.94.0

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl git pkg-config wget tar ca-certificates \
    libpam0g-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Go — direct from go.dev, not apt
RUN wget -q "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"

# Rust — via rustup, not apt
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH="/usr/local/cargo/bin:${PATH}"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain "${RUST_CHANNEL}" --no-modify-path \
    && rustup target add wasm32-unknown-unknown --toolchain "${RUST_CHANNEL}"

# Node — via nvm (downloads prebuilt binaries from nodejs.org, not apt)
ENV NVM_DIR=/usr/local/nvm
RUN mkdir -p "$NVM_DIR" \
    && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash \
    && . "$NVM_DIR/nvm.sh" \
    && nvm install "${NODE_VERSION}" \
    && nvm alias default "${NODE_VERSION}"
ENV PATH="${NVM_DIR}/versions/node/v${NODE_VERSION}/bin:${PATH}"

WORKDIR /src
COPY . /src/

# Remove any stray package-main files that break the build
RUN for f in hello.go main.go; do \
        if [ -f "$f" ] && grep -q "^package main" "$f"; then rm "$f"; fi; \
    done

RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    make ensure-js-deps
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    make build-ui
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    make build/teleport build/tctl build/tsh

# ── Stage 2: thin runtime — only the compiled binaries ───────────────────────
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpam0g ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/build/teleport /usr/local/bin/teleport
COPY --from=builder /src/build/tctl     /usr/local/bin/tctl
COPY --from=builder /src/build/tsh      /usr/local/bin/tsh
COPY deploy/server/docker-entrypoint.sh /docker-entrypoint.sh

RUN chmod +x /docker-entrypoint.sh \
             /usr/local/bin/teleport \
             /usr/local/bin/tctl \
             /usr/local/bin/tsh

EXPOSE 3080 3022 3024 3025

ENTRYPOINT ["/docker-entrypoint.sh"]
