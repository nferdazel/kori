# Unit tests for the slice-1 pure surface: the log line the acceptance harness
# grades byte-wise, CLI flag forms and precedence, and config defaults. No socket
# is opened here; the harness starts the real binary.

import std/[json, options, os, sequtils, strutils, tables, times]

import "../../apps/api/src/kori"
import "../../apps/api/src/generated/static_files"

var failures = 0

template check(label: string, condition: untyped) =
  if condition:
    echo "PASS  ", label
  else:
    echo "FAIL  ", label
    inc failures

template checkRaises(label: string, errorType: typedesc, body: untyped) =
  var raised = false
  try:
    body
  except errorType:
    raised = true
  except CatchableError:
    discard
  check label, raised

# ------------------------------------------------------------------ log line ---

const NullLine =
  "{\"ts\":\"2026-11-16T09:43:00+07:00\",\"route\":\"opencode-go\",\"status\":200," &
  "\"latency_ms\":41,\"tokens_in\":null,\"tokens_out\":null," &
  "\"failover_from\":\"\",\"failover_reason\":\"\",\"stream\":false}"

check "log line is byte-exact with null token counts",
  requestLogLine("2026-11-16T09:43:00+07:00", "opencode-go", 200, 41,
                 none(int), none(int), "", "", false) == NullLine

check "log line carries provider-reported tokens",
  requestLogLine("2026-11-16T09:43:00+07:00", "opencode-go", 200, 41,
                 some(11), some(7), "", "", true).contains("\"tokens_out\":7")

check "log line reports stream from the caller's body",
  requestLogLine("t", "leg", 200, 1, none(int), none(int), "", "", true)
    .endsWith("\"stream\":true}")

let keys = parseJson(NullLine).keys().toSeq()
check "log line key order is SPEC 5.1",
  keys == @["ts", "route", "status", "latency_ms", "tokens_in", "tokens_out",
            "failover_from", "failover_reason", "stream"]

check "log line escapes a quote in the route name",
  requestLogLine("t", "a\"b", 200, 1, none(int), none(int), "", "", false)
    .contains("\"route\":\"a\\\"b\"")

check "log line carries the alias the caller asked for",
  requestLogLine("t", "leg-a", 200, 1, none(int), none(int), "", "", false,
                 "kori/fast").contains("\"alias\":\"kori/fast\"")

check "a request that named no alias has no alias key at all",
  not requestLogLine("t", "leg-a", 200, 1, none(int), none(int), "", "", false)
    .contains("\"alias\"")

let aliasRow = buildLogRow(parseJson(requestLogLine(
  "t", "leg-a", 200, 1, none(int), none(int), "", "", false, "kori/fast")))
check "the row projection keeps the alias when the line has one",
  aliasRow{"alias"} != nil and aliasRow{"alias"}.getStr() == "kori/fast"

let tooLongAlias = repeat('a', MaxAliasBytes + 1)
check "an alias of exactly 256 bytes is still accepted",
  not aliasTooLong(repeat('a', MaxAliasBytes))

check "an alias of 257 bytes is refused",
  aliasTooLong(tooLongAlias)

let tooLongBody = aliasTooLongBody()
check "the too-long body names the type and the limit and nothing else",
  tooLongBody.contains("\"type\":\"alias_too_long\"") and
    tooLongBody.contains("longer than 256 bytes") and tooLongBody.len < 120

check "the too-long body does not carry the alias",
  not tooLongBody.contains("aaaa")

check "the log value of an over-long alias is cut to the log budget",
  aliasLogValue(tooLongAlias).len == MaxAliasLogBytes

check "the log value of a normal alias keeps the caller's prefix",
  aliasLogValue("fast") == "kori/fast"

let maxAlias = repeat('a', MaxAliasBytes)
check "a legal 256-byte alias survives the log value whole",
  aliasLogValue(maxAlias) == AliasPrefix & maxAlias and
    aliasLogValue(maxAlias).len == MaxAliasLogBytes

let twoByteStraddle = repeat('a', MaxAliasBytes - 1) & "\u00e9"
check "a two-byte rune at the cut is dropped whole, not half",
  aliasLogValue(twoByteStraddle) == AliasPrefix & repeat('a', MaxAliasBytes - 1) and
    aliasLogValue(twoByteStraddle).len == MaxAliasLogBytes - 1

let fourByteStraddle = repeat('a', 254) & "\xF0\x9F\x98\x80"
check "a four-byte rune at the cut is dropped whole, not half",
  aliasLogValue(fourByteStraddle) == AliasPrefix & repeat('a', 254) and
    aliasLogValue(fourByteStraddle).len == 259

check "a limit of zero yields the empty string, not an exception",
  cutUtf8("kori/fast", 0) == ""

let longLine = parseJson(requestLogLine(
  "t", "leg-a", 400, 1, none(int), none(int), "", "alias_too_long", false,
  aliasLogValue(tooLongAlias)))
check "a refused over-long alias still fits one log line",
  longLine{"alias"} != nil and longLine{"alias"}.getStr().len == MaxAliasLogBytes

# ---------------------------------------------------------------------- CLI ---

block:
  let cli = parseCli(@["--config", "/tmp/k.json", "--port", "9000"])
  check "CLI accepts '--flag value'", cli.configPath == "/tmp/k.json" and cli.port == 9000

block:
  let cli = parseCli(@["--config=/tmp/k.json", "--port=9001", "--address=0.0.0.0"])
  check "CLI accepts '--flag=value'",
    cli.configPath == "/tmp/k.json" and cli.port == 9001 and
    cli.address == "0.0.0.0" and cli.hasAddress

block:
  let cli = parseCli(@["--help"])
  check "--help is a flag, not an error", cli.help

checkRaises "unknown flag is rejected", CliError:
  discard parseCli(@["--config=/tmp/k.json", "--nope=1"])

checkRaises "--config is required", CliError:
  discard parseCli(@["--port=9000"])

checkRaises "non-numeric port is rejected", CliError:
  discard parseCli(@["--config=/tmp/k.json", "--port=abc"])

checkRaises "port above 65535 is rejected", CliError:
  discard parseCli(@["--config=/tmp/k.json", "--port=70000"])

checkRaises "a hostname is not an address literal", CliError:
  discard parseCli(@["--config=/tmp/k.json", "--address=localhost"])

checkRaises "a flag with no value is rejected", CliError:
  discard parseCli(@["--config"])

# ------------------------------------------------------------------- config ---

let scratch = getTempDir() / ("kori-unit-" & $getCurrentProcessId())
createDir(scratch)

proc writeConfig(name, content: string): string =
  result = scratch / name
  writeFile(result, content)

block:
  let path = writeConfig("minimal.json", """
{"listen":{"host":"127.0.0.1","port":4011},"log":{"path":"/tmp/x.jsonl"},
 "legs":[{"name":"opencode-go","base_url":"https://opencode.ai/inference/go/openai/v1"}]}
""")
  let cfg = loadConfig(path)
  check "config reads listen and log", cfg.listenPort == 4011 and cfg.logPath == "/tmp/x.jsonl"
  check "model falls back to the leg name", cfg.legs[0].model == "opencode-go"
  check "role defaults to primary", cfg.legs[0].role == lrPrimary
  check "weight defaults to 1", cfg.legs[0].weight == 1
  check "balance defaults to false", cfg.balance == false

block:
  let path = writeConfig("headers.json", """
{"legs":[{"name":"leg-a","base_url":"http://127.0.0.1:1/v1","api_key":"k",
 "headers":{"x-opencode-session":"s"},"role":"fallback"}]}
""")
  let cfg = loadConfig(path)
  check "config reads a leg header", cfg.legs[0].headers == @[("x-opencode-session", "s")]
  check "config reads role fallback", cfg.legs[0].role == lrFallback

checkRaises "invalid JSON exits 2", ConfigError:
  discard loadConfig(writeConfig("broken.json", "{not json"))

checkRaises "missing config file exits 2", ConfigError:
  discard loadConfig(scratch / "absent.json")

checkRaises "a leg without base_url is rejected", ConfigError:
  discard loadConfig(writeConfig("nourl.json", """{"legs":[{"name":"a"}]}"""))

checkRaises "an empty legs array is rejected", ConfigError:
  discard loadConfig(writeConfig("nolegs.json", """{"legs":[]}"""))

checkRaises "a weight v1 cannot honour is rejected", ConfigError:
  discard loadConfig(writeConfig("weight.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","weight":2}]}
"""))

block:
  var cfg = loadConfig(writeConfig("prec.json", """
{"listen":{"host":"10.0.0.1","port":1234},"log":{"path":"/tmp/a.jsonl"},
 "legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1"}]}
"""))
  applyCli(cfg, CliOptions(configPath: "/x"))
  check "config beats the built-in default",
    cfg.listenHost == "10.0.0.1" and cfg.listenPort == 1234
  var cli = CliOptions(configPath: "/x", hasAddress: true, address: "127.0.0.1",
                       hasPort: true, port: 4011, hasLog: true, logPath: "/tmp/b.jsonl")
  applyCli(cfg, cli)
  check "CLI beats config",
    cfg.listenHost == "127.0.0.1" and cfg.listenPort == 4011 and
    cfg.logPath == "/tmp/b.jsonl"

checkRaises "no log path anywhere exits 2", ConfigError:
  var cfg = Config(listenHost: "127.0.0.1",
                   legs: @[Leg(name: "a", baseUrl: "http://127.0.0.1:1/v1")])
  applyCli(cfg, CliOptions(configPath: "/x"))

# --------------------------------------------------------------- upstream IO ---

check "usage is read from the provider body",
  usageTokens("""{"usage":{"prompt_tokens":11,"completion_tokens":7}}""") ==
    (some(11), some(7))

check "absent usage is null, never zero",
  usageTokens("""{"choices":[]}""") == (none(int), none(int))

check "stream is read from the caller body", wantsStream("""{"stream":true}""")
check "a non-JSON body is not a stream", not wantsStream("not json")

# ------------------------------------------------------------ classification ---

check "401 is the availability class", failureToken(401, "") == "auth_401"
check "400 with MissingSessionID is its own class",
  failureToken(400, """{"error":{"message":"MissingSessionID"}}""") == "missing_session_id"
check "a 400 that is not MissingSessionID is a client error",
  failureToken(400, """{"error":{"message":"model flash does not exist"}}""") == ""
check "403 is a client error and never fails over", failureToken(403, "") == ""
check "404 is a client error and never fails over", failureToken(404, "") == ""
check "429 with a quota body is the capacity class",
  failureToken(429, """{"error":{"type":"GoUsageLimitError"}}""") == "quota_429"
check "429 without a quota body is a client error (D9.3)",
  failureToken(429, """{"error":{"message":"Rate limit reached for requests per minute (RPM).","type":"requests"}}""") == ""
check "503 is upstream_5xx", failureToken(503, "") == "upstream_5xx"
check "502 with an HTML body is upstream_5xx",
  failureToken(502, "<html>bad gateway</html>") == "upstream_5xx"
check "a 200 is not a failure", failureToken(200, "") == ""

check "the quota body is recognised in its other spellings",
  isQuotaBody("insufficient_quota") and isQuotaBody("you are over your usage limit")
check "a plain rate limit is not a quota body",
  not isQuotaBody("Rate limit reached for requests per minute")

# ---------------------------------------------------------------- R10 inject ---

const StreamRequest = """{
  "model": "flash",
  "stream": true,
  "messages": [
    {
      "role": "user",
      "content": "PROMPT-PLACEHOLDER"
    }
  ],
  "temperature": 0
}"""

block:
  let injected = injectIncludeUsage(StreamRequest)
  let parsed = parseJson(injected)
  check "R10 injects include_usage on a stream",
    parsed{"stream_options"}{"include_usage"}.getBool()
  var stripped = parsed
  stripped.delete("stream_options")
  check "R10 changes nothing else in the request",
    $stripped == $parseJson(StreamRequest)
  check "R10 does not inject twice",
    injectIncludeUsage(injected) == injected
  check "R10 leaves a non-object body alone", injectIncludeUsage("[]") == "[]"
  check "R10 keeps an empty object valid", injectIncludeUsage("{}") ==
    """{"stream_options":{"include_usage":true}}"""

block:
  # DEC-10: the leg's model id replaces the caller's, and the rest of the bytes
  # stay as the caller wrote them.
  let rewritten = rewriteModel(StreamRequest, "deepseek/deepseek-v4-1-flash")
  check "3c the leg model replaces the caller's",
    parseJson(rewritten){"model"}.getStr() == "deepseek/deepseek-v4-1-flash"
  check "3c every other byte survives the rewrite",
    rewritten.replace("\"deepseek/deepseek-v4-1-flash\"", "\"flash\"") == StreamRequest
  check "3c a nested model key is not the one replaced",
    rewriteModel("""{"messages":[{"model":"inner"}],"model":"outer"}""", "leg-model") ==
      """{"messages":[{"model":"inner"}],"model":"leg-model"}"""
  check "3c a body with no model key is untouched",
    rewriteModel("""{"messages":[]}""", "leg-model") == """{"messages":[]}"""
  check "3c a non-string model is left alone",
    rewriteModel("""{"model":7}""", "leg-model") == """{"model":7}"""
  check "3c an empty leg model is a no-op",
    rewriteModel(StreamRequest, "") == StreamRequest
  check "3c the rewrite is valid JSON with a quote in the id",
    parseJson(rewriteModel("""{"model":"x"}""", "a\"b")){"model"}.getStr() == "a\"b"
  check "3c a string value named model before the key is ignored",
    rewriteModel("""{"foo":"model","model":"caller-id"}""", "leg-model") ==
      """{"foo":"model","model":"leg-model"}"""
  check "3c an array element named model before the key is ignored",
    rewriteModel("""{"stop":["model"],"model":"caller-id"}""", "leg-model") ==
      """{"stop":["model"],"model":"leg-model"}"""
  check "3c an escaped model key is rewritten",
    rewriteModel("""{"\u006dodel":"caller-id"}""", "leg-model") ==
      """{"\u006dodel":"leg-model"}"""
  check "3c duplicate top-level model keys are both rewritten",
    rewriteModel("""{"model":"c1","model":"c2"}""", "leg-model") ==
      """{"model":"leg-model","model":"leg-model"}"""
  check "3c top-level array is not treated as top-level object",
    rewriteModel("""[{"model":"caller-id"}]""", "leg-model") ==
      """[{"model":"caller-id"}]"""

# ------------------------------------------------------------------- effort ---

block:
  # Item 4: the leg's ceiling. Rank order is minimal < none < low < medium <
  # high < xhigh < max, so a value above the leg's list is pulled DOWN to the
  # highest member still below it, never up.
  let wide = Leg(name: "wide", hasEfforts: true,
                 efforts: @["low", "high", "max"])
  let narrow = Leg(name: "narrow", hasEfforts: true, efforts: @["low", "high"])
  check "effort: a member of the leg's list is sent as asked",
    decideEffort(wide, "high") == EffortDecision(sent: "high", clamped: false,
                                                 skip: false)
  check "effort: max above a low/high list clamps to high",
    decideEffort(narrow, "max") == EffortDecision(sent: "high", clamped: true,
                                                  skip: false)
  check "effort: medium clamps DOWN to low, not up to high",
    decideEffort(wide, "medium") == EffortDecision(sent: "low", clamped: true,
                                                   skip: false)
  check "effort: xhigh clamps to high, because max is not below it",
    decideEffort(wide, "xhigh") == EffortDecision(sent: "high", clamped: true,
                                                  skip: false)
  check "effort: max on a list that has max is sent as asked",
    decideEffort(wide, "max") == EffortDecision(sent: "max", clamped: false,
                                                skip: false)

  let highOnly = Leg(name: "highOnly", hasEfforts: true,
                     efforts: @["high", "max"])
  check "effort: low against high/max is a skip, never an upgrade",
    decideEffort(highOnly, "low") == EffortDecision(sent: "", clamped: false,
                                                    skip: true)
  check "effort: an empty effort list skips every ranked request",
    decideEffort(Leg(name: "none", hasEfforts: true, efforts: @[]),
                 "high").skip

  let open = Leg(name: "open")
  check "effort: a leg with no efforts key passes the value through",
    decideEffort(open, "max") == EffortDecision(sent: "max", clamped: false,
                                                skip: false)
  check "effort: a caller with no effort is passed through untouched",
    decideEffort(wide, "") == EffortDecision(sent: "", clamped: false,
                                             skip: false)
  check "effort: an unranked value is forwarded, not guessed at",
    decideEffort(wide, "turbo") == EffortDecision(sent: "turbo", clamped: false,
                                                  skip: false)

block:
  check "effort: rank order matches the agreed ladder",
    EffortRanks == @["minimal", "none", "low", "medium", "high", "xhigh", "max"]
  check "effort: an unknown name has no rank", effortRank("turbo") == -1

block:
  # The stop is decided from two separate counts, never by comparing one counter
  # with the walk length: a leg skipped for an unmapped alias must not hide the
  # effort skip that ended the request.
  check "effort stop: zero dials plus one effort skip is a stop",
    effortStopWithoutDial(0, 1)
  check "effort stop: zero dials plus no effort skip is not a stop",
    not effortStopWithoutDial(0, 0)
  check "effort stop: a dialled leg keeps the 502 even after an effort skip",
    not effortStopWithoutDial(1, 1)
  check "effort stop: a partly mapped alias still stops with no dial",
    effortStopWithoutDial(0, 2)

block:
  # D9's window counter: the 400 that names the caller's effort dialled nothing,
  # so it moves no availability; a skip the walk served past still counts.
  check "availability: an effort stop does not count",
    not countsTowardAvailability(true, true)
  check "availability: a served-past skip still counts",
    countsTowardAvailability(true, false)
  check "availability: a request with no failover never counts",
    not countsTowardAvailability(false, false)

block:
  # The clamp is a textual rewrite of one key, so every other byte survives.
  let body = """{"model":"x","reasoning_effort":"max","messages":[]}"""
  let clamped = rewriteTopLevelString(body, "reasoning_effort", "high")
  check "effort: the clamp rewrites the top-level value",
    parseJson(clamped){"reasoning_effort"}.getStr() == "high"
  check "effort: the clamp leaves every other byte alone",
    clamped.replace("\"high\"", "\"max\"") == body
  check "effort: the clamp does not touch a nested reasoning_effort",
    rewriteTopLevelString(
      """{"a":{"reasoning_effort":"max"},"reasoning_effort":"max"}""",
      "reasoning_effort", "low") ==
      """{"a":{"reasoning_effort":"max"},"reasoning_effort":"low"}"""
  check "effort: a body without the key is untouched",
    rewriteTopLevelString("""{"model":"x"}""", "reasoning_effort", "low") ==
      """{"model":"x"}"""
  check "effort: a non-string effort is left alone",
    rewriteTopLevelString("""{"reasoning_effort":3}""", "reasoning_effort",
                          "low") == """{"reasoning_effort":3}"""

block:
  check "effort: the caller's value is read from the body",
    requestEffort("""{"reasoning_effort":"medium"}""") == "medium"
  check "effort: a body with no field reads as empty",
    requestEffort("""{"model":"x"}""") == ""
  check "effort: a non-string field reads as empty",
    requestEffort("""{"reasoning_effort":7}""") == ""

block:
  let clampedLine = requestLogLine("t", "leg", 200, 1, none(int), none(int), "",
                                   "", false, "", "max>high")
  check "effort: a clamp adds the eleventh key",
    clampedLine.endsWith("\"effort_clamped\":\"max>high\"}")
  check "effort: a clamped line has no alias key unless the caller named one",
    not clampedLine.contains("\"alias\"")
  check "effort: a line without a clamp keeps the nine keys",
    requestLogLine("t", "leg", 200, 1, none(int), none(int), "", "", false) ==
      "{\"ts\":\"t\",\"route\":\"leg\",\"status\":200,\"latency_ms\":1," &
      "\"tokens_in\":null,\"tokens_out\":null,\"failover_from\":\"\"," &
      "\"failover_reason\":\"\",\"stream\":false}"
  let clampedRow = buildLogRow(parseJson(clampedLine))
  check "effort: the row projection keeps the clamp",
    clampedRow{"effort_clamped"} != nil and
      clampedRow{"effort_clamped"}.getStr() == "max>high"
  let plainRow = buildLogRow(parseJson(requestLogLine("t", "leg", 200, 1,
                                                      none(int), none(int),
                                                      "", "", false)))
  check "effort: the row projection does not invent a clamp",
    plainRow{"effort_clamped"} == nil

# ---------------------------------------------------------------- the router ---

proc makeGateway(legs: seq[Leg], balance: bool): Gateway =
  var cfg = Config(listenHost: "127.0.0.1", listenPort: 4011,
                   logPath: "/tmp/unused.jsonl", balance: balance)
  cfg.legs = legs
  newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")

proc legSpec(name: string, role: LegRole): Leg =
  Leg(name: name, baseUrl: "http://127.0.0.1:1/v1", model: name, role: role,
      weight: 1, enabled: true)

block:
  let gateway = makeGateway(@[legSpec("a", lrPrimary), legSpec("b", lrPrimary),
                              legSpec("c", lrFallback)], balance = false)
  check "strict order: the walk is the config order",
    gateway.pickOrder() == @[0, 1, 2]
  gateway.startCooldown(0, "conn_refused")
  check "a cooling leg is skipped and consumes no turn",
    gateway.pickOrder() == @[1, 2]

block:
  let gateway = makeGateway(@[legSpec("a", lrPrimary), legSpec("b", lrPrimary),
                              legSpec("c", lrFallback)], balance = true)
  var picks: seq[int]
  for _ in 1 .. 6:
    picks.add gateway.pickOrder()[0]
  check "balancing alternates the two primaries", picks == @[0, 1, 0, 1, 0, 1]
  check "the fallback is never picked while a primary is ok",
    gateway.pickOrder() == @[0, 1, 2]

block:
  let gateway = makeGateway(@[legSpec("a", lrPrimary), legSpec("b", lrPrimary),
                              legSpec("c", lrFallback)], balance = true)
  discard gateway.pickOrder()
  gateway.startCooldown(0, "auth_401")
  let walk = gateway.pickOrder()
  check "a dead primary hands the request to the other primary first",
    walk == @[1, 2]
  gateway.startCooldown(1, "auth_401")
  check "both primaries cooling leaves only the fallback",
    gateway.pickOrder() == @[2]
  gateway.startCooldown(2, "auth_401")
  check "every leg cooling means no dial at all", gateway.pickOrder().len == 0

block:
  let gateway = makeGateway(@[legSpec("a", lrPrimary), legSpec("b", lrPrimary)],
                            balance = true)
  gateway.startCooldown(0, "quota_429")
  check "a quota cooldown is 900 s, not 60",
    gateway.legs[0].coolingUntil - epochTime() > 890.0
  gateway.legs[0].coolingUntil = epochTime() - 1.0   # the cooldown expired
  check "an expired cooldown is eligible again", gateway.legAvailable(0, epochTime())
  gateway.legs[0].probeInFlight = true
  check "only one half-open probe is in flight at a time",
    not gateway.legAvailable(0, epochTime())
  gateway.legs[0].probeInFlight = false
  gateway.startCooldown(0, "quota_429")
  check "a second quota failure re-cools the leg for another 900 s",
    gateway.legs[0].coolingUntil - epochTime() > 890.0

block:
  let gateway = makeGateway(@[legSpec("a", lrPrimary)], balance = true)
  check "a fresh leg is unknown", legStateName(gateway.legs[0], epochTime()) == "unknown"
  gateway.startCooldown(0, "upstream_5xx")
  check "a failed leg is cooling, never dead",
    legStateName(gateway.legs[0], epochTime()) == "cooling"
  check "last_failure_class is the §3 token",
    gateway.legs[0].lastFailureClass == "upstream_5xx"
  check "the failure counter moved once", gateway.legs[0].failedInWindow == 1
  gateway.legs[0].coolingUntil = epochTime() - 1.0
  check "an expired cooldown reads as ok, not cooling",
    legStateName(gateway.legs[0], epochTime()) == "ok"
  gateway.markServed(0, 12)
  check "a served request clears the cooldown", gateway.legs[0].coolingUntil == 0.0
  check "a served request moves the served counter", gateway.legs[0].servedInWindow == 1
  check "a served request fills the latency ring", gateway.legs[0].latencies == @[12]

block:
  let gateway = makeGateway(@[legSpec("a", lrPrimary)], balance = true)
  gateway.legs[0].attempted = true
  check "an attempted leg that never failed and never served is ok",
    legStateName(gateway.legs[0], epochTime()) == "ok"

# ------------------------------------------------------------- admin surface ---

block:
  check "redactUrl keeps a clean base URL",
    redactUrl("https://opencode.ai/inference/go/openai/v1") ==
      "https://opencode.ai/inference/go/openai/v1"
  check "redactUrl drops a query that carries a key",
    redactUrl("https://example.test/v1?api_key=abc") == "https://example.test/v1"

block:
  check "parseRfc3339 reads a +07:00 offset",
    parseRfc3339("2026-11-16T09:53:20+07:00").isSome
  check "parseRfc3339 reads the same instant with +00:00",
    parseRfc3339("2026-11-16T02:53:20+00:00") ==
      parseRfc3339("2026-11-16T09:53:20+07:00")
  check "parseRfc3339 tolerates fractional seconds",
    parseRfc3339("2026-11-16T02:53:20.123456+00:00").isSome
  check "parseRfc3339 rejects a non-instant", parseRfc3339("not-a-time").isNone

block:
  let line = """{"ts":"2026-11-16T09:53:20+07:00","route":"a","status":200,""" &
    """"latency_ms":4,"tokens_in":null,"tokens_out":null,"failover_from":""" &
    """"","failover_reason":"","stream":false,"extra":"dropped"}"""
  let row = buildLogRow(parseJson(line))
  check "a row is exactly the nine keys in order",
    ($row).startsWith("{\"ts\":\"2026-11-16T09:53:20+07:00\",\"route\":\"a\"," &
      "\"status\":200,\"latency_ms\":4,\"tokens_in\":null,\"tokens_out\":null," &
      "\"failover_from\":\"\",\"failover_reason\":\"\",\"stream\":false}")
  check "an extra key on a line is dropped", row{"extra"} == nil

block:
  let node = parseJson("""{"ts":"2026-11-16T09:53:20+07:00","route":"a",""" &
    """"status":404,"tokens_in":1,"tokens_out":2,"failover_from":""" &
    """"","failover_reason":"auth_401","stream":true}""")
  var filter = LogFilter(stream: -1)
  check "no filter matches every row", rowMatches(node, filter)
  filter = LogFilter(stream: -1, hasRoute: true, route: "b")
  check "route filter rejects a different leg", not rowMatches(node, filter)
  filter = LogFilter(stream: -1, statusClass: 4)
  check "status_class 4xx matches a 404", rowMatches(node, filter)
  filter = LogFilter(stream: -1, statusClass: 2)
  check "status_class 2xx rejects a 404", not rowMatches(node, filter)
  filter = LogFilter(stream: -1, hasReason: true, reason: "auth_401")
  check "reason filter matches the token", rowMatches(node, filter)
  filter = LogFilter(stream: 0)
  check "stream false rejects a streamed row", not rowMatches(node, filter)
  filter = LogFilter(stream: -1, hasSince: true,
                     sinceEpoch: parseRfc3339("2026-11-16T09:53:21+07:00").get)
  check "since excludes an older row", not rowMatches(node, filter)

block:
  var content = ""
  for index in 0 ..< 60:
    content.add("{\"ts\":\"2026-11-16T09:" & align($index, 2, '0') &
      ":00+07:00\",\"route\":\"b\",\"status\":200,\"latency_ms\":" & $index &
      ",\"tokens_in\":1,\"tokens_out\":2,\"failover_from\":\"\"," &
      "\"failover_reason\":\"\",\"stream\":false}\n")
  let path = writeConfig("requests.jsonl", content)
  let total = kori.countLines(path)
  check "countLines counts every line", total == 60
  let page = readLogTail(path, total, 0, 10, LogFilter(stream: -1))
  check "a ten-row page has ten rows", page.rows.len == 10
  check "the page is newest first", page.rows[0]{"latency_ms"}.getInt == 59
  check "the scan did not cover the file", page.linesScanned <= 15
  check "there are older lines behind the page", page.moreOlder
  let second = readLogTail(path, total, 10, 10, LogFilter(stream: -1))
  check "offset 10 starts at the eleventh line from the end",
    second.rows[0]{"latency_ms"}.getInt == 49
  check "the two pages share no row",
    second.rows[0]{"latency_ms"}.getInt != page.rows[9]{"latency_ms"}.getInt
  let whole = readLogTail(path, total, 0, 200, LogFilter(stream: -1))
  check "a limit past the file returns every line and no more_older",
    whole.rows.len == 60 and not whole.moreOlder
  let missing = readLogTail(scratch / "absent.jsonl", 0, 0, 10,
                            LogFilter(stream: -1))
  check "a missing log is reported, not raised",
    not missing.exists and missing.rows.len == 0

# ------------------------------------------------------------- static surface ---

check "the root serves index.html", resolveStaticPath("/") == "/index.html"
check "an empty path serves index.html", resolveStaticPath("") == "/index.html"
check "a page path is looked up unchanged",
  resolveStaticPath("/requests.html") == "/requests.html"
check "a missing page is not an index fallback",
  resolveStaticPath("/nope.html") == "/nope.html"
check "a traversal attempt is only a key that is not present",
  resolveStaticPath("/../kori.nim") == "/../kori.nim"
check "an encoded traversal is not normalised into a real path",
  resolveStaticPath("/%2e%2e/kori.nim") == "/%2e%2e/kori.nim"

check "a hashed asset is immutable",
  cacheControlFor("/assets/main-3LGz82B_.css") == StaticAssetCache
check "a font keeps its name, so it is not immutable",
  cacheControlFor("/fonts/inter-latin-var.woff2") == StaticFontCache
check "a page is never cached across a deploy",
  cacheControlFor("/index.html") == StaticNoStore
check "the root path is no-store too, because it is a page",
  cacheControlFor(resolveStaticPath("/")) == StaticNoStore

# The committed module must be the one the binary serves, so a page the dist has
# cannot be missing from the table and a page the table has cannot be missing from
# the dist. This is the drift check in test form, for the four pages and the two
# assets that are named in the shell.
block:
  let table = staticFileTable()
  for path in ["/index.html", "/requests.html", "/routes.html", "/config.html",
               "/assets/main-3LGz82B_.css", "/assets/main-3kqSlnGk.js",
               "/fonts/inter-latin-var.woff2", "/fonts/jetbrains-mono-latin-var.woff2"]:
    check "the embedded table carries " & path, table.hasKey(path)
  check "every embedded page is html",
    table["/index.html"].contentType.startsWith("text/html")
  check "the two fonts are woff2",
    table["/fonts/inter-latin-var.woff2"].contentType == "font/woff2"
  check "an embedded body is not empty", table["/index.html"].body.len > 0
  check "no path in the table is a directory or a traversal",
    table.keys().toSeq().allIt(it.startsWith("/") and not it.contains(".."))

# --------------------------------------------------------- alias and enabled ---

block:
  let path = writeConfig("alias.json", """
{"legs":[
 {"name":"leg-a","base_url":"http://127.0.0.1:1/v1","model":"prov-a",
  "aliases":{"fast":"prov-a-fast","deep":"prov-a-deep"}},
 {"name":"leg-b","base_url":"http://127.0.0.1:2/v1","enabled":false,
  "aliases":{"fast":"prov-b-fast"}}]}
""")
  let cfg = loadConfig(path)
  check "a leg is enabled unless the config says otherwise", cfg.legs[0].enabled
  check "enabled false is read", not cfg.legs[1].enabled
  check "aliases are read per leg", cfg.legs[0].aliases["fast"] == "prov-a-fast"
  check "a leg's alias table is only its own", not cfg.legs[1].aliases.hasKey("deep")

checkRaises "a non-boolean enabled is rejected", ConfigError:
  discard loadConfig(writeConfig("bad-enabled.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","enabled":"yes"}]}
"""))

checkRaises "a non-object aliases is rejected", ConfigError:
  discard loadConfig(writeConfig("bad-aliases.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","aliases":["fast"]}]}
"""))

checkRaises "an empty alias target is rejected", ConfigError:
  discard loadConfig(writeConfig("bad-alias-value.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","aliases":{"fast":""}}]}
"""))

# ------------------------------------------------------------- effort config ---

block:
  let cfg = loadConfig(writeConfig("efforts.json", """
{"legs":[
 {"name":"leg-a","base_url":"http://127.0.0.1:1/v1","efforts":["low","high","max"]},
 {"name":"leg-b","base_url":"http://127.0.0.1:2/v1"}]}
"""))
  check "efforts are read per leg", cfg.legs[0].efforts == @["low", "high", "max"]
  check "a leg with an efforts key has a ceiling", cfg.legs[0].hasEfforts
  check "a leg with no efforts key has none", not cfg.legs[1].hasEfforts

checkRaises "an effort outside the rank table is rejected", ConfigError:
  discard loadConfig(writeConfig("bad-efforts.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","efforts":["low","turbo"]}]}
"""))

checkRaises "a non-array efforts is rejected", ConfigError:
  discard loadConfig(writeConfig("bad-efforts-type.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","efforts":"low"}]}
"""))

checkRaises "a non-string effort is rejected", ConfigError:
  discard loadConfig(writeConfig("bad-efforts-value.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","efforts":[3]}]}
"""))

check "kori/<alias> names an alias", aliasOf("kori/fast") == some("fast")
check "a provider id is not an alias", aliasOf("flash").isNone
check "an alias may carry a slash", aliasOf("kori/fast/mini") == some("fast/mini")
check "an empty alias name is still an alias", aliasOf("kori/") == some("")
check "requestModel reads the caller's top-level model",
  requestModel(StreamRequest) == "flash"
check "requestModel is empty when the body has none",
  requestModel("""{"messages":[]}""") == ""
check "requestModel survives a body that is not JSON", requestModel("not json") == ""

block:
  let cfg = loadConfig(writeConfig("alias-map.json", """
{"legs":[
 {"name":"leg-a","base_url":"http://127.0.0.1:1/v1","aliases":{"fast":"prov-a-fast"}},
 {"name":"leg-b","base_url":"http://127.0.0.1:2/v1","aliases":{"deep":"prov-b-deep"}}]}
"""))
  check "a leg resolves the alias it maps",
    aliasModel(cfg.legs[0], "fast") == some("prov-a-fast")
  check "a leg with no mapping resolves to none",
    aliasModel(cfg.legs[0], "deep").isNone
  check "the unknown-alias body names the alias and the type",
    unknownAliasBody("nope").contains("\"type\":\"unknown_alias\"") and
      unknownAliasBody("nope").contains("nope")

block:
  var a = legSpec("a", lrPrimary)
  var b = legSpec("b", lrPrimary)
  b.enabled = false
  let gateway = makeGateway(@[a, b], balance = false)
  check "a disabled leg is never available", not gateway.legAvailable(1, epochTime())
  check "a disabled leg is skipped without changing the order",
    gateway.pickOrder() == @[0]
  check "a disabled leg reads as skipped",
    legStateName(gateway.legs[1], epochTime(), b.enabled) == "skipped"
  check "an enabled leg keeps its own state",
    legStateName(gateway.legs[0], epochTime(), a.enabled) == "unknown"

# --------------------------------------------------------------------- report ---

removeDir(scratch)
if failures == 0:
  echo "\nall checks passed"
  quit(0)
echo "\n", failures, " check(s) failed"
quit(1)
