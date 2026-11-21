/* Fake data for the kori dashboard mockup. Nothing here comes from a running binary.
   Shapes follow DASHBOARD-surface.md §5 (state, log, config) and DECISIONS-v1.md D11/D12.
   Two scenarios, both inside window.KORI.scenarios; the Overview switch picks one. */

(function () {
  // Fixed snapshot instants so the mockup reads the same on every open.
  var STARTED = "2026-11-14T17:02:10+07:00";

  function pad(n) { return (n < 10 ? "0" : "") + n; }

  // ms epoch -> ISO with a fixed +07:00 offset, independent of the machine timezone.
  function isoJkt(ms) {
    var d = new Date(ms + 7 * 3600 * 1000);
    return d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate()) +
      "T" + pad(d.getUTCHours()) + ":" + pad(d.getUTCMinutes()) + ":" + pad(d.getUTCSeconds()) +
      "+07:00";
  }

  // A log row, newest first. `from` and `reason` are empty strings when the request failed over to nobody.
  function row(baseMs, i, route, opts) {
    opts = opts || {};
    return {
      ts: isoJkt(baseMs - (20 + i * 19) * 1000),
      route: route,
      status: opts.status == null ? 200 : opts.status,
      latency_ms: opts.lat == null ? 2200 : opts.lat,
      tokens_in: opts.tin === undefined ? 120 : opts.tin,
      tokens_out: opts.tout === undefined ? 60 : opts.tout,
      failover_from: opts.from || "",
      failover_reason: opts.reason || "",
      stream: opts.stream === undefined ? true : opts.stream
    };
  }

  function leg(o) {
    return {
      name: o.name, role: o.role, weight: o.weight, model: o.model,
      state: o.state,
      cooling_until: o.cooling_until || null,
      last_failure_class: o.last_failure_class || null,
      last_failure_at: o.last_failure_at || null,
      last_success_at: o.last_success_at || null,
      served_in_window: o.served, failed_in_window: o.failed,
      latency_ms_p50: o.p50 == null ? null : o.p50,
      latency_ms_max: o.p50 == null ? null : o.p50max
    };
  }

  /* ---------- scenario A: balanced, one primary cooling ----------
     Last ten requests split 5/5 between the two primaries; opencode-go is cooling on auth_401 for 60 s
     and commandcode keeps serving. sinarcloud is the fallback and has served nothing. */

  var A_SNAPSHOT = "2026-11-14T23:04:31+07:00";
  var aBase = Date.parse(A_SNAPSHOT);

  var aLog = [];
  for (var i = 0; i < 96; i++) {
    var isGo = i % 2 === 1;                    // newest row is commandcode, then alternating
    var failedHere = (i === 0 || i === 30);    // two requests where opencode-go was tried and failed
    aLog.push(row(aBase, i, isGo ? "opencode-go" : "commandcode", {
      from: failedHere ? "opencode-go" : "",
      reason: failedHere ? "auth_401" : "",
      lat: isGo ? 2400 : 2200,
      tin: 80 + (i * 13) % 140,
      tout: i === 12 ? null : 30 + (i * 7) % 90,
      stream: i !== 41
    }));
  }
  // One mid-stream abort, deep enough that it does not touch the last-ten preview.
  aLog[48].failover_reason = "mid_stream_abort";
  aLog[48].failover_from = "";

  var A = {
    generatedAt: A_SNAPSHOT,
    routes: [
      leg({
        name: "opencode-go", role: "primary", weight: 1, model: "deepseek-v4.1-flash",
        state: "cooling", last_failure_class: "auth_401",
        last_failure_at: "2026-11-14T23:04:11+07:00",
        cooling_until: "2026-11-14T23:05:11+07:00",
        last_success_at: "2026-11-14T23:03:58+07:00",
        served: 48, failed: 2, p50: 2400, p50max: 3900
      }),
      leg({
        name: "commandcode", role: "primary", weight: 1, model: "deepseek-v4.1-flash",
        state: "ok",
        last_success_at: "2026-11-14T23:04:26+07:00",
        served: 48, failed: 0, p50: 2200, p50max: 2900
      }),
      leg({
        name: "sinarcloud", role: "fallback", weight: 1, model: "glm-4.6",
        state: "unknown",
        served: null, failed: null
      })
    ],
    events: [
      { at: "2026-11-14T23:04:11+07:00", from_route: "opencode-go", to_route: "commandcode", reason: "auth_401" },
      { at: "2026-11-14T23:03:11+07:00", from_route: "opencode-go", to_route: "commandcode", reason: "auth_401" }
    ],
    window: {
      from: STARTED, to: A_SNAPSHOT,
      requests: 96, failovers_availability: 2, failovers_quota: 0
    },
    log: aLog
  };

  /* ---------- scenario B: both primaries cooling, the fallback takes everything ---------- */

  var B_SNAPSHOT = "2026-11-14T23:06:02+07:00";
  var bBase = Date.parse(B_SNAPSHOT);

  var bLog = [];
  var bReasons = ["quota_429", "auth_401", "conn_refused", "quota_429", "header_timeout", "upstream_5xx", "quota_429"];
  for (var j = 0; j < 96; j++) {
    var onFallback = j < 60;
    var fromLeg = "";
    var why = "";
    if (onFallback && j < 7) {
      fromLeg = j % 3 === 0 ? "opencode-go" : "commandcode";
      why = bReasons[j];
    }
    bLog.push(row(bBase, j, onFallback ? "sinarcloud" : (j % 2 === 1 ? "opencode-go" : "commandcode"), {
      from: fromLeg, reason: why,
      lat: onFallback ? 2600 : 2300,
      tin: 70 + (j * 17) % 150,
      tout: j === 22 ? null : 40 + (j * 11) % 80,
      stream: j !== 33
    }));
  }
  bLog[22].failover_reason = "mid_stream_abort";
  bLog[22].failover_from = "";

  var B = {
    generatedAt: B_SNAPSHOT,
    routes: [
      leg({
        name: "opencode-go", role: "primary", weight: 1, model: "deepseek-v4.1-flash",
        state: "cooling", last_failure_class: "quota_429",
        last_failure_at: "2026-11-14T23:03:40+07:00",
        cooling_until: "2026-11-14T23:18:40+07:00",
        last_success_at: "2026-11-14T23:03:21+07:00",
        served: 18, failed: 3, p50: 2400, p50max: 3900
      }),
      leg({
        name: "commandcode", role: "primary", weight: 1, model: "deepseek-v4.1-flash",
        state: "cooling", last_failure_class: "auth_401",
        last_failure_at: "2026-11-14T23:04:21+07:00",
        cooling_until: "2026-11-14T23:05:21+07:00",
        last_success_at: "2026-11-14T23:04:08+07:00",
        served: 18, failed: 4, p50: 2200, p50max: 2900
      }),
      leg({
        name: "sinarcloud", role: "fallback", weight: 1, model: "glm-4.6",
        state: "ok",
        last_success_at: "2026-11-14T23:05:58+07:00",
        served: 60, failed: 0, p50: 2600, p50max: 4100
      })
    ],
    events: [
      { at: "2026-11-14T23:04:21+07:00", from_route: "commandcode", to_route: "sinarcloud", reason: "auth_401" },
      { at: "2026-11-14T23:04:14+07:00", from_route: "opencode-go", to_route: "commandcode", reason: "quota_429" },
      { at: "2026-11-14T23:04:02+07:00", from_route: "opencode-go", to_route: "commandcode", reason: "quota_429" },
      { at: "2026-11-14T23:03:51+07:00", from_route: "commandcode", to_route: "sinarcloud", reason: "auth_401" },
      { at: "2026-11-14T23:03:40+07:00", from_route: "opencode-go", to_route: "commandcode", reason: "quota_429" }
    ],
    window: {
      from: STARTED, to: B_SNAPSHOT,
      requests: 96, failovers_availability: 4, failovers_quota: 3
    },
    log: bLog
  };

  var config = {
    listen: "127.0.0.1:8787",
    version: "0.1.0",
    started_at: STARTED,
    config: {
      path: "/etc/kori/config.json",
      modified_at: "2026-11-14T16:58:02+07:00"
    },
    balance: true,
    legs: [
      {
        order: 1, name: "opencode-go", role: "primary", weight: 1,
        base_url: "https://opencode.ai/inference/go/openai/v1",
        model: "deepseek-v4.1-flash",
        headers: ["x-opencode-session"],
        credential: { name: "opencode-go refresh token", state: "set", source: "file", ref: "/etc/kori/credentials:7" }
      },
      {
        order: 2, name: "commandcode", role: "primary", weight: 1,
        base_url: "https://api.commandcode.ai/v1",
        model: "deepseek-v4.1-flash",
        headers: [],
        credential: { name: "commandcode key", state: "set", source: "env", ref: "KORI_CMDCODE_KEY" }
      },
      {
        order: 3, name: "sinarcloud", role: "fallback", weight: 1,
        base_url: "https://api.sinarcloud.id/v1",
        model: "glm-4.6",
        headers: [],
        credential: { name: "sinarcloud key", state: "missing", source: "unknown", ref: null }
      }
    ],
    timeouts: { connect_ms: 3000, header_ms: 30000, body_ms: 120000 },
    cooldowns: { availability_s: 60, quota_s: 900 },
    log: {
      path: "/var/log/kori/requests.jsonl",
      append_only: true,
      redacted: true
    }
  };

  function withGateway(s) {
    s.gateway = {
      version: "0.1.0",
      started_at: STARTED,
      log_path: "/var/log/kori/requests.jsonl",
      log_lines: s.log.length,
      log_bytes: 128400
    };
    s.config = config;
    s.scan = { lines_scanned: s.log.length, budget: 5000, budget_exhausted: false };
    return s;
  }

  window.KORI = {
    scenarios: { a: withGateway(A), b: withGateway(B) },
    current: "a"
  };
  // Flat aliases for the three pages that do not switch scenarios.
  var pick = window.KORI.scenarios[window.KORI.current];
  window.KORI.generatedAt = pick.generatedAt;
  window.KORI.gateway = pick.gateway;
  window.KORI.routes = pick.routes;
  window.KORI.window = pick.window;
  window.KORI.failover_events = pick.events;
  window.KORI.log = pick.log;
  window.KORI.config = pick.config;
  window.KORI.scan = pick.scan;
})();
