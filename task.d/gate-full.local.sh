#!/usr/bin/env sh
# kori test hook for `./task gate-full`: rebuild the dashboard and fail if the committed dist is
# stale, then the Nim check, the nimble suite and the acceptance harness — what CI's `nim` and
# `image-web` jobs run. `gate` already ran the shellcheck/dry-run set, so it is not repeated here.
set -eu
cd "$(dirname "$0")/.."

sh ./task web
sh ./task nim
