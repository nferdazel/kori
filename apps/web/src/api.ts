// The three read endpoints. A failed call is data, not an exception the page has to catch blindly:
// each page decides what a dead endpoint may and may not blank (surface §3.6).

export interface FetchOk<T> {
  ok: true;
  data: T;
}
export interface FetchErr {
  ok: false;
  status: number;
  parameter?: string;
  /** The binary's error.type when the body carried one: the switch page keys its message off it. */
  type?: string;
  message: string;
}

export type Fetched<T> = FetchOk<T> | FetchErr;

// Every read on a gated page needs the session cookie. When it is missing the endpoint answers 401
// (or 302 to /login.html, which a fetch follows into an HTML page). Neither is fixable from here,
// so the browser goes to the login page once and comes back to the same URL afterwards. The failed
// call is still returned as data: a page mid-render must not throw. A fail-closed 404 is left alone,
// because a login form cannot help when the host has no token file at all.
let sentToLogin = false;

function goToLogin(): void {
  if (sentToLogin) return;
  sentToLogin = true;
  const here = location.pathname + location.search;
  const next = here.startsWith("/") && !here.startsWith("/login.html") ? "?next=" + encodeURIComponent(here) : "";
  location.replace("/login.html" + next);
}

function landedOnLogin(response: Response): boolean {
  if (!response.redirected) return false;
  try {
    return new URL(response.url).pathname === "/login.html";
  } catch {
    return false;
  }
}

// A read against a loopback admin endpoint answers in milliseconds, and the shell refreshes every
// 5 s. A timeout that outlives the tick would starve the next refresh, so it sits under it: one stuck
// read costs one tick, never the page. The shell also carries a watchdog of its own, past this, for a
// promise that hangs above fetch.
export const READ_TIMEOUT_MS = 4000;

export function readSignal(ms = READ_TIMEOUT_MS): { signal: AbortSignal; cancel: () => void } {
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), ms);
  return { signal: controller.signal, cancel: () => window.clearTimeout(timer) };
}

export function isTimeout(e: unknown): boolean {
  return e instanceof DOMException && e.name === "AbortError";
}

export function timeoutMessage(ms = READ_TIMEOUT_MS): string {
  return `no answer within ${ms / 1000}s`;
}

export const READ_TIMEOUT_S = READ_TIMEOUT_MS / 1000;

async function sendJson<T>(path: string, init: RequestInit, ms: number): Promise<Fetched<T>> {
  const { signal, cancel } = readSignal(ms);
  try {
    const response = await fetch(path, {
      ...init,
      cache: "no-store",
      signal,
    });
    if (response.status === 401 || landedOnLogin(response)) {
      goToLogin();
      return { ok: false, status: 401, message: "not signed in" };
    }
    const text = await response.text();
    let body: unknown = null;
    try {
      body = text ? JSON.parse(text) : null;
    } catch {
      body = null;
    }
    if (!response.ok) {
      const err = (body as { error?: { type?: string; message?: string } } | null)?.error;
      return {
        ok: false,
        status: response.status,
        parameter: response.status === 400 ? err?.message : undefined,
        type: err?.type,
        message: err?.message || `HTTP ${response.status}`,
      };
    }
    return { ok: true, data: body as T };
  } catch (e) {
    if (isTimeout(e)) return { ok: false, status: 0, message: timeoutMessage(ms) };
    return { ok: false, status: 0, message: e instanceof Error ? e.message : "network error" };
  } finally {
    cancel();
  }
}

function getJson<T>(path: string): Promise<Fetched<T>> {
  return sendJson<T>(path, { headers: { Accept: "application/json" } }, READ_TIMEOUT_MS);
}

import type { AdminConfig, AdminLog, AdminState } from "./types";

export const fetchState = () => getJson<AdminState>("/admin/state");
export const fetchConfig = () => getJson<AdminConfig>("/admin/config");

export interface LogQuery {
  limit?: number;
  offset?: number;
  route?: string;
  statusClass?: string;
  reason?: string;
  stream?: "true" | "false";
  since?: string;
}

export function fetchLog(query: LogQuery = {}): Promise<Fetched<AdminLog>> {
  const params = new URLSearchParams();
  if (query.limit !== undefined) params.set("limit", String(query.limit));
  if (query.offset !== undefined && query.offset > 0) params.set("offset", String(query.offset));
  if (query.route) params.set("route", query.route);
  if (query.statusClass) params.set("status_class", query.statusClass);
  if (query.reason) params.set("reason", query.reason);
  if (query.stream) params.set("stream", query.stream);
  if (query.since) params.set("since", query.since);
  const qs = params.toString();
  return getJson<AdminLog>("/admin/log" + (qs ? "?" + qs : ""));
}

// ---------------------------------------------------------------- the write surface

// A write also rewrites a backup file and re-validates the patched config before it answers, so it
// gets a longer leash than a read. The 5 s shell tick is held off while a write is in flight (the
// config page), which is why this can outlive the tick without starving it.
export const WRITE_TIMEOUT_MS = 8000;

export interface OverrideBody {
  legs: Record<string, boolean>;
  models: Record<string, boolean>;
  confirm_last_leg?: boolean;
}

export interface OverridesWritten {
  written: boolean;
  applied: boolean;
  reload_requested: boolean;
  updated_at: string;
  overrides: { legs: Record<string, boolean>; models: Record<string, boolean> };
}

// The body REPLACES the whole override block: a name left out goes back to the value the config
// file carries. Callers send the complete desired map, never one entry. The X-Kori-Write header is
// what marks a cookie-authenticated write as intended (DEC-27); no token travels in JavaScript.
export function putOverrides(body: OverrideBody): Promise<Fetched<OverridesWritten>> {
  return sendJson<OverridesWritten>(
    "/admin/overrides",
    {
      method: "PUT",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-Kori-Write": "1",
      },
      body: JSON.stringify(body),
    },
    WRITE_TIMEOUT_MS,
  );
}
