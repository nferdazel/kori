# Security clearance — kori 0.10.4, phase 8 (DEC-27)

**Verdict: PASS for the seven local commits. PASS WITH CONDITIONS before this surface is deployed.**

- Range reviewed: `c078130..f8c6aca` (7 commits) on `main`, working tree clean, nothing pushed.
- Repo: `/Users/sachiel/Projects/kori`. Version: v0.10.4 (`./task version-check`).
- Reviewer: Galih (Security Engineer). Date: 2026-11-25.
- The five questions below are answered PASS/FAIL with the evidence I executed or the exact
  lines I read. Nothing in this file was inferred from the commit messages.

## Method

Executed on the checkout at `f8c6aca`, binary rebuilt from that source:

| Command | Result |
| --- | --- |
| `./task version-check` | `version: v0.10.4 (VERSION, kori.nimble, generated module, CHANGELOG agree)` |
| `nim check --hints:off apps/api/src/kori.nim` | no errors |
| `nim c -d:release --mm:orc --threads:on --hints:off -o:apps/api/src/kori apps/api/src/kori.nim` | binary rebuilt from a clean tree |
| `nimble test -y` | `all checks passed` |
| `KORI_BIN=./apps/api/src/kori sh acceptance/a24-admin-overrides.sh` | `48 passed, 0 failed` |
| `KORI_BIN=./apps/api/src/kori sh acceptance/a25-rollback.sh` | `13 passed, 0 failed` |
| Ad-hoc rotation/scope proof (case R1–R4, harness copied to a temp dir, not committed) | `21 passed, 0 failed` |
| Ad-hoc cross-site-form proof (case C1–C3, temp dir, not committed) | `7 passed, 0 failed` |
| `gitleaks detect --source . --log-opts="c078130..HEAD" --redact` | `7 commits scanned`, `no leaks found` |

No dependency manifest (`package.json`, `pnpm-lock*`, `*.nimble`) changed in the range, so this
diff adds no dependency surface; `pnpm audit` was not run for that reason.

## 1. Scope separation — PASS

**Claim checked:** a read credential on `PUT /admin/overrides` is 403 and never causes a partial write.

- `adminWriteGate` — `apps/api/src/kori.nim:4743-4771`. A valid read bearer reaches
  `return awForbidden` at `4763-4767`; a live read cookie reaches `awForbidden` at `4768-4770`.
  Only the write token as bearer (`4760-4762`) or a write-scoped session with a matching token
  fingerprint (`4753-4759`) returns `awOk`.
- The handler maps `awForbidden` to `403 write_scope_required` **before** reading the body:
  `4973-4978` (gate) precedes `4980` (body cap), `4984-4992` (parse), and any file access
  (`5069` onward). There is one write path, after every gate.
- Route: only `PUT` reaches the handler; anything else is `405 Allow: PUT`
  (`5331-5337`). The route match is exact, so no path suffix reaches it.
- Runtime: R1 sends the read bearer with `{"legs":{"leg-b":false}}` and gets `403`
  `write_scope_required`, and `cmp` shows the config file byte-identical afterwards. R3 sends a
  **read session cookie** plus `X-Kori-Write: 1` and still gets `403 write_scope_required`.
  A24a/A24f repeat the bearer and cookie cases: `48 passed, 0 failed`.
- Note, not a bypass: when the operator points both token files at the same value, the received
  value is treated as the write credential (`5197-5206`) and therefore also opens the read
  surface. That is a credential the operator deliberately configured for writing; it is
  documented in the code comment, not an escalation.

## 2. CSRF — PASS

**Claim checked:** cookie-authenticated writes require `X-Kori-Write: 1`; a bearer write does not;
a cross-site form cannot reach the endpoint.

- Cookie path: `session.scope == asWrite` and `session.tokenHash == hash(token)` (`4753-4756`)
  then `headerIs(request, "X-Kori-Write", "1")`; missing header returns `awCsrf` (`4757-4759`),
  answered as `403 csrf_header_required` (`4977`, body at `4962-4963`). Exact header match,
  case-insensitive name, `4735-4741`.
- Bearer path: `4760-4762` returns `awOk` with no header check; A24a proves a bearer write with
  no `X-Kori-Write` is `200`.
- Cross-site form reachability: **no.** (a) HTML forms only issue GET/POST, and the route answers
  `405` to both; (b) a cross-origin `fetch` with `PUT` is not a simple request and the response
  carries no `Access-Control-Allow-Origin` (C2: preflight `405`, no CORS headers; a grep of the
  source finds no CORS header code at all); (c) the session cookie is
  `HttpOnly; Secure; SameSite=Strict` (`4822-4824`), so it is not sent on a cross-site request;
  (d) a form's three enctypes cannot produce the JSON object body `parseJson` requires
  (`4984-4992`).
- Runtime: C1 posts a form-encoded body to the endpoint → `405`, no CORS header, config file
  still has no `overrides` key. C2 `OPTIONS` → `405`, no CORS headers. R4 cookie write without
  the header → `403 csrf_header_required`; with it → `200`.

## 3. Session invalidation — PASS

**Claim checked:** `AdminSession` stores scope plus `hash(token)`; rotating the write token
invalidates existing write sessions; the TTL is 12 h.

- Shape: `AdminSession` has `expiresAt`, `scope`, `tokenHash` (`414-420`); the table is
  `gateway.sessions` (`480`), memory only, emptied by a restart.
- TTL: `AdminWriteSessionTtlS = 43_200.0` (`177`), selected per scope in `startSession`
  (`4817-4819`), and written into the cookie as `Max-Age` in the login handler (`5218-5219`).
  The read session keeps its 30-day `AdminSessionTtlS` (`185`).
- Binding and rotation: the login hashes the token that actually matched
  (`startSession(gateway, scope, hash(matchedToken))`, `5212`). The gate recomputes
  `hash(token.get)` from the file **on every request** (`readAdminWriteToken` at `4717-4733`,
  compare at `4755-4756`), so a rotated file no longer matches an old session; the session then
  falls through to the live-cookie branch and is refused `403` (`4768-4770`).
- Runtime: R4 logs in with the write token (`204`, `Max-Age=43200`), writes with the cookie
  (`200`), replaces the token file, then the same cookie gets `403`, the old bearer gets `401`,
  the new bearer gets `200`, and a read session still reads `200`. A24f asserts the 12 h
  `Max-Age`; A24g shows a restart keeps the file's override and loses only the sessions.
- Info, not a finding: `Hash` is a 64-bit stdlib fingerprint, not a password hash. It is never
  persisted or rendered, and only equality inside one process matters, so its weakness is not
  reachable; a memory compromise already hands out the token file anyway.

## 4. Secret never rendered — PASS

**Claim checked:** the write response, the log line, and `/admin/config` never contain a
credential or the token.

- Write response: built only from `written/applied/reload_requested`, a server timestamp, and
  the request's own `legs`/`models` maps after each name was validated against the config
  (`5042-5051`, response `5149-5164`). No config value, no token, no header.
- stderr line for a write: counts only, `"admin overrides written, N leg(s), M model(s)"`
  (`5146-5147`). The kept-artefact run shows exactly those three lines in `gateway.log`, with
  no token and no `api_key`.
- Request log: `requestLogLine` takes fixed parameters only (`1087-1129`) — route, status,
  latency, token counts, failover fields, stream, alias, effort, cost, `prompt_kib`,
  `header_ms`, `legs_cooling`, `retry_after_s`. No header, body, or credential is a parameter
  ("redaction is structural", `1098-1099`). The admin write has no request-log call site at
  all; the only two callers are the chat paths (`3428`, `3770`). The kept run's request log had
  0 lines because no chat traffic was sent — the claim rests on the call graph plus A24d's
  assertion that a chat line still carries no leg key.
- `/admin/config`: `configJson` at `4179-4357`. `base_url` goes through `redactUrl`
  (`4029-4044`, applied `4204` and `4343`); headers are printed by **name** only
  (`4217-4220`); keys by count and cooling count (`4221-4229`); credential as
  `state/source/ref` where `ref` is a file path or `<path>:<line>` (`4230-4243`,
  `credentialRefs` at `4045-4058`); OAuth as state + expiry (`4246-4253`); overrides as the
  boolean maps plus `updated_at` (`4308-4323`); `admin_writes` as counters and a timestamp
  (`4325-4331`). No token field exists in the function.
- Runtime: R2 plants a sentinel `api_key` in the config, then asserts the write response and
  `/admin/config` never contain it and never contain the write token:
  `21 passed, 0 failed`. A24a makes the same two assertions on the response.

## 5. Writable config threat — PASS, accepted with conditions

**Claim checked:** only the top-level `overrides` key is patched by text, credentials are never
re-serialised, the patched document is validated by `loadConfigText`, one `config.json.bak` at
0600, a size+mtime race gives 409, and a compromised process could still rewrite the file
through the same primitive.

- The patch is confined to one value: `overridesSpan` only accepts a key at depth 1
  (`4896-4937`, depth test `4919`), string-aware, and `patchOverridesText` splices that span
  (`4947-4957`). Everything else is copied byte-for-byte; unit checks
  "the patch keeps every credential byte" and "a second patch replaces the block instead of
  adding one" pass, and A24b asserts `.legs[0].api_key` is still the sentinel after a write.
- The body cannot name anything else: unknown top-level keys are 400 (`4997-5028`), every value
  must be a boolean (`5000-5024`), every `legs` name must exist (`5032-5041`), every `models`
  name must be an alias on some leg (`5042-5051`). No credential, URL, timeout or header can be
  written through it. The last-leg guard is a 409 unless `confirm_last_leg: true`
  (`5053-5063`).
- The patched text is parsed and validated by the boot loader before any file is touched:
  `loadConfigText(patched, ...)` at `5099`, loader at `647`, `overrides` schema at `932-980`.
  A failure returns 500 and writes nothing (`5098-5103`).
- Atomicity: `writeFileAtomic` opens `<path>.tmp` 0600, fsyncs, renames over the target
  (`2409-2435`, mode `2413`); the `.bak` is written first with the same primitive from the
  bytes read at `5069-5071` (`5121-5126`), then the config (`5127-5130`). No `await` sits
  between the read and the two writes, so another request on the single event loop cannot
  interleave.
- Race: size and mtime are captured before the patch (`5076-5081`) and re-checked after
  validation (`5104-5119`); a mismatch is `409 config_changed`. This narrows the window, it is
  not a lock: an external writer that replaces the file with the same size and preserves mtime
  (e.g. `cp -p`) could slip through. Such a writer can already write the config file.
- Judgement on `.bak`: **I accept it, one generation, same volume, 0600.** It is the same bytes
  already present in `config.json`, in the same directory, readable by the same uid; it adds one
  inode, not a new reader. The real widening is that a credential removed or rotated by hand
  survives in `.bak` until the next admin write. That is a procedure condition, not a reason to
  block the local commit.
- This surface is **narrower than a config editor**: the request vocabulary is two
  `name -> bool` maps plus one bool; the sink is one top-level key; the document is validated by
  the same loader that boots the process; and nothing read through the API ever renders a
  secret. A config editor would accept keys, URLs and credentials, which this cannot.
- A same-uid process can read the token file and call the endpoint, but it can already rewrite
  `config.json` directly; the endpoint does not raise the local-compromise ceiling. What a
  stolen write token buys an outsider is DoS (including the explicit full-outage confirm),
  not credential disclosure and not redirection: `base_url` and `api_key` are not writable.

### Conditions (before deploying this surface to qouver1)

1. RUNBOOK: state that `config.json.bak` holds every credential at 0600 on the same volume, and
   that rotating or removing a provider credential includes removing/refreshing that `.bak`.
   The rollback step stays `cp .bak config.json && chmod 600 config.json && SIGHUP` (rehearsed
   in A25).
2. Deployment check: confirm on qouver1 that the config directory is writable only by the
   gateway uid and that the `.bak` this code creates lands 0600 there. A24/A25 prove the code,
   not the deployment.

Neither condition blocks the seven local commits.

## Observations outside the five questions

- **OBS-1 (pre-existing, not this diff):** `redactUrl` (`4029-4044`) strips a sensitive query
  string but not URL userinfo. A `base_url` written as `https://user:pass@host/v1` would be
  printed unchanged by `/admin/config`. No config in this range does that, and
  `redactUrl` is untouched by the diff. Worth a follow-up: strip userinfo, or print only
  scheme+host+path.
- **OBS-2:** admin writes have no request-log row. The durable trail is `overrides.updated_at`
  in the file, the in-memory `admin_writes` counters, and one stderr line. Adequate for a
  single-operator host; it is not a tamper-evident audit log.
- **OBS-3:** the endpoint has no failed-attempt rate limit. The credential is high-entropy, the
  compare is constant-time (`4630-4641`), and a correct token is never refused by the login
  window (`5197-5222` before `5225`), so there is no lockout path to abuse.
- **OBS-4:** because `overrides` is validated against the legs and aliases, removing or
  renaming a leg/alias while an override for it remains makes the whole config fail to load on
  the next start (fail-closed). Removing an override first is the safe order; the RUNBOOK should
  say so.
- **OBS-5:** `writeFileAtomic` uses a fixed `.tmp` name without `O_EXCL`/`O_NOFOLLOW`. An actor
  who can create a symlink in the config directory could redirect the write, but that actor can
  already rewrite the config file; not a new privilege. Info only.
- **OBS-6:** a read session still lives 30 days and a rotated read token does not invalidate it
  (DEC-20/21, unchanged). It cannot write: scope and token fingerprint are checked, and R3
  proves a read cookie gets 403 even with the CSRF header.

## What I checked, and what I did not

**Checked by execution:** version consistency; `nim check`; release build from a clean tree;
unit tests; A24 (48 assertions) and A25 (13); a read-token refusal with byte-identical config
afterwards; a read-cookie refusal; a write-cookie success; token rotation invalidating a live
write session; secret absence in the write response, `/admin/config`, and `gateway.log`; a
cross-site form POST/OPTIONS against the endpoint; gitleaks over the seven commits.

**Checked by reading only:** the size+mtime 409 race (not raced in practice); the absence of a
partial-write path (traced, and the refusal paths are proven by cmp/R1); CORS absence (code
grep plus the OPTIONS response); the `.bak` mode on a deployed volume (only proven on this
machine's filesystem).

**Not checked:** qouver1, the container mount, Caddy, DNS or any production surface; no
load/DoS test; no `pnpm audit` (no manifest changed); no review of the dashboard's frontend
code beyond the write client (`apps/web/src/api.ts:156-172`), which sends the full override map
and always sets `X-Kori-Write`.
