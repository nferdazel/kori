# kori — in-house LLM provider gateway.
#
# Slice 2: failure classification with cooldowns, the per-phase deadlines of
# SPEC §3b, one pick per request with a failover walk (R12a), streaming with
# mid-stream abort (§5.3), and the all-dead 502 (§5.5).
#
# Slice 3: GET /admin/log over a bounded tail scan, GET /admin/config with every
# credential redacted, `recent[]` on /admin/state, and the D11 envelope.
#
# Slice 4: the four dashboard pages and their assets, served from the table that
# tools/gen-static.sh embeds at compile time. Nothing is read from disk at runtime.
#
# Slice 5: the OAuth credential refresh of SPEC §4 for a leg that carries an
# `oauth` block. A refresh that fails stops the request; it never fails over and
# never sends a stale bearer.
#
# Slice 7 (0.7.0): SIGHUP config reload (DEC-15), `cost_usd` from a config price
# table (DEC-16), size-based log rotation (DEC-17) and `/metrics` in the Prometheus
# text format (DEC-18).
#
# Slice 8 (0.7.0): `POST /v1/systemone`, a second door that passes a System One
# request through to its own ordered legs, unchanged except the model id
# (DEC-19). It is not a protocol translation and not part of the chat walk.
#
# Slice 9 (0.7.0): the admin gate (DEC-20). `/admin/*`, `/metrics`, `/healthz?deep`
# and the four dashboard pages need one shared token, presented as a bearer or as a
# session cookie minted by `POST /session/login`. The token lives in its own file,
# read per request, and a gateway with no token file answers 404 on every gated
# path instead of opening. `/healthz`, `/v1/*`, `/login.html` and the static assets
# stay open; non-GET under `/admin/*` stays 405.
#
# Deliberately absent, and not to be reported as done: every chat-shaped
# convenience endpoint (messages, responses, embeddings, images, audio, batch),
# protocol translation between chat and System One, spend caps and cache, caller
# identity, a second replica, and compression of rotated logs.
# docs/ARCHITECTURE.md, "Not built", is the list this comment must agree with.

import std/[algorithm, asyncdispatch, asyncnet, base64, exitprocs, hashes,
            httpcore, json, net, options, os, posix, strutils, sysrand, tables,
            times, uri]
import std/asynchttpserver

import generated/static_files
# KoriVersion comes from VERSION through tools/gen-version.sh, so /healthz, /admin/state and the
# startup line cannot report a number the repository does not declare.
import generated/version

const
  ## Stamped by config.nims from `git rev-parse --short HEAD`; "dev" when git is
  ## not available, so /healthz never claims a revision it does not have.
  KoriRevision* {.strdefine.} = "dev"

  DefaultHost = "127.0.0.1"
  DefaultPort = 8787

  LogFileMode = 0o640
  ## The cap on a caller's body, enforced by the HTTP layer before a byte is
  ## buffered: a declared Content-Length over it is a 413 on the framing check.
  ## 8 MiB is ten times the largest legitimate body this gateway is sent — a
  ## 200k-token chat request is under 1 MB, and there is no image, audio or batch
  ## path to carry anything bigger — and it is small enough that an
  ## unauthenticated POST cannot hold the container's 512M budget. Before this it
  ## was 32 MiB, which one 30 MiB login body turned into ~190 MB of RSS at a
  ## caller who never authenticated (measured, SEC-1).
  MaxRequestBytes* = 8_388_608
  MaxHeaderBytes = 65_536
  ## Bounds the *answer* read from an upstream, not a caller's body.
  MaxBodyBytes = 67_108_864
  ## The one deadline the HTTP library enforces, not this binary: from the first
  ## byte of a request to its last, headers and body included, and the idle time
  ## between two requests on a keep-alive connection. Without it a half-sent
  ## header block holds its connection and buffers for ever (SEC-2). It is looser
  ## than every other deadline because it bounds the caller, not a provider.
  ReadTimeoutMs* = 30_000

  # SPEC §3b.1. Every number is a deadline this binary enforces itself.
  ConnectDeadlineMs* = 2_000
  TlsDeadlineMs* = 3_000
  ## The floor of the streaming first-byte deadline, and its cap. A provider's
  ## first byte takes longer the more prompt it was handed: measured on
  ## commandcode, p90 was 20.8 s on 50k-token prompts against 15 s on short ones,
  ## so a fixed number fails a healthy leg nine times a day and walks real traffic
  ## to the fallback. The cap matters more than the slope: without it a
  ## pathological body buys a five-minute failover window.
  HeaderDeadlineStreamMs* = 15_000
  HeaderDeadlineStreamMaxMs* = 60_000
  ## Each KiB of outbound body buys this much extra budget. 100 lands a 50k-token
  ## prompt (~200 KiB) near 35 s; 1 ms/KiB would have bought 200 ms and fixed
  ## nothing. Re-measure at two prompt sizes before changing it.
  HeaderDeadlineStreamPerKiBMs* = 100
  HeaderDeadlineNonStreamMs* = 90_000
  ChunkIdleMs* = 120_000
  TotalNonStreamMs* = 300_000

  # Slice 6. A container stop is a SIGTERM and podman waits 10 s before it
  # escalates to SIGKILL, so the listener closes at once, the requests already in
  # flight get this budget, and the process exits 0 inside that window.
  ShutdownDrainMs* = 5_000
  ShutdownPollMs = 20

  # SPEC §4: the token call gets its own budget on top of connect and TLS, so a
  # hung token endpoint is a refresh timeout and never a slow provider.
  RefreshDeadlineMs* = 5_000
  DefaultRefreshSkewS = 60

  # SPEC §3.1 and §3.2.
  AvailabilityCooldownS* = 60.0
  CapacityCooldownS* = 900.0

  # DEC-23. A provider that stops sending headers usually blinks rather than dies:
  # measured on qouver1 2026-11-16..24, 590 header timeouts, and 90 of the 99
  # instant 502s fell within 90 s of one, because a flat 60 s skip turned a
  # second-long hiccup into a minute with no leg to dial. The first header timeout
  # therefore cools for the header window that failure just waited, clamped to this
  # floor and AvailabilityCooldownS, and each repeat doubles it inside that clamp.
  # A 15 s window therefore starts at 15 s and a 90 s window starts at the 60 s cap:
  # a rung shorter than the window it followed would send a probe that is dearer
  # than the cooldown it ends, and the next caller pays the difference.
  HeaderTimeoutCooldownS* = 5.0
  ## DEC-26. A header-timeout rung exists to stop the walk re-probing a dead leg
  ## more often than the window it just paid for. With one enabled leg there is no
  ## other leg to protect, so the rung only decides how long the caller is told to
  ## wait: 15 s, the streaming window's own floor, and no higher.
  SingleLegHeaderMaxMs* = 15_000
  ## DEC-26. A capacity failure keeps its 900 s in every shape, but an upstream
  ## that names its own Retry-After is believed between these bounds.
  CapacityRetryAfterMinS* = 60.0
  ## DEC-26. A plain 429 is a rate limit, not a spent balance: cool briefly and try
  ## the next leg. A provider that names no number gets the default.
  RateLimitRetryAfterMinS* = 5.0
  RateLimitRetryAfterMaxS* = 120.0
  RateLimitDefaultS* = 30.0

  # Item 5. A leg gets `retries` more dials before it is classed as failed and the
  # walk moves on, with a doubling pause between them. The pause is capped so one
  # leg can never spend the whole request budget waiting: 200, 400, 800, 1600 then
  # 2000 ms at the ceiling, which is 5 s for the five retries this ceiling allows.
  # The default is 0: an operator turns retries on per leg, so 0.6.1 behaviour is
  # unchanged for every config that does not name the key.
  RetryBaseMs* = 200
  RetryCeilingMs* = 2_000
  MaxRetriesPerLeg* = 5

  # DEC-11 (supersedes DEC-8): a weight is a small integer, not a percentage and
  # not a float, so a config cannot ask for a share that has no defined rounding.
  MaxWeight* = 1_000

  ## Item 4. A 404 whose body says the model does not exist is a dead route on
  ## that leg, not a caller error, and only when the alias table named the id:
  ## a caller that sent a provider id kori never touched keeps its own 404.
  TokenModelGone* = "model_gone"

  LatencyRingSize = 50
  RecentLimit = 10
  FailoverEventLimit = 20

  # Slice 4 cache policy. Only /assets/ names are content-hashed, so only those
  # may be immutable; the fonts keep their names across a font upgrade, and the
  # four pages must never be served stale after a deploy.
  StaticAssetCache* = "public, max-age=31536000, immutable"
  StaticFontCache* = "public, max-age=86400"
  StaticNoStore* = "no-store"

  # DEC-20, the admin gate. The token is one shared secret in its own file, never a
  # config key and never a command-line argument, so it cannot leak through
  # /admin/config, `ps` or a shell history. The path is fixed here only as a
  # default: the host points KORI_ADMIN_TOKEN_FILE at wherever it keeps the file.
  DefaultAdminTokenFile* = "/etc/kori/admin.token"
  AdminTokenEnv* = "KORI_ADMIN_TOKEN_FILE"
  ## DEC-27. The write surface has its own token file. A read deployment keeps no
  ## write token at all, and then every write answers the same 404 the read gate
  ## answers without a token: an unconfigured host does not advertise the surface.
  DefaultAdminWriteTokenFile* = "/etc/kori/admin-write.token"
  AdminWriteTokenEnv* = "KORI_ADMIN_WRITE_TOKEN_FILE"
  ## A write session is short on purpose: it can switch a provider off, and the
  ## read cookie already lives for thirty days.
  AdminWriteSessionTtlS* = 43_200.0
  AdminCookieName* = "kori_admin"
  ## 32 random bytes, base64url, unpadded: 43 characters of URL-safe alphabet, so
  ## the value needs no quoting in a cookie and carries no `=`.
  AdminSessionBytes* = 32
  ## Thirty days, the owner's call: one paste of the token covers a working month.
  ## The cost is that a stolen cookie, not just a copied token, stays useful that
  ## long, so a suspected leak means rotating the token and restarting kori-api.
  AdminSessionTtlS* = 2_592_000.0
  ## A restart invalidates every session, and the cap is what stops a caller that
  ## keeps logging in from growing the table without bound.
  MaxAdminSessions* = 256
  ## Five failed logins in five minutes, counted globally: behind Caddy every
  ## request arrives from one address, so a per-IP window would be one window.
  ## DEC-21: the window throttles the *failed* attempt. A correct token is
  ## compared first and always gets its session, because the surface is reachable
  ## unauthenticated and a window that refused the credential let anyone lock the
  ## owner out with five wrong tokens every five minutes.
  MaxAdminLoginFailures* = 5
  AdminLoginWindowS* = 300.0
  ## A login body is two short strings. The HTTP layer has already read the body by the
  ## time the handler runs, so this cap does not limit the read; it stops an oversized
  ## body from reaching parseJson. The gateway's own body limit bounds the read.
  MaxLoginBodyBytes* = 8_192

  # The seven failure classes plus the one log-only value (§3.1, §5.1).
  TokenAuth401* = "auth_401"
  TokenMissingSession* = "missing_session_id"
  TokenConnRefused* = "conn_refused"
  TokenDialTimeout* = "dial_timeout"
  TokenHeaderTimeout* = "header_timeout"
  TokenUpstream5xx* = "upstream_5xx"
  TokenQuota429* = "quota_429"
  TokenBilling402* = "billing_402"
  ## DEC-26. A 429 whose body is not a quota: a rate limit that may clear in
  ## seconds. It is its own class so it never inherits the 900 s capacity rung.
  TokenRateLimited* = "rate_limited_429"
  TokenMidStreamAbort* = "mid_stream_abort"

  ## The caller hung up before the answer was finished. It is not a leg failure:
  ## the leg was healthy and the stream it produced was the one the caller stopped
  ## reading. It cools nothing, fails over to nothing, and is its own value so a
  ## push of abandoned requests cannot be read as a provider going bad. An
  ## OpenAI-shaped client signals this by closing the socket; there is no separate
  ## cancel frame in SSE, so one name covers it instead of two that nothing could
  ## tell apart.
  TokenCallerFault* = "caller_fault"

  # Log-only values, not failure classes: a request that cannot refresh its
  # credential stops where it is, so nothing is failed over and nothing is cooled
  # (§4). They appear in `failover_reason` and nowhere else.
  TokenRefreshFailed* = "credential_refresh_failed"
  TokenRefreshTimeout* = "refresh_timeout"

  # Item 2. `kori/<alias>` is a gateway name, never a provider id, and the two
  # reasons an alias request can carry are its own.
  AliasPrefix* = "kori/"
  TokenAliasUnmapped* = "alias_unmapped"
  TokenUnknownAlias* = "unknown_alias"
  ## DEC-27. The alias is mapped, and the operator switched it off from the
  ## dashboard. A caller can tell this from a name the config never had.
  TokenAliasDisabled* = "alias_disabled"
  TokenAliasTooLong* = "alias_too_long"

  ## Item 3. The alias is echoed into the request log, so it is bounded far below
  ## MaxRequestBytes: 256 bytes is longer than any real alias and short enough
  ## that one request cannot widen a log line.
  MaxAliasBytes* = 256

  ## The log carries the caller's string with its `kori/` prefix, so the budget
  ## for a log value is the alias limit plus that prefix. A legal 256-byte name
  ## has to survive whole, or its row stops matching its own `?alias=` filter.
  MaxAliasLogBytes* = MaxAliasBytes + AliasPrefix.len

  ## Retention (0.7.0). Rotation is opt-in through `log.rotate_bytes`, because
  ## "append-only" is the promise this file makes to whoever reads it after an
  ## incident: a gateway that silently renames the log it was told to keep is a
  ## worse instrument than one that grows. 0 turns it off, which is the default.
  DefaultLogKeep* = 2
  MaxLogKeep* = 20

  ## Latency buckets for /metrics, in milliseconds, plus the implicit +Inf.
  LatencyBucketsMs* = [50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000]

  ## Effort ranks, smallest to largest. A leg lists the values it accepts; a
  ## request above the leg's ceiling is clamped DOWN to the highest value the leg
  ## still accepts, and never up, because spending more than the caller asked for
  ## is a cost decision nobody made. A value outside this table is not ranked and
  ## is forwarded untouched: kori does not invent a position for a name it does
  ## not know, and the leg's own validation is the authority on it.
  EffortRanks* = ["minimal", "none", "low", "medium", "high", "xhigh", "max"]

  ## Every leg skipped for effort is a client error with a body that names the
  ## value, the same shape `unknown_alias` uses: the caller can fix it.
  TokenEffortUnsupported* = "effort_unsupported"

type
  CliError* = object of CatchableError
  ConfigError* = object of CatchableError

  LegRole* = enum
    lrPrimary = "primary"
    lrFallback = "fallback"

  Oauth* = object
    ## SPEC §4. The endpoint and the client identity are data: nothing here is a
    ## vendor URL this binary assumes. A leg without this block keeps api_key.
    tokenUrl*: string
    clientId*: string
    clientSecret*: string
    refreshToken*: string
    accessToken*: string
    expiresAt*: float           ## epoch seconds, 0 when the config does not say
    refreshSkewSeconds*: int

  Leg* = object
    name*: string
    baseUrl*: string
    apiKey*: string
    apiKeys*: seq[string]      ## the pool; `api_key` is a pool of one when this is empty
    model*: string
    hasModel*: bool          ## `model` came from the config, so it is sent upstream
    headers*: seq[(string, string)]
    role*: LegRole
    weight*: int
    retries*: int              ## extra dials on this leg before it is classed failed
    oauth*: Oauth
    hasOauth*: bool
    enabled*: bool             ## effective: the file's value after `overrides.legs`
    enabledFile*: bool         ## the leg's own `enabled`, before any override
    aliases*: Table[string, string]  ## `kori/<alias>` -> this leg's provider id
    efforts*: seq[string]      ## the reasoning_effort values this leg accepts
    hasEfforts*: bool          ## `efforts` came from the config, so the ceiling applies

  Price* = object
    ## USD per million tokens, both directions. A model with no entry costs
    ## nothing to record: the log leaves `cost_usd` out rather than printing 0,
    ## because "not priced" and "free" are different facts.
    usdIn*: float
    usdOut*: float

  SystemoneLeg* = object
    ## DEC-19. A System One endpoint is not a chat leg and never enters the chat
    ## walk: it answers a decision, not a completion. It keeps its own ordered
    ## list, cooldowns and counters, and the same one-line log.
    name*: string
    baseUrl*: string
    apiKey*: string
    model*: string            ## the provider id sent upstream; "" forwards the caller's
    headers*: seq[(string, string)]
    weight*: int              ## DEC-28: its share of the pick when `systemone_balance` is on
    enabled*: bool

  Config* = object
    listenHost*: string
    listenPort*: int
    logPath*: string
    logRotateBytes*: int64   ## 0 keeps the single append-only file, which is the default
    logKeep*: int            ## rotated files kept beside the live one
    balance*: bool
    ## DEC-28. Its own switch, default false: turning the chat door's balancing on
    ## must not re-order System One traffic underneath the operator.
    systemoneBalance*: bool
    legs*: seq[Leg]
    prices*: Table[string, Price]  ## by model id, plus "*" for the fallback
    systemone*: seq[SystemoneLeg]  ## `POST /v1/systemone` upstreams, in config order
    # DEC-26. The streaming header deadline is a rule, and its three numbers are
    # data: an operator tunes them from the config, not from a rebuild.
    headerStreamBaseMs*: int
    headerStreamPerKiBMs*: int
    headerStreamMaxMs*: int
    headerNonStreamMs*: int
    # DEC-27. The dashboard's switches, kept in their own block so the leg objects
    # (and every credential byte among them) are never rewritten by a toggle.
    overridesLegs*: Table[string, bool]
    overridesModels*: Table[string, bool]
    overridesUpdatedAt*: string

  CliOptions* = object
    configPath*: string
    address*: string
    port*: int
    logPath*: string
    hasAddress*: bool
    hasPort*: bool
    hasLog*: bool
    help*: bool

  RequestLog* = object
    fd*: cint
    path*: string
    rotateBytes*: int64
    keep*: int
    bytes*: int64            ## what this process has written to the live file
    justRotated*: bool       ## set for the append that opened a fresh file
    failing*: bool           ## the last append failed; one stderr line per outage

  LegRuntime* = object
    attempted*: bool
    coolingUntil*: float        ## epoch seconds, 0 when the leg is not cooling
    probeInFlight*: bool        ## one half-open probe at a time
    lastFailureClass*: string
    lastFailureAt*: string
    lastSuccessAt*: string
    servedInWindow*: int
    failedInWindow*: int
    ## DEC-23: how many header timeouts came in a row without a served request,
    ## which is what the 5 s ladder doubles on. Any success resets it.
    headerTimeouts*: int
    latencies*: seq[int]
    ## Key pool state (P1). `keyIndex` is the pool entry in use; a dead key is
    ## skipped by `keyCooling` until its own cooldown expires. Only the index is
    ## observable, never the key.
    keyIndex*: int
    keyCooling*: seq[float]     ## epoch seconds per pool entry, 0 when live
    ## DEC-11: smooth weighted round-robin credit, never negative.
    weightCurrent*: int

  SystemoneRuntime* = object
    ## DEC-19. The same two facts the chat router keeps per leg, minus the things
    ## only a chat walk needs: no cursor, no key pool. DEC-28 adds the weighted
    ## pick's credit, because `balance` now selects the first System One leg.
    attempted*: bool
    coolingUntil*: float
    lastFailureClass*: string
    lastFailureAt*: string
    lastSuccessAt*: string
    ## DEC-23, the same ladder the chat door keeps: consecutive header timeouts
    ## with no served request in between.
    headerTimeouts*: int
    ## DEC-28: smooth weighted round-robin credit, never negative.
    weightCurrent*: int

  FailoverEvent* = object
    at*: string
    fromRoute*: string
    toRoute*: string
    reason*: string

  AdminScope* = enum
    asRead = "read"
    asWrite = "write"

  AdminSession* = object
    ## DEC-27. The scope and the token that minted the session live beside the
    ## expiry. A write token rotated on disk therefore invalidates its own
    ## sessions on the next request, and a read session can never be upgraded.
    expiresAt*: float
    scope*: AdminScope
    tokenHash*: Hash

  Metrics* = object
    ## Counters /metrics prints. Everything here is already decided elsewhere in
    ## the request path, so this is a tally, never a second source of truth: no
    ## leg state, no cooldown time, nothing that /admin/state also owns.
    requestsByRoute*: Table[string, int]
    logWriteFailures*: int       ## request-log lines that never reached the file
    failoversByReason*: Table[string, int]
    cooldownsByRoute*: Table[string, int]
    cooldownStarts*: Table[string, int]
    statusClasses*: Table[string, int]
    latency*: seq[int]           ## bucket counts, LatencyBucketsMs.len + 1 for +Inf
    latencySumMs*: float
    latencyCount*: int

  RefreshOutcome* = object
    ok*: bool
    timedOut*: bool
    detail*: string             ## for stderr only; never carries a credential

  OauthState* = object
    ## The live credential. `inFlight` is the single-flight latch: one token call
    ## per leg at a time, and every other request waits on that same future.
    accessToken*: string
    refreshToken*: string
    expiresAt*: float
    inFlight*: Future[RefreshOutcome]

  Gateway* = ref object
    cfg: Config
    log: RequestLog
    startedAt: string
    listenAddr: string
    requests*: int
    inFlight*: int             ## requests being served right now; read by the drain
    failoverAvailability*: int
    failoverCapacity*: int
    tokensInTotal*: int
    tokensOutTotal*: int
    cursor: int
    ssl*: SslContext
    legs*: seq[LegRuntime]
    systemone*: seq[SystemoneRuntime]
    oauth*: seq[OauthState]
    events*: seq[FailoverEvent]
    configPath*: string
    configModifiedAt*: string
    credentialRefs*: seq[string]
    logLines*: int
    staticFiles: Table[string, StaticFile]
    metrics*: Metrics
    costUsdTotal*: float         ## sum of cost_usd over the window, dollars
    costUsdKnown*: int           ## how many requests carried a priced answer
    reloads*: int                ## SIGHUP reloads that were applied
    lastReloadAt*: string
    lastReloadError*: string
    cli*: CliOptions             ## kept so a reload applies the same precedence
    # DEC-20. The gate's own state, all of it in memory: a restart empties the
    # session table on purpose, and nothing here is written to disk or logged.
    sessions*: Table[string, AdminSession]  ## session id -> expiry, scope, token
    loginFailures*: seq[float]        ## epochs of the read-token failures in the window
    writeLoginFailures*: seq[float]   ## the same window, counted apart for writes
    # DEC-27. What the write surface has done since the process started. Counters
    # only: no token, no session id, no config value a caller sent.
    adminWrites*: int
    lastAdminWriteAt*: string
    lastAdminWriteAction*: string

  RecvKind = enum
    rkData, rkEof, rkTruncated, rkTimeout, rkError

  RecvOut = object
    kind: RecvKind
    data: string

  BodyMode = enum
    bmLength, bmChunked, bmEof

  UpstreamReader = ref object
    socket: AsyncSocket
    buf: string
    mode: BodyMode
    remaining: int          ## bmLength bytes still owed
    chunkRemaining: int     ## bmChunked bytes left in the current chunk
    needCrlf: bool          ## a chunk's trailing CRLF is still unread
    finished: bool

  AttemptKind = enum
    akFailed,       ## the leg produced no usable response; fail over
    akServed,       ## a response was delivered to the caller
    akAborted,      ## a response died after the caller saw it (§5.3)
    akPassthrough,  ## a client error returned unchanged (§3.3)
    akTerminal      ## headers arrived, no body, no failover (§3b.2)

  AttemptOutcome = object
    kind: AttemptKind
    status: int
    reason: string
    tokensIn: Option[int]
    tokensOut: Option[int]
    headerWindowMs: int      ## the header deadline this attempt actually waited
    headerMs: int            ## ms from body sent to first response byte, -1 unknown
    retryAfterS: int         ## upstream Retry-After, -1 when absent or not a number
    passthroughBody: string  ## a 429 body kept so the last leg can return it honestly

  Chain = object
    firstFrom: string
    firstReason: string
    lastReason: string
    availability: bool
    capacity: bool

var logFdToClose: cint = -1
## DEC-27. Raised by the config write path and by SIGHUP, read by the main loop
## when no request is in flight. The write path needs it before its own proc, so
## the flag lives up here rather than beside the signal handlers.
var reloadRequested {.volatile.}: bool = false

# ---------------------------------------------------------------- CLI flags ---

proc usageLine(): string =
  "usage: kori --config <path> [--address <ipv4-literal>] [--port <1-65535>] " &
  "[--log <path>] [--help]"

proc usageText(): string =
  usageLine() & "\n\n" &
  "  --config   path to the JSON config file; required, no default\n" &
  "  --address  listener address; overrides listen.host, then " & DefaultHost & "\n" &
  "  --port     listener port; overrides listen.port, then " & $DefaultPort & "\n" &
  "  --log      request log path; overrides log.path, and one of the two is required\n" &
  "  --help     this text, on stdout, exit 0\n\n" &
  "Both '--flag value' and '--flag=value' are accepted. Precedence is\n" &
  "CLI > config > built-in default. Exit codes: 0 clean, 2 bad config or CLI,\n" &
  "1 anything else.\n"

proc failCli(msg: string) =
  raise newException(CliError, msg)

proc isIpLiteral(value: string): bool =
  try:
    discard parseIpAddress(value)
    result = true
  except ValueError:
    result = false

proc parsePort(value: string): int =
  try:
    result = parseInt(value.strip())
  except ValueError:
    failCli("--port is not an integer: '" & value & "'")
  if result < 1 or result > 65535:
    failCli("--port is not 1-65535: '" & value & "'")

proc parseCli*(args: seq[string]): CliOptions =
  ## `args` is the argv without the program name.
  const valueFlags = ["--config", "--address", "--port", "--log"]
  var i = 0
  while i < args.len:
    let arg = args[i]
    if not arg.startsWith("--"):
      failCli("unexpected argument '" & arg & "'")
    var name = arg
    var value = ""
    var inlineValue = false
    let eq = arg.find('=')
    if eq >= 0:
      name = arg[0 ..< eq]
      value = arg[eq + 1 .. ^1]
      inlineValue = true
    if name == "--help":
      if inlineValue:
        failCli("--help takes no value")
      result.help = true
      inc i
      continue
    if name notin valueFlags:
      failCli("unknown flag '" & name & "'")
    if not inlineValue:
      if i + 1 >= args.len:
        failCli(name & " needs a value")
      value = args[i + 1]
      inc i
    case name
    of "--config":
      result.configPath = value
    of "--address":
      if not isIpLiteral(value):
        failCli("--address is not an IP literal: '" & value & "'")
      result.address = value
      result.hasAddress = true
    of "--port":
      result.port = parsePort(value)
      result.hasPort = true
    of "--log":
      result.logPath = value
      result.hasLog = true
    else:
      discard
    inc i
  if result.help:
    return
  if result.configPath.len == 0:
    failCli("--config is required")

# ------------------------------------------------------------------- config ---

proc failConfig(msg: string) =
  raise newException(ConfigError, msg)

proc optionalString(node: JsonNode, key, ctx: string): string =
  let child = node{key}
  if child == nil or child.kind == JNull:
    return ""
  if child.kind != JString:
    failConfig(ctx & "." & key & " must be a string")
  child.getStr()

proc effortRank*(effort: string): int =
  ## The position of `effort` in `EffortRanks`, or -1 when this gateway does not
  ## rank that name. -1 is a real answer, not an error: an unranked value is one
  ## kori cannot compare, so it is forwarded untouched rather than guessed at.
  for index, name in EffortRanks:
    if name == effort:
      return index
  -1

proc loadConfigText*(raw, path: string): Config =
  ## The parse of one config document, separated from the read so the write path
  ## can validate a patched document before it replaces the file on disk.
  result.headerStreamBaseMs = HeaderDeadlineStreamMs
  result.headerStreamPerKiBMs = HeaderDeadlineStreamPerKiBMs
  result.headerStreamMaxMs = HeaderDeadlineStreamMaxMs
  result.headerNonStreamMs = HeaderDeadlineNonStreamMs
  result.overridesLegs = initTable[string, bool]()
  result.overridesModels = initTable[string, bool]()
  var root: JsonNode
  try:
    root = parseJson(raw)
  except CatchableError:
    failConfig("config '" & path & "' is not valid JSON")
  if root.kind != JObject:
    failConfig("config '" & path & "' must be a JSON object")

  let listen = root{"listen"}
  if listen != nil and listen.kind != JNull:
    if listen.kind != JObject:
      failConfig("listen must be an object")
    result.listenHost = optionalString(listen, "host", "listen")
    let port = listen{"port"}
    if port != nil and port.kind != JNull:
      if port.kind != JInt:
        failConfig("listen.port must be an integer")
      result.listenPort = port.getInt()
      if result.listenPort < 1 or result.listenPort > 65535:
        failConfig("listen.port is not 1-65535")

  let logNode = root{"log"}
  if logNode != nil and logNode.kind != JNull:
    if logNode.kind != JObject:
      failConfig("log must be an object")
    result.logPath = optionalString(logNode, "path", "log")
    # Retention is off unless asked for: an append-only log that renames itself
    # without being told is worse evidence than one that grows.
    let rotate = logNode{"rotate_bytes"}
    if rotate != nil and rotate.kind != JNull:
      if rotate.kind != JInt:
        failConfig("log.rotate_bytes must be an integer")
      if rotate.getInt() < 0:
        failConfig("log.rotate_bytes must not be negative")
      result.logRotateBytes = int64(rotate.getInt())
    result.logKeep = DefaultLogKeep
    let keep = logNode{"keep"}
    if keep != nil and keep.kind != JNull:
      if keep.kind != JInt:
        failConfig("log.keep must be an integer")
      if keep.getInt() < 1 or keep.getInt() > MaxLogKeep:
        failConfig("log.keep must be 1-" & $MaxLogKeep)
      result.logKeep = keep.getInt()

  # DEC-26. The four deadline numbers, with the compiled defaults. A value the
  # config does not name keeps the number this binary shipped with.
  let timeouts = root{"timeouts"}
  if timeouts != nil and timeouts.kind != JNull:
    if timeouts.kind != JObject:
      failConfig("timeouts must be an object")
    for key, spec in timeouts:
      if key notin ["header_ms_stream_base", "header_ms_stream_slope_per_kib",
                    "header_ms_stream_max", "header_ms_non_stream"]:
        failConfig("timeouts." & key & " is not a known timeout")
      if spec.kind != JInt:
        failConfig("timeouts." & key & " must be an integer")
      let value = spec.getInt()
      case key
      of "header_ms_stream_base":
        if value < 100 or value > 600_000:
          failConfig("timeouts.header_ms_stream_base must be 100-600000")
        result.headerStreamBaseMs = value
      of "header_ms_stream_slope_per_kib":
        if value < 0 or value > 1_000:
          failConfig("timeouts.header_ms_stream_slope_per_kib must be 0-1000")
        result.headerStreamPerKiBMs = value
      of "header_ms_stream_max":
        if value < 100 or value > 600_000:
          failConfig("timeouts.header_ms_stream_max must be 100-600000")
        result.headerStreamMaxMs = value
      of "header_ms_non_stream":
        if value < 100 or value > 600_000:
          failConfig("timeouts.header_ms_non_stream must be 100-600000")
        result.headerNonStreamMs = value
      else: discard
  if result.headerStreamBaseMs > result.headerStreamMaxMs:
    failConfig("timeouts.header_ms_stream_base must not exceed header_ms_stream_max")

  # Prices are money, so they are data in the config and never a constant in the
  # binary. USD per million tokens, both directions, keyed by the model id that is
  # actually sent upstream; `*` is the catch-all for a model with no entry.
  let prices = root{"prices"}
  if prices != nil and prices.kind != JNull:
    if prices.kind != JObject:
      failConfig("prices must be an object")
    for model, spec in prices:
      if model.len == 0:
        failConfig("prices has an empty model id")
      if spec.kind != JObject:
        failConfig("prices." & model & " must be an object")
      var price = Price()
      for direction in ["in", "out"]:
        let value = spec{direction}
        if value == nil or value.kind == JNull:
          continue
        var amount: float
        case value.kind
        of JInt: amount = value.getInt().float
        of JFloat: amount = value.getFloat()
        else:
          failConfig("prices." & model & "." & direction & " must be a number")
        if amount < 0:
          failConfig("prices." & model & "." & direction & " must not be negative")
        if direction == "in": price.usdIn = amount else: price.usdOut = amount
      result.prices[model] = price

  let balance = root{"balance"}
  if balance != nil and balance.kind != JNull:
    if balance.kind != JBool:
      failConfig("balance must be true or false")
    result.balance = balance.getBool()

  let systemoneBalance = root{"systemone_balance"}
  if systemoneBalance != nil and systemoneBalance.kind != JNull:
    if systemoneBalance.kind != JBool:
      failConfig("systemone_balance must be true or false")
    result.systemoneBalance = systemoneBalance.getBool()

  let legs = root{"legs"}
  if legs == nil or legs.kind != JArray:
    failConfig("config needs a legs array")
  for index in 0 ..< legs.len:
    let item = legs[index]
    let ctx = "legs[" & $index & "]"
    if item.kind != JObject:
      failConfig(ctx & " must be an object")
    var leg = Leg(role: lrPrimary, weight: 1)
    leg.name = optionalString(item, "name", ctx)
    if leg.name.len == 0:
      failConfig(ctx & ".name is required")
    leg.baseUrl = optionalString(item, "base_url", ctx)
    if leg.baseUrl.len == 0:
      failConfig(ctx & ".base_url is required")
    leg.apiKey = optionalString(item, "api_key", ctx)
    # P1 key pool: `api_keys` is an ordered pool, rotated on a 401 or a quota
    # 429. `api_key` stays supported and is the pool of one when this is absent,
    # so no config in use has to change.
    let apiKeysNode = item{"api_keys"}
    if apiKeysNode != nil and apiKeysNode.kind != JNull:
      if apiKeysNode.kind != JArray:
        failConfig(ctx & ".api_keys must be an array of strings")
      for keyIndex in 0 ..< apiKeysNode.len:
        let value = apiKeysNode[keyIndex]
        if value.kind != JString or value.getStr().len == 0:
          failConfig(ctx & ".api_keys[" & $keyIndex & "] must be a non-empty string")
        leg.apiKeys.add(value.getStr())
      if leg.apiKeys.len == 0:
        failConfig(ctx & ".api_keys must not be empty when the key is present")
    if leg.apiKeys.len == 0 and leg.apiKey.len > 0:
      leg.apiKeys.add(leg.apiKey)
    if leg.apiKeys.len > 1 and item{"oauth"} != nil and item{"oauth"}.kind == JObject:
      # A pool and an oauth block are two answers to the same question, and only
      # one of them can be the bearer. Refuse rather than pick silently.
      failConfig(ctx & " cannot carry both api_keys and oauth")

    # CONTRACT §1: model is optional; the leg name stands in, never a refusal.
    # A model the config names is also what kori sends upstream (DEC-10): the
    # three providers do not share model ids, so the leg's id replaces the
    # caller's on that leg alone. Without it the caller's model passes through.
    leg.model = optionalString(item, "model", ctx)
    if leg.model.len > 0:
      leg.hasModel = true
    else:
      leg.model = leg.name
    let headers = item{"headers"}
    if headers != nil and headers.kind != JNull:
      if headers.kind != JObject:
        failConfig(ctx & ".headers must be an object")
      for key, value in headers:
        if value.kind != JString:
          failConfig(ctx & ".headers." & key & " must be a string")
        leg.headers.add((key, value.getStr()))
    let role = item{"role"}
    if role != nil and role.kind != JNull:
      if role.kind != JString:
        failConfig(ctx & ".role must be a string")
      case role.getStr()
      of "primary": leg.role = lrPrimary
      of "fallback": leg.role = lrFallback
      else: failConfig(ctx & ".role must be primary or fallback")
    let weight = item{"weight"}
    if weight != nil and weight.kind != JNull:
      if weight.kind != JInt:
        failConfig(ctx & ".weight must be an integer")
      leg.weight = weight.getInt()
      # DEC-11, which supersedes DEC-8's refusal of every weight but 1: a weight
      # is now honoured, and it is a small integer so a share always has a defined
      # rounding. 0 or a negative weight would remove a leg from the split without
      # saying so, so it is refused; so is anything above the ceiling.
      if leg.weight < 1 or leg.weight > MaxWeight:
        failConfig(ctx & ".weight must be 1-" & $MaxWeight)
    # P1 retry: how many more dials this leg gets before the walk moves on. The
    # default is 0, so a config that does not name the key keeps 0.6.1's
    # failover-as-the-only-retry behaviour.
    let retries = item{"retries"}
    if retries != nil and retries.kind != JNull:
      if retries.kind != JInt:
        failConfig(ctx & ".retries must be an integer")
      leg.retries = retries.getInt()
      if leg.retries < 0 or leg.retries > MaxRetriesPerLeg:
        failConfig(ctx & ".retries must be 0-" & $MaxRetriesPerLeg)
    # Item 2. A leg can be switched off without leaving the chain, so the order the
    # operator wrote stays the order the walk uses.
    leg.enabled = true
    let enabledNode = item{"enabled"}
    if enabledNode != nil and enabledNode.kind != JNull:
      if enabledNode.kind != JBool:
        failConfig(ctx & ".enabled must be true or false")
      leg.enabled = enabledNode.getBool()
    leg.enabledFile = leg.enabled
    # Item 2. The alias table is per leg: one caller name, one provider id per leg.
    let aliasesNode = item{"aliases"}
    if aliasesNode != nil and aliasesNode.kind != JNull:
      if aliasesNode.kind != JObject:
        failConfig(ctx & ".aliases must be an object")
      for alias, value in aliasesNode:
        if alias.len == 0:
          failConfig(ctx & ".aliases has an empty alias name")
        if value.kind != JString or value.getStr().len == 0:
          failConfig(ctx & ".aliases." & alias & " must be a non-empty string")
        leg.aliases[alias] = value.getStr()
    # Item 4. A leg's effort ceiling. The list is the values this leg accepts;
    # a value outside the rank table is a typo in a config file, so it fails at
    # load with the leg and the value named instead of at request time.
    let effortsNode = item{"efforts"}
    if effortsNode != nil and effortsNode.kind != JNull:
      if effortsNode.kind != JArray:
        failConfig(ctx & ".efforts must be an array of strings")
      for effortIndex in 0 ..< effortsNode.len:
        let value = effortsNode[effortIndex]
        if value.kind != JString:
          failConfig(ctx & ".efforts[" & $effortIndex & "] must be a string")
        let effort = value.getStr()
        if effortRank(effort) < 0:
          failConfig(ctx & ".efforts[" & $effortIndex & "] '" & effort &
                     "' is not a known effort; expected one of " &
                     EffortRanks.join(", "))
        leg.efforts.add(effort)
      leg.hasEfforts = true
    # SPEC §4. A leg with no `oauth` block behaves exactly as it did before: one
    # static bearer from api_key.
    let oauth = item{"oauth"}
    if oauth != nil and oauth.kind != JNull:
      let octx = ctx & ".oauth"
      if oauth.kind != JObject:
        failConfig(octx & " must be an object")
      leg.hasOauth = true
      leg.oauth.tokenUrl = optionalString(oauth, "token_url", octx)
      if leg.oauth.tokenUrl.len == 0:
        failConfig(octx & ".token_url is required")
      let tokenUri = parseUri(leg.oauth.tokenUrl)
      if tokenUri.scheme notin ["http", "https"] or tokenUri.hostname.len == 0:
        failConfig(octx & ".token_url must be an http or https URL")
      leg.oauth.clientId = optionalString(oauth, "client_id", octx)
      if leg.oauth.clientId.len == 0:
        failConfig(octx & ".client_id is required")
      leg.oauth.clientSecret = optionalString(oauth, "client_secret", octx)
      leg.oauth.refreshToken = optionalString(oauth, "refresh_token", octx)
      if leg.oauth.refreshToken.len == 0:
        failConfig(octx & ".refresh_token is required")
      leg.oauth.accessToken = optionalString(oauth, "access_token", octx)
      leg.oauth.refreshSkewSeconds = DefaultRefreshSkewS
      let expiresAt = oauth{"expires_at"}
      if expiresAt != nil and expiresAt.kind != JNull:
        case expiresAt.kind
        of JInt: leg.oauth.expiresAt = expiresAt.getInt().float
        of JFloat: leg.oauth.expiresAt = expiresAt.getFloat()
        else:
          failConfig(octx & ".expires_at must be epoch seconds")
        if leg.oauth.expiresAt < 0:
          failConfig(octx & ".expires_at must not be negative")
      let skew = oauth{"refresh_skew_seconds"}
      if skew != nil and skew.kind != JNull:
        if skew.kind != JInt:
          failConfig(octx & ".refresh_skew_seconds must be an integer")
        leg.oauth.refreshSkewSeconds = skew.getInt()
        if leg.oauth.refreshSkewSeconds < 0:
          failConfig(octx & ".refresh_skew_seconds must not be negative")
    result.legs.add(leg)
  if result.legs.len == 0:
    failConfig("config needs at least one leg")

  # DEC-27. `overrides` is the dashboard's switch block: two maps of name -> bool.
  # It is parsed after the legs so a name that matches nothing is a load error
  # rather than a switch that silently does nothing.
  let overrides = root{"overrides"}
  if overrides != nil and overrides.kind != JNull:
    if overrides.kind != JObject:
      failConfig("overrides must be an object")
    for key, _ in overrides:
      if key notin ["legs", "models", "updated_at"]:
        failConfig("overrides." & key & " is not a known key")
    let updated = overrides{"updated_at"}
    if updated != nil and updated.kind != JNull:
      if updated.kind != JString:
        failConfig("overrides.updated_at must be a string")
      result.overridesUpdatedAt = updated.getStr()
    let legOverrides = overrides{"legs"}
    if legOverrides != nil and legOverrides.kind != JNull:
      if legOverrides.kind != JObject:
        failConfig("overrides.legs must be an object")
      for name, value in legOverrides:
        if value.kind != JBool:
          failConfig("overrides.legs." & name & " must be true or false")
        var known = false
        for leg in result.legs:
          if leg.name == name:
            known = true
            break
        if not known:
          failConfig("overrides.legs." & name & " names no leg")
        result.overridesLegs[name] = value.getBool()
    let modelOverrides = overrides{"models"}
    if modelOverrides != nil and modelOverrides.kind != JNull:
      if modelOverrides.kind != JObject:
        failConfig("overrides.models must be an object")
      for alias, value in modelOverrides:
        if value.kind != JBool:
          failConfig("overrides.models." & alias & " must be true or false")
        var known = false
        for leg in result.legs:
          if leg.aliases.hasKey(alias):
            known = true
            break
        if not known:
          failConfig("overrides.models." & alias & " names no model alias")
        result.overridesModels[alias] = value.getBool()
    for index in 0 ..< result.legs.len:
      let name = result.legs[index].name
      if result.overridesLegs.hasKey(name):
        result.legs[index].enabled = result.overridesLegs[name]

  # DEC-19. `systemone` is a second door with its own ordered legs. It is
  # optional: a config without it serves the chat door exactly as before and
  # answers 404 on `/v1/systemone`, so no existing config changes behaviour.
  let systemone = root{"systemone"}
  if systemone != nil and systemone.kind != JNull:
    if systemone.kind != JObject:
      failConfig("systemone must be an object")
    let soLegs = systemone{"legs"}
    if soLegs == nil or soLegs.kind != JArray:
      failConfig("systemone needs a legs array")
    for index in 0 ..< soLegs.len:
      let item = soLegs[index]
      let ctx = "systemone.legs[" & $index & "]"
      if item.kind != JObject:
        failConfig(ctx & " must be an object")
      var leg = SystemoneLeg(enabled: true)
      leg.name = optionalString(item, "name", ctx)
      if leg.name.len == 0:
        failConfig(ctx & ".name is required")
      leg.baseUrl = optionalString(item, "base_url", ctx)
      if leg.baseUrl.len == 0:
        failConfig(ctx & ".base_url is required")
      leg.apiKey = optionalString(item, "api_key", ctx)
      # Required here, unlike a chat leg: a System One request names a model, and
      # the whole point of this door is that kori owns which id reaches which
      # provider. An empty id would forward a caller string that commandcode
      # rejects with its own 400.
      leg.model = optionalString(item, "model", ctx)
      if leg.model.len == 0:
        failConfig(ctx & ".model is required")
      let headers = item{"headers"}
      if headers != nil and headers.kind != JNull:
        if headers.kind != JObject:
          failConfig(ctx & ".headers must be an object")
        for key, value in headers:
          if value.kind != JString:
            failConfig(ctx & ".headers." & key & " must be a string")
          leg.headers.add((key, value.getStr()))
      let enabledNode = item{"enabled"}
      if enabledNode != nil and enabledNode.kind != JNull:
        if enabledNode.kind != JBool:
          failConfig(ctx & ".enabled must be true or false")
        leg.enabled = enabledNode.getBool()
      # DEC-28. The same 1-1000 share as a chat leg, and the same reason for
      # refusing 0: it would silently remove a leg from the split. Absent means 1,
      # so every config written before this key existed balances evenly.
      let weightNode = item{"weight"}
      if weightNode != nil and weightNode.kind != JNull:
        if weightNode.kind != JInt:
          failConfig(ctx & ".weight must be an integer")
        leg.weight = weightNode.getInt()
        if leg.weight < 1 or leg.weight > MaxWeight:
          failConfig(ctx & ".weight must be 1-" & $MaxWeight)
      else:
        leg.weight = 1
      result.systemone.add leg
    if result.systemone.len == 0:
      failConfig("systemone.legs must not be empty when the block is present")

proc loadConfig*(path: string): Config =
  var raw: string
  try:
    raw = readFile(path)
  except CatchableError as e:
    failConfig("cannot read config '" & path & "': " & e.msg)
  loadConfigText(raw, path)

proc applyCli*(cfg: var Config, cli: CliOptions) =
  ## CLI > config > built-in default, in that order (CONTRACT §2).
  if cli.hasAddress:
    cfg.listenHost = cli.address
  elif cfg.listenHost.len == 0:
    cfg.listenHost = DefaultHost
  if not isIpLiteral(cfg.listenHost):
    failConfig("listen address is not an IP literal: '" & cfg.listenHost & "'")
  if cli.hasPort:
    cfg.listenPort = cli.port
  elif cfg.listenPort == 0:
    cfg.listenPort = DefaultPort
  if cli.hasLog:
    cfg.logPath = cli.logPath
  if cfg.logPath.len == 0:
    failConfig("no log path: pass --log or set log.path in the config")

# ---------------------------------------------------------------- log writer ---

proc jsonEscape*(value: string): string =
  result = newStringOfCap(value.len + 2)
  result.add '"'
  for ch in value:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      if ord(ch) < 0x20:
        result.add "\\u" & toHex(ord(ch), 4).toLowerAscii()
      else:
        result.add ch
  result.add '"'

proc jsonIntOrNull(value: Option[int]): string =
  if value.isSome: $value.get else: "null"

proc jsonUsd6*(value: float): string =
  ## Six decimals of a dollar is a tenth of a cent: below that a log line is
  ## noise, not money. Fixed form so two lines for the same request differ only
  ## when the numbers do.
  formatFloat(value, ffDecimal, 6)

proc jsonFloat6*(value: float): JsonNode =
  ## The same six-decimal number as `jsonUsd6`, as a JSON number rather than a
  ## string, so a dashboard can sum it without parsing text.
  parseJson(formatFloat(value, ffDecimal, 6))

proc requestLogLine*(ts, route: string, status, latencyMs: int,
                     tokensIn, tokensOut: Option[int],
                     failoverFrom, failoverReason: string,
                     stream: bool, alias = "", effortClamped = "",
                     costUsd = none(float), promptKib = -1, headerMs = -1,
                     legsCooling = -1, retryAfterS = -1): string =
  ## The nine keys of SPEC §5.1 in that order, plus `alias` as a tenth when the
  ## caller named a gateway alias, plus `effort_clamped` as an eleventh when the
  ## leg's ceiling pulled the requested effort down, plus `cost_usd` as a twelfth
  ## when the config prices the model that served. All three extra keys are
  ## conditional and come last: a request that named no alias, never clamped and
  ## ran on an unpriced model carries exactly the nine. Redaction is structural
  ## (R17): no header, no body and no credential is a parameter here, so there is
  ## nothing for a later pass to strip. "no alias" and "an empty alias" are
  ## different facts, and only the first one reaches this proc; the same holds for
  ## a clamp that never happened and for a model the config does not price.
  result = "{\"ts\":" & jsonEscape(ts) &
    ",\"route\":" & jsonEscape(route) &
    ",\"status\":" & $status &
    ",\"latency_ms\":" & $latencyMs &
    ",\"tokens_in\":" & jsonIntOrNull(tokensIn) &
    ",\"tokens_out\":" & jsonIntOrNull(tokensOut) &
    ",\"failover_from\":" & jsonEscape(failoverFrom) &
    ",\"failover_reason\":" & jsonEscape(failoverReason) &
    ",\"stream\":" & (if stream: "true" else: "false")
  if alias.len > 0:
    result.add ",\"alias\":" & jsonEscape(alias)
  if effortClamped.len > 0:
    result.add ",\"effort_clamped\":" & jsonEscape(effortClamped)
  if costUsd.isSome:
    result.add ",\"cost_usd\":" & jsonUsd6(costUsd.get)
  # DEC-26. Four more optional keys, last for the same reason as the three above:
  # a line written by an older binary still parses, and a reader that knows only
  # the nine keys sees the same row it always did.
  if promptKib >= 0:
    result.add ",\"prompt_kib\":" & $promptKib
  if headerMs >= 0:
    result.add ",\"header_ms\":" & $headerMs
  if legsCooling >= 0:
    result.add ",\"legs_cooling\":" & $legsCooling
  if retryAfterS >= 0:
    result.add ",\"retry_after_s\":" & $retryAfterS
  result.add "}"

proc openRequestLog*(path: string, rotateBytes: int64 = 0,
                     keep = DefaultLogKeep): RequestLog =
  ## Opened once, for the process lifetime: O_WRONLY|O_CREAT|O_APPEND, mode 0640.
  let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_APPEND,
                      Mode(LogFileMode))
  if fd < 0:
    failConfig("cannot open log '" & path & "': errno " & $errno)
  result.fd = fd
  result.path = path
  result.rotateBytes = rotateBytes
  result.keep = keep
  try:
    result.bytes = getFileSize(path)
  except CatchableError:
    result.bytes = 0
  logFdToClose = fd

proc rotateLog*(log: var RequestLog): bool =
  ## Close, shift `<path>.<n>` one place up, move the live file to `.1`, reopen.
  ## A failed shift is reported and the old fd is kept, so a rotation that could
  ## not happen loses no request line; the file simply keeps growing.
  let path = log.path
  discard posix.close(log.fd)
  logFdToClose = -1
  try:
    # Oldest first, so the file about to be overwritten is gone before any move.
    let oldest = path & "." & $log.keep
    if fileExists(oldest):
      removeFile(oldest)
    var index = log.keep - 1
    while index >= 1:
      let source = path & "." & $index
      if fileExists(source):
        moveFile(source, path & "." & $(index + 1))
      dec index
    if fileExists(path):
      moveFile(path, path & ".1")
  except CatchableError as error:
    stderr.writeLine("kori: log rotation failed: " & error.msg &
                     " (continuing in the current file)")
    let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_APPEND,
                        Mode(LogFileMode))
    if fd >= 0:
      log.fd = fd
      logFdToClose = fd
    else:
      # The fd this proc closed is still in `log.fd`. Keeping that number is a
      # real hazard: the kernel hands it to the next open, and the log would then
      # write request lines into whatever that turns out to be. -1 makes
      # appendLine reopen by path instead.
      log.fd = -1
    return false
  let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_APPEND,
                      Mode(LogFileMode))
  if fd < 0:
    stderr.writeLine("kori: cannot reopen log after rotation: errno " & $errno)
    log.fd = -1
    return false
  log.fd = fd
  logFdToClose = fd
  log.bytes = 0
  log.justRotated = true
  true

proc reopenLog(log: var RequestLog): bool =
  ## After a rotation that could not reopen the file, the fd is -1. Writing to it
  ## fails on every request, so each append retries the open once: the disk may
  ## have room again, or the mount may be back.
  let fd = posix.open(log.path.cstring, O_WRONLY or O_CREAT or O_APPEND,
                      Mode(LogFileMode))
  if fd < 0:
    return false
  log.fd = fd
  logFdToClose = fd
  # The byte counter follows the file this process is now writing to, not the one
  # it lost, or the next rotation would fire at the wrong size.
  try:
    log.bytes = getFileSize(log.path)
  except CatchableError:
    log.bytes = 0
  true

proc reportLogFailure(log: var RequestLog, detail: string) =
  ## The request path is the hot path: report the first failed append of an
  ## outage and the first one that succeeds after it, never one line per request.
  if not log.failing:
    log.failing = true
    stderr.writeLine("kori: request log is not being written: " & detail)

proc appendLine*(log: var RequestLog, line: string): bool =
  ## One write(2) carrying the whole line including its newline (CONTRACT §3). A
  ## short write is left short rather than spliced: a partial line is honest, two
  ## interleaved requests are not. Returns false whenever the line did not reach
  ## the file, so the caller can tally it; the line it writes to stderr is one
  ## per outage, not one per request.
  let data = line & "\n"
  log.justRotated = false
  # Rotation is checked against the size this process has accounted for, so a
  # request never has to stat the file. The check runs before the write, so a
  # rotation never splits a line.
  if log.rotateBytes > 0 and log.bytes > 0 and
     log.bytes + int64(data.len) > log.rotateBytes:
    if log.rotateLog():
      log.bytes = 0
  if log.fd < 0 and not reopenLog(log):
    log.reportLogFailure("no open file for '" & log.path & "': errno " & $errno)
    return false
  var written = posix.write(log.fd, unsafeAddr data[0], data.len)
  if written < 0 and errno == EINTR:
    written = posix.write(log.fd, unsafeAddr data[0], data.len)
  if written != data.len:
    let detail = if written < 0: "errno " & $errno
                 else: "short write: " & $written & " of " & $data.len & " bytes"
    log.reportLogFailure(detail & " to '" & log.path & "'")
    return false
  if log.failing:
    log.failing = false
    stderr.writeLine("kori: request log is being written again: '" &
                     log.path & "'")
  log.bytes += int64(written)
  true

proc recordRequestLog*(gateway: Gateway, line: string) =
  ## Both request paths reach the file through here, so the answer to "did this
  ## line land" is tallied in one place. A lost line is the whole risk of this
  ## design: the gateway keeps serving, so only a counter can make it visible.
  if not gateway.log.appendLine(line):
    inc gateway.metrics.logWriteFailures
    return
  # After a rotation the live file starts at zero, so the total the page reports
  # is the one for the file it is actually reading.
  if gateway.log.justRotated:
    gateway.logLines = 1
  else:
    inc gateway.logLines

# ------------------------------------------------------------------- pricing ---

proc priceFor*(cfg: Config, model: string): Option[Price] =
  ## The model that answered, then the catch-all. A model the config does not
  ## price has no cost, which is a different fact from a cost of zero.
  if cfg.prices.hasKey(model):
    return some(cfg.prices[model])
  if cfg.prices.hasKey("*"):
    return some(cfg.prices["*"])
  none(Price)

proc requestCost*(cfg: Config, model: string, tokensIn,
                  tokensOut: Option[int]): Option[float] =
  ## USD for one request, from the provider's own counts only. A leg that
  ## reported no tokens yields no cost: an estimate invented here would end up in
  ## a monthly total nobody can reconcile.
  let price = priceFor(cfg, model)
  if price.isNone:
    return none(float)
  var total = 0.0
  var known = false
  if tokensIn.isSome:
    total += tokensIn.get.float * price.get.usdIn / 1_000_000.0
    known = true
  if tokensOut.isSome:
    total += tokensOut.get.float * price.get.usdOut / 1_000_000.0
    known = true
  if not known:
    return none(float)
  some(total)

# ------------------------------------------------------------------- metrics ---

proc promEscape*(value: string): string =
  ## The exposition format's own escaping for a label value: backslash, quote and
  ## newline. A route name comes from the config, but the config is not trusted to
  ## keep a text format parseable.
  for ch in value:
    case ch
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    else: result.add ch

proc bucketIndex(latencyMs: int): int =
  ## The first bucket whose ceiling covers this sample; the last slot is +Inf.
  for index, ceiling in LatencyBucketsMs:
    if latencyMs <= ceiling:
      return index
  LatencyBucketsMs.len

proc recordMetrics*(metrics: var Metrics, route: string, status: int,
                    latencyMs: int, failoverReason: string) =
  metrics.requestsByRoute.mgetOrPut(route, 0).inc
  let class = $((status div 100)) & "xx"
  metrics.statusClasses.mgetOrPut(class, 0).inc
  metrics.latency[bucketIndex(latencyMs)].inc
  metrics.latencySumMs += latencyMs.float
  metrics.latencyCount.inc
  # `failover_reason` is empty on a request that never failed over, and that
  # emptiness is not a reason: only a named reason becomes a series.
  if failoverReason.len > 0:
    metrics.failoversByReason.mgetOrPut(failoverReason, 0).inc

proc metricsText*(gateway: Gateway): string =
  ## Prometheus text exposition, type `prometheus`. Plain text and no library:
  ## the numbers are already tallied by the request path, so this proc only
  ## renders them. Labels are escaped as the format requires.
  var text = ""
  text.add "# HELP kori_requests_total Requests answered, by route.\n"
  text.add "# TYPE kori_requests_total counter\n"
  for route in gateway.metrics.requestsByRoute.keys:
    text.add "kori_requests_total{route=\"" & promEscape(route) & "\"} " &
            $gateway.metrics.requestsByRoute[route] & "\n"
  text.add "# HELP kori_responses_total Requests answered, by status class.\n"
  text.add "# TYPE kori_responses_total counter\n"
  for class in ["2xx", "4xx", "5xx"]:
    if gateway.metrics.statusClasses.hasKey(class):
      text.add "kori_responses_total{class=\"" & class & "\"} " &
              $gateway.metrics.statusClasses[class] & "\n"
  text.add "# HELP kori_failovers_total Failovers, by the reason the walk recorded.\n"
  text.add "# TYPE kori_failovers_total counter\n"
  for reason in gateway.metrics.failoversByReason.keys:
    text.add "kori_failovers_total{reason=\"" & promEscape(reason) & "\"} " &
            $gateway.metrics.failoversByReason[reason] & "\n"
  text.add "# HELP kori_route_cooldowns_total Cooldowns started on a route.\n"
  text.add "# TYPE kori_route_cooldowns_total counter\n"
  for route in gateway.metrics.cooldownStarts.keys:
    text.add "kori_route_cooldowns_total{route=\"" & promEscape(route) & "\"} " &
            $gateway.metrics.cooldownStarts[route] & "\n"
  text.add "# HELP kori_route_cooling Whether a route is cooling right now (1) or not (0).\n"
  text.add "# TYPE kori_route_cooling gauge\n"
  for index, leg in gateway.cfg.legs:
    let cooling = if gateway.legs[index].coolingUntil > epochTime(): 1 else: 0
    text.add "kori_route_cooling{route=\"" & promEscape(leg.name) & "\"} " &
            $cooling & "\n"
  # DEC-19: a System One leg is a route too, and a gauge that hid it would make a
  # cooling door look healthy. Names are the config's, so an operator who reuses a
  # name across the two doors merges two series on purpose.
  for index, leg in gateway.cfg.systemone:
    let cooling = if gateway.systemone[index].coolingUntil > epochTime(): 1 else: 0
    text.add "kori_route_cooling{route=\"" & promEscape(leg.name) & "\"} " &
            $cooling & "\n"
  text.add "# HELP kori_request_duration_ms Request latency in milliseconds.\n"
  text.add "# TYPE kori_request_duration_ms histogram\n"
  var cumulative = 0
  for index, ceiling in LatencyBucketsMs:
    cumulative += gateway.metrics.latency[index]
    text.add "kori_request_duration_ms_bucket{le=\"" & $ceiling & "\"} " &
            $cumulative & "\n"
  cumulative += gateway.metrics.latency[LatencyBucketsMs.len]
  text.add "kori_request_duration_ms_bucket{le=\"+Inf\"} " & $cumulative & "\n"
  text.add "kori_request_duration_ms_sum " & formatFloat(gateway.metrics.latencySumMs,
                                                        ffDecimal, 3) & "\n"
  text.add "kori_request_duration_ms_count " & $gateway.metrics.latencyCount & "\n"
  text.add "# HELP kori_cost_usd_total Cost of priced requests in this window, USD.\n"
  text.add "# TYPE kori_cost_usd_total counter\n"
  text.add "kori_cost_usd_total " & formatFloat(gateway.costUsdTotal, ffDecimal, 6) & "\n"
  text.add "# HELP kori_reloads_total Config reloads applied from SIGHUP.\n"
  text.add "# TYPE kori_reloads_total counter\n"
  text.add "kori_reloads_total " & $gateway.reloads & "\n"
  # The gateway keeps serving when the log cannot be written, so a lost request
  # line is invisible everywhere else. This counter is the only signal that the
  # artifact the whole gateway exists to produce stopped arriving.
  text.add "# HELP kori_log_write_failures_total Request-log lines that never reached the file.\n"
  text.add "# TYPE kori_log_write_failures_total counter\n"
  text.add "kori_log_write_failures_total " & $gateway.metrics.logWriteFailures & "\n"
  text.add "# HELP kori_info Build information, always 1.\n"
  text.add "# TYPE kori_info gauge\n"
  text.add "kori_info{version=\"" & promEscape(KoriVersion) & "\",revision=\"" &
          promEscape(KoriRevision) & "\"} 1\n"
  text

# --------------------------------------------------------------------- time ---

proc rfc3339*(moment: DateTime): string =
  moment.format("yyyy-MM-dd'T'HH:mm:sszzz")

proc nowStamp*(): string =
  rfc3339(now())

proc stampAt*(epochSeconds: float): string =
  rfc3339(fromUnix(int64(epochSeconds)).local)

proc newUpstreamSslContext*(): SslContext =
  ## One context for the process. `CVerifyPeer` with the built-in certificate
  ## list is the same configuration httpclient uses, so a leg that verifies
  ## today keeps verifying.
  newContext(verifyMode = CVerifyPeer)

# ------------------------------------------------------------------- router ---

proc newGateway*(cfg: Config, log: RequestLog,
                listenAddr: string): Gateway =
  result = Gateway(cfg: cfg, log: log, startedAt: nowStamp(),
                   listenAddr: listenAddr, cursor: -1,
                   ssl: newUpstreamSslContext(),                   legs: newSeq[LegRuntime](cfg.legs.len),
                   systemone: newSeq[SystemoneRuntime](cfg.systemone.len),
                   oauth: newSeq[OauthState](cfg.legs.len),
                   metrics: Metrics(latency: newSeq[int](LatencyBucketsMs.len + 1),
                                    requestsByRoute: initTable[string, int](),
                                    failoversByReason: initTable[string, int](),
                                    cooldownStarts: initTable[string, int](),
                                    statusClasses: initTable[string, int]()),
                   sessions: initTable[string, AdminSession](),
                   staticFiles: staticFileTable())
  # The seeded credential is the starting point, not the truth: a refresh replaces
  # it in memory and, when the file is writable, on disk.
  for index, leg in cfg.legs:
    if leg.hasOauth:
      result.oauth[index].accessToken = leg.oauth.accessToken
      result.oauth[index].refreshToken = leg.oauth.refreshToken
      result.oauth[index].expiresAt = leg.oauth.expiresAt

proc legAvailable*(gateway: Gateway, index: int, now: float): bool =
  ## A cooling leg is skipped without a dial. Once the cooldown expires the leg
  ## is eligible again, and the first request that picks it is the half-open
  ## probe (§3.2): a second failure starts a fresh full cooldown. A leg the config
  ## switched off is never available, and it keeps its place in the order.
  if not gateway.cfg.legs[index].enabled:
    return false
  let runtime = gateway.legs[index]
  if runtime.coolingUntil <= 0:
    return true
  if runtime.coolingUntil > now:
    return false
  not runtime.probeInFlight

proc enabledLegCount*(gateway: Gateway): int =
  ## DEC-26. The number that decides whether a header rung exists to protect
  ## another leg or only to tell the caller how long to wait. Overrides are already
  ## folded into `enabled` at load.
  for leg in gateway.cfg.legs:
    if leg.enabled:
      inc result

proc systemoneEnabledCount*(gateway: Gateway): int =
  for leg in gateway.cfg.systemone:
    if leg.enabled:
      inc result

proc coolingSummary*(gateway: Gateway,
                     now: float): tuple[enabled, cooling, retryAfterS: int] =
  ## Every enabled leg is cooling: how many, and how long until the first of them
  ## is eligible again. `retryAfterS` is the ceiling of that wait, so a caller is
  ## never told to retry before the gateway will dial.
  for index, leg in gateway.cfg.legs:
    if not leg.enabled:
      continue
    inc result.enabled
    let untilAt = gateway.legs[index].coolingUntil
    if untilAt > now:
      inc result.cooling
      let wait = int(untilAt - now) + 1
      if result.retryAfterS == 0 or wait < result.retryAfterS:
        result.retryAfterS = wait

proc systemoneCoolingSummary*(gateway: Gateway,
                              now: float): tuple[enabled, cooling,
                                                 retryAfterS: int] =
  for index, leg in gateway.cfg.systemone:
    if not leg.enabled:
      continue
    inc result.enabled
    let untilAt = gateway.systemone[index].coolingUntil
    if untilAt > now:
      inc result.cooling
      let wait = int(untilAt - now) + 1
      if result.retryAfterS == 0 or wait < result.retryAfterS:
        result.retryAfterS = wait

proc modelDisabled*(gateway: Gateway, alias: string): bool =
  ## DEC-27. Only an explicit `false` switches an alias off; a missing key keeps
  ## the alias serving.
  gateway.cfg.overridesModels.hasKey(alias) and
    not gateway.cfg.overridesModels[alias]

proc pickWeighted[T](legs: seq[T], pool: seq[int],
                     currents: var seq[int]): int =
  ## DEC-11's smooth weighted round-robin, the nginx algorithm: every turn each
  ## candidate gains its weight, the largest current wins, and the winner pays the
  ## total back. One call per request, no durable state, and a weight of 1 on
  ## every leg degenerates to plain round-robin. `currents` is indexed by leg.
  ## Generic since DEC-28: the chat legs and the System One legs both carry a
  ## `weight`, and the same pick decides both doors.
  var total = 0
  for index in pool:
    total += legs[index].weight
  if total <= 0:
    return pool[0]
  var chosen = pool[0]
  var best = low(int)
  for index in pool:
    currents[index] += legs[index].weight
    if currents[index] > best:
      best = currents[index]
      chosen = index
  currents[chosen] -= total
  chosen

proc pickOrder*(gateway: Gateway): seq[int] =
  ## R12a: one pick at request start, before any dial, then a walk. Balancing
  ## picks over the primaries that are available, weighted by DEC-11; the fallback
  ## only enters the pick when no primary can serve (D12.1). The walk is always the
  ## configured order: the pick, then the other primaries, then the fallbacks.
  let now = epochTime()
  var primaries: seq[int]
  var fallbacks: seq[int]
  for index in 0 ..< gateway.cfg.legs.len:
    if not gateway.legAvailable(index, now):
      continue
    if gateway.cfg.legs[index].role == lrPrimary:
      primaries.add index
    else:
      fallbacks.add index

  if not gateway.cfg.balance:
    # D12.5: strict config order, no pick to make.
    for index in 0 ..< gateway.cfg.legs.len:
      if gateway.legAvailable(index, now):
        result.add index
    if result.len > 0:
      gateway.cursor = result[0]
    return

  var pool = primaries
  if pool.len == 0:
    pool = fallbacks
  if pool.len == 0:
    return @[]

  var currents = newSeq[int](gateway.cfg.legs.len)
  for index in 0 ..< gateway.cfg.legs.len:
    currents[index] = gateway.legs[index].weightCurrent
  let chosen = pickWeighted(gateway.cfg.legs, pool, currents)
  for index in 0 ..< gateway.cfg.legs.len:
    gateway.legs[index].weightCurrent = currents[index]
  gateway.cursor = chosen

  result.add chosen
  for index in 0 ..< gateway.cfg.legs.len:
    if index != chosen and gateway.cfg.legs[index].role == lrPrimary and
       gateway.legAvailable(index, now):
      result.add index
  for index in 0 ..< gateway.cfg.legs.len:
    if index != chosen and gateway.cfg.legs[index].role == lrFallback and
       gateway.legAvailable(index, now):
      result.add index

proc cooldownSeconds*(reason: string, headerTimeouts: int,
                      headerWindowMs: int, singleLeg = false,
                      retryAfterS = -1): float =
  ## DEC-23: the class decides the width. A header timeout is the one class that
  ## widens with repetition, and its first rung is the header window that failure
  ## just cost, clamped to [HeaderTimeoutCooldownS, AvailabilityCooldownS].
  ##
  ## The window is the floor because a rung shorter than the wait it followed
  ## schedules a probe that is more expensive than the cooldown it ends: on the
  ## non-stream door the window is 90 s, so a 5 s rung would hand one caller 90 s
  ## of stall every five seconds of a real outage. A door whose window already
  ## costs a minute keeps the old flat 60 s, by construction.
  ##
  ## `headerTimeouts` is the count before this failure, so 0 is the first rung.
  ##
  ## DEC-26 adds two shapes: a rate-limited 429 cools for its Retry-After inside
  ## [5, 120] s, and a one-leg gateway caps a header rung at 15 s because there is
  ## no other leg a longer skip could protect.
  if reason in [TokenQuota429, TokenBilling402]:
    var capacity = CapacityCooldownS
    if retryAfterS > 0:
      capacity = min(max(float(retryAfterS), CapacityRetryAfterMinS),
                     CapacityCooldownS)
    return capacity
  if reason == TokenRateLimited:
    if retryAfterS > 0:
      return min(max(float(retryAfterS), RateLimitRetryAfterMinS),
                 RateLimitRetryAfterMaxS)
    return RateLimitDefaultS
  if reason != TokenHeaderTimeout:
    return AvailabilityCooldownS
  var cooldown = float(headerWindowMs) / 1000.0
  if cooldown < HeaderTimeoutCooldownS:
    cooldown = HeaderTimeoutCooldownS
  if cooldown >= AvailabilityCooldownS:
    cooldown = AvailabilityCooldownS
  else:
    for _ in 1 .. headerTimeouts:
      cooldown *= 2.0
      if cooldown >= AvailabilityCooldownS:
        cooldown = AvailabilityCooldownS
        break
  if singleLeg:
    cooldown = min(cooldown, SingleLegHeaderMaxMs.float / 1000.0)
  cooldown

proc startCooldown*(gateway: Gateway, index: int, reason: string,
                    headerWindowMs = HeaderDeadlineNonStreamMs,
                    singleLeg = false, retryAfterS = -1) =
  ## §3.1 and §3.2: the cooldown starts at the failure, and the leg's failure
  ## counter moves once for this request (D11.1). `headerWindowMs` is the header
  ## deadline this attempt actually waited, so the ladder's first rung can never
  ## be cheaper than the probe that would follow it (DEC-23).
  let now = epochTime()
  var runtime = addr gateway.legs[index]
  let cooldown = cooldownSeconds(reason, runtime.headerTimeouts, headerWindowMs,
                                 singleLeg, retryAfterS)
  if reason == TokenHeaderTimeout:
    runtime.headerTimeouts.inc
  runtime.attempted = true
  runtime.coolingUntil = now + cooldown
  runtime.probeInFlight = false
  runtime.lastFailureClass = reason
  runtime.lastFailureAt = stampAt(now)
  runtime.failedInWindow.inc
  let name = gateway.cfg.legs[index].name
  gateway.metrics.cooldownStarts.mgetOrPut(name, 0).inc

proc markServed*(gateway: Gateway, index: int, latencyMs: int) =
  let now = epochTime()
  var runtime = addr gateway.legs[index]
  runtime.attempted = true
  runtime.coolingUntil = 0
  # DEC-23: a leg that answered is a leg that blinked, not one that is going
  # down, so the header-timeout ladder starts over at 5 s.
  runtime.headerTimeouts = 0
  runtime.lastSuccessAt = stampAt(now)
  runtime.servedInWindow.inc
  runtime.latencies.add latencyMs
  if runtime.latencies.len > LatencyRingSize:
    runtime.latencies.delete(0)

proc markAttempted*(gateway: Gateway, index: int) =
  gateway.legs[index].attempted = true

proc legStateName*(runtime: LegRuntime, now: float, enabled = true): string =
  ## D7: `dead` is not a router state, and `unknown` is a fresh start. A leg the
  ## config switched off reads as `skipped`: still in the chain, never dialled.
  if not enabled:
    "skipped"
  elif runtime.coolingUntil > now:
    "cooling"
  elif runtime.attempted:
    "ok"
  else:
    "unknown"

proc recordEvent(gateway: Gateway, fromRoute, toRoute, reason: string) =
  gateway.events.add FailoverEvent(at: nowStamp(), fromRoute: fromRoute,
                                   toRoute: toRoute, reason: reason)
  while gateway.events.len > FailoverEventLimit:
    gateway.events.delete(0)

# ------------------------------------------------------- systemone router ---

proc systemoneOrder*(gateway: Gateway, now: float): seq[int] =
  ## DEC-19 as amended by DEC-28. With `systemone_balance: false` (the default)
  ## this is config order and nothing else: a fallback chain, not a load balancer.
  ## With it on, the first pick is the same smooth weighted round-robin the chat
  ## door uses, over the legs that are enabled and not cooling, and the rest of the
  ## walk stays config order. A cooling leg is skipped without a dial exactly as a
  ## chat leg is.
  var pool: seq[int]
  for index, leg in gateway.cfg.systemone:
    if not leg.enabled:
      continue
    if gateway.systemone[index].coolingUntil > now:
      continue
    pool.add index
  if pool.len == 0:
    return @[]
  if not gateway.cfg.systemoneBalance:
    return pool
  var currents = newSeq[int](gateway.cfg.systemone.len)
  for index in 0 ..< gateway.cfg.systemone.len:
    currents[index] = gateway.systemone[index].weightCurrent
  let chosen = pickWeighted(gateway.cfg.systemone, pool, currents)
  for index in 0 ..< gateway.cfg.systemone.len:
    gateway.systemone[index].weightCurrent = currents[index]
  result.add chosen
  for index in pool:
    if index != chosen:
      result.add index

proc startSystemoneCooldown*(gateway: Gateway, index: int, reason: string,
                             headerWindowMs = HeaderDeadlineNonStreamMs,
                             singleLeg = false, retryAfterS = -1) =
  ## The same two cooldowns and the same reason tokens as the chat door, so one
  ## log is readable without knowing which door a line came from.
  let now = epochTime()
  var runtime = addr gateway.systemone[index]
  let cooldown = cooldownSeconds(reason, runtime.headerTimeouts, headerWindowMs,
                                 singleLeg, retryAfterS)
  if reason == TokenHeaderTimeout:
    runtime.headerTimeouts.inc
  runtime.attempted = true
  runtime.coolingUntil = now + cooldown
  runtime.lastFailureClass = reason
  runtime.lastFailureAt = stampAt(now)
  let name = gateway.cfg.systemone[index].name
  gateway.metrics.cooldownStarts.mgetOrPut(name, 0).inc

proc markSystemoneServed(gateway: Gateway, index: int) =
  let now = epochTime()
  var runtime = addr gateway.systemone[index]
  runtime.attempted = true
  runtime.coolingUntil = 0
  runtime.headerTimeouts = 0
  runtime.lastSuccessAt = stampAt(now)

proc systemoneUnsupportedBody*(body: string): bool =
  ## A provider that answers "this endpoint does not take that model" is telling
  ## kori the leg is wrong for the id, not the caller. Narrow on purpose: a plain
  ## 400 from the same provider is the caller's body and must reach the caller.
  body.contains("unsupported_model") or
    body.contains("is not supported on this endpoint") or
    body.contains("does not support")

proc systemoneUsage*(body: string): (Option[int], Option[int]) =
  ## DEC-19. System One reports `usage.input_tokens` and `usage.output_tokens`,
  ## not the [OI] `prompt_tokens`/`completion_tokens`, so the chat reader finds
  ## nothing here. Provider-reported only: a leg that reports nothing gets null.
  try:
    let node = parseJson(body)
    if node.kind == JObject:
      let usage = node{"usage"}
      if usage != nil and usage.kind == JObject:
        let tokensIn = usage{"input_tokens"}
        let tokensOut = usage{"output_tokens"}
        if tokensIn != nil and tokensIn.kind == JInt:
          result[0] = some(tokensIn.getInt())
        if tokensOut != nil and tokensOut.kind == JInt:
          result[1] = some(tokensOut.getInt())
  except CatchableError:
    discard

# --------------------------------------------------------------- upstream io ---

proc remainingMs(deadline: float): int =
  let left = int((deadline - epochTime()) * 1000.0)
  if left < 0: 0 else: left

proc deadlineIn(ms: int): float =
  epochTime() + ms.float / 1000.0

proc streamHeaderDeadlineMs*(baseMs, perKiBMs, maxMs, bodyBytes: int): int =
  ## SPEC §3b.1 with the size slope of D-2, with the numbers passed in so the
  ## config owns them (DEC-26). A body of zero bytes still gets the floor.
  if bodyBytes <= 0 or perKiBMs <= 0:
    return baseMs
  min(baseMs + (bodyBytes div 1024) * perKiBMs, maxMs)

proc streamHeaderDeadlineMs*(bodyBytes: int): int =
  ## The compiled defaults, kept for callers that have no config in hand and for
  ## the unit tests that pin the shipped numbers.
  streamHeaderDeadlineMs(HeaderDeadlineStreamMs, HeaderDeadlineStreamPerKiBMs,
                         HeaderDeadlineStreamMaxMs, bodyBytes)

proc awaitRecv(socket: AsyncSocket, maxBytes: int,
               deadline: float): Future[RecvOut] {.async.} =
  let budget = remainingMs(deadline)
  if budget <= 0:
    return RecvOut(kind: rkTimeout)
  let pending = socket.recv(maxBytes)
  if not await withTimeout(pending, budget):
    return RecvOut(kind: rkTimeout)
  if pending.failed:
    return RecvOut(kind: rkError)
  let data = pending.read()
  if data.len == 0:
    RecvOut(kind: rkEof)
  else:
    RecvOut(kind: rkData, data: data)

proc awaitSend(socket: AsyncSocket, data: string,
               deadline: float): Future[bool] {.async.} =
  let budget = remainingMs(deadline)
  if budget <= 0:
    return false
  let pending = socket.send(data)
  if not await withTimeout(pending, budget):
    return false
  not pending.failed

proc truncateIfEof(got: RecvOut): RecvOut =
  ## A body that stops before its framing says it is done did not end, it died.
  if got.kind == rkEof: RecvOut(kind: rkTruncated) else: got

proc readLine(reader: UpstreamReader, deadline: float): Future[RecvOut] {.async.} =
  while true:
    let stop = reader.buf.find("\r\n")
    if stop >= 0:
      result = RecvOut(kind: rkData, data: reader.buf[0 ..< stop])
      reader.buf = reader.buf[stop + 2 .. ^1]
      return
    let got = await awaitRecv(reader.socket, 8192, deadline)
    if got.kind != rkData:
      return got
    reader.buf.add got.data

proc readSlice(reader: UpstreamReader,
               deadline: float): Future[RecvOut] {.async.} =
  ## The next slice of decoded body, chunked decoding included. `rkData` with a
  ## non-empty string, `rkEof` at the end, `rkTimeout`/`rkError` otherwise.
  if reader.finished:
    return RecvOut(kind: rkEof)
  case reader.mode
  of bmEof:
    if reader.buf.len > 0:
      result = RecvOut(kind: rkData, data: reader.buf)
      reader.buf = ""
      return
    result = await awaitRecv(reader.socket, 16_384, deadline)
    if result.kind == rkEof:
      reader.finished = true
  of bmLength:
    if reader.remaining <= 0:
      reader.finished = true
      return RecvOut(kind: rkEof)
    if reader.buf.len > 0:
      let take = min(reader.buf.len, reader.remaining)
      result = RecvOut(kind: rkData, data: reader.buf[0 ..< take])
      reader.buf = reader.buf[take .. ^1]
      reader.remaining -= take
      return
    let want = min(16_384, reader.remaining)
    result = await awaitRecv(reader.socket, want, deadline)
    if result.kind == rkData:
      reader.remaining -= result.data.len
    elif result.kind == rkEof:
      # Content-Length promised more than the connection delivered (§5.3).
      reader.finished = true
      result = RecvOut(kind: rkTruncated)
  of bmChunked:
    while true:
      if reader.chunkRemaining == 0:
        if reader.needCrlf:
          let crlf = await reader.readLine(deadline)
          if crlf.kind != rkData:
            return truncateIfEof(crlf)
          reader.needCrlf = false
        let sizeLine = await reader.readLine(deadline)
        if sizeLine.kind != rkData:
          return truncateIfEof(sizeLine)
        let rawSize = sizeLine.data.split(';')[0].strip()
        var size = 0
        try:
          size = parseHexInt(rawSize)
        except ValueError:
          reader.finished = true
          return RecvOut(kind: rkError)
        if size == 0:
          # Trailer section: read until the blank line.
          while true:
            let trailer = await reader.readLine(deadline)
            if trailer.kind != rkData or trailer.data.len == 0:
              break
          reader.finished = true
          return RecvOut(kind: rkEof)
        reader.chunkRemaining = size
      if reader.buf.len > 0:
        let take = min(reader.buf.len, reader.chunkRemaining)
        result = RecvOut(kind: rkData, data: reader.buf[0 ..< take])
        reader.buf = reader.buf[take .. ^1]
        reader.chunkRemaining -= take
        if reader.chunkRemaining == 0:
          reader.needCrlf = true
        return
      let want = min(16_384, reader.chunkRemaining)
      result = await awaitRecv(reader.socket, want, deadline)
      if result.kind != rkData:
        return truncateIfEof(result)
      reader.chunkRemaining -= result.data.len
      if reader.chunkRemaining == 0:
        reader.needCrlf = true
      return

proc parseHead(raw: string): tuple[status: int, headers: seq[(string, string)]] =
  let lines = raw.split("\r\n")
  if lines.len == 0:
    return (0, @[])
  let statusParts = lines[0].split(' ')
  if statusParts.len < 2:
    return (0, @[])
  try:
    result.status = parseInt(statusParts[1])
  except ValueError:
    return (0, @[])
  for index in 1 ..< lines.len:
    let line = lines[index]
    if line.len == 0:
      continue
    let colon = line.find(':')
    if colon <= 0:
      continue
    result.headers.add((line[0 ..< colon].strip().toLowerAscii(),
                        line[colon + 1 .. ^1].strip()))

proc headerValue(headers: seq[(string, string)], name: string): string =
  for (key, value) in headers:
    if key == name:
      return value
  ""

proc upstreamPath(baseUrl: string): string =
  var path = parseUri(baseUrl).path
  while path.endsWith("/"):
    path.setLen(path.len - 1)
  if path.len == 0:
    path = "/v1"
  path & "/chat/completions"

proc systemonePath*(baseUrl: string): string =
  ## DEC-19. The same rule as `upstreamPath` with the other endpoint: the base
  ## URL names where a provider lives, and kori appends the one path this door
  ## speaks. A base that already ends in `/systemone` keeps its own path, so both
  ## spellings in a config mean the thing the operator wrote.
  var path = parseUri(baseUrl).path
  while path.endsWith("/"):
    path.setLen(path.len - 1)
  if path.endsWith("/systemone"):
    return path
  if path.len == 0:
    path = "/v1"
  path & "/systemone"

# ------------------------------------------------------------- classification ---

proc isQuotaBody*(body: string): bool =
  ## §3.2: a quota 429 carries a quota body. The measured one is
  ## `GoUsageLimitError`; the other spellings are the "equivalents" the spec
  ## names. A plain rate limit is not this class (D9.3).
  body.contains("GoUsageLimitError") or body.contains("usage_limit") or
    body.contains("usage limit") or body.contains("insufficient_quota") or
    body.contains("QuotaExceeded")

proc modelGoneBody*(body: string): bool =
  ## A 404 whose body says the model does not exist on that leg. Matched on the
  ## provider spellings we have seen (`model_not_found`, "does not exist", "no
  ## such model") and kept narrow: a bare 404 stays a caller error, because a
  ## wrong path or a wrong host is not a dead model.
  body.contains("model_not_found") or body.contains("model not found") or
    body.contains("does not exist") or body.contains("no such model") or
    body.contains("unknown model") or body.contains("invalid model")

proc failureToken*(status: int, body: string, aliasMapped = false,
                   modelGone = false): string =
  ## §3.1 to §3.3. Empty string means "not a failure class": the response either
  ## served the caller or is a client error returned unchanged. `modelGone` is
  ## passed in by the caller of this proc, because only the walk knows whether the
  ## alias table named the model id this leg was sent: a caller's own id keeps the
  ## 404 it earned.
  if status == 401:
    TokenAuth401
  elif status == 400 and body.contains("MissingSessionID"):
    TokenMissingSession
  elif status == 404 and aliasMapped and modelGoneBody(body):
    TokenModelGone
  elif status == 429 and isQuotaBody(body):
    TokenQuota429
  elif status == 429:
    ## DEC-26. A 429 that is not a quota is a rate limit: it may clear in seconds,
    ## so it is its own class rather than inheriting the 900 s capacity rung.
    TokenRateLimited
  elif status == 402:
    # A provider that has run out of credit answers 402 with its own billing
    # body. It is a dead route, not a caller error: leaving it unclassified
    # handed the provider's billing text to the caller and kept a leg that
    # cannot serve in rotation (sinarcloud, 2026-11-22).
    TokenBilling402
  elif status >= 500:
    TokenUpstream5xx
  else:
    ""

proc isSuccessStatus(status: int): bool =
  status >= 200 and status < 300

# ------------------------------------------------------------- request body ---

proc injectIncludeUsage*(body: string): string =
  ## R10: kori sets `stream_options.include_usage` when the caller did not. The
  ## edit is textual and touches nothing else, so the rest of the caller's bytes
  ## reach the leg unchanged (A6b compares the parsed request minus that key).
  if body.contains("\"stream_options\""):
    return body
  let brace = body.find('{')
  if brace < 0:
    return body
  var after = brace + 1
  while after < body.len and body[after] in {' ', '\t', '\r', '\n'}:
    inc after
  let addition = "\"stream_options\":{\"include_usage\":true}"
  if after < body.len and body[after] == '}':
    body[0 .. brace] & addition & body[after .. ^1]
  else:
    body[0 .. brace] & addition & "," & body[after .. ^1]

proc isKeyNamed(rawKey, name: string): bool =
  ## A top-level key as it appears in the caller's bytes, matched after unescaping:
  ## `"model"` and `"mo\u0064el"` are the same key, and a rewrite has to catch both.
  if rawKey == name:
    return true
  if rawKey.contains('\\'):
    try:
      let parsed = parseJson("\"" & rawKey & "\"")
      if parsed.kind == JString and parsed.getStr() == name:
        return true
    except CatchableError:
      discard
  false

proc rewriteTopLevelString*(body, key, value: string): string =
  ## The top-level string `key` becomes `value`, at the top level and nowhere
  ## else. Textual on purpose: every other byte the caller sent still reaches the
  ## leg, the same promise `injectIncludeUsage` keeps. A body with no such key, or
  ## with a non-string value there, is returned untouched, never refused.
  if key.len == 0 or body.len == 0:
    return body

  var stack: seq[char] = @[]
  var expectingKey = false
  var replacements: seq[tuple[valStart, valStop: int]] = @[]

  var i = 0
  while i < body.len:
    let c = body[i]
    case c
    of '{':
      stack.add '{'
      if stack.len == 1:
        expectingKey = true
      inc i
    of '}':
      if stack.len > 0 and stack[^1] == '{':
        discard stack.pop()
      if stack.len == 1 and stack[0] == '{':
        expectingKey = false
      inc i
    of '[':
      stack.add '['
      inc i
    of ']':
      if stack.len > 0 and stack[^1] == '[':
        discard stack.pop()
      inc i
    of ',':
      if stack.len == 1 and stack[0] == '{':
        expectingKey = true
      inc i
    of '"':
      let isTopKey = (stack.len == 1 and stack[0] == '{' and expectingKey)
      let strStart = i
      inc i
      while i < body.len and body[i] != '"':
        if body[i] == '\\' and i + 1 < body.len:
          inc i, 2
        else:
          inc i
      if i >= body.len:
        return body
      let strStop = i
      inc i

      if isTopKey:
        let rawKey = body[strStart + 1 ..< strStop]
        expectingKey = false
        var cursor = i
        while cursor < body.len and body[cursor] in {' ', '\t', '\r', '\n'}:
          inc cursor
        if cursor < body.len and body[cursor] == ':':
          inc cursor
          while cursor < body.len and body[cursor] in {' ', '\t', '\r', '\n'}:
            inc cursor
          if isKeyNamed(rawKey, key):
            if cursor < body.len and body[cursor] == '"':
              let vStart = cursor
              var vCursor = cursor + 1
              while vCursor < body.len and body[vCursor] != '"':
                if body[vCursor] == '\\' and vCursor + 1 < body.len:
                  inc vCursor, 2
                else:
                  inc vCursor
              if vCursor >= body.len:
                return body
              let vStop = vCursor + 1
              replacements.add((vStart, vStop))
              i = vStop
            else:
              i = cursor
          else:
            i = cursor
    else:
      inc i

  if replacements.len == 0:
    return body

  let replacement = $(%value)
  var res = ""
  var lastIdx = 0
  for r in replacements:
    res.add body[lastIdx ..< r.valStart]
    res.add replacement
    lastIdx = r.valStop
  if lastIdx < body.len:
    res.add body[lastIdx .. ^1]
  res

proc rewriteModel*(body, model: string): string =
  ## DEC-10: the leg's own model id replaces the caller's. One key, one rewrite,
  ## nothing else touched.
  if model.len == 0:
    return body
  rewriteTopLevelString(body, "model", model)

proc requestEffort*(body: string): string =
  ## The caller's top-level `reasoning_effort` string, or "" when the body has
  ## none. A parse, not a rewrite: nothing here has to keep the caller's bytes.
  try:
    let node = parseJson(body)
    if node.kind == JObject:
      let effort = node{"reasoning_effort"}
      if effort != nil and effort.kind == JString:
        return effort.getStr()
  except CatchableError:
    discard
  ""

type EffortDecision* = object
  ## What one leg should do with the caller's effort. `skip` means the leg cannot
  ## serve this value at any level below it, so the walk moves on without a dial
  ## and without a cooldown, exactly as an unmapped alias does.
  sent*: string
  clamped*: bool
  skip*: bool

proc decideEffort*(leg: Leg, asked: string): EffortDecision =
  ## `asked` empty means the caller named no effort, and a leg with no `efforts`
  ## key has no ceiling: both pass through untouched. A value kori does not rank
  ## is also passed through, because there is no honest position to compare it to.
  result = EffortDecision(sent: asked)
  if not leg.hasEfforts or asked.len == 0:
    return
  let askedRank = effortRank(asked)
  if askedRank < 0:
    return
  for accepted in leg.efforts:
    if accepted == asked:
      return
  var bestRank = -1
  for accepted in leg.efforts:
    let rank = effortRank(accepted)
    if rank >= 0 and rank < askedRank and rank > bestRank:
      bestRank = rank
  if bestRank < 0:
    result.skip = true
    result.sent = ""
    return
  result.sent = EffortRanks[bestRank]
  result.clamped = true

proc effortUnsupportedBody*(asked: string): string =
  ## A client error with a body that names the value no leg could serve.
  "{\"error\":{\"type\":\"effort_unsupported\",\"message\":" &
    jsonEscape("no leg accepts reasoning_effort '" & asked & "'") & "}}"

proc effortStopWithoutDial*(dials, effortSkips: int): bool =
  ## A request the caller's own effort ended: nothing was dialled and at least
  ## one leg was skipped for its ceiling. The two skip reasons are counted
  ## separately, so a walk that also skipped an unmapped alias still reads as
  ## this case instead of being measured against the walk length.
  dials == 0 and effortSkips > 0

proc countsTowardAvailability*(availability: bool, effortStop: bool): bool =
  ## D9's window counter counts legs that could not serve. A 400 naming the
  ## caller's effort dialled nothing, so it moves no availability; a skip the
  ## walk then served past is counted exactly as before.
  availability and not effortStop

proc requestModel*(body: string): string =
  ## The caller's top-level `model` string, or "" when the body has none. A parse,
  ## not a rewrite: nothing here has to keep the caller's bytes.
  try:
    let node = parseJson(body)
    if node.kind == JObject:
      let model = node{"model"}
      if model != nil and model.kind == JString:
        return model.getStr()
  except CatchableError:
    discard
  ""

proc aliasOf*(model: string): Option[string] =
  ## `kori/<alias>` names a gateway alias; any other name is a provider id that is
  ## forwarded as it always was.
  if model.startsWith(AliasPrefix):
    some(model[AliasPrefix.len .. ^1])
  else:
    none(string)

proc unknownAliasBody*(alias: string): string =
  ## A client error with a body that says what the caller can fix.
  "{\"error\":{\"type\":\"unknown_alias\",\"message\":" &
    jsonEscape("no leg maps the model alias '" & alias & "'") & "}}"

proc aliasDisabledBody*(alias: string): string =
  ## DEC-27. Fixed shape, the caller's own alias echoed only after the same length
  ## bound an unknown alias gets.
  "{\"error\":{\"type\":\"" & TokenAliasDisabled &
    "\",\"message\":" & jsonEscape("model alias '" & alias &
    "' is switched off in the gateway") & "}}"

proc aliasTooLong*(alias: string): bool =
  ## Item 3: checked before any leg is touched, so an over-long name never reaches
  ## the walk, the log line at full length, or the response body.
  alias.len > MaxAliasBytes

proc cutUtf8*(value: string, limit: int): string =
  ## A byte cut can land inside a multi-byte rune, and jsonEscape passes every
  ## byte >= 0x20 through raw, so half a rune would make the log line invalid
  ## UTF-8. Back off to the start of that rune instead. A rune longer than the
  ## limit cannot happen in UTF-8 (four bytes at most), but the loop still ends
  ## at 0 and yields the empty string rather than reading out of bounds.
  if limit <= 0: return ""
  if limit >= value.len: return value
  var stop = limit
  while stop > 0 and (ord(value[stop]) and 0b1100_0000) == 0b1000_0000:
    dec stop
  result = value[0 ..< stop]

proc aliasLogValue*(alias: string): string =
  ## The caller's own string, prefix included, so the line says what was asked
  ## for. A legal alias (at most MaxAliasBytes) survives whole, which is what
  ## keeps its row matching an exact `?alias=` filter; a refused one is cut to
  ## MaxAliasLogBytes on a rune boundary, so it still says which request it was
  ## without carrying the rest of a 33 MB body into the log.
  cutUtf8(AliasPrefix & alias, MaxAliasLogBytes)

proc aliasTooLongBody*(): string =
  ## Fixed text: the offending name is never echoed back.
  "{\"error\":{\"type\":\"" & TokenAliasTooLong &
    "\",\"message\":\"model alias is longer than " & $MaxAliasBytes & " bytes\"}}"

proc wantsStream*(body: string): bool =
  try:
    let node = parseJson(body)
    if node.kind == JObject:
      let stream = node{"stream"}
      if stream != nil and stream.kind == JBool:
        return stream.getBool()
  except CatchableError:
    discard
  false

proc usageTokens*(body: string): (Option[int], Option[int]) =
  ## Provider-reported only. A provider that reports nothing gets null, never 0
  ## and never an estimate (R11).
  try:
    let node = parseJson(body)
    if node.kind == JObject:
      let usage = node{"usage"}
      if usage != nil and usage.kind == JObject:
        let tokensIn = usage{"prompt_tokens"}
        let tokensOut = usage{"completion_tokens"}
        if tokensIn != nil and tokensIn.kind == JInt:
          result[0] = some(tokensIn.getInt())
        if tokensOut != nil and tokensOut.kind == JInt:
          result[1] = some(tokensOut.getInt())
  except CatchableError:
    discard

proc scanStreamUsage(slice: string, tokensIn, tokensOut: var Option[int]) =
  ## The final usage chunk is the only place a stream reports tokens (R10).
  for line in slice.splitLines():
    if not line.startsWith("data: "):
      continue
    let payload = line[6 .. ^1].strip()
    if payload.len == 0 or payload == "[DONE]":
      continue
    let (ins, outs) = usageTokens(payload)
    if ins.isSome:
      tokensIn = ins
    if outs.isSome:
      tokensOut = outs

# ----------------------------------------------------------- caller response ---

proc reasonText(code: int): string =
  case code
  of 200: "OK"
  of 201: "Created"
  of 400: "Bad Request"
  of 401: "Unauthorized"
  of 403: "Forbidden"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 409: "Conflict"
  of 422: "Unprocessable Entity"
  of 429: "Too Many Requests"
  of 500: "Internal Server Error"
  of 502: "Bad Gateway"
  of 503: "Service Unavailable"
  of 504: "Gateway Timeout"
  else: "Status"

proc buildHead(code: int, headers: seq[(string, string)]): string =
  result = "HTTP/1.1 " & $code & " " & reasonText(code) & "\r\n"
  for (name, value) in headers:
    result.add name & ": " & value & "\r\n"
  result.add "\r\n"

proc sendFull(request: Request, code: int, contentType: string,
              body: string): Future[void] {.async.} =
  var headers = @[("Content-Type", contentType),
                  ("Content-Length", $body.len)]
  await request.client.send(buildHead(code, headers) & body)

proc sendErrorBody(request: Request, code: int, payload: string): Future[void] {.async.} =
  await request.sendFull(code, "application/json", payload)

proc chunkFrame(data: string): string =
  toHex(data.len).toLowerAscii() & "\r\n" & data & "\r\n"

proc sseErrorEvent(reason: string, message: string): string =
  "event: error\ndata: {\"error\":{\"type\":" & jsonEscape(reason) &
    ",\"message\":" & jsonEscape(message) & "}}\n\n"

proc allLegsFailedBody(message: string): string =
  "{\"error\":{\"type\":\"all_legs_failed\",\"message\":" &
    jsonEscape(message) & "}}"

proc allLegsCoolingBody(retryAfterS: int): string =
  ## DEC-26. The gateway never dialled: the code is 503, the body names the state
  ## and the wait, and no leg name reaches the caller.
  "{\"error\":{\"type\":\"all_legs_cooling\",\"message\":" &
    jsonEscape("no leg can serve this request now; retry in " & $retryAfterS &
               "s") &
    ",\"retry_after_s\":" & $retryAfterS & "}}"

proc noLegEnabledBody(): string =
  "{\"error\":{\"type\":\"no_leg_enabled\",\"message\":" &
    jsonEscape("every provider is switched off in the gateway") & "}}"

proc sendErrorBodyWithHeaders(request: Request, code: int, payload: string,
                              extra: seq[(string, string)]): Future[void] {.async.} =
  var headers = @[("Content-Type", "application/json"),
                  ("Content-Length", $payload.len),
                  ("Cache-Control", "no-store")]
  for pair in extra:
    headers.add pair
  await request.client.send(buildHead(code, headers) & payload)

proc credentialRefreshBody(reason, detail: string): string =
  ## §4: the type is the reason token, so a caller can tell a credential problem
  ## from a provider problem without reading prose.
  "{\"error\":{\"type\":" & jsonEscape(reason) & ",\"message\":" &
    jsonEscape(detail) & "}}"

# ------------------------------------------------------------------ attempts ---

proc closeQuietly(socket: AsyncSocket) =
  ## A socket whose connect never completed is not registered with the dispatcher,
  ## and closing it raises `File descriptor not registered`. That raise inside an
  ## async callback kills the process, so every close goes through here.
  if socket.isNil:
    return
  try:
    socket.close()
  except CatchableError:
    discard

proc dial(uri: Uri): Future[tuple[ok: bool, timedOut: bool,
                                 socket: AsyncSocket]] {.async.} =
  let socket = newAsyncSocket()
  let port =
    if uri.port.len > 0: Port(parseInt(uri.port))
    elif uri.scheme == "https": Port(443)
    else: Port(80)
  try:
    let connecting = socket.connect(uri.hostname, port)
    if not await withTimeout(connecting, ConnectDeadlineMs):
      closeQuietly(socket)
      return (false, true, nil)
    if connecting.failed:
      closeQuietly(socket)
      return (false, false, nil)
    # DEC-24. A gateway request head is a few hundred bytes on a fresh
    # connection, so Nagle would hold the tail until the ACK: the provider sees
    # our headers late and the caller pays it before the first token. A failure
    # here is ignored on purpose: the socket is connected and usable, and turning
    # a failed socket option into `conn_refused` would cool a healthy leg for 60 s.
    try:
      socket.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
    except CatchableError:
      discard
    (true, false, socket)
  except CatchableError:
    closeQuietly(socket)
    (false, false, nil)

# ------------------------------------------------------- credential refresh ---

proc writeFileAtomic(path, content: string): bool =
  ## A temp file beside the target, opened 0600 before a byte is written, then
  ## renamed over it: a reader sees the old file or the new one, never half of one.
  let tmp = path & ".tmp"
  let fd = posix.open(tmp.cstring, O_WRONLY or O_CREAT or O_TRUNC, Mode(0o600))
  if fd < 0:
    return false
  var offset = 0
  var failed = false
  while offset < content.len:
    let written = posix.write(fd, unsafeAddr content[offset], content.len - offset)
    if written <= 0:
      failed = true
      break
    offset += written
  if not failed:
    discard posix.fsync(fd)
  discard posix.close(fd)
  if failed:
    discard posix.unlink(tmp.cstring)
    return false
  try:
    moveFile(tmp, path)
    true
  except CatchableError:
    discard posix.unlink(tmp.cstring)
    false

proc stringLiteralEnd(raw: string, quoteAt: int): int =
  ## Index of the closing quote of the string opening at `quoteAt`, or -1.
  var index = quoteAt + 1
  while index < raw.len:
    case raw[index]
    of '\\': index += 2
    of '"': return index
    else: inc index
  -1

proc enclosingObject(raw: string, pos: int): tuple[found: bool, open, close: int] =
  ## The innermost JSON object containing byte `pos`, found by a string-aware
  ## brace walk so a brace inside a token or a URL cannot fool it.
  var stack: seq[int]
  var inString = false
  var escaped = false
  var index = 0
  while index < raw.len:
    let ch = raw[index]
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
    else:
      case ch
      of '"': inString = true
      of '{': stack.add index
      of '}':
        if stack.len > 0: discard stack.pop()
      else: discard
    if index == pos:
      if stack.len == 0:
        return (false, 0, 0)
      let open = stack[^1]
      var depth = 0
      var innerString = false
      var innerEscaped = false
      var cursor = open
      while cursor < raw.len:
        let current = raw[cursor]
        if innerString:
          if innerEscaped: innerEscaped = false
          elif current == '\\': innerEscaped = true
          elif current == '"': innerString = false
        else:
          case current
          of '"': innerString = true
          of '{': inc depth
          of '}':
            dec depth
            if depth == 0:
              return (true, open, cursor)
          else: discard
        inc cursor
      return (false, 0, 0)
    inc index
  (false, 0, 0)

proc oauthBlockSpan(raw: string,
                    tokenUrl: string): tuple[found: bool, open, close: int] =
  ## The byte span of the `oauth` object whose `token_url` is this leg's. Located
  ## by that value rather than by a line number, so reformatting the file is safe.
  ## Two legs sharing one token endpoint are ambiguous and are not guessed at.
  const needle = "\"token_url\""
  let expected = jsonEscape(tokenUrl)
  var hits: seq[int]
  var searchAt = 0
  while true:
    let at = raw.find(needle, searchAt)
    if at < 0:
      break
    searchAt = at + needle.len
    var cursor = searchAt
    while cursor < raw.len and raw[cursor] in {' ', '\t', '\r', '\n'}: inc cursor
    if cursor >= raw.len or raw[cursor] != ':':
      continue
    inc cursor
    while cursor < raw.len and raw[cursor] in {' ', '\t', '\r', '\n'}: inc cursor
    if cursor >= raw.len or raw[cursor] != '"':
      continue
    let stop = stringLiteralEnd(raw, cursor)
    if stop < 0:
      continue
    if raw[cursor .. stop] == expected:
      hits.add at
  if hits.len != 1:
    return (false, 0, 0)
  enclosingObject(raw, hits[0])

proc lineIndent(raw: string, pos: int): string =
  ## The leading whitespace of the line `pos` sits on, so a spliced block keeps
  ## the file's own indentation instead of collapsing it onto one line.
  var start = pos
  while start > 0 and raw[start - 1] != '\n': dec start
  var stop = start
  while stop < raw.len and raw[stop] in {' ', '\t'}: inc stop
  raw[start ..< stop]

proc oauthBlockText(leg: Leg, state: OauthState, indent: string): string =
  ## The oauth object as it is written back: same keys, same order, live values,
  ## one key per line at the file's own indentation. Everything outside this one
  ## object keeps its bytes.
  var keys: seq[(string, string)]
  keys.add(("\"token_url\"", jsonEscape(leg.oauth.tokenUrl)))
  keys.add(("\"client_id\"", jsonEscape(leg.oauth.clientId)))
  if leg.oauth.clientSecret.len > 0:
    keys.add(("\"client_secret\"", jsonEscape(leg.oauth.clientSecret)))
  keys.add(("\"refresh_token\"", jsonEscape(state.refreshToken)))
  if state.accessToken.len > 0:
    keys.add(("\"access_token\"", jsonEscape(state.accessToken)))
  if state.expiresAt > 0:
    keys.add(("\"expires_at\"", $int64(state.expiresAt)))
  if leg.oauth.refreshSkewSeconds != DefaultRefreshSkewS:
    keys.add(("\"refresh_skew_seconds\"", $leg.oauth.refreshSkewSeconds))
  result = "{\n"
  for index, (name, value) in keys:
    result.add indent & "  " & name & ": " & value
    if index + 1 < keys.len:
      result.add ","
    result.add "\n"
  result.add indent & "}"

proc persistOauth(gateway: Gateway, index: int): bool =
  ## SPEC §4 point 7. The rotated credential goes back into the same config file,
  ## atomically, with every other byte untouched. A read-only config (the container
  ## mounts it `:ro`) is not an error: the process serves the refreshed credential
  ## from memory and says so once on stderr.
  if gateway.configPath.len == 0:
    return false
  let leg = gateway.cfg.legs[index]
  var raw: string
  try:
    raw = readFile(gateway.configPath)
  except CatchableError as error:
    stderr.writeLine("kori: cannot read config back for leg '" & leg.name & "': " &
                     error.msg & " (serving the refreshed credential from memory)")
    return false
  let span = oauthBlockSpan(raw, leg.oauth.tokenUrl)
  if not span.found:
    stderr.writeLine("kori: cannot locate the oauth block for leg '" & leg.name &
                     "' in " & gateway.configPath &
                     " (serving the refreshed credential from memory)")
    return false
  let patched = raw[0 ..< span.open] &
                oauthBlockText(leg, gateway.oauth[index],
                               lineIndent(raw, span.open)) &
                raw[span.close + 1 .. ^1]
  if not writeFileAtomic(gateway.configPath, patched):
    stderr.writeLine("kori: cannot write " & gateway.configPath & " for leg '" &
                     leg.name &
                     "' (read-only?); serving the refreshed credential from memory")
    return false
  true

proc refreshLeg(gateway: Gateway, index: int): Future[RefreshOutcome] {.async.} =
  ## One form-encoded POST to the configured token endpoint, inside
  ## RefreshDeadlineMs once the connection is up. No token, refresh token or
  ## client secret is ever written to stderr, the log or an admin response.
  let leg = gateway.cfg.legs[index]
  let uri = parseUri(leg.oauth.tokenUrl)
  let isTls = uri.scheme == "https"
  var form = "grant_type=refresh_token"
  form.add "&refresh_token=" & encodeUrl(gateway.oauth[index].refreshToken, true)
  form.add "&client_id=" & encodeUrl(leg.oauth.clientId, true)
  if leg.oauth.clientSecret.len > 0:
    form.add "&client_secret=" & encodeUrl(leg.oauth.clientSecret, true)

  var connected: bool
  var dialTimedOut: bool
  var socket: AsyncSocket
  (connected, dialTimedOut, socket) = await dial(uri)
  if not connected:
    return RefreshOutcome(ok: false, timedOut: dialTimedOut,
      detail: (if dialTimedOut: "token endpoint dial timed out"
               else: "token endpoint connection refused"))
  try:
    var client = socket
    if isTls:
      gateway.ssl.wrapConnectedSocket(client, handshakeAsClient, uri.hostname)
    var head = "POST " & (if uri.path.len > 0: uri.path else: "/") & " HTTP/1.1\r\n"
    head.add "Host: " & uri.hostname
    if uri.port.len > 0:
      head.add ":" & uri.port
    head.add "\r\n"
    head.add "Content-Type: application/x-www-form-urlencoded\r\n"
    head.add "Accept: application/json\r\n"
    head.add "Content-Length: " & $form.len & "\r\n"
    head.add "Connection: close\r\n\r\n"

    # The budget starts once the connection is up, so connect and TLS keep their
    # own deadlines and a hung endpoint cannot pass for a slow provider (§4).
    let refreshDeadline = deadlineIn(RefreshDeadlineMs)
    let sendDeadline = if isTls: deadlineIn(TlsDeadlineMs) else: refreshDeadline
    if not await client.awaitSend(head, sendDeadline):
      return RefreshOutcome(ok: false, timedOut: isTls,
        detail: "token endpoint did not accept the request")
    if not await client.awaitSend(form, refreshDeadline):
      return RefreshOutcome(ok: false, timedOut: true,
        detail: "token endpoint timed out reading the request")

    var raw = ""
    var headDone = false
    while not headDone:
      if raw.len > MaxHeaderBytes:
        return RefreshOutcome(ok: false,
          detail: "token endpoint sent oversized headers")
      if raw.find("\r\n\r\n") >= 0:
        headDone = true
        break
      let got = await awaitRecv(client, 8192, refreshDeadline)
      case got.kind
      of rkData: raw.add got.data
      of rkTimeout:
        return RefreshOutcome(ok: false, timedOut: true,
          detail: "token endpoint timed out before headers")
      of rkEof, rkTruncated, rkError:
        return RefreshOutcome(ok: false,
          detail: "token endpoint closed before headers")

    let split = raw.find("\r\n\r\n")
    let (status, _) = parseHead(raw[0 ..< split])
    var payload = raw[split + 4 .. ^1]
    # Connection: close, so the body ends at EOF; the size is the only bound.
    while payload.len <= 1_048_576:
      let got = await awaitRecv(client, 16_384, refreshDeadline)
      if got.kind == rkData:
        payload.add got.data
      elif got.kind == rkTimeout:
        return RefreshOutcome(ok: false, timedOut: true,
          detail: "token endpoint timed out reading the body")
      else:
        break
    if status < 200 or status >= 300:
      return RefreshOutcome(ok: false, detail: "token endpoint answered " & $status)
    var node: JsonNode
    try:
      node = parseJson(payload)
    except CatchableError:
      return RefreshOutcome(ok: false,
        detail: "token endpoint answered with non-JSON")
    if node.kind != JObject:
      return RefreshOutcome(ok: false,
        detail: "token endpoint answered with non-object JSON")
    let access = node{"access_token"}
    if access == nil or access.kind != JString or access.getStr().len == 0:
      return RefreshOutcome(ok: false,
        detail: "token answer carried no access_token")

    gateway.oauth[index].accessToken = access.getStr()
    let rotated = node{"refresh_token"}
    if rotated != nil and rotated.kind == JString and rotated.getStr().len > 0:
      gateway.oauth[index].refreshToken = rotated.getStr()
    let expiresIn = node{"expires_in"}
    if expiresIn != nil and expiresIn.kind == JInt and expiresIn.getInt() > 0:
      gateway.oauth[index].expiresAt = epochTime() + expiresIn.getInt().float
    else:
      gateway.oauth[index].expiresAt = 0
    discard gateway.persistOauth(index)
    RefreshOutcome(ok: true)
  except CatchableError as error:
    RefreshOutcome(ok: false, detail: "token endpoint unusable: " & error.msg)
  finally:
    closeQuietly(socket)

proc refreshIfNeeded(gateway: Gateway, index: int,
                     force: bool): Future[RefreshOutcome] {.async.} =
  ## Single flight: the first request that needs a refresh makes the call and
  ## every other one waits on the same future, so eight concurrent requests cost
  ## one token call, not eight.
  let leg = gateway.cfg.legs[index]
  if not leg.hasOauth:
    return RefreshOutcome(ok: true)
  if not force:
    let expiresAt = gateway.oauth[index].expiresAt
    if expiresAt <= 0:
      # No expiry in the config: nothing says the token is stale, so only a 401
      # is allowed to force a refresh.
      return RefreshOutcome(ok: true)
    if epochTime() < expiresAt - leg.oauth.refreshSkewSeconds.float:
      return RefreshOutcome(ok: true)
  if gateway.oauth[index].inFlight != nil:
    return await gateway.oauth[index].inFlight
  let pending = gateway.refreshLeg(index)
  gateway.oauth[index].inFlight = pending
  var outcome: RefreshOutcome
  try:
    outcome = await pending
  finally:
    gateway.oauth[index].inFlight = nil
  outcome

proc refreshReason(outcome: RefreshOutcome): string =
  if outcome.timedOut: TokenRefreshTimeout else: TokenRefreshFailed

proc bearerFor(gateway: Gateway, index: int, keyIndex = 0): string =
  ## An oauth leg sends its live access token; a pooled leg sends the entry the
  ## rotation chose; a leg with one `api_key` is a pool of one.
  let leg = gateway.cfg.legs[index]
  if leg.hasOauth:
    return gateway.oauth[index].accessToken
  if leg.apiKeys.len > 0:
    if keyIndex >= 0 and keyIndex < leg.apiKeys.len:
      return leg.apiKeys[keyIndex]
    return ""
  leg.apiKey

proc pickKeyIndex*(gateway: Gateway, index: int, now: float): int =
  ## The pool entry this dial should use. -1 means every key in the pool is
  ## cooling, so the leg cannot be dialled at all and the walk moves on without a
  ## cooldown on the leg itself.
  let leg = gateway.cfg.legs[index]
  if leg.apiKeys.len == 0:
    return 0
  if leg.apiKeys.len == 1:
    return 0
  let runtime = gateway.legs[index]
  if runtime.keyIndex >= 0 and runtime.keyIndex < leg.apiKeys.len and
     (runtime.keyCooling.len <= runtime.keyIndex or
      runtime.keyCooling[runtime.keyIndex] <= now):
    return runtime.keyIndex
  for key in 0 ..< leg.apiKeys.len:
    if runtime.keyCooling.len <= key or runtime.keyCooling[key] <= now:
      return key
  -1

proc coolKey*(gateway: Gateway, index, keyIndex: int, reason: string): bool =
  ## A dead credential is not a dead leg: one pool entry is skipped for its own
  ## cooldown and the leg stays available. Returns whether another live key is
  ## left to try, so the caller knows to dial again instead of failing over.
  ## A leg with a pool of one has nothing to rotate to and keeps the leg-level
  ## cooldown it always had.
  let leg = gateway.cfg.legs[index]
  if leg.apiKeys.len <= 1:
    return false
  let cooldown =
    if reason in [TokenQuota429, TokenBilling402]: CapacityCooldownS
    else: AvailabilityCooldownS
  let now = epochTime()
  var runtime = addr gateway.legs[index]
  if runtime.keyCooling.len != leg.apiKeys.len:
    runtime.keyCooling = newSeq[float](leg.apiKeys.len)
  if keyIndex >= 0 and keyIndex < runtime.keyCooling.len:
    runtime.keyCooling[keyIndex] = now + cooldown
  runtime.keyIndex = -1
  gateway.pickKeyIndex(index, now) >= 0

proc isRetryable*(reason: string): bool =
  ## The classes where dialling the same leg again can plausibly answer: a refused
  ## connection, a dial or header deadline, an upstream 5xx. A 401 rotates a key
  ## instead, and a quota 429, a missing session, a dead model and a caller error
  ## are all decided, so retrying them only spends time.
  reason in [TokenConnRefused, TokenDialTimeout, TokenHeaderTimeout,
             TokenUpstream5xx]

proc retryPauseMs*(attempt: int, jitterSeed: int): int =
  ## Doubling from RetryBaseMs up to RetryCeilingMs, plus up to a quarter of the
  ## pause as jitter so a fleet of callers does not resynchronise on one leg.
  var pause = RetryBaseMs
  for _ in 1 .. attempt:
    pause = pause * 2
    if pause >= RetryCeilingMs:
      pause = RetryCeilingMs
      break
  if pause > RetryCeilingMs:
    pause = RetryCeilingMs
  let span = pause div 4
  if span <= 0:
    return pause
  pause + (abs(jitterSeed) mod (span + 1))

proc attemptLeg(gateway: Gateway, request: Request, leg: Leg, bearer: string,
                body: string, stream: bool, totalDeadline: float,
                aliasMapped = false): Future[AttemptOutcome] {.async.} =
  ## One leg, one attempt, and the caller's response written from here when the
  ## attempt produced one. The failover window ends when response headers arrive
  ## (§3b.2), so everything below that line either serves or aborts.
  result.status = 502
  let uri = parseUri(leg.baseUrl)
  let isTls = uri.scheme == "https"

  var connected: bool
  var dialTimedOut: bool
  var socket: AsyncSocket
  (connected, dialTimedOut, socket) = await dial(uri)
  if not connected:
    result.kind = akFailed
    result.reason = if dialTimedOut: TokenDialTimeout else: TokenConnRefused
    return

  # §3b.2: once headers from a leg have reached the caller, this request is bound
  # to that leg. `headersSent` is what makes the exception handler below able to
  # tell a broken leg from a caller that went away after the answer started.
  var headersSent = false

  try:
    var client = socket
    if isTls:
      gateway.ssl.wrapConnectedSocket(client, handshakeAsClient, uri.hostname)

    var head = "POST " & upstreamPath(leg.baseUrl) & " HTTP/1.1\r\n"
    head.add "Host: " & uri.hostname
    if uri.port.len > 0:
      head.add ":" & uri.port
    head.add "\r\n"
    head.add "Content-Type: application/json\r\n"
    head.add "Content-Length: " & $body.len & "\r\n"
    head.add "Accept: " & (if stream: "text/event-stream" else: "application/json") & "\r\n"
    head.add "Connection: close\r\n"
    var hasAuthorization = false
    for (name, value) in leg.headers:
      if name.toLowerAscii() == "authorization":
        hasAuthorization = true
      head.add name & ": " & value & "\r\n"
    if bearer.len > 0 and not hasAuthorization:
      head.add "Authorization: Bearer " & bearer & "\r\n"
    head.add "\r\n"

    # The head send drives the TLS handshake, so its deadline is the TLS one.
    let handshakeDeadline =
      if isTls: deadlineIn(TlsDeadlineMs)
      else: deadlineIn(gateway.cfg.headerNonStreamMs)
    if not await client.awaitSend(head, handshakeDeadline):
      result.kind = akFailed
      result.reason = if isTls: TokenDialTimeout else: TokenConnRefused
      return
    if body.len > 0:
      if not await client.awaitSend(body, totalDeadline):
        result.kind = akFailed
        result.reason = TokenConnRefused
        return

    # ---- response headers: the end of the failover window (§3b.2) ----
    result.headerWindowMs =
      if stream: streamHeaderDeadlineMs(gateway.cfg.headerStreamBaseMs,
                                        gateway.cfg.headerStreamPerKiBMs,
                                        gateway.cfg.headerStreamMaxMs, body.len)
      else: gateway.cfg.headerNonStreamMs
    let headerSentAt = epochTime()
    let headerDeadline = deadlineIn(result.headerWindowMs)
    var raw = ""
    var headDone = false
    while not headDone:
      if raw.len > MaxHeaderBytes:
        result.kind = akFailed
        result.reason = TokenUpstream5xx
        return
      let stop = raw.find("\r\n\r\n")
      if stop >= 0:
        headDone = true
        break
      let got = await awaitRecv(client, 8192, headerDeadline)
      case got.kind
      of rkData: raw.add got.data
      of rkTimeout:
        result.kind = akFailed
        result.reason = TokenHeaderTimeout
        return
      of rkEof, rkTruncated, rkError:
        result.kind = akFailed
        result.reason = TokenConnRefused
        return

    let split = raw.find("\r\n\r\n")
    let (status, headers) = parseHead(raw[0 ..< split])
    let leftover = raw[split + 4 .. ^1]
    # DEC-26. The measurement the plan asked for: body sent to first byte of the
    # response head. Only the answering leg records one, so a failed leg leaves it
    # unknown rather than reporting a wait it did not finish.
    result.headerMs = max(0, int((epochTime() - headerSentAt) * 1000.0))
    let retryHeader = headerValue(headers, "retry-after")
    if retryHeader.len > 0:
      try:
        let seconds = parseInt(retryHeader.strip())
        if seconds >= 0:
          result.retryAfterS = seconds
      except ValueError:
        discard
    if status == 0:
      result.kind = akFailed
      result.reason = TokenUpstream5xx
      return

    var reader = UpstreamReader(socket: client, buf: leftover, mode: bmEof)
    let transferEncoding = headerValue(headers, "transfer-encoding").toLowerAscii()
    let contentLength = headerValue(headers, "content-length")
    if transferEncoding.contains("chunked"):
      reader.mode = bmChunked
    elif contentLength.len > 0:
      try:
        reader.mode = bmLength
        reader.remaining = parseInt(contentLength)
      except ValueError:
        reader.mode = bmEof

    if not isSuccessStatus(status):
      # Read the body only when classification needs it, or when the caller will
      # receive it unchanged. 401 and 5xx fail over on the status alone.
      var errorBody = ""
      if status == 400 or status == 429 or status < 500:
        let budget = totalDeadline
        while true:
          let slice = await reader.readSlice(budget)
          if slice.kind == rkData:
            errorBody.add slice.data
            if errorBody.len > MaxBodyBytes:
              break
          elif slice.kind == rkTimeout:
            if status < 500 and status != 400 and status != 429:
              break
            break
          else:
            break

      let token = failureToken(status, errorBody, aliasMapped)
      if token.len > 0:
        result.kind = akFailed
        result.reason = token
        # DEC-26: a rate limit is the one failure whose own words are useful to
        # the caller. Keep them so the last leg can pass the 429 through.
        if token == TokenRateLimited:
          result.passthroughBody = errorBody
          result.status = status
        return
      # §3.3: any other 4xx is the caller's problem. Returned unchanged.
      let contentType = headerValue(headers, "content-type")
      headersSent = true
      await request.sendFull(status,
        (if contentType.len > 0: contentType else: "application/json"), errorBody)
      result.kind = akPassthrough
      result.status = status
      return

    # ---- a successful response: the request is bound to this leg ----
    let contentType = headerValue(headers, "content-type")
    if stream:
      let outgoing =
        if contentType.len > 0: contentType else: "text/event-stream"
      await request.client.send(buildHead(status, @[
        ("Content-Type", outgoing),
        ("Cache-Control", "no-cache"),
        ("Transfer-Encoding", "chunked")]))
      headersSent = true
      # The status the caller already has; the log must not report the 502 default
      # just because a write failed later.
      result.status = status
      var tokensIn: Option[int]
      var tokensOut: Option[int]
      var aborted = false
      var sawDone = false
      let needsDone = contentType.contains("event-stream")
      while true:
        let slice = await reader.readSlice(deadlineIn(ChunkIdleMs))
        case slice.kind
        of rkData:
          scanStreamUsage(slice.data, tokensIn, tokensOut)
          if slice.data.contains("[DONE]"):
            sawDone = true
          await request.client.send(chunkFrame(slice.data))
        of rkEof:
          break
        of rkTruncated, rkTimeout, rkError:
          aborted = true
          break
      # An event stream that closes without its terminator was cut short: the
      # caller gets the structured signal (§5.3 R9), never a silent half answer.
      if not aborted and needsDone and not sawDone:
        aborted = true
      if aborted:
        # §5.3 R9: exactly one SSE error event, then the stream closes. No second
        # provider, ever, in this request.
        await request.client.send(chunkFrame(
          sseErrorEvent(TokenMidStreamAbort, "upstream stream ended after the first byte")))
        await request.client.send("0\r\n\r\n")
        result.kind = akAborted
        result.status = status
        result.reason = TokenMidStreamAbort
        result.tokensIn = tokensIn
        result.tokensOut = tokensOut
        return
      await request.client.send("0\r\n\r\n")
      result.kind = akServed
      result.status = status
      result.tokensIn = tokensIn
      result.tokensOut = tokensOut
      return

    # Non-streaming: buffer, then answer. Headers are already in, so no failover.
    var payload = ""
    var aborted = false
    while true:
      let slice = await reader.readSlice(totalDeadline)
      case slice.kind
      of rkData:
        payload.add slice.data
        if payload.len > MaxBodyBytes:
          break
      of rkEof:
        break
      of rkTruncated, rkTimeout, rkError:
        aborted = true
        break
    let (tokensIn, tokensOut) = usageTokens(payload)
    if aborted and payload.len == 0:
      # T-A3d: nothing reached the caller and no failover is allowed, so the
      # caller gets a status it can act on and the log names no reason.
      await request.sendErrorBody(504,
        allLegsFailedBody("upstream_body_timeout"))
      result.kind = akTerminal
      result.status = 504
      return
    await request.sendFull(status,
      (if contentType.len > 0: contentType else: "application/json"), payload)
    headersSent = true
    if aborted:
      result.kind = akAborted
      result.status = status
      result.reason = TokenMidStreamAbort
      result.tokensIn = tokensIn
      result.tokensOut = tokensOut
      return
    result.kind = akServed
    result.status = status
    result.tokensIn = tokensIn
    result.tokensOut = tokensOut
  except CatchableError:
    # A socket error after headers were written is the caller leaving mid-answer:
    # the leg already produced the response and the write is what failed. A socket
    # error before anything reached the caller is an unusable leg. The closed
    # vocabulary has no other token for the second case, and `conn_refused` is the
    # honest one: the connection could not be established.
    if headersSent:
      result.kind = akAborted
      result.reason = TokenCallerFault    else:
      result.kind = akFailed
      result.reason = TokenConnRefused
  finally:
    closeQuietly(socket)

# -------------------------------------------------------------------- proxy ---

proc handleChat(gateway: Gateway, request: Request): Future[void] {.async.} =
  let started = epochTime()
  let totalDeadline = deadlineIn(TotalNonStreamMs)
  let callerBody = request.body
  let stream = wantsStream(callerBody)
  let forwardBody = if stream: injectIncludeUsage(callerBody) else: callerBody

  # Item 2: a `kori/<alias>` model is a gateway name resolved per leg, so one
  # caller name can reach providers that do not share model ids.
  let callerModel = requestModel(callerBody)
  let alias = aliasOf(callerModel)

  var chain = Chain()
  var status = 502
  var route = ""
  var terminalAbort = false
  var abortReason = ""
  var tokensIn: Option[int]
  var tokensOut: Option[int]
  var answered = false
  var hardStop = ""
  var hardStopDetail = ""

  # Item 4: the caller's effort, read once from the bytes that reach the legs.
  # Empty means the caller named none, and then nothing here changes the body.
  let callerEffort = requestEffort(forwardBody)
  var effortSkips = 0
  var dials = 0
  var effortClampedLog = ""
  # Item (cost): the id the answering leg was actually sent, so the price lookup
  # uses the provider's model and not the caller's alias.
  var servedModel = ""
  # DEC-26. Facts the response and the log both need.
  var headerMs = -1
  var legsCooling = -1
  var retryAfterS = -1
  var terminalReason = ""
  var lastRateBody = ""
  var lastRateStatus = 429
  var lastRateS = -1
  let singleLeg = gateway.enabledLegCount() == 1
  let promptKib = forwardBody.len div 1024

  var aliasKnown = false
  if alias.isSome and not aliasTooLong(alias.get):
    for leg in gateway.cfg.legs:
      if leg.aliases.hasKey(alias.get):
        aliasKnown = true
        break
  if alias.isSome and aliasTooLong(alias.get):
    # Item 3: bounded here, before any leg is touched. The body is fixed text, so
    # an oversized model string is never echoed back at the caller.
    await request.sendErrorBody(400, aliasTooLongBody())
    status = 400
    answered = true
    chain.firstReason = TokenAliasTooLong
  elif alias.isSome and gateway.modelDisabled(alias.get):
    # DEC-27. The alias exists and the operator switched it off, which is a
    # different fact from a name no leg maps.
    await request.sendErrorBody(400, aliasDisabledBody(alias.get))
    status = 400
    answered = true
    chain.firstReason = TokenAliasDisabled
  elif alias.isSome and not aliasKnown:
    # No leg in the config maps this name: a client error with a body that says
    # so, not a 500 and not a walk that ends in an all-legs-failed 502.
    await request.sendErrorBody(400, unknownAliasBody(alias.get))
    status = 400
    answered = true
    chain.firstReason = TokenUnknownAlias

  let order = gateway.pickOrder()
  if not answered and order.len == 0:
    # DEC-26. No dial at all (D12.3's third sentence), and an honest answer: what
    # the caller can do (wait) and for how long. Nothing here names a leg.
    let summary = gateway.coolingSummary(epochTime())
    route = ""
    status = 503
    answered = true
    if summary.enabled == 0:
      terminalReason = "no_leg_enabled"
      legsCooling = 0
      await request.sendErrorBody(503, noLegEnabledBody())
    else:
      terminalReason = "all_legs_cooling"
      legsCooling = summary.cooling
      retryAfterS = max(summary.retryAfterS, 1)
      await request.sendErrorBodyWithHeaders(503,
        allLegsCoolingBody(retryAfterS), @[("Retry-After", $retryAfterS)])

  if not answered:
    for position, index in order:
      let leg = gateway.cfg.legs[index]
      # Item 2: a leg with no mapping for this alias is skipped. No dial, no
      # cooldown, no half-open probe, and the reason the log carries names it.
      if alias.isSome and not leg.aliases.hasKey(alias.get):
        chain.lastReason = TokenAliasUnmapped
        if chain.firstReason.len == 0:
          chain.firstReason = TokenAliasUnmapped
          chain.firstFrom = leg.name
          chain.availability = true
        if position + 1 < order.len:
          gateway.recordEvent(leg.name, gateway.cfg.legs[order[position + 1]].name,
                              TokenAliasUnmapped)
        continue
      # Item 4: a leg whose ceiling has nothing at or below the caller's value
      # cannot serve this request at any level the caller agreed to. It is
      # skipped the same way an unmapped alias is: no dial, no cooldown, no
      # half-open probe, and the walk moves to the next leg.
      let effortChoice = decideEffort(leg, callerEffort)
      if effortChoice.skip:
        inc effortSkips
        chain.lastReason = TokenEffortUnsupported
        if chain.firstReason.len == 0:
          chain.firstReason = TokenEffortUnsupported
          chain.firstFrom = leg.name
          chain.availability = true
        if position + 1 < order.len:
          gateway.recordEvent(leg.name, gateway.cfg.legs[order[position + 1]].name,
                              TokenEffortUnsupported)
        continue
      # §4: a credential that cannot be refreshed stops the request here. Nothing
      # is dialled, nothing is failed over, no stale bearer leaves the process.
      if leg.hasOauth:
        let ready = await gateway.refreshIfNeeded(index, force = false)
        if not ready.ok:
          hardStop = refreshReason(ready)
          hardStopDetail = ready.detail
          route = leg.name
          break
      gateway.markAttempted(index)
      inc dials
      route = leg.name
      # DEC-10: a leg that names a model gets that id, and only that leg does. An
      # alias request resolves per leg instead: a leg's static `model` does not
      # stand in for a missing alias mapping, it is only the non-alias default.
      var legBody =
        if alias.isSome: rewriteModel(forwardBody, leg.aliases[alias.get])
        elif leg.hasModel: rewriteModel(forwardBody, leg.model)
        else: forwardBody
      servedModel =
        if alias.isSome: leg.aliases[alias.get]
        elif leg.hasModel: leg.model
        else: callerModel
      # Item 4: a clamped value is rewritten in place, textually, so every other
      # byte the caller sent still reaches the leg. A clamp is recorded against
      # the leg that answers, so a clamp on a leg that then failed is replaced by
      # whatever the next leg decided.
      if effortChoice.clamped:
        legBody = rewriteTopLevelString(legBody, "reasoning_effort",
                                        effortChoice.sent)
      effortClampedLog =
        if effortChoice.clamped: callerEffort & ">" & effortChoice.sent
        else: ""
      # P1: one leg may be dialled more than once. A dead key in the pool rotates
      # before the leg is blamed, a retryable transport failure gets the leg's
      # `retries` extra dials, and a 401 on an oauth leg buys one forced refresh.
      # Every path is bounded by the pool length, the retry ceiling or a flag, so
      # no request can loop here.
      var keyIndex = gateway.pickKeyIndex(index, epochTime())
      if keyIndex < 0:
        # Every key in the pool is cooling. Nothing is dialled and the leg itself
        # is not put on a cooldown: its credentials are, which is a different fact.
        chain.lastReason = TokenAuth401
        if chain.firstReason.len == 0:
          chain.firstReason = TokenAuth401
          chain.firstFrom = leg.name
          chain.availability = true
        if position + 1 < order.len:
          gateway.recordEvent(leg.name, gateway.cfg.legs[order[position + 1]].name,
                              TokenAuth401)
        continue
      var rotations = 0
      var oauthRetried = false
      var retriesUsed = 0
      # §3.2 half-open probe: exactly one dial may leave for a cooling leg, and the
      # latch is taken here, after every skip that dials nothing, so no `continue`
      # above it can leave the latch on with no reset behind it.
      let probing = gateway.legs[index].coolingUntil > 0
      if probing:
        gateway.legs[index].probeInFlight = true
      var outcome: AttemptOutcome
      block legDials:
        while true:
          outcome = await gateway.attemptLeg(request, leg,
                                             gateway.bearerFor(index, keyIndex),
                                             legBody, stream, totalDeadline,
                                             alias.isSome)
          if outcome.kind != akFailed:
            break legDials
          # A 401 from an oauth leg buys one forced refresh and one more dial, then
          # it is classified exactly as before. Never a loop.
          if outcome.reason == TokenAuth401 and leg.hasOauth and not oauthRetried:
            oauthRetried = true
            let retried = await gateway.refreshIfNeeded(index, force = true)
            if not retried.ok:
              hardStop = refreshReason(retried)
              hardStopDetail = retried.detail
              break legDials
            continue
          # A dead key is a dead credential, not a dead leg: rotate within the pool
          # until its live entries are spent, and only then blame the leg. A spent
          # balance is per credential, the same as a spent quota.
          if outcome.reason in [TokenAuth401, TokenQuota429, TokenBilling402] and
             leg.apiKeys.len > 1 and rotations + 1 < leg.apiKeys.len:
            inc rotations
            if gateway.coolKey(index, keyIndex, outcome.reason):
              let nextKey = gateway.pickKeyIndex(index, epochTime())
              if nextKey >= 0:
                keyIndex = nextKey
                continue
            break legDials
          # A retryable transport failure gets `retries` more dials on this leg.
          # Default 0: a config that does not ask for retries keeps 0.6.1's rule
          # that failover is the only retry.
          if retriesUsed < leg.retries and isRetryable(outcome.reason):
            inc retriesUsed
            await sleepAsync(retryPauseMs(retriesUsed, int(epochTime() * 1000.0)))
            continue
          break legDials
      if probing:
        gateway.legs[index].probeInFlight = false
      if hardStop.len > 0:
        break

      case outcome.kind
      of akFailed:
        gateway.startCooldown(index, outcome.reason, outcome.headerWindowMs,
                              singleLeg, outcome.retryAfterS)
        chain.lastReason = outcome.reason
        if chain.firstReason.len == 0:
          chain.firstReason = outcome.reason
          chain.firstFrom = leg.name
          if outcome.reason in [TokenQuota429, TokenBilling402]:
            chain.capacity = true
          else:
            chain.availability = true
        if outcome.reason == TokenRateLimited and outcome.passthroughBody.len > 0:
          # DEC-26. Keep the last 429 in the walk. If no leg serves, the caller
          # gets the provider's own 429 back instead of a fabricated 502.
          lastRateBody = outcome.passthroughBody
          lastRateStatus = outcome.status
          lastRateS = outcome.retryAfterS
        if position + 1 < order.len:
          gateway.recordEvent(leg.name, gateway.cfg.legs[order[position + 1]].name,
                              outcome.reason)
      of akServed, akAborted, akPassthrough, akTerminal:
        status = outcome.status
        terminalAbort = outcome.kind == akAborted
        if terminalAbort:
          abortReason = outcome.reason
        tokensIn = outcome.tokensIn
        tokensOut = outcome.tokensOut
        if outcome.headerMs >= 0:
          headerMs = outcome.headerMs
        # A caller that hung up still got a live answer from a live leg, so the
        # leg is marked served: the abort is the caller's fault, not the leg's.
        if outcome.kind != akTerminal:
          gateway.markServed(index, int((epochTime() - started) * 1000.0))
        answered = true
        break

  if hardStop.len > 0:
    # §4: loud on stderr, one 502 to the caller, and no answer from an expired
    # credential. The detail never carries a token.
    stderr.writeLine("kori: credential refresh failed for route '" & route & "': " &
                     hardStopDetail)
    await request.sendErrorBody(502, credentialRefreshBody(hardStop, hardStopDetail))
    status = 502
    tokensIn = none(int)
    tokensOut = none(int)
    answered = true

  let effortStop = effortStopWithoutDial(dials, effortSkips)
  if not answered and effortStop and hardStop.len == 0:
    # Item 4: the value the caller asked for is what ended this request: no leg
    # was dialled and at least one was skipped for its ceiling. A walk that also
    # skipped an unmapped alias lands here too, because those skips are counted
    # separately instead of being compared with the walk length. A 400 with a
    # body that names the value, the same shape an unknown alias gets, and no
    # cooldown was started. A leg that was really dialled and failed keeps the
    # 502 below.
    route = gateway.cfg.legs[^1].name
    await request.sendErrorBody(400, effortUnsupportedBody(callerEffort))
    status = 400
    tokensIn = none(int)
    tokensOut = none(int)
    answered = true

  if not answered and lastRateBody.len > 0:
    # DEC-26. The walk ended on a plain 429: return the provider's own body and
    # its own Retry-After, not an all-legs-failed 502.
    var extra: seq[(string, string)]
    if lastRateS >= 0:
      extra.add ("Retry-After", $lastRateS)
    await request.sendErrorBodyWithHeaders(lastRateStatus, lastRateBody, extra)
    status = lastRateStatus
    retryAfterS = lastRateS
    terminalReason = TokenRateLimited
    tokensIn = none(int)
    tokensOut = none(int)
    answered = true

  if not answered:
    # §5.5: one 502 whatever the legs returned, carrying the terminal reason.
    let message = if chain.lastReason.len > 0: chain.lastReason else: "all_legs_failed"
    await request.sendErrorBody(502, allLegsFailedBody(message))
    status = 502
    tokensIn = none(int)
    tokensOut = none(int)

  gateway.requests.inc
  if tokensIn.isSome:
    gateway.tokensInTotal += tokensIn.get
  if tokensOut.isSome:
    gateway.tokensOutTotal += tokensOut.get
  # Galih's LOW from the 0.6.1 gate: an effort skip followed by a credential 502
  # used to move no availability counter, because the effort stop was decided from
  # the dial count alone. The suppression belongs to the answer the caller got, so
  # it is keyed on the 400 and not on the skip: the 502 that a broken credential
  # produced is an availability failure and is counted here.
  let suppressAvailability = effortStop and status == 400
  if countsTowardAvailability(chain.availability, suppressAvailability):
    gateway.failoverAvailability.inc
  if chain.capacity:
    gateway.failoverCapacity.inc

  # §5.1: `failover_reason` is the first reason the request met, with the abort
  # that the caller actually saw as the one override (D9.2, D10.1). A caller that
  # hung up before the answer finished is named as itself (`caller_fault`), not as
  # `mid_stream_abort`: the leg was healthy, and a push of abandoned requests must
  # not read as a provider going bad. A request that never failed over keeps the
  # empty string, which is the binding answer for this field. A hard stop is not a
  # failover: nothing was abandoned, so `failover_from` stays empty.
  let logReason =
    if hardStop.len > 0: hardStop
    elif terminalAbort and abortReason.len > 0: abortReason
    elif terminalAbort: TokenMidStreamAbort
    elif terminalReason.len > 0: terminalReason
    else: chain.firstReason

  let latencyMs = int((epochTime() - started) * 1000.0)
  # The price lookup uses the id the answering leg was sent, then the config's
  # catch-all. An answer with no token count is left unpriced, never estimated.
  let costUsd =
    if gateway.cfg.prices.len == 0: none(float)
    else: requestCost(gateway.cfg, servedModel, tokensIn, tokensOut)
  gateway.metrics.recordMetrics(route, status, latencyMs, logReason)
  if costUsd.isSome:
    gateway.costUsdTotal += costUsd.get
    inc gateway.costUsdKnown
  gateway.recordRequestLog(requestLogLine(
      ts = nowStamp(),
      route = route,
      status = status,
      latencyMs = latencyMs,
      tokensIn = tokensIn,
      tokensOut = tokensOut,
      failoverFrom = (if hardStop.len > 0: "" else: chain.firstFrom),
      failoverReason = logReason,
      stream = stream,
      # The caller's own string, prefix included, so the line says what was
      # asked for while `route` keeps saying which leg answered.
      alias = (if alias.isSome: aliasLogValue(alias.get) else: ""),
      # Empty unless the answering leg pulled the effort down, so a request that
      # never clamped keeps the nine keys it had before this feature.
      effortClamped = effortClampedLog,
      # Absent on a model the config does not price: "not priced" is not "$0.00".
      costUsd = costUsd,
      promptKib = promptKib,
      headerMs = headerMs,
      legsCooling = legsCooling,
      retryAfterS = retryAfterS))

# ------------------------------------------------------------- systemone ---

proc attemptSystemone(gateway: Gateway, request: Request, leg: SystemoneLeg,
                      body: string, totalDeadline: float): Future[AttemptOutcome] {.async.} =
  ## DEC-19. One System One leg, one attempt, no retry and no key pool: the body
  ## goes upstream with exactly one field changed (the model id) and whatever the
  ## provider answers is written back untouched. A response is forwarded when it
  ## arrives, so there is no failover window after the caller has seen a byte.
  result.status = 502
  let uri = parseUri(leg.baseUrl)
  let isTls = uri.scheme == "https"

  var connected: bool
  var dialTimedOut: bool
  var socket: AsyncSocket
  (connected, dialTimedOut, socket) = await dial(uri)
  if not connected:
    result.kind = akFailed
    result.reason = if dialTimedOut: TokenDialTimeout else: TokenConnRefused
    return

  var headersSent = false
  try:
    var client = socket
    if isTls:
      gateway.ssl.wrapConnectedSocket(client, handshakeAsClient, uri.hostname)

    var head = "POST " & systemonePath(leg.baseUrl) & " HTTP/1.1\r\n"
    head.add "Host: " & uri.hostname
    if uri.port.len > 0:
      head.add ":" & uri.port
    head.add "\r\n"
    head.add "Content-Type: application/json\r\n"
    head.add "Content-Length: " & $body.len & "\r\n"
    head.add "Accept: application/json\r\n"
    head.add "Connection: close\r\n"
    var hasAuthorization = false
    for (name, value) in leg.headers:
      if name.toLowerAscii() == "authorization":
        hasAuthorization = true
      head.add name & ": " & value & "\r\n"
    if leg.apiKey.len > 0 and not hasAuthorization:
      head.add "Authorization: Bearer " & leg.apiKey & "\r\n"
    head.add "\r\n"

    let handshakeDeadline =
      if isTls: deadlineIn(TlsDeadlineMs)
      else: deadlineIn(gateway.cfg.headerNonStreamMs)
    if not await client.awaitSend(head, handshakeDeadline):
      result.kind = akFailed
      result.reason = if isTls: TokenDialTimeout else: TokenConnRefused
      return
    if body.len > 0:
      if not await client.awaitSend(body, totalDeadline):
        result.kind = akFailed
        result.reason = TokenConnRefused
        return

    let headerDeadline = deadlineIn(gateway.cfg.headerNonStreamMs)
    result.headerWindowMs = gateway.cfg.headerNonStreamMs
    let headerSentAt = epochTime()
    var raw = ""
    var headDone = false
    while not headDone:
      if raw.len > MaxHeaderBytes:
        result.kind = akFailed
        result.reason = TokenUpstream5xx
        return
      let stop = raw.find("\r\n\r\n")
      if stop >= 0:
        headDone = true
        break
      let got = await awaitRecv(client, 8192, headerDeadline)
      case got.kind
      of rkData: raw.add got.data
      of rkTimeout:
        result.kind = akFailed
        result.reason = TokenHeaderTimeout
        return
      of rkEof, rkTruncated, rkError:
        result.kind = akFailed
        result.reason = TokenConnRefused
        return

    let split = raw.find("\r\n\r\n")
    let (status, headers) = parseHead(raw[0 ..< split])
    let leftover = raw[split + 4 .. ^1]
    # DEC-26. The measurement the plan asked for: body sent to first byte of the
    # response head. Only the answering leg records one, so a failed leg leaves it
    # unknown rather than reporting a wait it did not finish.
    result.headerMs = max(0, int((epochTime() - headerSentAt) * 1000.0))
    let retryHeader = headerValue(headers, "retry-after")
    if retryHeader.len > 0:
      try:
        let seconds = parseInt(retryHeader.strip())
        if seconds >= 0:
          result.retryAfterS = seconds
      except ValueError:
        discard
    if status == 0:
      result.kind = akFailed
      result.reason = TokenUpstream5xx
      return

    var reader = UpstreamReader(socket: client, buf: leftover, mode: bmEof)
    let transferEncoding = headerValue(headers, "transfer-encoding").toLowerAscii()
    let contentLength = headerValue(headers, "content-length")
    if transferEncoding.contains("chunked"):
      reader.mode = bmChunked
    elif contentLength.len > 0:
      try:
        reader.mode = bmLength
        reader.remaining = parseInt(contentLength)
      except ValueError:
        reader.mode = bmEof

    # A decision is one small JSON answer, so the body is buffered either way:
    # the log needs the token counts, and a caller that gets an error gets the
    # provider's own words rather than a summary.
    var payload = ""
    var aborted = false
    while true:
      let slice = await reader.readSlice(totalDeadline)
      case slice.kind
      of rkData:
        payload.add slice.data
        if payload.len > MaxBodyBytes:
          break
      of rkEof:
        break
      of rkTruncated, rkTimeout, rkError:
        aborted = true
        break

    let contentType = headerValue(headers, "content-type")

    if not isSuccessStatus(status):
      # The chat door's own failure classes, with one addition this door needs:
      # a provider that says it does not take this model is a bad leg, not a bad
      # caller, so the walk moves on instead of handing the caller a 400 that
      # names a model they never chose.
      var token = failureToken(status, payload)
      if token.len == 0 and systemoneUnsupportedBody(payload):
        token = TokenModelGone
      if token.len > 0:
        result.kind = akFailed
        result.reason = token
        return
      headersSent = true
      await request.sendFull(status,
        (if contentType.len > 0: contentType else: "application/json"), payload)
      result.kind = akPassthrough
      result.status = status
      return

    if aborted and payload.len == 0:
      await request.sendErrorBody(504, allLegsFailedBody("upstream_body_timeout"))
      result.kind = akTerminal
      result.status = 504
      return

    await request.sendFull(status,
      (if contentType.len > 0: contentType else: "application/json"), payload)
    headersSent = true
    let (tokensIn, tokensOut) = systemoneUsage(payload)
    result.tokensIn = tokensIn
    result.tokensOut = tokensOut
    if aborted:
      result.kind = akAborted
      result.status = status
      result.reason = TokenMidStreamAbort
      return
    result.kind = akServed
    result.status = status
  except CatchableError:
    if headersSent:
      result.kind = akAborted
      result.reason = TokenCallerFault
    else:
      result.kind = akFailed
      result.reason = TokenConnRefused
  finally:
    closeQuietly(socket)

proc handleSystemone(gateway: Gateway, request: Request): Future[void] {.async.} =
  ## DEC-19. `POST /v1/systemone`: a passthrough for a decision request. The one
  ## edit is the top-level `model`, replaced with the leg's configured id; every
  ## other byte the caller sent reaches the provider. No streaming (System One is
  ## one JSON answer), no retry, no key pool, no second protocol path.
  let started = epochTime()
  let totalDeadline = deadlineIn(TotalNonStreamMs)
  var body = request.body

  var status = 502
  var route = ""
  var terminalAbort = false
  var abortReason = ""
  var tokensIn: Option[int]
  var tokensOut: Option[int]
  var answered = false
  var servedModel = ""
  var firstFrom = ""
  var firstReason = ""
  var headerMs = -1
  var legsCooling = -1
  var retryAfterS = -1
  var terminalReason = ""
  var lastRateBody = ""
  var lastRateStatus = 429
  var lastRateS = -1
  let singleLeg = gateway.systemoneEnabledCount() == 1
  let promptKib = body.len div 1024

  let order = gateway.systemoneOrder(epochTime())
  if order.len == 0:
    # DEC-26. Same honest answer as the chat door: no leg is dialled, so the code
    # is 503 and the body says how long to wait. Nothing here names a leg.
    let summary = gateway.systemoneCoolingSummary(epochTime())
    route = ""
    status = 503
    answered = true
    if summary.enabled == 0:
      terminalReason = "no_leg_enabled"
      legsCooling = 0
      await request.sendErrorBody(503, noLegEnabledBody())
    else:
      terminalReason = "all_legs_cooling"
      legsCooling = summary.cooling
      retryAfterS = max(summary.retryAfterS, 1)
      await request.sendErrorBodyWithHeaders(503,
        allLegsCoolingBody(retryAfterS), @[("Retry-After", $retryAfterS)])

  if not answered and body.strip().len == 0:
    route = gateway.cfg.systemone[0].name
    await request.sendErrorBody(400,
      "{\"error\":{\"type\":\"bad_request\",\"message\":\"body\"}}")
    status = 400
    answered = true

  if not answered:
    for position, index in order:
      let leg = gateway.cfg.systemone[index]
      route = leg.name
      gateway.systemone[index].attempted = true
      servedModel = leg.model
      let legBody = rewriteModel(body, leg.model)
      let outcome = await gateway.attemptSystemone(request, leg, legBody,
                                                  totalDeadline)
      if outcome.kind == akFailed:
        gateway.startSystemoneCooldown(index, outcome.reason,
                                       outcome.headerWindowMs, singleLeg,
                                       outcome.retryAfterS)
        if firstReason.len == 0:
          firstReason = outcome.reason
          firstFrom = leg.name
        if outcome.reason == TokenRateLimited and outcome.passthroughBody.len > 0:
          lastRateBody = outcome.passthroughBody
          lastRateStatus = outcome.status
          lastRateS = outcome.retryAfterS
        if position + 1 < order.len:
          gateway.recordEvent(leg.name,
                              gateway.cfg.systemone[order[position + 1]].name,
                              outcome.reason)
        continue
      status = outcome.status
      terminalAbort = outcome.kind == akAborted
      if terminalAbort:
        abortReason = outcome.reason
      tokensIn = outcome.tokensIn
      tokensOut = outcome.tokensOut
      if outcome.headerMs >= 0:
        headerMs = outcome.headerMs
      if outcome.kind != akTerminal:
        gateway.markSystemoneServed(index)
      answered = true
      break

  if not answered and lastRateBody.len > 0:
    var extra: seq[(string, string)]
    if lastRateS >= 0:
      extra.add ("Retry-After", $lastRateS)
    await request.sendErrorBodyWithHeaders(lastRateStatus, lastRateBody, extra)
    status = lastRateStatus
    retryAfterS = lastRateS
    terminalReason = TokenRateLimited
    tokensIn = none(int)
    tokensOut = none(int)
    answered = true

  if not answered:
    let message = if firstReason.len > 0: firstReason else: "all_legs_failed"
    await request.sendErrorBody(502, allLegsFailedBody(message))
    status = 502
    tokensIn = none(int)
    tokensOut = none(int)

  # The same completion the chat door uses, so this door's decisions land in the
  # same log and the same counters. No alias and no effort apply here, and
  # `stream` is always false: System One answers once.
  gateway.requests.inc
  if tokensIn.isSome:
    gateway.tokensInTotal += tokensIn.get
  if tokensOut.isSome:
    gateway.tokensOutTotal += tokensOut.get

  let logReason =
    if terminalAbort and abortReason.len > 0: abortReason
    elif terminalAbort: TokenMidStreamAbort
    elif terminalReason.len > 0: terminalReason
    else: firstReason

  let latencyMs = int((epochTime() - started) * 1000.0)
  let costUsd =
    if gateway.cfg.prices.len == 0: none(float)
    else: requestCost(gateway.cfg, servedModel, tokensIn, tokensOut)
  gateway.metrics.recordMetrics(route, status, latencyMs, logReason)
  if costUsd.isSome:
    gateway.costUsdTotal += costUsd.get
    inc gateway.costUsdKnown
  gateway.recordRequestLog(requestLogLine(
      ts = nowStamp(),
      route = route,
      status = status,
      latencyMs = latencyMs,
      tokensIn = tokensIn,
      tokensOut = tokensOut,
      failoverFrom = firstFrom,
      failoverReason = logReason,
      stream = false,
      costUsd = costUsd,
      promptKib = promptKib,
      headerMs = headerMs,
      legsCooling = legsCooling,
      retryAfterS = retryAfterS))

# ---------------------------------------------------------------- log tail ---

const
  ## D8: a page is a tail, never the whole file. 5,000 lines is the scan budget.
  LogScanBudget = 5000
  LogTailBlock = 8192

## The row projection. `alias`, `effort_clamped` and `cost_usd` are last and are
## only there when the line carries them: a request that named a provider id,
## never clamped and ran on an unpriced model has none of the three, and the page
## shows that absence rather than inventing an empty string or a zero.
const LogRowKeys = ["ts", "route", "status", "latency_ms", "tokens_in",
                    "tokens_out", "failover_from", "failover_reason", "stream",
                    "alias", "effort_clamped", "cost_usd", "prompt_kib",
                    "header_ms", "legs_cooling", "retry_after_s"]

const OptionalLogKeys* = ["alias", "effort_clamped", "cost_usd", "prompt_kib",
                          "header_ms", "legs_cooling", "retry_after_s"]

type
  LogFilter* = object
    route*: string
    hasRoute*: bool
    alias*: string
    hasAlias*: bool
    statusClass*: int        ## 0 absent, else 2, 4 or 5
    reason*: string
    hasReason*: bool
    stream*: int             ## -1 absent, 0 false, 1 true
    sinceEpoch*: float
    hasSince*: bool

  TailPage* = object
    exists*: bool
    bytes*: int64
    lines*: int
    rows*: seq[JsonNode]
    linesScanned*: int
    budgetExhausted*: bool
    reachedBeginning*: bool
    moreOlder*: bool
    oldestReadAt*: string
    offset*: int
    limit*: int

proc countLines*(path: string): int =
  ## The total line count is read once, at startup, so a page never has to walk
  ## the whole file to answer `file.lines`. Appends keep it in step afterwards.
  var file: File
  if not open(file, path, fmRead):
    return 0
  defer: file.close()
  var buffer = newString(65536)
  var lastByte = '\n'
  while true:
    let got = readBuffer(file, addr buffer[0], buffer.len)
    if got <= 0:
      break
    for index in 0 ..< got:
      if buffer[index] == '\n':
        inc result
    lastByte = buffer[got - 1]
  if lastByte != '\n':
    inc result

proc parseRfc3339*(value: string): Option[float] =
  ## Tolerant on fractional seconds only, because two producers write this log.
  var text = value.strip()
  let dot = text.find('.')
  if dot >= 0:
    var index = dot + 1
    while index < text.len and text[index] in {'0' .. '9'}:
      inc index
    text = text[0 ..< dot] & text[index .. ^1]
  try:
    result = some(parse(text, "yyyy-MM-dd'T'HH:mm:sszzz").toTime().toUnix().float)
  except CatchableError:
    result = none(float)

proc buildLogRow*(node: JsonNode): JsonNode =
  ## Exactly the twelve keys of SPEC §5.1, in that order. `alias`,
  ## `effort_clamped` and `cost_usd` are conditional and come last: they are there
  ## only when the line carries them. Anything else a line carries is dropped, so
  ## the page cannot widen the row by accident.
  result = newJObject()
  for key in LogRowKeys:
    let value = node{key}
    if value == nil:
      # `alias`, `effort_clamped` and `cost_usd` are the three keys a line may
      # legitimately lack; every other key is written on every line, so a null
      # there means the line itself is damaged.
      if key in OptionalLogKeys:
        continue
      result[key] = newJNull()
    else:
      result[key] = value

proc rowMatches*(node: JsonNode, filter: LogFilter): bool =
  if filter.hasRoute:
    let route = node{"route"}
    if route == nil or route.kind != JString or route.getStr() != filter.route:
      return false
  if filter.hasAlias:
    # The exact string the caller sent, prefix included. A row without the key
    # never matches: it answered a provider id, not an alias.
    let alias = node{"alias"}
    if alias == nil or alias.kind != JString or alias.getStr() != filter.alias:
      return false
  if filter.statusClass != 0:
    let status = node{"status"}
    if status == nil or status.kind != JInt or
       status.getInt() div 100 != filter.statusClass:
      return false
  if filter.hasReason:
    let reason = node{"failover_reason"}
    let text = if reason != nil and reason.kind == JString: reason.getStr() else: ""
    if text != filter.reason:
      return false
  if filter.stream >= 0:
    let stream = node{"stream"}
    let value = stream != nil and stream.kind == JBool and stream.getBool()
    if value != (filter.stream == 1):
      return false
  if filter.hasSince:
    let stamp = node{"ts"}
    if stamp == nil or stamp.kind != JString:
      return false
    let moment = parseRfc3339(stamp.getStr())
    if moment.isNone or moment.get < filter.sinceEpoch:
      return false
  true

proc readLogTail*(path: string, totalLines: int, offset, limit: int,
                  filter: LogFilter): TailPage =
  ## Scans backward from EOF, one block at a time, and stops once the page plus
  ## one proving line is in hand, the 5,000-line budget is spent, or the start of
  ## the file is reached. The whole file is never loaded.
  result.exists = fileExists(path)
  result.lines = totalLines
  result.offset = offset
  result.limit = limit
  result.reachedBeginning = true
  if not result.exists:
    return
  var file: File
  if not open(file, path, fmRead):
    result.exists = false
    return
  defer: file.close()
  let size = getFileSize(file)
  result.bytes = size
  # A page never needs more lines than the scan budget can hold, and clamping
  # keeps a huge `offset` from overflowing the target below.
  var wanted = offset + limit + 1
  if wanted < 0 or wanted > LogScanBudget + 1:
    wanted = LogScanBudget + 1
  var pos = size
  var buf = ""
  var processed = 0
  var scanned = 0
  var matched = 0
  var done = false
  result.reachedBeginning = false
  while not done and pos > 0:
    let count = int(min(int64(LogTailBlock), pos))
    let newPos = pos - count
    var chunk = newString(count)
    setFilePos(file, newPos)
    let got = readBuffer(file, addr chunk[0], count)
    if got <= 0:
      break
    if got < count:
      chunk.setLen(got)
    buf = chunk & buf
    pos = newPos
    var atLineStart = pos == 0
    if not atLineStart:
      var previous: char
      setFilePos(file, pos - 1)
      if readBuffer(file, addr previous, 1) == 1 and previous == '\n':
        atLineStart = true
    var parts = buf.split('\n')
    if buf.len > 0 and buf[^1] == '\n':
      parts.setLen(parts.len - 1)
    let firstComplete = if atLineStart: 0 else: 1
    let complete = parts.len - firstComplete
    var index = parts.len - processed - 1
    while index >= firstComplete:
      let line = parts[index]
      inc scanned
      if line.len > 0:
        var node: JsonNode
        var parsed = true
        try:
          node = parseJson(line)
        except CatchableError:
          parsed = false
        if parsed and node.kind == JObject and rowMatches(node, filter):
          inc matched
          if matched > offset and matched <= offset + limit:
            result.rows.add(buildLogRow(node))
      if matched >= wanted:
        done = true
        break
      if scanned >= LogScanBudget:
        done = true
        result.budgetExhausted = true
        break
      dec index
    processed = complete
  result.linesScanned = scanned
  # `done` means the scan stopped on its own terms (page full or budget spent),
  # so older lines remain behind the oldest one examined. A scan that ran out of
  # file instead reached the beginning and there is nothing older.
  result.reachedBeginning = not done
  result.moreOlder = done
  if result.rows.len > 0:
    let stamp = result.rows[^1]{"ts"}
    if stamp != nil and stamp.kind == JString:
      result.oldestReadAt = stamp.getStr()

proc parseQuery*(query: string): seq[(string, string)] =
  if query.len == 0:
    return
  for pair in query.split('&'):
    if pair.len == 0:
      continue
    let eq = pair.find('=')
    if eq < 0:
      result.add((decodeUrl(pair), ""))
    else:
      result.add((decodeUrl(pair[0 ..< eq]), decodeUrl(pair[eq + 1 .. ^1])))

proc queryValue(params: seq[(string, string)], key: string): Option[string] =
  for (name, value) in params:
    if name == key:
      return some(value)
  none(string)

proc badRequestBody(parameter: string): string =
  "{\"error\":{\"type\":\"bad_request\",\"message\":" &
    jsonEscape(parameter) & "}}"

proc redactUrl*(value: string): string =
  ## §5.4: a base URL is printed in full only when it carries no credential.
  ## `user:pass@host` is one: the authority (up to the first `/`, `?` or `#`)
  ## is stripped at its last `@`, and the query/fragment rules follow. The last
  ## `@` matters because a password may itself contain one, and the `?`/`#`
  ## bounds matter because an `@` past them is path or query data, not userinfo.
  var url = value
  let schemeAt = url.find("://")
  let authStart = if schemeAt >= 0: schemeAt + 3 else: 0

  # A URL's authority is `[userinfo@]host[:port]`, and userinfo may not contain an
  # unescaped `/`, `?` or `#`: when one is used, the rest of the credential lands
  # in what now looks like the path, the query or the fragment. A colon in the
  # authority that does not begin an all-digit port is the tell; a bracketed IPv6
  # host is never userinfo.
  block:
    var sep = url.len
    for stop in ['/', '?', '#']:
      let hit = url.find(stop, authStart)
      if hit >= 0 and hit < sep:
        sep = hit
    let bracketed = authStart < url.len and url[authStart] == '['
    # Judge the port by the LAST colon in the span. `host:`, `host:443` and
    # `host:443:` all have to land in the right bucket, and the first colon in
    # `127.0.0.1:8090:` is the real port, not the tell.
    let span = if authStart < sep: url[authStart ..< sep] else: ""
    let colon = span.rfind(':')
    var credential = false
    var emptyPort = false
    if not bracketed and colon >= 0:
      let after = span[colon + 1 .. ^1]
      # `host:` with nothing after the colon is an empty port, not userinfo.
      # Digits that fill the rest are a port; anything else is a password
      # (`user:pa/ss`, `user:1pa/ss`, `user:pa?ss`).
      emptyPort = after.len == 0
      if not emptyPort:
        var allDigits = true
        for ch in after:
          if not isDigit(ch):
            allDigits = false
            break
        credential = not allDigits
    # An empty port with an '@' behind it is the shape that keeps printing a
    # query or a path value as the host. Nothing in `host:` is a credential, so
    # there is no terminator to find and nothing safe to print.
    if emptyPort and url.find('@', authStart) >= 0:
      return url[0 ..< authStart] & "<redacted>"
    let atInSpan = url.rfind('@', authStart, sep - 1)
    if credential:
      # The credential was split by `sep`, so its terminator is the last `@`
      # past it. It cannot be further than the next separator: an `@` beyond
      # that is query or fragment data, and taking it would print the query as
      # the new authority (`?x=a@b&api_key=S` once printed `https://b&api_key=S`).
      var nextSep = url.len
      for stop in ['/', '?', '#']:
        let hit = url.find(stop, sep + 1)
        if hit >= 0 and hit < nextSep:
          nextSep = hit
      var at = url.rfind('@', authStart, nextSep - 1)
      # A credential that already ended inside the authority cannot end again
      # past the separator when both sides are host-shaped: the value is
      # malformed and nothing after the cut is a proven host.
      if at >= sep and atInSpan >= 0:
        let between = url[atInSpan + 1 ..< sep]
        let colonAt = between.find(':')
        let betweenHost = if colonAt >= 0: between[0 ..< colonAt] else: between
        let after = if at + 1 < nextSep: url[at + 1 ..< nextSep] else: ""
        let afterColon = after.find(':')
        let afterHost = if afterColon >= 0: after[0 ..< afterColon] else: after
        if betweenHost.len > 0 and afterHost.len > 0 and
           (betweenHost[0] == '[' or betweenHost.toLowerAscii() == "localhost" or
            betweenHost.contains('.')) and
           (afterHost[0] == '[' or afterHost.toLowerAscii() == "localhost" or
            afterHost.contains('.')):
          return url[0 ..< authStart] & "<redacted>"
      # `=`/`&` before the `@` is query or form data, not the rest of a password.
      if at >= sep and (url[sep ..< at].contains('=') or url[sep ..< at].contains('&')):
        at = -1
      if at >= sep:
        # The `@` past the separator only ends a credential if the text before
        # the separator was userinfo. A dotted name in the port slot means the
        # text was a host with a broken port, so every `@` past it is data.
        let portText = if colon >= 0: span[colon + 1 .. ^1] else: ""
        let hostPart = if colon >= 0: span[0 ..< colon] else: span
        let portLooksLikeData = colon >= 0 and portText.len > 0 and
          not portText.allCharsInSet(Digits) and
          (hostPart.len == 0 or hostPart[0] == '[' or
           hostPart.toLowerAscii() == "localhost" or hostPart.contains('.'))
        if portLooksLikeData:
          return url[0 ..< authStart] & "<redacted>"
        url = url[0 ..< authStart] &
              (if at + 1 < url.len: url[at + 1 .. ^1] else: "")
      elif atInSpan < 0 and url.find('@', authStart) >= 0:
        # An `@` exists but nothing proves where the credential ends. Print no
        # host rather than guess one out of the middle of a password.
        return url[0 ..< authStart] & "<redacted>"

  var authEnd = url.len
  for stop in ['/', '?', '#']:
    let hit = url.find(stop, authStart)
    if hit >= 0 and hit < authEnd:
      authEnd = hit
  let at = url.rfind('@', authStart, authEnd - 1)
  if at >= 0:
    let tail = if at + 1 < url.len: url[at + 1 .. ^1] else: ""
    url = url[0 ..< authStart] & tail
  # Whatever survived has to be a host[:port] and nothing else. A '=', '&' or
  # '@' here means the split stopped inside data and the "host" is really a
  # query or a path fragment. Only checked when the value carried a credential
  # at all, so a plain base URL is never rewritten.
  if value.find('@', authStart) >= 0:
    var hostEnd = url.len
    for stop in ['/', '?', '#']:
      let hit = url.find(stop, authStart)
      if hit >= 0 and hit < hostEnd:
        hostEnd = hit
    let host = url[authStart ..< hostEnd]
    # A credential was stripped, so what took its place has to look like a host:
    # a dotted name, `localhost`, or a bracketed address. A bare token is data
    # far more often than a single-label host, and printing it is the leak this
    # proc exists to prevent. Checked only when a split actually rewrote the
    # value, so a URL whose `@` is ordinary path data is left alone.
    let hostLike = not (url != value) or
                   (host.len > 0 and
                    (host[0] == '[' or host.toLowerAscii() == "localhost" or
                     host.contains('.')))
    if host.len == 0 or not hostLike or host.contains('=') or host.contains('&') or host.contains('@'):
      return url[0 ..< authStart] & "<redacted>"
  let query = url.find('?')
  let fragment = url.find('#')
  if query < 0:
    if fragment >= 0:
      return url[0 ..< fragment]
    return url
  let tail = url[query + 1 .. ^1].toLowerAscii()
  if tail.contains("key") or tail.contains("token") or tail.contains("secret") or
     tail.contains("api"):
    return url[0 ..< query]
  if fragment >= 0 and fragment > query:
    return url[0 ..< fragment]
  url

proc credentialRefs*(configPath: string, legCount: int): seq[string] =
  ## `<path>:<line>` for each leg's api_key, never the value. If the file cannot
  ## be read back or the count does not line up, the path alone is the ref.
  var refs: seq[string]
  try:
    let text = readFile(configPath)
    var number = 0
    for line in text.splitLines():
      inc number
      if line.contains("\"api_key\""):
        refs.add(configPath & ":" & $number)
  except CatchableError:
    discard
  if refs.len != legCount:
    return newSeq[string](legCount)
  refs

# -------------------------------------------------------------------- state ---

proc ringStats(samples: seq[int]): (Option[int], Option[int]) =
  if samples.len == 0:
    return (none(int), none(int))
  var sorted = samples
  sorted.sort()
  var maximum = sorted[0]
  for value in sorted:
    if value > maximum:
      maximum = value
  (some(sorted[(sorted.len - 1) div 2]), some(maximum))

proc stateJson*(gateway: Gateway): string =
  ## The seven top-level keys of CONTRACT §4, in that order. `failover_events`
  ## sits before `recent` on purpose: the harness takes the first array whose
  ## members carry a timestamp, and `recent` would match too.
  let now = epochTime()
  var root = newJObject()
  root["generated_at"] = %nowStamp()

  var gatewayNode = newJObject()
  gatewayNode["version"] = %KoriVersion
  gatewayNode["started_at"] = %gateway.startedAt
  gatewayNode["listen"] = %gateway.listenAddr
  root["gateway"] = gatewayNode

  var routes = newJArray()
  for index, leg in gateway.cfg.legs:
    let runtime = gateway.legs[index]
    var route = newJObject()
    route["name"] = %leg.name
    route["role"] = %($leg.role)
    route["model"] = %leg.model
    route["state"] = %legStateName(runtime, now, leg.enabled)
    if runtime.coolingUntil > now:
      route["cooling_until"] = %stampAt(runtime.coolingUntil)
    else:
      route["cooling_until"] = newJNull()
    if runtime.lastFailureClass.len > 0:
      route["last_failure_class"] = %runtime.lastFailureClass
    else:
      route["last_failure_class"] = newJNull()
    if runtime.lastFailureAt.len > 0:
      route["last_failure_at"] = %runtime.lastFailureAt
    else:
      route["last_failure_at"] = newJNull()
    if runtime.lastSuccessAt.len > 0:
      route["last_success_at"] = %runtime.lastSuccessAt
    else:
      route["last_success_at"] = newJNull()
    route["served_in_window"] = %runtime.servedInWindow
    route["failed_in_window"] = %runtime.failedInWindow
    let (p50, maximum) = ringStats(runtime.latencies)
    route["latency_ms_p50"] = (if p50.isSome: %p50.get else: newJNull())
    route["latency_ms_max"] = (if maximum.isSome: %maximum.get else: newJNull())
    routes.add(route)
  root["routes"] = routes

  # DEC-19. The second door's legs are reported apart from `routes`, because they
  # are not part of the chat failover chain and a dashboard that merged the two
  # would draw a walk that does not exist.
  if gateway.cfg.systemone.len > 0:
    var soLegs = newJArray()
    for index, leg in gateway.cfg.systemone:
      let runtime = gateway.systemone[index]
      var node = newJObject()
      node["name"] = %leg.name
      node["model"] = %leg.model
      node["state"] = %(if not leg.enabled: "skipped"
                       elif runtime.coolingUntil > now: "cooling"
                       elif runtime.attempted: "ok"
                       else: "unknown")
      node["cooling_until"] = (if runtime.coolingUntil > now:
                                 %stampAt(runtime.coolingUntil) else: newJNull())
      node["last_failure_class"] = (if runtime.lastFailureClass.len > 0:
                                      %runtime.lastFailureClass else: newJNull())
      node["last_success_at"] = (if runtime.lastSuccessAt.len > 0:
                                   %runtime.lastSuccessAt else: newJNull())
      soLegs.add node
    root["systemone"] = soLegs

  var windowNode = newJObject()
  windowNode["from"] = %gateway.startedAt
  windowNode["to"] = %nowStamp()
  windowNode["requests"] = %gateway.requests
  windowNode["failover_availability"] = %gateway.failoverAvailability
  windowNode["failover_capacity"] = %gateway.failoverCapacity
  windowNode["tokens_in"] = %gateway.tokensInTotal
  windowNode["tokens_out"] = %gateway.tokensOutTotal
  # The same total /metrics prints, so a dashboard and a scraper cannot disagree.
  windowNode["cost_usd"] = %jsonFloat6(gateway.costUsdTotal)
  windowNode["cost_known_requests"] = %gateway.costUsdKnown
  root["window"] = windowNode

  var events = newJArray()
  for event in gateway.events:
    var node = newJObject()
    node["at"] = %event.at
    node["from_route"] = %event.fromRoute
    node["to_route"] = %event.toRoute
    node["reason"] = %event.reason
    events.add(node)
  root["failover_events"] = events

  # §5.1: `recent[]` is the same nine-key row as /admin/log, capped at the same
  # limit and read from the tail, so Overview gets its ten rows in one refresh.
  let recentPage = readLogTail(gateway.cfg.logPath, gateway.logLines, 0,
                               RecentLimit, LogFilter(stream: -1))
  var recent = newJArray()
  for row in recentPage.rows:
    recent.add(row)
  root["recent"] = recent
  root["limit"] = %RecentLimit

  $root

proc configJson*(gateway: Gateway): string =
  ## §5.3: the loaded config, read-only, every credential redacted by the binary
  ## before serialisation. Only header names are printed, never a value.
  var root = newJObject()
  root["generated_at"] = %nowStamp()
  root["listen"] = %gateway.listenAddr
  root["version"] = %KoriVersion
  root["started_at"] = %gateway.startedAt

  var configNode = newJObject()
  configNode["path"] = %gateway.configPath
  if gateway.configModifiedAt.len > 0:
    configNode["modified_at"] = %gateway.configModifiedAt
  else:
    configNode["modified_at"] = newJNull()
  root["config"] = configNode
  root["balance"] = %gateway.cfg.balance
  root["systemone_balance"] = %gateway.cfg.systemoneBalance

  var legs = newJArray()
  for index, leg in gateway.cfg.legs:
    var node = newJObject()
    node["order"] = %(index + 1)
    node["name"] = %leg.name
    node["role"] = %($leg.role)
    node["weight"] = %leg.weight
    node["base_url"] = %redactUrl(leg.baseUrl)
    node["model"] = %leg.model
    node["enabled"] = %leg.enabledFile
    node["serving"] = %leg.enabled
    if gateway.cfg.overridesLegs.hasKey(leg.name):
      node["override"] = %gateway.cfg.overridesLegs[leg.name]
    else:
      node["override"] = newJNull()
    node["retries"] = %leg.retries
    var aliases = newJObject()
    for alias, providerId in leg.aliases:
      aliases[alias] = %providerId
    node["aliases"] = aliases
    var headers = newJArray()
    for (headerName, _) in leg.headers:
      headers.add(%headerName)
    node["headers"] = headers
    # A pool is reported by size and the index in use, never by value: how many
    # keys a leg holds and which one is live is operational, a key is a secret.
    node["keys"] = %leg.apiKeys.len
    let liveKeys = gateway.legs[index].keyCooling
    var coolingKeys = 0
    for untilAt in liveKeys:
      if untilAt > epochTime():
        inc coolingKeys
    node["keys_cooling"] = %coolingKeys
    var credential = newJObject()
    let hasLiveToken = leg.hasOauth and gateway.oauth[index].accessToken.len > 0
    credential["name"] = %(if leg.hasOauth: leg.name & " OAuth token"
                           else: leg.name & " API key")
    credential["state"] = %(if hasLiveToken or (not leg.hasOauth and
                                                leg.apiKey.len > 0): "set"
                            else: "missing")
    credential["source"] = %"file"
    var credentialRef = gateway.configPath
    if not leg.hasOauth and index < gateway.credentialRefs.len and
       gateway.credentialRefs[index].len > 0:
      credentialRef = gateway.credentialRefs[index]
    credential["ref"] = %credentialRef
    node["credential"] = credential
    # §4: the state of the refresh, never the credential. An epoch expiry is not a
    # secret; a token is.
    if leg.hasOauth:
      var oauth = newJObject()
      oauth["state"] = %(if hasLiveToken: "set" else: "missing")
      if gateway.oauth[index].expiresAt > 0:
        oauth["expires_at"] = %int64(gateway.oauth[index].expiresAt)
      else:
        oauth["expires_at"] = newJNull()
      node["oauth"] = oauth
    legs.add(node)
  root["legs"] = legs

  var timeouts = newJObject()
  timeouts["connect_ms"] = %ConnectDeadlineMs
  timeouts["tls_ms"] = %TlsDeadlineMs
  timeouts["header_ms_stream"] = %gateway.cfg.headerStreamBaseMs
  # D-2: the streaming window is a rule, not a number. The two ends and the slope
  # are published so a reader can compute what a given body gets without the source.
  timeouts["header_ms_stream_slope_per_kib"] = %gateway.cfg.headerStreamPerKiBMs
  timeouts["header_ms_stream_max"] = %gateway.cfg.headerStreamMaxMs
  timeouts["header_ms_non_stream"] = %gateway.cfg.headerNonStreamMs
  timeouts["idle_ms"] = %ChunkIdleMs
  timeouts["total_ms"] = %TotalNonStreamMs
  root["timeouts"] = timeouts

  var cooldowns = newJObject()
  cooldowns["availability_s"] = %int(AvailabilityCooldownS)
  cooldowns["quota_s"] = %int(CapacityCooldownS)
  # DEC-23: the header-timeout ladder starts here and doubles per consecutive
  # timeout, so a reader can compute the second rung without the source.
  cooldowns["header_timeout_s"] = %int(HeaderTimeoutCooldownS)
  cooldowns["header_timeout_max_s"] = %int(AvailabilityCooldownS)
  # DEC-26: a one-leg gateway caps the header rung here, because there is no other
  # leg a longer skip could protect.
  cooldowns["single_leg_header_max_s"] = %int(SingleLegHeaderMaxMs div 1000)
  root["cooldowns"] = cooldowns

  var logNode = newJObject()
  logNode["path"] = %gateway.cfg.logPath
  logNode["append_only"] = %true
  logNode["redacted"] = %true
  # `append_only` stays true under rotation: every write is still one append to
  # the file it targets. Rotation renames a finished file, it never rewrites one.
  logNode["rotate_bytes"] = %int64(gateway.cfg.logRotateBytes)
  logNode["keep"] = %gateway.cfg.logKeep
  root["log"] = logNode

  var prices = newJObject()
  for model, price in gateway.cfg.prices:
    var entry = newJObject()
    entry["in"] = %jsonFloat6(price.usdIn)
    entry["out"] = %jsonFloat6(price.usdOut)
    prices[model] = entry
  root["prices"] = prices

  var reload = newJObject()
  reload["count"] = %gateway.reloads
  reload["at"] = (if gateway.lastReloadAt.len > 0: %gateway.lastReloadAt
                  else: newJNull())
  reload["error"] = (if gateway.lastReloadError.len > 0: %gateway.lastReloadError
                     else: newJNull())
  root["reload"] = reload

  # DEC-27. The switch block exactly as the binary holds it, so the dashboard can
  # say what is overridden without reading the file. Values only; no credential.
  var overridesNode = newJObject()
  var legOverrides = newJObject()
  for name, value in gateway.cfg.overridesLegs:
    legOverrides[name] = %value
  var modelOverrides = newJObject()
  for name, value in gateway.cfg.overridesModels:
    modelOverrides[name] = %value
  overridesNode["legs"] = legOverrides
  overridesNode["models"] = modelOverrides
  if gateway.cfg.overridesUpdatedAt.len > 0:
    overridesNode["updated_at"] = %gateway.cfg.overridesUpdatedAt
  else:
    overridesNode["updated_at"] = newJNull()
  root["overrides"] = overridesNode

  var writes = newJObject()
  writes["count"] = %gateway.adminWrites
  writes["last_at"] = (if gateway.lastAdminWriteAt.len > 0:
                         %gateway.lastAdminWriteAt else: newJNull())
  writes["last_action"] = (if gateway.lastAdminWriteAction.len > 0:
                             %gateway.lastAdminWriteAction else: newJNull())
  root["admin_writes"] = writes

  # DEC-19. Reported beside the chat legs, never inside them: a System One leg is
  # not part of that walk, and a dashboard that merged the two lists would draw a
  # failover chain that does not exist. The credential is reported the same way,
  # as state and a file reference, never a value.
  if gateway.cfg.systemone.len > 0:
    var soLegs = newJArray()
    for index, leg in gateway.cfg.systemone:
      var node = newJObject()
      node["order"] = %(index + 1)
      node["name"] = %leg.name
      node["base_url"] = %redactUrl(leg.baseUrl)
      node["model"] = %leg.model
      node["weight"] = %leg.weight
      node["enabled"] = %leg.enabled
      var headers = newJArray()
      for (headerName, _) in leg.headers:
        headers.add(%headerName)
      node["headers"] = headers
      var credential = newJObject()
      credential["name"] = %(leg.name & " API key")
      credential["state"] = %(if leg.apiKey.len > 0: "set" else: "missing")
      credential["source"] = %"file"
      credential["ref"] = %gateway.configPath
      node["credential"] = credential
      soLegs.add(node)
    root["systemone"] = soLegs

  $root

proc healthzJson*(): string =
  "{\"status\":\"ok\",\"version\":" & jsonEscape(KoriVersion) &
    ",\"revision\":" & jsonEscape(KoriRevision) & "}"

proc deepHealthJson*(gateway: Gateway): string =
  ## P1: `/healthz?deep` reports the state kori already keeps, per leg. Zero dials
  ## and zero tokens: an active probe would spend the owner's quota to answer a
  ## question the router already knows. Liveness stays `status: ok` here as well,
  ## because the process answering at all is the liveness fact.
  let now = epochTime()
  var root = newJObject()
  root["status"] = %"ok"
  root["version"] = %KoriVersion
  root["revision"] = %KoriRevision
  var legs = newJArray()
  for index, leg in gateway.cfg.legs:
    let runtime = gateway.legs[index]
    var node = newJObject()
    node["name"] = %leg.name
    node["role"] = %($leg.role)
    node["state"] = %legStateName(runtime, now, leg.enabled)
    node["cooling_until"] = (if runtime.coolingUntil > now: %stampAt(runtime.coolingUntil)
                             else: newJNull())
    node["last_success_at"] = (if runtime.lastSuccessAt.len > 0: %runtime.lastSuccessAt
                               else: newJNull())
    node["last_failure_at"] = (if runtime.lastFailureAt.len > 0: %runtime.lastFailureAt
                               else: newJNull())
    node["last_failure_class"] = (if runtime.lastFailureClass.len > 0:
                                    %runtime.lastFailureClass else: newJNull())
    node["served_in_window"] = %runtime.servedInWindow
    node["failed_in_window"] = %runtime.failedInWindow
    legs.add(node)
  root["legs"] = legs
  $root


proc modelsJson*(gateway: Gateway): string =
  ## P0 item 1: the model list an OpenAI client probes before it will talk to a
  ## gateway. Derived from the config, never from a provider: one entry per
  ## `kori/<alias>` and one per leg id that the config names or the leg is sent.
  ## Serving this list means a client can enumerate what this door accepts, which
  ## is the one thing every SDK needs and kori could not answer.
  var data = newJArray()
  var seen = initTable[string, bool]()
  var aliasNames: seq[string]

  # Aliases first, in leg order, and deduplicated: the same name on two legs is one
  # model to the caller, and the alias table resolves it per leg.
  for leg in gateway.cfg.legs:
    for alias in leg.aliases.keys:
      let name = AliasPrefix & alias
      if seen.hasKey(name):
        continue
      seen[name] = true
      aliasNames.add name
  for name in aliasNames:
    var node = newJObject()
    node["id"] = %name
    node["object"] = %"model"
    node["owned_by"] = %"kori"
    data.add node

  # Then the concrete ids. A leg's `model` is what that leg is sent; a leg without
  # one is sent the caller's string, so it contributes no id of its own.
  for leg in gateway.cfg.legs:
    if not leg.hasModel:
      continue
    if seen.hasKey(leg.model):
      continue
    seen[leg.model] = true
    var node = newJObject()
    node["id"] = %leg.model
    node["object"] = %"model"
    node["owned_by"] = %leg.name
    data.add node

  var root = newJObject()
  root["object"] = %"list"
  root["data"] = data
  $root

# ------------------------------------------------------------------ handlers ---

proc respondJson(request: Request, status: HttpCode,
                 body: string): Future[void] {.async.} =
  ## Every JSON answer goes through here, so the two headers a JSON read surface
  ## needs are set once: `no-store` keeps a proxy or a browser from caching a
  ## gated read, and `nosniff` keeps a sniffing browser from reinterpreting the
  ## body. A HEAD gets the same headers and the length a GET would answer, and no
  ## body: RFC 9110 §9.3.2.
  var headers = newHttpHeaders()
  headers["Content-Type"] = "application/json"
  headers["Cache-Control"] = "no-store"
  headers["X-Content-Type-Options"] = "nosniff"
  # Declared here, not by `respond`: it would otherwise measure the empty HEAD
  # payload and answer `Content-Length: 0`, which is not the length a GET answers.
  headers["Content-Length"] = $body.len
  let payload = if request.reqMethod == HttpHead: "" else: body
  await request.respond(status, payload, headers)

proc respondMethodNotAllowed(request: Request, allow = "GET"): Future[void] {.async.} =
  ## D11 point 4: the refusal names the methods the surface answers. A HEAD gets
  ## no body (RFC 9110 §9.3.2), which is why every refusal is built here rather
  ## than in five copies that each forgot it.
  var headers = newHttpHeaders()
  headers["Content-Type"] = "application/json"
  headers["Cache-Control"] = "no-store"
  headers["X-Content-Type-Options"] = "nosniff"
  headers["Allow"] = allow
  let full = "{\"error\":{\"type\":\"method_not_allowed\",\"message\":" & $ %allow & "}}"
  headers["Content-Length"] = $full.len
  let body = if request.reqMethod == HttpHead: "" else: full
  await request.respond(Http405, body, headers)

proc handleAdminLog(gateway: Gateway,
                    request: Request): Future[void] {.async.} =
  ## §5.2. A malformed value is a 400 with the parameter's name and no file read.
  let params = parseQuery(request.url.query)
  var offset = 0
  var limit = 50
  var filter = LogFilter(stream: -1)

  let limitValue = queryValue(params, "limit")
  if limitValue.isSome:
    var parsed = -1
    try:
      parsed = parseInt(limitValue.get)
    except CatchableError:
      parsed = -1
    if parsed < 1 or parsed > 200:
      await respondJson(request, Http400, badRequestBody("limit"))
      return
    limit = parsed

  let offsetValue = queryValue(params, "offset")
  if offsetValue.isSome:
    var parsed = -1
    try:
      parsed = parseInt(offsetValue.get)
    except CatchableError:
      parsed = -1
    if parsed < 0:
      await respondJson(request, Http400, badRequestBody("offset"))
      return
    offset = parsed

  let routeValue = queryValue(params, "route")
  if routeValue.isSome:
    filter.hasRoute = true
    filter.route = routeValue.get

  let aliasValue = queryValue(params, "alias")
  if aliasValue.isSome:
    filter.hasAlias = true
    filter.alias = aliasValue.get

  let classValue = queryValue(params, "status_class")
  if classValue.isSome:
    case classValue.get
    of "2xx": filter.statusClass = 2
    of "4xx": filter.statusClass = 4
    of "5xx": filter.statusClass = 5
    else:
      await respondJson(request, Http400, badRequestBody("status_class"))
      return

  let reasonValue = queryValue(params, "reason")
  if reasonValue.isSome:
    filter.hasReason = true
    filter.reason = if reasonValue.get == "none": "" else: reasonValue.get

  let streamValue = queryValue(params, "stream")
  if streamValue.isSome:
    case streamValue.get
    of "true": filter.stream = 1
    of "false": filter.stream = 0
    else:
      await respondJson(request, Http400, badRequestBody("stream"))
      return

  let sinceValue = queryValue(params, "since")
  if sinceValue.isSome:
    let moment = parseRfc3339(sinceValue.get)
    if moment.isNone:
      await respondJson(request, Http400, badRequestBody("since"))
      return
    filter.hasSince = true
    filter.sinceEpoch = moment.get

  let page = readLogTail(gateway.cfg.logPath, gateway.logLines, offset, limit,
                         filter)

  var root = newJObject()
  root["generated_at"] = %nowStamp()
  root["source"] = %(if page.reachedBeginning: "whole" else: "tail")
  var fileNode = newJObject()
  fileNode["path"] = %gateway.cfg.logPath
  fileNode["bytes"] = %page.bytes
  fileNode["lines"] = %page.lines
  fileNode["exists"] = %page.exists
  root["file"] = fileNode
  root["offset"] = %offset
  root["limit"] = %limit
  var rows = newJArray()
  for row in page.rows:
    rows.add(row)
  root["rows"] = rows
  var scan = newJObject()
  scan["lines_scanned"] = %page.linesScanned
  scan["budget"] = %LogScanBudget
  scan["budget_exhausted"] = %page.budgetExhausted
  if page.oldestReadAt.len > 0:
    scan["oldest_read_at"] = %page.oldestReadAt
  else:
    scan["oldest_read_at"] = newJNull()
  root["scan"] = scan
  root["more_older"] = %page.moreOlder

  await respondJson(request, Http200, $root)

proc cacheControlFor*(path: string): string =
  if path.startsWith("/assets/"):
    StaticAssetCache
  elif path.startsWith("/fonts/"):
    StaticFontCache
  else:
    StaticNoStore

proc resolveStaticPath*(requestPath: string): string =
  ## "/" is the only alias, and it is a fixed one. Every other path is handed to
  ## the table unchanged: no prefix rule and no index fallback, so a missing file
  ## stays missing instead of quietly serving index.html with a 200.
  if requestPath.len == 0 or requestPath == "/": "/index.html"
  else: requestPath

proc notFoundBody(): string =
  "{\"error\":{\"type\":\"not_found\",\"message\":\"no such path\"}}"

# -------------------------------------------------------------- admin gate ---
#
# DEC-20. One shared token, one cookie, no identity. The gate is deliberately the
# smallest thing that can hold: a file read, a constant-time compare, and a table
# in memory. Every gated answer is a fixed body, so nothing the caller sent is
# ever echoed back and there is no path from a `Cookie` header into a log line.

proc adminTokenPath*(): string =
  ## Resolved per request so the environment is the only place the path is set:
  ## never a config key (it would show up in /admin/config) and never an argument
  ## (it would show up in `ps`).
  let fromEnv = getEnv(AdminTokenEnv)
  if fromEnv.len > 0: fromEnv else: DefaultAdminTokenFile

proc readAdminToken*(): Option[string] =
  ## Read on every request, so replacing the file rotates the token without a
  ## restart. A file that is missing, unreadable or only whitespace is one answer:
  ## no token. The caller turns that into a 404, never into an open gate.
  let path = adminTokenPath()
  var raw: string
  try:
    if not fileExists(path):
      return none(string)
    raw = readFile(path)
  except CatchableError:
    return none(string)
  let token = raw.strip()
  if token.len == 0:
    return none(string)
  some(token)

proc constantTimeEquals*(actual, supplied: string): bool =
  ## No early return and no short-circuit on length: the loop always runs to the
  ## longer of the two, and a length difference is folded into the same result
  ## instead of deciding it. What an attacker learns from timing is the length of
  ## their own input, which they already know.
  var diff = if actual.len == supplied.len: 0'u8 else: 1'u8
  let spans = max(actual.len, supplied.len)
  for index in 0 ..< spans:
    let a = if index < actual.len: uint8(actual[index]) else: 0'u8
    let b = if index < supplied.len: uint8(supplied[index]) else: 0'u8
    diff = diff or (a xor b)
  diff == 0

proc bearerValue*(request: Request): string =
  ## The `Bearer` scheme only, case-insensitive, and the whole remaining value is
  ## the credential: a token with a space in it stays intact.
  let values = request.headers.getOrDefault("Authorization")
  for value in seq[string](values):
    let trimmed = value.strip()
    if trimmed.len > 7 and trimmed[0 ..< 7].toLowerAscii() == "bearer ":
      return trimmed[7 .. ^1].strip()

proc sessionCookieValue*(request: Request): string =
  ## The first `kori_admin` the request carries. A malformed pair is skipped, not
  ## rejected: the gate only ever needs one usable credential.
  let values = request.headers.getOrDefault("Cookie")
  for value in seq[string](values):
    for part in value.split(';'):
      let pair = part.strip()
      let eq = pair.find('=')
      if eq > 0 and pair[0 ..< eq].strip() == AdminCookieName:
        return pair[eq + 1 .. ^1].strip()

proc adminDeniedBody*(): string =
  ## Fixed, with no parameter: nothing the caller sent can reach it.
  "{\"error\":{\"type\":\"unauthorized\",\"message\":\"admin token required\"}}"

const TooManyLoginsBody* =
  "{\"error\":{\"type\":\"too_many_requests\",\"message\":\"too many failed logins\"}}"

proc acceptsHtml*(request: Request): bool =
  ## Explicit only. `curl` sends `*/*` by default, and a wildcard is not a request
  ## for a page: a script gets the 401 that says why, a browser gets the form.
  let values = request.headers.getOrDefault("Accept")
  for value in seq[string](values):
    for part in value.split(','):
      let media = part.split(';')[0].strip().toLowerAscii()
      if media == "text/html" or media == "application/xhtml+xml":
        return true
  false

const
  ## The five dashboard pages. `/login.html` is open, because a gated page that
  ## answered 401 would have no way to offer the form.
  GatedPages* = ["/", "/index.html", "/requests.html", "/routes.html", "/config.html"]

proc isGatedPage*(path: string): bool =
  path in GatedPages

type
  AdminGate* = enum
    agOk,        ## a credential was presented and it is the one in the file
    agNoToken,   ## no token configured: the gated surface answers 404
    agDenied     ## a token exists and this request does not have it

  AdminWriteGate* = enum
    awOk,        ## the write token, as a bearer or as a write session
    awNoToken,   ## no write token file: the surface answers 404
    awDenied,    ## no credential that authenticates anything
    awForbidden, ## authenticated with the read credential: wrong scope
    awCsrf       ## a write session without the X-Kori-Write header

proc pruneSessions*(gateway: Gateway, now: float) =
  var expired: seq[string]
  for id, session in gateway.sessions:
    if session.expiresAt <= now:
      expired.add id
  for id in expired:
    gateway.sessions.del id

proc pruneLoginFailures*(gateway: Gateway, now: float) =
  var kept: seq[float]
  for at in gateway.loginFailures:
    if now - at < AdminLoginWindowS:
      kept.add at
  gateway.loginFailures = kept

proc readAdminWriteToken*(): Option[string] =
  ## DEC-27. The same file contract as the read token, in its own path. A host
  ## without this file has no write surface at all: the caller gets the 404 the
  ## read gate answers without a token.
  let fromEnv = getEnv(AdminWriteTokenEnv)
  let path = if fromEnv.len > 0: fromEnv else: DefaultAdminWriteTokenFile
  var raw: string
  try:
    if not fileExists(path):
      return none(string)
    raw = readFile(path)
  except CatchableError:
    return none(string)
  let token = raw.strip()
  if token.len == 0:
    return none(string)
  some(token)

proc headerIs*(request: Request, name, want: string): bool =
  ## Exact, case-insensitive header *name* (the table already is), exact value.
  ## Used for the one non-simple header a cookie write must carry (DEC-27).
  for value in seq[string](request.headers.getOrDefault(name)):
    if value.strip() == want:
      return true
  false

proc adminWriteGate*(gateway: Gateway, request: Request): AdminWriteGate =
  ## DEC-27. The same constant-time compare as the read gate, then three facts the
  ## read gate does not need: the session's scope, the token that minted it, and
  ## the header a cross-site form cannot set.
  let token = readAdminWriteToken()
  if token.isNone:
    return awNoToken
  let now = epochTime()
  pruneSessions(gateway, now)
  let cookie = sessionCookieValue(request)
  if cookie.len > 0 and gateway.sessions.hasKey(cookie):
    let session = gateway.sessions[cookie]
    if session.expiresAt > now and session.scope == asWrite and
       session.tokenHash == hash(token.get):
      if headerIs(request, "X-Kori-Write", "1"):
        return awOk
      return awCsrf
  let bearer = bearerValue(request)
  if bearer.len > 0 and constantTimeEquals(token.get, bearer):
    return awOk
  # A credential that is valid for reads is authenticated but not allowed here.
  let readToken = readAdminToken()
  if readToken.isSome and bearer.len > 0 and
     constantTimeEquals(readToken.get, bearer):
    return awForbidden
  if cookie.len > 0 and gateway.sessions.hasKey(cookie) and
     gateway.sessions[cookie].expiresAt > now:
    return awForbidden
  awDenied

proc adminGate*(gateway: Gateway, request: Request): AdminGate =
  ## Session first: it is a table lookup, and a browser sends the cookie on every
  ## request while a script sends the bearer. Either one is enough.
  let token = readAdminToken()
  if token.isNone:
    return agNoToken
  let now = epochTime()
  pruneSessions(gateway, now)
  let cookie = sessionCookieValue(request)
  if cookie.len > 0 and gateway.sessions.hasKey(cookie):
    let session = gateway.sessions[cookie]
    if session.expiresAt > now:
      return agOk
  let bearer = bearerValue(request)
  if bearer.len > 0 and constantTimeEquals(token.get, bearer):
    return agOk
  # DEC-27, amended: the write token is a superset of the read one. It can already
  # mint a write session, and a write session reads every GET; refusing the same
  # credential as a bearer only forced a script to trade it for a cookie first.
  let writeToken = readAdminWriteToken()
  if bearer.len > 0 and writeToken.isSome and
     constantTimeEquals(writeToken.get, bearer):
    return agOk
  agDenied

proc startSession*(gateway: Gateway, scope = asRead,
                   tokenHash: Hash = Hash(0)): Option[string] =
  ## A session id that is guessable is not a gate, so no CSPRNG means no session
  ## and the caller is told the surface is unavailable rather than let in.
  ## DEC-27: the scope and the fingerprint of the token that minted it are stored
  ## beside the expiry, so a write session cannot outlive a rotated write token.
  var bytes: array[AdminSessionBytes, byte]
  if not urandom(bytes):
    return none(string)
  var id = encode(bytes, safe = true)
  # Unpadded: `=` is legal in a cookie value but needs quoting, and 32 bytes
  # encode to 43 characters without it.
  while id.len > 0 and id[^1] == '=':
    id.setLen(id.len - 1)
  let now = epochTime()
  pruneSessions(gateway, now)
  if gateway.sessions.len >= MaxAdminSessions:
    # The cap is a bound on memory, not a queue: the entry closest to expiring
    # goes, which is the one a caller is least likely to still be using.
    var oldestId = ""
    var oldestAt = 0.0
    for existing, session in gateway.sessions:
      if oldestId.len == 0 or session.expiresAt < oldestAt:
        oldestId = existing
        oldestAt = session.expiresAt
    gateway.sessions.del oldestId
  let ttl = if scope == asWrite: AdminWriteSessionTtlS else: AdminSessionTtlS
  gateway.sessions[id] = AdminSession(expiresAt: now + ttl, scope: scope,
                                      tokenHash: tokenHash)
  some(id)

proc sessionCookie*(value: string, maxAge: int): string =
  AdminCookieName & "=" & value &
    "; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=" & $maxAge

proc respondGateDenied*(request: Request, page: bool): Future[void] {.async.} =
  ## A page the browser asked for redirects to the form; everything else gets the
  ## 401 that names the problem. `no-store` keeps a browser from caching either.
  var headers = newHttpHeaders()
  headers["Cache-Control"] = "no-store"
  if page and acceptsHtml(request):
    headers["Location"] = "/login.html"
    await request.respond(Http302, "", headers)
    return
  headers["Content-Type"] = "application/json"
  let full = adminDeniedBody()
  headers["Content-Length"] = $full.len
  let body = if request.reqMethod == HttpHead: "" else: full
  await request.respond(Http401, body, headers)

proc respondGateMissing*(request: Request): Future[void] {.async.} =
  ## Contract 2: a gateway with no token proves nothing about having one, so the
  ## gated surface does not exist to a caller who cannot be authenticated. Never
  ## 401 and never 500: the answer is the same 404 an unknown path gets.
  await respondJson(request, Http404, notFoundBody())

# ------------------------------------------------------------ config write ---
# DEC-27. The only mutation the admin surface accepts: two switch maps, patched
# into the config file by text, validated by the same loader the process boots
# with, and applied in memory without moving the leg list.

const MaxOverridesBodyBytes* = 16_384

type
  JsonSpan = object
    found: bool
    valueStart: int
    valueEnd: int

proc jsonValueEnd(raw: string, start: int): int =
  ## The last byte of the JSON value beginning at `start`, or -1. String-aware, so
  ## a brace inside a token or a URL cannot end an object early.
  if start < 0 or start >= raw.len:
    return -1
  case raw[start]
  of '{', '[':
    var depth = 0
    var inString = false
    var escaped = false
    var i = start
    while i < raw.len:
      let ch = raw[i]
      if inString:
        if escaped: escaped = false
        elif ch == '\\': escaped = true
        elif ch == '"': inString = false
      else:
        case ch
        of '"': inString = true
        of '{', '[': inc depth
        of '}', ']':
          dec depth
          if depth == 0:
            return i
        else: discard
      inc i
    -1
  of '"':
    stringLiteralEnd(raw, start)
  else:
    var i = start
    while i < raw.len and raw[i] notin {',', '}', ']', ' ', '\t', '\r', '\n'}:
      inc i
    i - 1

proc overridesSpan(raw: string): JsonSpan =
  ## The top-level `"overrides"` value. Only a key at depth 1 can match, so an
  ## `overrides` string inside a leg or a header value is never touched.
  var depth = 0
  var inString = false
  var escaped = false
  var i = 0
  while i < raw.len:
    let ch = raw[i]
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      inc i
      continue
    case ch
    of '"':
      let endQuote = stringLiteralEnd(raw, i)
      if endQuote < 0:
        return
      var j = endQuote + 1
      while j < raw.len and raw[j] in {' ', '\t', '\r', '\n'}:
        inc j
      if depth == 1 and j < raw.len and raw[j] == ':' and
         raw[i + 1 ..< endQuote] == "overrides":
        inc j
        while j < raw.len and raw[j] in {' ', '\t', '\r', '\n'}:
          inc j
        if j >= raw.len:
          return
        let endValue = jsonValueEnd(raw, j)
        if endValue >= j:
          return JsonSpan(found: true, valueStart: j, valueEnd: endValue)
      i = endQuote + 1
    of '{':
      inc depth
      inc i
    of '}':
      dec depth
      inc i
    else:
      inc i

proc overrideMapText(pairs: seq[(string, bool)]): string =
  ## Sorted by name so two writes of the same state produce the same bytes.
  var parts: seq[string]
  for pair in pairs:
    parts.add jsonEscape(pair[0]) & ":" & (if pair[1]: "true" else: "false")
  parts.sort()
  "{" & parts.join(",") & "}"

proc patchOverridesText*(raw, valueText: string): string =
  let span = overridesSpan(raw)
  if span.found:
    return raw[0 ..< span.valueStart] & valueText & raw[span.valueEnd + 1 .. ^1]
  let close = raw.rfind('}')
  if close < 0:
    return ""
  let head = raw[0 ..< close]
  let needsComma = head.strip().len > 1
  head & (if needsComma: "," else: "") & "\n  \"overrides\": " & valueText &
    "\n" & raw[close .. ^1]

proc writeScopeBody*(): string =
  "{\"error\":{\"type\":\"write_scope_required\",\"message\":\"a write token is required for this endpoint\"}}"

proc csrfHeaderBody*(): string =
  "{\"error\":{\"type\":\"csrf_header_required\",\"message\":\"X-Kori-Write: 1 is required for a cookie write\"}}"

proc lastLegBody*(): string =
  "{\"error\":{\"type\":\"last_leg\",\"message\":\"this would switch off the last serving provider; send confirm_last_leg to do it anyway\"}}"

proc adminBadBody*(message: string): string =
  "{\"error\":{\"type\":\"bad_request\",\"message\":" & jsonEscape(message) & "}}"

proc handleAdminOverrides(gateway: Gateway,
                          request: Request): Future[void] {.async.} =
  case gateway.adminWriteGate(request)
  of awNoToken: await respondGateMissing(request); return
  of awDenied: await respondGateDenied(request, page = false); return
  of awForbidden: await respondJson(request, Http403, writeScopeBody()); return
  of awCsrf: await respondJson(request, Http403, csrfHeaderBody()); return
  of awOk: discard

  if request.body.len > MaxOverridesBodyBytes:
    await respondJson(request, Http413,
      "{\"error\":{\"type\":\"body_too_large\",\"message\":\"overrides body is larger than 16 KiB\"}}")
    return
  var node: JsonNode
  try:
    node = parseJson(request.body)
  except CatchableError:
    await respondJson(request, Http400, adminBadBody("body is not valid JSON"))
    return
  if node.kind != JObject:
    await respondJson(request, Http400, adminBadBody("body must be a JSON object"))
    return

  var confirmLast = false
  var legs = initTable[string, bool]()
  var models = initTable[string, bool]()
  for key, value in node:
    case key
    of "confirm_last_leg":
      if value.kind != JBool:
        await respondJson(request, Http400,
          adminBadBody("confirm_last_leg must be true or false"))
        return
      confirmLast = value.getBool()
    of "legs":
      if value.kind != JObject:
        await respondJson(request, Http400, adminBadBody("legs must be an object"))
        return
      for name, flag in value:
        if flag.kind != JBool:
          await respondJson(request, Http400,
            adminBadBody("legs." & name & " must be true or false"))
          return
        legs[name] = flag.getBool()
    of "models":
      if value.kind != JObject:
        await respondJson(request, Http400, adminBadBody("models must be an object"))
        return
      for name, flag in value:
        if flag.kind != JBool:
          await respondJson(request, Http400,
            adminBadBody("models." & name & " must be true or false"))
          return
        models[name] = flag.getBool()
    else:
      await respondJson(request, Http400,
        adminBadBody("overrides." & key & " is not a known key"))
      return

  # Only names the config knows. A typo is refused here rather than written into a
  # file the next reload would refuse whole.
  for name in legs.keys:
    var known = false
    for leg in gateway.cfg.legs:
      if leg.name == name:
        known = true
        break
    if not known:
      await respondJson(request, Http400,
        adminBadBody("legs." & name & " names no leg"))
      return
  for name in models.keys:
    var known = false
    for leg in gateway.cfg.legs:
      if leg.aliases.hasKey(name):
        known = true
        break
    if not known:
      await respondJson(request, Http400,
        adminBadBody("models." & name & " names no model alias"))
      return

  # The last-leg guard: the file's own `enabled` is the baseline, not the value an
  # earlier override wrote.
  var serving = 0
  for leg in gateway.cfg.legs:
    let effective =
      if legs.hasKey(leg.name): legs[leg.name] else: leg.enabledFile
    if effective:
      inc serving
  if serving == 0 and not confirmLast:
    await respondJson(request, Http409, lastLegBody())
    return

  if gateway.configPath.len == 0:
    await respondJson(request, Http500,
      adminBadBody("this process has no config path to write"))
    return
  var raw: string
  try:
    raw = readFile(gateway.configPath)
  except CatchableError:
    await respondJson(request, Http500,
      adminBadBody("cannot read the config file back"))
    return
  let originalSize = raw.len
  var originalMtime = fromUnix(0)
  try:
    originalMtime = getLastModificationTime(gateway.configPath)
  except CatchableError:
    discard

  let stamp = nowStamp()
  var legPairs: seq[(string, bool)]
  for name, flag in legs:
    legPairs.add (name, flag)
  var modelPairs: seq[(string, bool)]
  for name, flag in models:
    modelPairs.add (name, flag)
  let valueText = "{\"legs\":" & overrideMapText(legPairs) &
    ",\"models\":" & overrideMapText(modelPairs) &
    ",\"updated_at\":" & jsonEscape(stamp) & "}"
  let patched = patchOverridesText(raw, valueText)
  if patched.len == 0:
    await respondJson(request, Http500,
      adminBadBody("the config file has no closing object to patch"))
    return
  try:
    discard loadConfigText(patched, gateway.configPath)
  except ConfigError:
    await respondJson(request, Http500,
      adminBadBody("the patched config did not validate; nothing was written"))
    return
  # An external hand edit or an OAuth refresh between the read and the write is a
  # conflict, not a file to clobber.
  var currentMtime = fromUnix(0)
  try:
    currentMtime = getLastModificationTime(gateway.configPath)
  except CatchableError:
    discard
  var sizeChanged = true
  try:
    sizeChanged = getFileSize(gateway.configPath) != originalSize.int64
  except CatchableError:
    discard
  if currentMtime != originalMtime or sizeChanged:
    await respondJson(request, Http409,
      "{\"error\":{\"type\":\"config_changed\",\"message\":\"the config changed while the write was prepared; retry\"}}")
    return

  # One generation of backup beside the original, same 0600 mode, then the same
  # temp-and-rename the OAuth write-back already uses.
  if not writeFileAtomic(gateway.configPath & ".bak", raw):
    await respondJson(request, Http500,
      adminBadBody("cannot write the config backup"))
    return
  if not writeFileAtomic(gateway.configPath, patched):
    await respondJson(request, Http500,
      adminBadBody("cannot write the config file"))
    return

  # Apply now without touching the leg list: `enabled` is a field future requests
  # read, and nothing holds an index across this block. The reload is requested as
  # well, so the in-memory config and the file converge at the next quiet moment.
  gateway.cfg.overridesLegs = legs
  gateway.cfg.overridesModels = models
  gateway.cfg.overridesUpdatedAt = stamp
  for index in 0 ..< gateway.cfg.legs.len:
    let name = gateway.cfg.legs[index].name
    gateway.cfg.legs[index].enabled =
      if legs.hasKey(name): legs[name] else: gateway.cfg.legs[index].enabledFile
  inc gateway.adminWrites
  gateway.lastAdminWriteAt = stamp
  gateway.lastAdminWriteAction = "overrides"
  reloadRequested = true
  stderr.writeLine("kori: admin overrides written, " & $legs.len &
                   " leg(s), " & $models.len & " model(s)")

  var root = newJObject()
  root["written"] = %true
  root["applied"] = %true
  root["reload_requested"] = %true
  root["updated_at"] = %stamp
  var legNode = newJObject()
  for name, flag in legs:
    legNode[name] = %flag
  var modelNode = newJObject()
  for name, flag in models:
    modelNode[name] = %flag
  var overrides = newJObject()
  overrides["legs"] = legNode
  overrides["models"] = modelNode
  root["overrides"] = overrides
  await respondJson(request, Http200, $root)


proc handleSessionLogin(gateway: Gateway,
                        request: Request): Future[void] {.async.} =
  ## DEC-20 §6 and §8, as narrowed by DEC-21: the window throttles a *failed*
  ## attempt, never the credential. A caller over the limit gets 429 without the
  ## token being compared, but only after its own attempt would have failed; a
  ## correct token always gets its session. The window is global because behind
  ## Caddy every request arrives from one address, and it used to be checked
  ## before the comparison, which let anyone lock the owner out of the dashboard
  ## with five wrong tokens every five minutes (SEC-3).
  if request.reqMethod != HttpPost:
    await respondMethodNotAllowed(request, allow = "POST")
    return
  let token = readAdminToken()
  let writeToken = readAdminWriteToken()
  if token.isNone and writeToken.isNone:
    await respondGateMissing(request)
    return
  let now = epochTime()
  pruneLoginFailures(gateway, now)
  var supplied = ""
  if request.body.len <= MaxLoginBodyBytes:
    try:
      let node = parseJson(request.body)
      if node.kind == JObject and node.hasKey("token") and
         node["token"].kind == JString:
        supplied = node["token"].getStr()
    except CatchableError:
      # A body that is not this shape is a failed login, not a 400: the gate has
      # one answer for "no valid token" and this is one of the ways to have none.
      discard
  # DEC-27: the write token logs in with write scope; the read token keeps the
  # thirty-day session it always had. When an operator sets both files to the same
  # value, the write scope wins, because that is the credential they configured for
  # writing and the shorter session is the safe reading of an ambiguous setup.
  var scope = asRead
  var matchedToken = ""
  if supplied.len > 0 and writeToken.isSome and
     constantTimeEquals(writeToken.get, supplied):
    scope = asWrite
    matchedToken = writeToken.get
  elif supplied.len > 0 and token.isSome and
       constantTimeEquals(token.get, supplied):
    scope = asRead
    matchedToken = token.get
  if matchedToken.len > 0:
    let sessionId = startSession(gateway, scope, hash(matchedToken))
    if sessionId.isNone:
      await respondJson(request, Http500,
        "{\"error\":{\"type\":\"session_unavailable\",\"message\":\"no session could be created\"}}")
      return
    var headers = newHttpHeaders()
    let ttl = if scope == asWrite: AdminWriteSessionTtlS else: AdminSessionTtlS
    headers["Set-Cookie"] = sessionCookie(sessionId.get, int(ttl))
    headers["Cache-Control"] = "no-store"
    await request.respond(Http204, "", headers)
    return
  # A failed attempt: over the limit it is a 429 and the list is not appended to
  # (that is what keeps the window a window), under it the failure is recorded.
  if gateway.loginFailures.len >= MaxAdminLoginFailures:
    await respondJson(request, Http429, TooManyLoginsBody)
    return
  gateway.loginFailures.add now
  await respondJson(request, Http401, adminDeniedBody())

proc handleSessionLogout(gateway: Gateway,
                         request: Request): Future[void] {.async.} =
  ## Idempotent on purpose: an unknown or absent cookie still drops nothing and
  ## still clears the browser's copy, so a stale tab logs out in one click.
  if request.reqMethod != HttpPost:
    await respondMethodNotAllowed(request, allow = "POST")
    return
  let id = sessionCookieValue(request)
  if id.len > 0 and gateway.sessions.hasKey(id):
    gateway.sessions.del id
  var headers = newHttpHeaders()
  headers["Set-Cookie"] = sessionCookie("", 0)
  headers["Cache-Control"] = "no-store"
  await request.respond(Http204, "", headers)


proc handleStatic(gateway: Gateway,
                  request: Request): Future[void] {.async.} =
  ## The four pages, /assets/* and /fonts/*, from the compiled table only.
  ##
  ## Exact path match: "/" is index.html and every other request is a lookup, so
  ## there is no prefix rule, no index fallback and no way for a path outside the
  ## table to reach a file. Nothing here touches the filesystem, so a traversal
  ## attempt is just a key that is not present.
  if request.reqMethod notin {HttpGet, HttpHead}:
    await respondMethodNotAllowed(request, allow = "GET, HEAD")
    return

  let path = resolveStaticPath(request.url.path)
  if not gateway.staticFiles.hasKey(path):
    await respondJson(request, Http404, notFoundBody())
    return

  # DEC-20 §3. The five pages carry the numbers, so they sit behind the gate.
  # `/login.html` and `/assets/*`, `/fonts/*` stay open: the form has to be
  # reachable without a credential, and a stylesheet carries no state.
  if isGatedPage(path):
    case gateway.adminGate(request)
    of agNoToken: await respondGateMissing(request)
    of agDenied: await respondGateDenied(request, page = true)
    of agOk: discard

  let entry = gateway.staticFiles[path]
  var headers = @[("Content-Type", entry.contentType),
                  ("Content-Length", $entry.body.len),
                  ("Cache-Control", cacheControlFor(path)),
                  ("X-Content-Type-Options", "nosniff")]
  # A HEAD gets the same headers and no body; the length is the body's.
  let payload = if request.reqMethod == HttpHead: "" else: entry.body
  await request.client.send(buildHead(200, headers) & payload)

proc routeRequest(gateway: Gateway, request: Request): Future[void] {.async.} =
  let path = request.url.path
  if path == "/healthz":
    if request.reqMethod notin {HttpGet, HttpHead}:
      await respondMethodNotAllowed(request, allow = "GET, HEAD")
    else:
      # P1: `?deep` is one variant of the health path, not a second path, and it
      # answers from router state without dialling a leg. Presence is what asks
      # for it: `?deep`, `?deep=1` and `?deep=true` are the same request, and only
      # an explicit false keeps the shallow body.
      let deep = queryValue(parseQuery(request.url.query), "deep")
      if deep.isSome and deep.get.toLowerAscii() notin ["0", "false", "no"]:
        # DEC-20 §4: the shallow body is the deploy gate and stays open, because a
        # rollback probe must not need a secret. `?deep` names legs, states and
        # cooldowns, so it is the data surface and it is gated like /admin/state.
        case gateway.adminGate(request)
        of agNoToken: await respondGateMissing(request)
        of agDenied: await respondGateDenied(request, page = false)
        of agOk: await respondJson(request, Http200, gateway.deepHealthJson())
      else:
        await respondJson(request, Http200, healthzJson())
  elif path == "/v1/models":
    # P0: the model list. GET and HEAD, like every other read-only surface.
    if request.reqMethod notin {HttpGet, HttpHead}:
      await respondMethodNotAllowed(request, allow = "GET, HEAD")
    else:
      await respondJson(request, Http200, gateway.modelsJson())
  elif path == "/session/login":
    await gateway.handleSessionLogin(request)
  elif path == "/session/logout":
    await gateway.handleSessionLogout(request)
  elif path == "/metrics":
    # Prometheus scrapes a GET and nothing else. Text format, `prometheus` type
    # version 0.0.4, which every scraper in use reads.
    if request.reqMethod notin {HttpGet, HttpHead}:
      await respondMethodNotAllowed(request, allow = "GET, HEAD")
    else:
      case gateway.adminGate(request)
      of agNoToken: await respondGateMissing(request)
      of agDenied: await respondGateDenied(request, page = false)
      of agOk:
        let body = gateway.metricsText()
        let headers = @[("Content-Type", "text/plain; version=0.0.4; charset=utf-8"),
                        ("Cache-Control", "no-store"),
                        ("X-Content-Type-Options", "nosniff"),
                        ("Content-Length", $body.len)]
        # A HEAD gets the same headers and no body, like every other read surface.
        let payload = if request.reqMethod == HttpHead: "" else: body
        await request.client.send(buildHead(200, headers) & payload)
  elif path == "/admin/overrides":
    # DEC-27. The one write on the admin surface. Its own gate, its own method,
    # and a 405 that names PUT for everything else.
    if request.reqMethod != HttpPut:
      await respondMethodNotAllowed(request, allow = "PUT")
    else:
      await gateway.handleAdminOverrides(request)
  elif path.startsWith("/admin/"):
    # D11 point 4: any method but GET or HEAD under /admin/ is a 405 that names
    # GET, with no upstream dial and no state change. An unknown path under
    # /admin/ is a 404, so nothing else can grow there unnoticed.
    if request.reqMethod notin {HttpGet, HttpHead}:
      await respondMethodNotAllowed(request)
    else:
      case gateway.adminGate(request)
      of agNoToken: await respondGateMissing(request)
      of agDenied: await respondGateDenied(request, page = false)
      of agOk:
        if path == "/admin/state":
          await respondJson(request, Http200, gateway.stateJson())
        elif path == "/admin/log":
          await gateway.handleAdminLog(request)
        elif path == "/admin/config":
          await respondJson(request, Http200, gateway.configJson())
        else:
          await respondJson(request, Http404, notFoundBody())
  elif path == "/v1/chat/completions":
    if request.reqMethod != HttpPost:
      await respondMethodNotAllowed(request, allow = "POST")
    else:
      await gateway.handleChat(request)
  elif path == "/v1/systemone":
    # DEC-19. A second door with its own upstreams. A config that declares no
    # `systemone` block has no such route, and 404 is the honest answer: the
    # binary did not gain an endpoint because a caller asked for one.
    if gateway.cfg.systemone.len == 0:
      await respondJson(request, Http404, notFoundBody())
    elif request.reqMethod != HttpPost:
      await respondMethodNotAllowed(request, allow = "POST")
    else:
      await gateway.handleSystemone(request)
  else:
    # Last in the chain on purpose: /healthz, /admin/* and /v1/* keep their
    # priority, so the D11 envelope is untouched by the static surface.
    await gateway.handleStatic(request)

proc dispatch*(gateway: Gateway, request: Request): Future[void] {.async.} =
  ## Every client request passes here, so a shutdown knows how much is still in
  ## flight without asking the HTTP layer.
  inc gateway.inFlight
  try:
    # DEC-24. The listener hands us a socket the HTTP layer accepted, and neither
    # `asynchttpserver` nor the OS enables NoDelay by default. Every response kori
    # sends is one head plus one body, so Nagle only ever adds a wait here. The
    # syscall is per request on a keep-alive connection and costs microseconds
    # against a completion measured in seconds.
    try:
      request.client.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
    except CatchableError:
      discard
    await gateway.routeRequest(request)
  finally:
    dec gateway.inFlight

# ----------------------------------------------------------------- shutdown ---

var stopSignalNumber {.volatile.}: cint = 0

proc onStopSignal(signalNumber: cint) {.noconv.} =
  ## Signal context: one store, no allocation, no lock, no logging.
  stopSignalNumber = signalNumber

proc onReloadSignal(signalNumber: cint) {.noconv.} =
  ## SIGHUP only raises a flag. The parse happens on the event loop, where an
  ## allocation is allowed and a failure can be reported without touching the
  ## running router.
  reloadRequested = true

proc reloadConfig*(gateway: Gateway): bool =
  ## Read the same config path again and apply it in place. A config that does not
  ## parse, does not validate, or that moves the listener is refused whole: the
  ## process keeps serving the config it already proved. Rotation state, cooldowns
  ## and live OAuth tokens survive by leg name where the leg still exists.
  let path = gateway.configPath
  if path.len == 0:
    return false
  var fresh: Config
  try:
    fresh = loadConfig(path)
    applyCli(fresh, gateway.cli)
  except ConfigError as error:
    gateway.lastReloadError = error.msg
    stderr.writeLine("kori: SIGHUP reload refused, still serving the old config: " &
                     error.msg)
    return false
  # A listener cannot move under a running server, and pretending otherwise would
  # leave /admin/config reporting an address nothing is bound to.
  if fresh.listenHost != gateway.cfg.listenHost or
     fresh.listenPort != gateway.cfg.listenPort:
    gateway.lastReloadError = "listen address or port changed; restart to move the listener"
    stderr.writeLine("kori: SIGHUP reload refused, still serving the old config: " &
                     gateway.lastReloadError)
    return false
  if fresh.logPath != gateway.cfg.logPath:
    var reopened: RequestLog
    try:
      reopened = openRequestLog(fresh.logPath, fresh.logRotateBytes, fresh.logKeep)
    except ConfigError as error:
      gateway.lastReloadError = error.msg
      stderr.writeLine("kori: SIGHUP reload refused, still serving the old config: " &
                       error.msg)
      return false
    discard posix.close(gateway.log.fd)
    gateway.log = reopened
    gateway.logLines = countLines(fresh.logPath)
  else:
    # Same file: keep the fd and its byte counter, take the new policy.
    gateway.log.rotateBytes = fresh.logRotateBytes
    gateway.log.keep = fresh.logKeep

  # Router state follows a leg by name. A leg that disappeared loses its state,
  # which is correct: nothing will dial it again. A leg that was added starts
  # fresh, which is the same state a restart would have given it.
  var oldLegs = gateway.cfg.legs
  var oldRuntime = gateway.legs
  var oldOauth = gateway.oauth
  var oldSystemone = gateway.cfg.systemone
  var oldSoRuntime = gateway.systemone
  var runtime = newSeq[LegRuntime](fresh.legs.len)
  var oauth = newSeq[OauthState](fresh.legs.len)
  for index, leg in fresh.legs:
    for oldIndex, oldLeg in oldLegs:
      if oldLeg.name != leg.name:
        continue
      runtime[index] = oldRuntime[oldIndex]
      # The config may have rotated the seed token on disk; a token this process
      # refreshed is newer than the file only when the file still carries the old
      # one, so the in-memory value wins when it is not expired.
      let freshSeed = leg.oauth.accessToken
      let lived = oldOauth[oldIndex]
      if leg.hasOauth and lived.accessToken.len > 0 and
         lived.accessToken != freshSeed and
         (lived.expiresAt <= 0 or lived.expiresAt > epochTime()):
        oauth[index] = lived
      elif leg.hasOauth:
        oauth[index].accessToken = leg.oauth.accessToken
        oauth[index].refreshToken = leg.oauth.refreshToken
        oauth[index].expiresAt = leg.oauth.expiresAt
      break
  gateway.cfg = fresh
  gateway.legs = runtime
  gateway.oauth = oauth
  # DEC-19: a System One leg's state follows its name across a reload for the
  # same reason a chat leg's does. A leg that disappeared loses its cooldown; a
  # leg that was added starts fresh.
  var freshSoRuntime = newSeq[SystemoneRuntime](fresh.systemone.len)
  for index, leg in fresh.systemone:
    for oldIndex, oldLeg in oldSystemone:
      if oldLeg.name != leg.name:
        continue
      freshSoRuntime[index] = oldSoRuntime[oldIndex]
      break
  gateway.systemone = freshSoRuntime
  gateway.credentialRefs = credentialRefs(path, fresh.legs.len)
  inc gateway.reloads
  gateway.lastReloadAt = nowStamp()
  gateway.lastReloadError = ""
  # One line on stderr, because a reload that leaves no trace is indistinguishable
  # from a reload that did not happen.
  stderr.writeLine("kori: SIGHUP reload applied, " & $fresh.legs.len &
                   " leg(s), reload #" & $gateway.reloads)
  true

proc installStopHandlers*() =
  ## SIGTERM is what `podman stop` and systemd send; SIGINT is what a terminal
  ## sends. Both take the same path, so a stop in development proves the stop in
  ## the container. SIGHUP is the reload, and it is a flag the loop reads, never
  ## work done in the handler.
  discard posix.signal(SIGTERM, onStopSignal)
  discard posix.signal(SIGINT, onStopSignal)
  discard posix.signal(SIGHUP, onReloadSignal)

proc stopSignalName*(signalNumber: cint): string =
  case int(signalNumber)
  of 1: "SIGHUP"
  of 2: "SIGINT"
  of 15: "SIGTERM"
  else: "signal " & $int(signalNumber)

proc drainAndExit*(gateway: Gateway, server: AsyncHttpServer) =
  ## Close the listener, let what is already in flight finish inside
  ## ShutdownDrainMs, then exit: 0 when everything drained, 75 when the ceiling
  ## was reached with work still in flight. Either way one line at each end, and
  ## the second line never claims a drain that did not happen.
  let started = epochTime()
  let draining = gateway.inFlight
  stderr.writeLine("kori: " & stopSignalName(stopSignalNumber) &
                   " received, listener closed, draining " & $draining &
                   " in-flight connection(s)")
  server.close()
  while gateway.inFlight > 0 and
        (epochTime() - started) * 1000.0 < ShutdownDrainMs.float:
    waitFor sleepAsync(ShutdownPollMs)
  let elapsedMs = int((epochTime() - started) * 1000.0)
  let remaining = gateway.inFlight
  if remaining > 0:
    # 75 is deliberately not in RestartPreventExitStatus: the service comes back on
    # its own and the journal keeps the one line that says the drain was cut short.
    # A silent exit 0 here would make every drain proof meaningless.
    stderr.writeLine("kori: shutdown complete, drained " &
                     $(draining - remaining) & " of " & $draining &
                     " connection(s) in " & $elapsedMs & " ms, " & $remaining &
                     " still in flight at the " & $ShutdownDrainMs & " ms ceiling")
    quit(75)
  stderr.writeLine("kori: shutdown complete, drained " & $draining &
                   " connection(s) in " & $elapsedMs & " ms, exit 0")
  quit(0)

# ---------------------------------------------------------------------- main ---

proc closeLogAtExit() {.noconv.} =
  if logFdToClose >= 0:
    discard posix.close(logFdToClose)
    logFdToClose = -1

proc main() =
  var cli: CliOptions
  try:
    cli = parseCli(commandLineParams())
  except CliError as error:
    stderr.writeLine("kori: " & error.msg & " — " & usageLine())
    quit(2)

  if cli.help:
    stdout.write(usageText())
    quit(0)

  var cfg: Config
  try:
    cfg = loadConfig(cli.configPath)
    applyCli(cfg, cli)
  except ConfigError as error:
    stderr.writeLine("kori: " & error.msg)
    quit(2)

  var requestLog: RequestLog
  try:
    requestLog = openRequestLog(cfg.logPath, cfg.logRotateBytes, cfg.logKeep)
  except ConfigError as error:
    stderr.writeLine("kori: " & error.msg)
    quit(2)
  addExitProc(closeLogAtExit)

  let gateway = newGateway(cfg, requestLog,
                           cfg.listenHost & ":" & $cfg.listenPort)
  gateway.configPath = cli.configPath
  gateway.cli = cli
  gateway.credentialRefs = credentialRefs(cli.configPath, cfg.legs.len)
  gateway.logLines = countLines(cfg.logPath)
  try:
    gateway.configModifiedAt = rfc3339(getLastModificationTime(cli.configPath).local)
  except CatchableError:
    discard

  stderr.writeLine("kori " & KoriVersion & " (" & KoriRevision & ") listening on " &
                   gateway.listenAddr & ", log " & cfg.logPath)

  installStopHandlers()
  let server = newAsyncHttpServer(maxBody = MaxRequestBytes,
                                  readTimeout = ReadTimeoutMs)
  let handler = proc (request: Request): Future[void] {.async, gcsafe.} =
    await gateway.dispatch(request)
  let serving = server.serve(Port(cfg.listenPort), handler, cfg.listenHost)
  # serve() ends only when the listener does: during a shutdown its accept fails
  # on the closed socket, and that error is read here so the way out is not an
  # unhandled future failure.
  serving.addCallback(proc (future: Future[void]) {.gcsafe.} =
    if future.failed:
      try:
        future.read()
      except CatchableError:
        discard)
  while not serving.finished and stopSignalNumber == 0:
    # A reload swaps the leg list, and a request mid-walk holds indices into the
    # list it started with. The swap therefore waits for the last request to
    # finish; the flag stays raised and this loop retries every poll. A stream
    # running for minutes delays the reload, which is the honest trade: no
    # in-flight request is ever cut or pointed at another leg's state.
    if reloadRequested and gateway.inFlight == 0:
      reloadRequested = false
      discard gateway.reloadConfig()
    waitFor sleepAsync(ShutdownPollMs)
  if stopSignalNumber == 0:
    # The listener died on its own; surface it exactly as waitFor used to.
    serving.read()
    quit(0)
  drainAndExit(gateway, server)

when isMainModule:
  main()
