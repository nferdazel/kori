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
`run-all.sh` as the ten end-to-end cases. Both are driven by `KORI_BIN` and nothing else.
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

## DEC-6 — The request log is append-only, one line, nine keys

**Status:** accepted.

**Context.** The claim this gateway has to make checkable is "how many failovers, when, on
which route". That claim is only as strong as the log behind it.

**Decision.** One line per request, appended with a single write, never rewritten and never
rotated in v1. The keys are fixed and ordered: `ts`, `route`, `status`, `latency_ms`,
`tokens_in`, `tokens_out`, `failover_from`, `failover_reason`, `stream`.

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

**Status:** accepted.

**Context.** Weighted splitting across primaries is a feature with a real cost: the split has
to be defined, observable and testable.

**Decision.** `weight` must be `1`. Any other value is refused at startup with exit `2`.
`balance` defaults to `false`, which keeps strict config order.

**Consequences.** A config never asks for a split the binary cannot honour. Turning on
balancing is one boolean and it is round-robin, not weighted, so there is nothing to explain
when the traffic does not land where someone expected.
