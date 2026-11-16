// One shell on all four pages: nav state, the 5 s countdown ring, the "refreshed" line, the gateway
// sentence and the uptime. The page modules hand this module a refresh function; it decides when to
// call it and how to report a failed refresh without blanking the last good render.

import { q, qq } from "./dom";
import { clockFromMs, uptime } from "./format";

const CIRC = 2 * Math.PI * 8;
const REFRESH_S = 5;

let secsLeft = REFRESH_S;
let lastGoodMs: number | null = null;
let lastFailMs: number | null = null;
let startedAt: string | null = null;
let refreshFn: (() => Promise<boolean>) | null = null;
let busy = false;

export function initShell(page: string): void {
  qq<HTMLAnchorElement>(".rail-nav a, .seg a").forEach((a) => {
    if (a.getAttribute("href") === page) a.setAttribute("aria-current", "page");
  });
  const arc = q<SVGCircleElement>("[data-ring-arc]");
  if (arc) arc.setAttribute("stroke-dasharray", CIRC.toFixed(2));
  paintRing();
  paintRefreshed();
  window.setInterval(onTick, 1000);
}

export function setSentence(text: string, dead = false): void {
  const node = q<HTMLElement>("[data-sentence]");
  if (!node) return;
  node.textContent = text;
  node.classList.toggle("dead", dead);
}

export function setUp(started: string): void {
  startedAt = started;
  paintRefreshed();
}

export function startLoop(fn: () => Promise<boolean>): void {
  refreshFn = fn;
  void runRefresh();
}

function onTick(): void {
  paintRefreshed();
  secsLeft -= 1;
  if (secsLeft <= 0) {
    secsLeft = REFRESH_S;
    paintRing();
    void runRefresh();
    return;
  }
  paintRing();
}

function paintRing(): void {
  const arc = q<SVGCircleElement>("[data-ring-arc]");
  const label = q<HTMLElement>("[data-ring-num]");
  if (arc) arc.setAttribute("stroke-dashoffset", (CIRC * (secsLeft / REFRESH_S)).toFixed(2));
  if (label) label.textContent = secsLeft + "s";
}

function paintRefreshed(): void {
  const node = q<HTMLElement>("[data-refreshed]");
  if (node) {
    if (lastFailMs !== null && (lastGoodMs === null || lastFailMs >= lastGoodMs)) {
      const from = lastGoodMs === null ? "before start" : clockFromMs(lastGoodMs);
      node.textContent = `last refresh failed at ${clockFromMs(lastFailMs)}, showing data from ${from}`;
      node.classList.add("dead-text");
    } else if (lastGoodMs !== null) {
      const s = Math.max(0, Math.round((Date.now() - lastGoodMs) / 1000));
      node.textContent = `refreshed ${s}s ago`;
      node.classList.remove("dead-text");
    }
  }
  const up = q<HTMLElement>("[data-uptime]");
  if (up && startedAt) up.textContent = "up " + uptime(startedAt, Date.now());
}

async function runRefresh(): Promise<void> {
  if (!refreshFn || busy) return;
  busy = true;
  try {
    const ok = await refreshFn();
    if (ok) lastGoodMs = Date.now();
    else lastFailMs = Date.now();
  } catch {
    lastFailMs = Date.now();
  } finally {
    busy = false;
    paintRefreshed();
  }
}
