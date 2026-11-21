#!/usr/bin/env sh
# kori test hook for `./task gate-full`: rebuild the dashboard and fail if the committed dist is
# stale, audit the lockfile, scan the whole history for secrets, then the Nim check, the nimble
# suite and the acceptance harness — what CI's `nim` and `image-web` and `security` jobs run.
# `gate` already ran the shellcheck/dry-run set and the publishable-range secret scan, so neither is
# repeated here. This hook may need a toolchain and the package registry; `gate` may not.
set -eu
cd "$(dirname "$0")/.."

sh ./task web
sh ./task audit
sh ./task secrets
sh ./task nim
