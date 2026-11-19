#!/usr/bin/env bash
# rollback.sh — put :prev back in service. Manual path; deploy-vps.sh does this automatically
# when its health gate fails.
set -euo pipefail

APP_DIR="${KORI_APP_DIR:-/srv/qouver/apps/kori}"
IMAGE="${KORI_IMAGE:-localhost/kori}"
SERVICE="${KORI_SERVICE:-kori-api}"
HEALTH_URL="${KORI_HEALTH_URL:-http://127.0.0.1:8787/healthz}"
STATE_FILE="$APP_DIR/.deployed_rev"
LOG="$APP_DIR/logs/deploy.log"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

podman image exists "${IMAGE}:prev" || { log "ERROR: no ${IMAGE}:prev to roll back to"; exit 1; }

CURRENT="$(cat "$STATE_FILE" 2>/dev/null || echo unknown)"
podman tag "${IMAGE}:prev" "${IMAGE}:local"
systemctl --user restart "$SERVICE"

deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ]; do
  if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    log "==> rolled back from $CURRENT to :prev, healthy"
    printf '%s\n' "rollback-from-$CURRENT" >"$STATE_FILE"
    exit 0
  fi
  sleep 2
done

log "ERROR: rollback unhealthy within 60s; service is down"
exit 1
