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
  orphaned **billable** resources (droplet, disks, firewall, IPs). _Carve-out:_
  reused DigitalOcean **SSH keys** (public, free, bounded to one per device key) are
  intentionally left registered; `destroy` also prunes the box from the operator's
  `known_hosts` so a recycled IP won't trip a host-key mismatch.
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

## E — Environment & secrets

App secrets are served on the box by an **OpenBao vault**, gated by the SSH login, and
loaded each session from a durable plaintext home on the operator's machine. The vault
is a **disposable, session-scoped cache** — its contents die with the box.

- **E1** App secrets are served by an **OpenBao vault running on the devbox in
  production mode (`file` storage, sealed/encrypted at rest), bound to `127.0.0.1`
  only** — unreachable from the network. The **SSH login is the access gate**: only a
  session authenticated by the operator's SSH key can reach the vault. (OpenBao has no
  SSH-key auth method of its own; localhost-binding behind SSH is how the SSH key gates
  access.)
- **E2** The **durable home-of-record** for app secrets is the **operator's machine**,
  stored **plaintext** in a structured layout (default `~/devbox-secrets/`, perms
  `700`/`600`). The box's vault is a session-scoped cache loaded from there — secrets
  are never born on the box and do not survive its teardown.
- **E3** Secrets reach the box via **`devbox vault load [path]`**, which pushes the
  plaintext values from the operator's store into the box's OpenBao **over the
  authenticated SSH session**. The box never pulls secrets itself and keeps no durable
  copy. Editing/organizing the store is done in the operator's editor.
- **E4** Secrets are **never** placed in cloud-init / user-data, shell rc files,
  committed files, or droplet metadata.
- **E5** The vault uses a **single unseal key (1-of-1)**. The **unseal key + root token
  live on the operator's machine** (`vault-keys.json`, `0600`); the unseal key is fed in
  per session and the box **never stores the unseal key**. The box holds only a
  **least-privilege token** (policy `devbox-app`, scoped to `secret/*`), not root, in
  **owner-only `0600` files** for load/reads. Neither the unseal key nor any token is
  ever passed on the command line — they travel via stdin/env, so `ps` /
  `/proc/<pid>/cmdline` can't leak them.
- **E6** The box's *own* auth (Claude, GitHub) follows the same spirit — interactive
  login + forwarded SSH agent, nothing at rest (see [A], [T]).
- **E7** **Production mode, sealed-on-disk, re-init per box.** OpenBao stores its data
  encrypted on the box's disk; it boots **sealed** and is unsealed per session from the
  operator's key. Because the box is disposable (no persistent volume), each fresh box
  is **re-initialized** — it gets a new unseal key + root token, saved to the laptop for
  that box's life. (Chosen over dev/in-memory mode for a real unlock gate.)

**Runtime exposure (inherent, not removable).** To *use* a secret, its plaintext must
sit in process memory, where co-resident code on the box (e.g. a malicious dependency)
can read it and exfiltrate via open outbound. No storage choice fixes this. Mitigate
by: least-privilege scoping, short-lived/rotating credentials, separating **dev**
secrets (things run on the box) from **prod** secrets, and — best — letting the
deployment **target** pull its own secrets so the devbox is never a conduit for
production secrets.

## V — Verification (definition of done)

- **V1** A documented post-deploy check confirms the box is live and the harness
  works: `claude --version` succeeds as `eddyg`, the OS-appropriate git-write-guard
  fires on a sample `git commit`, and `gh auth status` is healthy.
- **V2** Agent forwarding is verified from the box (private `git ls-remote` succeeds
  using a forwarded key — no key stored on the box).
- **V3** The deploy command **reports what it did** (provider, OS, host/IP, access
  mode, what was installed, how to connect) — it does not silently succeed.
- **V4** `devbox vault load` pushes a secret from the operator's store into the box's
  OpenBao; an app on the box can read it back **only from within an SSH session**
  (vault is unreachable from the network); and after teardown nothing usable remains
  (E1–E3).

## Resolved decisions (2026-06-16)

- **Auth (T4, T2):** interactive, **no secrets at rest** — git via the forwarded
  agent; `claude` and `gh auth login` interactively on first session.
- **P3 defaults:** pinned — `sgp1`, `s-2vcpu-4gb`, Ubuntu 24.04; SSH port `2222`.
- **Provisioning tool:** `doctl` + `cloud-init` + bash (not Terraform). **No state
  file** — DigitalOcean is the source of truth; so the "state location" question is
  moot.
- **Network access:** SSH on `2222`, key-only, no IP allowlist, no Tailscale.
- **Secrets model:** **OpenBao vault on the devbox, production mode** (file storage,
  sealed-on-disk), bound to localhost, gated by the SSH login (see [E]). Single unseal
  key held on the laptop; **re-init per box**. Durable home for values = plaintext
  structured store on the operator's machine; `devbox vault load` pushes them in per
  session; the vault dies with the box. (Superseded, in order: tmpfs/sparse-shadow →
  SOPS-resolve-on-laptop → OpenBao dev/in-memory → **OpenBao prod mode**.)
