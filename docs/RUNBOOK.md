# Runbook

The operational facts that are not behaviour: how a change reaches `main`, how a version becomes a
release, where the scripts keep their backups, and what to read before blaming a release for a
failed deploy. Each item names the file and line it comes from, so a later reader can check it
against the code instead of trusting this page.

Two facts here live in GitHub repository settings, not in the tree, so no file in this repository
proves them: the `protect-release-tags` ruleset (§2) and `enforce_admins` on `main` (§1). Both were
read back from the API on 2026-11-24, and these two commands are what re-checks them:

```sh
gh api repos/nferdazel/kori/branches/main/protection --jq '.enforce_admins.enabled, .required_status_checks.contexts'
gh api repos/nferdazel/kori/rulesets --jq '.[] | {name, target, enforcement}'
```

Everything else cites a line in this repository.

---

## 1. Getting a change onto `main`

`main` has `enforce_admins` on. A direct push is rejected for everyone, the owner included, until
the `Gate` status check is green. `Gate` is the single required status
(`.github/workflows/ci.yml:142-143`); a red `Gate` blocks the merge, not just the push.

**The only way in is a branch plus a pull request.** That is not a preference. Before this was on,
two releases reached `main` ahead of their own gate; with `enforce_admins`, that path no longer
exists.

```sh
git switch -c fix/cooldown-after-401 main
# ... commits ...
git push -u origin fix/cooldown-after-401    # push the branch, open the PR from it
```

The branch name follows the concern, per `CONTRIBUTING.md:43`. The PR description carries the
commands run and their output; `Gate` green is the evidence the merge needs.

---

## 2. Cutting a release: tag after the merge, never before

Release tags are permanent. The GitHub ruleset `protect-release-tags` covers `refs/tags/v*` with
deletion, update and non-fast-forward all blocked, and no bypass actor. A tag pushed to the remote
therefore cannot be deleted or moved. The only way to correct a mistyped remote tag is to disable
the ruleset for a moment, fix the tag, and turn it back on.

So the order is fixed:

1. **Merge first.** The `chore(release): vX.Y.Z` commit (written by `./task release`, staged with
   `VERSION`, the generated version module, `kori.nimble` and the cut `CHANGELOG.md` section) lands
   on `main` through a PR like any other change. Nothing is tagged on the branch.
2. **Read the tip of `main`** and tag exactly that commit:

   ```sh
   git switch main
   git pull --ff-only origin main
   git tag -f -a -m "release vX.Y.Z" vX.Y.Z "$(git rev-parse origin/main)"
   test "$(git rev-list -n1 vX.Y.Z)" = "$(git rev-parse origin/main)" && echo "tag is on origin/main"
   ```

   `git rev-list -n1` peels the annotated tag to its commit, so this asserts the tag points where
   `main` points, not merely that a tag exists. `-f` is for the local tag only: a local tag is not
   protected and a re-tag before pushing is harmless, while the remote tag is the one that cannot
   move.
3. **Push the tag.** This is the release action:

   ```sh
   git push origin vX.Y.Z
   ```

`.github/workflows/release.yml:19` runs on `push: tags: v*`. The push is what creates the GitHub
Release, so everything the tag depends on must already be final at the moment of the push:

- the tag name must equal `v$(cat VERSION)`; a mismatch fails the job at
  `.github/workflows/release.yml:50` and no Release is created;
- `CHANGELOG.md` must already carry the `## [x.y.z]` section, because its contents become the
  Release body; an empty or missing section fails the job at
  `.github/workflows/release.yml:70`.

Both are read from the tagged commit, not from your working tree. A wrong tag message or a
CHANGELOG section fixed after the push means deleting and re-creating a protected tag, which is the
thing this ruleset exists to prevent. Confirm both before `git push`.

`./task release --push` still is not a shortcut for the sequence above. It creates the tag first
(`task.d/release.sh:157`), then pushes the branch you are standing on and the tag (`:162-163`).
Since 2026-11-24 `./task release` refuses the `--push` flag unless `HEAD` is `main`, before the
script runs a single command, so a refusal leaves no half-bumped tree and no `chore(release)`
commit behind (`task:161-169`, exercised by `tests/dryrun-release.sh`; the guard sits in `task`
rather than in `task.d/release.sh` because that script is vendored byte-identically into seven
repos and must not carry a rule only kori has). Before that guard the hole was specific: a feature
branch is a *new* ref, so its push succeeded and the permanent tag left with it.

A stale or diverged local `main` fails closed for the same reason, but later: the tag is already
created locally by `:157` when the branch push is rejected at `:162`, so the script dies with
`push failed; tag vX.Y.Z is local` and leaves both the tag and the `chore(release): vX.Y.Z` commit
on your local `main`. Nothing reaches the remote. Deleting only the tag is not enough: the release
commit stays, so the next run bumps again and leaves a second tag and a second release commit. Once
`git log origin/main..HEAD` shows that commit and nothing of yours, run `git tag -d vX.Y.Z` and
`git reset --hard origin/main`, then retry. Merge, confirm the tip, then tag by hand.

Running `--no-push` off `main` is allowed and stays local, because a tag for a trial run is
legitimate. `./task release` drops the shared script's closing line, "Publish with: `git push origin
HEAD vX.Y.Z`" (`task.d/release.sh:165`), because following it from a branch publishes a permanent
tag on a commit that never reaches `main`. What it prints instead is to tag `main` by hand after the
merge.

---

## 3. Config backups: one per process, named by timestamp and pid

`ops/scripts/kori-config.sh` backs up the live config before `--force` replaces it. The backup name
carries the timestamp and the pid:

```
<config>.bak-YYYYMMDD-HHMMSS-<pid>     # ops/scripts/kori-config.sh:161
```

The pid was added because a timestamp alone has one-second granularity: two `--force` runs landing
in the same second wrote the same name, so the second backup overwrote the first while retention
still counted two (`CHANGELOG.md`, v0.10.2).

Retention is unchanged and does not parse the name. It keeps the newest `KORI_CONFIG_BAK_KEEP`
(default `2`) by mtime, so a name that does not parse still sorts by when it was written
(`ops/scripts/kori-config.sh:168-172`).

**Invariant: one backup per process.** `$$` is sufficient because the script takes at most one
backup per invocation, and nothing else in the process renames a backup. A second
`backup_live_config` call inside a single process would produce the same `<pid>` again and collide
on the same second; if that ever becomes necessary, the name needs a counter, not a different pid.
`tests/dryrun-config.sh:192` pins `date` so a fast runner reproduces the same-second case in CI as
well as a slow one.

---

## 4. Unit backups in the deploy: same second-granularity naming, known and not fixed

`ops/scripts/deploy-vps.sh` backs up the live quadlet unit before replacing it, at two points —
`ops/scripts/deploy-vps.sh:374` for an ops-only commit and `ops/scripts/deploy-vps.sh:564` for a
normal deploy:

```
<service>.container.bak-YYYYMMDD-HHMMSS
```

This name is still down to the second only, with no pid. It is a **known pattern, not a bug to fix
in this release**:

- `flock` serialises deploys (`ops/scripts/deploy-vps.sh:116`), so two deploys cannot overlap;
- a single run is far longer than one second, so two runs cannot share a timestamp even back to
  back.

The two names also live in different paths within one run (ops-only exits before the normal path
reaches its backup), so the absence of a pid is not reachable today. If the lock is ever removed or
a run is ever cut below a second, this becomes the same collision that v0.10.2 fixed in
`kori-config.sh`, and the fix is the same: add `-$$`.

---

## 5. A deploy rejected by the smoke gate is not necessarily a bad binary

`ops/scripts/deploy-vps.sh:697-707` runs `smoke.sh` after the health gate and rolls back to `:prev`
when smoke fails. A smoke failure means **an assertion in the gate is wrong or the release is
wrong** — the two are not the same, and the log says which assertion failed.

On 2026-11-24 the gate rejected a healthy 0.10.0 on qouver1. `smoke.sh:156` still matched 0.9.1's
flat `"error":"method not allowed"` body, while 0.10.0 answered the correct nested
`"type":"method_not_allowed"` envelope. The binary was right; the assertion was stale. The fix
landed in the gate (`ops/scripts/smoke.sh:156` and `tests/dryrun-smoke.sh:113`), not in the release.

Reading a rejection:

```sh
tail -n 40 /srv/qouver/apps/kori/logs/smoke.log    # the failing assertion, quoted
grep -n 'bad "' ops/scripts/smoke.sh               # what each failure message means
```

If the failing line quotes a body or status the release deliberately changed, the assertion is
stale and the gate needs the fix. If the assertion still describes the contract, the release is
wrong. Check the assertion before blaming the binary.

---

## 6. Reading `deploy.log`: two lines that look like failures and are not

`/srv/qouver/apps/kori/logs/deploy.log` carries the whole run. Two lines there are routine:

- **`cosign verify did not pass ... retrying in 3s`.** The signature is published to the registry
  after the image, so the first attempt can lose a race that resolves itself. `verify_signature`
  (`ops/scripts/deploy-vps.sh:482-498`) retries `COSIGN_ATTEMPTS` (default 5, 3s apart) and only
  then gives up; an unverified digest is never tagged and the running container is untouched
  (`:527`). The line `cosign verify passed on attempt N` prints only when `attempt > 1`
  (`:488-490`), so a first-attempt pass prints nothing and its absence proves nothing. What does
  prove a verified image is `:536`, `image pulled, digest ... verified and tagged :local`, which
  cannot print before `verify_signature` returns 0 and cannot print on the `die` path at `:527`.
- **`nothing to deploy` after a long wait.** The wait loop polls for `sha-<rev>` until its budget
  runs out; if CI never produced the image (a red Nim job, for example) the run ends at
  `ops/scripts/deploy-vps.sh:549` with the container left running rather than restarted into
  nothing. `:549` is reachable only from `PULL_RC=1`; a registry that is down or returns 401 dies
  earlier at `:542-544` with `is NOT 'not built'`. That wording is the difference between "CI built
  nothing" and "the pull failed", so read it before checking the CI run.

The running version is authoritative at `/healthz` (`{"status":"ok","version":"0.10.2",
"revision":"3d1dc1d"}`), not at a path under `/srv/qouver/apps/kori/`; the copy of `VERSION` on the
host sits in `src/VERSION` and is what the source checkout carries. `curl -s
http://127.0.0.1:8787/healthz` on the host is the one place version and revision are reported
together by the process that is actually serving.
