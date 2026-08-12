# syntax=docker/dockerfile:1
#
# Four-stage build: builder (toolchain+source) -> ui-builder (frontend) ->
# binaries (Go compile, needs ui-builder's webassets for go:embed) -> thin
# runtime (just the compiled binaries, no toolchain).
#
# The split lets you build/test just the frontend in isolation without
# touching the Go compile at all:
#   docker build -f deploy/server/Dockerfile --target ui-builder -t teleport-ui .
# (run from the repo root — same context as the real build)
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

# ── Stage: frontend only ──────────────────────────────────────────────────────
# Isolated so `docker build --target ui-builder` builds/verifies just the
# JS/webassets, skipping the Go compile entirely.
FROM builder AS ui-builder

# pnpm store (content-addressable download cache) + the project's actual
# node_modules (resolved symlink tree, which also holds webpack's own
# persistent build cache under node_modules/.cache) both need caching —
# without the store, every build re-downloads every JS package; without
# node_modules too, every build re-links them and re-bundles from scratch
# even when nothing changed. Both mounts must be repeated on every RUN that
# touches JS — a cache mount only exists for the duration of the RUN it's
# declared on, its content doesn't persist into the image layer for later
# steps.
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/root/.local/share/pnpm/store \
    --mount=type=cache,target=/src/node_modules \
    make ensure-js-deps
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/root/.local/share/pnpm/store \
    --mount=type=cache,target=/src/node_modules \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    make build-ui

# ── Stage: Go binaries — needs ui-builder's webassets for go:embed ──────────
FROM ui-builder AS binaries

# `teleport`/`tsh`'s Make targets are .PHONY and unconditionally depend on
# `rdpclient`/`rdpdecoder` (Windows desktop RDP support), which are separate
# `cargo build --release` invocations — these run on every single build
# regardless of what changed, and without a cache mount here they were
# re-downloading every crate from scratch and fully recompiling in release
# mode every time. CARGO_HOME=/usr/local/cargo (set earlier), and cargo's
# own build output defaults to <repo root>/target/ (no CARGO_TARGET_DIR set).
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    make build/teleport build/tctl build/tsh

# ── Stage: thin runtime — only the compiled binaries ─────────────────────────
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpam0g ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=binaries /src/build/teleport /usr/local/bin/teleport
COPY --from=binaries /src/build/tctl     /usr/local/bin/tctl
COPY --from=binaries /src/build/tsh      /usr/local/bin/tsh
COPY deploy/server/docker-entrypoint.sh /docker-entrypoint.sh

RUN chmod +x /docker-entrypoint.sh \
             /usr/local/bin/teleport \
             /usr/local/bin/tctl \
             /usr/local/bin/tsh

EXPOSE 3080 3022 3024 3025

ENTRYPOINT ["/docker-entrypoint.sh"]
