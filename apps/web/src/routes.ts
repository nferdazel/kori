// Routes: the per-leg table. Every cell is a router field; nothing is inferred, nothing is summed,
// and a passed cooling_until never turns a row ok on its own.

import { fetchLog, fetchState } from "./api";
import { clear, el, q, show } from "./dom";
import { age, clock, cooldownWindow, num, secs, spanLabel, windowLabel } from "./format";
import { initShell, setSentence, setUp, startLoop } from "./shell";
import type { RouteLeg } from "./types";

let lastState: Awaited<ReturnType<typeof fetchState>> | null = null;

function stateKey(leg: RouteLeg): string {
  if (leg.state === "ok") return "ok";
  if (leg.state === "unknown") return "unknown";
  return leg.last_failure_class === "quota_429" ? "quota" : "cooling";
}

function stateGlyph(leg: RouteLeg): string {
  const key = stateKey(leg);
  if (key === "ok") return "\u25CF";
  if (key === "quota") return "\u2298";
  if (key === "cooling") return "\u25D0";
  return "?";
}

function stateWord(leg: RouteLeg, nowMs: number): string {
  const key = stateKey(leg);
  if (key === "ok") return "ok";
  if (key === "unknown") return "unknown";
  if (key === "quota") {
    const left = Math.max(0, Math.round((Date.parse(leg.cooling_until || "") - nowMs) / 60000));
    return "quota, " + (left > 0 ? left + "m left" : "ending");
  }
  return "cooling";
}

function stateNode(leg: RouteLeg, nowMs: number): HTMLElement {
  const span = el("span", "state " + stateKey(leg));
  span.appendChild(el("span", "dot"));
  span.appendChild(document.createTextNode(stateGlyph(leg) + " " + stateWord(leg, nowMs)));
  return span;
}

function render(): void {
  if (!lastState || !lastState.ok) return;
  const state = lastState.data;
  const tbody = q("[data-routes]");
  if (!tbody) return;
  clear(tbody);
  const nowMs = Date.parse(state.generated_at);

  for (const leg of state.routes) {
    const tr = el("tr", "row");
    const cell = (node: Node | string, label: string, cls?: string): void => {
      const td = el("td", cls);
      td.dataset.label = label;
      if (node instanceof Node) td.appendChild(node);
      else td.textContent = node;
      tr.appendChild(td);
    };

    const name = el("span", "cell-route");
    name.appendChild(document.createTextNode(leg.name));
    name.appendChild(el("span", "leg-role", " " + leg.role));
    cell(name, "leg");

    cell(leg.model || "-", "model");
    cell(stateNode(leg, nowMs), "state");
    cell(
      leg.cooling_until ? `${clock(leg.cooling_until)} (${windowLabel(cooldownWindow(leg))})` : "-",
      "cooling until",
    );
    cell(leg.last_failure_class || "-", "last failure");
    // - only for a leg the router has never tried; 0 is a real zero.
    cell(leg.state === "unknown" && !leg.failed_in_window ? "-" : num(leg.failed_in_window), "failed in window", "num");
    cell(leg.served_in_window === null ? "-" : String(leg.served_in_window), "served", "num");
    cell(
      leg.latency_ms_p50 === null ? "-" : `${secs(leg.latency_ms_p50)} / ${secs(leg.latency_ms_max)}`,
      "p50 / max",
    );

    let last: string | null = null;
    let kind = "";
    if (leg.last_success_at && (!leg.last_failure_at || Date.parse(leg.last_success_at) > Date.parse(leg.last_failure_at))) {
      last = leg.last_success_at;
      kind = "success ";
    } else if (leg.last_failure_at) {
      last = leg.last_failure_at;
      kind = "failed ";
    }
    cell(last ? kind + age(last, nowMs) : "no requests yet", "last seen");

    tbody.appendChild(tr);
  }

  const note = q("[data-routes-note]");
  if (note) {
    note.textContent = `window ${spanLabel(state)} \u00B7 counts are requests served or abandoned in this window, not since boot`;
  }

  const scroller = q(".routes-scroll");
  if (scroller && scroller.scrollWidth > scroller.clientWidth + 1) {
    scroller.tabIndex = 0;
    scroller.setAttribute("role", "region");
    scroller.setAttribute("aria-label", "Routes table, scrolls sideways at this width");
  }
}

function setNote(logExists: boolean, path: string): void {
  const node = q("[data-log-note]");
  if (!node) return;
  if (logExists) {
    show(node, false);
  } else {
    show(node, true);
    node.textContent = `no request log yet at ${path}. The gateway logs its first line on the first request.`;
  }
}

async function refresh(): Promise<boolean> {
  const [stateRes, logRes] = await Promise.all([fetchState(), fetchLog({ limit: 1 })]);
  if (stateRes.ok) {
    lastState = stateRes;
    setUp(stateRes.data.gateway.started_at);
    const w = stateRes.data.window;
    const cooling = stateRes.data.routes.filter((r) => r.state === "cooling").length;
    const unknown = stateRes.data.routes.filter((r) => r.state === "unknown").length;
    const parts: string[] = [];
    if (w.requests === 0 && unknown === stateRes.data.routes.length) {
      parts.push(`gateway started ${clock(stateRes.data.gateway.started_at).slice(0, 5)}, no requests yet`);
    } else {
      parts.push(`${stateRes.data.routes.filter((r) => r.state === "ok").length} ok`);
      if (cooling) parts.push(`${cooling} cooling`);
      if (unknown) parts.push(`${unknown} unknown`);
      parts.push(`${w.requests} requests ${spanLabel(stateRes.data)}`);
    }
    setSentence(parts.join(", "), false);
    render();
    if (logRes.ok) setNote(logRes.data.file.exists, logRes.data.file.path);
    const p = q("[data-footer-path]");
    if (p) p.textContent = "log " + (logRes.ok ? logRes.data.file.path : "-");
    const n = q("[data-footer-count]");
    if (n) n.textContent = logRes.ok ? `${logRes.data.file.lines} lines` : "";
    return true;
  }
  return false;
}

export function startRoutes(): void {
  initShell("routes.html");
  startLoop(refresh);
}
