#!/bin/sh
# A20 — a log file the process lost is reopened by path, and the line lands (2026-11-21).
#
#   a20a  a rotation that cannot reopen the file leaves no fd behind
#   a20b  every append retries the open, and the outage is one stderr line
#   a20c  the next append after recovery reopens by path and the line lands
#   a20d  the counter and the page agree on what was lost and what was kept
#
# BE-1/BE-2 on `main` fixed the fd to -1 when a rotation could not reopen, and
# retried the open on every append. `tests/unit/test_kori.nim` covers the reopen
# in isolation; this case drives it over the wire, because the hazard was in the
# process, not in the proc.
#
# The failure is induced by taking the log's directory away (a mount that dropped,
# a directory renamed under the process): the rotation finds nothing to move, the
# reopen answers ENOENT, and the fd is -1 rather than some number the next `open`
# in the process would inherit.
#
# Both guards were reverted on purpose to prove this case red, one at a time:
# leaving the closed fd in place (the gateway then died on the first request after
# recovery: 13 passed, 8 failed) and dropping the retry in `appendLine` (16 passed,
# 5 failed on the recovery half). The clean build is green below.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

LOGDIR="$RUN/logdir"
JLOG="$LOGDIR/gateway.jsonl"
JLOG_AWAY="$LOGDIR.gone"

# This case owns its log path, so it reads it itself instead of `log_count`,
# which is fixed to the shared $GW_LOG.
jlog_count() { if [ -f "$JLOG" ]; then wc -l <"$JLOG" | tr -d ' '; else echo 0; fi; }
log_failures() { # log_failures -> the counter's value, or empty when it is absent
  admin_get "$RUN/a20-metrics.txt" /metrics >/dev/null 2>&1
  awk '$1 == "kori_log_write_failures_total" { print $2; found = 1 }
       END { if (!found) print "" }' "$RUN/a20-metrics.txt"
}
stderr_count() { grep -c "$1" "$RUN/gateway.log" 2>/dev/null || echo 0; }
# The reload is waited for by its own counter, never by the value it carried: a
# reload that was refused leaves the counter where it was and must fail here.
reload_count() { admin_get "$RUN/a20-cfg.json" '/admin/config' >/dev/null 2>&1 || true
  jq -r '.reload.count // 0' "$RUN/a20-cfg.json" 2>/dev/null; }
reload() { # reload <rotate-bytes> -> rewrite the policy and wait for it to apply
  before=$(reload_count)
  python3 - "$GW_CFG" "$1" "$JLOG" <<'PY'
import json, sys
path, rotate, log = sys.argv[1], int(sys.argv[2]), sys.argv[3]
cfg = json.load(open(path))
cfg["log"]["path"] = log
cfg["log"]["rotate_bytes"] = rotate
json.dump(cfg, open(path, "w"), indent=2)
PY
  kill -HUP "$pid"
  i=0
  while [ $i -lt 100 ]; do
    [ "$(reload_count)" != "$before" ] && break
    i=$((i + 1)); sleep 0.05
  done
}

mkdir -p "$LOGDIR"
jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/a20-req.json"

gw_stop; stub_kill leg-a 18096
stub leg-a 18096 ok
write_config "leg-a|http://127.0.0.1:18096/v1|key-leg-a|"
# Rotation stays off until two lines are on disk, so the case decides when it arms.
python3 - "$GW_CFG" "$JLOG" <<'PY'
import json, sys
path, log = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
cfg["log"]["path"] = log
cfg["log"]["rotate_bytes"] = 0
json.dump(cfg, open(path, "w"), indent=2)
PY
gw_start
pid=$(pgrep -f -- "--config $GW_CFG" | head -n 1)
assert_ne "A20 the gateway pid is known" "$pid" ""

req a20-seed-1 "$RUN/a20-req.json"
req a20-seed-2 "$RUN/a20-req.json"
assert_eq "A20 two requests wrote two lines" "$(jlog_count)" "2"
failures_before=$(log_failures)
assert_ne "A20 the counter is published" "$failures_before" ""

echo
echo "=== A20a: a rotation that cannot reopen the file leaves no fd behind"
# One line is ~150 bytes, so 100 bytes arms a rotation on the very next append.
reload 100
mv "$LOGDIR" "$JLOG_AWAY"
dials_before=$(dials leg-a)
req a20-lost-1 "$RUN/a20-req.json"
assert_eq "A20a the request is served while its line is lost" \
  "$(http_code a20-lost-1)" "200"
# The route cannot be read off the log here, because the log is the thing this
# case is losing: the stub's own dial counter is what proves it was served.
assert_eq "A20a it was served by the leg, not refused" \
  "$(dials leg-a)" "$((dials_before + 1))"
assert_eq "A20a the rotation named the reopen it could not do" \
  "$(stderr_count 'cannot reopen log after rotation')" "1"
assert_eq "A20a no line reached the file it lost" "$(jlog_count)" "0"
assert_eq "A20a the lost line is counted" \
  "$(log_failures)" "$((failures_before + 1))"

echo
echo "=== A20b: every append retries the open, and the outage is one stderr line"
req a20-lost-2 "$RUN/a20-req.json"
assert_eq "A20b the second lost line is counted too" \
  "$(log_failures)" "$((failures_before + 2))"
assert_eq "A20b the outage is reported once, not per request" \
  "$(stderr_count 'request log is not being written')" "1"
assert_eq "A20b still no line reached the file" "$(jlog_count)" "0"

echo
echo "=== A20c: the next append after recovery reopens by path"
# Rotation is disarmed first, so the recovery this grades is the append's own
# reopen and not a successful rotation that would have moved the file aside.
reload 0
mv "$JLOG_AWAY" "$LOGDIR"
req a20-recovered "$RUN/a20-req.json"
assert_eq "A20c the recovered request answered 200" "$(http_code a20-recovered)" "200"
assert_eq "A20c exactly one line landed in the file it lost" "$(jlog_count)" "3"
assert_eq "A20c the recovered line is whole JSON" \
  "$(tail -n 1 "$JLOG" | jq -r 'type')" "object"
assert_eq "A20c the recovered line carries the request's route" \
  "$(tail -n 1 "$JLOG" | jq -r '.route')" "leg-a"
assert_eq "A20c the recovery is reported once" \
  "$(stderr_count 'request log is being written again')" "1"
assert_eq "A20c a line that landed is not counted as lost" \
  "$(log_failures)" "$((failures_before + 2))"
# The earlier lines are still the earlier lines: the reopen appended, it did not
# start over. Without the -1 fix the fd number would have gone to whatever the
# process opened next, and this count would be wrong in a way nothing else sees.
assert_eq "A20c the two lines from before the outage are still first" \
  "$(head -n 2 "$JLOG" | jq -s -r 'map(.route) | join(",")')" "leg-a,leg-a"

echo
echo "=== A20d: the counter and the page agree on what was lost and kept"
assert_eq "A20d /admin/log reports the file's own line count" \
  "$(admin_get "$RUN/a20-log.json" '/admin/log' >/dev/null; \
     jq -r '.file.lines' "$RUN/a20-log.json")" "3"
assert_eq "A20d the page shows the recovered line" \
  "$(log_row "$RUN/a20-log.json" 0 ts)" "$(tail -n 1 "$JLOG" | jq -r '.ts')"
assert_eq "A20d the page keeps the lines from before the outage" \
  "$(log_row_count "$RUN/a20-log.json")" "3"

kill_stubs
finish
