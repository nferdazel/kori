# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Nothing in this file has been deployed. kori runs from a locally built binary; the deploy
templates under `ops/` describe the intended host shape and have not been run against one.

## [Unreleased]

## [0.5.2] - 2026-11-17

### Fixed

- The `KORI_REVISION` build-arg guard tested only that the value was non-empty, so an argument
  of spaces passed it. `config.nims` then found nothing usable in the value, the build fell
  through to git, `.git` is not in the build context, and the image reported `dev` again with
  no error — the symptom 0.5.1 was meant to close. The guard now requires a git sha shape
  (lowercase hex, 7 to 40 characters) and fails the build otherwise.
- The revision reaches the startup line and `/healthz` verbatim, and nothing checked what it
  contained, so a newline or a control character in the build-arg could forge a log line. The
  same shape check in `config.nims` rejects it before the build, and the value is no longer
  trimmed into something the environment did not say.

## [0.5.1] - 2026-11-17

### Fixed

- An image built from this tree reported `dev` on `/healthz` and in the startup line. The
  revision was read from git inside the build context, and `.git` is not part of that context,
  so the answer depended on whether a checkout happened to sit next to the Dockerfile.
  `KORI_REVISION` is now a required build-arg that fails the build when it is missing, a new
  `.dockerignore` keeps `.git` out of the context, and `config.nims` prefers the environment
  over git, so a local build still reports the commit it was built from.

## [0.5.0] - 2026-11-17

### Added

- Per-leg `enabled`: a leg set to `false` keeps its place in the failover order but is never
  dialled, and `/admin/state` reads it as `skipped`.
- Per-leg `aliases`: a caller model of `kori/<alias>` resolves through each leg's own table,
  so one caller-facing name can reach a different provider id on each leg. A leg with no
  entry for the name is skipped for that request without a cooldown and records
  `alias_unmapped` in the log; a name no leg maps is a `400` with an `unknown_alias` body; the
  response `model` still names the provider id the serving leg actually sent.
- The request log carries a tenth key, `alias`, holding the caller's `kori/<alias>` exactly
  as sent and only on a request that named one. A request that named a provider id has no
  `alias` key at all, not an empty one. `/admin/log` takes an `alias` filter that matches only
  rows carrying the key.
- An alias is bounded at 256 bytes before any leg is touched: a longer name is a `400`
  `alias_too_long` whose body is fixed text that never repeats the name, and the log keeps the
  first 261 bytes of it (`MaxAliasBytes` plus the `kori/` prefix) so the line still says which
  request it was.

### Changed

- The deploy templates widen the stop budget so the drain fits inside it: the binary drains
  for 5 s, podman gets `StopTimeout=15` and systemd `TimeoutStopSec=25`. `StopTimeout` is
  written by the deploy because quadlet only honours it from podman 4.4; an older podman is
  detected and the key left out with a warning instead of being silently ignored. The unit is
  staged once, so the compare, the install and the gate read the same bytes, and an unchanged
  unit is no longer rewritten.
- `README.md` and `docs/DECISIONS.md` describe the ten-key log, the two leg fields and the
  request-side alias rules, so the feature can be switched on from the documents alone.

### Fixed

- A container stop no longer ends in exit 137. kori is PID 1 in its container, so the kernel
  discarded the `SIGTERM` podman sent, podman `SIGKILL`ed at its timeout, the unit failed and
  `OnFailure=alert@` fired a false critical on every deploy. The binary now installs
  `SIGTERM`/`SIGINT` handlers, closes the listener, waits up to 5 s for in-flight requests to
  reach zero and exits 0.
- The drain no longer reports an exit it did not have: it re-reads the in-flight count after
  the wait loop, and a cut-short drain prints `drained X of Y ... N still in flight` and exits
  75 instead of the line a clean drain prints. `75` is deliberately absent from
  `RestartPreventExitStatus`, so the service still comes back on its own.
- A request whose alias was unknown *and* whose legs were all cooling wrote a `400` body and
  then a `502` body on the same connection, with the status staying `400`. The cooling branch
  now sits behind the same flag the rest of the handler uses, so one connection gets one body.
- The alias log budget counts the `kori/` prefix (261 bytes), so a legal 252-256 byte alias
  survives whole and still matches its own `?alias=` filter, and the cut backs off to a rune
  boundary instead of leaving half a rune in the line.

## [0.4.0] - 2026-11-17

### Added

- OAuth credential refresh per leg: an expired token is refreshed before the dial, a `401`
  buys one refresh and one retry, the rotated credential is written back to the config, and
  a refresh that fails stops the request with `502` instead of failing over.
- A leg's `model` is the id that leg is sent (DEC-10): the caller's top-level `model` is
  replaced with it on that leg alone, so one gateway can chain providers that do not share
  model ids. A leg without `model` still forwards the caller's body byte for byte.
- `/admin/state` carries window token totals (`window.tokens_in`, `window.tokens_out`), summed
  from the usage each served request reported, and the dashboard shows them as a sixth
  readout so cost is visible without opening the log.

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
