# Contributing

kori is an in-house LLM gateway with a single maintainer: one Nim binary that exposes
`/v1/chat/completions` and walks an ordered list of provider legs.

## Before you send anything

- Open an issue first for anything that changes routing, the log schema or the admin surface. Those
  three are the contract the acceptance harness proves, and a patch that moves them silently is
  worse than no patch.
- One concern per pull request. A routing change and a dashboard change in one diff cannot be
  reviewed together.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`).

## Build and test

| Step | Command | Notes |
|---|---|---|
| Build | `./task nim` | `nim check`, `nimble test`, the static-embed drift check, the release build, then the acceptance self-test |
| Ops scripts | `./task ops` | shellcheck plus the deploy, smoke, preflight, rollback and config dry runs; no podman, no network |
| Dashboard | `./task web` | vite build in `apps/web`, then fail if the committed `dist` is stale |
| Dependencies | `./task audit` | `pnpm audit --audit-level=high` on `apps/web`; needs the registry, so `gate` never runs it |
| Secrets | `./task secrets` | gitleaks over the whole history, not just the commits a branch would publish |
| Everything | `./task check` | all of the above in CI order |

The acceptance harness is the gate that matters most:

```sh
KORI_BIN=./apps/api/src/kori sh acceptance/run-all.sh
```

It proves failover, cooldown, the deadlines, the quota class, mid-stream abort, tool-call passthrough,
a cold start, the all-dead `502`, the read-only dashboard and credential refresh against a real
binary. A change to routing or logging is not done until it has a case there, or an existing case
still passes for the right reason.

CI also runs `./ops/scripts/contract-check.sh .`, the golden CI/CD rules every repository here shares,
and a gitleaks job. Every job carries `timeout-minutes: 15` and caches its toolchain; a new job keeps
both.

## Branch and pull request

- Branch from `main` and name it after the concern (`fix/cooldown-after-401`).
- Paste the commands you ran and their result in the description. "Tests pass" is not evidence.
- Fill in the pull request template, including the four-line handoff at the bottom.

## What not to send

- A real credential, a `refresh_token`, a session header, or a config file with one in it. The
  repository is public, so a leak is public the moment it is pushed. `config.json` never belongs here;
  the example file is `ops/etc/config.json.example`.
- Prompt or response bodies copied out of a real request. The log deliberately carries none.
- A dependency, unless the description says why the standard library cannot do the job.
- Build output, unless it is the committed dashboard embed that `./task web` checks for drift.

Security reports do not go in an issue: see [`SECURITY.md`](SECURITY.md).
