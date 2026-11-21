#!/usr/bin/env bash
# kori-config.sh — write the gateway's config.json from a values file or stdin.
#
# Why this exists: /srv/qouver/apps/kori/etc/config.json is the one artifact the first deploy
# cannot run without, it holds every provider credential, and nothing in the repo described its
# shape. A hand-written file fails at container start with exit 2 and no rollback target.
#
# Contract:
#   - values come from --values FILE or stdin, never from argv, so no value reaches another
#     process's command line; a values file readable by group or other is refused;
#   - the file is written under umask 077, 0600, temp in the same directory, renamed into place,
#     so a reader never sees half a config;
#   - an existing config.json is not replaced without --force;
#   - the result is validated by the kori binary's own config load before the rename. The load
#     path is the one the unit takes (loadConfig + applyCli); only --address/--port/--log are
#     overridden to loopback and a scratch log, so validation never binds the live port or
#     writes the live request log.
#
# Usage:
#   kori-config.sh --values FILE [--out PATH] [--template PATH] [--force]
#   kori-config.sh < values.env            # same, values on stdin
#
# Values file format, one per line, '#' comments and blank lines ignored:
#   KORI_COMMANDCODE_API_KEY=...
#   KORI_SINARCLOUD_API_KEY=...
#
# A value is required only when the template still carries its placeholder, so a template that
# chains the two static-key legs does not demand the three OpenCode OAuth values. Adding an
# opencode-go leg back to the template makes them required again:
#   KORI_OPENCODE_REFRESH_TOKEN=...
#   KORI_OPENCODE_ACCESS_TOKEN=...
#   KORI_OPENCODE_SESSION=...
#
# The binary used for validation is $KORI_BIN when set, else apps/api/src/kori in this checkout
# (what ./task nim builds). Without a binary the script refuses to write: an unparsed config is
# exactly the failure this script exists to prevent.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APP_DIR="${KORI_APP_DIR:-/srv/qouver/apps/kori}"

VALUES_FILE=""
OUT="$APP_DIR/etc/config.json"
TEMPLATE="$REPO/ops/etc/config.json.example"
FORCE=0

die() { printf 'kori-config: %s\n' "$*" >&2; exit 1; }

file_mode() { # file_mode <path> -> permission bits as octal, on BSD and GNU
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

usage() {
  printf 'usage: kori-config.sh [--values FILE] [--out PATH] [--template PATH] [--force]\n'
  printf '       values are read from --values or stdin, never from argv\n'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --values) [ "$#" -ge 2 ] || die "--values needs a path"; VALUES_FILE="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || die "--out needs a path"; OUT="$2"; shift 2 ;;
    --template) [ "$#" -ge 2 ] || die "--template needs a path"; TEMPLATE="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --help | -h) usage; exit 0 ;;
    *)
      # A bare argument would be a value on the command line. Refuse instead of guessing.
      die "unexpected argument '$1' — values are read from --values FILE or stdin, never argv"
      ;;
  esac
done

[ -r "$TEMPLATE" ] || die "template not readable: $TEMPLATE"
if [ -n "$VALUES_FILE" ]; then
  [ -r "$VALUES_FILE" ] || die "values file not readable: $VALUES_FILE"
  # The values file holds live credentials. Writing a 0600 config from a wider source leaves
  # the same secrets reachable by other local accounts, so refuse instead of warning: only a mode
  # whose group and other digits are both zero gets through.
  values_mode="$(file_mode "$VALUES_FILE")"
  case "$values_mode" in
    *00) ;;
    *) die "values file is $values_mode, group or other can reach it: chmod 600 $VALUES_FILE" ;;
  esac
elif [ -t 0 ]; then
  die "no values: pass --values FILE or pipe the keys on stdin"
fi

# ── read the values ─────────────────────────────────────────────────────────
UNSET=$'\001'
v_refresh="$UNSET"
v_access="$UNSET"
v_session="$UNSET"
v_commandcode="$UNSET"
v_sinarcloud="$UNSET"
line_number=0

set_value() { # set_value <key> <value>
  case "$1" in
    KORI_OPENCODE_REFRESH_TOKEN) v_refresh="$2" ;;
    KORI_OPENCODE_ACCESS_TOKEN) v_access="$2" ;;
    KORI_OPENCODE_SESSION) v_session="$2" ;;
    KORI_COMMANDCODE_API_KEY) v_commandcode="$2" ;;
    KORI_SINARCLOUD_API_KEY) v_sinarcloud="$2" ;;
    *) return 1 ;;
  esac
  return 0
}

while IFS= read -r line || [ -n "$line" ]; do
  line_number=$((line_number + 1))
  case "$line" in
    '' | '#'*) continue ;;
  esac
  case "$line" in
    *=*) ;;
    # The line is not echoed: a malformed line is where a value would leak into a log.
    *) die "values line $line_number is not KEY=value" ;;
  esac
  key="${line%%=*}"
  value="${line#*=}"
  set_value "$key" "$value" || die "values line $line_number has an unknown key '$key'"
done < "${VALUES_FILE:-/dev/stdin}"

for key in KORI_OPENCODE_REFRESH_TOKEN KORI_OPENCODE_ACCESS_TOKEN KORI_OPENCODE_SESSION KORI_COMMANDCODE_API_KEY KORI_SINARCLOUD_API_KEY; do
  case "$key" in
    KORI_OPENCODE_REFRESH_TOKEN) value="$v_refresh" ;;
    KORI_OPENCODE_ACCESS_TOKEN) value="$v_access" ;;
    KORI_OPENCODE_SESSION) value="$v_session" ;;
    KORI_COMMANDCODE_API_KEY) value="$v_commandcode" ;;
    KORI_SINARCLOUD_API_KEY) value="$v_sinarcloud" ;;
  esac
  # Only a value the template actually substitutes is required: a template with no opencode-go
  # leg has nothing to fill from the three OpenCode values, so demanding them would block the run
  # on a credential no leg would use.
  grep -qF -- "__${key}__" "$TEMPLATE" || continue
  [ "$value" != "$UNSET" ] || die "values file is missing $key"
  [ -n "$value" ] || die "$key is empty"
  case "$value" in
    __KORI_*) die "$key still holds the template placeholder" ;;
  esac
done

# ── refuse to replace a live config, and keep the one it replaces ─────────────
# The old file is the only copy of a working set of provider credentials, and the reason to run
# this script is usually that the new one does not work. So --force backs the live file up first,
# 0600, beside it, and keeps the newest two: the host had four hand-made .bak files of an earlier
# config, none of them pruned, one of them a 372-byte half-written file (2026-11-21).
if [ -e "$OUT" ] && [ "$FORCE" -ne 1 ]; then
  die "$OUT exists — pass --force to replace it"
fi
CONFIG_BAK_KEEP="${KORI_CONFIG_BAK_KEEP:-2}"
backup_live_config() { # backup_live_config <path>
  local live="$1" bak
  [ -f "$live" ] || return 0
  bak="$live.bak-$(date '+%Y%m%d-%H%M%S')"
  # `cp -p` would carry a wider source mode over; the copy holds the same credentials, so it gets
  # the same 0600 as the original at creation and is renamed into place.
  ( umask 077; cp -- "$live" "$bak.tmp.$$" ) && mv -f "$bak.tmp.$$" "$bak" \
    || die "cannot back up $live; refusing to replace it"
  chmod 0600 "$bak" || die "could not narrow $bak to 0600"
  printf 'kori-config: previous config kept as %s\n' "$bak" >&2
  # Oldest first, drop everything beyond the newest $CONFIG_BAK_KEEP. `-t` is mtime order, so a
  # name that does not parse still sorts by when it was written.
  case "$CONFIG_BAK_KEEP" in '' | *[!0-9]*) CONFIG_BAK_KEEP=2 ;; esac
  ls -1t "$live".bak-* 2>/dev/null | tail -n "+$((CONFIG_BAK_KEEP + 1))" \
    | while IFS= read -r old; do rm -f -- "$old"; done
}
if [ "$FORCE" -eq 1 ]; then backup_live_config "$OUT"; fi
[ -d "$(dirname "$OUT")" ] || die "output directory does not exist: $(dirname "$OUT")"

# ── substitute, in the shell, into a 0600 temp beside the target ────────────
json_escape() { # json_escape <value> -> the value safe inside a JSON string
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

subst() { # subst <line> <placeholder> <escaped-value>
  local line="$1" placeholder="$2" value="$3"
  if [ "${line#*"$placeholder"}" = "$line" ]; then
    printf '%s' "$line"
  else
    printf '%s%s%s' "${line%%"$placeholder"*}" "$value" "${line#*"$placeholder"}"
  fi
}

TMP="$OUT.tmp.$$"
VERIFY_DIR=""
cleanup() {
  if [ -n "$TMP" ]; then rm -f "$TMP"; fi
  if [ -n "$VERIFY_DIR" ]; then rm -rf "$VERIFY_DIR"; fi
}
trap cleanup EXIT

umask 077
: >"$TMP" || die "cannot create $TMP"
chmod 0600 "$TMP"

esc_refresh="$(json_escape "$v_refresh")"
esc_access="$(json_escape "$v_access")"
esc_session="$(json_escape "$v_session")"
esc_commandcode="$(json_escape "$v_commandcode")"
esc_sinarcloud="$(json_escape "$v_sinarcloud")"

while IFS= read -r line || [ -n "$line" ]; do
  line="$(subst "$line" __KORI_OPENCODE_REFRESH_TOKEN__ "$esc_refresh")"
  line="$(subst "$line" __KORI_OPENCODE_ACCESS_TOKEN__ "$esc_access")"
  line="$(subst "$line" __KORI_OPENCODE_SESSION__ "$esc_session")"
  line="$(subst "$line" __KORI_COMMANDCODE_API_KEY__ "$esc_commandcode")"
  line="$(subst "$line" __KORI_SINARCLOUD_API_KEY__ "$esc_sinarcloud")"
  printf '%s\n' "$line" >>"$TMP"
done <"$TEMPLATE"

# ── validate with the binary's own config load ──────────────────────────────
find_binary() {
  KORI_BINARY=""
  if [ -n "${KORI_BIN:-}" ]; then
    [ -x "$KORI_BIN" ] || die "KORI_BIN is not executable: $KORI_BIN"
    KORI_BINARY="$KORI_BIN"
    return 0
  fi
  if [ -x "$REPO/apps/api/src/kori" ]; then
    KORI_BINARY="$REPO/apps/api/src/kori"
    return 0
  fi
  return 1
}

verify_config() { # verify_config <binary> <candidate>
  local binary="$1" candidate="$2" base attempt port err pid waited rc
  VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kori-config-verify.XXXXXX")" \
    || die "cannot create a temp directory for the check"
  base=$((20000 + ($$ % 20000)))
  attempt=1
  while [ "$attempt" -le 3 ]; do
    port=$((base + attempt - 1))
    err="$VERIFY_DIR/stderr.$attempt"
    "$binary" --config "$candidate" --address 127.0.0.1 --port "$port" \
      --log "$VERIFY_DIR/requests.$attempt.jsonl" >/dev/null 2>"$err" &
    pid=$!
    waited=0
    while [ "$waited" -lt 50 ]; do
      if grep -q 'listening on' "$err" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return 0
      fi
      if ! kill -0 "$pid" 2>/dev/null; then
        if wait "$pid" 2>/dev/null; then rc=0; else rc=$?; fi
        if [ "$rc" = "2" ]; then
          printf 'kori-config: the parser rejected the config:\n' >&2
          while IFS= read -r message || [ -n "$message" ]; do
            printf '  %s\n' "$message" >&2
          done <"$err"
          return 1
        fi
        break # not a config error (port taken, missing library); try the next port
      fi
      sleep 0.1
      waited=$((waited + 1))
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    attempt=$((attempt + 1))
  done
  printf 'kori-config: the binary never reported listening on 3 loopback ports; last output:\n' >&2
  while IFS= read -r message || [ -n "$message" ]; do
    printf '  %s\n' "$message" >&2
  done <"$err"
  return 1
}

find_binary \
  || die "no kori binary to validate with — run ./task nim, or set KORI_BIN to a built binary"
binary="$KORI_BINARY"
verify_config "$binary" "$TMP" || die "the config was not written; the parser rejected the shape"

# ── rename into place ──────────────────────────────────────────────────────
mv -f "$TMP" "$OUT" || die "cannot move the finished config into $OUT"
TMP=""
printf 'kori-config: wrote %s (0600, %s bytes), validated by %s\n' \
  "$OUT" "$(wc -c <"$OUT" | tr -d ' ')" "$binary"
