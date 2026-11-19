#!/usr/bin/env bash
# preflight.sh — read-only host check for qouver1, run before the first deploy.
#
# Why it exists: the deploy is blocked on three answers that only the host can give (is 8787
# free, is a build already running, does this Caddy have the rate limit module), plus a handful
# of facts that decide whether the Quadlet unit will even start (user lingering, the Quadlet
# generator, rootless podman, disk headroom). Asking a human to remember all of that is how a
# deploy dies at step 6 with a healthy-looking pipeline.
#
# It changes nothing: no podman build, no systemctl start/restart, no network request beyond a
# loopback connect probe. The only file it may create is the deploy lock it takes and releases
# (see the lock probe below), and the env file is read for its mode and ownership only — the
# contents are never printed.
#
# Exit: 0 = no FAIL (WARNs allowed), 1 = at least one FAIL, 2 = bad usage.
#
# Usage on qouver1, as the deploy user:
#   bash ops/scripts/preflight.sh
# Overrides: KORI_APP_DIR, KORI_SERVICE, KORI_PORT, KORI_MIN_FREE_GIB.
set -uo pipefail

APP_DIR="${KORI_APP_DIR:-/srv/qouver/apps/kori}"
SERVICE="${KORI_SERVICE:-kori-api}"
PORT="${KORI_PORT:-8787}"
MIN_FREE_GIB="${KORI_MIN_FREE_GIB:-5}"
ENV_FILE="$APP_DIR/env/kori-prod.env"
# Same path deploy-vps.sh takes on fd 9. It used to be /tmp/deploy-<service>.lock, which any
# local user could pre-create; the app directory is the deploy user's.
LOCK_FILE="$APP_DIR/.deploy.lock"

FAILS=0
WARNS=0

pass() { printf 'PASS  %-26s %s\n' "$1" "$2"; }
warn() { printf 'WARN  %-26s %s\n' "$1" "$2"; WARNS=$((WARNS + 1)); }
bad() { printf 'FAIL  %-26s %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }

have() { command -v "$1" >/dev/null 2>&1; }

# ── host identity ────────────────────────────────────────────────────────────
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  OS_NAME="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"
else
  OS_NAME="$(uname -s) $(uname -r)"
fi
pass "host" "$OS_NAME"

if have getenforce; then
  case "$(getenforce 2>/dev/null)" in
    Enforcing) pass "selinux" "Enforcing" ;;
    Permissive) warn "selinux" "Permissive — Caddy's /srv imports and the log rotation are only proven under Enforcing" ;;
    *) warn "selinux" "getenforce returned no usable mode" ;;
  esac
else
  warn "selinux" "getenforce absent — not the EL9 host; deploy facts below are unverified"
fi

# ── systemd user session ─────────────────────────────────────────────────────
# Without lingering, the user manager stops when the last session closes and the Quadlet unit
# goes with it. This is the failure that looks like "it worked yesterday".
if have loginctl; then
  linger="$(loginctl show-user "${USER:-$(id -un)}" -p Linger --value 2>/dev/null || printf 'unknown')"
  case "$linger" in
    yes) pass "linger" "enabled for ${USER:-$(id -un)}" ;;
    no) bad "linger" "disabled — run 'loginctl enable-linger ${USER:-$(id -un)}' or the unit dies at logout" ;;
    *) warn "linger" "could not read Linger (needs a systemd user session)" ;;
  esac
else
  warn "linger" "loginctl absent — cannot confirm the user manager survives logout"
fi

# ── quadlet ──────────────────────────────────────────────────────────────────
QUADLET_BIN=""
# KORI_QUADLET_BIN is for a non-standard install; when set it is the only path consulted.
if [ -n "${KORI_QUADLET_BIN:-}" ]; then
  CANDIDATES="$KORI_QUADLET_BIN"
else
  CANDIDATES="/usr/libexec/podman/quadlet /usr/lib/podman/quadlet $(command -v quadlet 2>/dev/null || true)"
fi
# shellcheck disable=SC2086  # a space-separated candidate list is the point
for candidate in $CANDIDATES; do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    QUADLET_BIN="$candidate"
    break
  fi
done
if [ -n "$QUADLET_BIN" ]; then
  pass "quadlet" "$QUADLET_BIN"
else
  bad "quadlet" "generator not found — ops/systemd/${SERVICE}.container will never turn into a unit"
fi

# ── podman, rootless ────────────────────────────────────────────────────────
if have podman; then
  podman_version="$(podman --version 2>/dev/null | awk '{print $3}')"
  rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || printf 'unknown')"
  if [ "$rootless" = "true" ]; then
    pass "podman" "rootless, version ${podman_version:-unknown}"
  else
    bad "podman" "rootless=$rootless — the unit, the tags and the image store assume a rootless user"
  fi
else
  bad "podman" "not installed"
fi

# ── required commands ───────────────────────────────────────────────────────
missing_cmds=""
for cmd in flock curl git install; do
  have "$cmd" || missing_cmds="$missing_cmds $cmd"
done
if [ -z "$missing_cmds" ]; then
  pass "tools" "flock curl git install present"
else
  bad "tools" "missing:$missing_cmds"
fi
if have restorecon; then
  pass "restorecon" "present (the edge block needs httpd_sys_content_t)"
else
  warn "restorecon" "absent — the rendered edge block will not be relabelled"
fi

# ── port ────────────────────────────────────────────────────────────────────
# A listening socket is only a failure if it is not ours: a re-run of this check with kori
# already deployed must stay green.
port_busy=""
if have ss; then
  ss -ltn 2>/dev/null | awk -v p=":${PORT}" '$4 ~ p"$" {found=1} END {exit !found}' && port_busy=1
else
  # No ss: probe loopback directly. Connection refused means free, nothing is written.
  if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
    exec 3>&- 2>/dev/null
    port_busy=1
  fi
fi
if [ -z "$port_busy" ]; then
  pass "port ${PORT}" "free"
else
  ours=""
  if have podman; then
    ours="$(podman ps --filter "name=${SERVICE}" --format '{{.Names}}' 2>/dev/null | grep -qxF "$SERVICE" && printf yes)"
  fi
  if [ "$ours" = "yes" ]; then
    pass "port ${PORT}" "held by ${SERVICE} — an existing deploy is running"
  else
    bad "port ${PORT}" "in use by something else — pick another port or stop the listener"
  fi
fi

# ── one build at a time ─────────────────────────────────────────────────────
busy_build=""
if have pgrep; then
  busy_build="$(pgrep -af 'podman build|podman-build|buildah (bud|build)' 2>/dev/null | head -1 || true)"
fi
if [ -n "$busy_build" ]; then
  bad "build slot" "a build is already running: $(printf '%s' "$busy_build" | cut -c1-90)"
else
  pass "build slot" "no podman/buildah build in progress"
fi

# Lock probe: a separate fd, and only a non-blocking try. If another deploy holds it, this
# deploy must not start; that is the same lock deploy-vps.sh takes on fd 9.
if have flock; then
  if ( umask 077; exec 8>"$LOCK_FILE" && flock -n 8 ) 2>/dev/null; then
    pass "deploy lock" "free ($LOCK_FILE)"
  else
    bad "deploy lock" "held by another deploy ($LOCK_FILE)"
  fi
else
  bad "deploy lock" "flock missing, cannot prove the lock is free"
fi

# ── disk headroom for the image store ──────────────────────────────────────
if have podman && have df; then
  graph_root="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)"
  target="${graph_root:-$HOME}"
  [ -d "$target" ] || target="$HOME"
  free_gib="$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1048576}')"
  if [ -n "$free_gib" ]; then
    if [ "$free_gib" -lt "$MIN_FREE_GIB" ]; then
      bad "disk" "${free_gib} GiB free on ${target} (need ${MIN_FREE_GIB}) — :local and :prev must both fit"
    else
      pass "disk" "${free_gib} GiB free on ${target}"
    fi
  else
    warn "disk" "could not read free space on ${target}"
  fi
else
  warn "disk" "podman or df missing, free space unread"
fi

# ── caddy at the edge ──────────────────────────────────────────────────────
if have caddy; then
  caddy_version="$(caddy version 2>/dev/null | head -1 | awk '{print $1}')"
  if caddy list-modules 2>/dev/null | grep -qx 'http.handlers.rate_limit'; then
    pass "caddy" "${caddy_version} with http.handlers.rate_limit"
    RL_MODULE="yes"
  else
    warn "caddy" "${caddy_version} without http.handlers.rate_limit — per-IP limit stays a Cloudflare rule"
    RL_MODULE="no"
  fi
else
  warn "caddy" "not on PATH — the edge block cannot be validated here"
  RL_MODULE="no"
fi

# `admin off` is why deploy-vps.sh restarts Caddy instead of reloading it. Informational.
if [ -r /etc/caddy/Caddyfile ]; then
  if grep -q 'import /srv/qouver/apps/kori/caddy/site.caddy' /etc/caddy/Caddyfile 2>/dev/null; then
    pass "caddy import" "site block is imported"
  else
    warn "caddy import" "no 'import ${APP_DIR}/caddy/site.caddy' line yet — Dimas adds it once, by hand"
  fi
  grep -q 'admin off' /etc/caddy/Caddyfile 2>/dev/null \
    && pass "caddy admin" "off — apply with 'systemctl restart caddy', never reload" \
    || pass "caddy admin" "on — reload is available"
else
  warn "caddy import" "/etc/caddy/Caddyfile not readable"
fi

# ── the app directory the deploy writes into ───────────────────────────────
if [ -d "$APP_DIR" ]; then
  pass "app dir" "$APP_DIR"
else
  bad "app dir" "$APP_DIR missing — deploy-vps.sh creates logs/ but not the checkout"
fi

if [ -f "$ENV_FILE" ]; then
  mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || printf '?')"
  if [ "$mode" = "600" ]; then
    pass "env file" "present, mode 600 (contents not read)"
  else
    bad "env file" "mode ${mode} — must be 600, it holds the edge token"
  fi
else
  bad "env file" "$ENV_FILE missing — the deploy dies at the env gate"
fi

if [ -d "$APP_DIR/src/.git" ]; then
  origin_url="$(git -C "$APP_DIR/src" remote get-url origin 2>/dev/null || printf 'none')"
  head_rev="$(git -C "$APP_DIR/src" rev-parse --short=8 HEAD 2>/dev/null || printf '?')"
  pass "checkout" "$APP_DIR/src at ${head_rev}, origin ${origin_url}"
else
  bad "checkout" "$APP_DIR/src is not a git clone — 'git fetch origin main' has nothing to fetch"
fi

# ── verdict ─────────────────────────────────────────────────────────────────
printf '\n'
if [ "$FAILS" -eq 0 ]; then
  printf 'RESULT: ready (%s warn) — port %s, build slot, disk, edge, app dir all accounted for\n' "$WARNS" "$PORT"
  if [ "${RL_MODULE:-no}" = "no" ]; then
    printf 'NOTE: no caddy-ratelimit module; keep the Cloudflare per-IP rule in place until Dimas rebuilds Caddy.\n'
  fi
  exit 0
fi
printf 'RESULT: %s blocker(s), %s warn — do not deploy until the FAIL lines are cleared\n' "$FAILS" "$WARNS"
exit 1
