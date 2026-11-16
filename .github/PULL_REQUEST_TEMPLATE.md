## What this changes

<!-- One paragraph. What changed and why. Link the issue or the spec section if there is one. -->

## Checks run

- [ ] `./task ops` — result:
- [ ] `./task nim` — result:
- [ ] `./task web` (if `apps/web/` changed) — result:
- [ ] `./ops/scripts/contract-check.sh .` — violations:
- [ ] `gitleaks git --redact --no-banner .` — clean
- [ ] dependency scan for the ecosystem touched (`npm audit --audit-level=high` for `apps/web`)
- [ ] acceptance suite, when routing, fallback, log or the admin surface changed:
      `KORI_BIN=./apps/api/src/kori sh acceptance/run-all.sh`

## Scope

- [ ] One commit, one reason
- [ ] No new dependency, or the reason it is worth one:
- [ ] Docs updated in this change if behaviour changed
- [ ] Nothing in the diff carries a credential, token, `.env` file or connection string

## Handoff

```
STATE:
ARTIFACT:
DONE WHEN:
OPEN:
```
