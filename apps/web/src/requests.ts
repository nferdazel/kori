// Requests: a GET view over /admin/log. Filters are a navigation (a new URL, one request), paging
// moves the offset, and one row expands to the nine log keys. Prompt size is the one filter the
// endpoint has no parameter for, so it narrows the rows this page loaded and the page says so:
// filtering a sample cannot answer "nothing matches in the log".

import { fetchLog, fetchState } from "./api";
import { clear, el, q, qq, show } from "./dom";
import { bytesLabel, clock, mbLabel, rfc3339, spanLabel } from "./format";
import { buildLogRow } from "./logtable";
import { initShell, setSentence, setUp, startLoop } from "./shell";
import type { AdminLog, LogRow } from "./types";

const PAGE_SIZE = 50;
const RANGES: Record<string, number> = { "15m": 15, "1h": 60, "24h": 1440 };

// The same five buckets the overview table uses, as URL tokens so a filtered view is linkable.
const PROMPT_BUCKETS: Record<string, { label: string; lo: number; hi: number | null }> = {
  lt32: { label: "under 32 KiB", lo: 0, hi: 32 },
  "32-64": { label: "32 to 64 KiB", lo: 32, hi: 64 },
  "64-128": { label: "64 to 128 KiB", lo: 64, hi: 128 },
  "128-256": { label: "128 to 256 KiB", lo: 128, hi: 256 },
  gte256: { label: "256 KiB and over", lo: 256, hi: null },
};

interface Filters {
  route: string;
  status: string;
  reason: string;
  stream: string;
  prompt: string;
  range: string;
}

const S: Filters & { offset: number; sel: number; openKey: string | null } = {
  route: "all",
  status: "all",
  reason: "all",
  stream: "all",
  prompt: "all",
  range: "all",
  offset: 0,
  sel: -1,
  openKey: null,
};

let lastLog: AdminLog | null = null;
let lastNewest: string | null = null;
let lastLines = 0;
let routesReady = false;
// The rows after the prompt-size filter: j/k and expand index into what is on screen, not the page.
let visibleRows: LogRow[] = [];

function rowKey(row: LogRow): string {
  return `${row.ts}|${row.route}|${row.status}|${row.latency_ms}`;
}

function inPromptBucket(row: LogRow, bucket: string): boolean {
  const range = PROMPT_BUCKETS[bucket];
  const kib = row.prompt_kib;
  if (!range || typeof kib !== "number") return false;
  return kib >= range.lo && (range.hi === null || kib < range.hi);
}

function readURL(): void {
  try {
    const params = new URLSearchParams(location.search);
    (["route", "status", "reason", "stream", "range"] as const).forEach((k) => {
      const v = params.get(k);
      if (v) S[k] = v;
    });
    // An unknown bucket from a hand-edited URL would empty the table and explain nothing.
    const prompt = params.get("prompt");
    if (prompt && PROMPT_BUCKETS[prompt]) S.prompt = prompt;
    const off = parseInt(params.get("offset") || "0", 10);
    if (Number.isFinite(off) && off > 0) S.offset = off;
  } catch {
    /* a page opened without a query is fine */
  }
}

function writeURL(): void {
  try {
    const params = new URLSearchParams();
    (["route", "status", "reason", "stream", "prompt", "range"] as const).forEach((k) => {
      if (S[k] && S[k] !== "all") params.set(k, S[k]);
    });
    if (S.offset > 0) params.set("offset", String(S.offset));
    const qs = params.toString();
    history.replaceState(null, "", location.pathname + (qs ? "?" + qs : ""));
  } catch {
    /* some file:// contexts refuse history; the filters still work */
  }
}

function filtersSentence(): string {
  const parts: string[] = [];
  if (S.route !== "all") parts.push("route " + S.route);
  if (S.status !== "all") parts.push("status " + S.status);
  if (S.reason !== "all") parts.push("reason " + S.reason);
  if (S.stream !== "all") parts.push(S.stream === "true" ? "stream" : "not streamed");
  if (S.prompt !== "all") parts.push("prompt " + (PROMPT_BUCKETS[S.prompt]?.label ?? S.prompt));
  if (S.range !== "all") parts.push("last " + S.range);
  return parts.length ? parts.join(" \u00B7 ") : "no filters";
}

function hasFilters(): boolean {
  return S.route !== "all" || S.status !== "all" || S.reason !== "all" || S.stream !== "all" || S.range !== "all";
}

function sinceParam(): string | undefined {
  const mins = RANGES[S.range];
  if (!mins) return undefined;
  return rfc3339(new Date(Date.now() - mins * 60000));
}

function setControlsDisabled(disabled: boolean): void {
  qq<HTMLSelectElement>("[data-filters] select").forEach((sel) => {
    sel.disabled = disabled;
    if (disabled) sel.setAttribute("aria-disabled", "true");
    else sel.removeAttribute("aria-disabled");
  });
}

function buildRouteOptions(names: string[]): void {
  if (routesReady) return;
  const sel = q<HTMLSelectElement>('[name="route"]');
  if (!sel) return;
  clear(sel);
  sel.appendChild(new Option("all", "all"));
  for (const name of names) sel.appendChild(new Option(name, name));
  sel.value = S.route;
  routesReady = true;
}

function fileFacts(log: AdminLog): string {
  if (!log.file.exists) return `no file at ${log.file.path}`;
  if (log.file.bytes === 0) return `the file exists and is empty, ${log.file.path}`;
  if (log.source === "whole") return `whole log, ${log.file.lines} lines, ${bytesLabel(log.file.bytes)}`;
  return `read from the last ${mbLabel(log.file.bytes)}`;
}

// §3.4: "no file yet" and "no match" are different facts and must not read the same. A file with
// no bytes is the second flavour of no-data, not an empty filter result.
function noLogYet(log: AdminLog): boolean {
  return !log.file.exists || log.file.bytes === 0;
}

function shownRows(log: AdminLog): LogRow[] {
  return S.prompt === "all" ? log.rows : log.rows.filter((row) => inPromptBucket(row, S.prompt));
}

function renderCaption(log: AdminLog): void {
  const node = q("[data-caption]");
  if (!node) return;
  const rows = log.rows;
  const shown = shownRows(log).length;
  const rest: string[] = [];
  if (rows.length > 0) {
    rest.push(`oldest ${clock(rows[rows.length - 1].ts)}`, `newest ${clock(rows[0].ts)}`);
  }
  rest.push(`filters: ${filtersSentence()}`, fileFacts(log));
  clear(node);
  // A filter that narrows the page names both counts, so the sample it worked on stays visible.
  node.appendChild(el("b", undefined, shown === rows.length ? `${rows.length} rows` : `${shown} of ${rows.length} rows`));
  node.appendChild(document.createTextNode(", " + rest.join(" \u00B7 ")));
}

function renderRows(log: AdminLog): void {
  const tbody = q("[data-log]");
  const table = q("[data-log-table]");
  const pager = q("[data-pager]");
  const empty = q("[data-empty]");
  if (!tbody) return;

  const loaded = log.rows;
  const rows = shownRows(log);
  visibleRows = rows;
  const isEmpty = rows.length === 0;
  show(table, !isEmpty);
  show(pager, !isEmpty);
  show(empty, isEmpty);
  clear(tbody);

  const promptNote = q("[data-prompt-note]");
  if (promptNote) {
    const narrowed = S.prompt !== "all";
    show(promptNote, narrowed);
    if (narrowed) {
      promptNote.textContent = `Prompt size is not a server filter: this narrows the ${loaded.length} rows loaded on this page, not the whole log. A row with no prompt_kib never matches.`;
    }
  }

  if (isEmpty) {
    const emptyTitle = q("[data-empty-title]");
    const emptyBody = q("[data-empty-body]");
    const chips = q("[data-chips]");
    const clearLink = q("[data-clear]");
    if (noLogYet(log)) {
      // §3.4 flavour 1 and 2: nothing has been logged, so no filter can match anything.
      if (emptyTitle) emptyTitle.textContent = "Nothing logged yet";
      if (emptyBody) {
        emptyBody.textContent = log.file.exists
          ? `The file exists and is empty at ${log.file.path}. The gateway logs its first line on the first request.`
          : `No request log yet at ${log.file.path}. The gateway logs its first line on the first request.`;
      }
      show(chips, false);
      show(clearLink, false);
    } else {
      if (emptyTitle) emptyTitle.textContent = "No requests match these filters";
      if (emptyBody) emptyBody.textContent = "The tail had rows; none of them fit. The file itself was not read whole.";
      show(chips, true);
      show(clearLink, true);
      if (chips) {
        clear(chips);
        for (const c of filtersSentence() === "no filters" ? [] : filtersSentence().split(" \u00B7 ")) {
          chips.appendChild(el("span", "chip", c));
        }
      }
    }
    return;
  }

  let openIndex = -1;
  if (S.openKey) openIndex = rows.findIndex((r) => rowKey(r) === S.openKey);
  if (S.sel >= rows.length) S.sel = rows.length - 1;
  if (S.openKey && openIndex < 0) S.openKey = null;

  rows.forEach((row, i) => {
    const built = buildLogRow(row, true);
    const open = i === openIndex;
    if (built.toggle) built.toggle.setAttribute("aria-expanded", open ? "true" : "false");
    const caret = built.toggle?.querySelector(".caret");
    if (caret) caret.textContent = open ? "\u02C5" : "\u203A";
    if (built.detail) built.detail.hidden = !open;
    if (S.sel === i) built.tr.classList.add("sel");

    const toggle = () => {
      S.sel = i;
      S.openKey = open ? null : rowKey(row);
      renderRows(log);
      const focusTbody = q("[data-log]");
      if (S.sel >= 0 && focusTbody) qq<HTMLTableRowElement>("tr.row", focusTbody)[S.sel]?.focus();
    };
    built.toggle?.addEventListener("click", (e) => {
      e.stopPropagation();
      toggle();
    });
    built.tr.addEventListener("click", toggle);
    tbody.appendChild(built.tr);
    if (built.detail) tbody.appendChild(built.detail);
  });

  const older = q<HTMLButtonElement>("[data-older]");
  if (older) older.disabled = !log.more_older;
  const newer = q<HTMLButtonElement>("[data-newer]");
  if (newer) newer.disabled = S.offset === 0;
  const note = q("[data-pager-note]");
  if (note) note.textContent = `rows ${S.offset + 1}\u2013${S.offset + rows.length}`;

  // §3.7: filtering a tail cannot prove a negative, so say so instead of guessing. The page length
  // is the server's answer, never the client-filtered count.
  const tail = q("[data-tail-note]");
  if (tail) {
    const endOfTail = hasFilters() && loaded.length < PAGE_SIZE && log.more_older;
    show(tail, endOfTail);
    if (endOfTail) tail.textContent = "end of the scanned tail";
  }
}

function renderError(status: number, parameter?: string): void {
  const caption = q("[data-caption]");
  const errline = q("[data-errline]");
  if (errline) {
    show(errline, true);
    errline.textContent =
      status === 400 && parameter
        ? `the endpoint rejected the parameter ${parameter}`
        : `the log endpoint did not answer at ${clock(rfc3339(new Date()))}`;
  }
  if (caption && lastLog) renderCaption(lastLog);
}

function renderStale(log: AdminLog): void {
  const stale = q("[data-stale]");
  if (!stale) return;
  const grew = S.offset > 0 && log.file.lines > lastLines && lastNewest !== null;
  if (grew) {
    show(stale, true);
    clear(stale);
    const n = log.file.lines - lastLines;
    stale.appendChild(document.createTextNode(`${n} new lines since ${clock(lastNewest)}, newest not shown `));
    const jump = el("a", "linkish", "jump to newest");
    jump.href = "#";
    jump.addEventListener("click", (e) => {
      e.preventDefault();
      S.offset = 0;
      S.sel = -1;
      S.openKey = null;
      writeURL();
      void refresh();
    });
    stale.appendChild(jump);
  } else {
    show(stale, false);
  }
}

async function refresh(): Promise<boolean> {
  const [stateRes, logRes] = await Promise.all([
    fetchState(),
    fetchLog({
      limit: PAGE_SIZE,
      offset: S.offset,
      route: S.route !== "all" ? S.route : undefined,
      statusClass: S.status !== "all" ? S.status : undefined,
      reason: S.reason !== "all" ? S.reason : undefined,
      stream: S.stream === "all" ? undefined : (S.stream as "true" | "false"),
      since: sinceParam(),
    }),
  ]);

  if (stateRes.ok) {
    setUp(stateRes.data.gateway.started_at);
    buildRouteOptions(stateRes.data.routes.map((r) => r.name));
    const w = stateRes.data.window;
    const span = spanLabel(stateRes.data);
    setSentence(
      `log browser \u00B7 ${w.requests} requests ${span}, ${w.failover_availability} availability and ${w.failover_capacity} quota failovers`,
      false,
    );
  }

  if (logRes.ok) {
    const log = logRes.data;
    show(q("[data-errline]"), false);
    lastLog = log;
    renderCaption(log);
    renderRows(log);
    renderStale(log);
    lastNewest = log.rows.length ? log.rows[0].ts : lastNewest;
    lastLines = log.file.lines;
    setControlsDisabled(noLogYet(log));
    const p = q("[data-footer-path]");
    if (p) p.textContent = "log " + log.file.path;
    const n = q("[data-footer-count]");
    if (n) n.textContent = `${log.file.lines} lines \u00B7 ${bytesLabel(log.file.bytes)}`;
    return true;
  }

  renderError(logRes.status, logRes.parameter);
  return false;
}

function bind(): void {
  readURL();
  const map: Array<[keyof Filters, string]> = [
    ["route", "route"],
    ["status", "status"],
    ["reason", "reason"],
    ["stream", "stream"],
    ["prompt", "prompt"],
    ["range", "range"],
  ];
  for (const [key, name] of map) {
    const sel = q<HTMLSelectElement>(`[name="${name}"]`);
    if (!sel) continue;
    sel.value = S[key];
    sel.addEventListener("change", () => {
      S[key] = sel.value;
      S.offset = 0;
      S.sel = -1;
      S.openKey = null;
      writeURL();
      void refresh();
    });
  }

  q("[data-older]")?.addEventListener("click", () => {
    S.offset += PAGE_SIZE;
    S.sel = -1;
    S.openKey = null;
    writeURL();
    void refresh();
  });
  q("[data-newer]")?.addEventListener("click", () => {
    S.offset = Math.max(0, S.offset - PAGE_SIZE);
    S.sel = -1;
    S.openKey = null;
    writeURL();
    void refresh();
  });

  const clearAll = (): void => {
    S.offset = 0;
    S.sel = -1;
    S.openKey = null;
    S.route = S.status = S.reason = S.stream = "all";
    S.prompt = "all";
    S.range = "all";
    qq<HTMLSelectElement>("[data-filters] select").forEach((x) => (x.value = "all"));
    writeURL();
    void refresh();
  };
  q("[data-clear]")?.addEventListener("click", (e) => {
    e.preventDefault();
    clearAll();
  });

  document.addEventListener("keydown", (e) => {
    const target = e.target as HTMLElement | null;
    const typing = target && /^(SELECT|INPUT|TEXTAREA)$/.test(target.tagName);
    if (typing) {
      if (e.key === "Escape") {
        target?.blur();
        clearAll();
      }
      return;
    }
    if (e.key === "j" || e.key === "ArrowDown") {
      e.preventDefault();
      moveSel(1);
    } else if (e.key === "k" || e.key === "ArrowUp") {
      e.preventDefault();
      moveSel(-1);
    } else if (e.key === "Enter" && S.sel >= 0 && lastLog) {
      e.preventDefault();
      const row = visibleRows[S.sel];
      if (row) {
        S.openKey = S.openKey === rowKey(row) ? null : rowKey(row);
        renderRows(lastLog);
        const focusTbody = q("[data-log]");
        if (S.sel >= 0 && focusTbody) qq<HTMLTableRowElement>("tr.row", focusTbody)[S.sel]?.focus();
      }
    } else if (e.key === "/") {
      e.preventDefault();
      q<HTMLSelectElement>('[name="route"]')?.focus();
    } else if (e.key === "Escape") {
      if (S.sel >= 0 || S.openKey) {
        S.sel = -1;
        S.openKey = null;
        if (lastLog) renderRows(lastLog);
      } else {
        clearAll();
      }
    }
  });
}

function moveSel(delta: number): void {
  if (!lastLog) return;
  const count = visibleRows.length;
  if (count <= 0) return;
  S.sel = Math.max(0, Math.min(count - 1, S.sel + delta));
  renderRows(lastLog);
  const tbody = q("[data-log]");
  if (tbody) qq<HTMLTableRowElement>("tr.row", tbody)[S.sel]?.focus();
}

export function startRequests(): void {
  initShell("requests.html");
  bind();
  startLoop(refresh);
}
