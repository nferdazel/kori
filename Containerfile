# syntax=docker/dockerfile:1
#
# kori image: one Nim binary, dashboard embedded, no node and no npm in the runtime layer.
#
# Build context = repo root. Three stages:
#   web     node + vite, produces apps/web/dist
#   build   Nim, generates the staticRead module from dist, compiles kori
#   runtime debian-slim, binary only
#
# Everything below is pinned. A floating base tag means two builds of the same commit can
# produce different runtimes; the digests are the ones already used by the house images and
# must be bumped in review, not automatically.

# DEBIAN_DIGEST is the index digest the house images already pin (cbs apps/api/Dockerfile,
# 21 Oct 2026) — copied, not invented.
ARG DEBIAN_DIGEST=sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
# NODE_DIGEST has no default: read it with
#   podman manifest inspect node:22-bookworm-slim | jq -r .digest
# and pass it. A made-up digest fails the pull, but a made-up-looking one in a repo is worse than
# none, because the next person copies it.
ARG NODE_DIGEST=

# ── stage 1: dashboard ───────────────────────────────────────────────────────
FROM node:22-bookworm-slim@${NODE_DIGEST} AS web
ARG NODE_DIGEST

WORKDIR /web
# `npm ci` needs the lockfile; without one the build is not reproducible and should fail here,
# not in production.
COPY apps/web/package.json apps/web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY apps/web/ ./
RUN npm run build
# Vite writes apps/web/dist. Fixed filenames, no content hashes: the embed step needs a stable
# file list, and the binary is the cache key anyway.

# ── stage 2: nim ────────────────────────────────────────────────────────────
FROM debian:bookworm-slim@${DEBIAN_DIGEST} AS build

# Nim tarball is verified, not trusted: a swapped tarball builds "successfully" with code that
# is not ours. NIM_SHA256 has no default on purpose — read it from nim-lang.org/download and
# pass it, so the value is a decision someone made rather than a number a model invented.
ARG NIM_VERSION=2.4.2
ARG NIM_SHA256=
RUN [ -n "$NIM_SHA256" ] || { echo "NIM_SHA256 build-arg is required" >&2; exit 1; }

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils git build-essential libssl-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz" -o /tmp/nim.tar.xz \
    && echo "${NIM_SHA256}  /tmp/nim.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/nim \
    && tar -xJf /tmp/nim.tar.xz -C /opt/nim --strip-components=1 \
    && rm -f /tmp/nim.tar.xz
ENV PATH="/opt/nim/bin:${PATH}"

WORKDIR /src
COPY kori.nimble ./
RUN nimble install -d -y

COPY . .
# Dashboard first, then the module that embeds it, then the compiler. If dist is stale the
# binary serves a stale page with no error anywhere — that is the failure this order prevents.
COPY --from=web /web/dist ./apps/web/dist
RUN sh tools/gen-static.sh apps/web/dist src/generated/static_files.nim
RUN nim c -d:release --mm:orc --threads:on --hints:off --out:/out/kori apps/api/src/kori.nim

# ── stage 3: runtime ────────────────────────────────────────────────────────
FROM debian:bookworm-slim@${DEBIAN_DIGEST} AS runtime

# libssl3 + ca-certificates: the gateway dials providers over TLS. Without them the binary starts
# and every leg fails at the first handshake, which reads as a provider outage.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libssl3 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 10001 kori && useradd -u 10001 -g 10001 -M -s /usr/sbin/nologin kori

COPY --from=build /out/kori /usr/local/bin/kori
USER 10001:10001
# 0.0.0.0 inside the container is required by rootless port forwarding; the host publishes
# 127.0.0.1 only (see ops/systemd/kori-api.container and OPS-SHIP §4.1).
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/kori"]
