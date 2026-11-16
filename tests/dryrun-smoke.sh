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

cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
S="${SMOKE_STATE:?}"
printf 'curl %s\n' "$*" >>"$S/calls.log"
code_only=0; hdr=""; url=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    -w) code_only=1; shift 2 ;;
    -H) hdr="$2"; shift 2 ;;
    -K|--config) cfg="$2"; shift 2 ;;
    -o|--max-time|-s|-f|-S) shift 2 2>/dev/null || shift 1 ;;
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
  # loopback admin endpoint
  if [ "$code_only" = "1" ]; then say 200; exit 0; fi
  case "${FAKE_STATE:-ok}" in
    empty) exit 22 ;;
    notjson) say 'not json at all'; exit 0 ;;
    *) say '{"legs":[]}' ;;
  esac
  exit 0
fi
if [ "${url#*"$FAKE_EDGE_URL"}" != "$url" ]; then
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
    KORI_EDGE_URL="${1:-}" KORI_EDGE_TOKEN="${2:-}" \
    bash "$SMOKE" >"$ROOT/out.txt" 2>&1
  echo $?
}
oks() { grep -c '^OK ' "$ROOT/out.txt" || true; }

# ── scenario 1: everything wired and healthy -> exit 0, full edge matrix ────
reset_state
rc="$(run "$FAKE_EDGE_URL" "$FAKE_GOOD_TOKEN")"
[ "$rc" = "0" ] && pass "healthy host exits 0" || fail "healthy host exited $rc: $(cat "$ROOT/out.txt")"
[ "$(oks)" = "8" ] && pass "8 OK lines: state, loopback, log, JSON, 4 edge" \
  || fail "expected 8 OK lines, got $(oks): $(tr '\n' '|' <"$ROOT/out.txt")"
grep -q 'edge without bearer -> 401' "$ROOT/out.txt" && pass "edge refuses a missing bearer" \
  || fail "missing-bearer check absent"
grep -q 'edge refuses /admin/state -> 404' "$ROOT/out.txt" && pass "edge refuses /admin from outside" \
  || fail "/admin edge check absent"
grep -q "Bearer $FAKE_GOOD_TOKEN" "$STATE/calls.log" \
  && fail "the edge token reached curl argv, where /proc/<pid>/cmdline exposes it" \
  || pass "the edge token never reaches curl argv"

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

# ── scenario 4: state endpoint silent -> FAIL ──────────────────────────────
reset_state
export FAKE_STATE=empty
rc="$(run "$FAKE_EDGE_URL" "$FAKE_GOOD_TOKEN")"
unset FAKE_STATE
[ "$rc" != "0" ] && pass "silent /admin/state exits non-zero" || fail "silent state exited 0"
grep -q 'FAIL GET /admin/state did not answer' "$ROOT/out.txt" && pass "silent state is named" \
  || fail "silent state not named"

# ── scenario 5: state answers non-JSON -> FAIL ─────────────────────────────
reset_state
export FAKE_STATE=notjson
rc="$(run "" "")"
unset FAKE_STATE
[ "$rc" != "0" ] && pass "non-JSON state exits non-zero" || fail "non-JSON state exited 0"

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

printf '\n%s\n' "artifacts: $ROOT"
if [ "$FAILS" -eq 0 ]; then
  printf 'RESULT: all scenarios passed\n'
  exit 0
fi
printf 'RESULT: %s check(s) failed\n' "$FAILS"
exit 1
