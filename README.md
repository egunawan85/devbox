# devbox

My personal Claude Code configuration, plus the code to deploy it onto an on-demand
cloud **devbox** — a reproducible, AI-powered development environment.

Clone this repo, point it at a provider, and get a fresh box — Linux on DigitalOcean
or Windows on Azure — that already runs my agent doctrine, guardrails, and toolchain.
Or just push the config to a box that already exists.

## What's here

| Path | What |
|---|---|
| `claude-config/` | The harness payload deployed to the devbox — `CLAUDE.md`, `settings.json`, `hooks/`, and the installers. A self-contained `~/.claude` mirror. |
| `deploy/` | Provisioning + orchestration (DigitalOcean/Linux, Azure/Windows). |
| `docs/` | Design docs — see below. |

## Docs

- [docs/devbox.overview.md](docs/devbox.overview.md) — why the devbox exists + the
  mental model.
- [docs/devbox.spec.md](docs/devbox.spec.md) — the contract a deployed devbox must
  satisfy (**the end state**).

## Deploy

Both paths are built. **Linux/DigitalOcean**: `deploy/devbox up` provisions a box,
installs this config for user `eddyg`, locks it to no-public-inbound, wires SSH agent
forwarding, and brings up the OpenBao vault — plus a config-only path (`configure
--host …`) for boxes that already exist. **Windows/Azure**: a `-p <profile>` target
(e.g. `-p rg`) — `up` does provision + config + vault + the .NET build toolchain (MSBuild
+ LocalDB). See [`deploy/README.md`](deploy/README.md) for the runbook and
[the spec](docs/devbox.spec.md) for the full contract.
