# Architecture

The behaviour kori must satisfy is the spec in
`workloop/items/server-room/2026-11-14-gateway-failover/SPEC-gateway-nim.md`, and the
measurement it reproduces is in `DECISION-GATEWAY.md` and `PHASE1-PROOF.md` beside it.
This document covers what the README does not: why the shape is what it is, and how the
pieces are laid out.

## Shape

One binary, one config file, one append-only log. No Python, no Postgres, no migration, no
second service. The workload is one person's provider traffic, so the operating cost of a
second runtime is the thing worth removing; the routing itself is small.

The three things that are not small, and are therefore the reason this is written rather
than configured: server-sent events, tool-call passthrough, and token accounting. LiteLLM
was replaced on shape, not on features.

```
caller ──POST /v1/chat/completions──► kori
                                       │  pick order (config order, or weighted round-robin)
                                       ├──► leg A (primary)      ── ok ──► caller
                                       │        │ fail
                                       │        └─ classify, cooldown
                                       ├──► leg B (fallback)     ── ok ──► caller
                                       │        │ fail
                                       └──► leg C (fallback)     ── ok ──► caller
                                                │ all failed
                                                └──► 502 to caller
                                       │
                                       └─ one JSON line to the request log, always
```

## Source layout

`apps/api/src/kori.nim` is one module in sections, in the order a request moves through it.

| Section | Holds |
|---|---|
| CLI flags | flag parsing, precedence over config, exit `2` on bad input |
| config | JSON loading, leg defaults, the four header-deadline numbers, prices, the log rotation policy, and every refusal: a pool that cannot also be the bearer, an unranked effort, a `weight` outside 1-1000, a `retries` outside 0-5, a negative price |
| log writer | the sixteen-key line (nine keys always; `alias`, `effort_clamped` and `cost_usd`, then `prompt_kib`, `header_ms`, `legs_cooling` and `retry_after_s`, only when the request earned them), the single append, size rotation with `keep`, the descriptor held for the process |
| time | RFC 3339 stamps used by the log and the admin GETs |
| router | leg availability, pick order, smooth weighted round-robin (`DEC-11`), leg and key cooldowns, served/attempted counters, the latency ring |
| upstream IO | raw socket dial, TLS wrap, the deadline-bounded send and receive |
| classification | status plus body to a failure token, `model_gone` and `caller_fault` included, and the quota-body test |
| request body | `stream` detection, `stream_options.include_usage` injection, the per-leg effort ceiling |
| caller response | streaming and non-streaming write-back, abort on mid-stream death |
| attempts | one leg, one attempt, the retry budget (`DEC-12`), the key pool (`DEC-13`), and the outcome the walk consumes |
| credential refresh | the token call, the single in-flight refresh per leg, the atomic write-back of a rotated credential |
| proxy | the failover walk and the one log line per request |
| systemone | the second door (`DEC-19`): its own ordered legs, the model-id rewrite, and a passthrough of every other byte |
| log tail | bounded backwards scan for `/admin/log` and `recent[]` |
| state | `/admin/state`, `/admin/config` and `/healthz?deep` JSON, with credentials redacted |
| handlers | dispatch, the static surface, `/healthz`, `/admin/*`, `/v1/models`, `/v1/chat/completions`, `/v1/systemone` |
| main | startup order: CLI, config, log, listener |

`apps/api/src/config.nims` adds `-d:ssl` and the revision define. The revision is read from
git at build time and falls back to `dev`, so `/healthz` never reports a revision the
binary does not have.

`apps/api/src/generated/static_files.nim` is generated, never edited. It is a table of
path, content type and body for the eight files under `apps/web/dist`.

## Request lifecycle

1. `dispatch` routes by path. `/healthz`, `/metrics`, `/admin/*`, `/v1/models`,
   `/v1/chat/completions` and `/v1/systemone` keep priority; the static surface is last in the
   chain, so adding a dashboard page can never shadow an API path.
2. `handleChat` reads the body once, decides `stream` from it, and injects
   `stream_options.include_usage` for streaming requests that omit it.
3. `pickOrder` returns the legs to try, skipping any leg whose cooldown has not expired, a leg
   the config disabled, and a leg that cannot serve the request's effort. With `balance` false
   the order is the config order; with `balance` true the first leg is chosen by smooth weighted
   round-robin across the available primaries (`DEC-11`), and the walk then covers the other
   primaries and finally the fallbacks.
4. `attemptLeg` dials one leg, writes the upstream request, and reads the response. A pooled
   credential is chosen here: an entry on its own cooldown is skipped, and a `401` or a quota
   `429` cools only the key that failed before the leg is blamed (`DEC-13`). A `402` does the same
   and takes the capacity cooldown, because a spent balance is a dead route and not a caller error. The transport classes get up to `legs[].retries` more dials on the same leg behind a
   doubling pause (`DEC-12`), which is why a retry leaves `failover_from` empty: the request never
   left the leg. The failover window ends when response headers arrive: below that line an attempt
   either serves the caller or aborts. On a streamed request that window is not a constant — it is
   15 s plus 100 ms per KiB of outbound body, capped at 60 s (`DEC-22`), so a long prompt is not
   failed over for being long.
5. A failed attempt is classified, put on cooldown, and recorded as a failover event if
   another leg remains. The walk continues. A failed credential refresh is the exception: the
   caller gets `502 credential_refresh_failed` (or `refresh_timeout`) and nothing else is
   dialled, because the request never reached a provider and a stale bearer is worse than a
   stop.
6. Whatever happened, one log line is written before the handler returns. `failover_reason`
   is the first reason met, except for a mid-stream abort, which overrides it because it is
   what the caller actually saw. The same completion feeds the `/metrics` counters, so a scrape
   and the log cannot disagree about how many requests a route answered. `prompt_kib` is the
   prompt body size in KiB (bytes, not tokens: JSON overhead is in it) and `header_ms` is the
   wait from body sent to the first response byte, recorded only on the leg that answered, so a
   failure leaves it out instead of reporting a wait it never finished. `legs_cooling` and
   `retry_after_s` are written only by the row that never dialled: when no leg can serve, the
   answer is `503 all_legs_cooling` (or `503 no_leg_enabled`) with a `Retry-After` header equal
   to the body's `retry_after_s`, the log row carries `route: ""`, and no leg name reaches the
   caller. A request that dialled and failed keeps its `502`.

Cooldowns are 60 s for availability failures and 900 s for a quota `429`, with three exceptions
(`DEC-26`). `header_timeout` starts at the header window that attempt waited, clamped to 5–60 s, and
doubles per consecutive timeout inside that clamp (`DEC-23`); the streaming door therefore starts at
15 s and the 90 s non-stream and System One doors start at the 60 s cap, because a rung shorter than
the window it followed would schedule a probe dearer than the cooldown it ends. A gateway with one
enabled leg caps that rung at 15 s: with no second leg to protect, the rung only decides how long the
caller is told to wait. A quota `429` that names its own `Retry-After` is believed, clamped to
60–900 s, and a `429` that is not a quota is `rate_limited_429` on a 5–120 s clock (30 s when the
provider names nothing): it is a rate limit that may clear in seconds, so it never inherits the
capacity rung, the walk fails over past it, and the last leg's own `429` and `Retry-After` are passed
to the caller instead of a fabricated `502`. A leg whose cooldown has expired is
eligible again, and the first request that picks
it acts as the half-open probe: a second failure starts a fresh full cooldown. A pool entry cools
on the same clock, and the leg itself is only cooled once every entry in the pool is cooling. A leg
skipped for its effort ceiling or for an unmapped alias was never dialled, so it is not a failure
and takes no cooldown.

## The System One door

`POST /v1/systemone` is a second door (`DEC-19`), and it shares the log, the counters and the
classification rules but not the walk. Its upstreams come from a `systemone.legs` block, they
are tried in config order, and the walk stops at the first answer. `systemone_balance: true`
(`DEC-28`, default false) makes the first pick a smooth weighted round-robin over the eligible
legs, by `systemone.legs[].weight`; the tail of the walk stays config order, so failover is still
deterministic. The chat door's `balance` does not reach this list. The caller's body is
forwarded byte for byte with one field replaced, the top-level `model`, because the name a
caller uses for a decision model is not the id a provider accepts. The answer is written back
untouched, which is why this door has no streaming path and no `stream_options` injection: a
decision is one JSON body.

A provider that answers `unsupported_model`, or "is not supported on this endpoint", is a bad
leg and the walk moves on (`model_gone`); a plain `400` from the same provider is the caller's
own body and reaches the caller unchanged. Nothing here fails over after the first byte, for
the same reason the chat door does not: the caller already has the answer.

## Static surface

`tools/gen-static.sh` turns `apps/web/dist` into a Nim module using `staticRead` with paths
relative to the generated file. It sorts files, writes no timestamps and no absolute paths,
so two runs over the same dist are byte-identical on any machine. That determinism is what
lets CI treat a stale embed as a git diff rather than a guess.

At runtime the handler does an exact table lookup. `/` maps to `index.html`; `/assets/*` and
`/fonts/*` are served with long-lived immutable caching, the four pages with `no-store` so a
deploy cannot leave a stale page in a browser. An unknown path is a `404`, not an index
fallback.

The dashboard is committed because the container never runs Node: `nim c` alone must
produce a binary that serves the pages. `apps/web/dist` and the generated module are both
committed, and CI fails if either is out of step with the other.

## State

Router state lives in memory: per-leg cooling deadline, per-key cooling deadline, counters, last
failure class, last success, and a latency ring. Nothing is rebuilt from the log on restart, and
there is no database by design. The log is the durable record of what happened; `/admin/log` and
`recent[]` read it backwards with a bounded scan budget, never whole. `/healthz?deep` is the same
state projected per leg, and it dials nothing, so asking what is broken cannot cost a provider
call or a token.

`/admin/config` reports the config path and a `<path>:<line>` reference per leg credential, never
the value. A `base_url` printed there loses its `user:pass@` authority, so a credential carried in
the URL cannot come out through the dashboard. The key pool is reported as a size and a cooling
count, and an `oauth` leg as a state
plus its expiry, so the same page can answer "which credential is dead" without carrying one. It
also reports the log rotation policy, the price table and the last reload (`count`, `at`,
`error`), which is the artifact a `SIGHUP` leaves behind.

A `SIGHUP` re-reads the config away from the request path and swaps it in only after it parses,
validates and keeps the same listener. Router state is carried across by leg name, so a reload is
not a restart: cooldowns and live OAuth tokens survive, and a stream in flight is not cut.

`PUT /admin/overrides` is the one write (`DEC-27`). It accepts two switch maps and nothing else,
patches the top-level `overrides` key in `config.json` by text so no credential byte is
re-serialised, validates the patched document with the boot loader, writes `config.json.bak` (0600,
one generation) and then replaces the file by temp-and-rename. The effective `enabled` of every leg
changes in memory at once — only a boolean moves, no leg index — and a reload is requested so the
file and the process converge at the next quiet moment. The endpoint has its own token file
(`KORI_ADMIN_WRITE_TOKEN_FILE`): a missing file answers `404`, the read token answers `403`, a
write session lives 12 h and must carry `X-Kori-Write: 1`, switching the last serving provider off
is `409` without `confirm_last_leg`, and a size or mtime change between read and write is
`409 config_changed`. The write credential is also accepted as a bearer on every gated GET
(`/admin/state`, `/admin/config`, `/admin/log`), because it could already mint a write session and
a write session reads every page; the read token stays read-only and can never write. `/admin/config` reports `enabled` (the file), `serving` (the effective value)
and `override` (null when the dashboard has never touched that name), so the three states stay
distinguishable without reading the file.

## Acceptance harness

`acceptance/` proves the router end to end against a real binary. Each case is its own
process with its own temp directory and its own `stub.py` provider, so a failing case cannot
leave a listener behind for the next one. Cases name logical ports; `lib.sh` resolves each
to a free port per run, because a fixed port made `a3` flake when a stopped gateway had not
released it yet.

`acceptance/selftest.sh` proves the harness itself: every assertion is checked once against
input it must accept and once against input it must reject. It needs no binary and no
network, which is why it can run in the `Nim` job before the release build.

## Ops templates

`ops/` mirrors the host shape one to one: `deploy-vps.sh`, `rollback.sh`, `smoke.sh`,
`preflight.sh`, `contract-check.sh`, a Caddy site template, an env template, a Quadlet unit, the
`kori-readyz` readiness probe and a webhook definition. They are the contract the deploy runs to,
not a taping of one host: the host-side pieces (hook install, clone, env file, config file, Caddy
import line) live on the host and are owned by the deploy owner, not by this repository. qouver1 has
run kori behind the Caddy edge since 2026-11-18; which revision is on it right now is recorded there
in `.deployed_rev`, and a document that repeated it here would be wrong after the next deploy.

Two different checks watch the process, and they answer different questions. The deploy gate asks
`/healthz` once, at the end of a deploy, and rolls back to `:prev` if it does not answer. The
readiness probe asks the same route every five minutes from a separate systemd user unit and pages
through `OnFailure=alert@`; it covers the window the deploy gate cannot see, a process that is still
running and stopped answering. The probe reads `/healthz` rather than `/healthz?deep`, which is
gated: a credential missing from the host must not be able to page as an outage.

## Not built

- Anything but chat, plus the one decision door. No `/v1/messages`, no Responses API, no
  embeddings, images, audio or batch. Every chat leg is spoken to in the OpenAI protocol, so a
  native passthrough for Bedrock, Vertex or Azure would be a second protocol path rather than a
  config change, and a client that speaks only Anthropic's or OpenAI's Responses protocol cannot
  use this door today. `POST /v1/systemone` (`DEC-19`) is the exception, and it is a passthrough
  and not a translation: it forwards one wire shape and never converts between two.
- Cost, budget and cache. A request line carries `cost_usd` when the config prices the model that
  answered (`DEC-16`), so a month can be summed from the log; there is still no spend cap per key or
  per caller, and no exact or semantic cache.
- Caller identity. The only credential in front of kori is the one bearer the edge holds, so any
  per-caller limit, quota or audit trail would have to be built at the edge or not at all.
- HA. Router state is one process in memory, so there is no second replica and no cluster. `/metrics`
  is the scrape surface (`DEC-18`); nothing in the request path is shared between processes.
- Log compression. Rotation bounds the file (`DEC-17`), but a rotated file stays plain text: gzip
  inside the binary would mean a compression library in a build whose point is having none.
- Editing a leg from a browser. `SIGHUP` applies a hand-edited file (`DEC-15`); the admin surface is
  still read-only, and it stays that way on purpose.
- The credential write-back inside a container is best effort: a read-only mounted config is
  served from memory with a warning, so a rotated token survives a restart only if the mount is
  writable.
