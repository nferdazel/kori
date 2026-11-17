// Formatting shared by every page. Every number on the surface is mono and tabular; these helpers
// only decide the text, the CSS decides the face. A null never prints as 0: it prints as "-".

import type { AdminState, RouteLeg } from "./types";

export function clock(iso: string | null | undefined): string {
  if (!iso) return "-";
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) {
    return iso.length >= 19 ? iso.slice(11, 19) : iso;
  }
  return clockFromMs(ms);
}

export function clockFromMs(ms: number): string {
  const d = new Date(ms);
  const p = (n: number) => (n < 10 ? "0" : "") + n;
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

export function secs(ms: number | null | undefined): string {
  if (ms === null || ms === undefined) return "-";
  return (ms / 1000).toFixed(ms >= 10000 ? 0 : 1) + "s";
}

export function num(n: number | null | undefined): string {
  return n === null || n === undefined ? "-" : String(n);
}

export function pct(part: number, total: number): string {
  if (!total) return "-";
  return Math.round((part / total) * 100) + "%";
}

// Token counts are large and rarely exact; a readout wants the magnitude, not every digit.
export function compact(n: number | null | undefined): string {
  if (n === null || n === undefined) return "-";
  if (n < 1000) return String(n);
  if (n < 1000000) return (n / 1000).toFixed(n < 10000 ? 1 : 0) + "k";
  return (n / 1000000).toFixed(1) + "M";
}

export function age(iso: string | null, nowMs: number): string {
  if (!iso) return "never";
  const s = Math.max(0, Math.round((nowMs - Date.parse(iso)) / 1000));
  if (s < 60) return s + "s ago";
  if (s < 3600) return Math.round(s / 60) + "m ago";
  return Math.round(s / 3600) + "h ago";
}

export function uptime(startedAt: string, nowMs: number): string {
  const s = Math.max(0, Math.round((nowMs - Date.parse(startedAt)) / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const p = (n: number) => (n < 10 ? "0" : "") + n;
  return h ? `${h}h ${p(m)}m` : `${m}m`;
}

// The bracket on a cooling row is the real subtraction, never a constant (surface §2.5, §3.2).
export function cooldownWindow(leg: RouteLeg): number | null {
  if (!leg.cooling_until || !leg.last_failure_at) return null;
  return Math.round((Date.parse(leg.cooling_until) - Date.parse(leg.last_failure_at)) / 1000);
}

export function windowLabel(seconds: number | null): string {
  if (seconds === null) return "";
  return seconds < 90 ? seconds + "s" : Math.round(seconds / 60) + "m";
}

// Every window label comes from window.from, never a hardcoded "last hour" (surface §7).
export function spanLabel(state: AdminState): string {
  const from = state.window.from;
  if (from === state.gateway.started_at) {
    return "since gateway start " + clock(from).slice(0, 5);
  }
  const hours = (Date.parse(state.window.to) - Date.parse(from)) / 3600000;
  return hours >= 23 ? "last 24h" : "since " + clock(from).slice(0, 5);
}

export function rfc3339(d: Date): string {
  const p = (n: number) => (n < 10 ? "0" : "") + n;
  const off = -d.getTimezoneOffset();
  const sign = off >= 0 ? "+" : "-";
  const abs = Math.abs(off);
  return (
    `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}` +
    `T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}` +
    `${sign}${p(Math.floor(abs / 60))}:${p(abs % 60)}`
  );
}

export function bytesLabel(bytes: number): string {
  if (bytes >= 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + " MB";
  if (bytes >= 1024) return (bytes / 1024).toFixed(1) + " KB";
  return bytes + " B";
}

export function mbLabel(bytes: number): string {
  return (bytes / (1024 * 1024)).toFixed(1) + " MB";
}
