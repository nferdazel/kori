#!/usr/bin/env bash
# dryrun-rollback.sh — exercises ops/scripts/rollback.sh, the manual path back to :prev.
#
# Why this exists: the automatic rollback inside deploy-vps.sh has scenarios; the manual one had
# none, and it is the command an operator runs at 02:00. Three properties are easy to lose and
# expensive to lose: it must take the same deploy lock (or it retags :local while a deploy is
# pulling), its log must stay 0600 (it appends the same file deploy-vps.sh keeps narrow), and
# .deployed_rev must be a revision afterwards (every later deploy reads it as PREV_MAIN).
#
# What is real: bash, the script under test, file modes, the tee redirect.
# What is stubbed: podman, systemctl, curl, flock, sleep.
#
# Usage: bash tests/dryrun-rollback.sh        (exit 0 = all scenarios passed)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
ROLLBACK="$KIT/ops/scripts/rollback.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kori-rollback.XXXXXX")"
FAILS=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

file_mode() { # file_mode <path> -> permission bits as octal, on BSD and GNU
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

BIN="$ROOT/bin"
STATE="$ROOT/state"
APP_DIR="$ROOT/app"
mkdir -p "$BIN" "$STATE" "$APP_DIR/logs"

cat >"$BIN/podman" <<'STUB'
#!/usr/bin/env bash
S="${ROLLBACK_STATE:?}"
printf 'podman %s\n' "$*" >>"$S/calls.log"
case "$1" in
  image)
    [ "${2:-}" = "exists" ] || exit 0
    grep -qxF "${3##*:}" "$S/tags" 2>/dev/null && exit 0 || exit 1
    ;;
  tag)
    printf '%s\n' "${3##*:}" >>"$S/tags"
    exit 0
    ;;
  inspect)
    # FAKE_REV is the revision the pulled image claims. Unset means the label is absent, which is
    # the case the script must not turn into a state file value.
    printf '%s\n' "${FAKE_REV-}"
    exit 0
    ;;
esac
exit 0
STUB

cat >"$BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${ROLLBACK_STATE:?}/calls.log"
exit 0
STUB

cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${ROLLBACK_STATE:?}/calls.log"
[ "${FAKE_HEALTH:-ok}" = "ok" ]
STUB

cat >"$BIN/flock" <<'STUB'
#!/usr/bin/env bash
printf 'flock %s\n' "$*" >>"${ROLLBACK_STATE:?}/flock.log"
exit "${FAKE_FLOCK_RC:-0}"
STUB

cat >"$BIN/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export ROLLBACK_STATE="$STATE"
export KORI_APP_DIR="$APP_DIR"
export KORI_IMAGE="localhost/kori"
export KORI_SERVICE="kori-api"
export KORI_HEALTH_GATE_SECONDS=4

reset_state() {
  : >"$STATE/tags"
  : >"$STATE/calls.log"
  rm -f "$STATE/flock.log" "$APP_DIR/.deployed_rev" "$APP_DIR/logs/deploy.log" "$APP_DIR/.deploy.lock"
  printf 'prev\n' >"$STATE/tags"
  export FAKE_FLOCK_RC=0 FAKE_HEALTH=ok FAKE_REV=deadbeefdeadbeef
}

run() { bash "$ROLLBACK" >"$ROOT/out.txt" 2>&1; echo $?; }

# ── scenario 1: no :prev -> refuse before touching anything ────────────────────
reset_state
: >"$STATE/tags"
rc="$(run)"
[ "$rc" != "0" ] && pass "no :prev exits non-zero ($rc)" || fail "no :prev exited 0"
grep -q 'no localhost/kori:prev to roll back to' "$ROOT/out.txt" \
  && pass "no :prev is named" || fail "no :prev message missing: $(cat "$ROOT/out.txt")"
grep -q '^systemctl' "$STATE/calls.log" && fail "restarted the service with no :prev" \
  || pass "service untouched with no :prev"

# ── scenario 2: happy path — :prev becomes :local, restart, health ─────────────
reset_state
rc="$(run)"
[ "$rc" = "0" ] && pass "rollback exits 0 ($rc)" || fail "rollback exited $rc: $(cat "$ROOT/out.txt")"
grep -qxF 'local' "$STATE/tags" && pass ":prev retagged as :local" || fail "no :local tag: $(tr '\n' ' ' <"$STATE/tags")"
grep -q 'systemctl --user restart kori-api' "$STATE/calls.log" && pass "service restarted" \
  || fail "service never restarted"
grep -q 'rolled back from' "$ROOT/out.txt" && pass "rollback says so" \
  || fail "rollback message missing: $(cat "$ROOT/out.txt")"

# ── scenario 3: .deployed_rev is the image's revision, not a phrase ───────────
[ "$(cat "$APP_DIR/.deployed_rev" 2>/dev/null)" = "$FAKE_REV" ] \
  && pass ".deployed_rev carries the image revision" \
  || fail ".deployed_rev is '$(cat "$APP_DIR/.deployed_rev" 2>/dev/null)'"
grep -q 'rollback-from-' "$APP_DIR/.deployed_rev" 2>/dev/null \
  && fail "the state file still carries a phrase instead of a revision" \
  || pass "no 'rollback-from-<sha>' placeholder in the state file"

# ── scenario 4: the log stays 0600 and appends, it does not replace ──────────
[ "$(file_mode "$APP_DIR/logs/deploy.log")" = "600" ] \
  && pass "deploy log is 0600" || fail "deploy log mode is $(file_mode "$APP_DIR/logs/deploy.log")"
grep -q 'rolled back' "$APP_DIR/logs/deploy.log" && pass "the rollback line reached the log" \
  || fail "the rollback line is not in deploy.log"

# ── scenario 5: a 0644 log left by an older run is narrowed in place ────────
reset_state
printf '[old] a line from a previous deploy\n' >"$APP_DIR/logs/deploy.log"
chmod 0644 "$APP_DIR/logs/deploy.log"
rc="$(run)"
[ "$rc" = "0" ] && pass "rollback over an existing log exits 0 ($rc)" || fail "existing log run exited $rc"
[ "$(file_mode "$APP_DIR/logs/deploy.log")" = "600" ] \
  && pass "a world-readable log is narrowed to 0600" \
  || fail "an existing 0644 log stayed $(file_mode "$APP_DIR/logs/deploy.log")"
grep -q 'a line from a previous deploy' "$APP_DIR/logs/deploy.log" \
  && pass "the existing log is appended, not replaced" \
  || fail "the existing log was replaced"

# ── scenario 6: the deploy lock is taken, and with -w not -n ────────────────
grep -qE '^flock -w ' "$STATE/flock.log" 2>/dev/null \
  && pass "rollback takes the deploy lock with a wait" \
  || fail "rollback did not take the deploy lock with -w: $(cat "$STATE/flock.log" 2>/dev/null)"
grep -qE 'flock -n' "$STATE/flock.log" 2>/dev/null \
  && fail "rollback uses the non-blocking lock, so a push mid-deploy is dropped" \
  || pass "rollback does not use the non-blocking lock"
[ -f "$APP_DIR/.deploy.lock" ] && pass "the lock file is the deploy's path" \
  || fail "the lock file is not $APP_DIR/.deploy.lock"

# ── scenario 7: a lock held by another run refuses, nothing retagged ────────
reset_state
export FAKE_FLOCK_RC=1
rc="$(run)"
[ "$rc" != "0" ] && pass "held lock exits non-zero ($rc)" || fail "held lock exited 0"
grep -q 'Deploy lock still held' "$ROOT/out.txt" && pass "held lock is named" \
  || fail "held lock message missing: $(cat "$ROOT/out.txt")"
grep -qxF 'local' "$STATE/tags" && fail "retagged :local while another run held the lock" \
  || pass "no tag moved without the lock"
grep -q '^systemctl' "$STATE/calls.log" && fail "restarted the service without the lock" \
  || pass "service untouched without the lock"

# ── scenario 8: unhealthy after rollback -> non-zero, state file untouched ──
reset_state
export FAKE_HEALTH=fail
printf '%s\n' "sickbeef" >"$APP_DIR/.deployed_rev"
rc="$(run)"
[ "$rc" != "0" ] && pass "unhealthy rollback exits non-zero ($rc)" || fail "unhealthy rollback exited 0"
grep -q 'rollback unhealthy' "$ROOT/out.txt" && pass "unhealthy rollback is named" \
  || fail "unhealthy rollback not named: $(cat "$ROOT/out.txt")"
[ "$(cat "$APP_DIR/.deployed_rev")" = "sickbeef" ] \
  && pass ".deployed_rev untouched when the rollback is unhealthy" \
  || fail ".deployed_rev moved on a failed rollback: $(cat "$APP_DIR/.deployed_rev")"
unset FAKE_HEALTH

# ── scenario 9: no usable revision label -> leave the state file alone ──────
# The image is foreign or hand-tagged; writing "unknown" here would make the next deploy compute
# its ops-only diff against a commit that does not exist.
reset_state
export FAKE_REV=""
printf '%s\n' "oldbeef" >"$APP_DIR/.deployed_rev"
rc="$(run)"
[ "$rc" = "0" ] && pass "a label-less image still rolls back ($rc)" || fail "label-less rollback exited $rc"
[ "$(cat "$APP_DIR/.deployed_rev")" = "oldbeef" ] \
  && pass ".deployed_rev kept when the image carries no revision" \
  || fail ".deployed_rev became '$(cat "$APP_DIR/.deployed_rev")'"
grep -q 'carries no usable revision label' "$ROOT/out.txt" \
  && pass "the missing label is announced, not guessed" \
  || fail "missing label not announced: $(cat "$ROOT/out.txt")"
unset FAKE_REV

# ── scenario 10: a revision that is not a sha is refused as a value ─────────
reset_state
export FAKE_REV="release-0.8.1"
printf '%s\n' "oldbeef" >"$APP_DIR/.deployed_rev"
rc="$(run)"
[ "$rc" = "0" ] && pass "a non-sha label still rolls back ($rc)" || fail "non-sha label exited $rc"
[ "$(cat "$APP_DIR/.deployed_rev")" = "oldbeef" ] \
  && pass "a non-sha label is not written to the state file" \
  || fail "a non-sha label reached the state file: $(cat "$APP_DIR/.deployed_rev")"
unset FAKE_REV

printf '\n%s\n' "artifacts: $ROOT"
if [ "$FAILS" -eq 0 ]; then
  printf 'RESULT: all scenarios passed\n'
  exit 0
fi
printf 'RESULT: %s check(s) failed\n' "$FAILS"
exit 1
