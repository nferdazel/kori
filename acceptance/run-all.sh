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

CASES="a1-failover a2-dead-socket a3-deadlines a4-capacity a5-client-error a6-stream a7-toolcall a8-fresh a9-all-dead a10-admin a11-refresh a12-model-map a13-parity"

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
