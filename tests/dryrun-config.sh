#!/usr/bin/env bash
# dryrun-config.sh — exercises ops/scripts/kori-config.sh and the committed config template.
#
# Why this exists: the fill script writes the one file the first deploy cannot start without, and
# it handles every provider credential. A mistake here is either a broken container (exit 2, no
# :prev to roll back to) or a secret on a command line. Both are cheap to prove and expensive to
# discover on qouver1.
#
# What is real here: bash, the script under test, the template, git-free file modes and renames.
# What is stubbed: the kori binary, in the scenarios that test the script's own logic. When a real
# binary is present ($KORI_BIN, else apps/api/src/kori from ./task nim) the last block runs the
# committed template and a broken one through the actual parser instead.
#
# Usage: bash tests/dryrun-config.sh        (exit 0 = all scenarios passed)
#        KORI_BIN=/path/to/kori bash tests/dryrun-config.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
FILL="$KIT/ops/scripts/kori-config.sh"
TEMPLATE="$KIT/ops/etc/config.json.example"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kori-config-dryrun.XXXXXX")"
FAILS=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

file_mode() { # file_mode <path> -> permission bits as octal, on BSD and GNU
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

# ── the stub binary ─────────────────────────────────────────────────────────
# It answers the two things the fill script needs: an argv record, and the parser's contract for
# a missing required field (one line on stderr, exit 2). Everything else it accepts and stays up,
# which is what a good config does.
STUB="$ROOT/bin/kori"
mkdir -p "$ROOT/bin"
cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_ARGV:?}"
cfg=""
port=""
log=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) cfg="${2:-}"; shift 2 ;;
    --port) port="${2:-}"; shift 2 ;;
    --log) log="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
if ! grep -q '"refresh_token"' "$cfg" 2>/dev/null; then
  printf 'kori: legs[0].oauth.refresh_token is required\n' >&2
  exit 2
fi
printf 'kori 0.0.0 (stub) listening on 127.0.0.1:%s, log %s\n' "$port" "$log" >&2
sleep 30
STUBEOF
chmod +x "$STUB"

export STUB_ARGV="$ROOT/argv.log"
: >"$STUB_ARGV"
export KORI_BIN="$STUB"

SENTINEL_RT="rt-SENTINEL-argv-probe-111"
SENTINEL_SES="ses_SENTINEL-argv-probe-222"
SENTINEL_CC="cc-SENTINEL-argv-probe-333"
SENTINEL_SC="sc-SENTINEL-argv-probe-444"

VALUES="$ROOT/values.env"
cat >"$VALUES" <<EOF
# sentinel values: not credentials
KORI_OPENCODE_REFRESH_TOKEN=$SENTINEL_RT
KORI_OPENCODE_SESSION=$SENTINEL_SES
KORI_COMMANDCODE_API_KEY=$SENTINEL_CC
KORI_SINARCLOUD_API_KEY=$SENTINEL_SC
EOF

# ── scenario 1: a filled config, 0600, no placeholder left ─────────────────
OUT="$ROOT/etc/config.json"
mkdir -p "$ROOT/etc"
run_fill() { bash "$FILL" --values "$VALUES" --out "$OUT" 2>"$ROOT/stderr"; }

run_fill
rc=$?
[ "$rc" = "0" ] && pass "fill from a values file exits 0" || fail "fill exited $rc: $(cat "$ROOT/stderr")"
[ -f "$OUT" ] && pass "config.json was written" || fail "config.json missing"
[ "$(file_mode "$OUT")" = "600" ] && pass "config.json is 0600" || fail "config.json mode is $(file_mode "$OUT")"
grep -q '__KORI_' "$OUT" && fail "a placeholder survived into the config" \
  || pass "no template placeholder left in the config"
for pair in "$SENTINEL_RT" "$SENTINEL_SES" "$SENTINEL_CC" "$SENTINEL_SC"; do
  grep -qF "$pair" "$OUT" && pass "value present: ${pair%%-SENTINEL*}" \
    || fail "value missing: ${pair%%-SENTINEL*}"
done
grep -q '"legs"' "$OUT" && pass "the config still has the legs array" || fail "legs array missing"

# ── scenario 2: a second run refuses to overwrite ──────────────────────────
cp "$OUT" "$ROOT/first-copy.json"
run_fill
rc=$?
[ "$rc" != "0" ] && pass "second run without --force exits non-zero ($rc)" \
  || fail "second run overwrote an existing config"
grep -q 'exists' "$ROOT/stderr" && pass "the refusal says the file exists" \
  || fail "the refusal does not say why"
cmp -s "$OUT" "$ROOT/first-copy.json" && pass "the existing config was left byte-identical" \
  || fail "the existing config changed under a refused run"

# ── scenario 3: --force replaces it ────────────────────────────────────────
sed -e "s/$SENTINEL_CC/cc-SENTINEL-second-run/" "$VALUES" >"$ROOT/values2.env"
bash "$FILL" --values "$ROOT/values2.env" --out "$OUT" --force 2>"$ROOT/stderr"
rc=$?
[ "$rc" = "0" ] && pass "--force replaces the config" || fail "--force failed: $(cat "$ROOT/stderr")"
grep -qF 'cc-SENTINEL-second-run' "$OUT" && pass "--force wrote the new value" \
  || fail "--force did not write the new value"

# ── scenario 4: a missing key fails and writes nothing ─────────────────────
grep -v 'KORI_COMMANDCODE_API_KEY' "$VALUES" >"$ROOT/values-missing.env"
OUT2="$ROOT/etc2/config.json"
mkdir -p "$ROOT/etc2"
bash "$FILL" --values "$ROOT/values-missing.env" --out "$OUT2" 2>"$ROOT/stderr"
rc=$?
[ "$rc" != "0" ] && pass "a missing key exits non-zero ($rc)" || fail "a missing key was accepted"
grep -q 'KORI_COMMANDCODE_API_KEY' "$ROOT/stderr" && pass "the error names the missing key" \
  || fail "the error does not name the missing key"
[ -e "$OUT2" ] && fail "a config was written without all four values" \
  || pass "no config written when a value is missing"

# ── scenario 5: an empty value is refused ──────────────────────────────────
sed -e "s/^KORI_SINARCLOUD_API_KEY=.*/KORI_SINARCLOUD_API_KEY=/" "$VALUES" >"$ROOT/values-empty.env"
bash "$FILL" --values "$ROOT/values-empty.env" --out "$OUT2" 2>"$ROOT/stderr"
rc=$?
[ "$rc" != "0" ] && pass "an empty value exits non-zero ($rc)" || fail "an empty value was accepted"
grep -q 'KORI_SINARCLOUD_API_KEY is empty' "$ROOT/stderr" && pass "the error says the key is empty" \
  || fail "the error does not say the key is empty"

# ── scenario 6: a pasted placeholder is refused ────────────────────────────
sed -e "s/^KORI_OPENCODE_SESSION=.*/KORI_OPENCODE_SESSION=__KORI_OPENCODE_SESSION__/" "$VALUES" \
  >"$ROOT/values-placeholder.env"
bash "$FILL" --values "$ROOT/values-placeholder.env" --out "$OUT2" 2>"$ROOT/stderr"
rc=$?
[ "$rc" != "0" ] && pass "an unfilled placeholder exits non-zero ($rc)" \
  || fail "an unfilled placeholder was accepted"
grep -q 'placeholder' "$ROOT/stderr" && pass "the error names the placeholder" \
  || fail "the error does not name the placeholder"

# ── scenario 7: a malformed line is refused without echoing it ─────────────
printf 'KORI_OPENCODE_REFRESH_TOKEN=%s\nthis-is-not-a-key-value-line\n' "$SENTINEL_RT" \
  >"$ROOT/values-bad-line.env"
bash "$FILL" --values "$ROOT/values-bad-line.env" --out "$OUT2" 2>"$ROOT/stderr"
rc=$?
[ "$rc" != "0" ] && pass "a malformed values line exits non-zero ($rc)" \
  || fail "a malformed values line was accepted"
grep -qF "$SENTINEL_RT" "$ROOT/stderr" && fail "the error echoed a value" \
  || pass "the error did not echo a value"

# ── scenario 8: values on stdin ────────────────────────────────────────────
OUT3="$ROOT/etc3/config.json"
mkdir -p "$ROOT/etc3"
bash "$FILL" --out "$OUT3" <"$VALUES" 2>"$ROOT/stderr"
rc=$?
[ "$rc" = "0" ] && pass "values on stdin exit 0" || fail "stdin run failed: $(cat "$ROOT/stderr")"
[ "$(file_mode "$OUT3")" = "600" ] && pass "stdin-written config is 0600" \
  || fail "stdin-written config mode is $(file_mode "$OUT3")"

# ── scenario 9: a value on argv is refused, not guessed ────────────────────
bash "$FILL" "$SENTINEL_RT" --out "$OUT2" 2>"$ROOT/stderr"
rc=$?
[ "$rc" != "0" ] && pass "a positional argument is refused ($rc)" || fail "a value on argv was accepted"
grep -q 'never argv' "$ROOT/stderr" && pass "the refusal says values never come from argv" \
  || fail "the refusal does not explain the rule"

# ── scenario 10: no value ever reaches a command line ──────────────────────
# The stub records its own argv. If the script had passed a value through an external process,
# the sentinel would be in that record.
leak=0
for pair in "$SENTINEL_RT" "$SENTINEL_SES" "$SENTINEL_CC" "$SENTINEL_SC"; do
  grep -qF "$pair" "$STUB_ARGV" && leak=1
done
[ "$leak" = "0" ] && pass "no value appears in the binary's argv" \
  || fail "a value reached a command line"
grep -q -- '--config' "$STUB_ARGV" && pass "the binary was called with --config (it really ran)" \
  || fail "the stub never ran"
if grep -qE '\b(sed|awk|xargs)\b' "$FILL"; then
  fail "the fill script calls sed/awk/xargs, which would carry a value in argv"
else
  pass "the fill script uses no external text filter"
fi

# ── scenario 11: a rejected config leaves nothing behind ───────────────────
grep -v 'refresh_token' "$TEMPLATE" >"$ROOT/broken-template.json"
OUT4="$ROOT/etc4/config.json"
mkdir -p "$ROOT/etc4"
bash "$FILL" --values "$VALUES" --out "$OUT4" --template "$ROOT/broken-template.json" \
  2>"$ROOT/stderr"
rc=$?
[ "$rc" != "0" ] && pass "a template missing a required field exits non-zero ($rc)" \
  || fail "a broken template was accepted"
[ -e "$OUT4" ] && fail "a broken config was renamed into place" \
  || pass "a broken config never lands at the target path"
leftover="$(find "$ROOT/etc4" -name '*.tmp.*' | head -1)"
[ -z "$leftover" ] && pass "no temp file left after a rejected config" \
  || fail "temp file left behind: $leftover"

# ── scenario 12: no binary means no write ──────────────────────────────────
# A copy of the script in a fake checkout, so apps/api/src/kori does not exist and KORI_BIN is
# unset: the script must refuse instead of writing an unvalidated config.
FAKE="$ROOT/fake-repo"
mkdir -p "$FAKE/ops/scripts" "$FAKE/ops/etc" "$FAKE/etc"
cp "$FILL" "$FAKE/ops/scripts/kori-config.sh"
cp "$TEMPLATE" "$FAKE/ops/etc/config.json.example"
env -u KORI_BIN bash "$FAKE/ops/scripts/kori-config.sh" --values "$VALUES" \
  --out "$FAKE/etc/config.json" 2>"$ROOT/stderr"
rc=$?
[ "$rc" != "0" ] && pass "no binary: the script refuses ($rc)" || fail "wrote a config with no parser check"
grep -q 'no kori binary' "$ROOT/stderr" && pass "the refusal names the missing binary" \
  || fail "the refusal does not name the missing binary"
[ -e "$FAKE/etc/config.json" ] && fail "an unvalidated config was written" \
  || pass "nothing was written without a parser check"

# ── scenario 13: the real parser, when a binary exists ─────────────────────
REAL_BIN="${KORI_BIN_REAL:-}"
if [ -z "$REAL_BIN" ] && [ -x "$KIT/apps/api/src/kori" ]; then
  REAL_BIN="$KIT/apps/api/src/kori"
fi
if [ -n "$REAL_BIN" ] && [ -x "$REAL_BIN" ]; then
  # 13a: the committed template is the shape the parser accepts, as-is.
  rport=$((24000 + ($$ % 5000)))
  "$REAL_BIN" --config "$TEMPLATE" --address 127.0.0.1 --port "$rport" \
    --log "$ROOT/real-template.jsonl" 2>"$ROOT/real-stderr" &
  rpid=$!
  seen=0
  i=0
  while [ "$i" -lt 50 ]; do
    if grep -q 'listening on' "$ROOT/real-stderr" 2>/dev/null; then seen=1; break; fi
    kill -0 "$rpid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$rpid" 2>/dev/null
  wait "$rpid" 2>/dev/null
  [ "$seen" = "1" ] && pass "the committed template loads in the real parser" \
    || fail "the real parser rejected the template: $(cat "$ROOT/real-stderr")"

  # 13b: a filled config passes, and a broken one fails with the parser's own message.
  OUT5="$ROOT/etc5/config.json"
  mkdir -p "$ROOT/etc5"
  KORI_BIN="$REAL_BIN" bash "$FILL" --values "$VALUES" --out "$OUT5" 2>"$ROOT/stderr"
  rc=$?
  [ "$rc" = "0" ] && pass "the real parser accepts a filled config" \
    || fail "the real parser rejected a filled config: $(cat "$ROOT/stderr")"
  [ "$(file_mode "$OUT5")" = "600" ] && pass "the validated config is 0600" \
    || fail "the validated config mode is $(file_mode "$OUT5")"
  KORI_BIN="$REAL_BIN" bash "$FILL" --values "$VALUES" --out "$ROOT/etc5/never.json" \
    --template "$ROOT/broken-template.json" 2>"$ROOT/stderr"
  rc=$?
  [ "$rc" != "0" ] && pass "the real parser rejects a config missing refresh_token ($rc)" \
    || fail "the real parser accepted a config missing refresh_token"
  grep -q 'refresh_token is required' "$ROOT/stderr" \
    && pass "the parser's own message reaches the caller" \
    || fail "the parser's message did not reach the caller: $(cat "$ROOT/stderr")"
else
  printf 'SKIP  no built binary (KORI_BIN or apps/api/src/kori); the real-parser block did not run\n'
fi

printf '\n%s\n' "artifacts: $ROOT"
if [ "$FAILS" -eq 0 ]; then
  printf 'RESULT: all scenarios passed\n'
  exit 0
fi
printf 'RESULT: %s check(s) failed\n' "$FAILS"
exit 1
