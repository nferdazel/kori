#!/usr/bin/env bash
# dryrun-deploy.sh — exercises ops/scripts/deploy-vps.sh end to end on a workstation.
#
# Why this exists: the deploy script's control flow (ref guard -> flock -> git sync -> pull ->
# revision label -> cosign -> :prev retag -> restart -> health gate -> auto-rollback ->
# .deployed_rev) has never been run. Syntax checking proves nothing about the rollback branch,
# and qouver1 is Dimas's slot.
#
# What is real here: bash, the script under test, git (a local bare "origin" and a real clone).
# What is stubbed: podman, cosign, systemctl, curl, sudo, restorecon, flock, sleep. The stubs keep
# state in $ROOT/state so tag history is inspectable afterwards.
#
# It does NOT prove the image builds, that the registry serves it, or that a unit loads. It
# proves the script does what the contract says on every path it can take.
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
case "$1" in
  pull)
    # ok       : the registry serves the image for this commit
    # notbuilt : CI legitimately pushed nothing for this commit
    # error    : registry down / 502 / expired token — must NOT be read as "not built"
    case "${FAKE_PULL:-ok}" in
      ok) printf 'stub pull ok\n'; exit 0 ;;
      notbuilt) printf 'Error: manifest unknown\n' >&2; exit 125 ;;
      *) printf 'Error: received unexpected HTTP status: 502 Bad Gateway\n' >&2; exit 125 ;;
    esac
    ;;
  inspect)
    # The label the image claims. The harness passes the sha the host should compare against,
    # so a mismatch is a scenario and not a coincidence.
    printf '%s\n' "${FAKE_REV:-}"
    exit 0
    ;;
  image)
    [ "${2:-}" = "exists" ] || exit 0
    grep -qxF "${3##*:}" "$S/tags" 2>/dev/null && exit 0 || exit 1
    ;;
  tag)
    printf '%s\n' "${3##*:}" >>"$S/tags"
    # Rolling :prev back onto :local is the moment the old image is serving again.
    case "${2##*:}" in prev) : >"$S/rolled_back" ;; esac
    ;;
  images)
    sort -u "$S/tags"
    ;;
  *)
    exit 0
    ;;
esac
STUB

# cosign verify: keyless signature check against this repo's workflow identity.
cat >"$BIN/cosign" <<'STUB'
#!/usr/bin/env bash
printf 'cosign %s\n' "$*" >>"${PODMAN_STATE:?}/calls.log"
[ "${FAKE_COSIGN:-ok}" = "ok" ] && exit 0 || exit 1
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
cp -R "$KIT/ops" "$KIT/tools" "$WORK/"
mkdir -p "$WORK/apps/web/dist" "$WORK/apps/api/src"
cp "$KIT/apps/api/Dockerfile" "$WORK/apps/api/Dockerfile"
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

head_sha() { git -C "$WORK" rev-parse HEAD; }
head_short() { printf '%.7s' "$(head_sha)"; }
sha_ref() { printf 'ghcr.io/nferdazel/kori-api:sha-%s' "$(head_short)"; }

# The image this commit built, claimed by the label, signed by this repo's workflow.
happy_image() {
  FAKE_REV="$(head_sha)"
  export FAKE_REV
  export FAKE_PULL=ok FAKE_COSIGN=ok
}

restarts() { grep -c 'systemctl --user restart kori-api' "$STATE/calls.log" || true; }

# ── scenario 1: wrong ref is ignored, no pull, no restart ────────────────────
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

# ── scenario 3: happy path — pull, verify, tag :local, restart ───────────────
reset_state
happy_image
export FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "happy path exits 0" || fail "happy path exited $rc: $(tail -3 "$ROOT/out.txt")"
[ -f "$APP_DIR/.deployed_rev" ] && pass ".deployed_rev written: $(cat "$APP_DIR/.deployed_rev")" \
  || fail ".deployed_rev missing"
[ "$(cat "$APP_DIR/.deployed_rev" 2>/dev/null)" = "$(head_sha)" ] \
  && pass ".deployed_rev is the full commit sha" || fail ".deployed_rev is not the full sha"
grep -qxF 'local' "$STATE/tags" && pass "image tagged :local" || fail "no :local tag"
[ -f "$UNIT_DIR/kori-api.container" ] && pass "unit installed to KORI_UNIT_DIR" || fail "unit not installed"
[ -f "$APP_DIR/caddy/site.caddy" ] && pass "edge block rendered" || fail "edge block not rendered"
grep -q 'dryrun-token' "$APP_DIR/caddy/site.caddy" && pass "edge token substituted" \
  || fail "edge token not substituted"
grep -q 'systemctl --user restart kori-api' "$STATE/calls.log" && pass "service restarted" \
  || fail "service never restarted"
grep -q 'sudo systemctl restart caddy' "$STATE/calls.log" && pass "caddy restarted" \
  || fail "caddy never restarted"

# ── scenario 3b: the pulled tag is the sha of the commit that was checked out ─
grep -qxF "podman pull $(sha_ref)" "$STATE/calls.log" && pass "pulled $(sha_ref)" \
  || fail "did not pull $(sha_ref): $(grep '^podman pull' "$STATE/calls.log")"
grep -q 'podman inspect -f {{ index .Labels "org.opencontainers.image.revision" }}' "$STATE/calls.log" \
  && pass "revision label read from the pulled image" || fail "revision label never read"
grep -q 'cosign verify' "$STATE/calls.log" && pass "signature verified" || fail "cosign never ran"
grep -qF -- '--certificate-identity-regexp ^https://github.com/nferdazel/kori/' "$STATE/calls.log" \
  && pass "signature pinned to this repo's workflow identity" \
  || fail "cosign identity not pinned to this repo"
grep -qxF "podman rmi $(sha_ref)" "$STATE/calls.log" && pass "sha tag removed after retag" \
  || fail "sha tag left behind: $(grep '^podman rmi' "$STATE/calls.log")"

# ── scenario 4: a redeploy rotates :local to :prev ──────────────────────────
reset_state
printf 'local\n' >"$STATE/tags"   # pretend a previous deploy is running
happy_image
export FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "redeploy exits 0" || fail "redeploy exited $rc"
grep -qxF 'prev' "$STATE/tags" && pass ":prev retag happened" || fail ":prev missing: $(tr '\n' ' ' <"$STATE/tags")"
first_tag="$(grep -E '^podman tag' "$STATE/calls.log" | head -1)"
[ "$first_tag" = "podman tag localhost/kori:local localhost/kori:prev" ] \
  && pass "retag runs first" || fail "first tag call was: $first_tag"
# The pull is what proves the image before any tag moves, so it must come first of all.
first_op="$(grep -E '^podman (pull|tag|build)' "$STATE/calls.log" | head -1)"
case "$first_op" in
  "podman pull "*) pass "pull precedes every tag move" ;;
  *) fail "first podman op was: $first_op" ;;
esac

# ── scenario 5: no commit-SHA tag survives in the image store ───────────────
sha_tags="$(grep -E '^[0-9a-f]{7,40}$' "$STATE/tags" || true)"
[ -z "$sha_tags" ] && pass "no commit-SHA tag in the image store" || fail "SHA tags found: $sha_tags"
[ "$(sort -u "$STATE/tags" | tr '\n' ' ')" = "local prev " ] \
  && pass "retained tags are exactly :local and :prev" \
  || fail "retained tags: $(sort -u "$STATE/tags" | tr '\n' ' ')"

# ── scenario 6: revision label mismatch -> die, nothing touched ────────────
reset_state
printf 'local\n' >"$STATE/tags"
export FAKE_PULL=ok FAKE_COSIGN=ok FAKE_CURL=ok
export FAKE_REV="0000000000000000000000000000000000000000"
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "revision mismatch exits non-zero ($rc)" || fail "revision mismatch exited 0"
grep -q 'says revision' "$APP_DIR/logs/deploy.log" && pass "mismatch names the two revisions" \
  || fail "mismatch not logged: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(restarts)" = "0" ] && pass "mismatch never restarted the service" || fail "mismatch restarted the service"
grep -q 'cosign' "$STATE/calls.log" && fail "cosign ran on an unverified-revision image" \
  || pass "cosign skipped when the revision is wrong"
[ "$(sort -u "$STATE/tags" | tr '\n' ' ')" = "local " ] && pass "tags untouched by the mismatch" \
  || fail "tags moved: $(sort -u "$STATE/tags" | tr '\n' ' ')"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev written for a rejected image" \
  || pass "rejected image did not move .deployed_rev"

# ── scenario 7: cosign failure -> die, nothing touched ─────────────────────
reset_state
printf 'local\n' >"$STATE/tags"
export FAKE_PULL=ok FAKE_CURL=ok FAKE_COSIGN=fail
FAKE_REV="$(head_sha)"
export FAKE_REV
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "unsigned image exits non-zero ($rc)" || fail "unsigned image exited 0"
grep -q 'cosign verify failed' "$APP_DIR/logs/deploy.log" && pass "signature failure logged" \
  || fail "signature failure not logged: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(restarts)" = "0" ] && pass "unsigned image never restarted the service" \
  || fail "unsigned image restarted the service"
[ "$(sort -u "$STATE/tags" | tr '\n' ' ')" = "local " ] && pass "tags untouched by the signature failure" \
  || fail "tags moved: $(sort -u "$STATE/tags" | tr '\n' ' ')"
export FAKE_COSIGN=ok

# ── scenario 8: registry 502 -> die (not "not built") ──────────────────────
reset_state
printf 'local\n' >"$STATE/tags"
export FAKE_PULL=error FAKE_COSIGN=ok FAKE_CURL=ok
FAKE_REV="$(head_sha)"
export FAKE_REV
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "registry 502 exits non-zero ($rc)" || fail "registry 502 exited 0"
grep -q "registry pull failed and this is NOT 'not built'" "$APP_DIR/logs/deploy.log" \
  && pass "502 is not read as 'not built'" || fail "502 message missing: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(restarts)" = "0" ] && pass "502 never restarted the service" || fail "502 restarted the service"

# ── scenario 9: no image for this commit -> keep the running container ─────
reset_state
printf 'local\n' >"$STATE/tags"
export FAKE_PULL=notbuilt FAKE_COSIGN=ok FAKE_CURL=ok
FAKE_REV="$(head_sha)"
export FAKE_REV
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "not-built exits 0" || fail "not-built exited $rc"
grep -q 'no image for' "$APP_DIR/logs/deploy.log" && pass "not-built says so" \
  || fail "not-built message missing: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(restarts)" = "0" ] && pass "not-built left the container running" || fail "not-built restarted the service"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev written when nothing was deployed" \
  || pass "not-built did not move .deployed_rev"
[ "$(sort -u "$STATE/tags" | tr '\n' ' ')" = "local " ] && pass "not-built left the tags alone" \
  || fail "tags moved: $(sort -u "$STATE/tags" | tr '\n' ' ')"

# ── scenario 10: health gate red -> rollback to :prev, deploy rejected ─────
reset_state
printf 'local\n' >"$STATE/tags"     # a good image already serving
happy_image
git -C "$WORK" -c user.email=arif@kori.local -c user.name=Arif \
  commit --quiet --allow-empty -m "bad build"
git -C "$WORK" push --quiet origin HEAD:main
happy_image
export FAKE_CURL=recover
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "unhealthy deploy exits non-zero ($rc)" || fail "unhealthy deploy exited 0"
grep -q 'health gate failed' "$APP_DIR/logs/deploy.log" && pass "health gate logged as failed" \
  || fail "health gate failure not logged"
grep -q 'rollback to :prev healthy; deploy of' "$APP_DIR/logs/deploy.log" && pass "rollback to :prev succeeded" \
  || fail "no successful rollback line: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(restarts)" = "2" ] && pass "restarted twice: new image, then :prev" \
  || fail "expected 2 restarts, saw $(restarts)"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev was written for a rejected deploy" \
  || pass "rejected deploy did not move .deployed_rev"

# ── scenario 11: both images sick -> no false comfort, exit non-zero ───────
reset_state
printf 'local\n' >"$STATE/tags"
happy_image
export FAKE_CURL=fail
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "double failure exits non-zero ($rc)" || fail "double failure exited 0"
grep -q 'rollback also unhealthy' "$APP_DIR/logs/deploy.log" && pass "double failure says a human is needed" \
  || fail "double failure not reported: $(tail -2 "$APP_DIR/logs/deploy.log")"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev written after double failure" \
  || pass "no .deployed_rev after double failure"

# ── scenario 12: another deploy holds the lock -> refuse, touch nothing ────
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

# ── scenario 13: env file missing -> die before git sync ───────────────────
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
grep -q 'podman pull' "$STATE/calls.log" && fail "pulled without an env file" \
  || pass "no pull without an env file"
mv "$ROOT/env.bak" "$APP_DIR/env/kori-prod.env"

# ── scenario 14: the host never builds ─────────────────────────────────────
builds="$(grep -c 'podman build' "$DEPLOY" || true)"
[ "$builds" = "0" ] && pass "deploy script contains no 'podman build'" \
  || fail "deploy script still builds on the host ($builds match(es))"

printf '\n%s\n' "artifacts: $ROOT"
if [ "$FAILS" -eq 0 ]; then
  printf 'RESULT: all scenarios passed\n'
  exit 0
fi
printf 'RESULT: %s check(s) failed\n' "$FAILS"
exit 1
