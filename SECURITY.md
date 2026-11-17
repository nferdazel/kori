# Security policy

## Reporting a vulnerability

Do not open a public issue. Use GitHub's private vulnerability reporting on this
repository:

1. Open https://github.com/nferdazel/kori
2. Go to the **Security** tab.
3. Choose **Report a vulnerability**.

That channel is private between you and the maintainer, and it is the fastest route.

**Owner-filled contact:** `[OWNER-FILLED: maintainer security email]` — used only when
GitHub reporting is unavailable to you.

Include what you did, what happened, the revision from `GET /healthz` (the `revision`
field), and the smallest request or config that reproduces it. Do not include live
credentials; redact them, and say that you redacted them.

## Scope

In scope:

- The gateway surface: `POST /v1/chat/completions`, request parsing, the response written
  back to the caller, streaming and tool-call passthrough.
- Routing and fallback: leg selection, failure classification, cooldown, and the `502`
  returned when every leg is dead.
- The admin surface: `GET /admin/state`, `GET /admin/log`, `GET /admin/config`, including
  credential redaction in the config response and the bounded log tail scan.
- The request log: the ten keys, the single-write append, and the guarantee that no
  header, body or credential reaches the file.
- The edge as this repo configures it: the bearer token gate and the per-IP rate limit in
  `ops/caddy/Caddyfile.kori.example`.
- Anything in this repository that would expose a credential, a token or a prompt.

Out of scope:

- The qouver1 host itself: firewall, systemd units, podman configuration and Caddy's own
  binary. Report those to the host owner, not here.
- Provider outages and provider-side incidents. A dead provider is an availability event,
  not a vulnerability in kori.
- Third-party Caddy modules, the Cloudflare edge, and anything in front of the origin.
- Findings that need a local shell on the host as a precondition.

## How a report is handled

- Acknowledgement through the same private thread.
- The maintainer reproduces it, then either fixes it or writes down why it is out of scope
  in that thread.
- A fix is one commit with the reasoning, and the reporter is credited in the thread
  unless they ask not to be.
- Nothing about an open report is posted publicly before a fix is available.

## Credentials

- Provider credentials live in one JSON config file, mode `0600`, outside every
  repository. They are never committed, never baked into an image and never written to the
  request log.
- The edge bearer is generated on the host (`openssl rand -hex 32`) and never leaves it.
- This repository stores templates only: `ops/env/kori-prod.env.example` and
  `ops/caddy/Caddyfile.kori.example` carry empty or placeholder values by design.
- If you believe a credential was committed, treat it as public: report it through the
  private channel above and rotate it at the provider first, then in the host config.
