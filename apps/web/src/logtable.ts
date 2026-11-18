// One row renderer for the log table, shared by Overview (read-only preview) and Requests
// (expandable). Nine D6 keys, newest first, a null token prints as "-" and never as 0.

import { el } from "./dom";
import { clock, num, secs } from "./format";
import type { LogRow } from "./types";

export function statusClass(status: number): string {
  if (status >= 500) return "status-5xx";
  if (status === 429) return "status-429";
  return "status-" + Math.floor(status / 100) + "xx";
}

export interface BuiltRow {
  tr: HTMLTableRowElement;
  toggle: HTMLButtonElement | null;
  detail: HTMLTableRowElement | null;
}

export function buildLogRow(row: LogRow, expandable: boolean): BuiltRow {
  const tr = el("tr", "row" + (expandable ? " expandable" : ""));
  if (expandable) tr.tabIndex = -1;

  const tdTime = el("td");
  tdTime.dataset.label = "time";
  let toggle: HTMLButtonElement | null = null;
  if (expandable) {
    toggle = el("button", "rowtoggle");
    toggle.type = "button";
    toggle.setAttribute("aria-expanded", "false");
    toggle.appendChild(el("span", "caret", "\u203A"));
    toggle.appendChild(document.createTextNode(clock(row.ts)));
    tdTime.appendChild(toggle);
  } else {
    tdTime.textContent = clock(row.ts);
    tdTime.className = "strong";
  }
  tr.appendChild(tdTime);

  const cell = (text: string, cls?: string, label?: string): HTMLTableCellElement => {
    const td = el("td", cls, text);
    if (label) td.dataset.label = label;
    return td;
  };

  tr.appendChild(cell(row.route, "cell-route", "route"));
  tr.appendChild(cell(String(row.status), statusClass(row.status), "status"));
  tr.appendChild(cell(secs(row.latency_ms), undefined, "latency"));
  tr.appendChild(cell(num(row.tokens_in), "num", "tokens in"));
  tr.appendChild(cell(num(row.tokens_out), "num", "tokens out"));
  tr.appendChild(cell(row.failover_from || "-", undefined, "from"));

  const tdReason = el("td");
  tdReason.dataset.label = "reason";
  const reason = row.failover_reason || "";
  const reasonCls = !reason ? "reason-none" : reason === "quota_429" ? "reason-quota" : "reason-token";
  tdReason.appendChild(el("span", reasonCls, reason || "none"));
  tr.appendChild(tdReason);

  tr.appendChild(cell(row.stream ? "yes" : "no", undefined, "stream"));

  if (!expandable) return { tr, toggle: null, detail: null };

  const detail = el("tr", "detail-row");
  const td = el("td");
  td.colSpan = 9;
  const pairs: Array<[string, string]> = [
    ["ts", row.ts],
    ["route", row.route],
    ["status", String(row.status)],
    ["latency_ms", String(row.latency_ms)],
    ["tokens_in", row.tokens_in === null ? "null" : String(row.tokens_in)],
    ["tokens_out", row.tokens_out === null ? "null" : String(row.tokens_out)],
    ["failover_from", '"' + (row.failover_from || "") + '"'],
    ["failover_reason", '"' + reason + '"'],
    ["stream", row.stream ? "true" : "false"],
  ];
  // The optional keys are listed only when the line carried them, the same rule
  // the binary writes them by: a request with no alias has no alias row.
  if (row.alias !== undefined) pairs.push(["alias", '"' + row.alias + '"']);
  if (row.effort_clamped !== undefined)
    pairs.push(["effort_clamped", '"' + row.effort_clamped + '"']);
  if (row.cost_usd !== undefined) pairs.push(["cost_usd", "$" + row.cost_usd.toFixed(6)]);
  for (const [k, v] of pairs) {
    const pair = el("span", "pair");
    pair.appendChild(el("span", "kv", k));
    pair.appendChild(el("span", "vv", v));
    td.appendChild(pair);
  }
  detail.appendChild(td);
  detail.hidden = true;
  return { tr, toggle, detail };
}
