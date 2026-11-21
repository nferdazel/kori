# kori

An in-house LLM provider gateway: one Nim binary that exposes a `/v1/chat/completions` door over an
ordered list of provider legs, failing over when a leg is dead, plus a `POST /v1/systemone` door that
passes a decision request through to its own legs. It exists to replace a LiteLLM deployment that
carried a Python service and a Postgres database for a workload of one person.

## What this is

- One door, ordered legs. A primary leg plus ordered fallbacks. The caller sees one endpoint and
  never learns which leg answered.
- A second door for decisions. `POST /v1/systemone` forwards a System One body with only the model
  id replaced, so a model that is not a chat model keeps its credential, its log line and its
  counters inside kori (`DEC-19`).
- Dead-route classification. A leg that answers `401`, `400 MissingSessionID`, connection refused, a
  dial or TLS timeout, a quota `429` or a `5xx` is marked dead and the next leg is tried. A client
  error that belongs to the caller (`400`, `403`, `404`, a plain `429`) is returned unchanged and
  nothing fails over.
- Cooldown. A dead leg is skipped without a dial until its cooldown expires.
- Retry, then fail over. `legs[].retries` absorbs a transport blip on the same leg before the walk
  moves on, and `legs[].api_keys` rotates a dead key before it blames the leg.
- A model list. `GET /v1/models` is derived from the config, so an OpenAI-shaped client can
  enumerate what this door accepts without a provider being dialled.
- One log line per request. Append-only JSONL carrying route, status, latency, token counts, the
  failover reason and, when the caller asked for a `kori/<alias>`, that alias.
- A read-only dashboard compiled into the binary, served from memory, behind one shared admin token
  (`DEC-20`).

What it is not: it is not a router with persistence or a control plane. kori has no Python, no
database and no migrations. Its only durable output is an append-only request log, and router state
is memory only.

## Status

Version `VERSION` at the root, currently 0.7.0, and tags are annotated `vX.Y.Z`.

Built and tested locally, and deployed on qouver1 behind the Caddy edge since 2026-11-18. The host
records the revision it runs in `.deployed_rev`; this file names the version it was cut at, not
what that host is running right now.

## Architecture

A request walks the configured legs in order. A leg that fails goes on cooldown and the next leg is
tried. A request that reaches a response is never rerouted afterwards.

With `"balance": true`, the starting leg is picked across the available `primary` legs by weight
(smooth weighted round-robin, `DEC-11`); the walk then covers the other primaries and finally the
`fallback` legs. The default `false` keeps strict config order, and the weight is inert then.

| Condition from a leg | Class | Cooldown |
|---|---|---|
| `401` | `auth_401` | 60 s |
| `400` with `MissingSessionID` | `missing_session_id` | 60 s |
| `404` saying the model does not exist, on a leg the alias table named | `model_gone` | 60 s |
| connection refused | `conn_refused` | 60 s |
| dial timeout | `dial_timeout` | 60 s |
| header timeout | `header_timeout` | 60 s |
| `5xx` | `upstream_5xx` | 60 s |
| `429` carrying a quota body | `quota_429` | 900 s |
| any other status | not a failure; returned to the caller | none |

`model_gone` is decided only when the alias table named the id this leg was sent. A caller that sent
a provider id itself keeps its own `404`, because a wrong id a gateway never touched is the caller's
mistake and failing over would hide it.

`credential_refresh_failed` and `refresh_timeout` are the two log-only values: they name a request
that stopped where it was instead of failing over.

A response that dies after its first byte is aborted and logged as `mid_stream_abort`; it is not
rerouted. A caller that hangs up after the first byte is logged as `caller_fault` instead: the leg
was healthy and the stream it produced was the one the caller stopped reading, so it cools nothing.
When every leg is dead the caller gets one `502` carrying the last failure reason.

A caller asks for a gateway alias by sending `model` as `kori/<alias>`. The name resolves per leg
through that leg's own `aliases` table, so one alias can reach a different provider id on each leg,
and the response reports the id the serving leg actually sent. A leg with no entry for the name is
skipped for that request and is not put on cooldown; the log carries `alias_unmapped` for it. A name
no leg maps is a `400` whose body type is `unknown_alias`. An alias longer than 256 bytes is refused
before any leg is touched, with a `400` whose body type is `alias_too_long` and whose text is fixed,
so the oversized name is never echoed back.

### Thinking effort

A client picks a thinking effort by sending a top-level `reasoning_effort` string in the
chat-completions body; it is not a header and not a nested object. kori forwards that value
byte-for-byte unless the leg it is about to dial declares a ceiling, which is what `legs[].efforts`
is.

The values are ranked, smallest to largest: `minimal`, `none`, `low`, `medium`, `high`, `xhigh`,
`max`. A leg's `efforts` array lists what that leg accepts, and nothing else changes:

| Caller asks | Leg accepts | Sent to the leg | Log carries |
|---|---|---|---|
| `high` | `["low", "high", "max"]` | `high` | no clamp key |
| `max` | `["low", "high"]` | `high` | `"effort_clamped":"max>high"` |
| `medium` | `["low", "high", "max"]` | `low` | `"effort_clamped":"medium>low"` |
| `low` | `["high", "max"]` | nothing, the leg is skipped | `effort_unsupported` |
| anything | no `efforts` key | the caller's value, untouched | no clamp key |
| anything ranked | `[]` | nothing, the leg is skipped | `effort_unsupported` |
| nothing | any | the field stays absent | no clamp key |

An empty array is not the same as a missing key. `"efforts": []` passes config load as a ceiling with
nothing under it, so every ranked value is skipped on that leg; only the absent key means no ceiling
at all. A leg written that way answers no ranked request, and when no other leg in the walk serves it
the caller gets the `effort_unsupported` `400` described below, so the mistake shows up at request
time and nowhere earlier.

A clamp only ever goes down. Asking for `low` against a leg that starts at `high` is skipped rather
than upgraded, because spending more than the caller asked for is a cost decision nobody made. A
skipped leg is not put on cooldown and does not count as a failure: the walk moves to the next leg
exactly as it does for an unmapped alias. When the walk ends with no leg dialled and at least one leg
skipped for this reason, the caller gets one `400` whose body type is `effort_unsupported` and which
names the value. That holds even when other legs in the same walk were skipped for a different reason,
such as an unmapped alias; a leg that was really dialled and failed keeps the `502` instead.

A value kori does not rank is forwarded untouched rather than guessed at, and the leg's own validation
decides what happens to it.

The ceiling is a cost and behaviour control, not a security control. Because an unranked value passes
through as the caller sent it, a leg's `efforts` list is not a hard limiter on what a client can ask
for: it only clamps the seven ranked values and leaves everything else to the leg.

The committed `ops/etc/config.json.example` carries the two legs this deployment runs:
`commandcode` as primary and `sinarcloud` as the one fallback, each with the `model` id it is sent.
`commandcode` accepts `low`, `high` and `max`; `sinarcloud` accepts `low` and `high` only. That
sinarcloud list is our own cost choice, not a provider limit: probed from the host on 2026-11-18,
`none`, `low`, `medium`, `high`, `max` and the unranked `turbo` all answered `200`, and `max` spent
fewer reasoning tokens than `high` did. The legs are listed that way so a `medium` request is still
clamped down and the log says so. `medium` is left out of every leg on purpose until a probe says a leg
accepts it, so a caller asking `medium` is clamped down and the log says so. `glm-5.3-flash` is an
alias on the `commandcode` leg only, mapped to `z-ai/glm-5.3-flash`. sinarcloud has no glm alias,
because it does not serve that model; without the alias the leg is skipped instead of being dialled
into a `400`.

Deadlines enforced by the binary, independent of any proxy in front of it:

| Phase | Limit |
|---|---|
| connect | 2 s |
| TLS handshake | 3 s |
| response headers, streaming | 15 s |
| response headers, non-streaming | 90 s |
| idle between chunks | 120 s |
| whole non-streaming request | 300 s |

### Retry before failover

Failover used to be kori's only retry, so one-second blip on a healthy provider was enough to mark
the leg dead and start its 60 s cooldown. `legs[].retries` is how many more dials that leg gets
before the walk moves on. The default is `0`, so a config that does not name the key behaves exactly
as it did.

| Caller-facing fact | Value |
|---|---|
| classes retried | `conn_refused`, `dial_timeout`, `header_timeout`, `upstream_5xx` |
| classes never retried | `auth_401` (a key rotates instead), `quota_429`, `missing_session_id`, `model_gone`, every caller `4xx` |
| pause | 200 ms doubling, capped at 2 s, plus up to a quarter as jitter |
| maximum | 5 (`MaxRetriesPerLeg`) |

A retry is not a failover: the request never left the leg, so `failover_from` and `failover_reason`
stay empty in the log and no cooldown starts. Only a dial count moves.

### Key pool

One key per leg meant one revoked key cost the whole leg. `legs[].api_keys` is an ordered pool;
`api_key` still works and is the pool of one, so no existing config changes.

A `401` or a quota `429` cools the key in use for its own cooldown (60 s, or 900 s for quota) and
tries the next live entry on the same leg before blaming the leg. When every entry is cooling the
leg cannot be dialled and the walk moves on without a cooldown of its own. A pool with more than one
entry and an `oauth` block are refused at startup, because only one of them can be the bearer.
`/admin/config` reports `keys` and `keys_cooling`; no key value and no key index reaches any
surface.

### Balancing

`balance: true` splits the pick across the available primaries instead of taking strict config order.
`legs[].weight` (1-1000) is each leg's share, using smooth weighted round-robin, and equal weights
are plain round-robin. A 3:1 config serves three requests on the heavy leg and one on the light one.
A cooling leg leaves the pool, so its share is redistributed instead of halving onto nobody. With
`balance: false` the weight is inert and the order is the config order. `DEC-11` supersedes the
older rule that refused every weight but 1.

### Credential refresh

A leg with an `oauth` block holds an access token that expires. kori refreshes it itself; a leg
without the block keeps its static `api_key` and never calls a token endpoint.

Before dialling, when the clock has reached `expires_at` minus `refresh_skew_seconds`, kori POSTs a
form-encoded `grant_type=refresh_token` with `refresh_token`, `client_id` and `client_secret` when one
is set. It reads `access_token`, a rotated `refresh_token` and `expires_in` from the JSON answer. A
`401` from the leg itself buys one forced refresh and one retry, then the leg is classified exactly as
any other `401`.

A refresh that fails stops the request. The caller gets `502` with
`{"error":{"type":"credential_refresh_failed"}}`, or `refresh_timeout` when the deadline fired; no
fallback leg is dialled, no stale bearer is sent, and one line goes to stderr. The token call has its
own 5 s budget after connect and TLS, so a hung token endpoint cannot pass for a slow provider.

Only one token call per leg is in flight at a time: requests that need the same refresh wait on it
instead of repeating it. The new credential is written back into the same config file atomically, at
mode `0600`, leaving every other byte alone. When the file cannot be written, as inside the container
where the config is mounted read-only, kori warns and serves the refreshed credential from memory.

`/admin/config` reports the refresh state, never the credential:

```json
"oauth": { "state": "set", "expires_at": 1794812128 }
```

### Request log

One line per request, appended with a single write, never rewritten. Nine keys, in this order,
plus three conditional ones at the end:

```json
{"ts":"2026-11-16T13:20:04+07:00","route":"commandcode","status":200,"latency_ms":812,"tokens_in":128,"tokens_out":64,"failover_from":"opencode-go","failover_reason":"auth_401","stream":false,"alias":"kori/fast","cost_usd":0.000154}
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
| `cost_usd` | the cost of this request from the answering leg's `prices` entry, six decimals; absent when the model is not priced or the provider reported no tokens, because "not priced" is not `$0.00` |

No header, body or credential is ever written to the log.

Rotation is off by default. Setting `log.rotate_bytes` makes kori move the live file aside at that
size and start a fresh one; `log.keep` (default `2`, maximum `20`) is how many rotated files stay
beside it. A rotation happens between two requests, is one rename, and never splits a line or drops
one. The rotated files are plain text: kori does not compress them, so no compression library and no
child process enters the binary.

### Reloading without a restart

`SIGHUP` re-reads the config file and applies it in place: legs, keys, models, aliases, efforts,
`prices`, `balance` and the log rotation policy. A restart would cut the streams in flight, and a
provider key that expired at 03:00 should not need one.

The new file is parsed and validated first. Anything that fails, fails whole: a broken file, a bad
weight, or a moved `listen` address is refused with one line on stderr, `/admin/config` records it
under `reload.error`, and the process keeps serving the config it already proved. Cooldowns, latency
history and pooled-key state follow a leg by name, so a leg that is still configured keeps its
history and a leg that was added starts fresh, exactly as a restart would have started it.

```sh
kill -HUP "$(pgrep -f 'kori --config')"
```

### Metrics

`GET /metrics` answers the Prometheus text format (`text/plain; version=0.0.4`): request counts by
route, counts by status class, failover counts by the reason the walk recorded, cooldowns started per
route, a live `kori_route_cooling` gauge, a latency histogram in milliseconds, the window's
`cost_usd`, the reload count and a `kori_info` build marker. Everything is tallied by the request
path; nothing dials a provider and no scrape touches the log file. The listener is the same loopback
one the rest of the admin surface uses, so scraping from another host means going through the edge.
A scrape needs the admin token like every other admin read.

### HTTP surface

| Path | Method | Auth | Purpose |
|---|---|---|---|
| `/v1/chat/completions` | POST | edge bearer | the gateway door |
| `/v1/systemone` | POST | edge bearer | a decision passthrough (`DEC-19`): the caller's System One body goes upstream with only `model` replaced, answered from its own `systemone.legs` list; `404` when the config declares none |
| `/v1/models` | GET, HEAD | edge bearer | the model list derived from this config: one `kori/<alias>` per alias, plus every leg `model` id; no provider is dialled |
| `/healthz` | GET, HEAD | none | `{"status":"ok","version":…,"revision":…}`; revision is the git sha the binary was built from, or `dev` |
| `/healthz?deep` | GET, HEAD | admin | the same liveness, plus per-leg state, cooldown, last success, last failure and window counters, read from router state with zero dials |
| `/metrics` | GET, HEAD | admin | Prometheus text exposition: requests, failover reasons, cooldowns, latency histogram, cost, reloads |
| `/admin/state` | GET, HEAD | admin | routes, window counters, failover events, recent log rows |
| `/admin/log` | GET, HEAD | admin | a page of the request log, newest first |
| `/admin/config` | GET, HEAD | admin | the loaded config with every credential redacted |
| `/`, `/index.html`, `/requests.html`, `/routes.html`, `/config.html` | GET, HEAD | admin | the dashboard pages, served from the compiled static table; a browser without the credential is redirected to `/login.html`, a script gets `401` |
| `/login.html`, `/assets/*`, `/fonts/*` | GET, HEAD | none | the login form and the files it needs; they carry no data |
| `/session/login` | POST | none | body `{"token":"…"}`; `204` and the `kori_admin` cookie, `401` for a wrong token, `429` over the login limit, `405` for any other method |
| `/session/logout` | POST | none | drops the session and clears the cookie; `204` whether or not one existed |
| anything else | any | none | `404` |

`admin` means the admin token as `Authorization: Bearer <token>` or the `kori_admin` session cookie;
see "Admin authentication" below. `edge bearer` is Caddy's `KORI_EDGE_TOKEN`; kori itself checks no
caller credential on `/v1/*`.

Any method other than GET or HEAD under `/admin/` is a `405` that names `GET`. The dashboard files
are compiled into the binary, so no page and no asset is read from disk. The one file a request
reads is the admin token, once per gated request.

`/admin/log` takes `limit` (1-200, default 50), `offset`, `route`, `status_class` (`2xx`, `4xx`,
`5xx`), `reason` (the token, or `none` for requests that did not fail over), `stream` (`true`,
`false`), `since` (RFC 3339) and `alias` (the exact `kori/<alias>` a caller named). A malformed value
is a `400` that names the parameter, and no file read happens.

Router state is memory only. After a restart every leg reads `unknown` with no cooldown and zero
counters; the log is the durable record, not a source of router state.

### Admin authentication

The admin surface is one shared token (`DEC-20`). A script or a scrape sends it as
`Authorization: Bearer <token>`; a browser gets the `kori_admin` session cookie from the login form.
Either one is enough, and the token is compared against the file in constant time.

`POST /session/login` takes `{"token":"<token>"}` and answers `204` with `Set-Cookie: kori_admin=…;
HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=2592000`. `POST /session/logout` drops the entry
and clears the cookie. Sessions live in memory for thirty days, so a restart signs everyone out.
Both paths sit outside `/admin/` on purpose: anything but GET or HEAD under `/admin/` is still a
`405`.

Five failed logins within five minutes answer `429` for every caller, because behind Caddy each
request arrives from one address. The limit is counted globally and applies to a *failed* attempt: a
correct token is compared first and always gets its session, so the window throttles brute force
without ever locking the owner out (`DEC-21`). Wait the window out for a wrong token.

A gated dashboard page answers `302` to `/login.html` when the request accepts HTML, and the `401`
JSON body otherwise, so `curl` learns why instead of receiving a page it cannot use. `/healthz` stays
open: it is the deploy probe, and a rollback must not need a secret. `/v1/*` is unchanged and the
edge bearer is its gate.

The token is a file, not a config key: `KORI_ADMIN_TOKEN_FILE`, default `/etc/kori/admin.token`,
read on every request, so a new value works for a new login without a restart. A live session is
checked against the session table, not against the current token, so replacing the file does not end
sessions already issued; rotation after a possible leak is the new file plus `systemctl --user restart
kori-api`. It never appears in `config.json`, in `/admin/config`, in a URL or in the request log. When the file is missing,
unreadable or empty, every gated surface answers `404` with the ordinary not-found body instead of
`401`: a gateway with no admin token should not advertise that it has an admin surface. The dashboard
is then dark, `/login.html` still loads, and a login attempt gets the same `404`. The token setup
steps are under "Deployment".

### Dashboard

Four read-only pages, wired to the three admin GETs. All four need the admin token; `/login.html` is
the only page that loads without one.

| Page | Shows |
|---|---|
| `/` Overview | route health, the window counters, recent requests |
| `/requests.html` | the request log with filters |
| `/routes.html` | per-route state, cooldowns and latency |
| `/config.html` | the loaded config with credentials redacted |

The pages are built in `apps/web` and committed as `apps/web/dist`. `tools/gen-static.sh` turns that
directory into `apps/api/src/generated/static_files.nim`, which is also committed. Both are checked
for drift in CI, so a stale embed fails the build instead of shipping an old page.

## Repository layout

```
apps/api/       Nim gateway source, Dockerfile
apps/api/src/generated/static_files.nim   dashboard compiled into the binary
apps/web/       dashboard source (vite, TypeScript) and the committed dist
acceptance/     A1-A17 harness, lib.sh, stub.py, self-test
ops/            deploy, rollback and smoke scripts, Caddy, env, systemd, webhook templates
tests/          unit tests and the dry runs ./task ops calls
tools/          gen-static.sh
task            the one entry point for the checks
docs/           architecture and decisions
```

## Local development

### Prerequisites

| Tool | Version | Needed for |
|---|---|---|
| Nim | 2.4.2 | the binary, the unit tests, the acceptance harness |
| Node.js and pnpm | 26 / pnpm 12 | rebuilding the dashboard under `apps/web` only |
| shellcheck | any recent | `./task ops` |
| jq, curl, python3 | stock | the acceptance harness under `acceptance/` |

Nim 2.4.2 is the version CI pins. The binary needs OpenSSL headers at build time, because every leg is
`https`.

### Quickstart

```sh
nim c -d:release --mm:orc --threads:on --hints:off -o:apps/api/src/kori apps/api/src/kori.nim
./apps/api/src/kori --config ~/.config/kori/kori.json --port 4021 --log /tmp/kori.jsonl
```

`apps/api/src/config.nims` is picked up automatically and adds `-d:ssl` plus the revision string
`/healthz` reports, so no extra flags are needed. `./task nim` runs the same build after `nim check`,
`nimble test` and the static-embed drift check, then runs the acceptance self-test against the binary.

`--config` is required. There is no default path and no search path. A missing file, unreadable file
or invalid JSON exits `2` before the listener opens.

| Flag | Meaning | Default |
|---|---|---|
| `--config` | path to the JSON config | required |
| `--address` | IPv4 literal to bind | `listen.host`, then `127.0.0.1` |
| `--port` | port, 1-65535 | `listen.port`, then `8787` |
| `--log` | request log path | `log.path`; exit `2` if neither is set |
| `--help` | usage on stdout | none |

Both `--flag value` and `--flag=value` are accepted. Precedence is CLI over config over built-in
default. An unknown flag, a non-numeric port or a non-literal address exits `2` with one usage line on
stderr. Exit codes: `0` clean, `2` bad config or CLI, `1` anything else.

The admin surface answers `404` until a token file exists, so a local run needs one too. Point the
variable at a file you create yourself instead of `/etc/kori`:

```sh
umask 077; openssl rand -hex 32 > /tmp/kori-admin.token
KORI_ADMIN_TOKEN_FILE=/tmp/kori-admin.token \
  ./apps/api/src/kori --config ~/.config/kori/kori.json --port 4021 --log /tmp/kori.jsonl
```

`/healthz` and `/v1/*` answer without it. `/admin/*`, `/metrics` and the dashboard pages do not.

## Configuration

The config is a JSON object. It holds every provider credential, so it never belongs in the
repository, in an image or in a log.

```json
{
  "listen": { "host": "127.0.0.1", "port": 8787 },
  "log":    { "path": "/var/log/kori/requests.jsonl", "rotate_bytes": 67108864, "keep": 2 },
  "balance": false,
  "prices": { "deepseek/deepseek-v4.1-flash": { "in": 0.3, "out": 1.2 } },
  "legs": [
    {
      "name": "commandcode",
      "base_url": "https://api.commandcode.ai/provider/v1",
      "model": "deepseek/deepseek-v4.1-flash",
      "api_key": "…",
      "role": "primary"
    },
    {
      "name": "sinarcloud",
      "base_url": "https://ai.sinarcloud.com/v1",
      "model": "deepseek/deepseek-v4-1-flash",
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
| `legs[].api_keys` | no | an ordered key pool, for example `["…","…"]`; rotated on a `401` or a quota `429` so one dead key does not cost the leg (DEC-13). Cannot be combined with `oauth` |
| `legs[].retries` | no | how many more dials this leg gets before the walk moves on, `0`-`5`, default `0` (DEC-12) |
| `legs[].headers` | no | extra request headers, for example `x-opencode-session` |
| `legs[].role` | no | `primary` or `fallback`, default `primary` |
| `legs[].weight` | no | `1`-`1000`, default `1`; the share of the pick when `balance` is on (DEC-11) |
| `legs[].enabled` | no | `true` or `false`, default `true`; a leg set to `false` keeps its place in the failover order but is never dialled, and `/admin/state` reads it as `skipped` |
| `legs[].aliases` | no | an object of caller alias to this leg's provider id, for example `{"fast": "prov-a-fast"}`; the key is the alias alone, without `kori/`, and one name may map to a different id on each leg |
| `legs[].efforts` | no | the `reasoning_effort` values this leg accepts, for example `["low", "high", "max"]`; a value outside the rank table is refused at startup. See "Thinking effort" above |
| `legs[].oauth` | no | makes the leg refresh its own access token; see above |
| `legs[].oauth.token_url` | yes, with `oauth` | the endpoint kori POSTs to; must be `http` or `https` |
| `legs[].oauth.client_id` | yes, with `oauth` | sent with the refresh grant |
| `legs[].oauth.refresh_token` | yes, with `oauth` | the seed; a rotation in the answer replaces it |
| `legs[].oauth.client_secret` | no | sent only when the endpoint needs it |
| `legs[].oauth.access_token` | no | a seed token, used until the first refresh |
| `legs[].oauth.expires_at` | no | epoch seconds; without it kori refreshes only after a `401` |
| `legs[].oauth.refresh_skew_seconds` | no | refresh this long before expiry, default `60` |
| `balance` | no | default `false`, which keeps strict leg order; `true` splits the pick across available primaries by `weight` (DEC-11) |
| `prices` | no | USD per million tokens, keyed by the model id sent upstream, for example `{"z-ai/glm-5.3-flash": {"in": 0.15, "out": 0.5}}`; `"*"` is the catch-all. A caller alias is not the key: the id the leg sends is. A model with no entry logs no `cost_usd` (DEC-16) |
| `systemone` | no | a second door, `POST /v1/systemone` (`DEC-19`); absent means the route answers `404`. Its legs are not part of the chat walk |
| `systemone.legs[].name` | yes, with `systemone` | the name that appears in the log and on the dashboard |
| `systemone.legs[].base_url` | yes, with `systemone` | kori appends `/systemone` to its path, unless the path already ends there |
| `systemone.legs[].model` | yes, with `systemone` | the provider id that replaces the caller's `model`; unlike a chat leg this is required, because the whole reason the door exists is that the caller's name is not the provider's |
| `systemone.legs[].api_key` | no | sent as `Authorization: Bearer …` unless `headers` already sets one |
| `systemone.legs[].headers` | no | extra request headers |
| `systemone.legs[].enabled` | no | `true` or `false`, default `true` |
| `log.rotate_bytes` | no | rotate the live log at this size in bytes; `0`, the default, keeps one growing file (DEC-17) |
| `log.keep` | no | how many rotated files stay beside the live one, `1`-`20`, default `2` |
| `listen`, `log` | no | overridden by `--address`, `--port`, `--log` |

For the `opencode-go` leg, which the committed template no longer chains, `token_url` and `client_id`
are the OpenCode Console's own values, published in its OAuth discovery document at
`https://opencode.ai/console/.well-known/oauth-authorization-server` and in
`https://opencode.ai/oauth/opencode/client.json`; the client is public and authenticates with
`token_endpoint_auth_method` `none`, so no client secret is sent. `refresh_token` is the only secret
in the block: it comes from the OpenCode credential store on the machine that owns the account
(`opencode auth export`), never from the repository, and the refreshed values are written back into
the running config file with mode `0600`. `ops/scripts/kori-config.sh` asks for the three OpenCode
values only when the template carries their placeholders, so a two-leg template needs the two
`api_key` values and nothing else.

The `commandcode` and `sinarcloud` legs take a static `api_key` and nothing else: neither key expires,
so neither leg has an `oauth` block and kori never refreshes them.

The caller's body is forwarded byte for byte, with one exception: for a streaming request kori sets
`stream_options.include_usage` if the caller did not, so the leg reports token counts.

The deploy side reads its own variables, listed with defaults in
[`ops/env/kori-prod.env.example`](ops/env/kori-prod.env.example): `KORI_APP_DIR`, `KORI_PORT`,
`KORI_IMAGE`, `KORI_SERVICE`, `KORI_HEALTH_URL`, `KORI_ADMIN_TOKEN_FILE` and `KORI_EDGE_TOKEN`.
`KORI_EDGE_TOKEN` is a secret and belongs only in the host environment, never in a committed file.
`smoke.sh` reads the admin token from `$KORI_APP_DIR/etc/admin.token` on the host; `KORI_ADMIN_TOKEN`
exists only as an override for a manual run and is never set on the host, because the env file it
would sit in also becomes the container's environment.

## Quality gates

`./task` is the single entry point; every target exits nonzero with a reason when its input is
missing.

```sh
./task help    # the target list
./task ops     # shellcheck + deploy/smoke/preflight/rollback/config dry runs, no podman, no network
./task web     # vite build in apps/web, then fail if the committed dist is stale
./task nim     # nim check, nimble test, embed drift, release build, acceptance self-test
./task check   # all of the above, in CI order
```

The acceptance harness proves the router end to end against a real binary:

```sh
KORI_BIN=./apps/api/src/kori sh acceptance/run-all.sh   # the seventeen cases, A1-A17
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
| a12 | a leg that names a model sends that id, and only that leg does (DEC-10) |
| a13 | `/v1/models`, `retries`, a key pool, `model_gone`, weighted balancing and `/healthz?deep` (DEC-11 to DEC-14) |
| a14 | `cost_usd`, the SIGHUP reload, log rotation and `/metrics` (DEC-15 to DEC-18) |
| a15 | the System One door: passthrough, its own log line, a bad model, a caller's 400 and an unconfigured door (DEC-19) |
| a16 | the admin gate: `401` without a credential, `404` with no token file, the cookie flags, the login limit, `429`, and `/healthz` still open (DEC-20) |
| a17 | the anonymous transport limits: a body over 8 MiB is a `413` before it is buffered, a half-sent request is released at the 30 s read timeout, every JSON read is `no-store` + `nosniff`, and `HEAD` carries no body |

Cases use logical port numbers; `acceptance/lib.sh` resolves each to a free port per run, so a run
leaves nothing behind and can be repeated immediately.

`.github/workflows/ci.yml` runs seven jobs: `Contract`, `Security`, `Ops`, `Nim`, `Gate`, `Image: api`,
`Web`. Every job has `timeout-minutes: 15`, caches its toolchain, and passes event data through `env:`
rather than interpolating it into a shell script. `Gate` is the single required status and the only
door to publishing the image.

## Deployment

`ops/` holds the deploy contract for a rootless podman deploy behind a Caddy edge: the deploy,
rollback and smoke scripts, the Caddy block, the env example, systemd units and the webhook
template. qouver1 runs this shape. The host-side pieces (webhook install, clone, env file, config
file, Caddy import) live on that host and belong to the deploy owner, so read `ops/` as the
contract those files implement rather than as a snapshot of the running machine.

The container mounts `/srv/qouver/apps/kori/etc` at `/etc/kori`, so the admin token file goes in that
directory and is created once, before the first deploy that expects a dashboard:

```sh
install -d -m 0700 /srv/qouver/apps/kori/etc
umask 077; openssl rand -hex 32 > /srv/qouver/apps/kori/etc/admin.token
chmod 600 /srv/qouver/apps/kori/etc/admin.token
```

The token stays out of the repository, out of the image and out of `config.json`. On the host it does
not belong in `ops/env/kori-prod.env` either, and the committed example never carries a value.
`KORI_ADMIN_TOKEN_FILE` names the path inside the container and already defaults to
`/etc/kori/admin.token`; set it only when the file lives somewhere else. Writing the host path into
that variable points the binary at a directory the container does not have, and every gated surface
answers `404` for the wrong reason.

Nothing in `ops/env/kori-prod.env` carries the token: that file becomes the container's process
environment, so a copy there is readable from inside the container and from `/proc` on the host.
`smoke.sh` reads the file above (`$APP_DIR/etc/admin.token`) itself, so with a token file in place the
release gate proves `200` on `/admin/state` and `/metrics`; with no file it asserts the `404` branch,
and with a file but no readable token it accepts `401`. `KORI_ADMIN_TOKEN` is an override for a manual
run against a local binary, not something the host sets.

The deploy, rollback and smoke scripts probe `/healthz`, never `/admin/state`. A host whose token
file is missing deploys green while the dashboard answers `404`: that is the fail-closed default,
not a failed deploy. If the dashboard is dark after a deploy, check the file exists, is readable and
is not empty inside the container.

### The readiness probe

`ops/systemd/kori-readyz.service` and `ops/systemd/kori-readyz.timer` are the only thing on the
host that notices a gateway which is up and no longer answering. `Restart=always` reacts to a
process that exits; `OnFailure=alert@kori-api.service` on the container unit only fires when the
unit itself fails. A wedged process, or a container up with the port dead, was silent until this
probe existed.

`deploy-vps.sh` installs both units into `~/.config/systemd/user` (not the Quadlet directory: systemd
answers `LoadState=not-found` for a timer placed there) and runs `systemctl --user enable --now
kori-readyz.timer`. An unchanged unit is not rewritten, so a normal deploy does not restart the timer.

The probe is one `curl --fail` against `http://127.0.0.1:8787/healthz`, every five minutes with up
to 30 s of randomised delay. It asks `/healthz` and not `/admin/state` on purpose: `/healthz` is open
by design (`DEC-20`), so the probe needs no credential and cannot go red because a token file is
missing or unreadable. Liveness and the gate are two different questions, and only the first one is
"It is 3 AM and the gateway is dead".

Reading a probe failure, and reproducing it by hand:

```sh
systemctl --user status kori-readyz.timer kori-readyz.service   # last run, next run
journalctl --user -u kori-readyz.service -n 20                  # what curl answered
curl -sS --fail --max-time 10 http://127.0.0.1:8787/healthz     # the same check, by hand
```

A failed run exits non-zero, and `OnFailure=alert@%N.service` pages through the same sink the rest of
the host uses. A deliberate stop also trips it: `deploy-vps.sh` restarts the unit to load the new
image, and `rollback.sh` restarts it again, so a probe failure inside or just after a deploy is the
deploy, not an outage. Read it together with the deploy log:

```sh
tail -n 40 /srv/qouver/apps/kori/logs/deploy.log   # was a deploy running at that minute?
```

A failure with no deploy and no rollback in that window is the real thing: pages even though
nothing was touched. Start with `journalctl --user -u kori-api -n 50` and the request log, and if the
gateway is really down, `ops/scripts/rollback.sh` puts the `:prev` image back.

## Documentation

Two documents, both under `docs/`, indexed at [`docs/README.md`](docs/README.md):

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): the request path, leg state and module boundaries.
- [`docs/DECISIONS.md`](docs/DECISIONS.md): the decision records this README refers to, including DEC-10.

## Security

Do not open a public issue. The reporting channel, the revision to quote, and what is in and out of
scope are in [`SECURITY.md`](SECURITY.md).

## Contributing

Send an issue or a patch to the maintainer. What a change has to pass, and what never belongs in a
diff, are in [`CONTRIBUTING.md`](CONTRIBUTING.md); the acceptance harness is the gate that matters
most, because it proves routing against a real binary.

## License

MIT. See [LICENSE](LICENSE).
