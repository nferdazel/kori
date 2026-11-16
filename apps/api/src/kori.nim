# kori — in-house LLM provider gateway.
#
# Slice 1 only: CLI and config precedence, the append-only request log, /healthz,
# /admin/state, and one non-streaming proxy path to the first configured leg.
#
# Deliberately absent, and not to be reported as done: failure classification
# (SPEC §3), deadlines (R5), failover and cooldowns (R6, R12a), SSE and
# mid-stream abort (R8-R11), balancing (D12), /admin/log, /admin/config and the
# dashboard (R18). A request is forwarded byte for byte (D9.1) to one leg and the
# upstream status is returned unchanged.

import std/[algorithm, asyncdispatch, asynchttpserver, exitprocs, httpclient,
            httpcore, json, net, options, os, posix, strutils, times, uri]

const
  KoriVersion* = "0.1.0"
  ## Stamped by config.nims from `git rev-parse --short HEAD`; "dev" when git is
  ## not available, so /healthz never claims a revision it does not have.
  KoriRevision* {.strdefine.} = "dev"

  DefaultHost = "127.0.0.1"
  DefaultPort = 8787

  LogFileMode = 0o640
  MaxRequestBytes = 33_554_432
  MaxUpstreamBytes = 67_108_864
  ## SPEC §3b.1 total for a non-streaming request. Slice 1 has no per-phase
  ## deadlines; this is the net that stops one hung leg pinning a request forever.
  UpstreamDeadlineMs = 300_000

  LatencyRingSize = 50
  RecentLimit = 10

type
  CliError* = object of CatchableError
  ConfigError* = object of CatchableError
  UpstreamTimeout* = object of CatchableError

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

  RequestLog = object
    fd: cint

  LegRuntime = object
    servedInWindow: int
    failedInWindow: int
    lastSuccessAt: string
    latencies: seq[int]

  Gateway = ref object
    cfg: Config
    log: RequestLog
    startedAt: string
    listenAddr: string
    requests: int
    failoverAvailability: int
    failoverCapacity: int
    legs: seq[LegRuntime]

  UpstreamResult = object
    reached: bool
    status: int
    payload: string
    contentType: string
    tokensIn: Option[int]
    tokensOut: Option[int]
    reason: string

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
      # no defined split (TAKEOVER-plan-team-c §5). Balancing is not built yet.
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

proc appendLine(log: RequestLog, line: string) =
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

# --------------------------------------------------------------------- time ---

proc rfc3339*(moment: DateTime): string =
  moment.format("yyyy-MM-dd'T'HH:mm:sszzz")

proc nowStamp*(): string =
  rfc3339(now())

# ------------------------------------------------------------------- upstream ---

proc upstreamUrl(leg: Leg): string =
  var base = leg.baseUrl.strip()
  while base.endsWith("/"):
    base.setLen(base.len - 1)
  base & "/chat/completions"

proc wantsStream*(body: string): bool =
  ## Read from the caller's body, never assumed: the log's `stream` key reports
  ## what the caller asked for, not what this build does with it.
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

proc awaitOrDeadline[T](future: Future[T], deadlineMs: int): Future[T] {.async.} =
  ## Nim 2.4's withTimeout reports completion as a bool rather than returning the
  ## value, so the value is read from the future the timeout guarded.
  if not await withTimeout(future, deadlineMs):
    raise newException(UpstreamTimeout, "upstream deadline exceeded")
  result = await future

proc doRequest(client: AsyncHttpClient, leg: Leg,
               body: string): Future[AsyncResponse] {.async.} =
  var headers = newHttpHeaders()
  headers["Content-Type"] = "application/json"
  for (name, value) in leg.headers:
    headers[name] = value
  # The caller's Authorization is accepted and ignored (R15); the leg's own
  # credential is the only one that leaves this process.
  if leg.apiKey.len > 0 and not headers.hasKey("Authorization"):
    headers["Authorization"] = "Bearer " & leg.apiKey
  result = await client.request(upstreamUrl(leg), HttpPost, body, headers)

proc callLeg(leg: Leg, body: string): Future[UpstreamResult] {.async.} =
  result.contentType = "application/json"
  let client = newAsyncHttpClient(maxRedirects = 0, maxBodySize = MaxUpstreamBytes)
  try:
    let response = await awaitOrDeadline(doRequest(client, leg, body),
                                         UpstreamDeadlineMs)
    result.status = response.code.int
    result.payload = await awaitOrDeadline(response.body, UpstreamDeadlineMs)
    let contentType = response.headers.getOrDefault("Content-Type")
    if contentType.len > 0:
      result.contentType = contentType
    (result.tokensIn, result.tokensOut) = usageTokens(result.payload)
    result.reached = true
  except OSError as error:
    # The one class slice 1 can prove from the OS. Anything else leaves `reason`
    # empty rather than inventing a §3 token that was never observed.
    if error.errorCode == ECONNREFUSED:
      result.reason = "conn_refused"
  except CatchableError:
    discard
  finally:
    client.close()

proc allLegsFailedBody(message: string): string =
  "{\"error\":{\"type\":\"all_legs_failed\",\"message\":" &
    jsonEscape(message) & "}}"

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

proc legState(lastSuccessAt: string): string =
  if lastSuccessAt.len > 0: "ok" else: "unknown"

proc stateJson*(gateway: Gateway): string =
  ## The seven top-level keys of CONTRACT §4, in that order. `failover_events`
  ## sits before `recent` on purpose: the harness takes the first array whose
  ## members carry a timestamp, and `recent` would match too.
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
    route["state"] = %legState(runtime.lastSuccessAt)
    route["cooling_until"] = newJNull()
    route["last_failure_class"] = newJNull()
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

  root["failover_events"] = newJArray()
  # recent[] and /admin/log read the log backwards from EOF. That reader belongs
  # to the dashboard slice, so this build reports an empty tail and says so with
  # its own limit rather than pretending the file was read.
  root["recent"] = newJArray()
  root["limit"] = %RecentLimit

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

proc proxyChat(gateway: Gateway, request: Request): Future[void] {.async.} =
  let started = epochTime()
  let stream = wantsStream(request.body)
  let leg = gateway.cfg.legs[0]
  let outcome = await callLeg(leg, request.body)

  var status: int
  var payload: string
  var contentType = outcome.contentType
  if outcome.reached:
    status = outcome.status
    payload = outcome.payload
  else:
    # No leg produced an answer: one error, not the last upstream status (R20).
    status = 502
    contentType = "application/json"
    payload = allLegsFailedBody(
      if outcome.reason.len > 0: outcome.reason else: "upstream_error")

  var responseHeaders = newHttpHeaders()
  responseHeaders["Content-Type"] = contentType
  try:
    await request.respond(HttpCode(status), payload, responseHeaders)
  except CatchableError:
    discard

  let latencyMs = int((epochTime() - started) * 1000)
  gateway.requests.inc
  if status >= 200 and status < 300:
    gateway.legs[0].servedInWindow.inc
    gateway.legs[0].lastSuccessAt = nowStamp()
    gateway.legs[0].latencies.add latencyMs
    if gateway.legs[0].latencies.len > LatencyRingSize:
      gateway.legs[0].latencies.delete(0)

  gateway.log.appendLine(requestLogLine(
    ts = nowStamp(),
    route = leg.name,
    status = status,
    latencyMs = latencyMs,
    tokensIn = outcome.tokensIn,
    tokensOut = outcome.tokensOut,
    failoverFrom = "",
    failoverReason = outcome.reason,
    stream = stream))

proc dispatch(gateway: Gateway, request: Request): Future[void] {.async.} =
  case request.url.path
  of "/healthz":
    if request.reqMethod notin {HttpGet, HttpHead}:
      await respondJson(request, Http405, "{\"error\":\"method not allowed\"}")
    else:
      await respondJson(request, Http200, healthzJson())
  of "/admin/state":
    if request.reqMethod notin {HttpGet, HttpHead}:
      await respondJson(request, Http405, "{\"error\":\"method not allowed\"}")
    else:
      await respondJson(request, Http200, gateway.stateJson())
  of "/v1/chat/completions":
    if request.reqMethod != HttpPost:
      await respondJson(request, Http405, "{\"error\":\"method not allowed\"}")
    else:
      await gateway.proxyChat(request)
  else:
    await respondJson(request, Http404,
                      "{\"error\":{\"type\":\"not_found\",\"message\":\"no such path\"}}")

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

  let gateway = Gateway(
    cfg: cfg,
    log: requestLog,
    startedAt: nowStamp(),
    listenAddr: cfg.listenHost & ":" & $cfg.listenPort,
    legs: newSeq[LegRuntime](cfg.legs.len))

  stderr.writeLine("kori " & KoriVersion & " (" & KoriRevision & ") listening on " &
                   gateway.listenAddr & ", log " & cfg.logPath)

  let server = newAsyncHttpServer(maxBody = MaxRequestBytes)
  let handler = proc (request: Request): Future[void] {.async, gcsafe.} =
    await gateway.dispatch(request)
  waitFor server.serve(Port(cfg.listenPort), handler, cfg.listenHost)

when isMainModule:
  main()
