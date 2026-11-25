# Decisions

Decisions already made for kori, recorded with the reasoning so a later reader does not
have to reconstruct it. Numbering here is local to this file; the spec's own `D`-numbers
live in `DASHBOARD-surface.md` and the failover spec, and are not restated.

A decision that is superseded gets a new entry that names it, not an edit to the old one.

---

## DEC-1 — The dashboard is compiled into the binary

**Status:** accepted.

**Context.** The dashboard is four static pages over three read-only GETs. The container
image runs one Nim binary and no Node, and the image is built from a repository where
`apps/web/dist` is committed.

**Decision.** `tools/gen-static.sh` turns `apps/web/dist` into
`apps/api/src/generated/static_files.nim` using `staticRead`, and the module is committed.
The binary serves the pages from memory. Nothing is read from disk at runtime.

**Consequences.** One image, one process, no file mount for the dashboard, and no way for
the served page to differ from the committed one. The cost is that the dashboard must be
rebuilt and regenerated in the same commit as any change, which CI enforces as a drift
check: regenerate, then `git diff --exit-code`. A hand edit to the generated module is a red
build, not a silent ship.

---

## DEC-2 — One image, one origin

**Status:** accepted.

**Context.** The alternative was a separate web image served by its own proxy, as some
other repositories here do.

**Decision.** The API image is the only image. The dashboard is served by the same listener
as `/v1` and `/admin`, on the same origin.

**Consequences.** No second deploy target, no CORS, no second Caddy site, and no version
skew between the page and the API it calls. The edge can refuse `/admin` for the public
door in one rule because there is only one door. The cost is that the dashboard cannot be
deployed independently of the gateway.

---

## DEC-3 — The acceptance harness lives in the repository

**Status:** accepted.

**Context.** The harness started as scripts inside workloop artifact folders. That made
`./task nim` red for anyone who cloned the repository, and it meant CI never ran a single
end-to-end case.

**Decision.** The harness lives at `acceptance/`, with `selftest.sh` as the fast gate and
`run-all.sh` as the end-to-end cases. Both are driven by `KORI_BIN` and nothing else.
CI builds a release binary and runs `run-all.sh`; `./task nim` runs `selftest.sh`.

**Consequences.** A clone can prove the router without reading a report. The harness is
subject to the same review as the code it tests, which is the point. Cases must stay
self-contained: no absolute paths, no writes outside a temp directory the harness creates
and removes, no live token in any fixture.

---

## DEC-4 — The admin surface is read-only

**Status:** accepted.

**Context.** A dashboard that can change routing looks useful until it becomes a second way
to configure a gateway whose only config is a file on the host.

**Decision.** `/admin/state`, `/admin/log` and `/admin/config` are `GET` and `HEAD` only.
Any other method under `/admin/` is a `405` that names `GET`, with no upstream dial and no
state change. An unknown path under `/admin/` is a `404`.

**Consequences.** There is exactly one way to change behaviour: edit the config and restart.
No admin action can move a cooldown, clear a counter or reveal a credential. `/admin/config`
reports a `<path>:<line>` reference per credential, never the value.

---

## DEC-5 — Router state is memory only

**Status:** accepted.

**Context.** The obvious alternative is persisting leg health so a restart does not forget
that a provider was dead.

**Decision.** Every leg starts `unknown` with no cooldown and zero counters. The request log
is the durable record; it is never a source of router state.

**Consequences.** No database, no migration, no restore drill, and no way for a stale
persisted state to keep a healthy leg out of rotation. The cost is that a restart loses
cooldown knowledge and will re-dial a dead leg once. That is one failed request, which the
fallback already handles.

---

## DEC-6 — The request log is append-only, one line, eleven keys

**Status:** accepted, amended 2026-11-17 (was: ten keys).

**Context.** The claim this gateway has to make checkable is "how many failovers, when, on
which route". That claim is only as strong as the log behind it.

**Decision.** One line per request, appended with a single write, never rewritten and never
rotated in v1. The keys are fixed and ordered: `ts`, `route`, `status`, `latency_ms`,
`tokens_in`, `tokens_out`, `failover_from`, `failover_reason`, `stream`, and then the two
conditional ones last: `alias` and `effort_clamped`. `alias` is there only when the caller
named a `kori/<alias>`: a request that named a provider id has no such key at all, not an
empty one, so the page shows the absence instead of inventing a value.

**Amendment, 2026-11-17.** `effort_clamped` was added when the per-leg effort ceiling
landed. Its value is `<asked>><sent>`, for example `max>high`, and it is written only when a
leg's ceiling actually pulled the requested effort down. The reason it is a key and not a
`failover_reason` value: a clamp is not a failure and starts no cooldown, so putting it in
the reason field would have made a served request read like a rerouted one. The reason it is
conditional rather than always present: a request that never clamped is exactly the request
this log already described with nine keys, and adding a null to every line would have made
every earlier row a special case. A clamp is recorded against the leg that answered, so a
clamp on a leg that then failed is replaced by whatever the next leg decided.

**Amendment, 2026-11-18.** No key was added: the retry, key-pool and
`caller_fault` work of 0.6.2 all fit the eleven keys. A retry is a second dial on the
same route, so it is not a failover and writes nothing new; a key rotation is likewise
invisible in the line, because the log may say which route answered and never which
credential did. A caller that hangs up after the first byte is named in
`failover_reason` as `caller_fault` instead of `mid_stream_abort`, because the leg was
healthy and a push of abandoned requests must not read as a provider going bad.

**Consequences.** A month-over-month comparison is repeatable, and a later reader can
re-check the failover count without asking anyone. Redaction is structural: the writer takes
no header, body or credential parameter, so there is nothing for a later pass to strip.
Adding a key is a spec change, not a local edit. Growth is handled by the bounded backwards
scan in `/admin/log`, not by rotation.

---

## DEC-7 — Loopback bind, edge at the door

**Status:** accepted.

**Context.** The gateway holds paid provider credentials, and the deploy host runs other
services behind one Caddy.

**Decision.** The binary binds `127.0.0.1` by default. The container publishes
`127.0.0.1:8787` only. The public door is one Caddy site with a bearer token, a per-IP rate
limit and a Cloudflare-range allow list, and `/admin` is refused there.

**Consequences.** An unauthenticated port on the LAN does not exist, and a mistake inside
the binary cannot expose the dashboard. Inside the container the binary must listen on
`0.0.0.0` for rootless podman to forward from the bridge address; the spec's "never
`0.0.0.0`" is satisfied by the publish address, not by the in-container bind. That is the one
place wording and runtime disagree, and it is deliberate.

---

## DEC-8 — One weight, refused otherwise

**Status:** superseded on 2026-11-18 by DEC-11. Left in place because a superseded
decision is recorded, not edited away.

**Context.** Weighted splitting across primaries is a feature with a real cost: the split has
to be defined, observable and testable.

**Decision.** `weight` must be `1`. Any other value is refused at startup with exit `2`.
`balance` defaults to `false`, which keeps strict config order.

**Consequences.** A config never asks for a split the binary cannot honour. Turning on
balancing is one boolean and it is round-robin, not weighted, so there is nothing to explain
when the traffic does not land where someone expected.

## DEC-9 — A failed credential refresh stops the request instead of failing over

**Status:** accepted. This is a deliberate deviation from the failover rule.

**Context.** Every other leg failure walks to the next leg, so a refresh failure looks like
one more failure to fail over from. It is not: the refresh belongs to the credential, not to
the leg's availability, and retrying the same leg with a stale bearer or asking a different
provider for the same work hides a broken credential behind an answer that looks served.

**Decision.** When the token endpoint refuses or the refresh deadline fires, the request
ends with `502` and `{"error":{"type":"credential_refresh_failed"}}` (or `refresh_timeout`
when the 5 s budget was spent). No fallback leg is dialled, no stale bearer is sent, and one
line goes to stderr. A `401` from the leg itself is different and keeps the normal rule: one
forced refresh, one retry, then the usual classification.

**Consequences.** A dead token is visible in the answer and in the log instead of being
absorbed by the failover chain. The cost is that a broken credential takes the route down
even when another leg could have answered, which is the point: it is an operator problem,
not a provider problem.

## DEC-10 — A leg's `model` is the id that leg is sent

**Status:** accepted. Supersedes the README line that said `model` is reported and never
rewritten, and fills a gap the failover spec leaves open.

**Context.** The spec fixes one primary route plus ordered fallback across opencode-go,
commandcode and sinarcloud, and it says nothing about the `model` field. The three providers
do not accept the same ids: a caller that sends one name cannot be served by all three if
kori forwards it verbatim, so the three-leg chain could never answer from more than one leg.
Measured on 2026-11-16: opencode-go answers `429 GoUsageLimitError` and commandcode
`400 insufficient credits`, so only sinarcloud has ever served a request, and the mismatch
had not shown up yet.

**Decision.** When a leg's config names `model`, kori replaces the caller's top-level
`model` with that id before dialling that leg, and only that leg. A leg without `model`
forwards the caller's body byte for byte, which is what every existing config does. The
rewrite is textual and touches one string value: everything else the caller sent reaches the
leg unchanged, the same promise `injectIncludeUsage` keeps. A body with no top-level `model`
string is not refused and not given one.

**Consequences.** One gateway can front three providers with different ids, and the caller
keeps asking for one model name. In the request log the three facts stay separate: `route`
is the leg that answered, the response `model` is the provider id that leg actually sent,
and `alias` is the name the caller asked for, written only when the caller used one. A leg
with a static `model` still cannot serve a per-request provider id: the config decides what
a leg sends, not the caller. That is consistent with a fixed chain and it is visible in the
config, but a wider need for caller-side model selection is a new decision, not a config
flag.

## DEC-11 — A weight is a small integer, and the split is smooth weighted round-robin

**Status:** accepted 2026-11-18. Supersedes DEC-8, which refused every weight but 1.

**Context.** DEC-8 refused a weighted split because an unhonoured weight is a lie in a
config file. The cost of that refusal was one honest line in the comparison table: kori
cannot balance. The split itself is 40 lines, and the reason to refuse it was never the
size, it was that an undefined split is worse than none. So the decision changes with the
rounding defined, not with the workload.

**Decision.** `legs[].weight` is an integer from 1 to 1000 (`MaxWeight`). Zero, a negative
number and anything above the ceiling are refused at startup with the leg and the value
named, because a zero weight would silently remove a leg from the split. With `balance:
true`, the pick is nginx's smooth weighted round-robin over the available primaries: each
turn a candidate gains its weight, the largest current wins, and the winner pays the total
back. Equal weights degenerate to plain round-robin, so a config that never names a weight
behaves exactly as it did. A cooling leg leaves the pool, so its share is redistributed
rather than silently halved onto nobody. `balance: false` keeps strict config order and the
weight is then inert, which the README says in one line instead of leaving it to be guessed.

**Consequences.** A 3:1 config serves three requests on the heavy leg and one on the light
one, repeatably, and the unit tests assert the exact 300:100 over 400 picks. The state is
the per-leg `weightCurrent` credit, which lives in memory with the rest of the router state
(DEC-5) and resets on restart. The cost is a per-request cursor and one arithmetic pass over
the candidate pool; no lock, no allocation beyond one small seq, and no effect on a config
that keeps weight at 1.

---

## DEC-12 — A retry is a dial on the same leg, and it is not a failover

**Status:** accepted 2026-11-18.

**Context.** kori's only retry was failover. One-second blip on a healthy provider was
enough to mark the leg dead and start a 60 s cooldown, which turns a tiny provider hiccup
into a minute of lost capacity on the leg that was about to work.

**Decision.** `legs[].retries` is how many more dials that leg gets before the walk moves
on. The default is 0, so no existing config changes behaviour. The pause doubles from 200 ms
to a 2 s ceiling, plus up to a quarter of the pause as jitter so a fleet of callers does not
resynchronise on one leg. Only the transport classes are retried: `conn_refused`,
`dial_timeout`, `header_timeout`, `upstream_5xx`. A `401` rotates a key instead, and a quota
`429`, a missing session, a dead model and any caller `4xx` are decided facts, so retrying
them only spends time and the owner's quota.

**Consequences.** A one-dial blip is absorbed without a failover event, a cooldown, or a
second provider spending tokens. The log line is unchanged: the request never left the leg,
so `failover_from` and `failover_reason` stay empty and the retry is visible only as the
leg's dial count. The bound is per leg and per request, so the worst case added latency is
the sum of the pauses, not a loop.

---

## DEC-13 — A dead key is a dead credential, not a dead leg

**Status:** accepted 2026-11-18.

**Context.** One key per leg means one revoked or capped key takes the whole leg out of the
chain for a full cooldown, even when the provider would answer the same route with another
key.

**Decision.** `legs[].api_keys` is an ordered pool. `api_key` stays supported and is the
pool of one when the pool is absent, so no config in use changes. On a `401` or a quota
`429`, the key in use is cooled for its own cooldown (60 s, or 900 s for quota) and the next
live entry is tried on the same leg before the leg is blamed. When every entry is cooling,
the leg cannot be dialled and the walk moves on without a cooldown of its own. A pool with
more than one entry and an `oauth` block are refused at startup: only one of them can be the
bearer, and picking silently would hide a config mistake. `/admin/config` reports the pool
size and how many entries are cooling, never a key. The request log carries no key and no
key index: it says which route answered, not which credential paid.

**Consequences.** A revoked key costs one dial, not the leg. The cost is that rotation is
in memory and resets on restart, which is the same contract the rest of the router state
keeps (DEC-5).

---

## DEC-14 — `/v1/models` is derived from the config, and `/healthz?deep` dials nothing

**Status:** accepted 2026-11-18.

**Context.** Every OpenAI-shaped SDK probes a model list before it will talk to a gateway, and kori
served one path and no list, so a client either could not enumerate or had to be
hand-configured. The same clients probe model health; both vendors do it by dialling the
provider, which spends the owner's quota to answer a question the router already knows.

**Decision.** `GET /v1/models` returns an OpenAI-shaped list built from the config alone: one entry
per `kori/<alias>` (deduplicated across legs, because one caller name is one model) and one
per leg model id the config names. No provider is dialled and no credential is read, so the
endpoint answers on a fresh process with every leg dead. `GET /healthz?deep` is a variant of
the existing health path, not a second path: each leg's state, cooling time, last success,
last failure and window counters, read from router state with zero dials. Liveness stays
`status: ok` in both answers, because a process answering at all is the liveness fact.

**Consequences.** A client can enumerate what this door accepts, which was the only real
blocker to a drop-in replacement. The cost: the list reflects the config, not what the
provider will actually accept, so a config that names a model the provider has dropped keeps
listing it until the operator fixes the config. That is visible in `/healthz?deep` the first
time the leg answers `404 model_not_found`, which is classified as `model_gone` and fails
over rather than being returned as a caller error.

## DEC-15 — A reload is a SIGHUP, and a file that does not validate is refused whole

**Status:** accepted 2026-11-18.

**Context.** Every config change — a rotated provider key, a new fallback, a disabled leg — needed a
restart, and a restart closes the listener while a stream may be half-written. On a gateway that
serves long completions, that is a request cut in half for a file edit.

**Decision.** `SIGHUP` re-reads the same config path. The new file is parsed and validated before
anything is applied; if it does not parse, does not validate, or moves `listen`, it is refused with
one stderr line, `/admin/config` records `reload.error`, and the process keeps serving the config it
already proved. On success legs, keys, models, aliases, efforts, `prices`, `balance` and the log
rotation policy are swapped in, router state follows a leg by name, and `reload.count` moves.
`listen` cannot change under a running process: it cannot rebind, so a moved listener is refused
whole rather than half-applied. A changed `log.path` is reopened, because the descriptor is the only
state a new path would invalidate. The swap itself waits for the in-flight request count to reach
zero, because a request mid-walk holds indices into the leg list it started with; a long stream
therefore delays a reload instead of being cut by one.

**Consequences.** A key can be rotated in a minute without a stream dropped, and a typo in the file
is a no-op instead of an outage. The cost: two sources of truth exist for a moment — the file on disk
and the config in memory — and `/admin/config` reports the memory, which is why `reload.at` and
`reload.error` are on the same payload. SIGHUP is not free of meaning (a container behind systemd
sends it on some stop paths), so the handler only raises a flag the event loop reads; it never does
work in signal context.

## DEC-16 — `cost_usd` is the config's price times the provider's own token counts

**Status:** accepted 2026-11-18.

**Context.** The log carried tokens and no money, so "what did this month cost" needed a spreadsheet
and a guess about which model answered on which leg. Prices change, and a price baked into a binary
is a price that lies until the next release.

**Decision.** `prices` is a top-level config object: model id to `{"in": usd_per_mtok, "out":
usd_per_mtok}`, with `"*"` as the catch-all. The lookup key is the id the answering leg was
actually sent — the leg's own `model`, or its alias mapping — because that is the model the
provider billed. The request line gains `cost_usd` as a twelfth, conditional key: six decimals,
present only when the model is priced and the provider reported at least one token direction.
`/admin/state` sums the same numbers into `window.cost_usd`, and `/metrics` prints it as
`kori_cost_usd_total`.

**Consequences.** A month is summing one JSON key, with no state and no database. The cost: a
provider that reports no usage yields no cost line, and a config that prices nothing yields no
`cost_usd` at all — both are visible absences rather than a zero that would quietly understate the
bill. A leg that reports tokens for a model the config does not price is also unpriced; the
catch-all entry exists so an operator can decide that once.

## DEC-17 — Rotation is size-based, opt-in, and plain text

**Status:** accepted 2026-11-18.

**Context.** The append-only log grew forever. Retention was listed as unhandled in the first
release, and an unbounded file on a 25 GB VPS is a disk incident waiting for the busiest week.

**Decision.** `log.rotate_bytes` turns rotation on; `log.keep` (default 2, maximum 20) says how many
rotated files stay beside the live one. At the threshold the process closes the descriptor, shifts
`<path>.N` one place up, renames the live file to `.1` and reopens. The check runs before the write,
so a line is never split. Rotation is off by default, because "append-only" is the promise this file
makes to whoever reads it after an incident. Rotated files are not compressed: gzip inside the
binary means a compression library in a build whose selling point is having no dependencies, and
spawning `gzip` on a request path is worse than a few more megabytes.

**Consequences.** Disk is bounded by `rotate_bytes * (keep + 1)` and a rotation never costs a
request. The cost: a busy day can push older lines out faster than a weekly read would like, and a
rotated file costs its full size until the operator compresses it out of band.

## DEC-18 — `/metrics` is plain text, tallied twice, and lives on the loopback listener

**Status:** accepted 2026-11-18.

**Context.** `/healthz?deep` answers a person. A scrape needs counters that survive a poll interval
and a format a scraper understands, and the whole point of this binary is not adding a library to
get one.

**Decision.** `GET /metrics` renders the Prometheus text format by hand: request counts by route,
status classes, failover reasons, cooldowns started, a cooling gauge, a millisecond histogram with
`LatencyBucketsMs` plus `+Inf`, the window's `cost_usd`, reload count and a `kori_info` marker. The
counters are incremented on the completion path that already writes the log line, so a scrape and
the log cannot disagree. The endpoint is on the same listener as the rest of the surface, so it is
loopback-only like `/admin/*` and reaching it from elsewhere is the edge's business.

**Consequences.** A Prometheus can scrape it with no exporter and no reverse proxy, and the numbers
are the ones the request path already decided. The cost: this is a second consumer of the same data,
so a counter that is incremented in two places has two places to get wrong — which is why the
increment sits exactly where the log line is built, and `/admin/state` reads the totals rather than
recomputing them. The histogram is a fixed table in the binary; changing the buckets means a release,
not a config edit.

## DEC-19 — `/v1/systemone` is a second door with its own legs, not a second protocol path

**Status:** accepted 2026-11-18, amended 2026-11-25 by DEC-28 (the first pick is weighted when
`systemone_balance` is on).

**Context.** Jev — the model that decides which bot answers a message in a group chat — is not a
chat model. On commandcode it is served at `POST /provider/v1/systemone` with a body of `state`,
`model` and `questions` keyed by question id, and it answers `answers` plus `usage.input_tokens` /
`usage.output_tokens`. Pointing MausBot straight at the provider would work, but it moves the
credential out of kori, takes the decision out of the request log and out of `/metrics`, and leaves
a second place to update when another provider starts serving jev.

**Decision.** `POST /v1/systemone` passes the caller's body through to an ordered list of System One
upstreams declared in a separate `systemone.legs` block. Exactly one field is rewritten: the
top-level `model` becomes the leg's configured id, because the caller's name for the model is not
the provider's (MausBot sends `jev-latest`; commandcode accepts `typesafe/jev-1.14.0`). Everything
else — `state`, `questions`, unknown fields — reaches the provider byte for byte, and the answer
comes back untouched. The walk is config order with the same dead-route classification and the same
60 s / 900 s cooldowns as the chat door, with one addition: a provider that answers "this model is
not supported on this endpoint" is a bad leg, so the walk moves on instead of handing the caller a
400 naming a model they never chose. There is no streaming, no retry, no key pool and no alias
table: System One answers once, and a decision is one call.

The block is optional. A config without it answers `404` on the route, so no existing config changes
behaviour, and a door nobody configured does not exist.

**Consequences.** One credential, one log, one set of counters for both doors, and adding a provider
that serves jev is a config edit plus `SIGHUP`. The cost: kori now speaks a second wire shape, and
that shape is a passthrough, not a translation — a provider that answers in a third shape cannot be
reached by a config edit, so "add another protocol" stays a code change and is refused here on
purpose. `systemone.legs[].model` is required, unlike a chat leg, because an empty id would forward
a caller string the provider rejects.

## DEC-20 — The admin surface has its own gate, inside the binary

**Status:** accepted 2026-11-19.

**Context.** `dash.qouver.com` served the dashboard and the three admin reads with no authentication.
On 2026-11-18 Galih measured `200` with no auth challenge on `/`, `/admin/state`, `/admin/log`,
`/admin/config`, `/metrics` and `/healthz`: no key was readable, `state=set`, `log.redacted=true`
and every non-GET under `/admin/` was `405`, but the pages named the provider chain, the model ids
and prices, the traffic volume, the window's `cost_usd` and the running revision. The footer said
"loopback only", which was false. Cloudflare plus the `@not_cloudflare` guard were the only gate,
so anyone who learned the hostname could read the dashboard. `DEC-7` binds the binary to loopback
and `DEC-18` calls the edge "the edge's business"; both were true of the network path and neither
decided who may read the pages.

**Decision.** Auth inside kori. `/admin/*`, `/metrics`, `/healthz?deep` and the five dashboard pages
require one shared token, presented as `Authorization: Bearer <token>` by a script or a scrape, or
carried as the `kori_admin` session cookie a browser gets from `POST /session/login`
(`{"token":"…"}`, `204`, thirty days, `HttpOnly; Secure; SameSite=Strict; Path=/`).
`POST /session/logout` drops the session. The token is a file named by `KORI_ADMIN_TOKEN_FILE`,
default `/etc/kori/admin.token`, read on every request so a new value works for a new login without a
restart, and compared in constant time over the full string. A session already issued is checked
against the session table, not against the current token, so a rotation after a possible leak is the
new file plus a restart of `kori-api`: without it, sessions minted under the old token live until they
expire. No token file, or an empty one, means every gated surface
answers `404` with the standard not-found body: a gateway that has no admin token should not tell a
caller it has an admin surface, and `401` would. Five failed logins in five minutes answer `429`,
counted globally rather than per IP, because behind Caddy every request arrives from one address and
a per-IP window would be one window. A gated page answers `302` to `/login.html` when the request
accepts HTML and `401` JSON otherwise, so a script learns why. `/healthz` and `/v1/*` stay ungated:
one is the deploy probe and the other is the OpenAI door, whose caller credential lives at the edge.

The two write paths sit at `/session/login` and `/session/logout`, not under `/admin/`, because
`DEC-4` and D11 keep `/admin/` read-only and GET/HEAD-only, and that is the rule a security review
re-checks.

Why not the other four. Cloudflare Access puts the only gate in a control plane nobody diffs, and no
Access header was present on any dash path, so it would have been a second system to learn for one
operator. Caddy `basic_auth` is a line in `site.caddy` and the closest of the four, but the gate
would still live only on qouver1: a rewrite of that block reopens the surface with nothing in this
repository going red. Tailscale adds a daemon and a second network to qouver1, which the deploy veto
on that host was already set against. Removing the DNS record and reaching the dashboard through an
SSH tunnel ends the dashboard as a thing anyone opens. The chosen option is source in this
repository: a reviewer sees it in a diff, the acceptance harness exercises it, and it holds if the
Caddy block drifts or an inside path reaches the listener directly.

**Consequences.** One gate for one operator, with no identity attached: no per-person audit, no MFA,
and no way to revoke one person without replacing the token for everyone. The auth code sits in the
binary that also serves `ai.qouver.com`, so a bug in it can close two doors at once; the log line has
no header field at all, so a cookie or a token has nowhere to be formatted into, and a unit test
proves a sentinel cookie value is absent from it. Sessions are memory only, so a restart signs the browser out, and a lost
token needs the file replaced on the host. Because `/admin/state` now answers `404` without a token,
the deploy gate moved to `/healthz`: a host with no token file deploys green with a dark dashboard,
which is the fail-closed default rather than a broken deploy. This record does not supersede `DEC-7`
or `DEC-18`; loopback and the edge still stand, and the binary now has a gate of its own behind
them. If the surface grows a need for per-person identity, the gate moves to Cloudflare Access and
this one becomes the second lock instead of the only one.

---

## DEC-21 — The login window throttles a failed attempt, not the credential

**Status:** accepted 2026-11-21. Narrows two sentences of `DEC-20`; `DEC-20`'s decision stands.

**Context.** `DEC-20` decided that five failed logins in five minutes answer `429`, counted
globally. It did not say *when* in the handler the window is read, and the code read it before the
token was compared, so a correct token was refused inside the window. The reasoning that made the
count global — behind Caddy every request arrives from one address, so a per-IP window would be one
window — is still true. What it did not account for is that `/session/login` is reachable without a
credential from the internet: measured 2026-11-21, five wrong tokens answered `429` to the sixth, and
the owner's own token answered `429` in the same window, locally and on `dash.qouver.com`. A loop of
five wrong logins every five minutes therefore keeps the owner out of their own dashboard for ever,
at a cost of about one request per minute. An availability decision had become a remote denial of
the gate it was meant to protect.

**Decision.** Compare first, throttle the failure. A request whose token matches gets its session
whatever the window holds. A request whose token does not match is counted, and the `429` applies to
that failed attempt only — the list never grows past `MaxAdminLoginFailures`, so the window still
closes after five failures for five minutes and a brute-force run is still cut off. The count stays
global for the `DEC-20` reason. The comparison an over-limit caller provokes is one constant-time
pass on a fixed-size string, so nothing is gained by refusing to do it.

**Consequences.** The lockout an anonymous caller could trigger is gone; the throttle it was there
for is not. The window is still not a per-caller signal, so an attacker who keeps the window full
makes *failed* logins answer `429` instead of `401` — a cheaper answer than before, and the reason
the edge rule in `OPS-SHIP §4.4` is still the right place for anything per-IP. `a16` asserts the new
contract: five failures, then a `429` for a wrong token and a `204` for the right one. The unit test
and the constant's comment name this record, so a reader following the number finds the reason.

---

## DEC-22 — The streaming first-byte deadline grows with the prompt, and stops at 60 s

**Status:** accepted 2026-11-24; supersedes the fixed number in `SPEC §3b.1`.

**Context.** `HeaderDeadlineStreamMs` was one constant, 15 s, applied to every streamed request
whatever it carried. Measured on `commandcode` across 24 hours on 2026-11-22: p90 first byte was
20.8 s for prompts of 50k tokens and above, against 15 s or less for short ones. So the deadline that
worked for a short prompt fired nine times a day on long ones. Each of those was a failover: the
request left a healthy leg, and the caller got whatever the next leg answered — which that week was
`sinarcloud` with an empty balance and a `402`. A deadline tuned for the common case was moving real
traffic to a worse provider, and the failover log called it a provider failure.

**Decision.** The streaming first-byte window is a floor plus a slope on the outbound body:
`15_000 + (body.len div 1024) * 100` milliseconds, capped at `60_000`. A short prompt keeps the
15 s it had; a 50k-token prompt (about 200 KiB) gets about 35 s. The cap is the part that matters
most: without it a pathological body buys a five-minute failover window and one hung leg stalls the
request. The non-streaming window stays 90 s, and `attemptSystemone`, which has no streaming path,
never sees this rule. `/admin/config` publishes `header_ms_stream`, `header_ms_stream_slope_per_kib`
and `header_ms_stream_max`, so the effective window is computable without reading the source.

**Rejected.** Raising the constant to 30 s: one line, but it only moves the cliff — 50k-token prompts
still cross it — while doubling the wait on a leg that is really dead. A per-provider table: more
config for a number that follows from body size, and it would need re-measuring per provider.

**The slope is a first cut.** 100 ms/KiB comes from one measurement at one prompt size on one
provider, chosen so the 200 KiB case lands near the measured p90 rather than to fit a curve. The
honest calibration is p50 and p90 at two prompt sizes; until that exists the slope is a named guess,
not a fitted constant, and the constant's comment says so.

**Consequences.** `a3` changed shape: A3b still proves the 15 s floor with a short body, and two new
steps prove the rule rather than a number — the same 17 s delay fails a short body and serves a
200 KiB one, on the same stub, so a pass cannot be the provider being faster. A retry or a failover
caused by a genuinely slow-but-alive long prompt is now a failure of this rule to be wide enough, not
of the provider. The cap means a 1 MiB prompt and an 8 MiB prompt get the same window; the 300 s
non-streaming total still bounds the request as a whole.

---

## DEC-23 — A header timeout cools for the header window it just waited, doubling to the 60 s cap

**Status:** accepted 2026-11-24; narrows the one flat cooldown in `DEC-8`/`DEC-10` for the
`header_timeout` class only.

**Context.** Every availability failure cooled a leg for 60 s regardless of class. That is right for
a refused connection or a `401`: those do not fix themselves in five seconds. It is wrong for a
header timeout, which is what a provider that accepted the request and then went quiet looks like.
Measured from the request log on qouver1, 2026-11-16 to 11-24 (32,340 lines): 590 requests carried
`header_timeout` and waited p50 19.5 s before giving up, 582 of them on `commandcode`; 455 were then
served by a fallback and 133 ended `502`. The damage was not those waits. With `sinarcloud` disabled
the chain is one leg, so while that leg was cooling `pickOrder` returned an empty list and the
caller got a `502` in 1–2 ms. Of 99 such instant `502`s, 90 fell within 90 s of a header timeout.
One blink therefore cost a full minute of downtime, and the request log recorded it as an anonymous
`502` with no failover reason.

**Decision.** `header_timeout` cools for the header window that failure just waited, clamped to
`[HeaderTimeoutCooldownS, AvailabilityCooldownS]` (5 s to 60 s), and each further header timeout in a
row without a served request doubles the rung inside the same clamp. `markServed` resets the ladder.
Every other availability class keeps its flat 60 s, and `quota_429`/`billing_402` keep 900 s; neither
reads the ladder. The same rule applies to the System One door, because it shares the reason tokens
and an operator reading one log should not have to learn two clocks. `/admin/config` publishes
`cooldowns.header_timeout_s` and `cooldowns.header_timeout_max_s`.

**The rung is measured in the door's own window, not in a constant.** The first version of this
decision used a flat 5 s first rung. Laras's release gate rejected it, and the code agrees: the
header window is 15 s on the streaming door but `HeaderDeadlineNonStreamMs` = 90 s on the
non-stream chat door and on `POST /v1/systemone` (`kori.nim:90`, `:3131`, `:3143`). A 5 s rung
therefore told the walk to re-probe a dead leg every five seconds and charge the next caller the
full 90 s each time: six back-to-back requests measured 180 s of stall with two of them, against
90 s with one under the old flat 60 s, and on the System One door a second request paid 90 s where
the old code served it in 1.6 ms. A rung shorter than the window it followed is a probe loop paid
for by callers, whatever the class means. `AttemptOutcome.headerWindowMs` now carries the deadline
that attempt actually waited and `startCooldown`/`startSystemoneCooldown` pass it in, so a 15 s door
gets 15, 30, 60 and a 90 s door gets the 60 s cap from the first failure. A window below the floor
still cools 5 s.

**Rejected.** A flat 5 s for every availability class: a dead socket or a revoked key would be
re-dialled twelve times a minute, which is a probe loop against a provider rather than a cooldown.
A flat 60 s as before: that is the bug this decision exists to fix, and it cost 90 of 99 instant
`502`s. A separate 5 s rung only on the streaming door: two ladders on one clock, and the non-stream
callers are the ones who can least afford a probe. A per-class config table: more surface for one
class that needed it, and the ladder is a property of what the class means, not of what this host
happens to run. Skipping the cooldown entirely for a header timeout and always probing: that is what
the ladder converges to anyway, but it puts the probe on every request instead of on one, so a
provider that is really down sees the full request rate.

**Consequences.** A leg that is really down reaches the same 60 s it had before, after one failure on
a door whose window is already a minute and after three on the streaming door. A leg that blinks
costs one request instead of a minute. A short cooldown means more dials against a dead leg than
before, and `legs[].retries` already bounds what one request may spend on that. The ladder is per
leg, in memory, and survives a config reload by leg name exactly as `coolingUntil` does; a restart
resets it, which is the same trade every other runtime counter here makes. `a22` proves all three
cases against a real binary: 15 s on the streaming door, the leg dialled again and serving once that
rung is over, and the 60 s cap on the 90 s non-stream door. The half-open latch (`probeInFlight`) is
taken after every skip that dials nothing, so a leg with a cooling key pool cannot leave it on.

## DEC-24 — Nagle is off on both ends of every upstream connection and on every accepted client

**Status:** accepted 2026-11-24.

**Context.** Neither `asynchttpserver` nor the OS default sets `TCP_NODELAY` here. A gateway request
head is a few hundred bytes written in a few writes, so Nagle's algorithm holds the tail until the
previous segment is acknowledged; with delayed ACK on the peer that is tens of milliseconds, before
the provider has been given anything to think about. Measured on qouver1: a full fresh handshake to
a provider costs about 59 ms (DNS 1.3, TCP 16, TLS 42). The 1 s door JEV pays 4.9% of its wall time
in that handshake, so a Nagle stall inside it is a larger share than it is on a 7 s chat completion.

**Decision.** `dial()` sets `OptNoDelay` on the upstream socket once the connection is up, which
covers the chat walk, the System One door and the OAuth token call because all three go through it.
`dispatch()` sets it on the accepted client socket, because `asynchttpserver` creates that socket
itself and offers no hook. Both calls ignore failure: the upstream socket is already connected and
usable by then, and a socket option that cannot be set is not a reason to cool a healthy leg for 60 s,
so it is caught inside `dial()` rather than escaping into the caller's `conn_refused` path.

**Rejected.** Building a custom listener to own the accept path: a second HTTP server implementation
to set one socket option. An nginx or Caddy setting instead: the binary must be bounded by its own
deadlines and its own socket options, independent of what a proxy in front of it does.

**Consequences.** Nothing about loopback correctness changes; the latency effect is only measurable
across a real network, so no acceptance case asserts a number. The client-side call is one syscall
per request on a keep-alive connection, which is microseconds against a completion measured in
seconds. Nagle's coalescing was never buying anything here: kori writes one head and one body, and
it uses no pipelined small writes on a connection it wants to be fast on.

## DEC-25 — jev is a System One leg on the plan that already pays for it, and never a chat leg

**Status:** accepted 2026-11-25.

**Context.** The OpenCode Go plan lists `jev-1.14` next to the chat models, so the question was
whether the decision model can ride the same subscription the gateway already uses instead of living
only on commandcode. Measured on qouver1 that day: `jev-1.14` answers `400 ModelProtocolUnsupported`
on `/inference/go/openai/v1/chat/completions` and on `/responses`, and answers `200` on
`/inference/go/systemone/v1/systemone` with the DEC-19 body, billed to the Go plan
(`"billing_source": "go"`, `cost: 0` on the call, input $0.042/M). The canonical id
`typesafe/jev-1.14.0` is refused there: "Model typesafe/jev-1.14.0 isn't included in OpenCode Go".
`/models` publishes exactly this split in each model's `api` block: a `decision` model carries
`systemone` and no `chat-completions`.

**Decision.** `jev-1.14` is a `systemone.legs[]` entry with
`base_url: "https://opencode.ai/inference/go/systemone/v1"`, the Go key as `api_key`, and the
`x-opencode-session` header the plan requires. It is ordered before `commandcode-jev`, which stays as
the fallback. No code changes: the door already rewrites `model` per leg and forwards the rest, which
is why the id can differ between the two hosts. kori never translates a chat request into a decision
call and never presents a decision model on `/v1/models` as a chat model.

**Rejected.** A protocol translator that serves jev through `/v1/chat/completions`: it would answer a
completion-shaped request with a choice distribution, and DEC-19 already refuses a third wire shape on
purpose. Also rejected: mapping the caller's `jev-latest` to the canonical id at the Go host, which
that host rejects.

**Consequences.** The decision door spends the Go subscription, so commandcode quota is no longer on
the critical path for group-chat routing. The failure classes stay DEC-19's: a `422` from the Go
gateway ("Upstream request failed: Endpoint is unavailable") is not in the dead-route list, so it
reaches the caller instead of failing over; that is a known gap, not addressed here.

## DEC-26 — The header window is config, a one-leg gateway skips for 15 s, and a failed walk says what it means

**Status:** accepted 2026-11-25.

**Context.** Three facts measured on qouver1 with the owner. First, of 103 requests since 16:24 WIB
86 answered `200` and 7 hit a header timeout on a prompt whose median size was 64k tokens; the
straight-line rule that already existed (base plus a per-KiB slope, capped) was never the reason a leg
was skipped — the numbers were, and they were compiled in. Second, with one leg enabled, a single
header timeout removed the only route for 60 s and the caller got `502 all_legs_cooling` labelled with
a leg that had not been dialled, at 0 ms. Third, an upstream `429` that names `Retry-After: 42` was
treated as a 900 s capacity failure, and a plain rate-limit `429` was a client error that never failed
over.

**Decision.** `timeouts.header_ms_stream_base`, `header_ms_stream_slope_per_kib`,
`header_ms_stream_max` and `header_ms_non_stream` are config keys with the current numbers as
defaults, validated (`0 < base <= max`, non-negative slope) and published under `timeouts` in
`/admin/config`. When every enabled leg is cooling the answer is `503 all_legs_cooling` with a
`Retry-After` header equal to the body's `retry_after_s` (the earliest expiry among the cooling legs,
never below 1 s), no leg name in the body, and `route: ""` in the log; zero enabled legs answers
`503 no_leg_enabled`, because "every leg is cooling" would be a lie about a config state. A gateway
with one enabled leg caps a header-timeout rung at 15 s: the rung only decides how long the caller is
told to wait, and the window's own floor is the smallest honest number. A quota `429` that names
`Retry-After` is believed, clamped to 60–900 s. A `429` that is not a quota becomes
`rate_limited_429` on a 5–120 s clock (30 s by default), fails over, and when the last leg still
answers `429` its own body and header reach the caller instead of a fabricated `502`.

**Rejected.** Raising the header deadline: the timeouts were provider stalls, not an undersized
budget, and the direct-dial first byte at 20/160/400 KiB was 0.9/3.8/4.7 s — inside the existing
window. Also rejected: keeping `502` for the all-cooling case (a `502` says a leg failed; nothing was
dialled), and a per-leg `Retry-After` in the body (it would name a leg to a caller who has no way to
choose one).

**Consequences.** Four more optional log keys (`prompt_kib`, `header_ms`, `legs_cooling`,
`retry_after_s`), all last, so the nine-key contract and old lines still hold. A client that retries
only `502` would stop retrying on `503`; that is a client fact, not a gateway one, and the plan's
Phase 9 gate is what decides whether it needs reverting (`408`-safe alternative: keep `502`, keep the
honest body and `Retry-After`).

## DEC-27 — The dashboard may switch providers and model aliases off, and that is the only write

**Status:** accepted 2026-11-25.

**Context.** Switching a provider off meant editing `/etc/kori/config.json` by hand and signalling the
process. The config file also holds every provider credential, so any write surface is a way to
rewrite a credential if it accepts more than it should, and the dashboard's read session is a 30-day
cookie — long enough that a stolen one must not be able to disable a leg.

**Decision.** The only mutation is `PUT /admin/overrides` with a body of
`{"legs":{name:bool}, "models":{alias:bool}, "confirm_last_leg":bool}`. A name that no leg or alias
has is a `400`. The block replaces the whole `overrides` block in `config.json`, applied by a textual
patch of that one top-level key, so no credential byte is ever re-serialised; the patched document is
validated by the same loader the process boots with before the file is replaced by temp-and-rename,
with one `config.json.bak` (0600, same volume, one generation) written first, and a size+mtime check
turns a concurrent hand edit or OAuth write-back into `409 config_changed`. The switch is applied in
memory immediately (only a boolean changes; no leg index moves) and a reload is requested so the file
and the process converge at the next quiet moment.

Writes have their own credential: `KORI_ADMIN_WRITE_TOKEN_FILE` (default
`/etc/kori/admin-write.token`), constant-time compared, and a host without that file answers the same
`404` the read gate answers without a token. A read token on this endpoint is `403
write_scope_required`. A session minted from the write token lives 12 h, stores its scope and a
fingerprint of the token that minted it, so rotating the token invalidates it, and a cookie write must
also carry `X-Kori-Write: 1` — a header a cross-site form cannot set. A bearer write needs no such
header. Refusing to switch the last serving provider off is `409 last_leg` unless the body says
`confirm_last_leg: true`.

**Amended 2026-11-25.** The write token is a superset of the read one, so it is accepted as a bearer on
every read GET (`/admin/state`, `/admin/config`, `/admin/log`) as well as on `PUT /admin/overrides`.
The first cut of the gate compared a bearer only against the read token, which answered `401` to a
script holding the write token even though the same credential could mint a write session and read
every page with it (and §6.5 of the plan already said "read endpoints with a write token: allowed").
That was an inconsistency, not a boundary: nothing gets wider, because the same caller could already
read through the cookie. The read token stays read-only, and a bearer of neither token is still
`401`.

**Rejected.** A general config editor, `PATCH` on arbitrary keys, and accepting credentials or
timeouts through the same door: each widens what a compromised process can rewrite. Also rejected:
waiting for `inFlight == 0` before applying a boolean.

**Consequences.** `config.json` and its directory must be writable by the gateway's uid (already true
in the container template, `:rw,Z`, uid 10001). Every write writes a `.bak`, so a second copy of the
credentials exists on the same protected volume — accepted, one generation only, and Galih's review
(Phase 8) is what signs off on it. `state.admin_writes` and a stderr line record that a write
happened, never what the token was.

## DEC-28 — `systemone_balance` gives the System One door the chat door's weighted pick

**Status:** accepted 2026-11-25.

**Context.** DEC-19 made `systemone.legs` a fallback chain walked in config order, and deliberately not
a load balancer. That was written when jev had one usable endpoint. Since 2026-11-25 the gateway runs on
two plans that both serve jev (`opencode-go` and `commandcode`, DEC-25) and the chat door splits traffic
between them 1:1, so jev traffic — the highest-volume caller kori has — piled onto the first leg while
the second sat idle until a failure. The owner asked for the System One door to be able to split its
traffic the same way.

**Decision.** A top-level `systemone_balance` (boolean, default **false**) turns the split on.
`systemone.legs[].weight` is a 1-1000 share with the same default (1) and the same refusal of 0 as a
chat leg. When `systemone_balance` is true, the first pick is the chat door's smooth weighted
round-robin over the enabled System One legs that are not cooling; the rest of the walk stays config
order, so failover is still deterministic and the second leg is still the one that answers when the
first dies. When it is false — the default, and what every config written before this key says — the
walk is exactly what DEC-19 wrote and the weight is inert. A cooling or disabled leg leaves the pool;
one eligible leg is always the pick.

**Rejected.** Reusing the chat door's `balance`: one switch for two doors means an operator who turns
on chat balancing silently re-orders the decision door, which is the kind of coupling that makes an
incident hard to reason about. Two switches with one default (off) keep DEC-19 the default on both
doors. Also rejected a weighted pick per dial rather than per request: a decision request is one call,
and a per-dial pick would move the model id mid-request.

**Consequences.** `/admin/config` reports `systemone_balance` and the `weight` of each System One leg,
like a chat leg. The SWRR state lives in memory per leg and resets on restart, which is harmless at this
volume. `systemone_balance: true` with `systemone` absent changes nothing, because there is no door to
balance.
