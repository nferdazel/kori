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
#
# A value from the environment has to look like a git sha before it is used.
# Trimming it and taking whatever is left is what 0.5.1 did: a build-arg of
# spaces passed the Dockerfile guard, `strip()` turned it into nothing here, the
# build fell through to git, then to "dev", and nothing said so. This value also
# goes into the startup line verbatim, so a newline or a control character in it
# could forge a log line; hex only rules both out.
let rawRevision = getEnv("KORI_REVISION")
let revision =
  if rawRevision.len > 0:
    var looksLikeSha = rawRevision.len >= 7 and rawRevision.len <= 40
    if looksLikeSha:
      for c in rawRevision:
        if c notin {'0'..'9', 'a'..'f'}:
          looksLikeSha = false
          break
    if not looksLikeSha:
      quit("config.nims: KORI_REVISION must be a lowercase hex git sha of 7 to 40 " &
           "characters, got " & escape(rawRevision), 1)
    rawRevision
  else:
    staticExec("git rev-parse --short HEAD 2>/dev/null || echo dev").strip()
if revision.len > 0:
  switch("define", "KoriRevision=" & revision)
