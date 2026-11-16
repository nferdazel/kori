# Compile-time configuration for the kori binary.
#
# `nim c` on this file's directory (apps/api/src) picks this up, which is what
# makes the pinned build command — no extra flags, see ./task and
# apps/api/Dockerfile — still produce an SSL-capable binary. Without -d:ssl every
# leg in the config is https and httpclient refuses to dial it at runtime.
import std/strutils

switch("define", "ssl")

# /healthz reports this. Read from git when the repo is present, and left as the
# "dev" default when it is not, so the value is never invented.
let revision = staticExec("git rev-parse --short HEAD 2>/dev/null || echo dev").strip()
if revision.len > 0:
  switch("define", "KoriRevision=" & revision)
