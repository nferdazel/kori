#!/usr/bin/env bash
# dryrun-release.sh — exercises the --push guard in `./task release`.
#
# Why this exists: a pushed release tag is permanent. GitHub's protect-release-tags ruleset blocks
# deletion, update and non_fast_forward on refs/tags/v* with no bypass, and main only takes changes
# through a pull request. So the one thing the release path must never do is publish a tag from a
# branch that can never become main: that tag cannot be taken back. Before this guard, the only
# mention of main in the whole release path was a comment, and a feature branch is a new ref, so
# its push succeeded and the permanent tag left with it.
#
# The guard lives in `task`, the per-repo entry point, because task.d/release.sh is vendored
# byte-identically into seven repos and must not carry a rule only kori has.
#
# What is real: bash, the script under test, git, a bare origin and a real clone.
# What is stubbed: nothing. --skip-check keeps the release gate out of the way.
#
# Usage: bash tests/dryrun-release.sh        (exit 0 = all scenarios passed)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kori-release.XXXXXX")"
FAILS=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

# A commit or an annotated tag refuses to run without an identity, and the harness must not read
# the operator's config: a global commit.gpgsign would hang the test on a key prompt.
export GIT_AUTHOR_NAME=dryrun GIT_AUTHOR_EMAIL=dryrun@example.invalid
export GIT_COMMITTER_NAME=dryrun GIT_COMMITTER_EMAIL=dryrun@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

git init -q --bare "$ROOT/origin.git"
git init -q -b main "$ROOT/repo"
cd "$ROOT/repo" || exit 1
mkdir -p task.d
cp "$KIT/task" task
cp "$KIT/task.d/release.sh" task.d/release.sh
printf '0.1.0\n' >VERSION
printf '# Changelog\n\n## [Unreleased]\n' >CHANGELOG.md
git add -A && git commit -qm 'chore: seed'
git remote add origin "$ROOT/origin.git"
git push -q -u origin main 2>/dev/null

tags_here() { git tag -l 'v[0-9]*' | tr '\n' ' ' | sed 's/ $//'; }
tags_origin() { git --git-dir="$ROOT/origin.git" tag -l 'v[0-9]*' | tr '\n' ' ' | sed 's/ $//'; }

# ── scenario 1: a feature branch is refused before anything is written ───────
git checkout -q -b feat/something
out=$(sh task release patch --skip-check --push 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  pass "feature branch: exit $rc, --push refused"
else
  fail "feature branch: --push was allowed (rc=0), tags=[$(tags_here)]"
fi
case "$out" in
  *"only from main"*) pass "feature branch: refusal names the rule" ;;
  *) fail "feature branch: refusal does not name the rule: $out" ;;
esac
case "$out" in
  *"feat/something"*) pass "feature branch: refusal names the branch it found" ;;
  *) fail "feature branch: refusal does not name the branch: $out" ;;
esac
if [ -z "$(tags_here)" ] && [ -z "$(tags_origin)" ]; then
  pass "feature branch: no tag here, none on origin"
else
  fail "feature branch: tags here=[$(tags_here)] origin=[$(tags_origin)]"
fi
if [ -z "$(git status --porcelain)" ] && [ "$(tr -d ' \n' <VERSION)" = "0.1.0" ]; then
  pass "feature branch: VERSION untouched, tree clean (no half-written release)"
else
  fail "feature branch: refusal left a half-written release: $(git status --porcelain) VERSION=$(tr -d ' \n' <VERSION)"
fi

# ── scenario 2: --no-push on a feature branch stays allowed ─────────────────
out=$(sh task release patch --skip-check --no-push 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(tags_here)" = "v0.1.1" ] && [ -z "$(tags_origin)" ]; then
  pass "feature branch --no-push: local v0.1.1 only, nothing published"
else
  fail "feature branch --no-push: rc=$rc here=[$(tags_here)] origin=[$(tags_origin)]"
fi

# ── scenario 3: detached HEAD is a name, not main ───────────────────────────
git checkout -q main
git checkout -q --detach
out=$(sh task release patch --skip-check --push 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ -z "$(tags_origin)" ]; then
  pass "detached HEAD: refused, nothing published"
else
  fail "detached HEAD: rc=$rc origin=[$(tags_origin)]"
fi
git checkout -q main
git tag -d v0.1.1 >/dev/null

# ── scenario 4: main still publishes, tag included ──────────────────────────
out=$(sh task release patch --skip-check --push 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(tags_here)" = "v0.1.1" ]; then
  pass "main: v0.1.1 tagged locally"
else
  fail "main: rc=$rc here=[$(tags_here)], out=$out"
fi
if [ "$(tags_origin)" = "v0.1.1" ]; then
  pass "main: v0.1.1 pushed to origin"
else
  fail "main: origin has [$(tags_origin)]"
fi
if git --git-dir="$ROOT/origin.git" merge-base --is-ancestor "$(git rev-parse 'v0.1.1^{commit}')" main 2>/dev/null; then
  pass "main: the tag points at a commit on origin/main"
else
  fail "main: the tag does not point at a commit on origin/main"
fi

cd / && rm -rf "$ROOT"

if [ "$FAILS" -ne 0 ]; then
  printf '\nRESULT: %d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nRESULT: all scenarios passed\n'
