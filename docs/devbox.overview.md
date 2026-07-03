# devbox — overview

> Why this exists and the mental model. Durable. For the contract (what must be
> true), see [devbox.spec.md](./devbox.spec.md).

## Why

I want a **reproducible, AI-powered development environment on demand**. Instead of
hand-configuring a fresh machine every time I start work, I keep one source-of-truth
repo and project it onto a throwaway cloud box. Spin one up when I need it, tear it
down when I'm done, and trust that every box behaves identically — same agent
doctrine, same guardrails, same tools.

## Mental model

```
   devbox repo (source of truth)         provision           configure
  ┌───────────────────────────┐         ┌──────────┐   ┌──────────────────────────┐
  │ claude-config/ (payload)   │         │ DO  →    │   │  devbox (Linux, Ubuntu)  │
  │   CLAUDE.md  (behavior)    │ ──────► │  Terraform│  │  or                      │
  │   settings.json            │         │ Azure →  │   │  devbox (Windows Server) │
  │   hooks/ (git-write-guard) │         └──────────┘   │  user: eddyg             │
  │   install.sh / install.ps1 │              │          │  ~/.claude/ ← payload    │
  │ deploy/  (provisioning)    │   install over SSH ────►│  + claude + github       │
  └───────────────────────────┘                          └──────────────────────────┘
        operator machine (macOS)                                 ephemeral

  network:  inbound = one SSH port (non-default), key-only  ──  laptop + desktop
  outbound: open  ──  devbox uses MY forwarded SSH agent to reach repos / other boxes
```

Two components, one feature:

1. **claude configuration** — the harness payload in its own folder
   (`claude-config/`), a self-contained `~/.claude` mirror and **cross-OS**:
   `CLAUDE.md` (agent behavior), `settings.json` (permissions + hooks), `hooks/` (a
   single cross-OS `git-write-guard.js`, run via `node`), and an idempotent installer
   per OS (`install.sh` / `install.ps1`) that links it into `~/.claude/`.
2. **deployment code** — provisions a box on the right provider for the chosen OS,
   creates the `eddyg` user, installs the toolchain (Claude Code + GitHub), locks
   down the network, and runs the configuration. Can also run **configure-only**
   against a box that already exists.

## Key choices

- **Two providers, two OSes.** DigitalOcean → Linux, Azure → Windows. _(This
  supersedes an earlier Linux-only decision.)_
- **One guard, written in Node.** The git-write-guard is a single `git-write-guard.js`
  run via `node` on every OS — `node` is in the toolchain anyway and gives robust JSON
  parsing. _(This supersedes an earlier two-guard `.sh`+`.ps1` split; the original
  PowerShell guard was also found corrupted.)_
- **Provision and configure are decoupled.** Standing up a box and installing the
  config are separate steps, so "deploy config to an existing deployment" is just the
  configure step run on its own (`--host`, `--os`).
- **The repo is the single source.** Nothing is configured by hand on the box. A box
  that drifts from the repo is a bug.
- **No private keys on the box.** Access is via my existing device SSH keys (laptop
  + desktop). The devbox reuses those same keys for outbound work via **SSH agent
  forwarding** — it never stores a key of its own.
- **Secrets: an OpenBao vault on the box, gated by SSH.** The box runs an OpenBao
  vault bound to localhost — reachable only from inside an SSH session, so my SSH login
  *is* the access gate. App secrets live plaintext on my laptop (durable home) and are
  pushed into the box's vault per session; the vault dies with the box. The box's own
  auth stays interactive + forwarded agent. The only irreducible exposure is *runtime*
  (a secret in use is plaintext in memory). See [spec §E](./devbox.spec.md).
- **Minimal inbound, open outbound.** The only inbound is SSH on a non-default port
  (key-only, no IP allowlist); everything else is denied. The box can freely reach
  out (git remotes, other devboxes it's been granted, package registries).
- **Ephemeral boxes, durable repo.** Recreating a box from the repo yields the same
  environment.
- **Two roles: workspace vs appliance.** The Linux box is where I develop (a
  *workspace*). The Windows box is narrowed to an on-demand **test appliance** — it runs
  the Windows-only suites and deallocates. I develop on Linux and *call* Windows; I don't
  live on it. See [win-test.overview.md](./win-test.overview.md).
- **Self-contained payload.** The entire `~/.claude` mirror — `CLAUDE.md`,
  `settings.json`, `hooks/` — lives under `claude-config/`, so the installer just
  links that one folder onto the box.

## Out of scope (for now)

- Fleet management / many simultaneous devboxes.
- Providers beyond DigitalOcean and Azure.
- Persistent/stateful workloads (treat the box as cattle, not a pet).
