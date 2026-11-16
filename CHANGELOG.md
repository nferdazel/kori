# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Nothing in this file has been deployed. kori runs from a locally built binary; the deploy
templates under `ops/` describe the intended host shape and have not been run against one.

## [Unreleased]

### Added

- OAuth credential refresh per leg: an expired token is refreshed before the dial, a `401`
  buys one refresh and one retry, the rotated credential is written back to the config, and
  a refresh that fails stops the request with `502` instead of failing over.
- A leg's `model` is the id that leg is sent (DEC-10): the caller's top-level `model` is
  replaced with it on that leg alone, so one gateway can chain providers that do not share
  model ids. A leg without `model` still forwards the caller's body byte for byte.

## [0.3.0] - 2026-11-16

### Added

- Gateway door `POST /v1/chat/completions`, one [OI]-compatible surface in front of an
  ordered list of provider legs.
- Ordered failover with cooldown: a dead leg is skipped without a dial until its cooldown
  expires, and the next leg is tried in config order.
- Dead-route classification for `401`, `400 MissingSessionID`, connection refused, dial and
  TLS timeouts, header timeouts, `5xx`, and quota `429` with its longer cooldown. Client
  errors that belong to the caller are returned unchanged and never fail over.
- Per-phase deadlines enforced by the binary: connect, TLS, response headers for streaming
  and non-streaming, idle between chunks, and a whole-request limit.
- Append-only request log, one JSON line per request with nine keys: `ts`, `route`,
  `status`, `latency_ms`, `tokens_in`, `tokens_out`, `failover_from`, `failover_reason`,
  `stream`. No header, body or credential is ever written.
- `stream_options.include_usage` is set on streaming requests that omit it, so token counts
  come from the provider instead of being estimated.
- Read-only admin GETs: `/admin/state`, `/admin/log` with paging and filters, and
  `/admin/config` with every credential redacted. Any other method under `/admin/` is a
  `405` that names `GET`.
- `/healthz`, reporting the version and the git revision the binary was built from.
- Read-only dashboard with four pages: Overview, Requests, Routes and Config, served from a
  static table compiled into the binary. No file is read from disk at runtime.
- Deterministic embed step `tools/gen-static.sh`, so a stale dashboard embed shows up as a
  git diff instead of shipping silently.
- Acceptance harness `acceptance/`, ten end-to-end cases against a real binary, plus a
  self-test that proves the harness fails when it should. Every case allocates a free port
  per run, so a run leaves nothing behind.
- `./task` as the single entry point for the checks: `ops`, `web`, `nim`, `check`, `help`.

### Security

- The config file holds every provider credential, is read from a path outside the
  repository, and is never baked into an image.
- The listener binds loopback by default; the container template publishes
  `127.0.0.1` only, and the edge template gates the door with a bearer token, a per-IP rate
  limit and a Cloudflare-range allow list.

### CI

- Seven jobs: `Contract`, `Security`, `Ops`, `Nim`, `Gate`, `Image: api`, `Web`. Every job
  has a 15-minute timeout, caches its toolchain, and passes event data through `env:`.
- The `Nim` job fails on static-embed drift and runs the acceptance suite against a release
  build.
- `Security` runs a gitleaks scan over the full history.
