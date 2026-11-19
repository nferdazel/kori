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

async function getJson<T>(path: string): Promise<Fetched<T>> {
  try {
    const response = await fetch(path, { headers: { Accept: "application/json" }, cache: "no-store" });
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
        message: err?.message || `HTTP ${response.status}`,
      };
    }
    return { ok: true, data: body as T };
  } catch (e) {
    return { ok: false, status: 0, message: e instanceof Error ? e.message : "network error" };
  }
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
