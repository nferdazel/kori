#!/usr/bin/env bash
# dryrun-smoke.sh — runs ops/scripts/smoke.sh against stubs, so every branch has been executed
# before it ever decides a release on qouver1.
#
# Stubbed: curl, ss, stat (GNU stat is what qouver1 has; macOS needs `stat -f`). Everything else is
# the real script, real bash, a real log file.
#
# Usage: bash tests/dryrun-smoke.sh      (exit 0 = all scenarios passed)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
SMOKE="$KIT/ops/scripts/smoke.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kori-smoke.XXXXXX")"
FAILS=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

BIN="$ROOT/bin"
STATE="$ROOT/state"
APP_DIR="$ROOT/app"
LOG_FILE="$APP_DIR/logs/requests.jsonl"
mkdir -p "$BIN" "$STATE" "$APP_DIR/logs"
: >"$STATE/calls.log"

export FAKE_BASE_URL="http://127.0.0.1:8787"
export FAKE_EDGE_URL="https://ai.qouver.com"
export FAKE_GOOD_TOKEN="smoke-token"
export FAKE_ADMIN_TOKEN="smoke-admin-token"

cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
S="${SMOKE_STATE:?}"
printf 'curl %s\n' "$*" >>"$S/calls.log"
code_only=0; hdr=""; url=""; cfg=""; dump_headers=0
while [ $# -gt 0 ]; do
  case "$1" in
    -w) code_only=1; shift 2 ;;
    -D) dump_headers=1; shift 2 ;;
    -H) hdr="$2"; shift 2 ;;
    -K|--config) cfg="$2"; shift 2 ;;
    -o|--max-time) shift 2 ;;
    -s|-S|-f) shift 1 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
# A bearer handed over as `-K -` arrives on stdin, so it never shows up in this stub's argv log.
if [ "$cfg" = "-" ]; then
  while IFS= read -r cline; do
    case "$cline" in
      header*=*)
        hdr="${cline#*\"}"; hdr="${hdr%\"*}" ;;
    esac
  done
fi
say() { printf '%s' "$1"; }
if [ "${url#*"$FAKE_BASE_URL"}" != "$url" ]; then
  # loopback surface: /healthz is open, /admin/* and /metrics are gated (DEC-20)
  path="${url#"$FAKE_BASE_URL"}"
  case "$path" in
    /healthz*)
      if [ "$code_only" = "1" ]; then say 200; exit 0; fi
      case "${FAKE_STATE:-ok}" in
        empty) exit 22 ;;
        notjson) say 'not json at all'; exit 0 ;;
        *) say '{"status":"ok","version":"0.0.0-test","revision":"deadbee"}' ;;
      esac
      exit 0 ;;
    /admin/state|/metrics)
      # FAKE_ADMIN_OPEN=1 is the broken binary: no credential, and the surface answers anyway.
      if [ "${FAKE_ADMIN_OPEN:-0}" = "1" ]; then
        [ "$code_only" = "1" ] && { say 200; exit 0; }
        say '{"legs":[]}'; exit 0
      fi
      if [ -n "${FAKE_ADMIN_TOKEN:-}" ] && [ "$hdr" = "Authorization: Bearer $FAKE_ADMIN_TOKEN" ]; then
        [ "$code_only" = "1" ] && { say 200; exit 0; }
        say '{"legs":[]}'; exit 0
      fi
      # A host with a token file answers 401 to a request that carries none; a host without one
      # answers 404. Both are closed; FAKE_ADMIN_CODE picks which one this scenario stands for.
      [ "$code_only" = "1" ] && { say "${FAKE_ADMIN_CODE:-404}"; exit 0; }
      say '{"error":{"type":"not_found","message":"no such path"}}'; exit 0 ;;
    *)
      [ "$code_only" = "1" ] && { say 404; exit 0; }
      exit 0 ;;
  esac
fi
if [ "${url#*"$FAKE_EDGE_URL"}" != "$url" ]; then
  # FAKE_EDGE_SECURITY=0 replays the origin as it answered before 2026-11-21: no HSTS at all,
  # which is what a site block that does not import the host's (security) snippet looks like.
  if [ "${FAKE_EDGE_SECURITY:-1}" = "1" ] && [ "$dump_headers" = "1" ]; then
    printf 'HTTP/2 200 \n'
    printf 'strict-transport-security: max-age=31536000; includeSubDomains\n'
    printf 'x-frame-options: DENY\n'
    printf 'referrer-policy: strict-origin-when-cross-origin\n'
    printf '\n'
    exit 0
  fi
  case "$url" in
    */admin/state)
      [ "$hdr" = "Authorization: Bearer $FAKE_GOOD_TOKEN" ] && { say 404; exit 0; }
      say 401; exit 0 ;;
    */v1/chat/completions)
      if [ "$hdr" = "Authorization: Bearer $FAKE_GOOD_TOKEN" ]; then
        if [ "$code_only" = "1" ]; then say "${FAKE_V1_CODE:-405}"; exit 0; fi
        say "${FAKE_V1_BODY-{\"error\":\"method not allowed\"}}"; exit 0
      fi
      if [ "${FAKE_EDGE_MODE:-strict}" = "leaky" ] && [ -n "$hdr" ]; then say 200; exit 0; fi
      say 401; exit 0 ;;
    *)
      if [ "$hdr" = "Authorization: Bearer $FAKE_GOOD_TOKEN" ]; then say 200; exit 0; fi
      if [ "${FAKE_EDGE_MODE:-strict}" = "leaky" ] && [ -n "$hdr" ]; then say 200; exit 0; fi
      say 401; exit 0 ;;
  esac
fi
say 000
STUB

cat >"$BIN/ss" <<'STUB'
#!/usr/bin/env bash
printf 'ss %s\n' "$*" >>"${SMOKE_STATE:?}/calls.log"
case "${FAKE_BIND:-loopback}" in
  loopback) printf 'State  Recv-Q  Send-Q  Local Address:Port\nLISTEN 0 4096 127.0.0.1:8787 0.0.0.0:*\n' ;;
  wildcard) printf 'LISTEN 0 4096 0.0.0.0:8787 0.0.0.0:*\n' ;;
  nothing) printf 'State  Recv-Q  Send-Q\n' ;;
esac
STUB

cat >"$BIN/stat" <<'STUB'
#!/usr/bin/env bash
S="${SMOKE_STATE:?}"
f="${3:-${2:-}}"
n="$(wc -c <"$f" | tr -d ' ')"
printf 'stat\n' >>"$S/calls.log"
if [ "${FAKE_SHRINK:-0}" = "1" ] && [ -f "$S/stat_once" ]; then
  printf '%s\n' "$((n - 10))"; exit 0
fi
: >"$S/stat_once"
printf '%s\n' "$n"
STUB

chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export SMOKE_STATE="$STATE"

reset_state() {
  : >"$STATE/calls.log"
  rm -f "$STATE/stat_once"
  printf '{"ts":"2026-11-15T23:00:00Z","route":"opencode-go","status":200,"latency_ms":412,"tokens_in":11,"tokens_out":22,"failover_reason":null}\n' >"$LOG_FILE"
}

run() {
  KORI_APP_DIR="$APP_DIR" KORI_LOG_FILE="$LOG_FILE" \
    KORI_EDGE_URL="${1:-}" KORI_EDGE_TOKEN="${2:-}" KORI_ADMIN_TOKEN="${3:-}" \
    bash "$SMOKE" >"$ROOT/out.txt" 2>&1
  echo $?
}
oks() { grep -c '^OK ' "$ROOT/out.txt" || true; }

# ── scenario 1: everything wired and healthy -> exit 0, full edge matrix ────
# No admin token set: the host stands where a fresh deploy does, so the gate must prove the
# 404 branch rather than assume an authenticated surface it never tested.
reset_state
rc="$(run "$FAKE_EDGE_URL" "$FAKE_GOOD_TOKEN")"
[ "$rc" = "0" ] && pass "healthy host exits 0" || fail "healthy host exited $rc: $(cat "$ROOT/out.txt")"
[ "$(oks)" = "10" ] && pass "10 OK lines: healthz, admin 404, loopback, log, JSON, 5 edge" \
  || fail "expected 10 OK lines, got $(oks): $(tr '\n' '|' <"$ROOT/out.txt")"
grep -q 'GET /healthz 200, valid JSON' "$ROOT/out.txt" && pass "the health probe is /healthz" \
  || fail "the health probe is not /healthz: $(tr '\n' '|' <"$ROOT/out.txt")"
grep -q 'GET /admin/state without a token -> 404 (no token file, fail closed)' "$ROOT/out.txt" \
  && pass "no token, no token file: /admin/state -> 404 is asserted, not skipped" \
  || fail "the fail-closed branch is not asserted"
grep -q 'edge without bearer -> 401' "$ROOT/out.txt" && pass "edge refuses a missing bearer" \
  || fail "missing-bearer check absent"
grep -q 'edge refuses /admin/state -> 404' "$ROOT/out.txt" && pass "edge refuses /admin from outside" \
  || fail "/admin edge check absent"
grep -q 'edge answers with Strict-Transport-Security' "$ROOT/out.txt" \
  && pass "the security headers are asserted, not assumed" \
  || fail "no assertion that the edge sends HSTS"
grep -q "Bearer $FAKE_GOOD_TOKEN" "$STATE/calls.log" \
  && fail "the edge token reached curl argv, where /proc/<pid>/cmdline exposes it" \
  || pass "the edge token never reaches curl argv"
grep -q "Bearer $FAKE_ADMIN_TOKEN" "$STATE/calls.log" \
  && fail "the admin token reached curl argv" \
  || pass "no admin token in argv (none was set in this scenario)"

# ── scenario 1b: admin token set -> the authenticated branch proves 200 twice ─
reset_state
rc="$(run "$FAKE_EDGE_URL" "$FAKE_GOOD_TOKEN" "$FAKE_ADMIN_TOKEN")"
[ "$rc" = "0" ] && pass "admin-token run exits 0" || fail "admin-token run exited $rc: $(cat "$ROOT/out.txt")"
grep -q 'GET /admin/state with the admin bearer -> 200' "$ROOT/out.txt" \
  && pass "/admin/state with the admin bearer -> 200" \
  || fail "/admin/state authenticated check missing: $(tr '\n' '|' <"$ROOT/out.txt")"
grep -q 'GET /metrics with the admin bearer -> 200' "$ROOT/out.txt" \
  && pass "/metrics with the admin bearer -> 200" || fail "/metrics authenticated check missing"
grep -q "Bearer $FAKE_ADMIN_TOKEN" "$STATE/calls.log" \
  && fail "the admin token reached curl argv, where /proc/<pid>/cmdline exposes it" \
  || pass "the admin token never reaches curl argv"
grep -q 'GET /healthz 200, valid JSON' "$ROOT/out.txt" \
  && pass "the health probe stays open with a token configured" \
  || fail "the health probe needs a credential now"

# ── scenario 1c: the binary answers the admin surface with no credential -> FAIL
# This is the whole point of DEC-20. If /admin/state answers 200 to a request that carries
# nothing, the gate is decorative and the smoke has to say so.
reset_state
export FAKE_ADMIN_OPEN=1
rc="$(run "" "")"
unset FAKE_ADMIN_OPEN
[ "$rc" != "0" ] && pass "an open admin surface exits non-zero ($rc)" \
  || fail "an open admin surface passed the release gate"
grep -q 'GET /admin/state without a token -> 200' "$ROOT/out.txt" \
  && pass "the open admin surface is named" || fail "the open admin surface is not named"

# ── scenario 1d: token file present, no bearer -> 401 must PASS and say so ──
# The other closed answer. On the host the binary reads /etc/kori/admin.token, so once the
# operator creates it an unauthenticated request gets 401, not 404. A gate that demanded 404
# would red on a correctly configured host. It must pass, and it must name which code it saw.
reset_state
export FAKE_ADMIN_CODE=401
rc="$(run "" "")"
unset FAKE_ADMIN_CODE
[ "$rc" = "0" ] && pass "a 401 without an admin bearer exits 0 ($rc)" \
  || fail "a 401 on /admin/state failed a correctly configured host"
grep -q 'GET /admin/state without a token -> 401 (token file present, no bearer sent)' "$ROOT/out.txt" \
  && pass "the 401 branch is named (token file present, no bearer sent)" \
  || fail "the 401 branch is not named: $(tr '\n' '|' <"$ROOT/out.txt")"

# ── scenario 1e: the token comes from the file, not from the env ───────────
# The host sets no KORI_ADMIN_TOKEN: this deploy's env file is the container's EnvironmentFile, so a
# copy of the token there would sit in the container's process environment. smoke.sh reads the file
# the binary reads instead, and the authenticated branch must light up from it alone.
reset_state
mkdir -p "$APP_DIR/etc"
printf '%s\n' "$FAKE_ADMIN_TOKEN" >"$APP_DIR/etc/admin.token"
chmod 600 "$APP_DIR/etc/admin.token"
rc="$(run "" "")"
[ "$rc" = "0" ] && pass "token from the file: run exits 0 ($rc)" \
  || fail "token from the file: run exited $rc: $(tr '\n' '|' <"$ROOT/out.txt")"
grep -q "admin checks use the token from $APP_DIR/etc/admin.token" "$ROOT/out.txt" \
  && pass "the gate names the token file as its source" \
  || fail "the gate does not name the token file: $(tr '\n' '|' <"$ROOT/out.txt")"
grep -q 'GET /admin/state with the admin bearer -> 200' "$ROOT/out.txt" \
  && pass "the file token drives the authenticated check" \
  || fail "the file token does not drive the authenticated check"
grep -q "Bearer $FAKE_ADMIN_TOKEN" "$STATE/calls.log" \
  && fail "the file token reached curl argv" \
  || pass "the file token never reaches curl argv"
rm -f "$APP_DIR/etc/admin.token"

# ── scenario 1f: an unexpected status is still a FAIL, not a shrug ──────────
# Anything outside {404, 401, 200} — a 500, a proxy's 502, a 000 on a dead socket — is not a
# closed admin surface, it is a broken one, and the gate must not read it as either.
reset_state
export FAKE_ADMIN_CODE=500
rc="$(run "" "")"
unset FAKE_ADMIN_CODE
[ "$rc" != "0" ] && pass "a 500 on /admin/state exits non-zero ($rc)" \
  || fail "a 500 on /admin/state passed the release gate"
grep -q 'GET /admin/state without a token -> 500 (expected 404 or 401)' "$ROOT/out.txt" \
  && pass "the unexpected status is named" || fail "the unexpected status is not named"

# ── scenario 2: local run, edge not wired yet -> 0 with a warning ───────────
reset_state
rc="$(run "" "")"
[ "$rc" = "0" ] && pass "no edge configured exits 0" || fail "no-edge run exited $rc"
grep -q '^WARN' "$ROOT/out.txt" && pass "skipped edge checks are announced as WARN" \
  || fail "no WARN line for skipped edge checks"

# ── scenario 3: half-configured edge must FAIL, not skip ───────────────────
reset_state
rc="$(run "$FAKE_EDGE_URL" "")"
[ "$rc" != "0" ] && pass "edge URL without token exits non-zero ($rc)" \
  || fail "edge URL without token exited 0 (release gate fail-open)"
grep -q 'KORI_EDGE_TOKEN is empty' "$ROOT/out.txt" && pass "half-configured edge says why" \
  || fail "half-configured edge message missing"

# ── scenario 4: health endpoint silent -> FAIL ─────────────────────────────
reset_state
export FAKE_STATE=empty
rc="$(run "$FAKE_EDGE_URL" "$FAKE_GOOD_TOKEN")"
unset FAKE_STATE
[ "$rc" != "0" ] && pass "silent /healthz exits non-zero" || fail "silent health exited 0"
grep -q 'FAIL GET /healthz did not answer' "$ROOT/out.txt" && pass "silent health is named" \
  || fail "silent health not named"

# ── scenario 5: health answers non-JSON -> FAIL ────────────────────────────
reset_state
export FAKE_STATE=notjson
rc="$(run "" "")"
unset FAKE_STATE
[ "$rc" != "0" ] && pass "non-JSON health exits non-zero" || fail "non-JSON health exited 0"
grep -q 'GET /healthz answered but the body is not JSON' "$ROOT/out.txt" \
  && pass "the non-JSON health body is named" || fail "the non-JSON health body is not named"

# ── scenario 6: port published on 0.0.0.0 -> FAIL ──────────────────────────
reset_state
export FAKE_BIND=wildcard
rc="$(run "" "")"
unset FAKE_BIND
[ "$rc" != "0" ] && pass "wildcard publish exits non-zero" || fail "wildcard publish exited 0"
grep -q 'published on a non-loopback address' "$ROOT/out.txt" && pass "wildcard publish is named" \
  || fail "wildcard publish not named"

# ── scenario 7: nothing listening on the port -> FAIL ──────────────────────
reset_state
export FAKE_BIND=nothing
rc="$(run "" "")"
unset FAKE_BIND
[ "$rc" != "0" ] && pass "no listener exits non-zero" || fail "no listener exited 0"

# ── scenario 8: request log shrank -> FAIL ─────────────────────────────────
reset_state
export FAKE_SHRINK=1
rc="$(run "" "")"
unset FAKE_SHRINK
[ "$rc" != "0" ] && pass "shrinking log exits non-zero" || fail "shrinking log exited 0"
grep -q 'request log shrank' "$ROOT/out.txt" && pass "shrinking log is named" || fail "shrink not named"

# ── scenario 9: last log line is not JSON -> FAIL ──────────────────────────
reset_state
printf 'route=opencode-go status=200\n' >"$LOG_FILE"
rc="$(run "" "")"
[ "$rc" != "0" ] && pass "unparseable log line exits non-zero" || fail "unparseable log line exited 0"
grep -q 'last log line is not valid JSON' "$ROOT/out.txt" && pass "unparseable line is named" \
  || fail "unparseable line not named"

# ── scenario 10: log file missing -> FAIL ──────────────────────────────────
reset_state
rm -f "$LOG_FILE"
rc="$(run "" "")"
[ "$rc" != "0" ] && pass "missing log exits non-zero" || fail "missing log exited 0"

# ── scenario 11: edge accepts a wrong bearer -> FAIL (token not enforced) ──
reset_state
export FAKE_EDGE_MODE=leaky
rc="$(run "$FAKE_EDGE_URL" "$FAKE_GOOD_TOKEN")"
unset FAKE_EDGE_MODE
[ "$rc" != "0" ] && pass "leaky bearer gate exits non-zero" || fail "leaky bearer gate exited 0"
grep -q 'edge with wrong bearer -> 200' "$ROOT/out.txt" && pass "leaky bearer gate is named" \
  || fail "leaky bearer gate not named"

# ── scenario 12: the v1 chat path answers 200 to a GET -> FAIL ─────────────
# v1 has no GET route, so a 200 here means the edge is answering something that is not kori.
reset_state
export FAKE_V1_CODE=200
rc="$(run "$FAKE_EDGE_URL" "$FAKE_GOOD_TOKEN")"
unset FAKE_V1_CODE
[ "$rc" != "0" ] && pass "GET on the v1 chat path answering 200 exits non-zero" \
  || fail "a GET on the v1 chat path answered 200 and the smoke still passed"
grep -q 'edge with right bearer -> 200 (expected 405)' "$ROOT/out.txt" \
  && pass "the 405 expectation is named" || fail "the 405 expectation is not named"

# ── scenario 13: a 405 that is not kori's -> FAIL ─────────────────────────
# Any proxy or error page in front of the origin can answer 405. Without the body check this
# scenario went green against an nginx error page (gate finding, 2026-11-16).
reset_state
export FAKE_V1_BODY='<html><head><title>405 Not Allowed</title></head><body><center><h1>405 Not Allowed</h1></center><hr><center>nginx</center></body></html>'
rc="$(run "$FAKE_EDGE_URL" "$FAKE_GOOD_TOKEN")"
unset FAKE_V1_BODY
[ "$rc" != "0" ] && pass "a foreign 405 body exits non-zero" || fail "a foreign 405 body passed the edge matrix"
grep -q "the body is not kori's" "$ROOT/out.txt" && pass "the foreign 405 body is named" \
  || fail "foreign 405 body not named"

# ── scenario 14: an edge without HSTS -> FAIL ────────────────────────────
# The measured state of ai.qouver.com until 2026-11-21: the block did not import the host's
# (security) snippet, so Cloudflare forwarded a response with no Strict-Transport-Security, no
# X-Frame-Options and no Referrer-Policy. A gate that only checks status codes calls that healthy.
reset_state
export FAKE_EDGE_SECURITY=0
rc="$(run "$FAKE_EDGE_URL" "$FAKE_GOOD_TOKEN")"
unset FAKE_EDGE_SECURITY
[ "$rc" != "0" ] && pass "an edge without HSTS exits non-zero ($rc)" \
  || fail "an edge without HSTS passed the release gate"
grep -q 'edge answers without Strict-Transport-Security' "$ROOT/out.txt" \
  && pass "the missing HSTS header is named" || fail "the missing HSTS header is not named"

printf '\n%s\n' "artifacts: $ROOT"
if [ "$FAILS" -eq 0 ]; then
  printf 'RESULT: all scenarios passed\n'
  exit 0
fi
printf 'RESULT: %s check(s) failed\n' "$FAILS"
exit 1
