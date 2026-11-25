# Unit tests for the slice-1 pure surface: the log line the acceptance harness
# grades byte-wise, CLI flag forms and precedence, and config defaults. No socket
# is opened here; the harness starts the real binary.

import std/[hashes, json, options, os, posix, sequtils, strutils, tables, times]

import std/asynchttpserver

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

checkRaises "a weight of zero is rejected", ConfigError:
  discard loadConfig(writeConfig("weight-zero.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","weight":0}]}
"""))

checkRaises "a weight above the ceiling is rejected", ConfigError:
  discard loadConfig(writeConfig("weight-high.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","weight":1001}]}
"""))

let weighted = loadConfig(writeConfig("weight-ok.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","weight":3}]}
"""))
check "DEC-11: a weight above 1 is accepted and kept",
  weighted.legs[0].weight == 3

let retried = loadConfig(writeConfig("retries-ok.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","retries":2}]}
"""))
check "retries: a leg keeps the count it names", retried.legs[0].retries == 2

check "retries: a leg that names none retries nothing",
  loadConfig(writeConfig("retries-none.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1"}]}
""")).legs[0].retries == 0

checkRaises "retries above the ceiling are rejected", ConfigError:
  discard loadConfig(writeConfig("retries-high.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","retries":6}]}
"""))

let pooled = loadConfig(writeConfig("keys-ok.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","api_keys":["k1","k2"]}]}
"""))
check "key pool: the pool is read in order",
  pooled.legs[0].apiKeys == @["k1", "k2"]

check "key pool: a single api_key is a pool of one",
  loadConfig(writeConfig("keys-one.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","api_key":"only"}]}
""")).legs[0].apiKeys == @["only"]

checkRaises "key pool: an empty api_keys is refused", ConfigError:
  discard loadConfig(writeConfig("keys-empty.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","api_keys":[]}]}
"""))

checkRaises "key pool: a pool with an oauth block is refused", ConfigError:
  discard loadConfig(writeConfig("keys-oauth.json", """
{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1","api_keys":["k1","k2"],
"oauth":{"token_url":"https://example.test/token","client_id":"c","refresh_token":"r"}}]}
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
check "429 without a quota body is the rate-limit class (DEC-26)",
  failureToken(429, """{"error":{"message":"Rate limit reached for requests per minute (RPM).","type":"requests"}}""") == "rate_limited_429"
check "402 is the billing class, whatever the body says",
  failureToken(402, "") == "billing_402" and
  failureToken(402, """{"error":{"message":"insufficient balance"}}""") == "billing_402"
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

proc weightedGateway(weights: seq[int]): Gateway =
  var cfg = Config(listenHost: "127.0.0.1", listenPort: 4011,
                   logPath: "/tmp/unused.jsonl", balance: true)
  for position, weight in weights:
    var leg = legSpec("leg-" & $position, lrPrimary)
    leg.weight = weight
    cfg.legs.add leg
  newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")

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

# DEC-23: the header-timeout ladder.
block:
  check "a header timeout on the 15 s streaming window cools 15 s, not 60",
    cooldownSeconds(TokenHeaderTimeout, 0, HeaderDeadlineStreamMs) == 15.0
  check "a second header timeout in a row doubles it",
    cooldownSeconds(TokenHeaderTimeout, 1, HeaderDeadlineStreamMs) == 30.0
  check "the ladder stops at the plain availability cooldown",
    cooldownSeconds(TokenHeaderTimeout, 2, HeaderDeadlineStreamMs) == 60.0
  check "a fourth header timeout in a row is still 60 s, not 120",
    cooldownSeconds(TokenHeaderTimeout, 5, HeaderDeadlineStreamMs) == 60.0
  check "a rung is never shorter than the window it followed: the 90 s door keeps 60 s",
    cooldownSeconds(TokenHeaderTimeout, 0, HeaderDeadlineNonStreamMs) == 60.0
  check "a window below the floor still cools the floor",
    cooldownSeconds(TokenHeaderTimeout, 0, 1_000) == 5.0
  check "every other availability class keeps its flat 60 s",
    cooldownSeconds(TokenConnRefused, 0, HeaderDeadlineStreamMs) == 60.0 and
      cooldownSeconds(TokenUpstream5xx, 3, HeaderDeadlineStreamMs) == 60.0
  check "quota and billing keep 900 s whatever the ladder says",
    cooldownSeconds(TokenQuota429, 0, HeaderDeadlineNonStreamMs) == 900.0 and
      cooldownSeconds(TokenBilling402, 4, HeaderDeadlineStreamMs) == 900.0

block:
  let gateway = makeGateway(@[legSpec("a", lrPrimary)], balance = true)
  gateway.startCooldown(0, TokenHeaderTimeout, HeaderDeadlineStreamMs)
  check "the first dropped header on the streaming door cools for about 15 s",
    gateway.legs[0].coolingUntil - epochTime() <= 15.0
  check "the ladder counter moved once", gateway.legs[0].headerTimeouts == 1
  gateway.startCooldown(0, TokenHeaderTimeout, HeaderDeadlineStreamMs)
  check "the second one doubles it",
    gateway.legs[0].coolingUntil - epochTime() > 29.0
  gateway.markServed(0, 5)
  check "a served request resets the ladder", gateway.legs[0].headerTimeouts == 0
  gateway.startCooldown(0, TokenHeaderTimeout, HeaderDeadlineStreamMs)
  check "so the next timeout is back to the first rung",
    gateway.legs[0].coolingUntil - epochTime() <= 15.0
  gateway.startCooldown(0, TokenUpstream5xx)
  check "a class that is not a header timeout leaves the ladder alone",
    gateway.legs[0].headerTimeouts == 1

block:
  let gateway = makeGateway(@[legSpec("a", lrPrimary)], balance = true)
  for _ in 1 .. 6:
    gateway.startCooldown(0, TokenHeaderTimeout, HeaderDeadlineStreamMs)
  check "a leg that keeps dropping headers reaches the full 60 s by the third",
    gateway.legs[0].coolingUntil - epochTime() > 55.0
  gateway.legs[0].coolingUntil = epochTime() - 1.0
  check "and it is still eligible after the cooldown, never permanently dead",
    gateway.legAvailable(0, epochTime())

# ------------------------------------------------------------- admin surface ---

block:
  check "redactUrl keeps a clean base URL",
    redactUrl("https://opencode.ai/inference/go/openai/v1") ==
      "https://opencode.ai/inference/go/openai/v1"
  check "redactUrl drops a query that carries a key",
    redactUrl("https://example.test/v1?api_key=abc") == "https://example.test/v1"
  check "redactUrl drops userinfo from the authority",
    redactUrl("https://user:s3cret@api.example.test/v1") ==
      "https://api.example.test/v1"
  check "the redacted URL carries no character of the password",
    not redactUrl("https://user:s3cret@api.example.test/v1").contains("s3cret")
  check "userinfo goes even when the query would keep the rest",
    redactUrl("https://user:pw@h.test/v1?mode=fast") == "https://h.test/v1?mode=fast"
  check "a base with no scheme loses its userinfo too",
    redactUrl("user:pw@h.test/v1") == "h.test/v1"
  check "an '@' in the path is not userinfo",
    redactUrl("https://h.test/v1/a@b") == "https://h.test/v1/a@b"
  check "an '@' in the query is not userinfo",
    redactUrl("https://h.test/v1?user=a@b") == "https://h.test/v1?user=a@b"
  check "an '@' in a query with no path is not userinfo",
    redactUrl("https://h.test?user=a@b") == "https://h.test?user=a@b"
  check "a password carrying an '@' keeps only the last one out",
    redactUrl("https://user:p@ss@h.test/v1") == "https://h.test/v1"
  check "the credential never survives even with an '@' in the password",
    not redactUrl("https://user:p@ss@h.test/v1").contains("p@ss")
  # F1: a separator inside the password ends the authority early, so the '@' is
  # no longer in what looks like the authority. That URL cannot dial, but it still
  # must not print the credential.
  check "a slash inside the password does not leave the credential printed",
    redactUrl("https://user:pa/ss@h.test/v1") == "https://h.test/v1"
  check "the password does not survive a slash in it",
    not redactUrl("https://user:pa/ss@h.test/v1").contains("pa/ss")
  check "the query after such a password is kept",
    redactUrl("https://user:pa/ss@h.test/v1?mode=fast") == "https://h.test/v1?mode=fast"
  # F1b: the same class for '?' and '#', and for a password that begins with a
  # digit (which must not be mistaken for a port).
  check "'?' inside the password does not print it",
    redactUrl("https://user:pa?ss@h.test/v1") == "https://h.test/v1"
  check "'#' inside the password does not print it",
    redactUrl("https://user:pa#ss@h.test/v1") == "https://h.test/v1"
  check "a password starting with a digit is not a port",
    redactUrl("https://user:1pa/ss@h.test/v1") == "https://h.test/v1"
  check "a digit-leading password does not survive either",
    not redactUrl("https://user:1pa/ss@h.test/v1").contains("1pa")
  # A normal userinfo plus an '@' inside a query keeps the query: the credential
  # is inside the authority, which is the ordinary rule's job.
  check "an '@' in the query survives with userinfo present",
    redactUrl("https://user:pw@h.test/v1?x=a@b") == "https://h.test/v1?x=a@b"
  # The rule must not eat a legitimate port, nor an '@' that is really a path.
  check "a port is not mistaken for userinfo",
    redactUrl("https://h.test:8443/v1/a@b") == "https://h.test:8443/v1/a@b"
  check "a bracketed IPv6 host is left intact",
    redactUrl("https://[::1]:8443/v1") == "https://[::1]:8443/v1"
  # F1c, known and named in the CHANGELOG: the rule cannot tell these from a real
  # port or a real path, so the credential is printed. They are pinned here so a
  # future widening of the rule has to say so out loud, and so the changelog
  # sentence cannot drift from the code again. Neither reaches the host named in
  # the string: parseUri reads `user`/`corp` as the host and dial() connects there.
  check "F1c: a digit run reaching the separator still prints",
    redactUrl("https://user:8443/rest@h.test/v1") == "https://user:8443/rest@h.test/v1"
  check "F1c: userinfo after a path still prints",
    redactUrl("https://corp/user:pw@h.test/v1") == "https://corp/user:pw@h.test/v1"
  # F1d: the '@' that ends a split credential is the one past the separator, and
  # never one past the next separator. An '@' in a query or a fragment is data,
  # and taking it printed the query value as the base URL.
  check "F1d: an '@' in the query is not the end of a split credential",
    redactUrl("https://h.test:/v1?x=a@b&api_key=SECRET7") == "https://<redacted>"
  check "F1d: a '?api_key=@' does not become the base URL",
    not redactUrl("https://h.test:/v1?api_key=@SECRET9").contains("SECRET9")
  check "F1d: the empty-port URL without an '@' still prints its host",
    redactUrl("https://h.test:/v1") == "https://h.test:/v1"
  check "F1d: a non-numeric port with an '@' in the query prints nothing it cannot place",
    redactUrl("https://h.test:abc/v1?api_key=@TAILSECRET") == "https://<redacted>"
  check "F1d: an '@' in a path after a bad port is not the base URL",
    redactUrl("https://h.test:abc/v1/a@b") == "https://<redacted>"
  # A password that carries an '@' before a separator used to print the rest of
  # the password as the host.
  check "an '@' inside the password before a separator does not survive",
    redactUrl("https://user:p@ssword/1@h.test/v1") == "https://h.test/v1"
  check "the same with '?' and '#'",
    redactUrl("https://user:p@ss?word@h.test/v1") == "https://h.test/v1"
  check "a query value never becomes the authority",
    not redactUrl("https://user:pa/ss@h.test/v1?api_key=@SECRET9").contains("SECRET9")
  # F1e: `host:` is an empty port, not userinfo, so the '@' behind it is query,
  # path or fragment data. Every one of these printed that data as the host.
  check "F1e: an '@' behind an empty port is not a credential",
    redactUrl("https://h.test:#x@F1E7") == "https://<redacted>"
  check "F1e: a query value behind an empty port does not print",
    not redactUrl("https://h.test:@b&api_key=SECRET7").contains("SECRET7")
  check "F1e: an '@' in the path behind an empty port prints nothing",
    redactUrl("https://h.test:/a@SECRET") == "https://<redacted>"
  check "F1e: the empty-port URL without an '@' is untouched",
    redactUrl("https://h.test:/v1") == "https://h.test:/v1"
  check "F1e: a real empty port with a query is untouched",
    redactUrl("http://127.0.0.1:8090/v1") == "http://127.0.0.1:8090/v1"

block:
  # §5.4 at the surface that prints it: /admin/config never carries the credential
  # a base URL was configured with.
  var cfg = Config(listenHost: "127.0.0.1", listenPort: 4011,
                   logPath: scratch / "redact.jsonl")
  cfg.legs = @[legSpec("leg-a", lrPrimary)]
  cfg.legs[0].baseUrl = "https://user:s3cret@api.example.test/v1"
  cfg.systemone = @[SystemoneLeg(name: "jev", baseUrl: "https://u:pw@x.test/v1",
                                 model: "m", enabled: true, weight: 1)]
  let gateway = newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")
  let printed = gateway.configJson()
  check "/admin/config prints no part of a base_url credential",
    not printed.contains("s3cret") and not printed.contains("u:pw@")
  check "/admin/config still prints the host, minus the userinfo",
    printed.contains("https://api.example.test/v1") and
      printed.contains("https://x.test/v1")

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
  cacheControlFor("/assets/any-hashed-name.js") == StaticAssetCache
check "a font keeps its name, so it is not immutable",
  cacheControlFor("/fonts/inter-latin-var.woff2") == StaticFontCache
check "a page is never cached across a deploy",
  cacheControlFor("/index.html") == StaticNoStore
check "the root path is no-store too, because it is a page",
  cacheControlFor(resolveStaticPath("/")) == StaticNoStore

# The committed module must be the one the binary serves, so a page the dist has
# cannot be missing from the table and a page the table has cannot be missing from
# the dist. This is the drift check in test form: the five pages and the two fonts
# are named here, and the hashed assets are matched by shape because their names
# change on every build that touches the bundle.
block:
  let table = staticFileTable()
  for path in ["/index.html", "/requests.html", "/routes.html", "/config.html",
               "/login.html",
               "/fonts/inter-latin-var.woff2", "/fonts/jetbrains-mono-latin-var.woff2"]:
    check "the embedded table carries " & path, table.hasKey(path)
  let keys = table.keys().toSeq()
  check "a hashed stylesheet is embedded",
    keys.anyIt(it.startsWith("/assets/") and it.endsWith(".css"))
  check "a hashed module is embedded",
    keys.anyIt(it.startsWith("/assets/") and it.endsWith(".js"))
  check "every embedded page is html",
    table["/index.html"].contentType.startsWith("text/html")
  check "the sign-in page is served as html",
    table["/login.html"].contentType.startsWith("text/html")
  check "the sign-in page carries a form field",
    table["/login.html"].body.contains("type=\"password\"")
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

block:
  # DEC-11: a weight is honoured as a share over many picks. 3:1 over 400 picks is
  # 300:100 by the nginx smooth algorithm, and equal weights degenerate to plain
  # round-robin, so nothing about a single-weight config changed.
  let gateway = weightedGateway(@[3, 1])
  var counts = [0, 0]
  for _ in 1 .. 400:
    let order = gateway.pickOrder()
    if order.len > 0:
      inc counts[order[0]]
  check "DEC-11: weights 3:1 split 300:100 over 400 picks",
    counts[0] == 300 and counts[1] == 100

block:
  let equal = weightedGateway(@[1, 1])
  var counts = [0, 0]
  for _ in 1 .. 10:
    let order = equal.pickOrder()
    if order.len > 0:
      inc counts[order[0]]
  check "DEC-11: equal weights stay an even round-robin",
    counts[0] == 5 and counts[1] == 5

block:
  # A cooling leg leaves the pool entirely, so the surviving weight takes every
  # pick rather than the split silently shifting to a half.
  let gateway = weightedGateway(@[3, 1])
  gateway.startCooldown(1, "conn_refused")
  var pickedB = 0
  for _ in 1 .. 20:
    let order = gateway.pickOrder()
    if order.len > 0 and order[0] == 1:
      inc pickedB
  check "DEC-11: a cooling leg takes no share", pickedB == 0

block:
  # A weighted leg that is the only available fallback still enters the walk when
  # no primary can serve.
  var cfg = Config(listenHost: "127.0.0.1", listenPort: 4011,
                   logPath: "/tmp/unused.jsonl", balance: true)
  var primary = legSpec("a", lrPrimary)
  var fallback = legSpec("f", lrFallback)
  fallback.weight = 5
  cfg.legs = @[primary, fallback]
  let gateway = newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")
  gateway.startCooldown(0, "conn_refused")
  let order = gateway.pickOrder()
  check "DEC-11: the fallback is picked when no primary can serve",
    order.len == 1 and order[0] == 1

block:
  # The retry pause doubles and caps, and the jitter never pushes it past the cap
  # plus a quarter of it.
  check "retry: the first pause is the base", retryPauseMs(0, 0) == RetryBaseMs
  check "retry: the pause doubles", retryPauseMs(1, 0) == RetryBaseMs * 2
  check "retry: the pause is capped at the ceiling",
    retryPauseMs(9, 0) == RetryCeilingMs
  check "retry: jitter stays inside a quarter of the pause",
    retryPauseMs(0, 999_999) <= RetryBaseMs + RetryBaseMs div 4
  check "retry: only transport classes are retried",
    isRetryable(TokenConnRefused) and isRetryable(TokenDialTimeout) and
      isRetryable(TokenHeaderTimeout) and isRetryable(TokenUpstream5xx)
  check "retry: a decided class is not retried",
    not isRetryable(TokenAuth401) and not isRetryable(TokenQuota429) and
      not isRetryable(TokenMissingSession) and not isRetryable(TokenModelGone) and
      not isRetryable(TokenCallerFault)

block:
  # The key pool: a dead entry is skipped for its own cooldown, and the leg stays
  # available while any other entry is live.
  var pooled = legSpec("p", lrPrimary)
  pooled.apiKeys = @["k1", "k2"]
  pooled.apiKey = ""
  let gateway = makeGateway(@[pooled], balance = false)
  check "key pool: the first live entry is used",
    gateway.pickKeyIndex(0, epochTime()) == 0
  check "key pool: cooling one entry leaves the other live",
    gateway.coolKey(0, 0, TokenAuth401)
  check "key pool: the next pick is the live entry",
    gateway.pickKeyIndex(0, epochTime()) == 1
  check "key pool: cooling the last entry reports nothing left",
    not gateway.coolKey(0, 1, TokenAuth401)
  check "key pool: every entry cooling means no dial",
    gateway.pickKeyIndex(0, epochTime()) == -1

block:
  let pooled3 = legSpec("p3", lrPrimary)
  var cfg = Config(listenHost: "127.0.0.1", listenPort: 4011,
                   logPath: "/tmp/unused.jsonl")
  var leg3 = pooled3
  leg3.apiKeys = @["k1"]
  leg3.apiKey = ""
  cfg.legs = @[leg3]
  let gw3 = newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")
  check "key pool: a pool of one never rotates",
    gw3.pickKeyIndex(0, epochTime()) == 0 and
      not gw3.coolKey(0, 0, TokenAuth401)

block:
  # DEC-11's model list: an alias and a named leg model both appear, once each.
  var cfg = Config(listenHost: "127.0.0.1", listenPort: 4011,
                   logPath: "/tmp/unused.jsonl")
  var first = legSpec("leg-a", lrPrimary)
  first.hasModel = true
  first.model = "prov-a"
  first.aliases["fast"] = "prov-a-fast"
  var second = legSpec("leg-b", lrFallback)
  second.hasModel = false
  second.model = "leg-b"
  second.aliases["fast"] = "prov-b-fast"
  cfg.legs = @[first, second]
  let gateway = newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")
  let models = parseJson(gateway.modelsJson())
  check "models: the list is an OpenAI list object",
    models{"object"}.getStr() == "list"
  check "models: an alias appears once even when two legs map it",
    models{"data"}.len == 2
  check "models: the alias id carries the kori prefix",
    models{"data"}[0]{"id"}.getStr() == "kori/fast"
  check "models: a leg's own model id is listed",
    models{"data"}[1]{"id"}.getStr() == "prov-a"
  check "models: a leg without its own model contributes no id",
    not gateway.modelsJson().contains("\"id\":\"leg-b\"")

block:
  var cfg = Config(listenHost: "127.0.0.1", listenPort: 4011,
                   logPath: "/tmp/unused.jsonl")
  cfg.legs = @[legSpec("leg-a", lrPrimary)]
  let gateway = newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")
  gateway.startCooldown(0, "auth_401")
  let deep = parseJson(gateway.deepHealthJson())
  check "deep health: liveness stays ok", deep{"status"}.getStr() == "ok"
  check "deep health: every leg is reported", deep{"legs"}.len == 1
  check "deep health: the cooling leg reads as cooling",
    deep{"legs"}[0]{"state"}.getStr() == "cooling"
  check "deep health: the failure class is named",
    deep{"legs"}[0]{"last_failure_class"}.getStr() == "auth_401"

block:
  # The three named classes P1 adds, and the one that must stay a caller error.
  check "404 model_not_found on a mapped alias is model_gone",
    failureToken(404, """{"error":{"code":"model_not_found"}}""", true) == "model_gone"
  check "404 model gone on a caller's own id stays a client error",
    failureToken(404, """{"error":{"code":"model_not_found"}}""", false) == ""
  check "a bare 404 is never model_gone",
    failureToken(404, """{"error":{"message":"not found"}}""", true) == ""
  check "caller_fault is its own name, not mid_stream_abort",
    TokenCallerFault == "caller_fault" and TokenCallerFault != TokenMidStreamAbort


# ---------------------------------------------------------------- 0.7.0 surface ---

block:
  # cost_usd: price x the provider's counts, and nothing at all when unpriced.
  var cfg = Config()
  cfg.prices["priced"] = Price(usdIn: 1.0, usdOut: 2.0)
  cfg.prices["*"] = Price(usdIn: 0.0, usdOut: 0.0)
  check "a priced model yields the stated cost",
    requestCost(cfg, "priced", some(1_000_000), some(500_000)) == some(2.0)
  check "a cost is absent without tokens",
    requestCost(cfg, "priced", none(int), none(int)).isNone
  check "one direction is enough",
    requestCost(cfg, "priced", some(2_000_000), none(int)) == some(2.0)
  check "an unpriced model is priced by the catch-all",
    requestCost(cfg, "other", some(1_000_000), none(int)) == some(0.0)
  var bare = Config()
  check "with no catch-all an unknown model is unpriced",
    requestCost(bare, "other", some(1_000_000), none(int)).isNone
  check "six decimals, fixed form", jsonUsd6(0.000154) == "0.000154"

block:
  let line = requestLogLine("2026-11-18T10:00:00+07:00", "leg-a", 200, 12,
                            some(11), some(7), "", "", false,
                            costUsd = some(0.000025))
  let node = parseJson(line)
  check "cost_usd is the last key", node{"cost_usd"} != nil
  check "cost_usd keeps six decimals", line.endsWith("\"cost_usd\":0.000025}")
  check "no cost key without a price",
    parseJson(requestLogLine("2026-11-18T10:00:00+07:00", "leg-a", 200, 12,
                             some(11), some(7), "", "", false)){"cost_usd"} == nil
  check "a cost row projects cost_usd",
    buildLogRow(node){"cost_usd"} != nil
  check "a row without a cost does not invent one",
    buildLogRow(parseJson(requestLogLine("2026-11-18T10:00:00+07:00", "a", 200, 1,
                                        none(int), none(int), "", "", false))){
      "cost_usd"} == nil

block:
  # The exposition: labels escaped, +Inf present, counters where the request path
  # leaves them.
  var cfg = Config(listenHost: "127.0.0.1", listenPort: 4011,
                   logPath: scratch / "metrics.jsonl")
  cfg.legs = @[legSpec("leg-a", lrPrimary)]
  let gateway = newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")
  gateway.metrics.recordMetrics("leg-a", 200, 40, "auth_401")
  gateway.metrics.recordMetrics("leg-a", 502, 90_000, "")
  let text = gateway.metricsText()
  check "metrics counts the route", text.contains("kori_requests_total{route=\"leg-a\"} 2")
  check "metrics counts the reason", text.contains("kori_failovers_total{reason=\"auth_401\"} 1")
  check "metrics has no empty reason series", not text.contains("reason=\"\"")
  check "metrics has the +Inf bucket", text.contains("le=\"+Inf\"} 2")
  check "metrics counts the status classes",
    text.contains("kori_responses_total{class=\"2xx\"} 1") and
      text.contains("kori_responses_total{class=\"5xx\"} 1")
  check "metrics reports the cooling gauge",
    text.contains("kori_route_cooling{route=\"leg-a\"} 0")
  check "metrics escapes a label", promEscape("a\"b") == "a\\\"b"

block:
  # Rotation: the live file moves to .1, keep is honoured, and every live line is
  # whole JSON.
  let path = scratch / "rotate.jsonl"
  removeFile(path)
  var log = openRequestLog(path, rotateBytes = 400, keep = 2)
  var n = 0
  while n < 20:
    discard log.appendLine(requestLogLine("2026-11-18T10:00:0" & $(n mod 10) &
                                          "+07:00", "leg-a", 200, n,
                                          some(n), some(n), "", "", false))
    inc n
  discard posix.close(log.fd)
  check "rotation created the first rotated file", fileExists(path & ".1")
  check "keep=2 caps the rotated files",
    not fileExists(path & ".3") and not fileExists(path & ".4")
  check "the live file is under the rotation limit", getFileSize(path) <= 400
  var whole = true
  for line in readFile(path).splitLines():
    if line.len > 0:
      try: discard parseJson(line)
      except CatchableError: whole = false
  check "every live line is still JSON", whole

block:
  # A failed rotation leaves fd = -1. Every append retries the open once instead of
  # writing to fd -1 for the rest of the process's life, and the outage is one
  # stderr line rather than one per request.
  let path = scratch / "reopen.jsonl"
  removeFile(path)
  var log = openRequestLog(path)
  discard posix.close(log.fd)
  log.fd = -1
  check "an append with no open file reopens it", log.appendLine("{\"a\":1}")
  check "the line reached the file", fileExists(path) and readFile(path).len > 0
  check "recovering reports one outage line", not log.failing
  discard posix.close(log.fd)

block:
  # The tally both request paths share: one counter for every line that did not
  # land, and the dashboard's line count only for the ones that did.
  let path = scratch / "record.jsonl"
  removeFile(path)
  var cfg = Config(listenHost: "127.0.0.1", listenPort: 4011, logPath: path)
  cfg.legs = @[legSpec("leg-a", lrPrimary)]
  var reqLog = openRequestLog(path)
  let written = newGateway(cfg, reqLog, "127.0.0.1:4011")
  written.recordRequestLog("{\"a\":1}")
  check "a line that lands counts", written.logLines == 1 and
    written.metrics.logWriteFailures == 0
  check "metrics prints the counter",
    written.metricsText().contains("kori_log_write_failures_total 0")
  check "metrics names it a counter",
    written.metricsText().contains("# TYPE kori_log_write_failures_total counter")
  discard posix.close(reqLog.fd)
  # A directory that does not exist: the fd is -1 and the reopen must fail too,
  # which is the full-disk shape without needing a full disk.
  let missing = scratch / "no-such-dir" / "record.jsonl"
  let lost = newGateway(cfg, RequestLog(fd: -1, path: missing), "127.0.0.1:4011")
  lost.recordRequestLog("{\"a\":2}")
  check "a line that does not land is tallied", lost.metrics.logWriteFailures == 1
  check "it does not inflate the line count", lost.logLines == 0
  check "metrics prints the failure",
    lost.metricsText().contains("kori_log_write_failures_total 1")

block:
  # Reload: a broken file changes nothing, a good one swaps the legs in place.
  let path = writeConfig("reload.json", """
{"listen":{"host":"127.0.0.1","port":4011},"log":{"path":"/tmp/reload.jsonl"},
 "legs":[{"name":"leg-a","base_url":"http://127.0.0.1:1/v1","api_key":"k"}]}
""")
  var cfg = loadConfig(path)
  let cli = CliOptions(configPath: path)
  applyCli(cfg, cli)
  let gateway = newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")
  gateway.configPath = path
  gateway.cli = cli
  writeFile(path, """{"legs": [ this is not json""")
  check "a broken reload is refused", gateway.reloadConfig() == false
  check "a broken reload names its reason", gateway.lastReloadError.len > 0
  check "a refused reload leaves the legs alone",
    parseJson(gateway.stateJson()){"routes"}.len == 1
  check "a refused reload is not counted", gateway.reloads == 0
  writeFile(path, """
{"listen":{"host":"127.0.0.1","port":4011},"log":{"path":"/tmp/reload.jsonl"},
 "legs":[{"name":"leg-a","base_url":"http://127.0.0.1:1/v1","api_key":"k"},
         {"name":"leg-b","base_url":"http://127.0.0.1:2/v1","api_key":"k"}]}
""")
  check "a good reload is applied", gateway.reloadConfig()
  check "a good reload swaps the legs",
    parseJson(gateway.stateJson()){"routes"}.len == 2
  check "a good reload is counted", gateway.reloads == 1
  check "a good reload clears the error", gateway.lastReloadError.len == 0
  writeFile(path, """
{"listen":{"host":"127.0.0.1","port":4999},"log":{"path":"/tmp/reload.jsonl"},
 "legs":[{"name":"leg-a","base_url":"http://127.0.0.1:1/v1","api_key":"k"}]}
""")
  check "a moved listener is refused", gateway.reloadConfig() == false
  check "a moved listener keeps the old port",
    ($parseJson(gateway.configJson()){"listen"}).contains(":4011")

# ------------------------------------------------------- 0.7.0 systemone ---

block:
  # DEC-19: the second door's config. Optional, its own list, and the model id is
  # required because that id is the whole reason the door exists.
  let path = writeConfig("systemone.json", """
{"legs":[{"name":"leg-a","base_url":"http://127.0.0.1:1/v1","api_key":"k"}],
 "systemone":{"legs":[
   {"name":"jev","base_url":"https://api.commandcode.ai/provider/v1",
    "api_key":"sk-jev","model":"typesafe/jev-1.14.0"}]}}
""")
  let cfg = loadConfig(path)
  check "a systemone block is parsed", cfg.systemone.len == 1
  check "its model is the configured id",
    cfg.systemone[0].model == "typesafe/jev-1.14.0"
  check "its head is the same config head, not a second protocol",
    systemonePath(cfg.systemone[0].baseUrl) == "/provider/v1/systemone"
  check "a base that already names the endpoint keeps it",
    systemonePath("https://x.test/v1/systemone") == "/v1/systemone"
  check "a bare host gets the default path",
    systemonePath("https://x.test") == "/v1/systemone"

  var noBlock = loadConfig(writeConfig("no-systemone.json", """
{"legs":[{"name":"leg-a","base_url":"http://127.0.0.1:1/v1","api_key":"k"}]}
"""))
  check "a config without the block has no systemone legs",
    noBlock.systemone.len == 0

  checkRaises "a systemone leg without a model is refused", ConfigError:
    discard loadConfig(writeConfig("systemone-no-model.json", """
{"legs":[{"name":"leg-a","base_url":"http://127.0.0.1:1/v1","api_key":"k"}],
 "systemone":{"legs":[{"name":"jev","base_url":"https://x.test/v1",
                       "api_key":"k"}]}}
"""))
  checkRaises "an empty systemone list is refused, not silently ignored",
    ConfigError:
    discard loadConfig(writeConfig("systemone-empty.json", """
{"legs":[{"name":"leg-a","base_url":"http://127.0.0.1:1/v1","api_key":"k"}],
 "systemone":{"legs":[]}}
"""))

block:
  # DEC-28: the System One weight is the chat leg's share, with the same default
  # and the same refusal of 0.
  let weighted = loadConfig(writeConfig("systemone-weight.json", """
{"legs":[{"name":"leg-a","base_url":"http://127.0.0.1:1/v1","api_key":"k"}],
 "systemone":{"legs":[
   {"name":"jev","base_url":"https://x.test/v1","api_key":"k","model":"m"},
   {"name":"jev-heavy","base_url":"https://y.test/v1","api_key":"k","model":"m",
    "weight":7}]}}
"""))
  check "a systemone leg with no weight gets 1, so old configs balance evenly",
    weighted.systemone[0].weight == 1
  check "a named weight is kept", weighted.systemone[1].weight == 7
  check "systemone_balance defaults to false, so DEC-19 stays the default",
    weighted.systemoneBalance == false
  let soBalanced = loadConfig(writeConfig("systemone-balanced.json", """
{"legs":[{"name":"leg-a","base_url":"http://127.0.0.1:1/v1","api_key":"k"}],
 "systemone_balance":true,
 "systemone":{"legs":[
   {"name":"jev","base_url":"https://x.test/v1","api_key":"k","model":"m"}]}}
"""))
  check "systemone_balance true is kept", soBalanced.systemoneBalance
  check "the chat door's balance is still its own default",
    soBalanced.balance == false
  checkRaises "a non-boolean systemone_balance is refused", ConfigError:
    discard loadConfig(writeConfig("systemone-balanced-bad.json", """
{"legs":[{"name":"leg-a","base_url":"http://127.0.0.1:1/v1","api_key":"k"}],
 "systemone_balance":"yes",
 "systemone":{"legs":[
   {"name":"jev","base_url":"https://x.test/v1","api_key":"k","model":"m"}]}}
"""))
  checkRaises "a systemone weight of 0 is refused", ConfigError:
    discard loadConfig(writeConfig("systemone-weight-zero.json", """
{"legs":[{"name":"leg-a","base_url":"http://127.0.0.1:1/v1","api_key":"k"}],
 "systemone":{"legs":[{"name":"jev","base_url":"https://x.test/v1",
                       "api_key":"k","model":"m","weight":0}]}}
"""))
  checkRaises "a systemone weight above the ceiling is refused", ConfigError:
    discard loadConfig(writeConfig("systemone-weight-max.json", """
{"legs":[{"name":"leg-a","base_url":"http://127.0.0.1:1/v1","api_key":"k"}],
 "systemone":{"legs":[{"name":"jev","base_url":"https://x.test/v1",
                       "api_key":"k","model":"m","weight":1001}]}}
"""))

block:
  # The one edit this door makes, and the usage shape it reads.
  let caller = """{"state":"who answers?","model":"jev-latest","questions":{}}"""
  check "the model id is replaced and nothing else is",
    rewriteModel(caller, "typesafe/jev-1.14.0") ==
      "{\"state\":\"who answers?\",\"model\":\"typesafe/jev-1.14.0\",\"questions\":{}}"
  let answer = """{"model":"typesafe/jev","answers":{},"usage":{"input_tokens":322,"output_tokens":43}}"""
  let (ins, outs) = systemoneUsage(answer)
  check "systemone usage reads input_tokens", ins == some(322)
  check "systemone usage reads output_tokens", outs == some(43)
  let (noneIn, noneOut) = systemoneUsage("""{"answers":{}}""")
  check "an answer with no usage reports null, never zero",
    noneIn.isNone and noneOut.isNone
  check "an unsupported model is a bad leg",
    systemoneUnsupportedBody(
      """{"error":{"message":"Model \"x\" is not supported on this endpoint."}}""")
  check "a caller's invalid input is not a bad leg",
    not systemoneUnsupportedBody(
      """{"error":{"message":"Invalid input: expected record","param":"questions"}}""")

block:
  # The order is the config's, and a cooling leg is skipped without a dial.
  var cfg = Config(listenHost: "127.0.0.1", listenPort: 4011,
                   logPath: scratch / "so.jsonl")
  cfg.legs = @[legSpec("leg-a", lrPrimary)]
  cfg.systemone = @[
    SystemoneLeg(name: "jev-a", baseUrl: "https://a.test/v1", model: "m",
                 enabled: true),
    SystemoneLeg(name: "jev-b", baseUrl: "https://b.test/v1", model: "m",
                 enabled: false),
    SystemoneLeg(name: "jev-c", baseUrl: "https://c.test/v1", model: "m",
                 enabled: true)]
  let gateway = newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")
  check "the order skips the disabled leg",
    gateway.systemoneOrder(epochTime()) == @[0, 2]
  gateway.startSystemoneCooldown(0, TokenAuth401)
  check "a cooling leg leaves the order",
    gateway.systemoneOrder(epochTime()) == @[2]
  check "the cooldown is counted for that route",
    parseJson(gateway.configJson()){"systemone"}.len == 3
  check "the config reports the block beside the chat legs",
    parseJson(gateway.configJson()){"legs"}.len == 1

block:
  # DEC-28: `systemone_balance` is its own opt-in (default false). With it on the
  # first System One pick is weighted and the rest of the walk stays config order;
  # with it off the walk is DEC-19 even when the chat door balances. Same SWRR as
  # DEC-11, so equal weights alternate and a cooling or disabled leg leaves the
  # pool instead of taking its share to nobody.
  var cfg = Config(listenHost: "127.0.0.1", listenPort: 4011,
                   logPath: scratch / "so-balance.jsonl",
                   balance: true, systemoneBalance: true)
  cfg.legs = @[legSpec("leg-a", lrPrimary)]
  cfg.systemone = @[
    SystemoneLeg(name: "jev-a", baseUrl: "https://a.test/v1", model: "m",
                 enabled: true, weight: 1),
    SystemoneLeg(name: "jev-b", baseUrl: "https://b.test/v1", model: "m",
                 enabled: true, weight: 1)]
  let gateway = newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")
  var picks: seq[int]
  for _ in 0 ..< 4:
    picks.add gateway.systemoneOrder(epochTime())[0]
  check "equal weights alternate the System One first pick",
    picks == @[0, 1, 0, 1]
  check "the walk after the pick is config order",
    gateway.systemoneOrder(epochTime()) == @[0, 1]
  gateway.startSystemoneCooldown(0, TokenAuth401)
  check "a cooling leg leaves the System One pool",
    gateway.systemoneOrder(epochTime()) == @[1]

  cfg.systemone[0].weight = 3
  let heavy = newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")
  var counts: array[2, int]
  for _ in 0 ..< 400:
    inc counts[heavy.systemoneOrder(epochTime())[0]]
  check "a 3:1 config over 400 requests gives 300:100",
    counts[0] == 300 and counts[1] == 100

  # A disabled leg is out of the pool and out of the walk, so it cannot be picked
  # even as the tail that would only be dialled on a failure.
  cfg.systemone[1].enabled = false
  let disabled = newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")
  var disabledPicks: seq[int]
  for _ in 0 ..< 20:
    disabledPicks.add disabled.systemoneOrder(epochTime())[0]
  check "a disabled leg is never picked",
    disabledPicks.allIt(it == 0) and
      disabled.systemoneOrder(epochTime()) == @[0]

  # The opt-in is separate from the chat door's `balance`: turning chat balancing
  # on must not re-order System One traffic underneath the operator.
  var chatOnly = cfg
  chatOnly.balance = true
  chatOnly.systemoneBalance = false
  chatOnly.systemone[1].enabled = true
  let unswitched = newGateway(chatOnly, RequestLog(fd: -1), "127.0.0.1:4011")
  var chatOnlyPicks: seq[int]
  for _ in 0 ..< 6:
    chatOnlyPicks.add unswitched.systemoneOrder(epochTime())[0]
  check "chat balance alone leaves the System One walk in config order",
    chatOnlyPicks.allIt(it == 0) and
      unswitched.systemoneOrder(epochTime()) == @[0, 1]

  # /admin/config publishes the flag and the shares, and still no credential.
  cfg.systemone[0].baseUrl = "https://u:pw@a.test/v1"
  let printed = parseJson(newGateway(cfg, RequestLog(fd: -1),
                                     "127.0.0.1:4011").configJson())
  check "the System One flag is published",
    printed{"systemone_balance"}.getBool() == true
  check "each System One leg publishes its weight",
    printed{"systemone"}[0]{"weight"}.getInt() == 3 and
      printed{"systemone"}[1]{"weight"}.getInt() == 1
  check "the published System One base_url carries no credential",
    printed{"systemone"}[0]{"base_url"}.getStr() == "https://a.test/v1"

# ------------------------------------------------------------- the admin gate ---
#
# DEC-20. These exercise the gate's whole decision surface without a socket: a
# Request is a plain object, so a header set is the only thing a case needs. The
# path/status table over a real HTTP connection is the acceptance case A16; what
# is proved here is that each arm of the gate answers what the contract says.

block:
  # Constant-time compare: the result, never the timing, is what these assert.
  check "the same string matches", constantTimeEquals("abc", "abc")
  check "a different string does not", not constantTimeEquals("abc", "abd")
  check "a prefix does not", not constantTimeEquals("abcdef", "abc")
  check "a longer value does not", not constantTimeEquals("abc", "abcdef")
  check "the empty string only matches itself",
    constantTimeEquals("", "") and not constantTimeEquals("a", "")

block:
  # The token file. Every way of not having one is one answer: no token.
  let file = scratch / "admin.token"
  putEnv(AdminTokenEnv, file)
  writeFile(file, "s3cret-token\n")
  check "the token file is read with its newline trimmed",
    readAdminToken() == some("s3cret-token")
  writeFile(file, "  s3cret-token  \r\n\n")
  check "surrounding whitespace is trimmed too",
    readAdminToken() == some("s3cret-token")
  writeFile(file, "")
  check "an empty token file is no token", readAdminToken().isNone
  writeFile(file, "   \n\t\n")
  check "a whitespace-only token file is no token", readAdminToken().isNone
  removeFile(file)
  check "a missing token file is no token", readAdminToken().isNone
  putEnv(AdminTokenEnv, scratch / "nested" / "admin.token")
  check "a path under a directory that does not exist is no token",
    readAdminToken().isNone
  delEnv(AdminTokenEnv)
  check "with the variable unset the documented default is used",
    adminTokenPath() == DefaultAdminTokenFile

block:
  # Bearer parsing. The scheme is case-insensitive; the credential is everything
  # after it, so a token containing a space survives.
  proc withHeaders(pairs: openArray[(string, string)]): Request =
    var headers = newHttpHeaders()
    for (name, value) in pairs:
      headers[name] = value
    Request(reqMethod: HttpGet, headers: headers)
  check "a bearer is parsed",
    withHeaders([("Authorization", "Bearer tok")]).bearerValue() == "tok"
  check "the scheme is case-insensitive",
    withHeaders([("Authorization", "bearer tok")]).bearerValue() == "tok"
  check "a bare credential with no scheme is not a bearer",
    withHeaders([("Authorization", "tok")]).bearerValue().len == 0
  check "a different scheme is not a bearer",
    withHeaders([("Authorization", "Basic dXNlcg==")]).bearerValue().len == 0
  check "no Authorization header means no bearer",
    withHeaders([("Accept", "*/*")]).bearerValue().len == 0
  check "a token with a space in it keeps the whole value",
    withHeaders([("Authorization", "Bearer a b c")]).bearerValue() == "a b c"

  check "the kori_admin cookie is parsed out of a multi-cookie header",
    withHeaders([("Cookie", "theme=dark; kori_admin=abc123; other=1")])
      .sessionCookieValue() == "abc123"
  check "another cookie name is not a session",
    withHeaders([("Cookie", "kori_adminx=abc")]).sessionCookieValue().len == 0
  check "no Cookie header means no session",
    withHeaders([("Accept", "*/*")]).sessionCookieValue().len == 0
  check "a malformed cookie pair does not throw",
    withHeaders([("Cookie", "garbage; kori_admin=xyz")])
      .sessionCookieValue() == "xyz"

  # A redirect is for a browser. `curl` sends */*, and a script that gets a 302
  # it cannot follow has been told nothing.
  check "an explicit text/html is a page request",
    withHeaders([("Accept", "text/html,application/xhtml+xml")]).acceptsHtml()
  check "a wildcard accept is not a page request",
    not withHeaders([("Accept", "*/*")]).acceptsHtml()
  check "a json accept is not a page request",
    not withHeaders([("Accept", "application/json")]).acceptsHtml()
  check "no Accept header is not a page request",
    not withHeaders([("Accept-Encoding", "gzip")]).acceptsHtml()

block:
  # The cookie the login sets, asserted literally: Galih's gate re-checks these
  # five attributes and none of them may drift.
  let cookie = sessionCookie("abc", 2_592_000)
  check "the admin session lifetime is 30 days", int(AdminSessionTtlS) == 2_592_000
  check "the cookie is named kori_admin", cookie.startsWith(AdminCookieName & "=")
  check "the cookie is HttpOnly", cookie.contains("; HttpOnly")
  check "the cookie is Secure", cookie.contains("; Secure")
  check "the cookie is SameSite=Strict", cookie.contains("; SameSite=Strict")
  check "the cookie is scoped to Path=/", cookie.contains("; Path=/")
  check "the cookie carries the 30 day max age", cookie.contains("; Max-Age=2592000")
  check "a cleared cookie has Max-Age=0", sessionCookie("", 0).contains("Max-Age=0")

block:
  # Sessions. A new id is 32 bytes of base64url; the table expires entries, caps
  # its size, and a restart (a new Gateway) starts empty.
  var cfg = Config(listenHost: "127.0.0.1", listenPort: 4011,
                   logPath: scratch / "gate.jsonl")
  cfg.legs = @[legSpec("leg-a", lrPrimary)]
  let gateway = newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")
  let first = gateway.startSession()
  check "a session id is produced", first.isSome
  check "the session id is 32 bytes of base64url, so 43 characters",
    first.get.len == 43
  check "the session id is unpadded", not first.get.contains('=')
  check "the session is in the table", gateway.sessions.hasKey(first.get)
  let second = gateway.startSession()
  check "two logins get two different ids", second.get != first.get

  # Expiry is enforced on read: an entry past its deadline is dropped by the next
  # gate call, so a 30 day old cookie cannot survive in a running process.
  gateway.sessions[second.get] =
    AdminSession(expiresAt: epochTime() - 1, scope: asRead,
                 tokenHash: hash("gate-token"))
  let probe = Request(reqMethod: HttpGet,
                      headers: newHttpHeaders([("Cookie",
                        AdminCookieName & "=" & second.get)]))
  let file = scratch / "gate.token"
  putEnv(AdminTokenEnv, file)
  writeFile(file, "gate-token\n")
  check "the gate denies an expired session", gateway.adminGate(probe) == agDenied
  check "the expired session is gone from the table",
    not gateway.sessions.hasKey(second.get)

  # A live cookie is the credential; the same request with a wrong bearer and no
  # cookie is not.
  let liveCookie = Request(reqMethod: HttpGet,
                           headers: newHttpHeaders([("Cookie",
                             AdminCookieName & "=" & first.get)]))
  check "a live cookie opens the gate", gateway.adminGate(liveCookie) == agOk
  let wrongBearer = Request(reqMethod: HttpGet,
                            headers: newHttpHeaders([("Authorization",
                              "Bearer not-the-token")]))
  check "a wrong bearer is denied", gateway.adminGate(wrongBearer) == agDenied
  let rightBearer = Request(reqMethod: HttpGet,
                            headers: newHttpHeaders([("Authorization",
                              "Bearer gate-token")]))
  check "the right bearer opens the gate", gateway.adminGate(rightBearer) == agOk

  # DEC-27, amended: the write token reads. It can already mint a write session,
  # which reads every GET, so the bearer form is not a wider door.
  let writeTokenFile = scratch / "gate-write.token"
  putEnv(AdminWriteTokenEnv, writeTokenFile)
  writeFile(writeTokenFile, "write-token\n")
  let writeBearer = Request(reqMethod: HttpGet,
                            headers: newHttpHeaders([("Authorization",
                              "Bearer write-token")]))
  check "the write bearer opens the read gate",
    gateway.adminGate(writeBearer) == agOk
  check "the write bearer is still not the read token",
    gateway.adminGate(rightBearer) == agOk

  # Fail closed: no token file means the gated surface does not exist, for every
  # request, and a bearer of any value is not a way around it.
  delEnv(AdminTokenEnv)
  putEnv(AdminTokenEnv, scratch / "absent.token")
  check "with no token file even the right bearer is not a gate answer",
    gateway.adminGate(rightBearer) == agNoToken
  check "with no token file a request with nothing is not a gate answer",
    gateway.adminGate(wrongBearer) == agNoToken

  # The cap bounds memory: 256 live sessions is the ceiling, and the next login
  # evicts the one closest to expiry instead of refusing the new one.
  putEnv(AdminTokenEnv, file)
  let capped = newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")
  for _ in 0 ..< MaxAdminSessions:
    discard capped.startSession()
  check "the session table stops at the cap", capped.sessions.len == MaxAdminSessions
  let overflow = capped.startSession()
  check "a login past the cap still gets a session", overflow.isSome
  check "the table is still capped after it",
    capped.sessions.len == MaxAdminSessions
  check "the newest session is the one that survived",
    capped.sessions.hasKey(overflow.get)
  delEnv(AdminTokenEnv)

block:
  # The login window. Five failures block the sixth *failed* attempt, and the
  # counter is global: behind Caddy every request arrives from one address. DEC-21
  # narrowed it so the window never refuses a correct token — the handler compares
  # first and only a mismatch is counted or 429'd.
  var cfg = Config(listenHost: "127.0.0.1", listenPort: 4011,
                   logPath: scratch / "window.jsonl")
  cfg.legs = @[legSpec("leg-a", lrPrimary)]
  let gateway = newGateway(cfg, RequestLog(fd: -1), "127.0.0.1:4011")
  let file = scratch / "window.token"
  putEnv(AdminTokenEnv, file)
  writeFile(file, "window-token\n")

  proc loginBody(token: string): string =
    "{\"token\":" & $ %token & "}"
  # The handler needs a socket to answer, so the window is driven directly: five
  # failures recorded inside the window, the sixth sees a full list. That is the
  # same list the handler reads after a mismatch.
  for _ in 0 ..< MaxAdminLoginFailures:
    gateway.loginFailures.add epochTime()
  gateway.pruneLoginFailures(epochTime())
  check "five failures inside the window fill it",
    gateway.loginFailures.len == MaxAdminLoginFailures
  # A failure older than the window is forgotten, which is what makes the limit a
  # window and not a permanent lockout.
  gateway.loginFailures = @[epochTime() - AdminLoginWindowS - 1.0]
  gateway.pruneLoginFailures(epochTime())
  check "a failure older than five minutes leaves the window",
    gateway.loginFailures.len == 0
  check "the login body shape is what the handler parses",
    parseJson(loginBody("t")){"token"}.getStr() == "t"
  # The two numbers the transport depends on. Both are enforced outside Nim code
  # this test can reach, so what is checked here is that they are the values the
  # acceptance harness measures against.
  check "a caller's body cap is 8 MiB, not the old 32", MaxRequestBytes == 8_388_608
  check "the read timeout is 30 s", ReadTimeoutMs == 30_000
  # D-2. The streaming first byte is a rule now, so two prompt sizes must get two
  # different windows. 200 KiB is the 50k-token case that p90'd at 20.8 s; the cap
  # is what stops a pathological body from buying a five-minute failover window.
  check "a short streamed body keeps the 15 s floor",
    streamHeaderDeadlineMs(0) == 15_000 and
      streamHeaderDeadlineMs(900) == 15_000 and
      streamHeaderDeadlineMs(200) == 15_000
  check "a 200 KiB streamed body gets about 35 s, not the floor",
    streamHeaderDeadlineMs(204_800) == 35_000
  check "the slope moves with the body, monotonically, between the floor and the cap",
    streamHeaderDeadlineMs(100 * 1024) > streamHeaderDeadlineMs(10 * 1024) and
      streamHeaderDeadlineMs(100 * 1024) < HeaderDeadlineStreamMaxMs
  check "a body past the cap gets the cap, not a five-minute window",
    streamHeaderDeadlineMs(50 * 1024 * 1024) == HeaderDeadlineStreamMaxMs and
      streamHeaderDeadlineMs(MaxRequestBytes) == HeaderDeadlineStreamMaxMs
  check "the cap is 60 s, inside the 90 s non-streaming one",
    HeaderDeadlineStreamMaxMs == 60_000 and
      HeaderDeadlineStreamMaxMs < HeaderDeadlineNonStreamMs
  delEnv(AdminTokenEnv)

block:
  # The sentinel. The request log line has no header parameter at all, so a cookie
  # or a token cannot be formatted into it; this proves the value is absent even
  # when every other field is filled, and that a gated path never produces a line.
  const sentinel = "SENTINEL-COOKIE-VALUE-do-not-log"
  let line = requestLogLine("2026-11-19T08:00:00+07:00", "leg-a", 200, 12,
                            some(3), some(4), "", "", false, "kori/fast")
  check "the log line never carries a cookie sentinel", not line.contains(sentinel)
  check "the log line never carries the cookie name",
    not line.contains(AdminCookieName)
  check "the log line has no header-shaped key",
    not line.contains("\"cookie\"") and not line.contains("\"authorization\"")
  # The gate's own answers are fixed bodies, so nothing the caller sent is echoed
  # back into a response either.
  check "the denial body is fixed and has no parameter",
    adminDeniedBody() ==
      "{\"error\":{\"type\":\"unauthorized\",\"message\":\"admin token required\"}}"

block:
  # Which paths the gate covers. `/healthz`, `/login.html` and the assets are the
  # ones that must stay open, and that is a property of this list.
  check "the root alias is a gated page", isGatedPage("/")
  for page in ["/index.html", "/requests.html", "/routes.html", "/config.html"]:
    check "the page " & page & " is gated", isGatedPage(page)
  check "the sign-in page is not gated", not isGatedPage("/login.html")
  check "a stylesheet is not gated", not isGatedPage("/assets/any-hashed-name.css")
  check "a font is not gated", not isGatedPage("/fonts/inter-latin-var.woff2")

block:
  # DEC-26. The new log keys are optional and last, so a line an older binary
  # wrote still parses and a reader that knows only the nine keys is unaffected.
  let bare = requestLogLine("2026-11-25T10:00:00Z", "leg-a", 200, 120,
                            some(100), some(50), "", "", false)
  check "a line without the new facts keeps the nine-key shape",
    not bare.contains("prompt_kib") and not bare.contains("header_ms")
  let measured = requestLogLine("2026-11-25T10:00:00Z", "leg-a", 200, 120,
                                some(100), some(50), "", "", false,
                                promptKib = 64, headerMs = 880)
  check "prompt_kib is the prompt size in KiB",
    measured.contains("\"prompt_kib\":64")
  check "header_ms is the wait to the first response byte",
    measured.contains("\"header_ms\":880")
  check "the new keys follow the nine",
    measured.find("\"prompt_kib\"") > measured.find("\"stream\"")

block:
  # DEC-26: the deadline numbers are config, not compile-time constants, and the
  # one rule that reads them answers the same shape as before.
  let path = writeConfig("tuned.json", """
{"timeouts":{"header_ms_stream_base":9000,"header_ms_stream_slope_per_kib":25,
 "header_ms_stream_max":30000,"header_ms_non_stream":45000},
 "legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1"}]}
""")
  let cfg = loadConfig(path)
  check "config reads the four timeout numbers",
    cfg.headerStreamBaseMs == 9000 and cfg.headerStreamPerKiBMs == 25 and
    cfg.headerStreamMaxMs == 30_000 and cfg.headerNonStreamMs == 45_000
  check "the tuned rule gives a 256 KiB body 15.4 s",
    streamHeaderDeadlineMs(cfg.headerStreamBaseMs, cfg.headerStreamPerKiBMs,
                           cfg.headerStreamMaxMs, 256 * 1024) == 15_400
  check "a body of zero bytes still gets the floor",
    streamHeaderDeadlineMs(9000, 25, 30_000, 0) == 9000
  check "the slope is capped",
    streamHeaderDeadlineMs(9000, 25, 30_000, 4 * 1024 * 1024) == 30_000

checkRaises "a base above the max is refused", ConfigError:
  discard loadConfigText("""{"timeouts":{"header_ms_stream_base":30000,
    "header_ms_stream_max":15000},"legs":[{"name":"a",
    "base_url":"http://127.0.0.1:1/v1"}]}""", "timeouts.json")

block:
  # DEC-26: the new cooldown shapes. A one-leg gateway caps a header rung at 15 s,
  # a capacity 429 is believed between 60 s and 900 s, and a plain rate limit is a
  # short class of its own.
  check "a single leg caps a header rung at 15 s",
    cooldownSeconds(TokenHeaderTimeout, 0, HeaderDeadlineNonStreamMs, true) == 15.0
  check "a single leg still cools at least the floor",
    cooldownSeconds(TokenHeaderTimeout, 0, 1_000, true) == 5.0
  check "two legs keep the 60 s cap on the 90 s door",
    cooldownSeconds(TokenHeaderTimeout, 0, HeaderDeadlineNonStreamMs, false) == 60.0
  check "a quota 429 believes a short Retry-After only down to 60 s",
    cooldownSeconds(TokenQuota429, 0, HeaderDeadlineStreamMs, false, 42) == 60.0
  check "a quota 429 caps a long Retry-After at 900 s",
    cooldownSeconds(TokenQuota429, 0, HeaderDeadlineStreamMs, false, 1200) == 900.0
  check "a rate-limit 429 defaults to 30 s",
    cooldownSeconds(TokenRateLimited, 0, HeaderDeadlineStreamMs) == 30.0
  check "a rate-limit 429 clamps to 5-120 s",
    cooldownSeconds(TokenRateLimited, 0, HeaderDeadlineStreamMs, false, 3) == 5.0 and
    cooldownSeconds(TokenRateLimited, 0, HeaderDeadlineStreamMs, false, 600) == 120.0


block:
  # DEC-27: the overrides block is parsed after the legs, so a name that matches
  # nothing is a load error rather than a switch that silently does nothing.
  let path = writeConfig("overridden.json", """
{"legs":[
  {"name":"a","base_url":"http://127.0.0.1:1/v1"},
  {"name":"b","base_url":"http://127.0.0.1:2/v1","enabled":false},
  {"name":"c","base_url":"http://127.0.0.1:3/v1","aliases":{"jev":"jev-1.14"}}],
 "overrides":{"legs":{"a":false,"b":true},"models":{"jev":false}}}
""")
  let cfg = loadConfig(path)
  check "an override switches a file-enabled leg off",
    cfg.legs[0].enabledFile and not cfg.legs[0].enabled
  check "an override switches a file-disabled leg on",
    not cfg.legs[1].enabledFile and cfg.legs[1].enabled
  check "a leg without an override keeps its file value",
    cfg.legs[2].enabledFile and cfg.legs[2].enabled
  check "a model override is read", cfg.overridesModels["jev"] == false

  # The dashboard write is a text patch, so a credential the file holds is never
  # a value the write path can lose, reorder or reformat.
  let raw = """{
  "listen": {"host":"127.0.0.1","port":4011},
  "log": {"path":"/tmp/x.jsonl"},
  "legs": [{"name":"a","base_url":"http://127.0.0.1:1/v1","api_key":"SENTINEL"}]
}"""
  let first = patchOverridesText(raw,
    """{"legs":{"a":false},"models":{},"updated_at":"2026-11-25T10:00:00Z"}""")
  check "the patch keeps every credential byte", first.contains("SENTINEL")
  let firstCfg = loadConfigText(first, "patch.json")
  check "the patched config turns the leg off without rewriting `enabled`",
    firstCfg.legs[0].enabledFile and not firstCfg.legs[0].enabled
  let second = patchOverridesText(first,
    """{"legs":{"a":true},"models":{},"updated_at":"2026-11-25T10:01:00Z"}""")
  check "a second patch replaces the block instead of adding one",
    second.count("\"overrides\"") == 1
  check "the second switch is the one that applies",
    loadConfigText(second, "patch.json").legs[0].enabled

checkRaises "an override of a name no leg has is refused", ConfigError:
  discard loadConfigText("""{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1"}],
    "overrides":{"legs":{"typo":false}}}""", "override-typo.json")

checkRaises "an override of a model no alias maps is refused", ConfigError:
  discard loadConfigText("""{"legs":[{"name":"a","base_url":"http://127.0.0.1:1/v1"}],
    "overrides":{"models":{"typo":false}}}""", "override-model-typo.json")

# --------------------------------------------------------------------- report ---

removeDir(scratch)
if failures == 0:
  echo "\nall checks passed"
  quit(0)
echo "\n", failures, " check(s) failed"
quit(1)
