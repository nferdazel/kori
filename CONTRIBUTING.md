# Contributing to kori

kori is a small repo with a strict gate. The rules below are the ones CI enforces, so a
local run and a red build mean the same thing.

## Before anything is called done

Run these from the repo root and read the result:

```sh
./task ops     # shellcheck plus the deploy/smoke/preflight dry runs
./task nim     # nim check, nimble test, embed drift, release build, acceptance self-test
./task check   # both of the above plus the dashboard build
```

`./task nim` builds the binary and runs the acceptance self-test, 92 checks:

```sh
KORI_BIN=./apps/api/src/kori sh acceptance/selftest.sh
```

The ten-case suite (A1 to A10) is a separate command, and it is what the Nim job in CI
runs after the release build:

```sh
KORI_BIN=./apps/api/src/kori sh acceptance/run-all.sh
```

House contract check, from the repo root:

```sh
./ops/scripts/contract-check.sh .
```

Pass the repo as the argument. Without an argument the script scans every git repo under
`~/Projects` and reports their violations as well.

## Security gate

This repository is public. A leaked token is public the moment it is pushed.

Before every commit, push and pull request:

- Run `gitleaks git --redact --no-banner .` over the history, not just the diff.
- Scan the dependencies you touched: `npm audit --audit-level=high` for `apps/web`, and
  `nimble` dependency review for the binary.
- Check the diff for `.env` files, connection strings, tokens, keys and credentials. The
  real environment file lives on the host only; `ops/env/*.env.example` is a template.
- Never commit `kori.json`. It holds every provider credential.

CI runs the same scan in the `Security` job over the full history.

## Commits

- One local commit per slice. A slice is one change with one reason, not a day of work.
- Conventional Commits: `feat(api): …`, `fix(ops): …`, `docs: …`, `ci(nim): …`,
  `test(acceptance): …`. Scope is the directory or component touched.
- English commit messages, English identifiers, English comments. Prose in `docs/` may be
  Indonesian; anything a user or an outside reader sees stays English.
- Do not push without the lead's go. A push to `main` publishes the image and fires the
  deploy path.

## Code

- Match the style around you. Smallest change that solves the problem.
- No new dependency unless it removes more complexity than it adds.
- The request log line has nine keys in a fixed order. Adding a key is a spec change, not a
  local edit.
- The dashboard is committed as `apps/web/dist`, and the embedded module
  `apps/api/src/generated/static_files.nim` is committed too. If you change one, regenerate
  the other with `tools/gen-static.sh`. CI fails on drift.
- Do not edit `apps/api/src/generated/static_files.nim` by hand.

## Documentation

- Document a command only after you have run it.
- A wrong doc is worse than no doc. Delete a stale one in the same change that makes it
  stale.
- Mark anything unverified as unverified.

## Handoff

Every handoff is four lines, no prose around them:

```
STATE:     which step this is
ARTIFACT:  commit sha, file paths, report path
DONE WHEN: the checks that were run, with their numbers
OPEN:      what is not verified and who holds it
```

## Pull requests

Fill in the template. A pull request that cannot name the checks it ran is not ready for
review.

## License

By contributing you agree that your contribution is licensed under the MIT license in
[LICENSE](LICENSE).
