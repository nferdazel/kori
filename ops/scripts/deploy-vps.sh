#!/usr/bin/env bash
# deploy-vps.sh — kori deploy contract for qouver1 (rootless podman + Quadlet).
#
# Called by the host webhook (adnanh/webhook, hook `kori`) with:
#   $1 = repository.name   $2 = ref
#
# Order: fail-closed ref guard -> flock -> git fetch/reset -> rev -> script self-update ->
#        ops-only commit? install the unit, health gate, stop -> pull the signed image for that
#        commit, verify its revision label and signature -> tag :local to :prev -> install unit
#        + render edge block -> restart -> health gate -> smoke -> auto-rollback to :prev
#        -> .deployed_rev -> prune.
#
# The host never builds. The image is built and signed in GitHub Actions (ci.yml, job
# image-api); this script only pulls ghcr.io/nferdazel/kori-api:sha-<7>. A host build here would
# be a second, unreviewed path to production and a second thing to keep working.
#
# No secret lives in this repo. Everything host-specific comes from the env file
# (/srv/qouver/apps/kori/env/kori-prod.env, mode 600).
#
# NOT YET RUN ON qouver1. kori is in development (owner, 2026-11-16): the skeleton below is the
# whole host contract, and the first run is a separate slot with Dimas watching.
#
# The script copies itself mid-run (self-update) and re-execs into the new file, so a fix merged
# to it takes effect on that same deploy. The lock fd survives exec.
set -euo pipefail

REPO="${1:-kori}"
REF="${2:-}"

APP_DIR="${KORI_APP_DIR:-/srv/qouver/apps/kori}"
ENV_FILE="$APP_DIR/env/kori-prod.env"
IMAGE="${KORI_IMAGE:-localhost/kori}"
IMAGE_REPO="${KORI_IMAGE_REPO:-ghcr.io/nferdazel/kori-api}"
SERVICE="${KORI_SERVICE:-kori-api}"
UNIT_DIR="${KORI_UNIT_DIR:-$HOME/.config/containers/systemd}"
STATE_FILE="$APP_DIR/.deployed_rev"
LOG="$APP_DIR/logs/deploy.log"
HEALTH_URL="${KORI_HEALTH_URL:-http://127.0.0.1:8787/healthz}"
HEALTH_GATE_SECONDS="${KORI_HEALTH_GATE_SECONDS:-60}"

# The edge block backup is a copy of the rendered block, so it carries the edge token. A run that
# dies between the backup and the restart would leave it behind in caddy/; the exit trap removes
# it. The restore path moves the backup back, so by then there is nothing left to delete.
# The staged quadlet unit is a plain temp copy and goes with it. The `.bak-*` unit backups are
# NOT removed here: they record what the host ran before, and the restore path reads them, so a
# run that dies still leaves the previous unit on disk.
CADDY_BAK=""
UNIT_STAGE=""
cleanup_temps() {
  if [ -n "${CADDY_BAK:-}" ] && [ -f "$CADDY_BAK" ]; then rm -f "$CADDY_BAK"; fi
  if [ -n "${UNIT_STAGE:-}" ] && [ -f "$UNIT_STAGE" ]; then rm -f "$UNIT_STAGE"; fi
}
trap cleanup_temps EXIT

# ── 1. Ref guard, fail-closed, and the first thing that runs ─────────────────
# Only refs/heads/main deploys. An empty or unexpected $REF exits 0 (ignore), never falls
# through: `[ -n "$REF" ] && deploy` is the fail-open shape this line exists to forbid.
# Deliberately above mkdir/log(): a guard that runs after a side effect is not a guard, and on a
# host where $APP_DIR cannot be created the script would die before ever reaching this line.
if [ "$REF" != "refs/heads/main" ]; then
  printf 'Deploy ignored: ref %s is not refs/heads/main\n' "'$REF'"
  exit 0
fi

command -v flock >/dev/null 2>&1 || {
  printf 'ERROR: flock missing; refusing to deploy without a concurrency lock\n'
  exit 1
}

mkdir -p "$APP_DIR/logs"
# The deploy log carries journal lines from the units it restarts, and a service that logs a
# credential would put it here. 0600 at creation and again on every run, because a log left at
# 0644 by an older deploy would keep that mode forever; the directory stays 0755 for the smoke
# script.
(umask 077; : >>"$LOG")
chmod 0600 "$LOG"
# The config mount is a directory, so the OAuth refresh can write its temp file next to the
# config and rename it into place. 0700 here, the file inside stays 0600.
install -d -m 0700 "$APP_DIR/etc"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }

# ── 2. Concurrency lock ──────────────────────────────────────────────────────
# Waits, it does not skip. With `-n` a push that landed while another deploy was pulling was
# dropped and never retried by the webhook, so main and the running revision drifted apart
# silently (2026-11-18, 098e29b vs f76887a). Queued runs are harmless because the git sync
# below re-reads origin/main after the lock is taken: the second one deploys the newest commit,
# and the first has already done the earlier one.
# The lock lives in the app directory, not /tmp. /tmp is world-writable (sticky, but still
# readable and pre-creatable by any local user), so a lock file there can be planted before this
# script opens it and the survivor deploys unguarded (Galih, 2026-11-19). $APP_DIR belongs to the
# deploy user, which is where sds and qouver already keep theirs. The fd, the wait and the queue
# behaviour are unchanged; only the path moved. preflight.sh reads the same path.
LOCK_FILE="$APP_DIR/.deploy.lock"
LOCK_WAIT_SECONDS="${KORI_LOCK_WAIT_SECONDS:-1800}"
# The self-update below re-execs this same process. `exec 9>...` in the re-executed script would
# replace the open file description and release the lock for a moment; a queued run could take it
# and this one would then wait its whole timeout for nothing. The marker is set only after the
# lock is held, and the fd check makes it true rather than trusted: an inherited marker with no
# open fd 9 is not a held lock.
if [ -z "${KORI_LOCK_HELD:-}" ] || [ ! -e /dev/fd/9 ]; then
  # Fail closed on a lock file this user does not control: a symlink or another owner's file
  # would be locked in name only. 0600 on creation, and narrowed again on every run for a file
  # an older deploy left wider.
  if [ -L "$LOCK_FILE" ] || { [ -e "$LOCK_FILE" ] && [ ! -O "$LOCK_FILE" ]; }; then
    die "lock file $LOCK_FILE is a symlink or owned by another user; refusing to take a lock someone else controls"
  fi
  ( umask 077; : >>"$LOCK_FILE" )
  chmod 0600 "$LOCK_FILE" || die "could not narrow $LOCK_FILE to 0600"
  exec 9>"$LOCK_FILE"
  if ! flock -w "$LOCK_WAIT_SECONDS" 9; then
    log "Deploy lock still held after ${LOCK_WAIT_SECONDS}s. Exiting."
    exit 1
  fi
  KORI_LOCK_HELD=1
  export KORI_LOCK_HELD
fi

[ -f "$ENV_FILE" ] || die "env file missing: $ENV_FILE (mode 600, holds the edge token and nothing else)"
# `set -a` so the values reach the child processes this script starts. A sourced file otherwise
# leaves plain shell variables, and smoke.sh would then run with KORI_EDGE_URL set but no token —
# the one combination it treats as a failed edge rather than a skipped one.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

MONO_DIR="$APP_DIR/src"
[ -d "$MONO_DIR/.git" ] || die "checkout missing: $MONO_DIR (clone $REPO there once, by hand)"

# ── 3. Git sync, force-push safe ─────────────────────────────────────────────
log "==> sync $REPO main"
git -C "$MONO_DIR" fetch --quiet origin main
git -C "$MONO_DIR" reset --hard --quiet origin/main
REV="$(git -C "$MONO_DIR" rev-parse HEAD)"
SHORT="${REV:0:7}"
log "==> rev $REV"

# ── 3b. Payload that is not an image ────────────────────────────────────────
# An ops-only commit (docs/, .github/, ops/, root *.md) builds no image. It must still land:
# on qouver this branch used to exit before the unit was installed, so a quadlet fix sat in the
# repo until the next image-bearing deploy (BACKLOG CM-05, 2026-11-16). The payload is handled
# below, after the helpers are in place.
OPS_ONLY=0
PREV_DEPLOYED="$(cat "$STATE_FILE" 2>/dev/null || true)"
PREV_MAIN="$PREV_DEPLOYED"
if [ -z "$PREV_MAIN" ] || ! git -C "$MONO_DIR" rev-parse --verify "${PREV_MAIN}^{commit}" >/dev/null 2>&1; then
  PREV_MAIN="$(git -C "$MONO_DIR" rev-parse "${REV}^" 2>/dev/null || true)"
fi
if [ -n "$PREV_MAIN" ] && [ "$PREV_MAIN" != "$REV" ]; then
  CHANGED="$(git -C "$MONO_DIR" diff --name-only "$PREV_MAIN" "$REV" || true)"
  if [ -n "$CHANGED" ] && ! printf '%s\n' "$CHANGED" | grep -qvE '^(docs/|\.github/|ops/|[^/]*\.md$)'; then
    OPS_ONLY=1
    log "==> only docs/workflow/ops paths changed since ${PREV_MAIN:0:7}; no image to wait for"
  fi
fi

# Scripts first, so the copy that gates this deploy is the copy in the repo. A file replaced
# mid-run keeps running the old inode; the re-exec is what makes a fix here take effect now
# rather than one deploy later.
mkdir -p "$APP_DIR/scripts"
REPO_SCRIPT="$MONO_DIR/ops/scripts/deploy-vps.sh"
SELF_SCRIPT="$APP_DIR/scripts/deploy-vps.sh"
SCRIPT_SWAPPED=0
if [ -f "$REPO_SCRIPT" ] && ! cmp -s "$REPO_SCRIPT" "$SELF_SCRIPT"; then
  cp -f "$REPO_SCRIPT" "$SELF_SCRIPT.new.$$" && chmod 0755 "$SELF_SCRIPT.new.$$" \
    && mv -f "$SELF_SCRIPT.new.$$" "$SELF_SCRIPT" \
    && SCRIPT_SWAPPED=1 && log "==> scripts/deploy-vps.sh updated from repo"
fi
for helper in smoke.sh rollback.sh; do
  SRC="$MONO_DIR/ops/scripts/$helper"
  DST="$APP_DIR/scripts/$helper"
  if [ -f "$SRC" ] && ! cmp -s "$SRC" "$DST"; then
    install -m 0755 "$SRC" "$DST.new.$$" && mv -f "$DST.new.$$" "$DST" \
      && log "==> scripts/$helper updated from repo"
  fi
done
if [ "$SCRIPT_SWAPPED" = "1" ]; then
  log "==> re-executing the updated deploy-vps.sh"
  exec "$SELF_SCRIPT" "$@"
fi

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_GATE_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

restart_service() {
  systemctl --user daemon-reload
  # A container that dies before READY makes this return non-zero at once; under `set -e` that
  # used to abort the deploy before the health gate and before rollback could finish. The gate
  # decides the outcome, never this exit code, so a failure here is a warning, not fatal.
  systemctl --user restart "$SERVICE" \
    || log "WARN: restart of $SERVICE returned non-zero; health gate decides"
}

# A quadlet unit systemd will not load is worse than an old one: the service is gone and nothing
# says so until a request fails. After the daemon-reload that turns the file into a unit, ask
# systemd what it thinks; anything but `loaded` is a failed render and must not be restarted into.
# UNTESTED on this laptop: it needs systemd + quadlet, which macOS does not have.
unit_renders() {
  systemctl --user daemon-reload || true
  local state
  state="$(systemctl --user show -p LoadState --value "$SERVICE" 2>/dev/null || true)"
  if [ "$state" != "loaded" ]; then
    log "ERROR: $SERVICE does not render: LoadState='${state:-<empty>}' after daemon-reload"
    return 1
  fi
  if [ "${PODMAN_STOP_TIMEOUT_OK:-0}" = "1" ]; then
    if ! systemctl --user cat "$SERVICE" 2>/dev/null | grep -q 'stop-timeout'; then
      log "WARN: $SERVICE renders but its unit text carries no stop-timeout; StopTimeout=15 may not have been honoured"
    fi
  fi
  return 0
}

# smoke.sh is part of the release gate, not a suggestion: a container that answers /healthz
# while its request log is unparseable, or that listens on a non-loopback address, is not a
# deploy. Its output goes to its own log so a failed run is readable afterwards.
SMOKE_LOG="$APP_DIR/logs/smoke.log"
run_smoke() {
  if [ ! -f "$APP_DIR/scripts/smoke.sh" ]; then
    log "==> WARN: scripts/smoke.sh missing; smoke gate skipped on this run"
    return 0
  fi
  if bash "$APP_DIR/scripts/smoke.sh" >"$SMOKE_LOG" 2>&1; then
    log "==> smoke passed ($SMOKE_LOG)"
    return 0
  fi
  log "ERROR: smoke failed; last lines of $SMOKE_LOG:"
  tail -n 6 "$SMOKE_LOG" | while IFS= read -r line; do log "    $line"; done
  return 1
}

# ── 4. Quadlet hardening gate (fail-closed) ─────────────────────────────────
# The unit is the security boundary around the process, so a weaker copy from the repo never
# replaces it. Aborts before anything is pulled, tagged or restarted.
UNIT_SRC="$MONO_DIR/ops/systemd/${SERVICE}.container"
[ -f "$UNIT_SRC" ] || die "quadlet unit missing: $UNIT_SRC — deploy aborted, unit on the host untouched"
for key in NoNewPrivileges=true DropCapability=ALL ReadOnly=true TimeoutStopSec=25; do
  k="${key%%=*}"; v="${key#*=}"
  grep -qEi "^[[:space:]]*${k}[[:space:]]*=[[:space:]]*${v}[[:space:]]*$" "$UNIT_SRC" \
    || die "quadlet hardening gate failed: $UNIT_SRC lacks ${key} — deploy aborted, unit on the host untouched"
done
# The image drops to uid 10001, which rootless podman maps to a subuid, so without keep-id the
# 0600 config owned by the deploy user is unreadable and the unit dies at start with
# "cannot read config '/etc/kori/config.json'" (measured 2026-11-16, first deploy). A unit that
# loses this line is not deployed.
grep -qEi "^[[:space:]]*UserNS[[:space:]]*=[[:space:]]*keep-id:uid=10001,gid=10001[[:space:]]*$" "$UNIT_SRC" \
  || die "quadlet unit lacks UserNS=keep-id:uid=10001,gid=10001 — the container cannot read its 0600 config; deploy aborted, unit on the host untouched"
# The config mount must be the writable DIRECTORY, not a single file at :ro. persistOauth writes a
# temp in the same directory and renames it over the config; a file bind cannot take that rename
# even at :rw, and at :ro every refresh is lost at the next container restart. A unit that goes
# back to the old shape silently disables token rotation, so it never reaches the host.
# The label must be private (`:Z`): a shared `:z` category is one any other container on this host
# can carry, and this directory holds every provider credential kori has.
grep -qE "^[[:space:]]*Volume=[^:]+:/etc/kori:rw,Z[[:space:]]*$" "$UNIT_SRC" \
  || die "quadlet config mount is not a writable directory at /etc/kori with a private label — deploy aborted, unit on the host untouched"
if grep -qE "^[[:space:]]*Volume=.*config\.json:/etc/kori/config\.json" "$UNIT_SRC"; then
  die "quadlet mounts config.json as a single file; OAuth rotation cannot persist — deploy aborted, unit on the host untouched"
fi
log "==> quadlet hardening gate passed (NoNewPrivileges, DropCapability=ALL, ReadOnly, TimeoutStopSec=25, config dir rw)"

# ── 4a. Stage the unit: the podman stop window goes in only where it is honoured ─
# Quadlet understands `StopTimeout=` in [Container] from podman 4.4. An older podman drops the
# key without a word, so the container would keep the 10s default and the 25s outer ring would be
# the only guard. Read the version first; empty or unparseable is "not supported", never a guess.
PODMAN_STOP_TIMEOUT_OK=0
PODMAN_VERSION="$(podman --version 2>/dev/null || true)"
PODMAN_SEMVER="$(printf '%s' "$PODMAN_VERSION" \
  | sed -n 's/.*version[[:space:]][[:space:]]*\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1.\2/p' | head -1)"
case "$PODMAN_SEMVER" in
  [0-9]*.[0-9]*) ;;
  *) PODMAN_SEMVER="" ;;
esac
if [ -n "$PODMAN_SEMVER" ]; then
  PODMAN_MAJOR="${PODMAN_SEMVER%%.*}"
  PODMAN_MINOR="${PODMAN_SEMVER#*.}"
  if [ "$PODMAN_MAJOR" -gt 4 ] || { [ "$PODMAN_MAJOR" -eq 4 ] && [ "$PODMAN_MINOR" -ge 4 ]; }; then
    PODMAN_STOP_TIMEOUT_OK=1
  fi
fi

# One staging file for the whole run: the ops-only comparison, the install and the gate all read
# it, so the key is inserted exactly once. 0600 from mktemp, outside the unit directory.
stage_unit() {
  UNIT_STAGE="$(umask 077; mktemp "${TMPDIR:-/tmp}/kori-unit.XXXXXX")" \
    || die "could not create a staging file for the quadlet unit"
  if [ "${PODMAN_STOP_TIMEOUT_OK:-0}" = "1" ]; then
    # The key belongs at the end of [Container], so it is emitted just before [Service].
    awk '/^\[Service\]$/ && !done { print "StopTimeout=15"; done = 1 } { print }' "$UNIT_SRC" >"$UNIT_STAGE" \
      || die "could not stage $UNIT_SRC"
    grep -qx 'StopTimeout=15' "$UNIT_STAGE" \
      || die "staged unit is missing StopTimeout=15 — deploy aborted, unit on the host untouched"
    log "==> staged quadlet unit with StopTimeout=15 (podman $PODMAN_SEMVER)"
  else
    cp -f "$UNIT_SRC" "$UNIT_STAGE" || die "could not stage $UNIT_SRC"
    log "WARN: podman ${PODMAN_SEMVER:-unknown} predates quadlet StopTimeout (needs >= 4.4); the container keeps podman's default 10s stop window and the 25s outer ring is the only guard"
  fi
}
stage_unit

# ── 4b. Ops-only commit: the unit is the whole payload ─────────────────────
# No image is pulled here, so .deployed_rev keeps the running image's revision. Install the unit
# only when it differs, restart only then, prove the service answers, and restore the previous
# file if it does not — the guarantee step 7 gives an image.
if [ "$OPS_ONLY" = "1" ]; then
  mkdir -p "$UNIT_DIR"
  UNIT_LIVE="$UNIT_DIR/${SERVICE}.container"
  if cmp -s "$UNIT_STAGE" "$UNIT_LIVE"; then
    log "==> ops-only commit $REV: live unit already matches, nothing to deploy or restart"
    exit 0
  fi
  UNIT_BAK=""
  if [ -f "$UNIT_LIVE" ]; then
    UNIT_BAK="$UNIT_LIVE.bak-$(date '+%Y%m%d-%H%M%S')"
    cp -p "$UNIT_LIVE" "$UNIT_BAK" || die "could not back up $UNIT_LIVE — unit untouched"
  fi
  install -m 0600 "$UNIT_STAGE" "$UNIT_LIVE.new.$$" && mv -f "$UNIT_LIVE.new.$$" "$UNIT_LIVE" \
    || die "could not install $UNIT_STAGE"
  log "==> ops-only commit $REV: quadlet unit updated (backup ${UNIT_BAK:-none}), restarting $SERVICE"
  restart_service || true
  if wait_healthy; then
    log "==> health gate passed after the unit-only restart ($HEALTH_URL); image unchanged at $(cat "$STATE_FILE" 2>/dev/null || echo unknown)"
    exit 0
  fi
  log "ERROR: $SERVICE did not answer $HEALTH_URL after the unit-only restart — restoring the previous unit"
  if [ -n "$UNIT_BAK" ] && [ -f "$UNIT_BAK" ]; then
    install -m 0600 "$UNIT_BAK" "$UNIT_LIVE"
    restart_service || true
    if wait_healthy; then
      log "==> unit rollback verified: previous unit restored from $(basename "$UNIT_BAK") and the service answers"
    else
      log "WARNING: service still not answering $HEALTH_URL after restoring $(basename "$UNIT_BAK") — needs a human"
    fi
  else
    log "WARNING: no previous unit to restore — the installed unit stays, needs a human"
  fi
  exit 1
fi

# ── 4c. Already at this revision ─────────────────────────────────────────────
# The lock waits now instead of skipping, so two or three handlers can queue behind one deploy.
# Each one re-reads origin/main and takes the newest commit, which means an earlier run in the
# queue may already have deployed exactly this revision. Retagging :local into :prev and
# restarting the service for identical bytes is a wasted restart and a :prev that no longer
# differs, so this run stops here. A failed deploy never writes .deployed_rev, so this can only
# fire when the previous run actually finished. KORI_FORCE_DEPLOY=1 exists for the one case this
# reads wrong: an operator re-running the same revision on purpose to recover the host.
if [ "${KORI_FORCE_DEPLOY:-0}" != "1" ] && [ -n "$PREV_DEPLOYED" ] && [ "$PREV_DEPLOYED" = "$REV" ]; then
  log "==> already running $SHORT (.deployed_rev matches this commit); nothing to deploy"
  exit 0
fi

# CI publishes this tag only after the gate job is green, and the webhook reaches this host
# before that. A tag that is not in the registry yet is therefore waited for, not read as "this
# commit built none": the single attempt used to keep the previous revision for good whenever
# the gate was slower than the webhook. Anything other than a missing tag (auth, network, 5xx)
# still fails at once. 45 x 20s = 15 min covers gate + queue + build on a busy runner.
IMAGE_WAIT_ATTEMPTS="${KORI_IMAGE_WAIT_ATTEMPTS:-45}"

# 0 = pulled, 1 = still absent after the window, 2 = a real pull error
pull_when_published() {
  local ref="$1" out="$2" attempt=1
  while :; do
    if podman pull "$ref" >"$out" 2>&1; then return 0; fi
    if ! grep -qiE 'manifest unknown|no such manifest|manifest for .* not found|name unknown' "$out"; then
      return 2
    fi
    [ "$attempt" -lt "$IMAGE_WAIT_ATTEMPTS" ] || return 1
    log "==> $ref not in the registry yet (gate or image job still running), attempt $attempt of $IMAGE_WAIT_ATTEMPTS"
    attempt=$((attempt + 1))
    sleep 20
  done
}

# A tag is a file name until the bytes state their own digest. Resolve the digest
# of what was just pulled, then verify and tag that digest, so a tag moved
# between pull and verify cannot point the local tag at unverified bytes.
#
# One tag carries TWO digests: the multi-arch image index that CI signed, and the
# per-arch manifest podman resolved to. Their order in RepoDigests is not stable,
# so `head -1` was a coin flip — on 2026-11-16 in fond it picked the per-arch digest,
# cosign rejected it and the deploy aborted with the web left on the old image. The
# manifest list in the registry says which digests are its children (mediaType
# decides, not position); the index is the one left over. No index means an empty
# result and a loud failure in the caller — never a per-arch digest presented as
# the signed one.
INDEX_MEDIA_TYPES="application/vnd.oci.image.index.v1+json application/vnd.docker.distribution.manifest.list.v2+json"
pulled_digest() {
  local ref="$1" list media children cand index=""
  list="$(podman manifest inspect "$ref" 2>/dev/null || true)"
  media="$(printf '%s' "$list" | sed -n 's/.*"mediaType" *: *"\([^"]*\)".*/\1/p' | head -1)"
  case " $INDEX_MEDIA_TYPES " in
    *" ${media:-none} "*) ;;
    *) return 0 ;;
  esac
  # Index manifests hold no layer/config digests, only their children's.
  # The same digest is recorded under two repository names once the image has
  # also been tagged :local (ghcr.io/... and localhost/...). Count distinct
  # digests, or a re-deploy of the same commit looks like two non-children and
  # returns empty — measured on qouver1, 2026-11-16.
  children=" $(printf '%s' "$list" | sed -n 's/.*"digest" *: *"\(sha256:[0-9a-f]*\)".*/\1/p' | tr '\n' ' ') "
  while read -r cand; do
    [ -n "$cand" ] || continue
    case "$children" in *" ${cand##*@} "*) continue ;; esac
    # Two non-children is an unknown shape: return empty rather than guess.
    [ -z "$index" ] || return 0
    index="$cand"
  done <<EOF
$(podman image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$ref" 2>/dev/null \
    | grep -F '@sha256:' | sort | awk -F'@' '!seen[$2]++' || true)
EOF
  printf '%s' "$index"
}

# CI signs the image right after pushing it, so the signature artifact is not
# readable for a few seconds: on 2026-11-16 a verify ~5s after the pull failed
# while the same digest passed seconds later. Bounded retry, then the same
# fail-closed abort as before — an unverified digest is never tagged, and a
# registry that never answers is not a pass.
COSIGN_ATTEMPTS="${COSIGN_ATTEMPTS:-5}"     # 5 x 3s = 15s of tolerance
COSIGN_RETRY_DELAY="${COSIGN_RETRY_DELAY:-3}"
verify_signature() {
  local digest="$1" attempt=1
  while :; do
    if cosign verify "$digest" \
      --certificate-identity-regexp "^https://github.com/nferdazel/kori/" \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com >/dev/null 2>&1; then
      if [ "$attempt" -gt 1 ]; then
        log "==> cosign verify passed on attempt $attempt for ${digest##*@}"
      fi
      return 0
    fi
    [ "$attempt" -lt "$COSIGN_ATTEMPTS" ] || return 1
    log "==> cosign verify did not pass for ${digest##*@} (attempt $attempt of $COSIGN_ATTEMPTS), retrying in ${COSIGN_RETRY_DELAY}s"
    attempt=$((attempt + 1))
    sleep "$COSIGN_RETRY_DELAY"
  done
}

# ── 5. Pull the image this commit built; the host never builds ───────────────
# sha-<7> is a filename until the image proves which commit it is. Two independent proofs run
# before any tag moves: the revision label must equal the commit just checked out, and the
# signature must come from this repository's workflow. Both failures leave the running
# container untouched.
#
# Retention: :local becomes :prev, the pulled sha tag becomes :local, and the sha tag is removed
# right after. No commit-SHA tag is left in the store to fill the disk silently.
IMAGE_REF="${IMAGE_REPO}:sha-${SHORT}"
IMAGE_PULLED=0
PULL_OUT="$(mktemp)"

PULL_RC=0
pull_when_published "$IMAGE_REF" "$PULL_OUT" || PULL_RC=$?

if [ "$PULL_RC" = "0" ]; then
  IMAGE_DIGEST="$(pulled_digest "$IMAGE_REF")"
  if [ -z "$IMAGE_DIGEST" ]; then
    rm -f "$PULL_OUT"
    die "Pulled $IMAGE_REF but it reports no digest — running container untouched"
  fi
  IMAGE_REV="$(podman inspect -f '{{ index .Labels "org.opencontainers.image.revision" }}' "$IMAGE_DIGEST" 2>/dev/null || true)"
  if [ "$IMAGE_REV" != "$REV" ]; then
    rm -f "$PULL_OUT"
    die "Image $IMAGE_REF says revision '${IMAGE_REV}', payload says $REV — running container untouched"
  fi
  verify_signature "$IMAGE_DIGEST" \
    || { rm -f "$PULL_OUT"; die "cosign verify failed for $IMAGE_DIGEST — running container untouched"; }

  if podman image exists "${IMAGE}:local"; then
    podman tag "${IMAGE}:local" "${IMAGE}:prev"
    log "==> tagged previous :local as :prev"
  fi
  podman tag "$IMAGE_DIGEST" "${IMAGE}:local"
  podman rmi "$IMAGE_REF" >/dev/null 2>&1 || true   # :local and :prev stay the only local tags
  IMAGE_PULLED=1
  log "==> image pulled, digest ${IMAGE_DIGEST##*@} verified and tagged :local (revision $IMAGE_REV)"
elif [ "$PULL_RC" = "1" ]; then
  # Legitimate: this commit did not change the image side, so CI pushed nothing for it.
  log "==> no image for ${SHORT} after ${IMAGE_WAIT_ATTEMPTS} attempts (this commit built none); keeping the running container"
else
  # A dead registry, an expired token or a 502 is NOT "not built". Fail closed.
  TAIL_OUT="$(tail -3 "$PULL_OUT" 2>/dev/null || true)"
  rm -f "$PULL_OUT"
  die "registry pull failed and this is NOT 'not built': $TAIL_OUT"
fi
rm -f "$PULL_OUT"

if [ "$IMAGE_PULLED" != "1" ]; then
  log "==> nothing to deploy for ${SHORT}; container left running, no restart"
  exit 0
fi

# ── 6. Unit + edge block from the repo (host is not the source of truth) ─────
# A unit that did not change is not rewritten and not backed up: rewriting it would restart the
# service for nothing, and a `.bak-*` per deploy is noise in the unit directory.
mkdir -p "$UNIT_DIR"
UNIT_LIVE="$UNIT_DIR/${SERVICE}.container"
UNIT_BAK=""
UNIT_CHANGED=0
if cmp -s "$UNIT_STAGE" "$UNIT_LIVE"; then
  log "==> quadlet unit unchanged, not reinstalling"
else
  if [ -f "$UNIT_LIVE" ]; then
    UNIT_BAK="$UNIT_LIVE.bak-$(date '+%Y%m%d-%H%M%S')"
    cp -p "$UNIT_LIVE" "$UNIT_BAK" || die "could not back up $UNIT_LIVE — unit untouched"
  fi
  install -m 0600 "$UNIT_STAGE" "$UNIT_LIVE.new.$$" \
    && mv -f "$UNIT_LIVE.new.$$" "$UNIT_LIVE" \
    || die "could not install $UNIT_STAGE"
  UNIT_CHANGED=1
  log "==> quadlet unit updated (backup ${UNIT_BAK:-none})"
fi

if [ -n "${KORI_EDGE_TOKEN:-}" ]; then
  RENDERED="$APP_DIR/caddy/site.caddy"
  mkdir -p "$APP_DIR/caddy"
  # The token is substituted by the shell, never by sed/awk: an external process would carry it in
  # argv, where every user on the host can read it from `ps` while the process lives. The temp file
  # is created by the shell at 0600 (umask 077), raised to 0640 only once its content is complete,
  # then renamed into place — no world-readable copy exists at any point.
  CADDY_BAK=""
  if [ -f "$RENDERED" ]; then
    CADDY_BAK="$RENDERED.prev.$$"
    # `cp -p` reapplies owner and group, and the deploy user is not in the caddy group, so a
    # restore that is otherwise fine can die on an ownership call. install sets the mode and lets
    # the setgid caddy dir supply the group: same end state, no ownership attempt.
    install -m 0640 "$RENDERED" "$CADDY_BAK" || die "could not back up $RENDERED — edge block untouched"
  fi
  OLD_UMASK="$(umask)"
  umask 077
  EDGE_TEMPLATE="$MONO_DIR/ops/caddy/Caddyfile.kori.example"
  [ -f "$EDGE_TEMPLATE" ] || die "edge template missing: $EDGE_TEMPLATE"
  : >"$RENDERED.tmp.$$"
  while IFS= read -r line || [ -n "$line" ]; do
    out="${line//__KORI_EDGE_TOKEN__/$KORI_EDGE_TOKEN}"
    printf '%s\n' "$out" >>"$RENDERED.tmp.$$"
  done <"$EDGE_TEMPLATE"
  chmod 0640 "$RENDERED.tmp.$$"
  mv -f "$RENDERED.tmp.$$" "$RENDERED"
  umask "$OLD_UMASK"
  # SELinux: Caddy runs as httpd_t and must be able to read this file (team note, 2026-11-15).
  restorecon "$RENDERED" 2>/dev/null || true
  log "==> rendered edge block $RENDERED"
  # Validate before the restart. A block that does not adapt takes every site on this host down
  # with it: the first run carried `servers` inside a site block (a global-only option), Caddy
  # exited 1 and the whole edge was dark until the import was commented out by hand (2026-11-16).
  # `caddy validate` adapts /etc/caddy/Caddyfile, which imports the block just rendered, so it
  # catches this with zero downtime. It needs root for the same reason the restart does.
  # The output goes to a 0600 file and is logged with the token masked: an adapt error quotes the
  # offending line, and one of those lines carries the bearer.
  VALIDATE_LOG="$(umask 077; mktemp)"
  # The redirect stays on the deploy user's side on purpose: the file is created 0600 by mktemp,
  # and `sudo tee` would need root to write into a path the script then has to read back.
  # shellcheck disable=SC2024
  if ! sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >"$VALIDATE_LOG" 2>&1; then
    log "ERROR: the rendered block does not validate; restoring the previous one, caddy untouched"
    if [ -n "$CADDY_BAK" ]; then
      mv -f "$CADDY_BAK" "$RENDERED"
    else
      # Never remove the file: /etc/caddy/Caddyfile imports it unconditionally, and a missing
      # import target makes Caddy refuse to start ("File to import not found"), so the next
      # restart would take every site down. A comment-only block adapts to nothing.
      printf '# kori edge block withdrawn: the rendered block did not validate\n' >"$RENDERED"
    fi
    # Masking happens in the shell, not through sed: the token must never reach another
    # process's argv, which is the same rule the render itself follows.
    tail -n 5 "$VALIDATE_LOG" | while IFS= read -r vline; do
      log "    caddy: ${vline//$KORI_EDGE_TOKEN/<redacted>}"
    done
    rm -f "$VALIDATE_LOG"
    exit 1
  fi
  rm -f "$VALIDATE_LOG"
  log "==> edge block validates (caddy validate)"
  # `admin off` on qouver1 makes `caddy reload` fail every time; restart is the switch.
  # A Caddy that cannot load the new block takes every site on this host down with it, so a failed
  # restart is not a warning: put back the block that was serving, restart once more, and fail the
  # deploy either way. The journal lines copied below carry no token.
  if sudo systemctl restart caddy; then
    if [ -n "$CADDY_BAK" ]; then rm -f "$CADDY_BAK"; fi
  else
    log "ERROR: caddy rejected the rendered block; restoring the previous one"
    if [ -n "$CADDY_BAK" ]; then
      mv -f "$CADDY_BAK" "$RENDERED"
    else
      # No previous block existed, so the last state Caddy loaded is "no file at this path".
      rm -f "$RENDERED"
    fi
    if sudo systemctl restart caddy; then
      log "ERROR: caddy answers again with the previous block; deploy of ${SHORT} REJECTED at the edge"
    else
      log "ERROR: caddy did not restart even with the previous block restored — the public edge is down, human needed"
    fi
    if command -v journalctl >/dev/null 2>&1; then
      journalctl -u caddy -n 20 --no-pager 2>&1 | while IFS= read -r jline; do log "    caddy: $jline"; done
    else
      log "    (journalctl not available here; read the caddy unit journal by hand)"
    fi
    exit 1
  fi
fi

# ── 7. Restart + health gate + smoke, with automatic rollback ───────────────
# A unit that does not render is never restarted into: systemd would drop the service and the old
# container would keep serving, which is the better of the two failures. Nothing was pulled or
# tagged back yet, so the running container is still the previous revision.
if [ "$UNIT_CHANGED" = "1" ] && ! unit_renders; then
  GATE_OK=0
  log "ERROR: the new quadlet unit does not render; not restarting — the running container keeps serving ${PREV_DEPLOYED:-the previous revision}"
  exit 1
fi
restart_service
GATE_OK=1
if ! wait_healthy; then
  log "ERROR: health gate failed within ${HEALTH_GATE_SECONDS}s"
  GATE_OK=0
elif ! run_smoke; then
  log "ERROR: health gate passed but smoke failed"
  GATE_OK=0
fi
if [ "$GATE_OK" != "1" ]; then
  log "ERROR: rolling back to :prev"
  ROLLBACK_OK=0
  if podman image exists "${IMAGE}:prev"; then
    podman tag "${IMAGE}:prev" "${IMAGE}:local"
    restart_service
    if wait_healthy; then
      ROLLBACK_OK=1
      log "==> rollback to :prev healthy (image only); deploy of $REV REJECTED"
    else
      log "ERROR: the :prev image is not healthy either"
    fi
  else
    log "ERROR: no :prev image to roll back to"
  fi
  if [ "$ROLLBACK_OK" != "1" ]; then
    # The unit moved as well, so an image-only rollback can leave a unit the previous binary
    # cannot run under. Put the previous unit back and say which outcome this run reached.
    if [ -n "$UNIT_BAK" ] && [ -f "$UNIT_BAK" ]; then
      install -m 0600 "$UNIT_BAK" "$UNIT_LIVE" \
        && log "==> previous quadlet unit restored from $(basename "$UNIT_BAK")" \
        || log "ERROR: could not restore $(basename "$UNIT_BAK") over $UNIT_LIVE — human needed"
      restart_service
      if wait_healthy; then
        ROLLBACK_OK=1
        log "==> rollback healthy with the previous unit and the :prev image; deploy of $REV REJECTED"
      else
        log "ERROR: rollback failed with the previous unit as well — service is down, human needed"
      fi
    elif [ "$UNIT_CHANGED" = "1" ]; then
      log "WARN: the unit changed this run and no backup was taken — the new unit stays installed"
    else
      log "==> the unit did not change this run, so there is nothing to restore"
    fi
  fi
  exit 1
fi

# ── 8. Record what is actually serving ──────────────────────────────────────
printf '%s\n' "$REV" >"$STATE_FILE"
log "==> deployed $REV, image tags: $(podman images --format '{{.Tag}}' "${IMAGE}" | sort | tr '\n' ' ')"
# The image that lost both tags is what fills the store; :local and :prev keep theirs.
podman image prune -f >/dev/null 2>&1 || true

