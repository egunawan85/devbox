# devbox — spec

> The contract: what must be true of a deployed devbox. Source of truth for the
> feature. Durable. For *why*, see [devbox.overview.md](./devbox.overview.md).

Each requirement is observable — you can check whether a given box satisfies it.

## P — Providers & OS matrix

- **P1** Each OS has one provider: **Linux → DigitalOcean**, **Windows → Azure**.
- **P2** Linux baseline: **Ubuntu LTS** (current 24.04). Windows baseline: **Windows
  Server LTS** with OpenSSH server. _Defaults; revisit per release._
- **P3** Size/region are **configurable with defaults** per provider.

## D — Deployment & lifecycle

- **D1** `up` is **one command, end to end**: it provisions a running box (if absent),
  configures it, brings the vault to ready (init/unseal — see [E]), and loads the
  operator's secrets. Idempotent (D3).
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
  authenticated work (git, other devboxes) without a key at rest. _Linux:_ via **SSH
  agent forwarding** of my device's agent. _Windows:_ the OpenSSH **server** on Windows
  does not implement agent forwarding (confirmed even on the latest OpenSSH v10), so the
  forwarded-agent mechanism is unavailable and is replaced by two paths: (a) the **devbox
  config** is **pushed from the operator's machine** over the authenticated SSH session
  during `configure` (the box never authenticates to GitHub for it); (b) **project repos**
  (the box's actual work) are reached by **interactive `gh auth login` + HTTPS git** in a
  dev session — a revocable, scoped OAuth token in `gh`'s config, consistent with the
  interactive box-auth already blessed by [E6]/[T4]. No SSH private key is ever stored on
  either OS.
- **A5** After deploy, I can reach the box from **either device with no password
  prompt**. _Linux:_ agent forwarding works (`ssh-add -l` over the connection shows my
  keys; `git ls-remote` to a private repo succeeds from the box). _Windows:_ `configure`
  delivers the config repo via push-from-laptop, and a `gh auth login` session can clone
  the project repos over HTTPS (see A4).

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

**OS applicability.** The *model* (E1–E6) is OS-neutral: an SSH-gated, localhost-bound
OpenBao vault, fed from the laptop, dying with the box. The *mechanics* differ by OS
because the substrate does — Linux uses systemd + tmpfs + logind; Windows has none of
these and substitutes a Windows Service, an encrypted-disk materialization, and a
session-count watchdog. Where a requirement names a Linux mechanism it states the Windows
equivalent inline. **OpenBao itself is cross-platform** (the project ships a `bao`
Windows binary), so the vault server, init/unseal, and `load` are the same on both; only
the lifecycle wrappers (E7–E9) are OS-specific.

- **E1** App secrets are served by an **OpenBao vault running on the devbox in
  production mode (`file` storage, sealed/encrypted at rest), bound to `127.0.0.1`
  only** — unreachable from the network. The **SSH login is the access gate**: only a
  session authenticated by the operator's SSH key can reach the vault. (OpenBao has no
  SSH-key auth method of its own; localhost-binding behind SSH is how the SSH key gates
  access.)
- **E2** The **durable home-of-record** for app secrets is the **operator's machine**,
  stored **plaintext** in a per-profile layout outside the repo (default
  `~/.config/devbox/<profile>/secrets/`, perms `700`/`600`). The box's vault is a
  session-scoped cache loaded from there — secrets are never born on the box, never live
  in the repo tree, and do not survive its teardown.
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
  ever passed on the command line — they travel via stdin/env, so a process listing
  (`ps` / `/proc/<pid>/cmdline` on Linux, the equivalent process inspection on Windows)
  can't leak them.
- **E6** The box's *own* auth (Claude, GitHub) follows the same spirit — interactive
  login + forwarded SSH agent, nothing at rest (see [A], [T]).
- **E7** **Production mode, sealed-on-disk, re-init per box.** OpenBao stores its data
  encrypted on the box's disk; it boots **sealed** and is unsealed per session from the
  operator's key. It runs as a **boot service that auto-starts (sealed) on every boot**
  — _Linux:_ a systemd unit; _Windows:_ a Windows Service (auto-start) — so after a
  reboot the server is up and `vault unseal` reopens it (no re-init). Because the box is
  disposable (no persistent volume), each fresh box is **re-initialized** — it gets a new
  unseal key + root token, saved to the laptop for that box's life. (Chosen over
  dev/in-memory mode for a real unlock gate.)
- **E8** _Optional._ **On-login materialization for file-based apps.** When the operator
  declares a manifest (vault project → dest path), the box materializes those secrets
  into the app's secret files while the operator is logged in, and **wipes them when the
  operator's _last_ session ends** — a **reference count**, not a per-logout action, so
  concurrent sessions are safe and a lingering one (e.g. a VS Code server) keeps the
  files until it too ends. Requires the vault unsealed; cleanup never touches a real file
  the operator placed, the operator's store, or the vault. The substrate differs by OS:
  - _Linux:_ secrets materialize to `.env` files **on tmpfs (RAM), never the box's
    disk**; lifecycle is reference-counted natively by **logind** + a systemd user
    service (materialize on first session, wipe on last).
  - _Windows:_ no tmpfs and no logind, so secrets materialize to each cloned repo's
    gitignored **`.vault`/`.env`** files — the very files the app's own loader already
    consumes — on the box's **encrypted, ephemeral disk** (owner/SYSTEM-ACL'd), and the
    reference count is **rebuilt by a SYSTEM watchdog** (60 s timer: recount the
    operator's live SSH sessions; materialize when ≥ 1 and the vault is unsealed, wipe
    when **zero**), with **logon/logoff event-log triggers (4624/4634)** layered on for
    near-instant wipe in the clean cases. Both paths run the identical "recount, wipe iff
    zero" logic, so they cannot disagree; the watchdog is authoritative and survives
    hard-kills (closed window, dropped connection) and crash/reboot leftovers (0 sessions
    at boot ⇒ stale files wiped before first login). Only files devbox wrote are ever
    wiped (tracked manifest). This **accepts encrypted-disk-at-rest on the ephemeral box**
    as the Windows substitute for Linux's RAM-only property — see the at-rest note below.
- **E9** _Optional._ **Auto-seal TTL.** The vault can be set to **re-seal a fixed time
  after each unseal** (reset on every unseal), enforced by a boot-managed timer
  (_Linux:_ systemd timer; _Windows:_ Scheduled Task) using a **seal-only** token
  (capability `sys/seal` only — it can lock the vault but **cannot read any secret**;
  root stays on the laptop). Re-locks a forgotten-unsealed vault; it does not wipe
  already-materialized session files (lock-only).

**At-rest posture (OS-dependent).** Linux keeps materialized secrets **RAM-only** (tmpfs)
— never on the box's disk. Windows cannot match that cheaply (no user-space tmpfs), so it
substitutes **session-lifecycle-bounded encrypted-disk-at-rest**: the materialized
`.vault`/`.env` exist on the box's encrypted, ephemeral disk **only while the operator has
a live session** (E8's reference count), and are gone at last logout and at teardown.
That window — "while you're logged in and working" — is exactly when the secret is already
plaintext in process memory anyway, so it does not widen the runtime exposure below. (A
RAM-disk could restore the RAM-only property later if wanted; deliberately deferred.)

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
- **V5** _(if E8 is enabled)_ The materialized secret files appear while the operator is
  logged in and are **gone once the operator's last session ends** — verified per OS:
  _Linux_, the `.env` is a tmpfs-backed link wiped at last logout; _Windows_, the repo's
  `.vault`/`.env` are real files on the encrypted disk that the watchdog wipes when the
  operator's SSH session count reaches zero (and a closed window / dropped connection
  wipes them too, not just a clean logout).

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
