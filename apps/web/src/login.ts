// The only page served before a session exists. One field, one POST, three answers: 204 leaves for
// wherever the person was going, everything else stays here and says what happened. The token
// travels in the request body only: never in the query string, never echoed into the DOM.

import "./app.css";
import { q } from "./dom";
import { isTimeout, READ_TIMEOUT_S, readSignal } from "./api";

const form = q<HTMLFormElement>("[data-login]");
const input = q<HTMLInputElement>("#token");
const submit = q<HTMLButtonElement>("[data-submit]");
const error = q<HTMLElement>("[data-error]");

// The gateway answers a gated HTML request with 302 to /login.html and no query string, so a bounced
// page load carries no destination and "/" is the honest landing. A page whose own fetch got a 401
// (an expired cookie mid-session) is the case that does carry one: api.ts builds `?next=` from the
// URL it was on. A referrer is not a substitute: after a 302 it names the page the person left, so
// following it would undo the click that bounced them.
function nextPath(): string {
  return safePath(new URLSearchParams(location.search).get("next")) ?? "/";
}

function safePath(raw: string | null): string | null {
  if (!raw) return null;
  // A same-origin absolute path only. `//host` and `/\host` are protocol-relative in a browser.
  if (!raw.startsWith("/") || raw.startsWith("//")) return null;
  // Backslashes and control characters are read differently by browsers and proxies.
  if (/[\\\u0000-\u001f\u007f]/.test(raw)) return null;
  let url: URL;
  try {
    url = new URL(raw, location.origin);
  } catch {
    return null;
  }
  if (url.origin !== location.origin) return null;
  if (url.pathname === "/login.html") return null;
  return url.pathname + url.search + url.hash;
}

function showError(text: string): void {
  if (!error) return;
  error.textContent = text;
  error.hidden = false;
}

function clearError(): void {
  if (!error) return;
  error.hidden = true;
  error.textContent = "";
}

function setBusy(busy: boolean): void {
  if (!submit) return;
  submit.disabled = busy;
  submit.textContent = busy ? "Checking" : "Sign in";
}

function message(status: number): string {
  if (status === 401) return "That token is not the one this gateway reads.";
  if (status === 429) return "too many attempts, try again in a few minutes";
  if (status === 404) return "This gateway has no admin token file, so the dashboard is closed.";
  return `The gateway answered ${status}. Try again.`;
}

async function signIn(token: string): Promise<void> {
  setBusy(true);
  clearError();
  const { signal, cancel } = readSignal();
  let response: Response;
  try {
    response = await fetch("/session/login", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ token }),
      credentials: "same-origin",
      cache: "no-store",
      signal,
    });
  } catch (e) {
    // The field keeps what was typed, so a retry does not need the token again.
    setBusy(false);
    showError(
      isTimeout(e)
        ? `The gateway did not answer within ${READ_TIMEOUT_S}s. Try again.`
        : "Could not reach the gateway. Check the connection and try again.",
    );
    input?.focus();
    return;
  } finally {
    cancel();
  }
  if (response.status === 204) {
    // replace, not assign: the login page stays out of the back history.
    location.replace(nextPath());
    return;
  }
  setBusy(false);
  showError(message(response.status));
  input?.focus();
}

form?.addEventListener("submit", (e) => {
  e.preventDefault();
  if (!input || !input.value) return;
  void signIn(input.value);
});
