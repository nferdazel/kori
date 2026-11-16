#!/usr/bin/env bash
# smoke.sh — post-deploy checks for kori. Exit 0 only when every hard check passes.
#
# Checks, in order:
#   1. GET /admin/state answers 200 and parses as JSON (this is the health probe; see OPS-SHIP §6.2)
#   2. the listener is reachable on loopback and NOT on any non-loopback address
#   3. the request log is append-only: the file never shrinks across a request, and its last line
#      parses as JSON. It does NOT prove one line per proxied request: that needs a real provider
#      leg, and a smoke run must not spend tokens.
#   4. edge, only when KORI_EDGE_URL is set: no bearer -> 401, wrong bearer -> 401, right bearer -> 200
#      and /admin/* stays unreachable from the edge
set -euo pipefail

APP_DIR="${KORI_APP_DIR:-/srv/qouver/apps/kori}"
BASE_URL="${KORI_BASE_URL:-http://127.0.0.1:8787}"
PORT="${KORI_PORT:-8787}"
LOG_FILE="${KORI_LOG_FILE:-$APP_DIR/logs/requests.jsonl}"
fail=0

ok() { printf 'OK   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }
warn() { printf 'WARN %s\n' "$*"; }

# ── 1. state endpoint ───────────────────────────────────────────────────────
body="$(curl -fsS --max-time 5 "$BASE_URL/admin/state" 2>/dev/null || true)"
if [ -z "$body" ]; then
  bad "GET /admin/state did not answer"
else
  if printf '%s' "$body" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "GET /admin/state 200, valid JSON"
  else
    bad "GET /admin/state answered but the body is not JSON"
  fi
fi

# ── 2. loopback only ────────────────────────────────────────────────────────
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

# ── 3. append-only log ──────────────────────────────────────────────────────
if [ -f "$LOG_FILE" ]; then
  before_size="$(stat -c %s "$LOG_FILE")"
  before_lines="$(wc -l <"$LOG_FILE")"
  curl -fsS --max-time 20 -o /dev/null "$BASE_URL/admin/state" >/dev/null 2>&1 || true
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
  # The real bearer goes to curl as a config on stdin, never in argv: /proc/<pid>/cmdline is
  # readable on the host, so an argument would hand the edge token to any local process for the
  # life of the request. `printf` here is a shell builtin, so no second process sees it either.
  code_auth() { printf 'header = "Authorization: Bearer %s"\n' "$KORI_EDGE_TOKEN" | code -K - "$@"; }
  c="$(code "$KORI_EDGE_URL/v1/models")"
  [ "$c" = "401" ] && ok "edge without bearer -> 401" || bad "edge without bearer -> $c (expected 401)"
  # The literal below is a deliberately wrong bearer: it must be rejected. Not a credential.
  c="$(code -H "Authorization: Bearer wrong-token" "$KORI_EDGE_URL/v1/models")"  # gitleaks:allow
  [ "$c" = "401" ] && ok "edge with wrong bearer -> 401" || bad "edge with wrong bearer -> $c (expected 401)"
  c="$(code_auth "$KORI_EDGE_URL/v1/models")"
  [ "$c" = "200" ] && ok "edge with right bearer -> 200" || bad "edge with right bearer -> $c (expected 200)"
  c="$(code_auth "$KORI_EDGE_URL/admin/state")"
  [ "$c" = "404" ] && ok "edge refuses /admin/state -> 404" || bad "edge answered /admin/state with $c (expected 404)"
else
  warn "KORI_EDGE_URL/KORI_EDGE_TOKEN unset, edge checks skipped"
fi

exit "$fail"
