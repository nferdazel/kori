#!/bin/sh
# Every acceptance case, in order, against one binary.
#
#   KORI_BIN=./apps/api/src/kori sh acceptance/run-all.sh
#
# Each case is its own process with its own temp directory, so a case that fails
# cannot leave a stub or a listener behind for the next one. Exits nonzero if any
# case is red, and names the ones that were.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
KORI_BIN=${KORI_BIN:-${GW_BIN:-$ACC_DIR/../apps/api/src/kori}}
export KORI_BIN

if [ ! -x "$KORI_BIN" ]; then
  echo "no executable at $KORI_BIN — build it first: nim c -d:release --mm:orc --threads:on -o:apps/api/src/kori apps/api/src/kori.nim" >&2
  exit 1
fi

# The default KORI_BIN is gitignored, so a stale build sits there and the whole
# suite reports green against code that is not this tree. Two people read two
# different binaries on 2026-11-23 and wrote opposite conclusions from it. When
# `strings` is missing the check is skipped rather than failed: a missing binutils
# is not evidence about the binary.
if command -v strings >/dev/null 2>&1; then
  want=$(tr -d ' \n\r' <"$ACC_DIR/../VERSION")
  have=$(strings "$KORI_BIN" | sed -n 's/^@\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' | head -1)
  if [ "$have" != "$want" ]; then
    echo "KORI_BIN $KORI_BIN is version '$have', this tree is '$want'" >&2
    echo "rebuild it, or point KORI_BIN at a fresh build: KORI_BIN=/path/to/kori sh acceptance/run-all.sh" >&2
    exit 1
  fi
fi

CASES="a1-failover a2-dead-socket a3-deadlines a4-capacity a5-client-error a6-stream a7-toolcall a8-fresh a9-all-dead a10-admin a11-refresh a12-model-map a13-parity a14-ops a15-systemone a16-admin-auth a17-transport a18-log-write a19-admin-scan-budget a20-log-reopen a21-billing-402 a22-cooldown-ladder a23-honest-cooling a24-admin-overrides"

red=
green=0
total=0
for case_name in $CASES; do
  total=$((total + 1))
  printf '\n========== %s ==========\n' "$case_name"
  if sh "$ACC_DIR/$case_name.sh"; then
    green=$((green + 1))
  else
    red="$red $case_name"
  fi
done

printf '\n%d of %d cases green' "$green" "$total"
if [ -n "$red" ]; then
  printf '; red:%s\n' "$red"
  exit 1
fi
printf '\n'
