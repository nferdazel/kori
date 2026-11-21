#!/usr/bin/env bash
# smoke.sh — post-deploy checks for kori. Exit 0 only when every hard check passes.
#
# Checks, in order:
#   1. GET /healthz answers 200 and parses as JSON. This is the health probe and it stays open by
#      design (DEC-20): the deploy gate must not need the admin token to learn that a container is
#      up. /healthz?deep is gated like the rest of the data surface and is not probed here.
#   2. admin surface, keyed on the token file the binary reads:
#      - token available ($APP_DIR/etc/admin.token, or KORI_ADMIN_TOKEN as an explicit override):
#        /admin/state and /metrics answer 200 with that bearer (sent on stdin, never argv)
#      - no token   : /admin/state must answer 404 (no token file, fail closed) or 401 (token file
#                     present, no bearer sent). Both are closed; the branch prints which one it saw.
#                     Only a 200 fails: that is the open surface DEC-20 exists to prevent.
#   3. the listener is reachable on loopback and NOT on any non-loopback address
#   4. the request log is append-only: the file never shrinks across a request, and its last line
#      parses as JSON. It does NOT prove one line per proxied request: that needs a real provider
#      leg, and a smoke run must not spend tokens.
#   5. edge, only when KORI_EDGE_URL is set: no bearer -> 401, wrong bearer -> 401, right bearer ->
#      405 with kori's own JSON body on a GET of the v1 chat path, /admin/* stays unreachable from
#      the edge, and the site block sends the host's security headers. The body matters: a 405 alone
#      can come from any proxy in front of the origin.
set -euo pipefail

APP_DIR="${KORI_APP_DIR:-/srv/qouver/apps/kori}"
BASE_URL="${KORI_BASE_URL:-http://127.0.0.1:8787}"
PORT="${KORI_PORT:-8787}"
LOG_FILE="${KORI_LOG_FILE:-$APP_DIR/logs/requests.jsonl}"
fail=0

ok() { printf 'OK   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }
warn() { printf 'WARN %s\n' "$*"; }

# ── 1. health endpoint (open by design) ─────────────────────────────────────
body="$(curl -fsS --max-time 5 "$BASE_URL/healthz" 2>/dev/null || true)"
if [ -z "$body" ]; then
  bad "GET /healthz did not answer"
else
  if printf '%s' "$body" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "GET /healthz 200, valid JSON"
  else
    bad "GET /healthz answered but the body is not JSON"
  fi
fi

# ── 2. admin surface: gated when a token exists, fail-closed when it does not ─
# A bearer goes to curl as a config on stdin, never in argv: /proc/<pid>/cmdline is readable on
# the host, so an argument would hand the admin token to any local process for the life of the
# request. `printf` is a shell builtin, so no second process sees it either.
admin_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
admin_code_auth() {
  printf 'header = "Authorization: Bearer %s"\n' "$ADMIN_TOKEN" | admin_code -K - "$@"
}
# The token is read from the file the binary reads, not from this process's environment: this
# deploy's env file is also the container's EnvironmentFile, so a copy of the token there lands in
# the container's process environment for anything that can read /proc. KORI_ADMIN_TOKEN stays as
# an explicit override for a manual run against a local binary.
ADMIN_TOKEN="${KORI_ADMIN_TOKEN:-}"
ADMIN_SOURCE="KORI_ADMIN_TOKEN"
if [ -z "$ADMIN_TOKEN" ] && [ -r "$APP_DIR/etc/admin.token" ]; then
  ADMIN_TOKEN="$(tr -d '\r\n' <"$APP_DIR/etc/admin.token")"
  ADMIN_SOURCE="$APP_DIR/etc/admin.token"
fi
if [ -n "$ADMIN_TOKEN" ]; then
  ok "admin checks use the token from $ADMIN_SOURCE"
  c="$(admin_code_auth "$BASE_URL/admin/state")"
  [ "$c" = "200" ] && ok "GET /admin/state with the admin bearer -> 200" \
    || bad "GET /admin/state with the admin bearer -> $c (expected 200)"
  c="$(admin_code_auth "$BASE_URL/metrics")"
  [ "$c" = "200" ] && ok "GET /metrics with the admin bearer -> 200" \
    || bad "GET /metrics with the admin bearer -> $c (expected 200)"
else
  # DEC-20 point 2 and the host reality: two closed answers are honest, and they mean different
  # things. 404 = no token file on the host, the fail-closed branch. 401 = a token file exists and
  # this request carried no bearer. Both prove the surface is not open; a gate that demanded 404
  # would red on every correctly configured host the moment the operator creates the token file.
  # 200 is the state that must never pass, and it is the only one this branch rejects by status.
  c="$(admin_code "$BASE_URL/admin/state")"
  case "$c" in
    404) ok "GET /admin/state without a token -> 404 (no token file, fail closed)" ;;
    401) ok "GET /admin/state without a token -> 401 (token file present, no bearer sent)" ;;
    200) bad "GET /admin/state without a token -> 200 (the admin gate is open)" ;;
    *) bad "GET /admin/state without a token -> $c (expected 404 or 401)" ;;
  esac
fi

# ── 3. loopback only ────────────────────────────────────────────────────────
# `ss` reports the publish address of the podman forward, which is what the host exposes.
if command -v ss >/dev/null 2>&1; then
  if ss -ltn "sport = :$PORT" | grep -qE "0\.0\.0\.0:$PORT|\*:$PORT|\[::\]:$PORT"; then
    bad "port $PORT is published on a non-loopback address"
  elif ss -ltn "sport = :$PORT" | grep -q "127.0.0.1:$PORT"; then
    ok "port $PORT published on 127.0.0.1 only"
  else
    bad "nothing listening on 127.0.0.1:$PORT"
  fi
else
  warn "ss not available, loopback check skipped"
fi

# ── 4. append-only log ──────────────────────────────────────────────────────
if [ -f "$LOG_FILE" ]; then
  before_size="$(stat -c %s "$LOG_FILE")"
  before_lines="$(wc -l <"$LOG_FILE")"
  curl -fsS --max-time 20 -o /dev/null "$BASE_URL/healthz" >/dev/null 2>&1 || true
  after_size="$(stat -c %s "$LOG_FILE")"
  if [ "$after_size" -lt "$before_size" ]; then
    bad "request log shrank ($before_size -> $after_size bytes)"
  else
    ok "request log did not shrink ($before_lines lines, $after_size bytes)"
  fi
  # Field contract: 9 fields, one line per request. A line that is not JSON means the writer is broken.
  if tail -n 1 "$LOG_FILE" | python3 -c 'import json,sys; json.loads(sys.stdin.readline())' 2>/dev/null; then
    ok "last log line parses as JSON"
  else
    bad "last log line is not valid JSON"
  fi
else
  bad "request log missing: $LOG_FILE"
fi

# ── 4. edge, when configured ────────────────────────────────────────────────
# A half-configured edge is a failure, not a skip: KORI_EDGE_URL without a token used to fall
# through to the else branch, so the release gate could pass without ever testing the edge.
if [ -n "${KORI_EDGE_URL:-}" ] && [ -z "${KORI_EDGE_TOKEN:-}" ]; then
  bad "KORI_EDGE_URL is set but KORI_EDGE_TOKEN is empty; edge matrix cannot run"
elif [ -n "${KORI_EDGE_URL:-}" ]; then
  code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
  headers_auth() { printf 'header = "Authorization: Bearer %s"\n' "$KORI_EDGE_TOKEN" | curl -s -D - -o /dev/null --max-time 10 -K - "$@"; }
  # The real bearer goes to curl as a config on stdin, never in argv: /proc/<pid>/cmdline is
  # readable on the host, so an argument would hand the edge token to any local process for the
  # life of the request. `printf` here is a shell builtin, so no second process sees it either.
  code_auth() { printf 'header = "Authorization: Bearer %s"\n' "$KORI_EDGE_TOKEN" | code -K - "$@"; }
  body_auth() { printf 'header = "Authorization: Bearer %s"\n' "$KORI_EDGE_TOKEN" | curl -s --max-time 10 -K - "$@"; }
  c="$(code "$KORI_EDGE_URL/v1/chat/completions")"
  [ "$c" = "401" ] && ok "edge without bearer -> 401" || bad "edge without bearer -> $c (expected 401)"
  # The literal below is a deliberately wrong bearer: it must be rejected. Not a credential.
  c="$(code -H "Authorization: Bearer wrong-token" "$KORI_EDGE_URL/v1/chat/completions")"  # gitleaks:allow
  [ "$c" = "401" ] && ok "edge with wrong bearer -> 401" || bad "edge with wrong bearer -> $c (expected 401)"
  # A GET of the chat path answers 405 from the binary: the route is POST-only. That proves the
  # edge forwarded into kori without spending a provider token. `/v1/models` also answers 200 for
  # free (DEC-14, derived from the config with no dial), but the 405 body below is the stronger
  # signal — it names kori's own error shape, which a proxy in front of the origin cannot fake.
  c="$(code_auth "$KORI_EDGE_URL/v1/chat/completions")"
  if [ "$c" != "405" ]; then
    bad "edge with right bearer -> $c (expected 405)"
  else
    # A 405 on its own proves nothing: any proxy or error page in front of the origin can answer
    # 405, so the status alone let a foreign 405 go green (gate finding, 2026-11-16). kori's own
    # 405 is a JSON body naming the method, so the body has to match as well.
    edge_body="$(body_auth "$KORI_EDGE_URL/v1/chat/completions" || true)"
    if printf '%s' "$edge_body" | grep -q '"error":"method not allowed"'; then
      ok "edge with right bearer -> 405 kori JSON on GET /v1/chat/completions"
    else
      bad "edge with right bearer -> 405 but the body is not kori's: $(printf '%s' "$edge_body" | head -c 120)"
    fi
  fi
  c="$(code_auth "$KORI_EDGE_URL/admin/state")"
  [ "$c" = "404" ] && ok "edge refuses /admin/state -> 404" || bad "edge answered /admin/state with $c (expected 404)"
  # The shared `(security)` snippet the rest of the host carries, which kori's blocks did not
  # import until 2026-11-21: the origin answered with no HSTS and nothing that stops framing.
  # Cloudflare forwards what the origin sends, so this header can only come from that snippet —
  # measured absent before the fix on ai.qouver.com and present on api.qouver.com.
  edge_headers="$(headers_auth "$KORI_EDGE_URL/v1/models" || true)"
  if printf '%s' "$edge_headers" | grep -qi '^strict-transport-security:'; then
    ok "edge answers with Strict-Transport-Security"
  else
    bad "edge answers without Strict-Transport-Security; the site block does not import the host's (security) snippet"
  fi
else
  warn "KORI_EDGE_URL/KORI_EDGE_TOKEN unset, edge checks skipped"
fi

exit "$fail"
