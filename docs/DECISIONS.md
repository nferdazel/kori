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
