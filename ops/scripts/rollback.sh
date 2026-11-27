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
# The lock bound is derived from the image window below, after the env file has been read: a
# deploy ahead of this run may have taken its window from that file, and a bound that read only
# the caller's environment would give up while that deploy was still inside its own limit.
STATE_FILE="$APP_DIR/.deployed_rev"
LOG="$APP_DIR/logs/deploy.log"

mkdir -p "$APP_DIR/logs"
(umask 077; : >>"$LOG")
chmod 0600 "$LOG"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }

# ── Host config, the same file deploy-vps.sh reads ──────────────────────────
# Read here for the same reason deploy reads it before its lock: the three tunables below can be
# set in this file, and an override that reaches the deploy but not this run turns one timeout
# into two (a deploy holding 5400 s while the rollback gives up at 3000 s, Galih, 2026-11-27).
# Only these three names are parsed, and the file is never sourced: it carries the edge token, a
# recovery run has no use for it, and a line that is not shell must not be able to abort a
# rollback. A missing file, a value that is not a number, or no value at all falls back to the
# same defaults deploy uses, with the file's value winning over the caller's environment exactly
# as it does in deploy.
ENV_FILE="$APP_DIR/env/kori-prod.env"
env_knob() { # env_knob <NAME> -> the file's value for NAME, quotes stripped, empty if absent
  [ -r "$ENV_FILE" ] || return 0
  local raw
  raw="$(sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$1=(.*)$/\2/p" "$ENV_FILE" | tail -1)"
  raw="${raw%%[[:space:]]#*}"                # a trailing comment is not part of the value
  raw="${raw%"${raw##*[![:space:]]}"}"       # nor is trailing whitespace
  raw="${raw#\"}"; raw="${raw%\"}"; raw="${raw#\'}"; raw="${raw%\'}"
  printf '%s\n' "$raw"
}
env_knob_defined() { # the file names this variable at all, even with an empty value
  [ -r "$ENV_FILE" ] || return 1
  [ -n "$(sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$1=.*/1/p" "$ENV_FILE" | tail -1)" ]
}
knob_number() { # knob_number <NAME> <default> -> a plain number for the arithmetic below
  local name="$1" default="$2" value
  # The file decides when it mentions the name, exactly as sourcing does: an empty assignment in
  # the file leaves the deploy on the default, so it must not let a caller's value through here.
  if env_knob_defined "$name"; then value="$(env_knob "$name")"
  else value="${!name:-}"; fi
  case "$value" in
    '') printf '%s\n' "$default" ;;
    *[!0-9]*)
      printf 'WARN: %s=%s in %s is not a number; using %s\n' "$name" "$value" "$ENV_FILE" "$default" >&2
      printf '%s\n' "$default" ;;
    *) printf '%s\n' "$value" ;;
  esac
}
# The same lock deploy-vps.sh takes, so the same bound: a deploy ahead of this one can spend its
# whole image window (KORI_IMAGE_WAIT_ATTEMPTS x KORI_IMAGE_WAIT_INTERVAL, 20 min by default)
# waiting for a tag, and one more can be queued behind it. The flat 1800 s predates the widened
# window (Galih, 2026-11-27), so it is derived from the same two knobs and the same formula.
WAIT_ATTEMPTS="$(knob_number KORI_IMAGE_WAIT_ATTEMPTS 60)"
WAIT_INTERVAL="$(knob_number KORI_IMAGE_WAIT_INTERVAL 20)"
IMAGE_WAIT_SECONDS=$(( WAIT_ATTEMPTS * WAIT_INTERVAL ))
LOCK_WAIT_SECONDS="$(knob_number KORI_LOCK_WAIT_SECONDS $((IMAGE_WAIT_SECONDS * 2 + 600)))"

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
