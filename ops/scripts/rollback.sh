#!/usr/bin/env bash
# rollback.sh — put :prev back in service. Manual path; deploy-vps.sh does this automatically
# when its health gate fails.
#
# Three things this path shares with deploy-vps.sh on purpose, because it is the same production
# surface:
#   - the deploy lock ($APP_DIR/.deploy.lock, fd 9). Without it a manual rollback can retag :local
#     and restart the unit in the middle of a deploy that is pulling, and the two runs take turns
#     moving the same two tags.
#   - a 0600 log. deploy-vps.sh creates logs/deploy.log 0600 because a journal line from a unit it
#     restarts could carry a credential; `tee` into a fresh file with the caller's umask undid that.
#   - a .deployed_rev that is a revision. It used to be written as "rollback-from-<sha>", which
#     every later deploy read as PREV_MAIN and silently fell back to REV^, and which stopped
#     answering "what is live". The image label carries the real revision, so that is what is
#     written. If the label cannot be read, the file is left alone and this says so: a wrong value
#     in that file is worse than a stale one.
set -euo pipefail

APP_DIR="${KORI_APP_DIR:-/srv/qouver/apps/kori}"
IMAGE="${KORI_IMAGE:-localhost/kori}"
SERVICE="${KORI_SERVICE:-kori-api}"
HEALTH_URL="${KORI_HEALTH_URL:-http://127.0.0.1:8787/healthz}"
HEALTH_GATE_SECONDS="${KORI_HEALTH_GATE_SECONDS:-60}"
LOCK_FILE="$APP_DIR/.deploy.lock"
LOCK_WAIT_SECONDS="${KORI_LOCK_WAIT_SECONDS:-1800}"
STATE_FILE="$APP_DIR/.deployed_rev"
LOG="$APP_DIR/logs/deploy.log"

mkdir -p "$APP_DIR/logs"
(umask 077; : >>"$LOG")
chmod 0600 "$LOG"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }

command -v flock >/dev/null 2>&1 \
  || die "flock missing; refusing to roll back without the deploy's concurrency lock"

# Same guard deploy-vps.sh applies: a lock file owned by someone else, or a symlink, is a lock in
# name only.
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

podman image exists "${IMAGE}:prev" || die "no ${IMAGE}:prev to roll back to"

CURRENT="$(cat "$STATE_FILE" 2>/dev/null || echo unknown)"
podman tag "${IMAGE}:prev" "${IMAGE}:local"

# The revision the image now serving claims. A value that is not a git sha shape is not written:
# the state file has exactly one meaning and a placeholder would break the next deploy's diff.
NEW_REV="$(podman inspect -f '{{ index .Labels "org.opencontainers.image.revision" }}' "${IMAGE}:local" 2>/dev/null || true)"
case "$NEW_REV" in
  '' | *[!0-9a-f]*) NEW_REV="" ;;
  *) [ "${#NEW_REV}" -ge 7 ] && [ "${#NEW_REV}" -le 40 ] || NEW_REV="" ;;
esac

systemctl --user restart "$SERVICE"

deadline=$((SECONDS + HEALTH_GATE_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
  if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    if [ -n "$NEW_REV" ]; then
      printf '%s\n' "$NEW_REV" >"$STATE_FILE"
      log "==> rolled back from $CURRENT to :prev (revision $NEW_REV), healthy"
    else
      log "==> rolled back from $CURRENT to :prev, healthy — the pulled image carries no usable revision label, so .deployed_rev was left at $CURRENT"
    fi
    exit 0
  fi
  sleep 2
done

log "ERROR: rollback unhealthy within ${HEALTH_GATE_SECONDS}s; service is down"
exit 1
