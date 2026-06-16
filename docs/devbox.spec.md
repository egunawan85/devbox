# devbox — spec

> The contract: what must be true of a deployed devbox. Source of truth for the
> feature. Durable. For *why*, see [devbox.overview.md](./devbox.overview.md); for the
> current build checklist, see [plans/devbox.md](./plans/devbox.md).

Each requirement is observable — you can check whether a given box satisfies it.

## P — Providers & OS matrix

- **P1** Each OS has one provider: **Linux → DigitalOcean**, **Windows → Azure**.
- **P2** Linux baseline: **Ubuntu LTS** (current 24.04). Windows baseline: **Windows
  Server LTS** with OpenSSH server. _Defaults; revisit per release._
- **P3** Size/region are **configurable with defaults** per provider.

## D — Deployment & lifecycle

- **D1** `provision` stands up a running box for a chosen OS/provider with **one
  command**, then configures it.
- **D2** `configure` runs **standalone against an existing box** given its host and
  OS (`--host`, `--os linux|windows`) — the config-only path.
- **D3** Both `provision` and `configure` are **idempotent / convergent**: re-running
  reconciles to spec rather than erroring or duplicating.
- **D4** `destroy` tears a provisioned box down with **one command**, leaving no
  orphaned resources (disks, firewalls, keys, IPs).
- **D5** Provider tokens/credentials are supplied via env or a git-ignored local
  file. **No secret is ever committed.**
- **D6** Re-creating a box from the repo at a given revision yields an **equivalent
  environment**.

## N — Network posture

- **N1** The box exposes **no public inbound** beyond the single administrative
  access path in §A. All other inbound is denied by the provider firewall (DO Cloud
  Firewall / Azure NSG).
- **N2** **Outbound is open** — the box can reach git remotes, package registries,
  and other deployments it's been granted.
- **N3** Administrative access is **SSH on a non-default port** (not 22), key-only.
  No IP allowlist. The single inbound firewall rule opens that one SSH port; the port
  is documented per box.
- **N4** No RDP / port 3389 on Windows — Windows is administered over SSH too.

## A — Access & SSH

- **A1** Access is **key-only**; password authentication is disabled on both OSes.
- **A2** Direct root/Administrator SSH login is disabled; access is via `eddyg`
  (sudo / admin as appropriate).
- **A3** **Up to two device public keys** (laptop + desktop) are authorized for
  `eddyg`. These are my existing keys — the same ones I use for repos.
- **A4** **No private key is ever stored on the box.** The box performs outbound
  authenticated work (git, other devboxes) via **SSH agent forwarding** of my
  device's agent — never a key at rest on the box.
- **A5** After deploy, I can reach the box from **either device with no password
  prompt**, and agent forwarding works (e.g. `ssh-add -l` over the connection shows
  my keys; `git ls-remote` to a private repo succeeds from the box).

## C — Claude configuration

- **C1** `CLAUDE.md`, `settings.json`, and `hooks/` are installed into `eddyg`'s
  `~/.claude/` on the box.
- **C2** Installed **by code, idempotently** (re-running converges; machine-local
  overrides like `settings.local.json` are preserved).
- **C3** **No hardcoded foreign paths.** Hook commands resolve relative to `$HOME` /
  the install location — never an absolute path from another machine.
- **C4** A **single cross-OS guard** — `git-write-guard.js`, run via `node` — gates
  git write/network ops (`push`, `commit`, `merge`, `reset`, …) to `ask` on every OS,
  including the wrapped forms (`git -C`, `-c`, env-prefixed, chained, quoted exe,
  PowerShell call operator). One implementation, one home.
- **C5** The rest of the permission model matches `settings.json` in this repo.

## T — Toolchain

- **T1** **Claude Code CLI** is installed and on `eddyg`'s `PATH`. _(Important
  install.)_
- **T2** **GitHub tooling** — `git` and `gh` — is installed and on `PATH`, and `gh`
  can authenticate. _(Important install.)_
- **T3** Baseline language runtime(s) for my typical work are present. _Default:
  Node.js LTS. Extend as needed._
- **T4** The Claude Code CLI can authenticate. _Mechanism open — see questions._

## V — Verification (definition of done)

- **V1** A documented post-deploy check confirms the box is live and the harness
  works: `claude --version` succeeds as `eddyg`, the OS-appropriate git-write-guard
  fires on a sample `git commit`, and `gh auth status` is healthy.
- **V2** Agent forwarding is verified from the box (private `git ls-remote` succeeds
  using a forwarded key — no key stored on the box).
- **V3** The deploy command **reports what it did** (provider, OS, host/IP, access
  mode, what was installed, how to connect) — it does not silently succeed.

## Open questions

- **T4 auth**: bake a Claude API key in via env, or interactive login on first use?
- **T2 gh auth**: rely on forwarded SSH for git, and `gh` via a token in env — or
  interactive `gh auth login` on first use?
- **P3 defaults**: pin sizes/regions, or prompt each deploy?
- Terraform **state** location: local (gitignored) vs. a remote backend?
