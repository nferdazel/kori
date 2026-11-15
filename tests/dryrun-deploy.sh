#!/usr/bin/env bash
# dryrun-deploy.sh — exercises ops/scripts/deploy-vps.sh end to end on a workstation.
#
# Why this exists: the deploy script's control flow (ref guard -> flock -> git sync -> :prev retag
# -> build -> restart -> health gate -> auto-rollback -> .deployed_rev) has never been run. Syntax
# checking proves nothing about the rollback branch, and qouver1 is Dimas's slot.
#
# What is real here: bash, the script under test, git (a local bare "origin" and a real clone).
# What is stubbed: podman, systemctl, curl, sudo, restorecon, flock, sleep. The stubs keep state in
# $ROOT/state so tag history is inspectable afterwards.
#
# It does NOT prove the image builds or that a unit loads. It proves the script does what the
# contract says on every path it can take.
#
# Usage: bash tests/dryrun-deploy.sh        (exit 0 = all scenarios passed)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
DEPLOY="$KIT/ops/scripts/deploy-vps.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kori-dryrun.XXXXXX")"
FAILS=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

# ── stubs ────────────────────────────────────────────────────────────────────
BIN="$ROOT/bin"
STATE="$ROOT/state"
mkdir -p "$BIN" "$STATE"
: >"$STATE/tags"
: >"$STATE/calls.log"

cat >"$BIN/podman" <<'STUB'
#!/usr/bin/env bash
S="${PODMAN_STATE:?}"
printf 'podman %s\n' "$*" >>"$S/calls.log"
case "$1 $2" in
  "image exists")
    grep -qxF "${3##*:}" "$S/tags" 2>/dev/null && exit 0 || exit 1
    ;;
  "tag "*)
    printf '%s\n' "${3##*:}" >>"$S/tags"
    # Rolling :prev back onto :local is the moment the old image is serving again.
    case "${2##*:}" in prev) : >"$S/rolled_back" ;; esac
    ;;
esac
case "$1" in
  build)
    printf 'local\n' >>"$S/tags"
    printf 'stub build ok\n'
    ;;
  images)
    sort -u "$S/tags"
    ;;
  *)
    exit 0
    ;;
esac
STUB

cat >"$BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${PODMAN_STATE:?}/calls.log"
exit 0
STUB

cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
S="${PODMAN_STATE:?}"
printf 'curl %s\n' "$*" >>"$S/calls.log"
# ok      : always healthy
# recover : the new image is sick, the old one (:prev) is fine once it is back in service
# fail    : nothing is healthy, not even the rollback
case "${FAKE_CURL:-ok}" in
  ok) exit 0 ;;
  recover) [ -f "$S/rolled_back" ] && { printf '{}\n'; exit 0; } || exit 7 ;;
  *) exit 7 ;;
esac
STUB

cat >"$BIN/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"${PODMAN_STATE:?}/calls.log"
"$@"
STUB

cat >"$BIN/restorecon" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

# flock is not on macOS; the script only needs -n 9 to succeed.
cat >"$BIN/flock" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

# The health gate polls with sleep; do not actually wait.
cat >"$BIN/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export PODMAN_STATE="$STATE"

# ── a real git origin holding the kit, plus a real clone ─────────────────────
ORIGIN="$ROOT/origin.git"
WORK="$ROOT/work"
APP_DIR="$ROOT/app"
UNIT_DIR="$ROOT/units"
mkdir -p "$UNIT_DIR"

git init --bare --quiet "$ORIGIN"
git clone --quiet "$ORIGIN" "$WORK" 2>/dev/null
cp -R "$KIT/Containerfile" "$KIT/ops" "$KIT/tools" "$WORK/"
mkdir -p "$WORK/apps/web/dist" "$WORK/apps/api/src"
printf 'placeholder\n' >"$WORK/apps/web/dist/index.html"
printf '# kori\n' >"$WORK/apps/api/src/kori.nim"
git -C "$WORK" add -A
git -C "$WORK" -c user.email=arif@kori.local -c user.name=Arif commit --quiet -m "ops kit"
git -C "$WORK" push --quiet origin HEAD:main

mkdir -p "$APP_DIR/env"
git clone --quiet "$ORIGIN" "$APP_DIR/src"
git -C "$APP_DIR/src" checkout --quiet main
printf 'KORI_EDGE_TOKEN=dryrun-token\n' >"$APP_DIR/env/kori-prod.env"

export KORI_APP_DIR="$APP_DIR"
export KORI_UNIT_DIR="$UNIT_DIR"
export KORI_SERVICE="kori-api"
export KORI_IMAGE="localhost/kori"
export KORI_HEALTH_GATE_SECONDS=4

reset_state() {
  : >"$STATE/tags"
  : >"$STATE/calls.log"
  rm -f "$STATE/rolled_back"
  rm -f "$APP_DIR/.deployed_rev" "$APP_DIR/logs/deploy.log"
}

run() { bash "$DEPLOY" kori "$@" >"$ROOT/out.txt" 2>&1; echo $?; }

# ── scenario 1: wrong ref is ignored, no build, no restart ───────────────────
reset_state
rc="$(run refs/heads/dev)"
[ "$rc" = "0" ] && pass "wrong ref exits 0" || fail "wrong ref exited $rc"
grep -q "Deploy ignored: ref 'refs/heads/dev' is not refs/heads/main" "$ROOT/out.txt" \
  && pass "wrong ref prints the ignore line" || fail "wrong ref message missing"
[ ! -s "$STATE/calls.log" ] && pass "wrong ref touched no podman/systemctl" \
  || fail "wrong ref still ran: $(tr '\n' ' ' <"$STATE/calls.log")"

# ── scenario 2: empty ref is ignored (fail-closed, not fail-open) ────────────
reset_state
rc="$(run "")"
[ "$rc" = "0" ] && pass "empty ref exits 0" || fail "empty ref exited $rc"
[ ! -s "$STATE/calls.log" ] && pass "empty ref touched no podman/systemctl" \
  || fail "empty ref still ran: $(tr '\n' ' ' <"$STATE/calls.log")"

# ── scenario 3: happy path ───────────────────────────────────────────────────
reset_state
FAKE_CURL=ok
export FAKE_CURL
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "happy path exits 0" || fail "happy path exited $rc: $(tail -3 "$ROOT/out.txt")"
[ -f "$APP_DIR/.deployed_rev" ] && pass ".deployed_rev written: $(cat "$APP_DIR/.deployed_rev")" \
  || fail ".deployed_rev missing"
grep -qxF 'local' "$STATE/tags" && pass "image tagged :local" || fail "no :local tag"
[ -f "$UNIT_DIR/kori-api.container" ] && pass "unit installed to KORI_UNIT_DIR" || fail "unit not installed"
[ -f "$APP_DIR/caddy/site.caddy" ] && pass "edge block rendered" || fail "edge block not rendered"
grep -q 'dryrun-token' "$APP_DIR/caddy/site.caddy" && pass "edge token substituted" \
  || fail "edge token not substituted"
grep -q 'systemctl --user restart kori-api' "$STATE/calls.log" && pass "service restarted" \
  || fail "service never restarted"
grep -q 'sudo systemctl restart caddy' "$STATE/calls.log" && pass "caddy restarted" \
  || fail "caddy never restarted"

# ── scenario 4: a second deploy must retag :local to :prev before building ───
reset_state
printf 'local\n' >"$STATE/tags"   # pretend a previous deploy is running
FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "redeploy exits 0" || fail "redeploy exited $rc"
grep -qxF 'prev' "$STATE/tags" && pass ":prev retag happened" || fail ":prev missing: $(tr '\n' ' ' <"$STATE/tags")"
first_podman="$(grep '^podman' "$STATE/calls.log" | grep -E '^podman (tag|build)' | head -1)"
[ "$first_podman" = "podman tag localhost/kori:local localhost/kori:prev" ] \
  && pass "retag runs before build" || fail "first tag/build call was: $first_podman"

# ── scenario 5: no commit-SHA tags, ever ────────────────────────────────────
sha_tags="$(grep -E '^[0-9a-f]{7,40}$' "$STATE/tags" || true)"
[ -z "$sha_tags" ] && pass "no commit-SHA tag in the image store" || fail "SHA tags found: $sha_tags"

# ── scenario 6: health gate red -> rollback to :prev, deploy rejected ───────
reset_state
printf 'local\n' >"$STATE/tags"     # a good image already serving
git -C "$WORK" -c user.email=arif@kori.local -c user.name=Arif \
  commit --quiet --allow-empty -m "bad build"
git -C "$WORK" push --quiet origin HEAD:main
FAKE_CURL=recover
export FAKE_CURL
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "unhealthy deploy exits non-zero ($rc)" || fail "unhealthy deploy exited 0"
grep -q 'health gate failed' "$APP_DIR/logs/deploy.log" && pass "health gate logged as failed" \
  || fail "health gate failure not logged"
grep -q 'rollback to :prev healthy; deploy of' "$APP_DIR/logs/deploy.log" && pass "rollback to :prev succeeded" \
  || fail "no successful rollback line: $(tail -3 "$APP_DIR/logs/deploy.log")"
restarts="$(grep -c 'systemctl --user restart kori-api' "$STATE/calls.log")"
[ "$restarts" = "2" ] && pass "restarted twice: new image, then :prev" \
  || fail "expected 2 restarts, saw $restarts"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev was written for a rejected deploy" \
  || pass "rejected deploy did not move .deployed_rev"

# ── scenario 6b: both images sick -> no false comfort, exit non-zero ────────
reset_state
printf 'local\n' >"$STATE/tags"
FAKE_CURL=fail
export FAKE_CURL
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "double failure exits non-zero ($rc)" || fail "double failure exited 0"
grep -q 'rollback also unhealthy' "$APP_DIR/logs/deploy.log" && pass "double failure says a human is needed" \
  || fail "double failure not reported: $(tail -2 "$APP_DIR/logs/deploy.log")"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev written after double failure" \
  || pass "no .deployed_rev after double failure"

# ── scenario 7: build failure leaves the running image alone ────────────────
reset_state
printf 'local\n' >"$STATE/tags"
cat >"$BIN/podman" <<'STUB'
#!/usr/bin/env bash
S="${PODMAN_STATE:?}"
printf 'podman %s\n' "$*" >>"$S/calls.log"
case "$1 $2" in
  "image exists") grep -qxF "${3##*:}" "$S/tags" 2>/dev/null && exit 0 || exit 1 ;;
  "tag "*) printf '%s\n' "${3##*:}" >>"$S/tags" ;;
esac
case "$1" in
  build) printf 'stub build FAILED\n' >&2; exit 125 ;;
  images) sort -u "$S/tags" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/podman"
FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "build failure exits non-zero ($rc)" || fail "build failure exited 0"
grep -q 'build failed; :local still points at the running image' "$APP_DIR/logs/deploy.log" \
  && pass "build failure logged without restart claim" || fail "build failure log line missing"
grep -q 'systemctl --user restart' "$STATE/calls.log" && fail "restarted after a failed build" \
  || pass "no restart after a failed build"

# ── scenario 8: another deploy holds the lock -> refuse, touch nothing ──────
reset_state
cat >"$BIN/flock" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$BIN/flock"
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "busy lock exits non-zero ($rc)" || fail "busy lock exited 0"
grep -q 'Deploy already in progress' "$APP_DIR/logs/deploy.log" && pass "busy lock says so" \
  || fail "busy lock message missing"
[ ! -s "$STATE/calls.log" ] && pass "busy lock ran no podman/systemctl" \
  || fail "busy lock still ran: $(tr '\n' ' ' <"$STATE/calls.log")"

# ── scenario 9: env file missing -> die before git sync ────────────────────
reset_state
cat >"$BIN/flock" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/flock"
mv "$APP_DIR/env/kori-prod.env" "$ROOT/env.bak"
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "missing env file exits non-zero ($rc)" || fail "missing env file exited 0"
grep -q 'env file missing' "$APP_DIR/logs/deploy.log" && pass "missing env file says so" \
  || fail "missing env message missing"
grep -q 'podman build' "$STATE/calls.log" && fail "built without an env file" \
  || pass "no build without an env file"
mv "$ROOT/env.bak" "$APP_DIR/env/kori-prod.env"

printf '\n%s\n' "artifacts: $ROOT"
if [ "$FAILS" -eq 0 ]; then
  printf 'RESULT: all scenarios passed\n'
  exit 0
fi
printf 'RESULT: %s check(s) failed\n' "$FAILS"
exit 1
