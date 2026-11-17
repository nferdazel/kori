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
                                       │  pick order (config order, or round-robin)
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
| config | JSON loading, leg defaults, the one refusal (`weight` other than 1) |
| log writer | the ten-key line, the single append, the descriptor held for the process |
| time | RFC 3339 stamps used by the log and the admin GETs |
| router | leg availability, pick order, cooldown, served/attempted counters, the latency ring |
| upstream IO | raw socket dial, TLS wrap, the deadline-bounded send and receive |
| classification | status plus body to a failure token, and the quota-body test |
| request body | `stream` detection, `stream_options.include_usage` injection |
| caller response | streaming and non-streaming write-back, abort on mid-stream death |
| attempts | one leg, one attempt, and the outcome the walk consumes |
| proxy | the failover walk and the one log line per request |
| log tail | bounded backwards scan for `/admin/log` and `recent[]` |
| state | `/admin/state` and `/admin/config` JSON, with credentials redacted |
| handlers | dispatch, the static surface, `/healthz`, `/admin/*`, `/v1/*` |
| main | startup order: CLI, config, log, listener |

`apps/api/src/config.nims` adds `-d:ssl` and the revision define. The revision is read from
git at build time and falls back to `dev`, so `/healthz` never reports a revision the
binary does not have.

`apps/api/src/generated/static_files.nim` is generated, never edited. It is a table of
path, content type and body for the eight files under `apps/web/dist`.

## Request lifecycle

1. `dispatch` routes by path. `/healthz`, `/admin/*` and `/v1/chat/completions` keep
   priority; the static surface is last in the chain, so adding a dashboard page can never
   shadow an API path.
2. `handleChat` reads the body once, decides `stream` from it, and injects
   `stream_options.include_usage` for streaming requests that omit it.
3. `pickOrder` returns the legs to try, skipping any leg whose cooldown has not expired.
   With `balance` false the order is the config order; with `balance` true the starting
   primary rotates round-robin and the walk then covers the other primaries and the
   fallbacks.
4. `attemptLeg` dials one leg, writes the upstream request, and reads the response. The
   failover window ends when response headers arrive: below that line an attempt either
   serves the caller or aborts.
5. A failed attempt is classified, put on cooldown, and recorded as a failover event if
   another leg remains. The walk continues.
6. Whatever happened, one log line is written before the handler returns. `failover_reason`
   is the first reason met, except for a mid-stream abort, which overrides it because it is
   what the caller actually saw.

Cooldowns are 60 s for availability failures and 900 s for a quota `429`. A leg whose
cooldown has expired is eligible again, and the first request that picks it acts as the
half-open probe: a second failure starts a fresh full cooldown.

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

Router state lives in memory: per-leg cooling deadline, counters, last failure class and a
latency ring. Nothing is rebuilt from the log on restart, and there is no database by
design. The log is the durable record of what happened; `/admin/log` and `recent[]` read it
backwards with a bounded scan budget, never whole.

`/admin/config` reports the config path and a `<path>:<line>` reference per leg credential,
never the value.

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

`ops/` mirrors the intended host shape one to one: `deploy-vps.sh`, `rollback.sh`,
`smoke.sh`, `preflight.sh`, `contract-check.sh`, a Caddy site template, an env template, a
Quadlet unit and a webhook definition. They are templates. No deploy has been run against a
host, and the host-side pieces (hook install, clone, env file, config file, Caddy import
line) are owned by the deploy owner, not by this repository.

## Not built

- Credential refresh (SPEC §4). The OpenCode credential is an OAuth access token with an
  expiry; the binary reads it from the config and does not refresh it. A request served with
  an expired token fails as `auth_401` and falls over, which is not the loud stop the spec
  asks for.
- Any deploy. See the changelog.
