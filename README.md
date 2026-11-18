# kori

kori is an in-house LLM provider gateway: one Nim binary that exposes a single
`/v1/chat/completions` door and routes each request across an ordered list of provider
legs, failing over when a leg is dead. It exists to replace a LiteLLM deployment that
carried a Python service and a Postgres database for a workload of one person. kori has
no Python, no database and no migrations. Its only durable output is an append-only
request log.

What it does:

- **One door, ordered legs.** A primary leg plus ordered fallbacks. The caller sees one
  endpoint and never learns which leg answered.
- **Dead-route classification.** A leg that answers `401`, `400 MissingSessionID`,
  connection refused, a dial or TLS timeout, a quota `429` or a `5xx` is marked dead and
  the next leg is tried. A client error that belongs to the caller (`400`, `403`, `404`,
  a plain `429`) is returned unchanged and nothing fails over.
- **Cooldown.** A dead leg is skipped without a dial until its cooldown expires.
- **One log line per request.** Append-only JSONL carrying route, status, latency, token
  counts, the failover reason and, when the caller asked for a `kori/<alias>`, that alias.
- **A read-only dashboard** compiled into the binary, served from memory.

## Requirements

| Tool | Version | Needed for |
|---|---|---|
| Nim | 2.4.2 | the binary, the unit tests, the acceptance harness |
| Node.js and pnpm | 26 / pnpm 12 | rebuilding the dashboard under `apps/web` only |
| shellcheck | any recent | `./task ops` |
| jq, curl, python3 | stock | the acceptance harness under `acceptance/` |

Nim 2.4.2 is the version CI pins. The binary needs OpenSSL headers at build time, because
every leg is `https`.

## Build

```sh
nim c -d:release --mm:orc --threads:on --hints:off -o:apps/api/src/kori apps/api/src/kori.nim
```

`apps/api/src/config.nims` is picked up automatically and adds `-d:ssl` plus the revision
string `/healthz` reports, so no extra flags are needed.

`./task nim` runs the same build after `nim check`, `nimble test` and the static-embed
drift check, then runs the acceptance self-test against the binary.

## Run

```sh
./apps/api/src/kori --config ~/.config/kori/kori.json --port 4021 --log /tmp/kori.jsonl
```

`--config` is required. There is no default path and no search path. A missing file,
unreadable file or invalid JSON exits `2` before the listener opens.

| Flag | Meaning | Default |
|---|---|---|
| `--config` | path to the JSON config | required |
| `--address` | IPv4 literal to bind | `listen.host`, then `127.0.0.1` |
| `--port` | port, 1–65535 | `listen.port`, then `8787` |
| `--log` | request log path | `log.path`; exit `2` if neither is set |
| `--help` | usage on stdout | — |

Both `--flag value` and `--flag=value` are accepted. Precedence is CLI over config over
built-in default. An unknown flag, a non-numeric port or a non-literal address exits `2`
with one usage line on stderr. Exit codes: `0` clean, `2` bad config or CLI, `1` anything
else.

## Configuration

The config is a JSON object. It holds every provider credential, so it never belongs in
the repository, in an image or in a log.

```json
{
  "listen": { "host": "127.0.0.1", "port": 8787 },
  "log":    { "path": "/var/log/kori/requests.jsonl" },
  "balance": false,
  "legs": [
    {
      "name": "opencode-go",
      "base_url": "https://opencode.ai/inference/go/openai/v1",
      "model": "deepseek-v4.1-flash",
      "headers": { "x-opencode-session": "…" },
      "role": "primary",
      "oauth": {
        "token_url": "https://opencode.ai/console/auth/oauth/token",
        "client_id": "https://opencode.ai/oauth/opencode/client.json",
        "refresh_token": "…"
      }
    },
    {
      "name": "commandcode",
      "base_url": "https://api.commandcode.ai/provider/v1",
      "api_key": "…",
      "role": "fallback"
    },
    {
      "name": "sinarcloud",
      "base_url": "https://ai.sinarcloud.com/v1",
      "api_key": "…",
      "role": "fallback"
    }
  ]
}
```

| Key | Required | Notes |
|---|---|---|
| `legs` | yes | at least one; order in the array is the failover order |
| `legs[].name` | yes | the name that appears in the log and on the dashboard |
| `legs[].base_url` | yes | kori appends `/chat/completions` to its path |
| `legs[].api_key` | no | sent as `Authorization: Bearer …` unless `headers` already sets one, or the leg has an `oauth` block |
| `legs[].model` | no | the model id that leg is sent, replacing the caller's `model` on that leg only; falls back to the leg name, which is reported and never sent (DEC-10) |
| `legs[].headers` | no | extra request headers, for example `x-opencode-session` |
| `legs[].role` | no | `primary` or `fallback`, default `primary` |
| `legs[].weight` | no | must be `1`; any other value is refused at startup |
| `legs[].enabled` | no | `true` or `false`, default `true`; a leg set to `false` keeps its place in the failover order but is never dialled, and `/admin/state` reads it as `skipped` |
| `legs[].aliases` | no | an object of caller alias to this leg's provider id, for example `{"fast": "prov-a-fast"}`; the key is the alias alone, without `kori/`, and one name may map to a different id on each leg |
| `legs[].efforts` | no | the `reasoning_effort` values this leg accepts, for example `["low", "high", "max"]`; a value outside the rank table is refused at startup. See "Thinking effort" below |
| `legs[].oauth` | no | makes the leg refresh its own access token; see below |
| `legs[].oauth.token_url` | yes, with `oauth` | the endpoint kori POSTs to; must be `http` or `https` |
| `legs[].oauth.client_id` | yes, with `oauth` | sent with the refresh grant |
| `legs[].oauth.refresh_token` | yes, with `oauth` | the seed; a rotation in the answer replaces it |
| `legs[].oauth.client_secret` | no | sent only when the endpoint needs it |
| `legs[].oauth.access_token` | no | a seed token, used until the first refresh |
| `legs[].oauth.expires_at` | no | epoch seconds; without it kori refreshes only after a `401` |
| `legs[].oauth.refresh_skew_seconds` | no | refresh this long before expiry, default `60` |
| `balance` | no | default `false`, which keeps strict leg order |
| `listen`, `log` | no | overridden by `--address`, `--port`, `--log` |

For the `opencode-go` leg, `token_url` and `client_id` are the OpenCode Console's own
values, published in its OAuth discovery document at
`https://opencode.ai/console/.well-known/oauth-authorization-server` and in
`https://opencode.ai/oauth/opencode/client.json`; the client is public and authenticates
with `token_endpoint_auth_method` `none`, so no client secret is sent. `refresh_token` is
the only secret in the block: it comes from the OpenCode credential store on the machine
that owns the account (`opencode auth export`), never from the repository, and the refreshed
values are written back into the running config file with mode `0600`.

The `commandcode` and `sinarcloud` legs take a static `api_key` and nothing else: neither
key expires, so neither leg has an `oauth` block and kori never refreshes them.


The caller's body is forwarded byte for byte, with one exception: for a streaming request
kori sets `stream_options.include_usage` if the caller did not, so the leg reports token
counts.

## Routing and failure handling

Legs are tried in config order. A leg that fails is put on cooldown and the next leg is
tried. A request that reaches a response is never rerouted afterwards.

With `"balance": true`, the starting leg rotates round-robin across the available
`primary` legs; the walk then covers the other primaries and finally the `fallback` legs.
The default `false` keeps strict config order.

| Condition from a leg | Class | Cooldown |
|---|---|---|
| `401` | `auth_401` | 60 s |
| `400` with `MissingSessionID` | `missing_session_id` | 60 s |
| connection refused | `conn_refused` | 60 s |
| dial timeout | `dial_timeout` | 60 s |
| header timeout | `header_timeout` | 60 s |
| `5xx` | `upstream_5xx` | 60 s |
| `429` carrying a quota body | `quota_429` | 900 s |
| any other status | not a failure; returned to the caller | — |

`credential_refresh_failed` and `refresh_timeout` are the two log-only values: they name a
request that stopped where it was instead of failing over (see below).

A response that dies after its first byte is aborted and logged as `mid_stream_abort`; it
is not rerouted. When every leg is dead the caller gets one `502` carrying the last
failure reason.

A caller asks for a gateway alias by sending `model` as `kori/<alias>`. The name resolves
per leg through that leg's own `aliases` table, so one alias can reach a different provider
id on each leg, and the response reports the id the serving leg actually sent. A leg with
no entry for the name is skipped for that request and is not put on cooldown; the log
carries `alias_unmapped` for it. A name no leg maps is a `400` whose body type is
`unknown_alias`. An alias longer than 256 bytes is refused before any leg is touched, with
a `400` whose body type is `alias_too_long` and whose text is fixed, so the oversized name
is never echoed back.

## Thinking effort

A client picks a thinking effort by sending a top-level `reasoning_effort` string in the
chat-completions body; it is not a header and not a nested object. kori forwards that value
byte-for-byte unless the leg it is about to dial declares a ceiling, which is what
`legs[].efforts` is.

The values are ranked, smallest to largest: `minimal`, `none`, `low`, `medium`, `high`,
`xhigh`, `max`. A leg's `efforts` array lists what that leg accepts, and nothing else
changes:

| Caller asks | Leg accepts | Sent to the leg | Log carries |
|---|---|---|---|
| `high` | `["low", "high", "max"]` | `high` | no clamp key |
| `max` | `["low", "high"]` | `high` | `"effort_clamped":"max>high"` |
| `medium` | `["low", "high", "max"]` | `low` | `"effort_clamped":"medium>low"` |
| `low` | `["high", "max"]` | nothing, the leg is skipped | `effort_unsupported` |
| anything | no `efforts` key | the caller's value, untouched | no clamp key |
| anything ranked | `[]` | nothing, the leg is skipped | `effort_unsupported` |
| nothing | any | the field stays absent | no clamp key |

An empty array is not the same as a missing key. `"efforts": []` passes config load as a
ceiling with nothing under it, so every ranked value is skipped on that leg; only the absent
key means no ceiling at all. A leg written that way answers no ranked request, and when no
other leg in the walk serves it the caller gets the `effort_unsupported` `400` described
below, so the mistake shows up at request time and nowhere earlier.

A clamp only ever goes down. Asking for `low` against a leg that starts at `high` is skipped
rather than upgraded, because spending more than the caller asked for is a cost decision
nobody made. A skipped leg is not put on cooldown and does not count as a failure: the walk
moves to the next leg exactly as it does for an unmapped alias. When the walk ends with no
leg dialled and at least one leg skipped for this reason, the caller gets one `400` whose
body type is `effort_unsupported` and which names the value. That holds even when other
legs in the same walk were skipped for a different reason, such as an unmapped alias; a
leg that was really dialled and failed keeps the `502` instead.

A value kori does not rank is forwarded untouched rather than guessed at, and the leg's own
validation decides what happens to it.

The ceiling is a cost and behaviour control, not a security control. Because an unranked
value passes through as the caller sent it, a leg's `efforts` list is not a hard limiter on
what a client can ask for: it only clamps the seven ranked values and leaves everything else
to the leg.

The committed `ops/etc/config.json.example` carries the three legs this deployment has:
`opencode-go` and `commandcode` accept `low`, `high` and `max`; `sinarcloud` accepts `low`
and `high` only. That sinarcloud list is our own cost choice, not a provider limit: probed
from the host on 2026-11-18, `none`, `low`, `medium`, `high`, `max` and the unranked `turbo`
all answered `200`, and `max` spent fewer reasoning tokens than `high` did. The legs are
listed that way so a `medium` request is still clamped down and the log says so.
`medium` is left out of every leg on purpose until a probe says a leg accepts it, so a
caller asking `medium` is clamped down and the log says so. `glm-5.3-flash` is an alias on
two legs only: `opencode-go` maps it to `glm-5.3-flash` and `commandcode` to
`z-ai/glm-5.3-flash`. sinarcloud has no glm alias, because it does not serve that model;
without the alias the leg is skipped instead of being dialled into a `400`.

Deadlines enforced by the binary, independent of any proxy in front of it:

| Phase | Limit |
|---|---|
| connect | 2 s |
| TLS handshake | 3 s |
| response headers, streaming | 15 s |
| response headers, non-streaming | 90 s |
| idle between chunks | 120 s |
| whole non-streaming request | 300 s |

## Credential refresh

A leg with an `oauth` block holds an access token that expires. kori refreshes it itself;
a leg without the block keeps its static `api_key` and never calls a token endpoint.

Before dialling, when the clock has reached `expires_at` minus `refresh_skew_seconds`,
kori POSTs a form-encoded `grant_type=refresh_token` with `refresh_token`, `client_id` and
`client_secret` when one is set. It reads `access_token`, a rotated `refresh_token` and
`expires_in` from the JSON answer. A `401` from the leg itself buys one forced refresh and
one retry, then the leg is classified exactly as any other `401`.

A refresh that fails stops the request. The caller gets `502` with
`{"error":{"type":"credential_refresh_failed"}}`, or `refresh_timeout` when the deadline
fired; no fallback leg is dialled, no stale bearer is sent, and one line goes to stderr.
The token call has its own 5 s budget after connect and TLS, so a hung token endpoint
cannot pass for a slow provider.

Only one token call per leg is in flight at a time: requests that need the same refresh
wait on it instead of repeating it. The new credential is written back into the same config
file atomically, at mode `0600`, leaving every other byte alone. When the file cannot be
written, as inside the container where the config is mounted read-only, kori warns and
serves the refreshed credential from memory.

`/admin/config` reports the refresh state, never the credential:

```json
"oauth": { "state": "set", "expires_at": 1794812128 }
```

## Request log

One line per request, appended with a single write, never rewritten and never rotated.
Nine keys, in this order, plus two conditional ones at the end:

```json
{"ts":"2026-11-16T13:20:04+07:00","route":"commandcode","status":200,"latency_ms":812,"tokens_in":128,"tokens_out":64,"failover_from":"opencode-go","failover_reason":"auth_401","stream":false,"alias":"kori/fast"}
```

| Key | Meaning |
|---|---|
| `ts` | RFC 3339 timestamp with offset |
| `route` | the leg that answered, or the last leg tried when none did |
| `status` | status returned to the caller |
| `latency_ms` | wall clock for the whole request |
| `tokens_in`, `tokens_out` | read from the provider's response, `null` when absent |
| `failover_from` | the first leg that failed, empty when none did |
| `failover_reason` | the first failure reason, empty when none did |
| `stream` | whether the caller asked for a stream |
| `alias` | the caller's `kori/<alias>` exactly as sent; present only on a request that named one, and clipped at a rune boundary to at most 261 bytes (`MaxAliasBytes` plus the `kori/` prefix) |
| `effort_clamped` | `<asked>><sent>` when the answering leg's ceiling pulled the effort down, for example `max>high`; absent when no clamp happened, so a request that never clamped still carries the nine keys above |

No header, body or credential is ever written to the log.

## HTTP surface

| Path | Method | Purpose |
|---|---|---|
| `/v1/chat/completions` | POST | the gateway door |
| `/healthz` | GET, HEAD | `{"status":"ok","version":…,"revision":…}`; revision is the git sha the binary was built from, or `dev` |
| `/admin/state` | GET, HEAD | routes, window counters, failover events, recent log rows |
| `/admin/log` | GET, HEAD | a page of the request log, newest first |
| `/admin/config` | GET, HEAD | the loaded config with every credential redacted |
| `/`, `/requests.html`, `/routes.html`, `/config.html`, `/assets/*`, `/fonts/*` | GET, HEAD | the dashboard, served from the compiled static table |
| anything else | any | `404` |

Any method other than GET or HEAD under `/admin/` is a `405` that names `GET`. Nothing is
read from disk at runtime: the dashboard files are compiled into the binary.

`/admin/log` takes `limit` (1–200, default 50), `offset`, `route`, `status_class`
(`2xx`, `4xx`, `5xx`), `reason` (the token, or `none` for requests that did not fail
over), `stream` (`true`, `false`), `since` (RFC 3339) and `alias` (the exact
`kori/<alias>` a caller named). A malformed value is a `400` that names the
parameter, and no file read happens.

Router state is memory only. After a restart every leg reads `unknown` with no cooldown
and zero counters; the log is the durable record, not a source of router state.

## Dashboard

Four read-only pages, wired to the three admin GETs:

| Page | Shows |
|---|---|
| `/` Overview | route health, the window counters, recent requests |
| `/requests.html` | the request log with filters |
| `/routes.html` | per-route state, cooldowns and latency |
| `/config.html` | the loaded config with credentials redacted |

The pages are built in `apps/web` and committed as `apps/web/dist`. `tools/gen-static.sh`
turns that directory into `apps/api/src/generated/static_files.nim`, which is also
committed. Both are checked for drift in CI, so a stale embed fails the build instead of
shipping an old page.

To rebuild the dashboard:

```sh
cd apps/web && pnpm install --frozen-lockfile && pnpm run build
```

Then regenerate the embedded module from the repo root:

```sh
sh tools/gen-static.sh apps/web/dist apps/api/src/generated/static_files.nim
```

## Checks

`./task` is the single entry point; every target exits nonzero with a reason when its
input is missing.

```sh
./task help    # the target list
./task ops     # shellcheck + deploy/smoke/preflight dry runs, no podman, no network
./task web     # vite build in apps/web, then fail if the committed dist is stale
./task nim     # nim check, nimble test, embed drift, release build, acceptance self-test
./task check   # all of the above, in CI order
```

The acceptance harness proves the router end to end against a real binary:

```sh
KORI_BIN=./apps/api/src/kori sh acceptance/run-all.sh   # the eleven cases, A1–A11
KORI_BIN=./apps/api/src/kori sh acceptance/selftest.sh  # proves the harness itself
```

| Case | What it proves |
|---|---|
| a1 | an availability failure falls over and the log names the dead leg |
| a2 | a dead socket costs one dial, not two |
| a3 | the three deadlines fire at their own numbers |
| a4 | a quota `429` is a different failure with a 900 s cooldown |
| a5 | a client error reaches the caller unchanged and nothing fails over |
| a6 | a stream that dies after the first byte is aborted, never rerouted |
| a7 | tool calls survive the proxy byte for byte |
| a8 | a fresh start knows nothing about any leg |
| a9 | all legs dead is one `502` and the log keeps both ends of the chain |
| a10 | the dashboard is a read-only surface over three GETs |
| a11 | an expired credential is refreshed, and a refresh forced to fail stops the request |

Cases use logical port numbers; `acceptance/lib.sh` resolves each to a free port per run,
so a run leaves nothing behind and can be repeated immediately.

## CI

`.github/workflows/ci.yml` runs seven jobs: `Contract`, `Security`, `Ops`, `Nim`, `Gate`,
`Image: api`, `Web`. Every job has `timeout-minutes: 15`, caches its toolchain, and passes
event data through `env:` rather than interpolating it into a shell script. `Gate` is the
single required status and the only door to publishing the image.

## Repository layout

```
apps/api/       Nim gateway source, Dockerfile
apps/api/src/generated/static_files.nim   dashboard compiled into the binary
apps/web/       dashboard source (vite, TypeScript) and the committed dist
acceptance/     A1–A11 harness, lib.sh, stub.py, self-test
ops/            deploy, rollback and smoke scripts, Caddy, env, systemd, webhook templates
tests/          unit tests and the dry runs ./task ops calls
tools/          gen-static.sh
task            the one entry point for the checks
docs/           architecture and decisions
```

`ops/` holds templates for a rootless podman deploy behind a Caddy edge. kori is not
deployed anywhere yet: the templates describe the intended shape, and no deploy script has
been run against a host.

## License

MIT. See [LICENSE](LICENSE).
