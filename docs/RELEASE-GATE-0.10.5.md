# Release gate — kori 0.10.5 (phase 9)

**Verdict: PASS for the seven local commits under gate.** Three findings do not change that
verdict: the changelog does not describe the release (blocks the tag, not the merge), one
banner the plan specifies was never built, and one 405 branch has no case. Nothing was
pushed, tagged, deployed or committed by this gate.

- Repo: `/Users/sachiel/Projects/kori`, branch `main`. The seven commits were gated at
  `f8c6aca`. Mid-gate, `990154a` (Galih's phase 8 clearance, `docs/SECURITY-CLEARANCE-DEC27.md`,
  docs only, +221 lines and no other file) landed on `main`; items 1, 6 and 9 were re-run at
  that HEAD and are recorded here at it. A docs-only commit does not change the web build or
  the binary, so items 2, 3, 4, 5, 8 and 10 stand as measured at `f8c6aca`, where the code is
  byte-identical to `990154a`.
- Range: `c078130..990154a` (eight commits) on top of `origin/main 311f5d9`.
- Version: `0.10.4` — the 0.10.5 bump has not been cut, so this report is named for the
  release it gates, not for the number the tree carries today.
- Gate owner: Laras (QA). Date: 2026-11-25. Each item states the revision its commands ran on;
  the output quoted is the output they produced.
- Artifacts (raw logs, client probe): `~/.openmausbot/workloop/items/kori/2026-11-25-release-gate-0.10.5/`

| # | Item | Verdict |
| --- | --- | --- |
| 1 | `./task version-check` | PASS |
| 2 | `./task web` (committed dist current) | PASS |
| 3 | `./task nim` (check, unit tests, 25 cases) | PASS |
| 4 | `acceptance/a25-rollback.sh` standalone | PASS |
| 5 | a23 / a24 / a25 (phases 4, 6, 7) | PASS |
| 6 | Nothing pushed, no branch, no PR | PASS |
| 7 | Client retry on all-cooling (plan risk 2) | PASS for opencode, unverified for jev |
| 8 | Stale audit items stay closed | PASS |
| 9 | `./task gate` (golden contract, shell, secret scan, ops dry runs) | PASS |
| 10 | Phase 5/7 interface in a real browser | PASS, one specified element missing |

---

## 1. `./task version-check` — PASS

```
$ cd ~/Projects/kori && ./task version-check
version: v0.10.4 (VERSION, kori.nimble, generated module, CHANGELOG agree)
EXIT=0
```

VERSION, `kori.nimble`, the generated module and CHANGELOG agree. They agree on `0.10.4`,
which is the number before the release bump; nothing about the seven commits changes it.

## 2. `./task web` — PASS

```
$ ./task web
$ tsc --noEmit && vite build
✓ 19 modules transformed
dist/assets/main-Oj5NtS4z.js   38.24 kB │ gzip: 12.96 kB
✓ built in 50ms
EXIT=0
$ git status --short
(empty)
```

The target rebuilds `apps/web/dist` and then fails if the committed copy differs. It exited
0 and the working tree stayed clean, so the committed dist is the one the source produces,
and `nim c` will embed that.

## 3. `./task nim` — PASS (25 of 25 cases)

```
$ ./task nim
version: v0.10.4 (...)
gen-static: 12 files embedded from apps/web/dist into apps/api/src/generated/static_files.nim
... nimble test ...                                    103 passed, 0 failed
========== a1-failover ... a25-rollback ==========
25 of 25 cases green
EXIT=0
```

- `nim check --hints:off apps/api/src/kori.nim`: no errors (the target stops here if there are).
- `nimble test -y`: `103 passed, 0 failed`.
- `acceptance/run-all.sh` against the freshly built binary: 25 cases, **857 assertions, 0
  failed**; with the 103 unit assertions the run is 960 assertions, none red.
- `gen-static` embedded 12 files and `git diff --quiet` on the generated module passed, so
  the committed `static_files.nim` matches the committed dist.

Per case (assertions): a1 46, a2 32, a3 26, a4 31, a5 39, a6 47, a7 37, a8 17, a9 20,
a10 79, a11 80, a12 25, a13 52, a14 27, a15 36, a16 59, a17 22, a18 11, a19 14, a20 21,
a21 32, a22 17, a23 26, a24 48, a25 13.

## 4. `acceptance/a25-rollback.sh` standalone — PASS

```
$ KORI_BIN=./apps/api/src/kori sh acceptance/a25-rollback.sh
PASS  A25 the .bak is the pre-write bytes
...
13 passed, 0 failed
EXIT=0
```

## 5. The phase 4 / 6 / 7 cases, run one at a time — PASS

```
$ KORI_BIN=./apps/api/src/kori sh acceptance/a23-honest-cooling.sh
PASS  A23c the rate-limited leg cools its 7 s Retry-After :: 7 in [6, 7]
26 passed, 0 failed                                            EXIT=0

$ KORI_BIN=./apps/api/src/kori sh acceptance/a24-admin-overrides.sh
PASS  A24g a host with no write token answers 404, not 403
48 passed, 0 failed                                            EXIT=0

$ KORI_BIN=./apps/api/src/kori sh acceptance/a25-rollback.sh
PASS  A25 the file is still 0600
13 passed, 0 failed                                            EXIT=0
```

What those three cases actually pin, in the words of their assertions:

- A23a: one leg, a header timeout — first request `502 all_legs_failed`, second `503
  all_legs_cooling`, `Retry-After` 1–6 s equal to `retry_after_s` in the body, no leg name
  in the body, log `route: ""`, `legs_cooling: 1`, `latency_ms < 100` (nothing dialled),
  and the leg serves again after the rung.
- A23b: two cooling legs — `Retry-After` is the earlier expiry (1–6 s), the quota leg cools
  58–60 s rather than 900 s, the header-timeout leg cools its 5 s rung.
- A23c: a plain 429 fails over to the next leg and cools for the `Retry-After` it named
  (6–7 s), with `failover_reason: rate_limited_429`.
- A24a–A24g: no credential `401`, read token `403`, write token `200`, last serving leg
  `409` without `confirm_last_leg` and `200` with it, cookie write without `X-Kori-Write`
  `403`, write session 12 h, override survives a restart, no write token file `404`.
- A25: switches leg-b off, `.bak` is the pre-write bytes at 0600, restore + SIGHUP moves
  `reload.count`, `started_at` unchanged (no restart), override gone from both the running
  config and the file, file still 0600.

## 6. Nothing was pushed — PASS

```
$ git -C ~/Projects/kori log origin/main..main --oneline | wc -l
9
$ git status --short
(empty)
$ git tag --points-at HEAD
(none)   # git describe: v0.10.4-9-g990154a
```

Nine commits ahead of `origin/main` (`311f5d9`): `c078130` (the DEC-25 docs commit that
predates this work), the seven named in the brief, and `990154a` (the phase 8 clearance that
landed while this gate was running). No new branch, no PR, no tag on this HEAD, working tree
clean at the start and end of the gate. The only change this gate made to the tree is this
untracked file.

## 7. Client retry on all-cooling (plan risk 2) — PASS for opencode, jev unverified

I ran the real client against a loopback endpoint that answers like an all-cooling kori.
Details and raw logs: `CLIENT-RETRY-PROBE.md` in the artifact folder.

| Answer | Requests the client made | Gaps |
| --- | --- | --- |
| `503` + `Retry-After: 15` | 12 | 15.03 s × 11, then `Error: all_legs_cooling` |
| `503`, no `Retry-After` | 12 | 2.42 → 11.74 s, jittered backoff |
| `502` + `Retry-After: 15` | 12 | 15.03 s × 11 (identical to the 503 run) |

- **It retries `503`.** opencode v2.4.1 treats 502 and 503 identically, so the `503` default
  stands and the code does not go back to 502.
- **It honours `Retry-After`**, which is why the header is worth sending.
- **The caller waits ~150 s** before the error, because it makes eleven of those waits.
- **jev is not verified.** It is not installed here and its retry policy is not readable on
  this machine. If jev turns out to retry only `502`, that is a jev fact and would be
  handled on the client or by a decision — the gateway should not answer dishonestly for it.

## 8. The two stale audit items stay closed — PASS

1. **`/admin/*` is no longer GET-only.** `apps/api/src/kori.nim:5331` dispatches
   `PUT /admin/overrides` before the `startsWith("/admin/")` read branch, and every other
   method on that path is refused with `Allow: PUT`. Measured on a live gateway built from
   this tree:

   ```
   $ curl -sS -D- -o /dev/null http://127.0.0.1:18077/admin/overrides
   HTTP/1.1 405 Method Not Allowed
   allow: PUT
   $ curl -sS -D- -o /dev/null -X POST http://127.0.0.1:18077/admin/state
   HTTP/1.1 405 Method Not Allowed
   allow: GET
   ```

2. **`respondMethodNotAllowed` sets `Allow`.** `kori.nim:4469` writes `headers["Allow"]`
   before the body, and `acceptance/a10-admin.sh:105` asserts `Allow: GET` for a refused
   POST on the admin reads, `a13-parity.sh:68` asserts `Allow: POST` on `/v1/models`, and
   `a15-systemone.sh:174` asserts the `/v1/systemone` 405 — all green in this run.

## 9. `./task gate` — PASS

Run twice: at `f8c6aca`, and again at `990154a` after the docs-only clearance commit landed
while this gate was running. Both exited 0 with the same result.

```
$ ./task gate
== gate: golden CI/CD contract           OK
== gate: secret scan
   gitleaks clean (311f5d92316488711fc3707fc3e9a58e1d077246..HEAD)
== gate: shell syntax, ops dry runs      RESULT: all scenarios passed (6 groups)
   gate ok
EXIT=0
```

Dependency and secret posture for the diff: gitleaks is clean over everything on `main` above
`origin/main` (nine commits), and `git diff --name-only 311f5d9..HEAD` adds no `.env`, key,
credential or pem file. No CVE
scanner runs for Nim in this repo (`task gate` says so out loud); the third-party surface
in the diff is `apps/web`, and `./task audit` was not re-run by this gate.

## 10. Phase 5 and 7 in a real browser — PASS, one specified element missing

A local gateway on `127.0.0.1:18090` with two live stubs, a read token and a write token,
and a log of 400 seeded rows. Checked in the built-in browser, not read off the diff.

- **Phase 5, latency by prompt size.** The Overview table renders five buckets with n, p50,
  p90, p99. The buckets my seeded data did not fill show `-`, not a zero, and the filled
  ones match the math I put in the file (`<32 KiB`: n 200, p50 1679 ms, p90 2799 ms,
  p99 3051 ms).
- **Phase 7, the switch.** Unchecking `leg-b` produced `leg-b: applied, reload queued` and
  an `OVERRIDE` badge with `file on · not serving · override off`; the override landed in
  the config file, `config.json.bak` appeared at 0600, `reload.count` went 0 → 1 and
  `started_at` did not move, so there was no restart. A request then went to `leg-a` and
  answered 200.
- **Last-leg gate.** Unchecking the last serving leg raised "Turn off the last serving
  provider?" with `Cancel` and `Turn it off anyway`. `Cancel` left the leg serving and said
  so; `Turn it off anyway` wrote both legs off, and the next request answered
  `503 no_leg_enabled` with no `Retry-After` (correct: that is a config state, not a wait)
  and one log row `route: "", failover_reason: "no_leg_enabled"`.
- **Keyboard.** `Space` on the focused checkbox opened the dialog, `Escape` cancelled it,
  focus stayed on the row. The switch is a native checkbox with a wired label.

**Finding (low, phase 7 spec, not one of the six items):** plan §6.6 asks for "a banner when
no leg is enabled: *No provider is serving; every request answers 503.*". That string does
not exist in `apps/web/src`, and with both legs switched off the Overview showed only the
503 rows in the request tape — no banner. The reload chip from the same section also exists
only as the status line (`reload queued`), not as a chip. The dialog, the badge and the
honest 503 all work; the banner does not exist.

---

## Other findings

**F1 — the CHANGELOG does not describe this release (blocks the tag, not the merge).**
`CHANGELOG.md` has exactly one entry under `## [Unreleased]`, and it is the DEC-25
`config.json.example` change from `c078130`. None of the seven commits (the log keys, the
configurable header window, the honest cooling, the 429 classes, the admin write surface,
the latency buckets, the provider switches) is recorded. `./task release` moves that
`Unreleased` section into the new version, so tagging 0.10.5 today would publish release
notes that do not mention the release. `docs/DECISIONS.md` (DEC-26, DEC-27) and
`docs/ARCHITECTURE.md` are updated, so this is a changelog gap, not a documentation gap.

**F2 — `GET /admin/overrides` → `405 Allow: PUT` has no case in the a-series.** Every other
405 has one (a10f, a13a, a15). I verified the branch by hand against a live gateway (section
8); it is correct today, and it will stay correct only until someone edits the dispatch
chain. Cheap to close: one assertion in a24.

## What remains unverified

- **jev's retry policy.** Only opencode was exercised (section 7).
- **Streaming callers.** A client that already received a first byte is a different path in
  every client; the probe used non-streaming only.
- **The dashboard at 360 px and with a screen reader.** The browser pass checked layout and
  keyboard, not a real assistive technology or a phone viewport.
- **Production behaviour.** Nothing was deployed: no build on qouver1, no container swap, no
  config on the host touched. The 48 h latency table that phase 2 wanted is not part of this
  gate either, and the header numbers still sit at their provisional values
  (`15000 + 100/KiB`, max 60000), which is why `/admin/config` prints them as the rule.
