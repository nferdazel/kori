#!/bin/sh
# A18 — a request log that cannot be written is visible in /metrics (2026-11-21).
#
#   a18a  a request whose line never reaches the file still answers 200
#   a18b  kori_log_write_failures_total counts every lost line
#   a18c  the log file gains no line, and /admin/log keeps reporting the file
#   a18d  an outage is one stderr line, not one per request
#
# The failure is induced with a file-size limit: the log is seeded past it, so the
# next write(2) comes back short. That is the same shape as ENOSPC — the gateway
# keeps serving and stops recording — and it needs no root, no full disk and no
# tmpfs. macOS lets one append squeeze past the limit before it starts refusing,
# so the first request is a probe and every assertion after it is relative.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

log_failures() { # log_failures -> the counter's value, or empty when it is absent
  admin_get "$RUN/a18-metrics.txt" /metrics >/dev/null 2>&1
  awk '$1 == "kori_log_write_failures_total" { print $2; found = 1 }
       END { if (!found) print "" }' "$RUN/a18-metrics.txt"
}

gw_stop; stub_kill leg-a 18091
stub leg-a 18091 ok
write_config "leg-a|http://127.0.0.1:18091/v1|key-leg-a|"

echo
echo "=== A18: a log target that cannot take another line"
# Well past any `ulimit -f 1` (512 bytes on BSD, 1 KiB on Linux), so the cap is
# already exceeded when the gateway opens the file.
seed_log 60
rm -f "$RUN/a18-metrics.txt"
GW_FSIZE_BLOCKS=1 gw_start

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/a18-req.json"

echo
echo "=== A18a: the request is served, not failed"
# The platform's remaining room past the cap is spent here, whatever it is, so
# the state this case grades starts from the next request.
dials_before=$(dials leg-a)
req a18-probe "$RUN/a18-req.json"
assert_eq "A18a the request answered 200" "$(http_code a18-probe)" "200"
# The route cannot be read off the log, because the log is the thing this case
# breaks and whether this line lands is platform-specific: BSD still lets one
# append squeeze past the cap, Linux refuses it outright, and the last line is
# then a seeded one. The stub's dial count proves the leg served it on both.
assert_eq "A18a it was served by the leg" "$(dials leg-a)" "$((dials_before + 1))"
lines_before=$(log_count)
failures_before=$(log_failures)
assert_ne "A18b the counter is published" "$failures_before" ""
# No room is left for one more line, or the rest of the case proves nothing.
req a18-room "$RUN/a18-req.json"
assert_eq "A18a the log target refuses the next line" \
  "$([ "$(log_count)" -eq "$lines_before" ] && echo refused || echo accepted)" "refused"
lines_before=$(log_count)
failures_before=$(log_failures)

echo
echo "=== A18b: every lost line moves the counter"
req a18-1 "$RUN/a18-req.json"
assert_eq "A18b the first lost line is counted" \
  "$(log_failures)" "$((failures_before + 1))"
req a18-2 "$RUN/a18-req.json"
assert_eq "A18b the second lost line is counted" \
  "$(log_failures)" "$((failures_before + 2))"
req a18-3 "$RUN/a18-req.json"
assert_eq "A18b the third lost line is counted" \
  "$(log_failures)" "$((failures_before + 3))"

echo
echo "=== A18c: nothing was written, and the page reads the file"
assert_eq "A18c the log file gained no line" "$(log_count)" "$lines_before"
assert_eq "A18c /admin/log reports the file's real count" \
  "$(admin_get "$RUN/a18-log.json" /admin/log >/dev/null; \
     jq -r '.file.lines' "$RUN/a18-log.json")" "$lines_before"
# The window count moves, because these requests were served; the file count is
# the one that must not, or a dashboard would report lines nobody can read.
assert_eq "A18c the window still counted the served requests" \
  "$(admin_json "$RUN/a18-state.json" >/dev/null; \
     jq -r '.window.requests' "$RUN/a18-state.json")" "5"

echo
echo "=== A18d: an outage is one stderr line, not one per request"
assert_eq "A18d one line per outage, not per request" \
  "$(grep -c 'request log is not being written' "$RUN/gateway.log" 2>/dev/null || echo 0)" "1"

kill_stubs
finish
