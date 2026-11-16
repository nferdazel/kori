#!/usr/bin/env bash
# deploy-vps.sh — kori deploy contract for qouver1 (rootless podman + Quadlet).
#
# Called by the host webhook (adnanh/webhook, hook `kori`) with:
#   $1 = repository.name   $2 = ref
#
# Order: fail-closed ref guard -> flock -> git fetch/reset -> rev -> pull the signed image for
#        that commit, verify its revision label and signature -> tag :local to :prev -> install
#        unit + render edge block -> restart -> health gate -> auto-rollback to :prev
#        -> .deployed_rev -> self-update.
#
# The host never builds. The image is built and signed in GitHub Actions (ci.yml, job
# image-api); this script only pulls ghcr.io/nferdazel/kori-api:sha-<7>. A host build here would
# be a second, unreviewed path to production and a second thing to keep working.
#
# No secret lives in this repo. Everything host-specific comes from the env file
# (/srv/qouver/apps/kori/env/kori-prod.env, mode 600).
#
# NOT YET RUN ON qouver1. First run is Dimas's slot, with him watching.
#
# The script copies itself mid-run (self-update) and keeps executing the old inode,
# so a fix merged to it takes effect one deploy later.
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
HEALTH_URL="${KORI_HEALTH_URL:-http://127.0.0.1:8787/admin/state}"
HEALTH_GATE_SECONDS="${KORI_HEALTH_GATE_SECONDS:-60}"

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
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }

# ── 2. Concurrency lock ──────────────────────────────────────────────────────
exec 9>"/tmp/deploy-${SERVICE}.lock"
if ! flock -n 9; then
  log "Deploy already in progress. Exiting."
  exit 1
fi

[ -f "$ENV_FILE" ] || die "env file missing: $ENV_FILE (mode 600, holds the edge token and nothing else)"
# shellcheck disable=SC1090
. "$ENV_FILE"

MONO_DIR="$APP_DIR/src"
[ -d "$MONO_DIR/.git" ] || die "checkout missing: $MONO_DIR (clone $REPO there once, by hand)"

# ── 3. Git sync, force-push safe ─────────────────────────────────────────────
log "==> sync $REPO main"
git -C "$MONO_DIR" fetch --quiet origin main
git -C "$MONO_DIR" reset --hard --quiet origin/main
REV="$(git -C "$MONO_DIR" rev-parse HEAD)"
SHORT="${REV:0:7}"
log "==> rev $REV"

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

# ── 4. Pull the image this commit built; the host never builds ───────────────
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

# ── 5. Unit + edge block from the repo (host is not the source of truth) ─────
install -m 0644 "$MONO_DIR/ops/systemd/${SERVICE}.container" "$UNIT_DIR/${SERVICE}.container"

if [ -n "${KORI_EDGE_TOKEN:-}" ]; then
  RENDERED="$APP_DIR/caddy/site.caddy"
  mkdir -p "$APP_DIR/caddy"
  sed "s|__KORI_EDGE_TOKEN__|${KORI_EDGE_TOKEN}|g" \
    "$MONO_DIR/ops/caddy/Caddyfile.kori.example" >"$RENDERED.tmp"
  install -m 0640 "$RENDERED.tmp" "$RENDERED"
  rm -f "$RENDERED.tmp"
  # SELinux: Caddy runs as httpd_t and must be able to read this file (team note, 2026-11-15).
  restorecon "$RENDERED" 2>/dev/null || true
  log "==> rendered edge block $RENDERED"
  # `admin off` on qouver1 makes `caddy reload` fail every time; restart is the switch.
  sudo systemctl restart caddy || log "WARN: caddy restart returned non-zero; check is-active"
fi

# ── 6. Restart + health gate with automatic rollback ────────────────────────
restart_service
if wait_healthy; then
  log "==> healthy after restart"
else
  log "ERROR: health gate failed within ${HEALTH_GATE_SECONDS}s; rolling back to :prev"
  if podman image exists "${IMAGE}:prev"; then
    podman tag "${IMAGE}:prev" "${IMAGE}:local"
    restart_service
    if wait_healthy; then
      log "==> rollback to :prev healthy; deploy of $REV REJECTED"
    else
      log "ERROR: rollback also unhealthy — service is down, human needed"
    fi
  else
    log "ERROR: no :prev image to roll back to"
  fi
  exit 1
fi

# ── 7. Record what is actually serving ──────────────────────────────────────
printf '%s\n' "$REV" >"$STATE_FILE"
log "==> deployed $REV, image tags: $(podman images --format '{{.Tag}}' "${IMAGE}" | sort | tr '\n' ' ')"

# Self-update: this script and the smoke script follow the repo, so a fix here is not a manual scp.
for f in deploy-vps.sh smoke.sh rollback.sh; do
  SRC="$MONO_DIR/ops/scripts/$f"
  DST="$APP_DIR/scripts/$f"
  if [ -f "$SRC" ] && ! cmp -s "$SRC" "$DST"; then
    install -m 0755 "$SRC" "$DST.tmp" && mv "$DST.tmp" "$DST"
    log "==> self-updated $f"
  fi
done
