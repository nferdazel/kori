# Compile-time configuration for the kori binary.
#
# `nim c` on this file's directory (apps/api/src) picks this up, which is what
# makes the pinned build command — no extra flags, see ./task and
# apps/api/Dockerfile — still produce an SSL-capable binary. Without -d:ssl every
# leg in the config is https and httpclient refuses to dial it at runtime.
import std/os
import std/strutils

switch("define", "ssl")

# /healthz and the startup line report this. Precedence: KORI_REVISION from the
# environment, then git when the repo is present, then the "dev" default when
# neither says anything, so the value is never invented. The environment wins
# because an image build has no .git in its context (see .dockerignore): there
# the revision is a required build-arg, not something read from a repository
# that happens to sit next to the Dockerfile.
let envRevision = getEnv("KORI_REVISION").strip()
let revision =
  if envRevision.len > 0:
    envRevision
  else:
    staticExec("git rev-parse --short HEAD 2>/dev/null || echo dev").strip()
if revision.len > 0:
  switch("define", "KoriRevision=" & revision)
