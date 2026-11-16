# Unit tests for the slice-1 pure surface: the log line the acceptance harness
# grades byte-wise, CLI flag forms and precedence, and config defaults. No socket
# is opened here; the harness starts the real binary.

import std/[json, options, os, sequtils, strutils]

import "../../apps/api/src/kori"

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

# --------------------------------------------------------------------- report ---

removeDir(scratch)
if failures == 0:
  echo "\nall checks passed"
  quit(0)
echo "\n", failures, " check(s) failed"
quit(1)
