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
- [docs/plans/devbox.md](docs/plans/devbox.md) — current build checklist (ephemeral).

## Deploy

> 🚧 Not built yet — see [the build plan](docs/plans/devbox.md). The intended end
> state: one command provisions a `devbox` (Linux/DigitalOcean or Windows/Azure),
> installs this config for user `eddyg`, locks the box to no-public-inbound, and wires
> SSH agent forwarding — plus a config-only path for boxes that already exist. See
> [the spec](docs/devbox.spec.md) for the full contract.
