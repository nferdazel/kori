// The wire shapes of the three admin GETs, taken from DASHBOARD-surface.md §5 and the binary's
// serialisers. Unknown is always null here; the page decides how to print it.

export type LegState = "ok" | "cooling" | "unknown";

export interface RouteLeg {
  name: string;
  role: "primary" | "fallback" | string;
  model: string | null;
  state: LegState;
  cooling_until: string | null;
  last_failure_class: string | null;
  last_failure_at: string | null;
  last_success_at: string | null;
  served_in_window: number | null;
  failed_in_window: number | null;
  latency_ms_p50: number | null;
  latency_ms_max: number | null;
}

export interface WindowCounters {
  from: string;
  to: string;
  requests: number;
  failover_availability: number;
  failover_capacity: number;
  tokens_in: number;
  tokens_out: number;
}

export interface FailoverEvent {
  at: string;
  from_route: string;
  to_route: string;
  reason: string;
}

export interface LogRow {
  ts: string;
  route: string;
  status: number;
  latency_ms: number;
  tokens_in: number | null;
  tokens_out: number | null;
  failover_from: string;
  failover_reason: string;
  stream: boolean;
  // Conditional in the wire row: present only when the request earned it.
  alias?: string;
  effort_clamped?: string;
  cost_usd?: number;
}

export interface GatewayInfo {
  version: string;
  started_at: string;
  listen: string;
}

export interface AdminState {
  generated_at: string;
  gateway: GatewayInfo;
  routes: RouteLeg[];
  window: WindowCounters;
  failover_events: FailoverEvent[];
  recent: LogRow[];
  limit: number;
}

export interface LogFile {
  path: string;
  bytes: number;
  lines: number;
  exists: boolean;
}

export interface LogScan {
  lines_scanned: number;
  budget: number;
  budget_exhausted: boolean;
  oldest_read_at: string | null;
}

export interface AdminLog {
  generated_at: string;
  source: "tail" | "whole";
  file: LogFile;
  offset: number;
  limit: number;
  rows: LogRow[];
  scan: LogScan;
  more_older: boolean;
}

export interface Credential {
  name: string;
  state: "set" | "missing";
  source: "env" | "file" | "unknown";
  ref: string;
}

export interface ConfigLeg {
  order: number;
  name: string;
  role: string;
  weight: number;
  base_url: string;
  model: string | null;
  headers: string[];
  credential: Credential;
}

export interface AdminConfig {
  generated_at: string;
  listen: string;
  version: string;
  started_at: string;
  config: { path: string; modified_at: string | null };
  balance: boolean;
  legs: ConfigLeg[];
  timeouts: {
    connect_ms: number;
    tls_ms: number;
    header_ms_stream: number;
    header_ms_stream_slope_per_kib: number;
    header_ms_stream_max: number;
    header_ms_non_stream: number;
    idle_ms: number;
    total_ms: number;
  };
  cooldowns: { availability_s: number; quota_s: number };
  log: { path: string; append_only: boolean; redacted: boolean };
}

export interface ApiError {
  error?: { type?: string; message?: string };
}
