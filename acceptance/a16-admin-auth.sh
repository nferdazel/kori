#!/bin/sh
# A16 — the admin surface is behind a token (DEC-20, option 5 of DEC-20's table).
#
# The contract this case is written against is
# workloop/items/kori/2026-11-19-admin-auth/DECISION-admin-auth.md, sections 1-10.
# Each numbered assertion below names the contract point it proves.
#
# a  no credential at all: /admin/state, /metrics, /, /admin/config are 401, /healthz is 200
# b  a wrong token is 401
# c  the right token as a bearer is 200 on /admin/state, /metrics and /admin/log
# d  a dashboard page asked for as HTML without a cookie is a 302 to /login.html,
#    while a JSON caller and /admin/state still learn why (401), and /login.html is open
# e  POST /session/login answers 204 and sets kori_admin with all five attributes
# f  that cookie replays on /admin/state, then logout drops it and it is refused
# g  a gateway with no token file answers 404 on the gated reads and 200 on /healthz
# h  five wrong logins then 429 on the sixth, and the right token is 429 too
# i  neither the token nor a session id reaches the request log
# j  /v1/chat/completions is untouched
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

gw_stop; stub_kill leg-a 18091
stub leg-a 18091 ok
write_config "leg-a|http://127.0.0.1:18091/v1|key-leg-a|"
gw_start

TOKEN=$ADMIN_TOKEN_VALUE
cookie() { cat "$RUN/a16-cookie" 2>/dev/null; }

echo
echo "=== A16a: nothing presented, on every gated surface"
assert_eq "A16a /admin/state without a credential is 401"   "$(open_code /admin/state)" "401"
assert_eq "A16a /metrics without a credential is 401"       "$(open_code /metrics)" "401"
# The brief writes this one as /admin/metrics. There is no such path (it is a 404
# behind the gate), but /admin/* is gated as a prefix, so it must still not answer
# before the path is even resolved.
assert_eq "A16a /admin/metrics without a credential is 401" "$(open_code /admin/metrics)" "401"
assert_eq "A16a /admin/config without a credential is 401"  "$(open_code /admin/config)" "401"
assert_eq "A16a / without a credential is 401"              "$(open_code /)" "401"
# Contract 4: /healthz is the deploy gate and stays open, so a rollback probe
# does not need a secret on the host.
assert_eq "A16a /healthz without a credential is still 200" "$(open_code /healthz)" "200"

echo
echo "=== A16b: a wrong token is not a token"
WRONG="acc-wrong-token-not-the-fixture"
assert_eq "A16b /admin/state with a wrong bearer is 401" \
  "$(gate_code GET /admin/state -H "Authorization: Bearer $WRONG")" "401"
assert_eq "A16b /metrics with a wrong bearer is 401" \
  "$(gate_code GET /metrics -H "Authorization: Bearer $WRONG")" "401"
# A prefix of the real token must not pass either: the comparison covers the
# whole string, not a shared prefix (contract 5).
assert_eq "A16b a prefix of the real token is 401" \
  "$(gate_code GET /admin/state -H "Authorization: Bearer $(printf '%s' "$TOKEN" | cut -c1-12)")" "401"

echo
echo "=== A16c: the right bearer opens the reads"
assert_eq "A16c /admin/state with the bearer is 200" \
  "$(curl -sS -o "$RUN/a16-state.json" -w '%{http_code}' --max-time 5 \
       -H "$(admin_token_header)" "$GW_URL/admin/state")" "200"
assert_eq "A16c /admin/state still carries the leg state behind the gate" \
  "$(admin_legs "$RUN/a16-state.json" | jq 'length')" "1"
assert_eq "A16c /metrics with the bearer is 200" \
  "$(curl -sS -o "$RUN/a16-metrics.txt" -w '%{http_code}' --max-time 5 \
       -H "$(admin_token_header)" "$GW_URL/metrics")" "200"
assert_eq "A16c /admin/log with the bearer is 200" \
  "$(curl -sS -o "$RUN/a16-log.json" -w '%{http_code}' --max-time 5 \
       -H "$(admin_token_header)" "$GW_URL/admin/log?limit=5")" "200"

echo
echo "=== A16d: a page asked for as HTML, and the form it needs"
assert_eq "A16d GET / as HTML without a cookie is a 302" \
  "$(gate_gen "$RUN/a16-root.body" / -H 'Accept: text/html')" "302"
assert_eq "A16d the redirect points at /login.html" \
  "$(gate_header "$RUN/a16-root.body.head" location)" "/login.html"
assert_eq "A16d GET /requests.html as HTML is a 302 too" \
  "$(gate_gen "$RUN/a16-req.body" /requests.html -H 'Accept: text/html')" "302"
# Contract 3: only pages redirect. A JSON caller on a page, and /admin/state
# asked for as HTML, both get the honest 401.
assert_eq "A16d GET / accepting JSON is a 401, not a redirect" \
  "$(gate_gen "$RUN/a16-root-json.body" / -H 'Accept: application/json')" "401"
assert_eq "A16d /admin/state asked for as HTML is still a 401" \
  "$(gate_gen "$RUN/a16-state-html.body" /admin/state -H 'Accept: text/html')" "401"
# Contract 3: /login.html is the only open page, because a gated page that
# answers 401 has no way to offer a form.
assert_eq "A16d /login.html is open" "$(open_code /login.html)" "200"

echo
echo "=== A16e: POST /session/login sets the session cookie"
assert_eq "A16e login with the right token is 204" \
  "$(gate_login "$RUN/a16-login" "$TOKEN")" "204"
assert_present "A16e the cookie is named kori_admin" "$RUN/a16-login.head" "$ADMIN_COOKIE_NAME="
assert_present "A16e the cookie carries HttpOnly"    "$RUN/a16-login.head" "HttpOnly"
assert_present "A16e the cookie carries Secure"      "$RUN/a16-login.head" "Secure"
assert_present "A16e the cookie carries SameSite=Strict" "$RUN/a16-login.head" "SameSite=Strict"
assert_present "A16e the cookie carries Path=/"      "$RUN/a16-login.head" "Path=/"
assert_present "A16e the cookie carries Max-Age=43200" "$RUN/a16-login.head" "Max-Age=43200"
value=$(gate_cookie_value "$RUN/a16-login.head")
printf '%s' "$value" >"$RUN/a16-cookie"
assert_eq "A16e the session id is 32 bytes base64url, so 43 characters" \
  "$(printf '%s' "$value" | tr -d '\n' | wc -c | tr -d ' ')" "43"
assert_absent "A16e the session id is not a padded base64 value" \
  "$RUN/a16-cookie" "="
[ -n "$value" ] && pass "A16e the cookie has a value" \
  || fail "A16e the cookie has a value" "Set-Cookie carried no kori_admin value"

echo
echo "=== A16f: the cookie replays, and logout kills it"
assert_eq "A16f /admin/state with the session cookie is 200" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
       --cookie "$ADMIN_COOKIE_NAME=$(cookie)" "$GW_URL/admin/state")" "200"
logout_code=$(gate_logout "$RUN/a16-logout" "$(cookie)")
case "$logout_code" in
  200|204) pass "A16f POST /session/logout answered $logout_code" ;;
  *) fail "A16f POST /session/logout" "expected a 2xx, got [$logout_code]" ;;
esac
assert_eq "A16f the logged-out cookie is refused afterwards" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
       --cookie "$ADMIN_COOKIE_NAME=$(cookie)" "$GW_URL/admin/state")" "401"

echo
echo "=== A16g: no token file is a 404, not a 401 and not a 500 (contract 2)"
gw_stop
ADMIN_TOKEN_FILE="$RUN/no-such-dir/admin.token" ADMIN_TOKEN_WRITE=0 gw_start
assert_eq "A16g /admin/state with no token file is 404" \
  "$(open_code /admin/state)" "404"
assert_eq "A16g /metrics with no token file is 404" \
  "$(open_code /metrics)" "404"
assert_eq "A16g /admin/config with no token file is 404" \
  "$(open_code /admin/config)" "404"
curl -sS -o "$RUN/a16-404.body" --max-time 5 "$GW_URL/admin/state" 2>/dev/null
assert_not_found_body "A16g the 404 carries the standard not-found body" "$RUN/a16-404.body"
assert_eq "A16g /healthz is still 200 with no token file" "$(open_code /healthz)" "200"
# A bearer of any value does not open a gateway that has no token to compare to.
assert_eq "A16g a bearer does not open a gateway with no token file" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
       -H "Authorization: Bearer $TOKEN" "$GW_URL/admin/state")" "404"

echo
echo "=== A16h: five failed logins, then a global 429 (contract 8)"
# A restart empties the failure counter and the session table, so the five below
# are the only attempts this window has seen.
unset ADMIN_TOKEN_FILE ADMIN_TOKEN_WRITE
gw_stop; gw_start
i=0
while [ $i -lt 5 ]; do
  i=$((i + 1))
  assert_eq "A16h failed login $i is 401" "$(gate_login "$RUN/a16-bad$i" "$WRONG")" "401"
done
assert_eq "A16h the sixth attempt is 429" "$(gate_login "$RUN/a16-bad6" "$WRONG")" "429"
# The counter is global, not per credential: the right token is refused through
# the same window.
assert_eq "A16h the right token is 429 inside the same window" \
  "$(gate_login "$RUN/a16-bad7" "$TOKEN")" "429"

echo
echo "=== A16i: the sentinel, over everything the log saw"
assert_absent "A16i the admin token value never reached the request log" "$GW_LOG" "$TOKEN"
assert_absent "A16i a session id never reached the request log" "$GW_LOG" "$(cookie)"
assert_absent "A16i a failed-login token never reached the request log" "$GW_LOG" "$WRONG"
assert_absent "A16i the request log carries no cookie header" "$GW_LOG" "kori_admin="

echo
echo "=== A16k: the token rotates without a restart (contract 1)"
# The window from A16h is still open, so this restart clears the failure counter
# as well as the session table.
unset ADMIN_TOKEN_FILE ADMIN_TOKEN_WRITE
gw_stop; gw_start
assert_eq "A16k the fixture token opens the gate" "$(admin_code /admin/state)" "200"
ROTATED="acc-ROTATED-token-SENTINEL-do-not-log"
printf '%s\n' "$ROTATED" >"$(admin_token_path)"
assert_eq "A16k the old token is refused after the file changed" \
  "$(admin_code /admin/state)" "401"
assert_eq "A16k the new token is accepted with no restart" \
  "$(gate_code GET /admin/state -H "Authorization: Bearer $ROTATED")" "200"
assert_eq "A16k the rotated token value never reached the request log" \
  "$(grep -cF "$ROTATED" "$GW_LOG" 2>/dev/null | tr -d ' \n' || echo 0)" "0"
# Put the fixture value back, so the sentinel checks below stay about one token.
printf '%s\n' "$TOKEN" >"$(admin_token_path)"

echo
echo "=== A16l: sessions live in memory, so a restart invalidates them (contract 6)"
gate_login "$RUN/a16-relogin" "$TOKEN" >/dev/null
again=$(gate_cookie_value "$RUN/a16-relogin.head")
assert_eq "A16l a fresh login yields a session that works" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
       --cookie "$ADMIN_COOKIE_NAME=$again" "$GW_URL/admin/state")" "200"
gw_stop; gw_start
assert_eq "A16l the same cookie is refused after a restart" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
       --cookie "$ADMIN_COOKIE_NAME=$again" "$GW_URL/admin/state")" "401"

echo
echo "=== A16j: the OpenAI surface is untouched (contract 10)"
stub_kill leg-a 18091
stub leg-a 18091 ok
# The bearer below is the edge credential every A1-A15 case sends, and it is not
# the admin token: this door never asks for the admin token.
jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"
stub_touch leg-a
req a16-j "$RUN/req-basic.json"
assert_eq "A16j /v1/chat/completions answers 200 with no admin credential" \
  "$(http_code a16-j)" "200"
assert_eq "A16j the request still reached the leg" "$(dials leg-a)" "1"
assert_log "A16j the served request still wrote its log line" '.route' 'leg-a'

kill_stubs
finish
