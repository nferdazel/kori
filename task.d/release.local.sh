#!/usr/bin/env sh
# kori release hook: stamps the version into kori.nimble and regenerates the embedded module.
# The CHANGELOG cut is the shared script's job (Keep a Changelog, same as every other repo).
# Called by task.d/release.sh as: sh task.d/release.local.sh <new> <old>
set -eu
cd "$(dirname "$0")/.."

new=$1

sed -i.bak -e "s/^version *= *\"[^\"]*\"/version     = \"$new\"/" kori.nimble
rm -f kori.nimble.bak
sh tools/gen-version.sh
sh ./task version-check
git add VERSION kori.nimble CHANGELOG.md apps/api/src/generated/version.nim
