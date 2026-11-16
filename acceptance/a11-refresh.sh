#!/bin/sh
# A11 — SPEC §4: the OAuth credential refresh, proven by forcing it to work and
# forcing it to fail. The token endpoint and the provider are both stubs on
# 127.0.0.1; nothing here reads a real credential.
#
# a  an expired token is refreshed before the dial: one token call, the provider
#    accepts only the new bearer, 200, one log line.
# b  the token endpoint answers 400, then 500: 502 credential_refresh_failed, the
#    provider is never dialled, no fallback is dialled, no stale bearer is sent.
# c  the token endpoint hangs: 502 refresh_timeout inside the refresh deadline.
# d  eight concurrent requests make exactly one token call.
# e  the refreshed credential lands in the config at 0600 with every other line
#    unchanged, and a restart spends no token call.
# f  the log, stderr and /admin/config carry no token value.
# g  a 401 on a leg whose expiry is unknown buys one refresh and one retry.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

OLD_TOKEN="acc-OLD-expired-access-token"
NEW_TOKEN="acc-NEW-refreshed-access-token"
ROTATED="acc-ROTATED-refresh-token"
SEED_REFRESH="acc-seed-refresh-token"
CLIENT_ID="kori-acc-client"

# The config carries the `oauth` block that a1-a10 deliberately never write.
# Written in the same shape gw_start re-serialises (indent 2, one key per line),
# so a byte comparison before and after a refresh is meaningful.
config_write() { # config_write <expires-at-epoch|0> [leg-a-extra-json]
  python3 - "$GW_CFG" "$GW_HOST" "$GW_PORT" "$GW_LOG" "$1" \
    "$(port_of 18095)" "$(port_of 18091)" "$(port_of 18092)" \
    "$OLD_TOKEN" "$SEED_REFRESH" "$CLIENT_ID" <<'PY'
import json, sys
(path, host, port, log, expires, token_port, leg_a, leg_b,
 old, refresh, cid) = sys.argv[1:]
oauth = {
    "token_url": "http://127.0.0.1:%s/token" % token_port,
    "client_id": cid,
    "refresh_token": refresh,
    "access_token": old,
}
if int(expires) > 0:
    oauth["expires_at"] = int(expires)
cfg = {
    "listen": {"host": host, "port": int(port)},
    "log": {"path": log},
    "legs": [
        {"name": "leg-a", "base_url": "http://127.0.0.1:%s/v1" % leg_a,
         "oauth": oauth},
        {"name": "leg-b", "base_url": "http://127.0.0.1:%s/v1" % leg_b,
         "api_key": "key-leg-b", "role": "fallback"},
    ],
}
json.dump(cfg, open(path, "w"), indent=2)
PY
  chmod 600 "$GW_CFG"
}

past() { echo $(( $(date +%s) - 60 )); }

# gw_stop kills every stub as well as the gateway, so a restart is always followed
# by fresh stubs. `stub` also truncates its count file, so every sub-case counts
# its own dials.
boot() { # boot <token-stub-mode> [token-stub args...]
  token_mode=$1; shift
  gw_stop
  gw_start
  stub_kill tokenep 18095
  stub tokenep 18095 "$token_mode" "$@"
  stub_kill leg-a 18091
  stub leg-a 18091 ok --expect-bearer "$NEW_TOKEN"
  stub_kill leg-b 18092
  stub leg-b 18092 ok
  # wait_tcp's own probe connection can land in a count file a moment after the
  # stub resets it, so settle first and zero the three counters again.
  sleep 0.3
  stub_touch tokenep
  stub_touch leg-a
  stub_touch leg-b
}

# Which lines differ between two config snapshots, and whether every one of them
# is a line for an allowed key. A line count change is reported as a difference.
changed_lines_are() { # changed_lines_are <before> <after> <key,key,...>
  python3 - "$1" "$2" "$3" <<'PY'
import sys
before = open(sys.argv[1]).read().splitlines()
after = open(sys.argv[2]).read().splitlines()
allowed = sys.argv[3].split(",")
if len(before) != len(after):
    print("LINE-COUNT %d -> %d" % (len(before), len(after)))
    sys.exit(0)
bad = []
for number, (old, new) in enumerate(zip(before, after), start=1):
    if old == new:
        continue
    if any('"%s"' % key in old and '"%s"' % key in new for key in allowed):
        continue
    bad.append("%d: %s -> %s" % (number, old.strip(), new.strip()))
print("OK" if not bad else "BAD " + " | ".join(bad))
PY
}

json_field() { # json_field <file> <jq-filter>
  jq -r "$2" "$1"
}

echo "=== A11a: an expired token is refreshed before the dial"
config_write "$(past)"
boot token --token "$NEW_TOKEN" --rotate "$ROTATED"
jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"

before=$(log_count)
req a11a "$RUN/req-basic.json"
assert_eq "A11a the refreshed request is served"          "$(http_code a11a)" "200"
assert_eq "A11a the body is the provider's"               \
  "$(jq -r '.choices[0].message.content' "$RUN/a11a.body")" "STUB-OK"
assert_eq "A11a exactly one token call"                   "$(dials tokenep)" "1"
assert_eq "A11a the provider was dialled once"            "$(dials leg-a)" "1"
assert_eq "A11a the fallback was never dialled"           "$(dials leg-b)" "0"
assert_one_line "A11a" "$before"
assert_log   "A11a the answering route"                   '.route' 'leg-a'
assert_log   "A11a the status"                            '.status' '200'
assert_log   "A11a no failover is claimed"                '.failover_from' ''
assert_log   "A11a no failover reason is claimed"         '.failover_reason' ''
assert_log_keys "A11a"
assert_present "A11a the token call was a refresh grant"  "$RUN/tokenep.req" "grant_type=refresh_token"
assert_present "A11a the token call named the client"     "$RUN/tokenep.req" "client_id=$CLIENT_ID"
assert_present "A11a the token call carried the seed"     "$RUN/tokenep.req" "refresh_token=$SEED_REFRESH"
assert_absent  "A11a the token call carried no secret"    "$RUN/tokenep.req" "client_secret"

echo
echo "=== A11b: a token endpoint that refuses stops the request"
for status in 400 500; do
  config_write "$(past)"
  boot token --status "$status"
  before=$(log_count)
  req "a11b-$status" "$RUN/req-basic.json"
  assert_eq "A11b $status the caller gets 502"            "$(http_code "a11b-$status")" "502"
  assert_eq "A11b $status the error names the reason"     \
    "$(jq -r '.error.type' "$RUN/a11b-$status.body")" "credential_refresh_failed"
  assert_eq "A11b $status the token endpoint was called"  "$(dials tokenep)" "1"
  assert_eq "A11b $status the provider was never dialled" "$(dials leg-a)" "0"
  assert_eq "A11b $status the fallback was never dialled" "$(dials leg-b)" "0"
  assert_one_line "A11b $status" "$before"
  assert_log "A11b $status the log names the route"       '.route' 'leg-a'
  assert_log "A11b $status the log names the reason"      '.failover_reason' 'credential_refresh_failed'
  assert_log "A11b $status no failover is claimed"        '.failover_from' ''
  assert_log "A11b $status both token counts are null"    '.tokens_in' 'null'
  admin_json "$RUN/a11b-$status.admin.json" >/dev/null
  assert_eq "A11b $status the leg is not put on cooldown" \
    "$(admin_count "$RUN/a11b-$status.admin.json" cooling)" "0"
  assert_eq "A11b $status no failover counter moved"      \
    "$(window_counter "$RUN/a11b-$status.admin.json" avail)" "0"
done

echo
echo "=== A11c: a token endpoint that hangs is a refresh timeout"
config_write "$(past)"
boot never
before=$(log_count)
req a11c "$RUN/req-basic.json"
assert_eq "A11c the caller gets 502"                      "$(http_code a11c)" "502"
assert_eq "A11c the error names the timeout"              \
  "$(jq -r '.error.type' "$RUN/a11c.body")" "refresh_timeout"
assert_between "A11c the refresh deadline is 5 s" "$(http_time a11c)" 4.5 9
assert_eq "A11c the provider was never dialled"           "$(dials leg-a)" "0"
assert_eq "A11c the fallback was never dialled"           "$(dials leg-b)" "0"
assert_one_line "A11c" "$before"
assert_log "A11c the log names the reason"                '.failover_reason' 'refresh_timeout'

echo
echo "=== A11d: eight concurrent requests make one token call"
config_write "$(past)"
boot token --token "$NEW_TOKEN" --rotate "$ROTATED"
pids=""
for i in 1 2 3 4 5 6 7 8; do
  ( curl -sS -o "$RUN/conc-$i.body" -w '%{http_code}' --max-time 60 \
      -X POST "$GW_URL/v1/chat/completions" \
      -H 'Content-Type: application/json' -H 'Expect:' \
      --data-binary "@$RUN/req-basic.json" >"$RUN/conc-$i.code" ) &
  pids="$pids $!"
done
for pid in $pids; do wait "$pid"; done
not200=0
for f in "$RUN"/conc-*.code; do
  [ "$(cat "$f")" = "200" ] || not200=$((not200 + 1))
done
assert_eq "A11d every concurrent request was served"      "$not200" "0"
assert_eq "A11d exactly one token call for eight requests" "$(dials tokenep)" "1"
assert_eq "A11d every request reached the provider"       "$(dials leg-a)" "8"

echo
echo "=== A11e: the refreshed credential is written back, and a restart spends nothing"
# A fresh expired config, then one request, so before and after are one refresh apart.
config_write "$(past)"
boot token --token "$NEW_TOKEN" --rotate "$ROTATED"
cp "$GW_CFG" "$RUN/cfg-before"
req a11e "$RUN/req-basic.json"
cp "$GW_CFG" "$RUN/cfg-after"
assert_eq "A11e the request was served"                   "$(http_code a11e)" "200"
assert_eq "A11e the config is still mode 0600"            "$(file_mode "$GW_CFG")" "600"
assert_eq "A11e the access token was replaced" \
  "$(json_field "$GW_CFG" '.legs[0].oauth.access_token')" "$NEW_TOKEN"
assert_eq "A11e the rotated refresh token was stored" \
  "$(json_field "$GW_CFG" '.legs[0].oauth.refresh_token')" "$ROTATED"
assert_eq "A11e the expiry moved into the future" \
  "$(jq -r '.legs[0].oauth.expires_at > now' "$GW_CFG")" "true"
assert_eq "A11e every other line is byte-identical" \
  "$(changed_lines_are "$RUN/cfg-before" "$RUN/cfg-after" 'access_token,refresh_token,expires_at')" "OK"
gw_restart
stub_kill tokenep 18095
stub tokenep 18095 token --token "$NEW_TOKEN"
stub_kill leg-a 18091
stub leg-a 18091 ok --expect-bearer "$NEW_TOKEN"
sleep 0.3
stub_touch tokenep
req a11e-restart "$RUN/req-basic.json"
assert_eq "A11e a restart serves from the stored token"   "$(http_code a11e-restart)" "200"
assert_eq "A11e a restart spends no token call"           "$(dials tokenep)" "0"

echo
echo "=== A11f: no token value reaches the log, stderr or /admin/config"
admin_get "$RUN/a11f-config.json" /admin/config >/dev/null
for secret in "$NEW_TOKEN" "$ROTATED" "$OLD_TOKEN" "$SEED_REFRESH"; do
  assert_absent "A11f the log carries no $secret"          "$GW_LOG" "$secret"
  assert_absent "A11f stderr carries no $secret"           "$RUN/gateway.log" "$secret"
  assert_no_credential "A11f /admin/config carries no $secret" "$RUN/a11f-config.json" "$secret"
done
assert_eq "A11f the oauth state is reported" \
  "$(json_field "$RUN/a11f-config.json" '.legs[0].oauth.state')" "set"
assert_eq "A11f the expiry is reported as epoch seconds" \
  "$(json_field "$RUN/a11f-config.json" '.legs[0].oauth.expires_at | type')" "number"
assert_eq "A11f a leg without oauth reports no oauth block" \
  "$(json_field "$RUN/a11f-config.json" '.legs[1] | has("oauth")')" "false"

echo
echo "=== A11g: a 401 on a leg with no known expiry buys one refresh and one retry"
config_write 0
boot token --token "$NEW_TOKEN" --rotate "$ROTATED"
req a11g "$RUN/req-basic.json"
assert_eq "A11g the retried request is served"            "$(http_code a11g)" "200"
assert_eq "A11g exactly one token call"                   "$(dials tokenep)" "1"
assert_eq "A11g the leg was dialled twice, not more"      "$(dials leg-a)" "2"
assert_eq "A11g the fallback was never dialled"           "$(dials leg-b)" "0"
assert_log "A11g the log names the answering route"       '.route' 'leg-a'
assert_log "A11g no failover is claimed"                  '.failover_from' ''
assert_log "A11g no failover reason is claimed"           '.failover_reason' ''
admin_json "$RUN/a11g.admin.json" >/dev/null
assert_eq "A11g the leg is not cooling after a recovered 401" \
  "$(admin_count "$RUN/a11g.admin.json" cooling)" "0"

kill_stubs
finish
