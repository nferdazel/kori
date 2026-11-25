// Config: the loaded config, the two switch surfaces, and the one write the dashboard owns. Five
// blocks of label and value, never a raw dump. A credential prints where it came from and whether
// it is set, never a character of its value.

import { fetchConfig, fetchState, putOverrides } from "./api";
import type { FetchErr, Fetched, OverrideBody, OverridesWritten } from "./api";
import { clear, el, q, show } from "./dom";
import { clock, clockFromMs, uptime } from "./format";
import { initShell, setSentence, setUp, startLoop } from "./shell";
import type { AdminConfig, ConfigLeg } from "./types";

type SwitchKind = "legs" | "models";

interface OverrideMap {
  legs: Record<string, boolean>;
  models: Record<string, boolean>;
}

interface LegFlags {
  enabled: boolean;
  serving: boolean;
  override: boolean | null;
}

interface RowRefs {
  input: HTMLInputElement;
  reset: HTMLButtonElement | null;
  state: HTMLElement;
  text: string;
}

const rows = new Map<string, RowRefs>();
let lastConfig: AdminConfig | null = null;
// Held while a PUT or its confirmation is open: the 5 s tick must not re-render the switches under
// the pointer, and must not read a config the write has not finished changing.
let writing = false;

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

// DEC-27 flags. A config read from a binary older than the switch block carries neither value, and
// that binary served every listed leg, so the file value falls back to what it does today.
function legFlags(leg: ConfigLeg): LegFlags {
  const override = leg.override ?? null;
  const enabled = leg.enabled ?? (override === null ? true : override);
  const serving = leg.serving ?? (override === null ? enabled : override);
  return { enabled, serving, override };
}

function legStateText(flags: LegFlags, name: string): string {
  // The router's own word first: an enabled leg that is cooling is still serving as far as the
  // config goes, and only /admin/state knows it is not answering right now.
  const router = routeState.get(name);
  const word = !flags.serving ? "skipped" : router === "cooling" ? "cooling" : "serving";
  const parts = [flags.enabled ? "file on" : "file off", word];
  parts.push(flags.override === null ? "no override" : "override " + (flags.override ? "on" : "off"));
  if (flags.serving && !flags.enabled) parts.push("switched on from the dashboard");
  if (!flags.serving && flags.enabled) parts.push("switched off from the dashboard");
  return parts.join(" \u00B7 ");
}

// Filled from /admin/state on every tick, so a cooling leg is named as cooling.
const routeState = new Map<string, string>();

function modelStateText(override: boolean | null): string {
  if (override === null) return "no override \u00B7 serving";
  return override ? "override on \u00B7 serving" : "override off \u00B7 not serving";
}

// The body replaces the override block, so the page always starts from the last config it read.
function overridesOf(config: AdminConfig): OverrideMap {
  return {
    legs: { ...(config.overrides?.legs ?? {}) },
    models: { ...(config.overrides?.models ?? {}) },
  };
}

function switchKey(kind: SwitchKind, name: string): string {
  return kind + ":" + name;
}

function setStatus(text: string, dead = false): void {
  const node = q("[data-write-status]");
  if (!node) return;
  node.textContent = text;
  node.classList.toggle("dead-text", dead);
}

function setPending(key: string, pending: boolean): void {
  const refs = rows.get(key);
  if (!refs) return;
  refs.input.disabled = pending;
  if (refs.reset) refs.reset.disabled = pending;
  refs.state.textContent = pending ? "saving\u2026" : refs.text;
}

function focusRow(key: string, reset = false): void {
  const refs = rows.get(key);
  if (!refs) return;
  (reset && refs.reset ? refs.reset : refs.input).focus();
}

function writeError(res: FetchErr, label: string): string {
  if (res.status === 403) {
    if (res.type === "csrf_header_required") {
      return "The write header never reached the gateway. Reload the page and try again.";
    }
    return "Sign in with the write token to change switches.";
  }
  if (res.status === 409) {
    if (res.type === "config_changed") {
      return "The config file changed underneath the write. Nothing was saved; try again.";
    }
    return "The write conflicted with the config on disk. Nothing was saved; try again.";
  }
  if (res.status === 404) return "This host has no write token configured, so switches are read-only.";
  if (res.status === 401) return "Not signed in. The login page takes over from here.";
  if (res.status === 400) return res.message;
  if (res.status === 0) {
    return `${label}: the write got no answer (${res.message}). Nothing is confirmed, so reload before trying again.`;
  }
  return `${label}: the write failed with HTTP ${res.status}. ${res.message}`;
}

// A native <dialog> is the trap: showModal holds Tab inside it and Escape closes it. Cancel is the
// default the browser focuses first, and the caller puts focus back on the switch afterwards.
function askLastLeg(): Promise<boolean> {
  const dialog = q<HTMLDialogElement>("[data-confirm]");
  const cancelButton = q<HTMLButtonElement>("[data-confirm-cancel]");
  const confirmButton = q<HTMLButtonElement>("[data-confirm-ok]");
  if (!dialog || !cancelButton || !confirmButton || typeof dialog.showModal !== "function") {
    return Promise.resolve(false);
  }

  return new Promise<boolean>((resolve) => {
    const finish = (answer: boolean): void => {
      cancelButton.removeEventListener("click", onCancel);
      confirmButton.removeEventListener("click", onConfirm);
      dialog.removeEventListener("cancel", onEscape);
      if (dialog.open) dialog.close();
      resolve(answer);
    };
    const onCancel = (): void => finish(false);
    const onConfirm = (): void => finish(true);
    const onEscape = (): void => finish(false);

    cancelButton.addEventListener("click", onCancel);
    confirmButton.addEventListener("click", onConfirm);
    dialog.addEventListener("cancel", onEscape);
    dialog.showModal();
    cancelButton.focus();
  });
}

function sendWrite(next: OverrideMap, confirmLast: boolean): Promise<Fetched<OverridesWritten>> {
  const body: OverrideBody = { legs: next.legs, models: next.models };
  if (confirmLast) body.confirm_last_leg = true;
  return putOverrides(body);
}

async function submit(
  key: string,
  kind: SwitchKind,
  name: string,
  want: boolean | null,
  label: string,
): Promise<void> {
  const config = lastConfig;
  if (!config) return;
  if (writing) {
    setStatus("One write at a time: the previous switch is still in flight.");
    return;
  }

  const next = overridesOf(config);
  if (want === null) delete next[kind][name];
  else next[kind][name] = want;

  writing = true;
  setPending(key, true);
  setStatus("");
  let res = await sendWrite(next, false);

  if (!res.ok && res.status === 409 && res.type === "last_leg") {
    setPending(key, false);
    const confirmed = await askLastLeg();
    if (!confirmed) {
      writing = false;
      setStatus(`${label}: nothing was saved. The last serving provider is still on.`);
      focusRow(key);
      return;
    }
    setPending(key, true);
    res = await sendWrite(next, true);
  }

  const cfg = await fetchConfig();
  writing = false;

  if (!res.ok) {
    setPending(key, false);
    setStatus(writeError(res, label), true);
    focusRow(key);
    return;
  }

  const applied = res.data.applied === false ? "written, applies on reload" : "applied";
  const note = `${label}: ${applied}${res.data.reload_requested ? ", reload queued" : ""}`;
  if (cfg.ok) {
    render(cfg.data);
    setStatus(note);
  } else {
    setPending(key, false);
    setStatus(`${note}. The config read did not answer, so this page still shows the previous state.`, true);
  }
  focusRow(key);
}

// No optimistic UI: the box moves only after the server has answered, so a click is refused here
// and the write decides the value.
function switchRow(opts: {
  key: string;
  kind: SwitchKind;
  name: string;
  checked: boolean;
  override: boolean | null;
  stateText: string;
  stateId: string;
  labelledBy: string;
}): HTMLElement {
  const wrap = el("div", "leg-switch");

  const hit = el("label", "sw-hit");
  const input = el("input", "sw-input");
  input.type = "checkbox";
  input.checked = opts.checked;
  input.dataset.switch = opts.key;
  input.setAttribute("aria-labelledby", opts.labelledBy);
  input.setAttribute("aria-describedby", opts.stateId);
  input.addEventListener("click", (event) => {
    event.preventDefault();
    void submit(opts.key, opts.kind, opts.name, !opts.checked, opts.name);
  });
  hit.appendChild(input);
  wrap.appendChild(hit);

  if (opts.override !== null) wrap.appendChild(el("span", "sw-badge", "override"));

  const state = el("span", "sw-state");
  state.id = opts.stateId;
  state.textContent = opts.stateText;
  wrap.appendChild(state);

  let reset: HTMLButtonElement | null = null;
  if (opts.override !== null) {
    reset = el("button", "sw-reset", "reset");
    reset.type = "button";
    reset.dataset.reset = opts.key;
    reset.setAttribute("aria-label", `reset ${opts.name} to the config file value`);
    reset.addEventListener("click", () => void submit(opts.key, opts.kind, opts.name, null, opts.name));
    wrap.appendChild(reset);
  }

  rows.set(opts.key, { input, reset, state, text: opts.stateText });
  return wrap;
}

function renderWriteCount(config: AdminConfig): void {
  const node = q("[data-write-count]");
  if (!node) return;
  const writes = config.admin_writes;
  if (!writes || !writes.count) {
    node.textContent = "no dashboard writes yet";
    return;
  }
  const last = writes.last_at ? "last at " + clock(writes.last_at) : "no write time reported";
  node.textContent = `${writes.count} dashboard write${writes.count === 1 ? "" : "s"}, ${last}`;
}

function render(config: AdminConfig): void {
  const root = q("[data-config]");
  if (!root) return;
  // The panel is rebuilt whole on every tick, so a switch holding focus is recorded and restored.
  const focused = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  const focusedSwitch = focused?.dataset.switch ?? null;
  const focusedReset = focused?.dataset.reset ?? null;

  rows.clear();
  clear(root);
  lastConfig = config;
  const nowMs = Date.now();

  // Plan 6.6: when nothing serves, say it once at the top instead of letting the reader add up
  // every row. The 503 is what the caller gets, so the banner says 503.
  if (!config.legs.some((leg) => leg.serving)) {
    root.appendChild(
      el("p", "notice provider-down", "No provider is serving; every request answers 503."),
    );
  }

  root.appendChild(
    cfgBlock("Listener", "loopback \u00B7 reads and the override write", (panel) => {
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
      const rows: Array<[string, string, string?]> = [
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
        [
          "header timeout cooldown",
          "the header window, clamped to " +
            config.cooldowns.header_timeout_s +
            "s-" +
            config.cooldowns.header_timeout_max_s +
            "s, doubling per repeat",
        ],
      ];
      if (typeof config.cooldowns.single_leg_header_max_s === "number") {
        rows.push(["header cooldown, one leg", config.cooldowns.single_leg_header_max_s + "s"]);
      }
      panel.appendChild(kvList(rows));
    }),
  );

  const legs = cfgBlock("Legs", "config order \u00B7 role and weight", (panel) => {
    config.legs.forEach((leg, index) => {
      const flags = legFlags(leg);
      const stateText = legStateText(flags, leg.name);
      const row = el("div", "legrow");
      row.appendChild(el("span", "ord", String(leg.order)));
      const name = el("span", "nm", leg.name);
      name.id = `leg-name-${index}`;
      row.appendChild(name);
      const role = el("span", "role " + leg.role, leg.role);
      role.id = `leg-role-${index}`;
      row.appendChild(role);
      row.appendChild(el("span", "wt", "weight " + leg.weight));
      const rest = el("span", "rest");
      rest.appendChild(el("b", undefined, leg.base_url));
      rest.appendChild(document.createTextNode(" \u00B7 " + (leg.model || "- (the caller's model is forwarded)")));
      rest.appendChild(document.createTextNode(" \u00B7 " + (leg.headers.length ? leg.headers.join(", ") + ": set" : "no extra headers")));
      row.appendChild(rest);
      row.appendChild(
        switchRow({
          key: switchKey("legs", leg.name),
          kind: "legs",
          name: leg.name,
          checked: flags.serving,
          override: flags.override,
          stateText,
          stateId: `leg-state-${index}`,
          labelledBy: `leg-name-${index} leg-role-${index}`,
        }),
      );
      panel.appendChild(row);
    });
    panel.appendChild(
      el(
        "p",
        "table-note cfg-note",
        `A switch writes the overrides block of ${config.config.path}, after the binary has re-validated the patched file. The copy it replaces is kept beside it as .bak.`,
      ),
    );
  });
  legs.classList.add("wide");
  root.appendChild(legs);

  const aliasIds = new Map<string, string[]>();
  for (const leg of config.legs) {
    for (const [alias, providerId] of Object.entries(leg.aliases ?? {})) {
      const ids = aliasIds.get(alias) ?? [];
      if (!ids.includes(providerId)) ids.push(providerId);
      aliasIds.set(alias, ids);
    }
  }
  const aliases = Array.from(aliasIds.keys()).sort();
  const modelOverrides: Record<string, boolean | undefined> = config.overrides?.models ?? {};

  const models = cfgBlock("Models", "one switch per alias \u00B7 global across legs", (panel) => {
    if (aliases.length === 0) {
      panel.appendChild(el("p", "table-note", "this config defines no model aliases"));
      return;
    }
    aliases.forEach((alias, index) => {
      const override = modelOverrides[alias] ?? null;
      const row = el("div", "modelrow");
      const name = el("span", "nm", alias);
      name.id = `model-name-${index}`;
      row.appendChild(name);
      row.appendChild(el("span", "provider", (aliasIds.get(alias) ?? []).join(", ")));
      row.appendChild(
        switchRow({
          key: switchKey("models", alias),
          kind: "models",
          name: alias,
          checked: override !== false,
          override,
          stateText: modelStateText(override),
          stateId: `model-state-${index}`,
          labelledBy: `model-name-${index}`,
        }),
      );
      panel.appendChild(row);
    });
  });
  models.classList.add("wide");
  root.appendChild(models);

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

  renderWriteCount(config);

  const keep = focusedSwitch ?? focusedReset;
  if (keep) focusRow(keep, focusedSwitch === null);
}

function renderError(): void {
  const root = q("[data-config]");
  if (!root) return;
  clear(root);
  root.appendChild(el("p", "notice", `the config endpoint did not answer at ${clockFromMs(Date.now())}`));
}

async function refresh(): Promise<boolean> {
  if (writing) return true;
  const [cfgRes, stateRes] = await Promise.all([fetchConfig(), fetchState()]);
  // A write that started while these reads were in flight owns the newer answer; rendering this
  // one would show the state it replaced.
  if (writing) return true;
  if (stateRes.ok) {
    routeState.clear();
    for (const route of stateRes.data.routes) routeState.set(route.name, route.state);
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
