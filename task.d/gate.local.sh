#!/usr/bin/env sh
# kori static checks for `./task gate`: shellcheck over the scripts plus the four dry runs.
# No podman, no network, no toolchain download. `./task gate-full` adds the Nim suite.
set -eu
cd "$(dirname "$0")/.."

sh ./task ops
