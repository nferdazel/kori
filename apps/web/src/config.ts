// Config: the loaded config, read-only. Five blocks of label and value, never a raw dump. A
// credential prints where it came from and whether it is set, never a character of its value.

import { fetchConfig, fetchState } from "./api";
import { clear, el, q, show } from "./dom";
import { clock, clockFromMs, uptime } from "./format";
import { initShell, setSentence, setUp, startLoop } from "./shell";
import type { AdminConfig } from "./types";

function cfgBlock(title: string, hint: string | null, build: (panel: HTMLElement) => void): HTMLElement {
  const panel = el("section", "panel");
  const head = el("div", "panel-head");
  head.appendChild(el("h2", undefined, title));
  if (hint) head.appendChild(el("span", "hint", hint));
  panel.appendChild(head);
  build(panel);
  return panel;
}

function kvList(rows: Array<[string, string, string?]>): HTMLElement {
  const dl = el("dl", "kv-list");
  for (const [key, value, cls] of rows) {
    const row = el("div", "row");
    row.appendChild(el("dt", undefined, key));
    row.appendChild(el("dd", cls || undefined, value));
    dl.appendChild(row);
  }
  return dl;
}

function credentialText(cr: AdminConfig["legs"][number]["credential"]): { text: string; cls?: string } {
  if (cr.state === "missing") return { text: "missing", cls: "dead" };
  if (cr.source === "env") return { text: `set (from env ${cr.ref})` };
  if (cr.source === "file") return { text: `set (from file ${cr.ref.replace(":", ", line ")})` };
  return { text: "set (source not reported)" };
}

function render(config: AdminConfig): void {
  const root = q("[data-config]");
  if (!root) return;
  clear(root);
  const nowMs = Date.now();

  root.appendChild(
    cfgBlock("Listener", "GET only \u00B7 loopback", (panel) => {
      const rows: Array<[string, string, string?]> = [
        ["listen", config.listen],
        ["version", config.version],
        ["started", clock(config.started_at)],
        ["uptime", uptime(config.started_at, nowMs)],
        [
          "config file",
          config.config.path + (config.config.modified_at ? ` \u00B7 modified ${clock(config.config.modified_at)}` : ""),
        ],
        [
          "balance",
          config.balance
            ? "on \u00B7 weighted round-robin over the primary legs (D12)"
            : "off \u00B7 strict config order",
        ],
      ];
      panel.appendChild(kvList(rows));
    }),
  );

  root.appendChild(
    cfgBlock("Timeouts and cooldowns", "milliseconds unless noted", (panel) => {
      panel.appendChild(
        kvList([
          ["connect", config.timeouts.connect_ms + "ms"],
          ["tls", config.timeouts.tls_ms + "ms"],
          ["header (stream)", config.timeouts.header_ms_stream + "ms base"],
          [
            "header (stream) rule",
            config.timeouts.header_ms_stream +
              "ms + " +
              config.timeouts.header_ms_stream_slope_per_kib +
              "ms/KiB, max " +
              config.timeouts.header_ms_stream_max +
              "ms",
          ],
          ["header (non-stream)", config.timeouts.header_ms_non_stream + "ms"],
          ["idle between chunks", config.timeouts.idle_ms + "ms"],
          ["total (non-stream)", config.timeouts.total_ms + "ms"],
          ["availability cooldown", config.cooldowns.availability_s + "s"],
          ["quota cooldown", config.cooldowns.quota_s + "s"],
        ]),
      );
    }),
  );

  const legs = cfgBlock("Legs", "config order \u00B7 role and weight", (panel) => {
    for (const leg of config.legs) {
      const row = el("div", "legrow");
      row.appendChild(el("span", "ord", String(leg.order)));
      row.appendChild(el("span", "nm", leg.name));
      row.appendChild(el("span", "role " + leg.role, leg.role));
      row.appendChild(el("span", "wt", "weight " + leg.weight));
      const rest = el("span", "rest");
      rest.appendChild(el("b", undefined, leg.base_url));
      rest.appendChild(document.createTextNode(" \u00B7 " + (leg.model || "- (the caller's model is forwarded)")));
      rest.appendChild(document.createTextNode(" \u00B7 " + (leg.headers.length ? leg.headers.join(", ") + ": set" : "no extra headers")));
      row.appendChild(rest);
      panel.appendChild(row);
    }
  });
  legs.classList.add("wide");
  root.appendChild(legs);

  const missing = config.legs.filter((l) => l.credential.state === "missing");
  root.appendChild(
    cfgBlock("Credentials", "values never leave the binary", (panel) => {
      if (missing.length) {
        panel.appendChild(
          el(
            "p",
            "notice",
            `${missing.length} credential missing: ${missing.map((l) => l.credential.name).join(", ")}. Requests to legs using it will fail.`,
          ),
        );
      }
      panel.appendChild(
        kvList(
          config.legs.map((l) => {
            const c = credentialText(l.credential);
            return [l.credential.name, c.text, c.cls] as [string, string, string?];
          }),
        ),
      );
    }),
  );

  root.appendChild(
    cfgBlock("Log", "append-only \u00B7 redacted", (panel) => {
      panel.appendChild(
        kvList([
          ["path", config.log.path],
          ["policy", "one line per request; prompt and credential values never written"],
          ["append-only", config.log.append_only ? "yes" : "no"],
          ["redacted", config.log.redacted ? "yes" : "no"],
        ]),
      );
    }),
  );
}

function renderError(): void {
  const root = q("[data-config]");
  if (!root) return;
  clear(root);
  root.appendChild(el("p", "notice", `the config endpoint did not answer at ${clockFromMs(Date.now())}`));
}

async function refresh(): Promise<boolean> {
  const [cfgRes, stateRes] = await Promise.all([fetchConfig(), fetchState()]);
  if (stateRes.ok) {
    setUp(stateRes.data.gateway.started_at);
    const w = stateRes.data.window;
    setSentence(`config loaded \u00B7 gateway ${stateRes.data.gateway.listen}, ${w.requests} requests in the current window`, false);
    const p = q("[data-footer-path]");
    if (p) p.textContent = "log " + (cfgRes.ok ? cfgRes.data.log.path : "-");
  }
  if (cfgRes.ok) {
    show(q("[data-errline]"), false);
    render(cfgRes.data);
    return true;
  }
  renderError();
  return false;
}

export function startConfig(): void {
  initShell("config.html");
  startLoop(refresh);
}
