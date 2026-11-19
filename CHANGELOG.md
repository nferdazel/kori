# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

0.6.0 was the first release deployed to qouver1, on 2026-11-18, behind the Caddy edge that `ops/`
describes. The host records the revision it actually runs in `.deployed_rev`, and that file, not
this one, is the answer to "what is live".

## [Unreleased]

### Security

- The admin surface is gated (`DEC-20`). `/admin/*`, `/metrics`, `/healthz?deep` and the five
  dashboard pages now need one shared token, sent as `Authorization: Bearer` by a script or a scrape,
  or carried as the `kori_admin` cookie a browser gets from `POST /session/login`.
  `POST /session/logout` drops the session; both live outside `/admin/`, which stays GET/HEAD-only with
  `405` on every other method. Five failed logins in five minutes answer `429`, counted globally.
  The token is a file, `KORI_ADMIN_TOKEN_FILE`, default `/etc/kori/admin.token`, read on every
  request, so a new value takes effect for new logins without a restart; a session already issued is
  checked against the session table, so rotating a token that may have leaked is the new file plus a
  restart of `kori-api`. It never sits in `config.json`,
  in `/admin/config` or in the request log. A host with no token file, or an empty one, answers `404` on
  every gated surface rather than `401`: the dashboard stays dark until the file exists, and a
  gateway with no admin token does not advertise that it has one. `/healthz` and `/v1/*` are
  unchanged, and `/healthz` is now the deploy gate: `deploy-vps.sh`, `rollback.sh` and `smoke.sh`
  probe it instead of `/admin/state`. One shared token means no per-person identity and no MFA.

### Fixed

- `ops/etc/config.json.example` priced the wrong ids. It carried `deepseek-v4.1-flash` at
  0.27/1.10 and `glm-5.3-flash` at 0.60/2.20, which are the caller names of the 0.6.x
  opencode-go leg, while a leg's price is looked up by the id that leg actually sends
  (`DEC-16`). A config regenerated from the template therefore logged no `cost_usd` on the
  commandcode and sinarcloud legs and none at all for a System One decision. The template now
  prices the ids the two chained legs send: `deepseek/deepseek-v4.1-flash` and
  `deepseek/deepseek-v4-1-flash` at 0.30/1.20, `z-ai/glm-5.3-flash` at 0.15/0.50 and
  `typesafe/jev-1.14.0` at 0.042/0.0 — the prices the host ran on 2026-11-18 — and keeps the two
  caller-name entries above, for a config that still chains the old leg.

### Changed

- The dashboard footer names the gate it actually sits behind ("read-only · token required") instead
  of claiming the surface is loopback only, which stopped being true when `dash.qouver.com` was
  published. A browser without a session is sent to `/login.html`; a script gets `401` JSON.
- `ops/etc/config.json.example` now chains the two legs qouver1 actually runs: `commandcode` as
  primary and `sinarcloud` as fallback, each with the `model` id it is sent (`deepseek/deepseek-v4.1-flash`
  and `deepseek/deepseek-v4-1-flash`). The `opencode-go` leg is gone from the template, because a config
  regenerated from it produced a three-leg chain the host does not run and needed three OpenCode OAuth
  values nothing would use. `ops/scripts/kori-config.sh` now requires a value only when the template
  carries its placeholder, so the two-leg template needs the two `api_key` values alone; adding the leg
  back to the template makes the OpenCode values required again.

## [0.7.0] - 2026-11-18

### Added

- `POST /v1/systemone`: a second door for a decision model that is not a chat model (`DEC-19`). The
  caller's body is forwarded byte for byte with one field replaced, the top-level `model`, so a
  caller name such as `jev-latest` becomes the provider id the leg is configured for. The answer is
  returned untouched. Its upstreams live in a separate `systemone.legs` block, tried in config
  order with the same dead-route classification, the same 60 s / 900 s cooldowns and the same
  one-line log and `/metrics` counters as the chat door. A provider that refuses the model
  (`unsupported_model`, "not supported on this endpoint") is a bad leg, so the walk moves on; a
  plain `400` is the caller's and reaches the caller unchanged. A config with no `systemone` block
  answers `404` on the route, so nothing changes for an existing config. `/admin/config` reports the
  block beside the chat legs, and `/admin/state` reports each System One leg's state and cooldown.
- `SIGHUP` reloads the config without a restart: legs, keys, models, aliases, efforts, `prices`,
  `balance` and the log rotation policy are applied in place after the new file parses and
  validates. A file that does not is refused whole, `/admin/config` records the error under
  `reload`, and the process keeps serving what it had. Cooldowns, latency history and live OAuth
  tokens follow a leg by name, so a reload is not a restart and a stream in flight is not cut
  (`DEC-15`).
- `prices` turns tokens into money: USD per million tokens per model id, with `"*"` as the
  catch-all. The request line gains `cost_usd` as a twelfth, conditional key when the answering
  leg's model is priced and the provider reported tokens; `/admin/state` sums it into
  `window.cost_usd` and `/metrics` prints `kori_cost_usd_total` (`DEC-16`).
- Log retention: `log.rotate_bytes` rotates the live file at that size, `log.keep` (default 2)
  says how many rotated files stay. Rotation is checked before the write, so a line is never
  split, and it is off unless configured (`DEC-17`).
- `GET /metrics`: Prometheus text exposition with per-route request counts, status classes,
  failover reasons, cooldowns started, a live cooling gauge, a latency histogram in milliseconds,
  the window's cost, the reload count and a `kori_info` build marker. No library and no second
  source of truth: the counters increment where the log line is written (`DEC-18`).

### Documentation

- The docs stop describing shipped work as absent. `docs/ARCHITECTURE.md` no longer lists
  credential refresh as unbuilt, its module table names every section the binary has, and its "Not
  built" list is the real one (non-chat endpoints, cost caps, cache, caller identity, HA, log
  compression). `README.md` moves to 0.6.2, mentions retry, the key pool and `/v1/models`, and its
  deploy paragraph no longer claims nothing runs on a host.

## [0.6.2] - 2026-11-18

### Added

- `GET /v1/models`: the model list derived from this config, for the clients that probe one
  before they will talk to a gateway. One entry per `kori/<alias>` (deduplicated across legs,
  because one caller name is one model) plus one per leg `model` id the config names. No
  provider is dialled and no credential is read, so it answers on a fresh process with every
  leg dead.
- `legs[].retries`: extra dials on the same leg before the walk moves on. Doubling pause from
  200 ms to a 2 s ceiling plus jitter; only `conn_refused`, `dial_timeout`, `header_timeout`
  and `upstream_5xx` are retried. Default `0`, so no existing config changes behaviour. A
  retry is not a failover, so the log line is unchanged.
- `legs[].api_keys`: an ordered key pool. A `401` or a quota `429` cools the key in use and
  the next live entry is tried on the same leg before the leg is blamed. `api_key` stays
  supported and is the pool of one. `/admin/config` reports `keys` and `keys_cooling`; no key
  value and no key index reaches any surface.
- `legs[].weight` above 1, with smooth weighted round-robin over the available primaries when
  `balance` is on. Equal weights are plain round-robin. `DEC-11` supersedes `DEC-8`, which
  refused every weight but 1.
- `/healthz?deep`: the same liveness plus per-leg state, cooldown, last success, last failure
  and window counters, read from router state with zero dials.
- Two named failure classes: `model_gone` for a `404` saying the model does not exist on a
  leg the alias table named (a caller's own id keeps its `404`), and `caller_fault` for a
  caller that hung up after the first byte, which no longer reads as `mid_stream_abort` and
  cools nothing.

### Fixed

- An effort skip followed by a credential `502` no longer reports zero availability movement.
  The suppression belongs to the `400` that names the caller's effort, so it is keyed on the
  answer the caller got instead of on the skip: Galih's LOW from the 0.6.1 gate.

## [0.6.1] - 2026-11-18

### Fixed

- A request the caller's own effort ended could be reported as a server failure. The `400`
  naming the unsupported value only fired when every leg in the walk was skipped for effort,
  so an alias mapped on some legs only, or a walk where another leg skipped as an unmapped
  alias, fell through to `502 all_legs_failed` carrying `alias_unmapped` while the log line
  said `effort_unsupported`. The stop is now decided from the dial count: no leg dialled and
  at least one leg skipped for its ceiling. A leg that was really dialled and failed keeps
  the `502`.
- That `400` no longer moves `window.failover_availability`. It dialled nothing, so it is not
  an availability failure; a skip the walk then served past still counts exactly as before.

### Changed

- README's thinking-effort section documents `"efforts": []` as a ceiling with nothing under
  it, which is not the same as the absent key, states that the ceiling is a cost and
  behaviour control rather than a security control, and records sinarcloud's measured
  provider ceiling: `none`, `low`, `medium`, `high`, `max` and the unranked `turbo` all
  answered `200` from the host, so `["low", "high"]` there is our own cost choice.

### Maintenance

- The `systemctl show` stub in `tests/dryrun-deploy.sh` answers an empty render when
  `FAKE_SYSTEMCTL_RENDER` is unset instead of defaulting to `loaded`, so an unset variable
  reads as a failed gate; each scenario sets `loaded` in its own baseline.
- `.gitignore`'s `config.nims` pattern is anchored to the repo root, so the tracked
  `apps/api/src/config.nims` is no longer covered by it.
- `apps/web/pnpm-workspace.yaml` parks GHSA-fc5q-39xc-vjpf (picomatch, high, no patched
  release, reachable only through vite's dev dependency chain) so `pnpm audit
  --audit-level=high` stops exiting `1` and the dist drift check in the Web job runs again.
  Parking a HIGH advisory is a security decision, so this one needs Galih's clearance before
  it reaches `main`.

## [0.6.0] - 2026-11-17

### Added

- Per-leg thinking-effort ceiling: `legs[].efforts` lists the `reasoning_effort` values a
  leg accepts, ranked `minimal < none < low < medium < high < xhigh < max`. A caller asking
  above the ceiling is clamped DOWN to the highest value the leg still accepts, never up;
  a leg whose list has nothing at or below the request is skipped without a cooldown, the
  same way an unmapped alias is, and when every leg skips the caller gets one `400` whose
  body type is `effort_unsupported` and which names the value. A leg with no `efforts` key
  has no ceiling, and a caller who named no effort is untouched.
- A conditional eleventh key in the request log, `effort_clamped`, holding `<asked>><sent>`
  for example `max>high`, written only when the answering leg pulled the value down. A
  request that never clamped keeps the nine keys it had. DEC-6 is amended accordingly.
- `glm-5.3-flash` as an alias on two legs: `opencode-go` maps it to `glm-5.3-flash` and
  `commandcode` to `z-ai/glm-5.3-flash`, so one caller name reaches each provider's own id.
  sinarcloud carries no glm alias on purpose, because it does not serve that model.

### Changed

- `ops/etc/config.json.example` now carries the effort ceilings for its three legs
  (`opencode-go` and `commandcode` `low, high, max`; `sinarcloud` `low, high`) and the two
  glm aliases. sinarcloud's ceiling is unmeasured and `medium` is left out of every leg
  until a probe says otherwise.

## [0.5.2] - 2026-11-17

### Fixed

- The `KORI_REVISION` build-arg guard tested only that the value was non-empty, so an argument
  of spaces passed it. `config.nims` then found nothing usable in the value, the build fell
  through to git, `.git` is not in the build context, and the image reported `dev` again with
  no error. That was the symptom 0.5.1 was meant to close. The guard now requires a git sha shape
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
