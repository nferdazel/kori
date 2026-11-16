// Overview: the route strip, five readouts, the request tape, the served-share split bar, the
// failover events and a ten-row preview. Three GETs feed it; none of the numbers is derived.

import { fetchConfig, fetchLog, fetchState } from "./api";
import { clear, el, q, show } from "./dom";
import {
  age,
  bytesLabel,
  clock,
  cooldownWindow,
  mbLabel,
  num,
  pct,
  secs,
  spanLabel,
  windowLabel,
} from "./format";
import { buildLogRow } from "./logtable";
import { initShell, setSentence, setUp, startLoop } from "./shell";
import type { AdminConfig, AdminLog, AdminState, RouteLeg } from "./types";

interface Store {
  state: AdminState | null;
  log: AdminLog | null;
  config: AdminConfig | null;
}

const store: Store = { state: null, log: null, config: null };
const TAPE_LIMIT = 50;

type StateKey = "ok" | "cooling" | "quota" | "unknown";

function stateKey(leg: RouteLeg): StateKey {
  if (leg.state === "ok") return "ok";
  if (leg.state === "unknown") return "unknown";
  return leg.last_failure_class === "quota_429" ? "quota" : "cooling";
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

function stateGlyph(leg: RouteLeg): string {
  const key = stateKey(leg);
  if (key === "ok") return "\u25CF";
  if (key === "quota") return "\u2298";
  if (key === "cooling") return "\u25D0";
  return "?";
}

function stateNode(leg: RouteLeg, nowMs: number): HTMLElement {
  const key = stateKey(leg);
  const span = el("span", "state " + key);
  span.appendChild(el("span", "dot"));
  span.appendChild(document.createTextNode(stateGlyph(leg) + " " + stateWord(leg, nowMs)));
  span.title = "state " + key;
  return span;
}

function servingLeg(state: AdminState): RouteLeg | null {
  return state.routes.find((r) => r.state === "ok") ?? null;
}

function weightFor(name: string): number | null {
  const leg = store.config?.legs.find((l) => l.name === name);
  return leg ? leg.weight : null;
}

function legIndex(name: string): number {
  const routes = store.state?.routes ?? [];
  const i = routes.findIndex((r) => r.name === name);
  return i < 0 ? 2 : i;
}

function headerSentence(state: AdminState): { text: string; dead: boolean } {
  const routes = state.routes;
  const w = state.window;
  const span = spanLabel(state);
  const cooling = routes.filter((r) => r.state === "cooling");
  const serving = servingLeg(state);
  const allUnknown = routes.length > 0 && routes.every((r) => r.state === "unknown");

  if (allUnknown && w.requests === 0) {
    return {
      text: `gateway started ${clock(state.gateway.started_at).slice(0, 5)}, no requests yet, no cooldowns`,
      dead: false,
    };
  }

  if (!serving && cooling.length > 0) {
    const first = cooling[0];
    const since = clock(first.last_failure_at || first.cooling_until);
    const lastOk = routes
      .map((r) => r.last_success_at)
      .filter((v): v is string => Boolean(v))
      .sort()
      .pop();
    return {
      text: `no route can serve requests, since ${since}. Last successful request ${lastOk ? clock(lastOk) : "never"}.`,
      dead: true,
    };
  }

  const parts: string[] = [];
  if (w.requests === 1 && cooling.length === 0) {
    // §3.4.3: one line must not be dressed as a trend.
    return {
      text: `1 request logged ${span}, ${w.failover_availability} failovers`,
      dead: false,
    };
  }
  for (const leg of cooling) {
    const who = leg.role === "primary" && cooling.length === 1 ? "primary" : leg.name;
    if (leg.last_failure_class === "quota_429") {
      parts.push(`${who} out of quota until ${clock(leg.cooling_until)}`);
    } else {
      parts.push(`${who} cooling until ${clock(leg.cooling_until)} (${leg.last_failure_class || "unknown"})`);
    }
  }
  if (cooling.length === 0 && serving) parts.push("all routes ok");
  if (cooling.length > 0 && serving) parts.push(`traffic on ${serving.name}`);

  if (w.requests === 1) {
    parts.push(`${w.failover_availability} failovers in 1 request`);
  } else if (w.failover_capacity > 0) {    parts.push(`${w.failover_availability} failovers, ${w.failover_capacity} quota failovers ${span}`);
  } else {
    parts.push(`${w.failover_availability} failovers ${span}`);
  }
  return { text: parts.join(", "), dead: false };
}

function renderStrip(): void {
  const root = q("[data-strip]");
  const state = store.state;
  if (!root || !state) return;
  clear(root);
  const nowMs = Date.parse(state.generated_at);
  for (const leg of state.routes) {
    const key = stateKey(leg);
    const box = el("article", "leg is-" + key);

    const top = el("div", "leg-top");
    const names = el("div");
    names.appendChild(el("div", "leg-name", leg.name));
    const weight = weightFor(leg.name);
    names.appendChild(el("div", "leg-role", leg.role + (weight === null ? "" : ` \u00B7 w${weight}`)));
    top.appendChild(names);
    top.appendChild(stateNode(leg, nowMs));
    box.appendChild(top);

    box.appendChild(el("p", "leg-model", leg.model || "-"));

    const where = el("p", "leg-where");
    if (leg.state === "ok") {
      where.textContent =
        (leg.served_in_window ?? 0) === 0 ? "not used in this window" : "last success " + age(leg.last_success_at, nowMs);
    } else if (leg.state === "unknown") {
      where.textContent = "no requests yet";
    } else {
      where.appendChild(el("span", "tok", leg.last_failure_class || "unknown"));
      where.appendChild(
        document.createTextNode(
          ` at ${clock(leg.last_failure_at)}, until ${clock(leg.cooling_until)} (${windowLabel(cooldownWindow(leg))})`,
        ),
      );
    }
    box.appendChild(where);

    const served = el("div", "leg-served");
    served.appendChild(el("span", undefined, "served this window"));
    served.appendChild(el("b", undefined, num(leg.served_in_window)));
    box.appendChild(served);

    root.appendChild(box);
  }
}

function renderReadouts(): void {
  const root = q("[data-readouts]");
  const state = store.state;
  if (!root || !state) return;
  clear(root);
  const w = state.window;

  let slowest: RouteLeg | null = null;
  for (const leg of state.routes) {
    if (leg.latency_ms_p50 !== null && (!slowest || leg.latency_ms_p50 > (slowest.latency_ms_p50 ?? 0))) slowest = leg;
  }
  const serving = servingLeg(state);

  const item = (label: string, value: string, sub: string, small = false): void => {
    const box = el("div", "readout");
    box.appendChild(el("span", "readout-label", label));
    box.appendChild(el("span", "readout-num" + (small ? " small" : ""), value));
    box.appendChild(el("span", "readout-sub", sub));
    root.appendChild(box);
  };

  item("requests", String(w.requests), spanLabel(state));
  item("failovers", String(w.failover_availability), "availability class");
  item("quota failovers", String(w.failover_capacity), "900s cooldown");
  item("slowest p50", slowest ? secs(slowest.latency_ms_p50) : "-", slowest ? slowest.name : "no samples", true);
  const medianSub = w.requests === 1 ? "1 request, median of 1" : serving ? "on " + serving.name : "no route serving";
  item("median", serving ? secs(serving.latency_ms_p50) : "-", medianSub, true);

  const asof = q("[data-asof]");
  if (asof) asof.textContent = "as of " + clock(state.window.to);
}

function tapeEmptyMessage(log: AdminLog): string | null {
  if (!log.file.exists) {
    return `no request log yet at ${log.file.path}. The gateway logs its first line on the first request.`;
  }
  if (log.file.bytes === 0) {
    return `no requests yet: the file exists and is empty at ${log.file.path}.`;
  }
  if (log.rows.length === 0) return "nothing to count yet";
  return null;
}

function renderTape(): void {
  const plot = q("[data-tape]");
  const empty = q("[data-tape-empty]");
  if (!plot) return;
  clear(plot);
  const log = store.log;
  if (!log) {
    show(empty, true);
    if (empty) empty.textContent = "the log endpoint did not answer; the tape needs log rows";
    return;
  }
  const message = tapeEmptyMessage(log);
  if (message) {
    show(empty, true);
    if (empty) empty.textContent = message;
    plot.hidden = true;
    const axis = q("[data-tape-axis]");
    const foot = q("[data-tape-foot]");
    const legend = q("[data-tape-legend]");
    clear(axis);
    clear(foot);
    clear(legend);
    return;
  }
  plot.hidden = false;
  show(empty, false);

  const rows = log.rows.slice(0, TAPE_LIMIT).reverse(); // log order: oldest on the left
  let max = 1;
  for (const r of rows) if (r.latency_ms > max) max = r.latency_ms;

  for (const r of rows) {
    const col = el("div", "tape-col leg-" + (legIndex(r.route) + 1) + (r.failover_from ? " has-failover" : ""));
    const bar = el("div", "bar");
    bar.style.height = Math.max(4, Math.round((r.latency_ms / max) * 124)) + "px";
    col.appendChild(bar);
    col.appendChild(el("div", "cap"));
    col.title =
      clock(r.ts) + " " + r.route + " " + r.status + " " + secs(r.latency_ms) +
      (r.failover_from ? " from " + r.failover_from + " (" + r.failover_reason + ")" : "");
    plot.appendChild(col);
  }

  const lo = Math.min(...rows.map((r) => r.latency_ms));
  const failovers = rows.filter((r) => r.failover_from).length;
  plot.setAttribute(
    "aria-label",
    `${rows.length} requests, ${clock(rows[0].ts)} to ${clock(rows[rows.length - 1].ts)}, latency ${secs(lo)} to ${secs(max)}, ${failovers} carried a failover`,
  );

  const axis = q("[data-tape-axis]");
  if (axis) {
    clear(axis);
    axis.appendChild(el("span", undefined, "0"));
    axis.appendChild(el("span", undefined, secs(max / 2)));
    axis.appendChild(el("span", undefined, secs(max)));
  }
  const foot = q("[data-tape-foot]");
  if (foot) {
    clear(foot);
    foot.appendChild(el("span", undefined, `${rows.length} requests \u00B7 ${clock(rows[0].ts)} \u2192 ${clock(rows[rows.length - 1].ts)}`));
  }
  const legend = q("[data-tape-legend]");
  if (legend && store.state) {
    clear(legend);
    store.state.routes.forEach((l, i) => {
      const s = el("span", "l" + (i + 1));
      s.appendChild(el("i"));
      s.appendChild(document.createTextNode(l.name));
      legend.appendChild(s);
    });
    const cap = el("span", "capkey");
    cap.appendChild(el("i"));
    cap.appendChild(document.createTextNode("failover cap"));
    legend.appendChild(cap);
  }
}

function renderShare(): void {
  const bar = q("[data-sharebar]");
  const list = q("[data-share-rows]");
  const state = store.state;
  if (!bar || !list || !state) return;
  clear(bar);
  clear(list);
  const total = state.window.requests || 0;
  state.routes.forEach((leg, i) => {
    const served = leg.served_in_window;
    const untried = served === null || (leg.state === "unknown" && served === 0);
    if (!untried && total > 0 && (served ?? 0) > 0) {
      const seg = el("span", "s" + (i + 1));
      seg.style.width = (((served ?? 0) / total) * 100) + "%";
      bar.appendChild(seg);
    }
    const li = el("li");
    li.appendChild(el("span", "sw s" + (i + 1)));
    li.appendChild(el("span", "nm", leg.name));
    li.appendChild(el("span", "ct", untried ? "-" : String(served)));
    li.appendChild(el("span", "pc", untried ? "-" : pct(served ?? 0, total)));
    list.appendChild(li);
  });
  const note = q("[data-share-note]");
  if (note) {
    note.textContent = `Counts are the router's served_in_window for ${spanLabel(state)}; the bar splits the same counts.`;
  }
}

function renderEvents(): void {
  const list = q("[data-events]");
  if (!list) return;
  clear(list);
  const state = store.state;
  const empty = q("[data-events-empty]");
  if (!state) return;
  const events = state.failover_events.slice(-20).reverse(); // newest first
  if (events.length === 0) {
    show(empty, true);
    if (empty) {
      const lines = store.log?.file.lines ?? state.window.requests;
      empty.textContent = `0 failovers ${spanLabel(state)}, from ${lines} logged requests.`;
    }
    return;
  }
  show(empty, false);
  for (const e of events) {
    const li = el("li");
    li.appendChild(el("span", "ev-time", clock(e.at)));
    const path = el("span", "ev-path");
    path.appendChild(document.createTextNode(e.from_route));
    path.appendChild(el("span", "ev-arrow", "\u2192"));
    path.appendChild(document.createTextNode(e.to_route));
    li.appendChild(path);
    li.appendChild(el("span", "ev-reason", e.reason));
    list.appendChild(li);
  }
  const hint = q("[data-events-hint]");
  if (hint) hint.textContent = `${events.length} shown \u00B7 newest first`;
}

function renderRecent(): void {
  const tbody = q("[data-recent]");
  const state = store.state;
  if (!tbody || !state) return;
  clear(tbody);
  if (state.recent.length === 0) {
    const tr = el("tr");
    const td = el("td", "table-note");
    td.colSpan = 9;
    td.textContent = "nothing to count yet";
    tr.appendChild(td);
    tbody.appendChild(tr);
  } else {
    for (const row of state.recent.slice(0, 10)) tbody.appendChild(buildLogRow(row, false).tr);
  }
  const lines = store.log?.file.lines;
  const count = q("[data-recent-count]");
  if (count) count.textContent = `last ${Math.min(10, state.recent.length)} of ${lines ?? "-"}`;
  const link = q<HTMLAnchorElement>("[data-all-link]");
  if (link) link.textContent = `open all ${lines ?? "-"} requests`;
}

function renderFooter(): void {
  const file = store.log?.file;
  const path = file?.path ?? store.config?.log.path ?? "-";
  const p = q("[data-footer-path]");
  if (p) p.textContent = "log " + path;
  const n = q("[data-footer-count]");
  if (n) n.textContent = file ? `${file.lines} lines \u00B7 ${bytesLabel(file.bytes)}` : "";
}

function renderStateError(): void {
  if (store.state) return; // keep the last good render; the refreshed line already says it failed
  setSentence("route state unavailable", true);
  const strip = q("[data-strip]");
  if (strip) {
    clear(strip);
    strip.appendChild(el("p", "errline", "the state endpoint did not answer"));
  }
  const readouts = q("[data-readouts]");
  if (readouts) {
    clear(readouts);
    const box = el("div", "readout readout-wide");
    box.appendChild(el("span", "readout-label", "window"));
    box.appendChild(el("span", "readout-sub", "the state endpoint did not answer"));
    readouts.appendChild(box);
  }
  const share = q("[data-share-rows]");
  if (share) clear(share);
  const shareNote = q("[data-share-note]");
  if (shareNote) {
    shareNote.classList.add("dead-text");
    shareNote.textContent = "the state endpoint did not answer";
  }
  clear(q("[data-events]"));
  show(q("[data-events-empty]"), true);
  const ev = q("[data-events-empty]");
  if (ev) ev.textContent = "the state endpoint did not answer";
  const tbody = q("[data-recent]");
  if (tbody) {
    clear(tbody);
    const tr = el("tr");
    const td = el("td", "table-note");
    td.colSpan = 9;
    td.textContent = "the state endpoint did not answer";
    tr.appendChild(td);
    tbody.appendChild(tr);
  }
}

async function refresh(): Promise<boolean> {
  const [stateRes, logRes, cfgRes] = await Promise.all([
    fetchState(),
    fetchLog({ limit: TAPE_LIMIT }),
    fetchConfig(),
  ]);
  if (cfgRes.ok) store.config = cfgRes.data;

  let ok = false;
  if (stateRes.ok) {
    store.state = stateRes.data;
    ok = true;
    setUp(stateRes.data.gateway.started_at);
    const sentence = headerSentence(stateRes.data);
    setSentence(sentence.text, sentence.dead);
    renderStrip();
    renderReadouts();
    renderEvents();
    renderRecent();
    renderShare();
  } else {
    renderStateError();
  }

  if (logRes.ok) {
    store.log = logRes.data;
    renderTape();
    if (store.state) renderEvents();
    if (store.state) renderRecent();
  } else if (!store.log) {
    const plot = q("[data-tape]");
    if (plot) plot.hidden = true;
    show(q("[data-tape-empty]"), true);
    const empty = q("[data-tape-empty]");
    if (empty) empty.textContent = "the log endpoint did not answer";
  }

  renderFooter();
  return ok;
}

export function startOverview(): void {
  initShell("index.html");
  startLoop(refresh);
}

// Exposed for the verification harness: lets a page be driven with a snapshot without a binary.
export function __setStoreForTest(s: Store): void {
  store.state = s.state;
  store.log = s.log;
  store.config = s.config;
  if (s.state) {
    setUp(s.state.gateway.started_at);
    const sentence = headerSentence(s.state);
    setSentence(sentence.text, sentence.dead);
    renderStrip();
    renderReadouts();
    renderEvents();
    renderRecent();
    renderShare();
  }
  renderTape();
  renderFooter();
}

export { mbLabel };
