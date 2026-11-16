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
# Deliberately absent, and not to be reported as done: balancing beyond weight 1
# and the credential refresh (§4). See REPORT.md for the open list.

import std/[algorithm, asyncdispatch, asyncnet, exitprocs,
            httpcore, json, net, options, os, posix, strutils, tables, times, uri]
import std/asynchttpserver

import generated/static_files

const
  KoriVersion* = "0.2.0"
  ## Stamped by config.nims from `git rev-parse --short HEAD`; "dev" when git is
  ## not available, so /healthz never claims a revision it does not have.
  KoriRevision* {.strdefine.} = "dev"

  DefaultHost = "127.0.0.1"
  DefaultPort = 8787

  LogFileMode = 0o640
  MaxRequestBytes = 33_554_432
  MaxHeaderBytes = 65_536
  MaxBodyBytes = 67_108_864

  # SPEC §3b.1. Every number is a deadline this binary enforces itself.
  ConnectDeadlineMs* = 2_000
  TlsDeadlineMs* = 3_000
  HeaderDeadlineStreamMs* = 15_000
  HeaderDeadlineNonStreamMs* = 90_000
  ChunkIdleMs* = 120_000
  TotalNonStreamMs* = 300_000

  # SPEC §3.1 and §3.2.
  AvailabilityCooldownS* = 60.0
  CapacityCooldownS* = 900.0

  LatencyRingSize = 50
  RecentLimit = 10
  FailoverEventLimit = 20

  # Slice 4 cache policy. Only /assets/ names are content-hashed, so only those
  # may be immutable; the fonts keep their names across a font upgrade, and the
  # four pages must never be served stale after a deploy.
  StaticAssetCache* = "public, max-age=31536000, immutable"
  StaticFontCache* = "public, max-age=86400"
  StaticNoStore* = "no-store"

  # The seven failure classes plus the one log-only value (§3.1, §5.1).
  TokenAuth401* = "auth_401"
  TokenMissingSession* = "missing_session_id"
  TokenConnRefused* = "conn_refused"
  TokenDialTimeout* = "dial_timeout"
  TokenHeaderTimeout* = "header_timeout"
  TokenUpstream5xx* = "upstream_5xx"
  TokenQuota429* = "quota_429"
  TokenMidStreamAbort* = "mid_stream_abort"

type
  CliError* = object of CatchableError
  ConfigError* = object of CatchableError

  LegRole* = enum
    lrPrimary = "primary"
    lrFallback = "fallback"

  Leg* = object
    name*: string
    baseUrl*: string
    apiKey*: string
    model*: string
    headers*: seq[(string, string)]
    role*: LegRole
    weight*: int

  Config* = object
    listenHost*: string
    listenPort*: int
    logPath*: string
    balance*: bool
    legs*: seq[Leg]

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

  LegRuntime* = object
    attempted*: bool
    coolingUntil*: float        ## epoch seconds, 0 when the leg is not cooling
    probeInFlight*: bool        ## one half-open probe at a time
    lastFailureClass*: string
    lastFailureAt*: string
    lastSuccessAt*: string
    servedInWindow*: int
    failedInWindow*: int
    latencies*: seq[int]

  FailoverEvent* = object
    at*: string
    fromRoute*: string
    toRoute*: string
    reason*: string

  Gateway* = ref object
    cfg: Config
    log: RequestLog
    startedAt: string
    listenAddr: string
    requests*: int
    failoverAvailability*: int
    failoverCapacity*: int
    cursor: int
    ssl*: SslContext
    legs*: seq[LegRuntime]
    events*: seq[FailoverEvent]
    configPath*: string
    configModifiedAt*: string
    credentialRefs*: seq[string]
    logLines*: int
    staticFiles: Table[string, StaticFile]

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

  Chain = object
    firstFrom: string
    firstReason: string
    lastReason: string
    availability: bool
    capacity: bool

var logFdToClose: cint = -1

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

proc loadConfig*(path: string): Config =
  var raw: string
  try:
    raw = readFile(path)
  except CatchableError as e:
    failConfig("cannot read config '" & path & "': " & e.msg)
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

  let balance = root{"balance"}
  if balance != nil and balance.kind != JNull:
    if balance.kind != JBool:
      failConfig("balance must be true or false")
    result.balance = balance.getBool()

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
    # CONTRACT §1: model is optional; the leg name stands in, never a refusal.
    leg.model = optionalString(item, "model", ctx)
    if leg.model.len == 0:
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
      # v1 refuses a weight it cannot honour rather than accepting a number with
      # no defined split (TAKEOVER-plan-team-c §5).
      if leg.weight != 1:
        failConfig(ctx & ".weight must be 1 in v1; the weighted split is not built")
    result.legs.add(leg)
  if result.legs.len == 0:
    failConfig("config needs at least one leg")

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

proc requestLogLine*(ts, route: string, status, latencyMs: int,
                     tokensIn, tokensOut: Option[int],
                     failoverFrom, failoverReason: string,
                     stream: bool): string =
  ## The nine keys of SPEC §5.1 in that order, and nothing else. Redaction is
  ## structural (R17): no header, no body and no credential is a parameter here,
  ## so there is nothing for a later pass to strip.
  "{\"ts\":" & jsonEscape(ts) &
    ",\"route\":" & jsonEscape(route) &
    ",\"status\":" & $status &
    ",\"latency_ms\":" & $latencyMs &
    ",\"tokens_in\":" & jsonIntOrNull(tokensIn) &
    ",\"tokens_out\":" & jsonIntOrNull(tokensOut) &
    ",\"failover_from\":" & jsonEscape(failoverFrom) &
    ",\"failover_reason\":" & jsonEscape(failoverReason) &
    ",\"stream\":" & (if stream: "true" else: "false") & "}"

proc openRequestLog*(path: string): RequestLog =
  ## Opened once, for the process lifetime: O_WRONLY|O_CREAT|O_APPEND, mode 0640.
  let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_APPEND,
                      Mode(LogFileMode))
  if fd < 0:
    failConfig("cannot open log '" & path & "': errno " & $errno)
  result.fd = fd
  logFdToClose = fd

proc appendLine(log: RequestLog, line: string): bool =
  ## One write(2) carrying the whole line including its newline (CONTRACT §3). A
  ## short write is left short rather than spliced: a partial line is honest, two
  ## interleaved requests are not.
  let data = line & "\n"
  var written = posix.write(log.fd, unsafeAddr data[0], data.len)
  if written < 0 and errno == EINTR:
    written = posix.write(log.fd, unsafeAddr data[0], data.len)
  if written != data.len:
    stderr.writeLine("kori: short log write: " & $written & " of " &
                     $data.len & " bytes")
    return false
  true

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
  Gateway(cfg: cfg, log: log, startedAt: nowStamp(), listenAddr: listenAddr,
          cursor: -1, ssl: newUpstreamSslContext(),
          legs: newSeq[LegRuntime](cfg.legs.len),
          staticFiles: staticFileTable())

proc legAvailable*(gateway: Gateway, index: int, now: float): bool =
  ## A cooling leg is skipped without a dial. Once the cooldown expires the leg
  ## is eligible again, and the first request that picks it is the half-open
  ## probe (§3.2): a second failure starts a fresh full cooldown.
  let runtime = gateway.legs[index]
  if runtime.coolingUntil <= 0:
    return true
  if runtime.coolingUntil > now:
    return false
  not runtime.probeInFlight

proc pickOrder*(gateway: Gateway): seq[int] =
  ## R12a: one pick at request start, before any dial, then a walk. Balancing
  ## picks round-robin over the primaries that are available; the fallback only
  ## enters the pick when no primary can serve (D12.1). The walk is always the
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

  var chosen = pool[0]
  for offset in 1 .. gateway.cfg.legs.len:
    let index = (gateway.cursor + offset) mod gateway.cfg.legs.len
    if index in pool:
      chosen = index
      break
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

proc startCooldown*(gateway: Gateway, index: int, reason: string) =
  ## §3.1 and §3.2: the cooldown starts at the failure, and the leg's failure
  ## counter moves once for this request (D11.1).
  let cooldown =
    if reason == TokenQuota429: CapacityCooldownS
    else: AvailabilityCooldownS
  let now = epochTime()
  var runtime = addr gateway.legs[index]
  runtime.attempted = true
  runtime.coolingUntil = now + cooldown
  runtime.probeInFlight = false
  runtime.lastFailureClass = reason
  runtime.lastFailureAt = stampAt(now)
  runtime.failedInWindow.inc

proc markServed*(gateway: Gateway, index: int, latencyMs: int) =
  let now = epochTime()
  var runtime = addr gateway.legs[index]
  runtime.attempted = true
  runtime.coolingUntil = 0
  runtime.lastSuccessAt = stampAt(now)
  runtime.servedInWindow.inc
  runtime.latencies.add latencyMs
  if runtime.latencies.len > LatencyRingSize:
    runtime.latencies.delete(0)

proc markAttempted*(gateway: Gateway, index: int) =
  gateway.legs[index].attempted = true

proc legStateName*(runtime: LegRuntime, now: float): string =
  ## D7: `dead` is not a router state, and `unknown` is a fresh start.
  if runtime.coolingUntil > now:
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

# --------------------------------------------------------------- upstream io ---

proc remainingMs(deadline: float): int =
  let left = int((deadline - epochTime()) * 1000.0)
  if left < 0: 0 else: left

proc deadlineIn(ms: int): float =
  epochTime() + ms.float / 1000.0

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

# ------------------------------------------------------------- classification ---

proc isQuotaBody*(body: string): bool =
  ## §3.2: a quota 429 carries a quota body. The measured one is
  ## `GoUsageLimitError`; the other spellings are the "equivalents" the spec
  ## names. A plain rate limit is not this class (D9.3).
  body.contains("GoUsageLimitError") or body.contains("usage_limit") or
    body.contains("usage limit") or body.contains("insufficient_quota") or
    body.contains("QuotaExceeded")

proc failureToken*(status: int, body: string): string =
  ## §3.1 to §3.3. Empty string means "not a failure class": the response either
  ## served the caller or is a client error returned unchanged.
  if status == 401:
    TokenAuth401
  elif status == 400 and body.contains("MissingSessionID"):
    TokenMissingSession
  elif status == 429 and isQuotaBody(body):
    TokenQuota429
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
    (true, false, socket)
  except CatchableError:
    closeQuietly(socket)
    (false, false, nil)

proc attemptLeg(gateway: Gateway, request: Request, leg: Leg, body: string,
                stream: bool, totalDeadline: float): Future[AttemptOutcome] {.async.} =
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
    if leg.apiKey.len > 0 and not hasAuthorization:
      head.add "Authorization: Bearer " & leg.apiKey & "\r\n"
    head.add "\r\n"

    # The head send drives the TLS handshake, so its deadline is the TLS one.
    let handshakeDeadline =
      if isTls: deadlineIn(TlsDeadlineMs)
      else: deadlineIn(HeaderDeadlineNonStreamMs)
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
    let headerDeadline =
      deadlineIn(if stream: HeaderDeadlineStreamMs else: HeaderDeadlineNonStreamMs)
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

      let token = failureToken(status, errorBody)
      if token.len > 0:
        result.kind = akFailed
        result.reason = token
        return
      # §3.3: any other 4xx is the caller's problem. Returned unchanged.
      let contentType = headerValue(headers, "content-type")
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
    # An SSL or socket error before anything reached the caller is an unusable
    # leg. The closed vocabulary has no token for it, and `conn_refused` is the
    # honest one: the connection could not be established.
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

  var chain = Chain()
  var status = 502
  var route = ""
  var terminalAbort = false
  var tokensIn: Option[int]
  var tokensOut: Option[int]
  var answered = false

  let order = gateway.pickOrder()
  if order.len == 0:
    # Every leg is cooling: no dial at all (D12.3's third sentence).
    route = gateway.cfg.legs[^1].name
    await request.sendErrorBody(502, allLegsFailedBody("all_legs_cooling"))
    answered = true

  if not answered:
    for position, index in order:
      let leg = gateway.cfg.legs[index]
      let probing = gateway.legs[index].coolingUntil > 0
      if probing:
        gateway.legs[index].probeInFlight = true
      gateway.markAttempted(index)
      route = leg.name
      let outcome = await gateway.attemptLeg(request, leg, forwardBody, stream,
                                             totalDeadline)
      if probing:
        gateway.legs[index].probeInFlight = false

      case outcome.kind
      of akFailed:
        gateway.startCooldown(index, outcome.reason)
        chain.lastReason = outcome.reason
        if chain.firstReason.len == 0:
          chain.firstReason = outcome.reason
          chain.firstFrom = leg.name
          if outcome.reason == TokenQuota429:
            chain.capacity = true
          else:
            chain.availability = true
        if position + 1 < order.len:
          gateway.recordEvent(leg.name, gateway.cfg.legs[order[position + 1]].name,
                              outcome.reason)
      of akServed, akAborted, akPassthrough, akTerminal:
        status = outcome.status
        terminalAbort = outcome.kind == akAborted
        tokensIn = outcome.tokensIn
        tokensOut = outcome.tokensOut
        if outcome.kind != akTerminal:
          gateway.markServed(index, int((epochTime() - started) * 1000.0))
        answered = true
        break

  if not answered:
    # §5.5: one 502 whatever the legs returned, carrying the terminal reason.
    let message = if chain.lastReason.len > 0: chain.lastReason else: "all_legs_failed"
    await request.sendErrorBody(502, allLegsFailedBody(message))
    status = 502
    tokensIn = none(int)
    tokensOut = none(int)

  gateway.requests.inc
  if chain.availability:
    gateway.failoverAvailability.inc
  if chain.capacity:
    gateway.failoverCapacity.inc

  # §5.1: `failover_reason` is the first reason the request met, with
  # `mid_stream_abort` as the one outcome that overrides it because it is what
  # the caller actually saw (D9.2, D10.1). A request that never failed over keeps
  # the empty string, which is the binding answer for this field.
  let logReason =
    if terminalAbort: TokenMidStreamAbort
    else: chain.firstReason

  let latencyMs = int((epochTime() - started) * 1000.0)
  if gateway.log.appendLine(requestLogLine(
      ts = nowStamp(),
      route = route,
      status = status,
      latencyMs = latencyMs,
      tokensIn = tokensIn,
      tokensOut = tokensOut,
      failoverFrom = chain.firstFrom,
      failoverReason = logReason,
      stream = stream)):
    inc gateway.logLines

# ---------------------------------------------------------------- log tail ---

const
  ## D8: a page is a tail, never the whole file. 5,000 lines is the scan budget.
  LogScanBudget = 5000
  LogTailBlock = 8192

const LogRowKeys = ["ts", "route", "status", "latency_ms", "tokens_in",
                    "tokens_out", "failover_from", "failover_reason", "stream"]

type
  LogFilter* = object
    route*: string
    hasRoute*: bool
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
  ## Exactly the nine keys of SPEC §5.1, in that order. Anything else a line
  ## carries is dropped, so the page cannot widen the row by accident.
  result = newJObject()
  for key in LogRowKeys:
    let value = node{key}
    if value == nil:
      result[key] = newJNull()
    else:
      result[key] = value

proc rowMatches*(node: JsonNode, filter: LogFilter): bool =
  if filter.hasRoute:
    let route = node{"route"}
    if route == nil or route.kind != JString or route.getStr() != filter.route:
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
  let query = value.find('?')
  let fragment = value.find('#')
  if query < 0:
    if fragment >= 0:
      return value[0 ..< fragment]
    return value
  let tail = value[query + 1 .. ^1].toLowerAscii()
  if tail.contains("key") or tail.contains("token") or tail.contains("secret") or
     tail.contains("api"):
    return value[0 ..< query]
  if fragment >= 0 and fragment > query:
    return value[0 ..< fragment]
  value

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
    route["state"] = %legStateName(runtime, now)
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

  var windowNode = newJObject()
  windowNode["from"] = %gateway.startedAt
  windowNode["to"] = %nowStamp()
  windowNode["requests"] = %gateway.requests
  windowNode["failover_availability"] = %gateway.failoverAvailability
  windowNode["failover_capacity"] = %gateway.failoverCapacity
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

  var legs = newJArray()
  for index, leg in gateway.cfg.legs:
    var node = newJObject()
    node["order"] = %(index + 1)
    node["name"] = %leg.name
    node["role"] = %($leg.role)
    node["weight"] = %leg.weight
    node["base_url"] = %redactUrl(leg.baseUrl)
    node["model"] = %leg.model
    var headers = newJArray()
    for (headerName, _) in leg.headers:
      headers.add(%headerName)
    node["headers"] = headers
    var credential = newJObject()
    credential["name"] = %(leg.name & " API key")
    credential["state"] = %(if leg.apiKey.len > 0: "set" else: "missing")
    credential["source"] = %"file"
    var credentialRef = gateway.configPath
    if index < gateway.credentialRefs.len and
       gateway.credentialRefs[index].len > 0:
      credentialRef = gateway.credentialRefs[index]
    credential["ref"] = %credentialRef
    node["credential"] = credential
    legs.add(node)
  root["legs"] = legs

  var timeouts = newJObject()
  timeouts["connect_ms"] = %ConnectDeadlineMs
  timeouts["tls_ms"] = %TlsDeadlineMs
  timeouts["header_ms_stream"] = %HeaderDeadlineStreamMs
  timeouts["header_ms_non_stream"] = %HeaderDeadlineNonStreamMs
  timeouts["idle_ms"] = %ChunkIdleMs
  timeouts["total_ms"] = %TotalNonStreamMs
  root["timeouts"] = timeouts

  var cooldowns = newJObject()
  cooldowns["availability_s"] = %int(AvailabilityCooldownS)
  cooldowns["quota_s"] = %int(CapacityCooldownS)
  root["cooldowns"] = cooldowns

  var logNode = newJObject()
  logNode["path"] = %gateway.cfg.logPath
  logNode["append_only"] = %true
  logNode["redacted"] = %true
  root["log"] = logNode

  $root

proc healthzJson*(): string =
  "{\"status\":\"ok\",\"version\":" & jsonEscape(KoriVersion) &
    ",\"revision\":" & jsonEscape(KoriRevision) & "}"

# ------------------------------------------------------------------ handlers ---

proc respondJson(request: Request, status: HttpCode,
                 body: string): Future[void] {.async.} =
  var headers = newHttpHeaders()
  headers["Content-Type"] = "application/json"
  await request.respond(status, body, headers)

proc respondMethodNotAllowed(request: Request): Future[void] {.async.} =
  ## D11 point 4: the refusal names the one method the read surface answers.
  var headers = newHttpHeaders()
  headers["Content-Type"] = "application/json"
  headers["Allow"] = "GET"
  await request.respond(Http405,
    "{\"error\":{\"type\":\"method_not_allowed\",\"message\":\"GET\"}}", headers)

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

proc handleStatic(gateway: Gateway,
                  request: Request): Future[void] {.async.} =
  ## The four pages, /assets/* and /fonts/*, from the compiled table only.
  ##
  ## Exact path match: "/" is index.html and every other request is a lookup, so
  ## there is no prefix rule, no index fallback and no way for a path outside the
  ## table to reach a file. Nothing here touches the filesystem, so a traversal
  ## attempt is just a key that is not present.
  if request.reqMethod notin {HttpGet, HttpHead}:
    var refusal = newHttpHeaders()
    refusal["Content-Type"] = "application/json"
    refusal["Allow"] = "GET, HEAD"
    await request.respond(Http405,
      "{\"error\":{\"type\":\"method_not_allowed\",\"message\":\"GET, HEAD\"}}",
      refusal)
    return

  let path = resolveStaticPath(request.url.path)
  if not gateway.staticFiles.hasKey(path):
    await respondJson(request, Http404, notFoundBody())
    return

  let entry = gateway.staticFiles[path]
  var headers = @[("Content-Type", entry.contentType),
                  ("Content-Length", $entry.body.len),
                  ("Cache-Control", cacheControlFor(path)),
                  ("X-Content-Type-Options", "nosniff")]
  # A HEAD gets the same headers and no body; the length is the body's.
  let payload = if request.reqMethod == HttpHead: "" else: entry.body
  await request.client.send(buildHead(200, headers) & payload)

proc dispatch(gateway: Gateway, request: Request): Future[void] {.async.} =
  let path = request.url.path
  if path == "/healthz":
    if request.reqMethod notin {HttpGet, HttpHead}:
      await respondJson(request, Http405, "{\"error\":\"method not allowed\"}")
    else:
      await respondJson(request, Http200, healthzJson())
  elif path.startsWith("/admin/"):
    # D11 point 4: any method but GET or HEAD under /admin/ is a 405 that names
    # GET, with no upstream dial and no state change. An unknown path under
    # /admin/ is a 404, so nothing else can grow there unnoticed.
    if request.reqMethod notin {HttpGet, HttpHead}:
      await respondMethodNotAllowed(request)
    elif path == "/admin/state":
      await respondJson(request, Http200, gateway.stateJson())
    elif path == "/admin/log":
      await gateway.handleAdminLog(request)
    elif path == "/admin/config":
      await respondJson(request, Http200, gateway.configJson())
    else:
      await respondJson(request, Http404,
                        "{\"error\":{\"type\":\"not_found\",\"message\":\"no such path\"}}")
  elif path == "/v1/chat/completions":
    if request.reqMethod != HttpPost:
      await respondJson(request, Http405, "{\"error\":\"method not allowed\"}")
    else:
      await gateway.handleChat(request)
  else:
    # Last in the chain on purpose: /healthz, /admin/* and /v1/* keep their
    # priority, so the D11 envelope is untouched by the static surface.
    await gateway.handleStatic(request)

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
    requestLog = openRequestLog(cfg.logPath)
  except ConfigError as error:
    stderr.writeLine("kori: " & error.msg)
    quit(2)
  addExitProc(closeLogAtExit)

  let gateway = newGateway(cfg, requestLog,
                           cfg.listenHost & ":" & $cfg.listenPort)
  gateway.configPath = cli.configPath
  gateway.credentialRefs = credentialRefs(cli.configPath, cfg.legs.len)
  gateway.logLines = countLines(cfg.logPath)
  try:
    gateway.configModifiedAt = rfc3339(getLastModificationTime(cli.configPath).local)
  except CatchableError:
    discard

  stderr.writeLine("kori " & KoriVersion & " (" & KoriRevision & ") listening on " &
                   gateway.listenAddr & ", log " & cfg.logPath)

  let server = newAsyncHttpServer(maxBody = MaxRequestBytes)
  let handler = proc (request: Request): Future[void] {.async, gcsafe.} =
    await gateway.dispatch(request)
  waitFor server.serve(Port(cfg.listenPort), handler, cfg.listenHost)

when isMainModule:
  main()
