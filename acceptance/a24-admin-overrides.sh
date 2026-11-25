#!/bin/sh
# A24 — DEC-27: the provider/model switches.
#
# A24a the write surface has its own credential: no credential is 401, the read
#      token is 403, the write token is 200, and the response never carries a
#      credential value.
# A24b a toggle is written atomically: the config keeps mode 0600, a 0600 `.bak`
#      appears, the block is patched in place, and /admin/config reports the file
#      value, the override and the effective `serving` separately.
# A24c the switch is applied without a restart (uptime unchanged), and the reload
#      counter moves at the next quiet moment.
# A24d the last-leg guard refuses to leave zero providers without an explicit
#      confirm_last_leg; with it, every request answers 503 no_leg_enabled.
# A24e a model (alias) switch answers 400 alias_disabled while it is off.
# A24f a cookie write needs X-Kori-Write; the write session lives 12 h.
# A24g the override survives a restart, and a host with no write token answers 404.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

SENTINEL_KEY="SENTINEL-CREDENTIAL-DO-NOT-RENDER"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p | .model = "kori/jev"' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-alias.json"

put_overrides() { # put_overrides <outfile> <json> [curl args...]
  _po_out=$1; _po_body=$2; shift 2
  curl -sS -o "$_po_out" -w '%{http_code}' --max-time 5 -X PUT \
    -H 'Content-Type: application/json' --data-binary "$_po_body" \
    "$@" "$GW_URL/admin/overrides"
}

write_alias_config() {
  write_config "leg-a|http://127.0.0.1:18086/v1|$SENTINEL_KEY|" \
               "leg-b|http://127.0.0.1:18085/v1|$SENTINEL_KEY|"
  python3 - "$GW_CFG" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
for leg in cfg["legs"]:
    leg["aliases"] = {"jev": "jev-1.14"}
json.dump(cfg, open(path, "w"), indent=2)
PY
  chmod 600 "$GW_CFG"
}

gw_stop; stub_kill leg-a 18086; stub_kill leg-b 18085
stub leg-a 18086 ok
stub leg-b 18085 ok
write_alias_config
gw_start
uptime_before=$(curl -sS --max-time 5 -H "$(admin_token_header)" "$GW_URL/admin/state" | jq -r '.gateway.started_at')

echo "=== A24a: the write gate has its own credential"
assert_eq "A24a PUT with no credential is 401" \
  "$(put_overrides "$RUN/a24-none.json" '{"legs":{}}')" "401"
assert_eq "A24a PUT with the read token is 403" \
  "$(put_overrides "$RUN/a24-read.json" '{"legs":{}}' -H "$(admin_token_header)")" "403"
assert_eq "A24a the refusal names the missing write scope" \
  "$(jq -r '.error.type' "$RUN/a24-read.json")" "write_scope_required"
assert_eq "A24a PUT with the write token is 200" \
  "$(put_overrides "$RUN/a24-ok.json" '{"legs":{}}' -H "$(admin_write_header)")" "200"
assert_absent "A24a the response never renders a credential" \
  "$RUN/a24-ok.json" "$SENTINEL_KEY"
assert_absent "A24a the response never renders the token" \
  "$RUN/a24-ok.json" "$ADMIN_WRITE_TOKEN_VALUE"
assert_eq "A24a an unknown leg name is refused" \
  "$(put_overrides "$RUN/a24-typo.json" '{"legs":{"typo":false}}' -H "$(admin_write_header)")" "400"

echo
echo "=== A24b: atomic write, backup, and three separate states"
assert_eq "A24b switching leg-b off is 200" \
  "$(put_overrides "$RUN/a24-off.json" '{"legs":{"leg-b":false}}' -H "$(admin_write_header)")" "200"
assert_eq "A24b the config file is still 0600" "$(file_mode "$GW_CFG")" "600"
assert_eq "A24b a backup was written beside it" "$(test -f "$GW_CFG.bak" && echo yes)" "yes"
assert_eq "A24b the backup is 0600 too" "$(file_mode "$GW_CFG.bak")" "600"
assert_eq "A24b the file carries exactly one overrides block" \
  "$(jq -r '[.. | objects | select(has("overrides"))] | length' "$GW_CFG")" "1"
assert_eq "A24b the block names leg-b false" \
  "$(jq -r '.overrides.legs["leg-b"]' "$GW_CFG")" "false"
assert_eq "A24b the leg's own enabled is untouched" \
  "$(jq -r '.legs[] | select(.name=="leg-b") | .enabled' "$GW_CFG")" "null"
assert_eq "A24b the credential bytes are untouched" \
  "$(jq -r '.legs[0].api_key' "$GW_CFG")" "$SENTINEL_KEY"
admin_get "$RUN/a24-config.json" /admin/config >/dev/null
assert_eq "A24b the file value is still enabled" \
  "$(jq -r '.legs[] | select(.name=="leg-b") | .enabled' "$RUN/a24-config.json")" "true"
assert_eq "A24b the override is false" \
  "$(jq -r '.legs[] | select(.name=="leg-b") | .override' "$RUN/a24-config.json")" "false"
assert_eq "A24b the effective value is off" \
  "$(jq -r '.legs[] | select(.name=="leg-b") | .serving' "$RUN/a24-config.json")" "false"

echo
echo "=== A24c: applied without a restart"
assert_eq "A24c the gateway did not restart" \
  "$(curl -sS --max-time 5 -H "$(admin_token_header)" "$GW_URL/admin/state" | jq -r '.gateway.started_at')" "$uptime_before"
stub_touch leg-a; stub_touch leg-b
req a24c "$RUN/req-alias.json"
assert_eq "A24c the request is served" "$(http_code a24c)" "200"
assert_eq "A24c it went to the serving leg" "$(lg '.route')" "leg-a"
assert_eq "A24c the disabled leg was never dialled" "$(dials leg-b)" "0"
n=0
while [ "$n" -lt 40 ]; do
  admin_get "$RUN/a24-reload.json" /admin/config >/dev/null
  [ "$(jq -r '.reload.count' "$RUN/a24-reload.json")" -ge 1 ] && break
  n=$((n + 1)); sleep 0.05
done
assert_eq "A24c the reload counter moved at the quiet moment" \
  "$(jq -r '.reload.count >= 1' "$RUN/a24-reload.json")" "true"

echo
echo "=== A24d: the last-leg guard"
assert_eq "A24d switching the last serving leg off without confirm is 409" \
  "$(put_overrides "$RUN/a24-last.json" '{"legs":{"leg-a":false,"leg-b":false}}' -H "$(admin_write_header)")" "409"
assert_eq "A24d the refusal is the named guard" \
  "$(jq -r '.error.type' "$RUN/a24-last.json")" "last_leg"
assert_eq "A24d the refused write changed nothing" \
  "$(jq -r '.overrides.legs["leg-a"]' "$GW_CFG")" "null"
assert_eq "A24d with confirm_last_leg it is 200" \
  "$(put_overrides "$RUN/a24-last-ok.json" '{"legs":{"leg-a":false,"leg-b":false},"confirm_last_leg":true}' -H "$(admin_write_header)")" "200"
before=$(log_count)
req a24d "$RUN/req-alias.json"
assert_eq "A24d every request answers 503" "$(http_code a24d)" "503"
assert_eq "A24d the type is no_leg_enabled" \
  "$(jq -r '.error.type' "$RUN/a24d.body")" "no_leg_enabled"
assert_one_line "A24d" "$before"
assert_log "A24d the log names no leg" '.route' ''
assert_log "A24d the reason is no_leg_enabled" '.failover_reason' 'no_leg_enabled'
assert_eq "A24d restoring both legs is 200" \
  "$(put_overrides "$RUN/a24-on.json" '{"legs":{}}' -H "$(admin_write_header)")" "200"
req a24d2 "$RUN/req-alias.json"
assert_eq "A24d a leg serves again" "$(http_code a24d2)" "200"

echo
echo "=== A24e: a model switch is global across legs"
assert_eq "A24e switching the alias off is 200" \
  "$(put_overrides "$RUN/a24-model.json" '{"models":{"jev":false}}' -H "$(admin_write_header)")" "200"
req a24e "$RUN/req-alias.json"
assert_eq "A24e the alias answers 400" "$(http_code a24e)" "400"
assert_eq "A24e the type is alias_disabled" \
  "$(jq -r '.error.type' "$RUN/a24e.body")" "alias_disabled"
assert_eq "A24e switching it back on is 200" \
  "$(put_overrides "$RUN/a24-model-on.json" '{"models":{"jev":true}}' -H "$(admin_write_header)")" "200"
req a24e2 "$RUN/req-alias.json"
assert_eq "A24e the alias serves again" "$(http_code a24e2)" "200"

echo
echo "=== A24f: cookie writes need the non-simple header, and the session is short"
assert_eq "A24f login with the write token is 204" \
  "$(gate_login "$RUN/a24-wlogin" "$ADMIN_WRITE_TOKEN_VALUE")" "204"
assert_present "A24f the write session lives 12 h" "$RUN/a24-wlogin.head" "Max-Age=43200"
wcookie=$(gate_cookie_value "$RUN/a24-wlogin.head")
assert_eq "A24f a cookie write without X-Kori-Write is 403" \
  "$(put_overrides "$RUN/a24-csrf.json" '{"legs":{}}' --cookie "$ADMIN_COOKIE_NAME=$wcookie")" "403"
assert_eq "A24f the refusal names the header" \
  "$(jq -r '.error.type' "$RUN/a24-csrf.json")" "csrf_header_required"
assert_eq "A24f with the header it is 200" \
  "$(put_overrides "$RUN/a24-csrf-ok.json" '{"legs":{"leg-b":false}}' --cookie "$ADMIN_COOKIE_NAME=$wcookie" -H 'X-Kori-Write: 1')" "200"

echo
echo "=== A24g: the override survives a restart; no write token is a 404"
gw_stop
gw_start
admin_get "$RUN/a24-restart.json" /admin/config >/dev/null
assert_eq "A24g after a restart leg-b is still overridden off" \
  "$(jq -r '.legs[] | select(.name=="leg-b") | .serving' "$RUN/a24-restart.json")" "false"
stub_touch leg-a; stub_touch leg-b
req a24g "$RUN/req-alias.json"
assert_eq "A24g the restart kept the switch" "$(lg '.route')" "leg-a"
assert_eq "A24g the disabled leg is still not dialled" "$(dials leg-b)" "0"

gw_stop
ADMIN_WRITE_TOKEN_WRITE=0 gw_start
assert_eq "A24g a host with no write token answers 404, not 403" \
  "$(put_overrides "$RUN/a24-nowrite.json" '{"legs":{}}' -H "$(admin_token_header)")" "404"

gw_stop
kill_stubs
finish
